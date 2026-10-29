/**
 * @description Dispatches an approved Primary_Order__c: creates the primary
 *              dispatch Invoice (+ lines) from the order's lines, applies GST
 *              (CGST/SGST/IGST via DMS_Tax_Service by origin/destination state),
 *              accrues distributor scheme payouts, deducts source-warehouse stock,
 *              refreshes the distributor's credit/outstanding, links the invoice
 *              back and advances the order to Dispatched.
 *
 *              This is the canonical primary-fulfilment path (the Sales-Order-shaped
 *              Primary_Order__c object superseded the legacy Indent__c). Kept at
 *              feature parity with DMS_IndentFulfillment_Service. Inert unless the
 *              DMS master + primary-fulfilment toggles are enabled.
 */
public without sharing class DMS_PrimaryOrderFulfillment_Service {

    public class FulfillmentException extends Exception {}

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    /**
     * Blocks fulfilment when the source warehouse cannot cover the order.
     *
     * Primary dispatch was the only stock movement in the system with no availability
     * gate: the deduction floors at zero (Math.max(0, onHand - qty)) and silently skips
     * products with no stock row, so an over-dispatch simply vanished — the distributor
     * was invoiced for goods the warehouse never had. Secondary billing already throws;
     * this brings primary in line.
     */
    private static void assertStockAvailable(
            List<Primary_Order__c> orders,
            Map<Id, List<INV_WarehouseStock_Service.StockLineItem>> deductByOrder) {

        // Required quantity per warehouse, per product, across the whole batch.
        Map<Id, Map<Id, Decimal>> requiredByWarehouse = new Map<Id, Map<Id, Decimal>>();
        for (Primary_Order__c o : orders) {
            List<INV_WarehouseStock_Service.StockLineItem> items = deductByOrder.get(o.Id);
            if (o.Warehouse__c == null || items == null) { continue; }
            if (!requiredByWarehouse.containsKey(o.Warehouse__c)) {
                requiredByWarehouse.put(o.Warehouse__c, new Map<Id, Decimal>());
            }
            Map<Id, Decimal> byProduct = requiredByWarehouse.get(o.Warehouse__c);
            for (INV_WarehouseStock_Service.StockLineItem i : items) {
                byProduct.put(i.productId, nz(byProduct.get(i.productId)) + nz(i.quantity));
            }
        }

        Map<Id, String> shortfall = new Map<Id, String>();   // productId -> "need X, available Y"
        for (Id whId : requiredByWarehouse.keySet()) {
            Map<Id, Decimal> byProduct = requiredByWarehouse.get(whId);
            Map<Id, Decimal> available = INV_WarehouseStock_Service.checkAvailability(
                whId, new List<Id>(byProduct.keySet()));
            for (Id prodId : byProduct.keySet()) {
                Decimal need = nz(byProduct.get(prodId));
                Decimal have = nz(available.get(prodId));
                if (need > have) {
                    shortfall.put(prodId, 'need ' + need + ', available ' + have);
                }
            }
        }
        if (shortfall.isEmpty()) { return; }

        List<String> parts = new List<String>();
        for (Product_Extension__c p : [
            SELECT Id, Name FROM Product_Extension__c WHERE Id IN :shortfall.keySet()
        ]) {
            parts.add(p.Name + ' (' + shortfall.get(p.Id) + ')');
        }
        throw new FulfillmentException(
            'Insufficient warehouse stock to fulfil this order: ' + String.join(parts, '; '));
    }

    public static void fulfillApproved(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) { return; }
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_PRIMARY_FULFILLMENT)) {
            return;
        }

        List<Primary_Order__c> orders = [
            SELECT Id, Account__c, Warehouse__c, Territory__c, Status__c, Invoice__c
            FROM Primary_Order__c WHERE Id IN :orderIds
        ];
        // Only fulfil approved orders with a source warehouse and no invoice yet.
        List<Primary_Order__c> fulfillable = new List<Primary_Order__c>();
        Set<Id> warehouseIds = new Set<Id>();
        Set<Id> distributorIds = new Set<Id>();
        for (Primary_Order__c o : orders) {
            if (o.Warehouse__c != null && o.Invoice__c == null) {
                fulfillable.add(o);
                warehouseIds.add(o.Warehouse__c);
                if (o.Account__c != null) { distributorIds.add(o.Account__c); }
            }
        }
        if (fulfillable.isEmpty()) { return; }

        Map<Id, List<Primary_Order_Line__c>> linesByOrder = new Map<Id, List<Primary_Order_Line__c>>();
        for (Primary_Order_Line__c l : [
            SELECT Id, Primary_Order__c, Product_Ext__c, Quantity__c, Base_Quantity__c,
                   Unit_Price__c, Discount_Amount__c, Tax_Rate__c, Tax_Amount__c, Line_Total__c
            FROM Primary_Order_Line__c WHERE Primary_Order__c IN :fulfillable
        ]) {
            if (l.Product_Ext__c == null) { continue; }
            if (!linesByOrder.containsKey(l.Primary_Order__c)) {
                linesByOrder.put(l.Primary_Order__c, new List<Primary_Order_Line__c>());
            }
            linesByOrder.get(l.Primary_Order__c).add(l);
        }

        // GST origin (source warehouse) / destination (distributor) states.
        Map<Id, String> warehouseState = new Map<Id, String>();
        for (Warehouse__c w : [SELECT Id, State__c FROM Warehouse__c WHERE Id IN :warehouseIds]) {
            warehouseState.put(w.Id, w.State__c);
        }
        Map<Id, String> distState = new Map<Id, String>();
        for (Account a : [SELECT Id, BillingState FROM Account WHERE Id IN :distributorIds]) {
            distState.put(a.Id, a.BillingState);
        }

        // 1. Invoice header per fulfillable order (that has lines).
        Map<Id, Invoice__c> invoiceByOrder = new Map<Id, Invoice__c>();
        List<Invoice__c> invoices = new List<Invoice__c>();
        String stamp = String.valueOf(Datetime.now().getTime());
        Integer counter = 0;
        for (Primary_Order__c o : fulfillable) {
            List<Primary_Order_Line__c> ls = linesByOrder.get(o.Id);
            if (ls == null || ls.isEmpty()) { continue; }
            Invoice__c inv = new Invoice__c(
                Account__c        = o.Account__c,
                Order_Type__c     = DMS_Constants.ORDER_TYPE_PRIMARY,
                Invoice_Date__c   = Date.today(),
                Dispatch_Date__c  = Date.today(),
                Invoice_Number__c = DMS_Config.primaryPrefix() + stamp + '-' + String.valueOf(counter).leftPad(4, '0'),
                Status__c         = 'Draft',
                Warehouse__c      = o.Warehouse__c,
                Territory__c      = o.Territory__c
            );
            invoices.add(inv);
            invoiceByOrder.put(o.Id, inv);
            counter++;
        }
        if (invoices.isEmpty()) { return; }
        insert invoices;

        // 2. Invoice lines + tax inputs + deduction items; accumulate taxable base.
        List<Invoice_Line__c> invLines = new List<Invoice_Line__c>();
        List<DMS_Tax_Service.LineTaxInput> taxInputs = new List<DMS_Tax_Service.LineTaxInput>();
        Map<Id, Decimal> baseById = new Map<Id, Decimal>();   // taxable base per invoice (accrual + subtotal)
        Map<Id, Id> accountByInvoice = new Map<Id, Id>();
        Map<Id, List<INV_WarehouseStock_Service.StockLineItem>> deductByOrder =
            new Map<Id, List<INV_WarehouseStock_Service.StockLineItem>>();

        for (Primary_Order__c o : fulfillable) {
            Invoice__c inv = invoiceByOrder.get(o.Id);
            if (inv == null) { continue; }
            String fromState = warehouseState.get(o.Warehouse__c);
            String toState = o.Account__c != null ? distState.get(o.Account__c) : null;
            accountByInvoice.put(inv.Id, o.Account__c);
            List<INV_WarehouseStock_Service.StockLineItem> deducts =
                new List<INV_WarehouseStock_Service.StockLineItem>();
            Integer lineNo = 1;
            for (Primary_Order_Line__c l : linesByOrder.get(o.Id)) {
                Decimal baseQty = nz(l.Base_Quantity__c) > 0 ? l.Base_Quantity__c : nz(l.Quantity__c);
                Decimal gross = baseQty * nz(l.Unit_Price__c);
                Decimal disc = nz(l.Discount_Amount__c);
                Decimal taxable = gross - disc;
                invLines.add(new Invoice_Line__c(
                    Invoice__c         = inv.Id,
                    Product_Ext__c     = l.Product_Ext__c,
                    Line_Number__c     = lineNo++,
                    Quantity__c        = baseQty,
                    Unit_Price__c      = l.Unit_Price__c,
                    Discount_Amount__c = disc,
                    Line_Amount__c     = gross
                    // Tax_Rate/CGST/SGST/IGST/Tax_Amount/Net/Total set from DMS_Tax_Service below.
                ));
                // Tax input index-aligned with invLines (GST computed on taxable base).
                taxInputs.add(new DMS_Tax_Service.LineTaxInput(l.Product_Ext__c, taxable, fromState, toState));
                baseById.put(inv.Id, nz(baseById.get(inv.Id)) + taxable);
                deducts.add(new INV_WarehouseStock_Service.StockLineItem(l.Product_Ext__c, null, baseQty));
            }
            deductByOrder.put(o.Id, deducts);
        }

        // 2a. GST per line (CGST/SGST/IGST split), rolled up per invoice.
        Map<Id, Decimal> taxById = new Map<Id, Decimal>();
        List<DMS_Tax_Service.LineTax> taxes = DMS_Tax_Service.calculate(taxInputs);
        for (Integer i = 0; i < invLines.size(); i++) {
            Invoice_Line__c il = invLines[i];
            DMS_Tax_Service.LineTax t = taxes[i];
            Decimal taxable = nz(il.Line_Amount__c) - nz(il.Discount_Amount__c);
            il.Tax_Rate__c   = t.taxRate;
            il.CGST__c       = t.cgst;
            il.SGST__c       = t.sgst;
            il.IGST__c       = t.igst;
            il.Tax_Amount__c = t.totalTax;
            il.Net_Amount__c   = taxable + nz(t.totalTax);
            il.Total_Amount__c = taxable + nz(t.totalTax);
            taxById.put(il.Invoice__c, nz(taxById.get(il.Invoice__c)) + nz(t.totalTax));
        }
        if (!invLines.isEmpty()) { insert invLines; }

        // 2b. Header amounts = taxable base + GST (drives distributor outstanding).
        List<Invoice__c> amountUpdates = new List<Invoice__c>();
        for (Id invId : baseById.keySet()) {
            Decimal sub = nz(baseById.get(invId));
            Decimal tax = nz(taxById.get(invId));
            amountUpdates.add(new Invoice__c(
                Id = invId, Subtotal__c = sub, Tax_Amount__c = tax,
                Total_Amount__c = sub + tax, Balance_Due__c = sub + tax
            ));
        }
        if (!amountUpdates.isEmpty()) { update amountUpdates; }

        // 2c. Accrue distributor scheme payouts on the primary invoices (taxable base).
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(baseById, accountByInvoice);

        // 3. Deduct source-warehouse stock per order — never dispatch stock we don't hold.
        assertStockAvailable(fulfillable, deductByOrder);
        for (Primary_Order__c o : fulfillable) {
            Invoice__c inv = invoiceByOrder.get(o.Id);
            List<INV_WarehouseStock_Service.StockLineItem> items = deductByOrder.get(o.Id);
            if (inv == null || items == null || items.isEmpty()) { continue; }

            // Resolve the ordered quantity to SPECIFIC batches, earliest expiry first. The
            // order lines carry no batch (a distributor orders a product, not a batch), and
            // this previously passed batch = null straight through — so the warehouse had no
            // FEFO at all and dated stock could age out while later batches shipped.
            Map<Id, Decimal> required = new Map<Id, Decimal>();
            for (INV_WarehouseStock_Service.StockLineItem i : items) {
                required.put(i.productId, nz(required.get(i.productId)) + nz(i.quantity));
            }
            List<INV_WarehouseStock_Service.StockLineItem> fefoItems =
                INV_WarehouseStock_Service.allocateFefo(o.Warehouse__c, required);

            // deductStock, not adjustDeduct: books a real Outbound_Dispatch entry against the
            // invoice (adjustDeduct mislabelled it as a Stock_Adjustment) and releases any
            // reservation. This is the ONLY warehouse-stock write for a primary order —
            // OMS_Invoice_TriggerHandler deliberately skips primary invoices.
            INV_WarehouseStock_Service.deductStock(o.Warehouse__c, fefoItems, inv.Id, 'Invoice');
        }

        // 4. Link invoice + advance order to Dispatched.
        List<Primary_Order__c> orderUpdates = new List<Primary_Order__c>();
        for (Primary_Order__c o : fulfillable) {
            Invoice__c inv = invoiceByOrder.get(o.Id);
            if (inv == null) { continue; }
            orderUpdates.add(new Primary_Order__c(
                Id = o.Id, Invoice__c = inv.Id, Status__c = 'Dispatched'
            ));
        }
        if (!orderUpdates.isEmpty()) { update orderUpdates; }

        // 5. Refresh distributor outstanding/credit so the new primary invoices count.
        if (!distributorIds.isEmpty()) {
            MDM_Account_TriggerHandler.recalculateCreditUtilization(distributorIds);
        }
    }
}