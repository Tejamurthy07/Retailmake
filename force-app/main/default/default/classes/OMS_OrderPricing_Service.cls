/**
 * @description Service class for calculating order line item pricing including
 *              base price lookup, scheme/discount application, and tax computation.
 *              Designed for bulk invocation from triggers and batch processes.
 *
 *              Price resolution follows a configurable priority hierarchy
 *              (from Pricebook_Priority__mdt):
 *              1. Customer-wise (specific to the account)
 *              2. Category + Territory + Channel (3 combinations)
 *              3. Territory + Channel (2 combinations)
 *              4. Category + Territory
 *              5. Territory-wise
 *              6. Channel-wise
 *              7. Category-wise
 *              8. Base price (product only, no dimensions)
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class OMS_OrderPricing_Service {

    /**
     * @description Calculates pricing for order line items by looking up the
     *              applicable price list entry using priority-based resolution
     *              and computing the line total.
     *              Sets Unit_Price__c, Line_Amount__c on each line item.
     *
     * @param lineItems The list of Order_Line_Item__c records to price.
     */
    public static void calculateLineItemPricing(List<Order_Line_Item__c> lineItems) {
        if (lineItems == null || lineItems.isEmpty()) {
            return;
        }

        // Collect product IDs and sales order IDs for price resolution
        Set<Id> productIds = new Set<Id>();
        Set<Id> orderIds = new Set<Id>();

        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c != null) {
                productIds.add(item.Product_Ext__c);
            }
            if (item.Sales_Order__c != null) {
                orderIds.add(item.Sales_Order__c);
            }
        }

        if (productIds.isEmpty()) {
            return;
        }

        // Fetch order details to determine customer, territory, channel for price lookup
        Map<Id, Sales_Order__c> orderMap = new Map<Id, Sales_Order__c>();
        if (!orderIds.isEmpty()) {
            orderMap = new Map<Id, Sales_Order__c>([
                SELECT Id, Region__c, Channel__c, Trade_Channel__c, Account__c, Territory__c, Order_Date__c
                FROM Sales_Order__c
                WHERE Id IN :orderIds
            ]);
        }

        // Fetch product details to get category for price lookup
        Map<Id, Product_Extension__c> productMap = new Map<Id, Product_Extension__c>([
            SELECT Id, Product_Category__c
            FROM Product_Extension__c
            WHERE Id IN :productIds
        ]);

        // Fetch active price list entries for the products, ordered by priority (ascending)
        List<Price_List__c> priceLists = [
            SELECT Id, Product_Ext__c, Region__c, Channel__c,
                   Customer__c, Category__c, Territory__c, Priority__c,
                   Unit_Price__c, Effective_From__c, Effective_To__c,
                   Price_Type__c, Min_Qty__c
            FROM Price_List__c
            WHERE Product_Ext__c IN :productIds
              AND Is_Active__c = true
              AND Effective_From__c <= TODAY
              AND (Effective_To__c >= TODAY OR Effective_To__c = null)
            ORDER BY Priority__c ASC, Effective_From__c DESC
        ];

        // Build a map of product ID -> list of price entries (ordered by priority)
        Map<Id, List<Price_List__c>> pricesByProduct = new Map<Id, List<Price_List__c>>();
        for (Price_List__c pl : priceLists) {
            if (!pricesByProduct.containsKey(pl.Product_Ext__c)) {
                pricesByProduct.put(pl.Product_Ext__c, new List<Price_List__c>());
            }
            pricesByProduct.get(pl.Product_Ext__c).add(pl);
        }

        // Calculate pricing for each line item
        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c == null) {
                continue;
            }

            Decimal quantity = item.Quantity__c != null ? item.Quantity__c : 0;
            Decimal unitPrice = item.Unit_Price__c;

            // Look up price if not manually set
            if (unitPrice == null || unitPrice == 0) {
                Sales_Order__c order = orderMap.get(item.Sales_Order__c);
                Product_Extension__c product = productMap.get(item.Product_Ext__c);

                Id accountId = (order != null) ? order.Account__c : null;
                Id territoryId = (order != null) ? order.Territory__c : null;
                // MDM-003: Use Trade_Channel__c (actual trade channel from Account)
                // instead of Channel__c (which is the order-entry method like Field App/Portal)
                String channel = '';
                if (order != null) {
                    channel = (BPM_FeatureToggle_Util.isEnabled('MDM-003') && String.isNotBlank(order.Trade_Channel__c))
                        ? order.Trade_Channel__c : order.Channel__c;
                }
                Id categoryId = (product != null) ? product.Product_Category__c : null;

                List<Price_List__c> productPrices = pricesByProduct.get(item.Product_Ext__c);
                Decimal orderQty = item.Quantity__c != null ? item.Quantity__c : 0;
                // Also record which Price_List__c matched so draft-edit and
                // audit can trace the exact pricing source applied.
                Price_List__c matchedPL = resolvePriceListByPriority(
                    productPrices, accountId, categoryId, territoryId, channel, orderQty
                );
                if (matchedPL != null) {
                    unitPrice = matchedPL.Unit_Price__c;
                    item.Price_List__c = matchedPL.Id;
                } else {
                    unitPrice = 0;
                }
                item.Unit_Price__c = unitPrice;
            }

            // Use base quantity (UOM-converted) for pricing when available;
            // unit price is always per base UOM, so we must multiply by the
            // converted base quantity to get the correct line amount.
            Decimal pricingQuantity = (item.Base_Quantity__c != null && item.Base_Quantity__c > 0)
                ? item.Base_Quantity__c : quantity;
            Decimal lineAmount = (unitPrice != null ? unitPrice : 0) * pricingQuantity;
            item.Line_Amount__c = lineAmount.setScale(2, RoundingMode.HALF_UP);

            // Calculate net amount (after line-level discount)
            Decimal discountPercent = item.Discount_Percent__c != null
                ? item.Discount_Percent__c : 0;
            Decimal discountAmount;
            if (discountPercent > 0) {
                // Calculate from percentage
                discountAmount = (lineAmount * discountPercent / 100)
                    .setScale(2, RoundingMode.HALF_UP);
                item.Discount_Amount__c = discountAmount;
            } else if (item.Discount_Amount__c != null && item.Discount_Amount__c > 0) {
                // Preserve pre-set discount amount (e.g., from controller/LWC)
                discountAmount = item.Discount_Amount__c;
                // Back-calculate the percentage for consistency
                if (lineAmount > 0) {
                    item.Discount_Percent__c = (discountAmount / lineAmount * 100)
                        .setScale(2, RoundingMode.HALF_UP);
                }
            } else {
                discountAmount = 0;
                item.Discount_Amount__c = 0;
            }
            item.Net_Amount__c = (lineAmount - discountAmount).setScale(2, RoundingMode.HALF_UP);
        }
    }

    /**
     * @description Applies eligible promotional schemes to order line items.
     *              Uses the SPM_SchemeEngine_Service to evaluate schemes and
     *              applies discounts or free goods to qualifying items.
     *
     * @param lineItems The list of Order_Line_Item__c records to evaluate.
     */
    public static void applySchemes(List<Order_Line_Item__c> lineItems) {
        if (lineItems == null || lineItems.isEmpty()) {
            return;
        }

        // Collect order IDs for account lookup
        Set<Id> orderIds = new Set<Id>();
        for (Order_Line_Item__c item : lineItems) {
            if (item.Sales_Order__c != null) {
                orderIds.add(item.Sales_Order__c);
            }
        }

        if (orderIds.isEmpty()) {
            return;
        }

        // Fetch parent order details
        Map<Id, Sales_Order__c> orderMap = new Map<Id, Sales_Order__c>([
            SELECT Id, Account__c, Order_Date__c
            FROM Sales_Order__c
            WHERE Id IN :orderIds
        ]);

        // Group line items by order
        Map<Id, List<Order_Line_Item__c>> itemsByOrder = new Map<Id, List<Order_Line_Item__c>>();
        for (Order_Line_Item__c item : lineItems) {
            if (!itemsByOrder.containsKey(item.Sales_Order__c)) {
                itemsByOrder.put(item.Sales_Order__c, new List<Order_Line_Item__c>());
            }
            itemsByOrder.get(item.Sales_Order__c).add(item);
        }

        // Evaluate schemes per order
        for (Id orderId : itemsByOrder.keySet()) {
            Sales_Order__c order = orderMap.get(orderId);
            if (order == null || order.Account__c == null) {
                continue;
            }

            List<Order_Line_Item__c> orderItems = itemsByOrder.get(orderId);
            Date orderDate = order.Order_Date__c != null ? order.Order_Date__c : Date.today();

            List<SPM_SchemeEngine_Service.SchemeResult> schemes =
                SPM_SchemeEngine_Service.getApplicableSchemes(
                    order.Account__c, orderItems, orderDate
                );

            // Apply scheme results to line items
            applySchemeResults(orderItems, schemes);
        }
    }

    /**
     * @description Calculates tax for order line items using the MDM Tax Engine.
     *              Sets CGST__c, SGST__c, IGST__c, and Tax_Amount__c on each item.
     *
     * @param lineItems The list of Order_Line_Item__c records to tax.
     */
    public static void calculateTax(List<Order_Line_Item__c> lineItems) {
        if (lineItems == null || lineItems.isEmpty()) {
            return;
        }

        // Collect order IDs for state lookup
        Set<Id> orderIds = new Set<Id>();
        for (Order_Line_Item__c item : lineItems) {
            if (item.Sales_Order__c != null) {
                orderIds.add(item.Sales_Order__c);
            }
        }

        // Fetch order details with shipping state
        Map<Id, Sales_Order__c> orderMap = new Map<Id, Sales_Order__c>();
        if (!orderIds.isEmpty()) {
            orderMap = new Map<Id, Sales_Order__c>([
                SELECT Id, Shipping_State__c, Warehouse_State__c
                FROM Sales_Order__c
                WHERE Id IN :orderIds
            ]);
        }

        // Prepare bulk tax calculation inputs
        List<Id> productIds = new List<Id>();
        List<Decimal> taxableAmounts = new List<Decimal>();
        List<Order_Line_Item__c> taxableItems = new List<Order_Line_Item__c>();
        String fromState = '';
        String toState = '';

        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c == null) {
                continue;
            }

            // Taxable amount = Net Amount (after line discount) - Scheme Discount
            Decimal netAmount = item.Net_Amount__c != null ? item.Net_Amount__c : 0;
            Decimal schemeDisc = item.Scheme_Discount__c != null ? item.Scheme_Discount__c : 0;
            Decimal taxableAmount = netAmount - schemeDisc;
            if (taxableAmount <= 0) {
                continue;
            }

            Sales_Order__c order = orderMap.get(item.Sales_Order__c);
            if (order != null) {
                fromState = String.isNotBlank(order.Warehouse_State__c)
                    ? order.Warehouse_State__c : '';
                toState = String.isNotBlank(order.Shipping_State__c)
                    ? order.Shipping_State__c : '';
            }

            productIds.add(item.Product_Ext__c);
            taxableAmounts.add(taxableAmount);
            taxableItems.add(item);
        }

        if (taxableItems.isEmpty()) {
            return;
        }

        // Bulk calculate tax
        List<MDM_TaxEngine_Service.TaxResult> taxResults =
            MDM_TaxEngine_Service.calculateTaxBulk(productIds, fromState, toState, taxableAmounts);

        // Fallback GST rates from the product master, used when no
        // Tax_Configuration__c record links to the product (the tax engine
        // returns 0 in that case, which would wipe out tax entirely).
        Map<Id, Decimal> productGstMap = new Map<Id, Decimal>();
        for (Product_Extension__c prod : [
            SELECT Id, GST_Rate__c FROM Product_Extension__c WHERE Id IN :productIds
        ]) {
            productGstMap.put(prod.Id, prod.GST_Rate__c != null ? prod.GST_Rate__c : 0);
        }

        Boolean interState = String.isNotBlank(fromState) && String.isNotBlank(toState)
            && !fromState.trim().equalsIgnoreCase(toState.trim());

        // Apply tax results to line items
        for (Integer i = 0; i < taxableItems.size(); i++) {
            Order_Line_Item__c item = taxableItems[i];
            MDM_TaxEngine_Service.TaxResult taxResult = taxResults[i];

            Decimal taxRate = taxResult.taxRate;
            Decimal totalTax = taxResult.totalTax;
            Decimal cgst = taxResult.cgst;
            Decimal sgst = taxResult.sgst;
            Decimal igst = taxResult.igst;

            // Fallback to product GST_Rate__c when no tax configuration matched
            if ((taxRate == null || taxRate <= 0) && productGstMap.containsKey(item.Product_Ext__c)) {
                taxRate = productGstMap.get(item.Product_Ext__c);
                Decimal taxable = taxableAmounts[i];
                if (taxRate > 0) {
                    totalTax = (taxable * taxRate / 100).setScale(2, RoundingMode.HALF_UP);
                    if (interState) {
                        igst = totalTax; cgst = 0; sgst = 0;
                    } else {
                        cgst = (totalTax / 2).setScale(2, RoundingMode.HALF_UP);
                        sgst = totalTax - cgst; igst = 0;
                    }
                }
            }

            item.CGST__c = cgst;
            item.SGST__c = sgst;
            item.IGST__c = igst;
            item.Tax_Amount__c = totalTax;
            item.Tax_Rate__c = taxRate;
            item.Total_Amount__c = (item.Net_Amount__c != null ? item.Net_Amount__c : 0)
                + (totalTax != null ? totalTax : 0);
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Resolves the unit price using priority-based lookup.
     *              Iterates through price list entries (already sorted by priority ASC)
     *              and returns the first match based on dimension matching.
     *
     *              For each price list entry, checks if its dimensions match:
     *              - Customer must match if set on the price list
     *              - Category must match if set on the price list
     *              - Territory must match if set on the price list
     *              - Channel must match if set on the price list
     *
     * @param productPrices List of price list entries for the product (sorted by priority ASC)
     * @param accountId     The customer account from the order
     * @param categoryId    The product category
     * @param territoryId   The territory from the order
     * @param channel       The channel from the order
     * @param orderQuantity The order quantity for Min_Qty filtering
     * @return The resolved unit price, or 0 if no match found
     */
    private static Decimal resolvePriceByPriority(
        List<Price_List__c> productPrices,
        Id accountId,
        Id categoryId,
        Id territoryId,
        String channel,
        Decimal orderQuantity
    ) {
        if (productPrices == null || productPrices.isEmpty()) {
            return 0;
        }

        for (Price_List__c pl : productPrices) {
            Boolean matches = true;

            // Customer dimension: if price list has customer, order must match
            if (pl.Customer__c != null) {
                if (accountId == null || pl.Customer__c != accountId) {
                    matches = false;
                }
            }

            // Category dimension: if price list has category, product must match
            if (matches && pl.Category__c != null) {
                if (categoryId == null || pl.Category__c != categoryId) {
                    matches = false;
                }
            }

            // Territory dimension: if price list has territory, order must match
            if (matches && pl.Territory__c != null) {
                if (territoryId == null || pl.Territory__c != territoryId) {
                    matches = false;
                }
            }

            // Channel dimension: if price list has channel, order must match
            if (matches && String.isNotBlank(pl.Channel__c)) {
                if (String.isBlank(channel) || pl.Channel__c != channel) {
                    matches = false;
                }
            }

            // Min Qty: if price list has minimum quantity, order quantity must meet it
            if (matches && pl.Min_Qty__c != null && pl.Min_Qty__c > 0) {
                if (orderQuantity < pl.Min_Qty__c) {
                    matches = false;
                }
            }

            if (matches) {
                return pl.Unit_Price__c;
            }
        }

        return 0;
    }

    /**
     * @description Same filtering/ordering as resolvePriceByPriority but
     *              returns the matched Price_List__c record (or null).
     *              Used by applyPricing to stamp Order_Line_Item__c.Price_List__c
     *              so the order-draft edit flow can show the exact price list
     *              applied and recalculate from the same source.
     */
    private static Price_List__c resolvePriceListByPriority(
        List<Price_List__c> productPrices,
        Id accountId,
        Id categoryId,
        Id territoryId,
        String channel,
        Decimal orderQuantity
    ) {
        if (productPrices == null || productPrices.isEmpty()) {
            return null;
        }

        for (Price_List__c pl : productPrices) {
            Boolean matches = true;

            if (pl.Customer__c != null
                && (accountId == null || pl.Customer__c != accountId)) matches = false;
            if (matches && pl.Category__c != null
                && (categoryId == null || pl.Category__c != categoryId)) matches = false;
            if (matches && pl.Territory__c != null
                && (territoryId == null || pl.Territory__c != territoryId)) matches = false;
            if (matches && String.isNotBlank(pl.Channel__c)
                && (String.isBlank(channel) || pl.Channel__c != channel)) matches = false;
            if (matches && pl.Min_Qty__c != null && pl.Min_Qty__c > 0
                && orderQuantity < pl.Min_Qty__c) matches = false;

            if (matches) return pl;
        }
        return null;
    }

    /**
     * @description Applies scheme results (discounts, free goods) to line items.
     *              Uses lineItemDiscounts map when available for targeted application,
     *              otherwise falls back to applying discount to the first qualifying item.
     */
    private static void applySchemeResults(
        List<Order_Line_Item__c> lineItems,
        List<SPM_SchemeEngine_Service.SchemeResult> schemes
    ) {
        if (schemes == null || schemes.isEmpty()) {
            return;
        }

        for (SPM_SchemeEngine_Service.SchemeResult scheme : schemes) {
            // Use per-line-item discount map if available (preferred). This
            // is a 'targeted' scheme — it explicitly identifies the lines it
            // applies to, so it's a legitimate primary attribution for those
            // lines.
            if (scheme.lineItemDiscounts != null && !scheme.lineItemDiscounts.isEmpty()) {
                for (Order_Line_Item__c item : lineItems) {
                    if (scheme.lineItemDiscounts.containsKey(item.Id)) {
                        Decimal itemDiscount = scheme.lineItemDiscounts.get(item.Id);
                        Decimal currentDiscount = item.Scheme_Discount__c != null
                            ? item.Scheme_Discount__c : 0;
                        item.Scheme_Discount__c = currentDiscount + itemDiscount;
                        // Only attribute the scheme to the line if there's
                        // no scheme already on it (either Scheme__c lookup
                        // or Scheme_Applied__c). The first targeted scheme
                        // wins; later schemes still contribute to the
                        // discount total but don't overwrite the lookup.
                        // Respecting a pre-set Scheme_Applied__c is what
                        // lets an explicit caller (e.g. order-entry UI that
                        // lets a rep pick a scheme manually) override the
                        // engine's automatic match.
                        if (item.Scheme__c == null && item.Scheme_Applied__c == null) {
                            item.Scheme__c = scheme.schemeId;
                            item.Scheme_Applied__c = scheme.schemeId;
                            item.Scheme_Category__c = scheme.schemeCategory;
                        }
                    }
                }
            } else if (scheme.discountAmount != null && scheme.discountAmount > 0) {
                // Order-level / proportional scheme — only contributes to
                // each line's Scheme_Discount__c. Does NOT overwrite the
                // per-line Scheme__c lookup, which would mis-attribute a
                // line's product-specific scheme (e.g. 'Detergent Invoice
                // Qty Discount' on a detergent line) to a generic order
                // scheme (e.g. 'Snacks & Noodles 3% Off') and confuse
                // reporting / audit.
                Decimal totalLineAmount = 0;
                for (Order_Line_Item__c item : lineItems) {
                    totalLineAmount += (item.Net_Amount__c != null ? item.Net_Amount__c : 0);
                }
                if (totalLineAmount > 0) {
                    for (Order_Line_Item__c item : lineItems) {
                        Decimal itemNetAmount = item.Net_Amount__c != null ? item.Net_Amount__c : 0;
                        Decimal proportion = itemNetAmount / totalLineAmount;
                        Decimal itemDiscount = (scheme.discountAmount * proportion)
                            .setScale(2, RoundingMode.HALF_UP);
                        Decimal currentDiscount = item.Scheme_Discount__c != null
                            ? item.Scheme_Discount__c : 0;
                        item.Scheme_Discount__c = currentDiscount + itemDiscount;
                        // Order-level schemes are intentionally NOT stamped
                        // onto the line's Scheme__c lookup — that field is
                        // reserved for a product/category-targeted scheme
                        // attribution. Order-level discounts only flow into
                        // Scheme_Discount__c.
                    }
                }
            }
        }
    }
}