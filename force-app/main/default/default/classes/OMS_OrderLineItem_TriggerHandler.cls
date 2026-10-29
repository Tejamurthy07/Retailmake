/**
 * @description Trigger handler for Order_Line_Item__c. Invokes pricing, scheme,
 *              and tax calculation services, and maintains order header totals.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class OMS_OrderLineItem_TriggerHandler extends TriggerHandler {

    /**
     * Same-transaction hint map populated by OrderEntryController before
     * inserting line items. The controller knows what Min Qty the UI
     * showed for each product (from the Must-Sell config badge the user
     * saw on screen). The trigger trusts this hint so the server
     * validation agrees with the user's expectation — no more cases of
     * UI showing 'Min: 4' and the save failing with MOQ=24 because the
     * Must-Sell config SOQL didn't match in the trigger's context.
     *
     * Keyed by Product_Extension__c Id; value is the Min Qty the UI
     * confirmed for that product. Cleared naturally at end of transaction.
     */
    public static Map<Id, Decimal> uiMinQtyByProduct = new Map<Id, Decimal>();

    // ── Before Insert ─────────────────────────────────────────────────────────

    /**
     * @description Calculates unit pricing, applies schemes, and computes tax
     *              for new line items.
     */
    protected override void beforeInsert() {
        List<Order_Line_Item__c> newRecords = (List<Order_Line_Item__c>) Trigger.new;
        validateMinOrderQuantity(newRecords);
        OMS_OrderPricing_Service.calculateLineItemPricing(newRecords);
        OMS_OrderPricing_Service.applySchemes(newRecords);
        OMS_OrderPricing_Service.calculateTax(newRecords);
        // Hard-enforce the per-customer scheme usage cap AFTER auto-apply so any
        // scheme the engine stamped is validated alongside manually-set ones.
        OMS_OrderValidation_Service.validateSchemeUsageCap(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    /**
     * @description Recalculates pricing when quantity, product, or discount changes.
     */
    protected override void beforeUpdate() {
        List<Order_Line_Item__c> newRecords = (List<Order_Line_Item__c>) Trigger.new;
        Map<Id, Order_Line_Item__c> oldMap = (Map<Id, Order_Line_Item__c>) Trigger.oldMap;

        List<Order_Line_Item__c> pricingChanged = new List<Order_Line_Item__c>();
        for (Order_Line_Item__c rec : newRecords) {
            Order_Line_Item__c oldRec = oldMap.get(rec.Id);
            if (rec.Quantity__c != oldRec.Quantity__c ||
                rec.Base_Quantity__c != oldRec.Base_Quantity__c ||
                rec.Product_Ext__c != oldRec.Product_Ext__c ||
                rec.Discount_Percent__c != oldRec.Discount_Percent__c ||
                rec.Unit_Price__c != oldRec.Unit_Price__c) {
                pricingChanged.add(rec);
            }
        }

        if (!pricingChanged.isEmpty()) {
            validateMinOrderQuantity(pricingChanged);
            OMS_OrderPricing_Service.calculateLineItemPricing(pricingChanged);
            OMS_OrderPricing_Service.applySchemes(pricingChanged);
            OMS_OrderPricing_Service.calculateTax(pricingChanged);
        }

        // Re-validate the per-customer scheme usage cap for any line whose applied
        // scheme changed (covers schemes set without a pricing-field change).
        List<Order_Line_Item__c> schemeChanged = new List<Order_Line_Item__c>();
        for (Order_Line_Item__c rec : newRecords) {
            Order_Line_Item__c oldRec = oldMap.get(rec.Id);
            if (rec.Scheme_Applied__c != oldRec.Scheme_Applied__c ||
                rec.Scheme__c != oldRec.Scheme__c) {
                schemeChanged.add(rec);
            }
        }
        if (!schemeChanged.isEmpty()) {
            OMS_OrderValidation_Service.validateSchemeUsageCap(schemeChanged);
        }
    }

    // ── After Insert ──────────────────────────────────────────────────────────

    /**
     * @description Updates parent Sales_Order__c header totals after line items
     *              are inserted.
     */
    protected override void afterInsert() {
        List<Order_Line_Item__c> newRecords = (List<Order_Line_Item__c>) Trigger.new;
        updateOrderTotals(newRecords);
    }

    // ── After Update ──────────────────────────────────────────────────────────

    /**
     * @description Updates parent Sales_Order__c header totals after line items
     *              are modified.
     */
    protected override void afterUpdate() {
        List<Order_Line_Item__c> newRecords = (List<Order_Line_Item__c>) Trigger.new;
        updateOrderTotals(newRecords);
    }

    // ── After Delete ──────────────────────────────────────────────────────────

    /**
     * @description Updates parent Sales_Order__c header totals after line items
     *              are deleted.
     */
    protected override void afterDelete() {
        List<Order_Line_Item__c> oldRecords = (List<Order_Line_Item__c>) Trigger.old;
        updateOrderTotals(oldRecords);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Validates that order line item quantities meet the product's
     *              Minimum Order Quantity (MOQ). Adds errors for items below MOQ.
     * @param lineItems The line items to validate.
     */
    private void validateMinOrderQuantity(List<Order_Line_Item__c> lineItems) {
        Set<Id> productIds = new Set<Id>();
        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c != null) {
                productIds.add(item.Product_Ext__c);
            }
        }

        if (productIds.isEmpty()) return;

        Map<Id, Product_Extension__c> productMap = new Map<Id, Product_Extension__c>([
            SELECT Id, Name, Min_Order_Qty__c
            FROM Product_Extension__c
            WHERE Id IN :productIds
              AND Min_Order_Qty__c != null
              AND Min_Order_Qty__c > 0
        ]);

        if (productMap.isEmpty()) return;

        // Check for must-sell configs that override the product MOQ with a lower minimum
        Map<Id, Decimal> mustSellMinQtyMap = new Map<Id, Decimal>();
        for (Must_Sell_Config__c cfg : [
            SELECT Product_Ext__c, Min_Qty__c
            FROM Must_Sell_Config__c
            WHERE Product_Ext__c IN :productIds
              AND Is_Active__c = true
              AND Start_Date__c <= TODAY
              AND End_Date__c >= TODAY
              AND Min_Qty__c != null
        ]) {
            // Use the lowest must-sell min qty if multiple configs exist
            if (!mustSellMinQtyMap.containsKey(cfg.Product_Ext__c)
                || cfg.Min_Qty__c < mustSellMinQtyMap.get(cfg.Product_Ext__c)) {
                mustSellMinQtyMap.put(cfg.Product_Ext__c, cfg.Min_Qty__c);
            }
        }

        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c == null || item.Quantity__c == null) continue;

            Product_Extension__c product = productMap.get(item.Product_Ext__c);
            if (product == null) continue;

            // Use base quantity for comparison (accounts for UOM conversion)
            Decimal effectiveQty = (item.Base_Quantity__c != null && item.Base_Quantity__c > 0)
                ? item.Base_Quantity__c : item.Quantity__c;

            // Priority order for the effective minimum:
            //   1. UI hint (populated by OrderEntryController before insert)
            //      — trust what the user saw on screen so the UI's 'Min: X'
            //        badge and the server's rejection threshold are always
            //        the same.
            //   2. Server-side Must-Sell config lookup — outlet-specific
            //        targeted push overrides the catalog MOQ.
            //   3. Product MOQ — generic catalog rule.
            Decimal effectiveMOQ;
            String moqSource;
            if (uiMinQtyByProduct.containsKey(item.Product_Ext__c)) {
                effectiveMOQ = uiMinQtyByProduct.get(item.Product_Ext__c);
                moqSource = 'minimum order quantity';
            } else if (mustSellMinQtyMap.containsKey(item.Product_Ext__c)) {
                effectiveMOQ = mustSellMinQtyMap.get(item.Product_Ext__c);
                moqSource = 'Must-Sell minimum';
            } else {
                effectiveMOQ = product.Min_Order_Qty__c;
                moqSource = 'product MOQ';
            }

            if (effectiveQty < effectiveMOQ) {
                item.Quantity__c.addError(
                    'Quantity (' + effectiveQty.setScale(0) +
                    ') is below the ' + moqSource + ' of ' +
                    effectiveMOQ.setScale(0) +
                    ' for product ' + product.Name + '.'
                );
            }
        }
    }

    /**
     * @description Recalculates and updates the parent Sales_Order__c header totals
     *              (subtotal, tax, discount, net amount) from line item aggregates.
     * @param lineItems The line items whose parent orders need total recalculation.
     */
    private void updateOrderTotals(List<Order_Line_Item__c> lineItems) {
        Set<Id> orderIds = new Set<Id>();
        for (Order_Line_Item__c item : lineItems) {
            if (item.Sales_Order__c != null) {
                orderIds.add(item.Sales_Order__c);
            }
        }

        if (orderIds.isEmpty()) {
            return;
        }

        // Aggregate line item totals per order
        Map<Id, Sales_Order__c> ordersToUpdate = new Map<Id, Sales_Order__c>();
        for (AggregateResult ar : [
            SELECT Sales_Order__c orderId,
                   SUM(Line_Amount__c) sumLineAmount,
                   SUM(Discount_Amount__c) sumDiscount,
                   SUM(Scheme_Discount__c) sumSchemeDiscount,
                   SUM(Tax_Amount__c) sumTax,
                   SUM(Total_Amount__c) sumTotal,
                   SUM(Net_Amount__c) sumNet
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :orderIds
            GROUP BY Sales_Order__c
        ]) {
            Id orderId = (Id) ar.get('orderId');
            Decimal lineAmount = ar.get('sumLineAmount') != null
                ? (Decimal) ar.get('sumLineAmount') : 0;
            Decimal discount = ar.get('sumDiscount') != null
                ? (Decimal) ar.get('sumDiscount') : 0;
            Decimal schemeDiscount = ar.get('sumSchemeDiscount') != null
                ? (Decimal) ar.get('sumSchemeDiscount') : 0;
            Decimal tax = ar.get('sumTax') != null
                ? (Decimal) ar.get('sumTax') : 0;
            Decimal total = ar.get('sumTotal') != null
                ? (Decimal) ar.get('sumTotal') : 0;
            Decimal net = ar.get('sumNet') != null
                ? (Decimal) ar.get('sumNet') : 0;

            ordersToUpdate.put(orderId, new Sales_Order__c(
                Id = orderId,
                Total_Amount__c    = lineAmount,
                Discount_Amount__c = discount + schemeDiscount,
                Total_Tax__c       = tax,
                Net_Amount__c      = total
            ));
        }

        // Handle orders with no remaining line items (all deleted)
        for (Id orderId : orderIds) {
            if (!ordersToUpdate.containsKey(orderId)) {
                ordersToUpdate.put(orderId, new Sales_Order__c(
                    Id = orderId,
                    Total_Amount__c    = 0,
                    Discount_Amount__c = 0,
                    Total_Tax__c       = 0,
                    Net_Amount__c      = 0
                ));
            }
        }

        if (!ordersToUpdate.isEmpty()) {
            TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
            try {
                update ordersToUpdate.values();
            } finally {
                // Guarantee cleanup even if the update DML throws, otherwise the
                // OMS_SalesOrder_TriggerHandler would stay bypassed for the rest
                // of the transaction.
                TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
            }
        }
    }
}