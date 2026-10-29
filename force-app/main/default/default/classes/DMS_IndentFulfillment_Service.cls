/**
 * @description DMS primary fulfillment. Converts approved Indents into primary
 *              dispatch Invoices, deducts source-warehouse stock, links the
 *              invoice back to the indent, and advances the indent to Dispatched.
 *              All behavior is gated by the DMS master + primary-fulfillment toggles.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_IndentFulfillment_Service {

    /**
     * @description Fulfills the given approved indents. Safe to call with a mix
     *              of ids; non-fulfillable indents (no source warehouse, already
     *              invoiced, no lines) are skipped.
     * @param indentIds Ids of indents that just became Approved.
     */
    public static void fulfillApprovedIndents(Set<Id> indentIds) {
        if (indentIds == null || indentIds.isEmpty()) {
            return;
        }
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_PRIMARY_FULFILLMENT)) {
            return;
        }
        // Deprecated path. Primary_Order__c is the canonical primary order; the
        // legacy Indent__c fulfilment is inert unless explicitly opted in, so an
        // approved Indent can never silently generate a second primary invoice.
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_LEGACY_INDENT_FULFILLMENT)) {
            return;
        }

        List<Indent__c> indents = [
            SELECT Id, Name, Account__c, Source_Warehouse__c, Territory__c,
                   Status__c, Invoice__c
            FROM Indent__c
            WHERE Id IN :indentIds
        ];

        // Only fulfill indents that have a source warehouse and no invoice yet.
        List<Indent__c> fulfillable = new List<Indent__c>();
        for (Indent__c ind : indents) {
            if (ind.Source_Warehouse__c != null && ind.Invoice__c == null) {
                fulfillable.add(ind);
            }
        }
        if (fulfillable.isEmpty()) {
            return;
        }

        Map<Id, List<Indent_Line__c>> linesByIndent = new Map<Id, List<Indent_Line__c>>();
        for (Indent_Line__c line : [
            SELECT Id, Indent__c, Product_Ext__c, Requested_Qty__c, Approved_Qty__c, Unit_Price__c
            FROM Indent_Line__c
            WHERE Indent__c IN :fulfillable
        ]) {
            if (!linesByIndent.containsKey(line.Indent__c)) {
                linesByIndent.put(line.Indent__c, new List<Indent_Line__c>());
            }
            linesByIndent.get(line.Indent__c).add(line);
        }

        // 1. Create primary invoices (one per fulfillable indent with lines).
        Map<Id, Invoice__c> invoiceByIndent = new Map<Id, Invoice__c>();
        List<Invoice__c> invoicesToInsert = new List<Invoice__c>();
        String stamp = String.valueOf(Datetime.now().getTime());
        Integer counter = 0;
        for (Indent__c ind : fulfillable) {
            List<Indent_Line__c> lines = linesByIndent.get(ind.Id);
            if (lines == null || lines.isEmpty()) {
                continue;
            }
            Invoice__c inv = new Invoice__c(
                Account__c       = ind.Account__c,
                Order_Type__c    = DMS_Constants.ORDER_TYPE_PRIMARY,
                Invoice_Date__c  = Date.today(),
                Dispatch_Date__c = Date.today(),
                Invoice_Number__c = DMS_Config.primaryPrefix() + stamp + '-' + String.valueOf(counter).leftPad(4, '0'),
                Status__c        = 'Draft',
                Warehouse__c     = ind.Source_Warehouse__c,
                Territory__c     = ind.Territory__c
            );
            invoicesToInsert.add(inv);
            invoiceByIndent.put(ind.Id, inv);
            counter++;
        }
        if (invoicesToInsert.isEmpty()) {
            return;
        }
        insert invoicesToInsert;

        // Pricing & tax reference data (price fallback + GST origin/destination states).
        Set<Id> productIds = new Set<Id>();
        Set<Id> warehouseIds = new Set<Id>();
        Set<Id> distributorIds = new Set<Id>();
        for (Indent__c ind : fulfillable) {
            if (ind.Source_Warehouse__c != null) { warehouseIds.add(ind.Source_Warehouse__c); }
            if (ind.Account__c != null) { distributorIds.add(ind.Account__c); }
            List<Indent_Line__c> ls = linesByIndent.get(ind.Id);
            if (ls != null) {
                for (Indent_Line__c l : ls) {
                    if (l.Product_Ext__c != null) { productIds.add(l.Product_Ext__c); }
                }
            }
        }
        // Price-list pricing per distributor (qty-aware); falls back to master inside the service.
        Map<Id, Map<Id, Decimal>> qtyByAcctProduct = new Map<Id, Map<Id, Decimal>>();
        for (Indent__c ind : fulfillable) {
            if (ind.Account__c == null) { continue; }
            if (!qtyByAcctProduct.containsKey(ind.Account__c)) {
                qtyByAcctProduct.put(ind.Account__c, new Map<Id, Decimal>());
            }
            Map<Id, Decimal> m = qtyByAcctProduct.get(ind.Account__c);
            List<Indent_Line__c> ls = linesByIndent.get(ind.Id);
            if (ls != null) {
                for (Indent_Line__c l : ls) {
                    if (l.Product_Ext__c == null) { continue; }
                    Decimal q = (l.Approved_Qty__c != null && l.Approved_Qty__c > 0)
                        ? l.Approved_Qty__c : (l.Requested_Qty__c != null ? l.Requested_Qty__c : 0);
                    Decimal prev = m.containsKey(l.Product_Ext__c) ? m.get(l.Product_Ext__c) : 0;
                    m.put(l.Product_Ext__c, prev + q);
                }
            }
        }
        Map<Id, Map<Id, Decimal>> priceByAcct = new Map<Id, Map<Id, Decimal>>();
        for (Id acc : qtyByAcctProduct.keySet()) {
            priceByAcct.put(acc, DMS_Pricing_Service.priceForLines(qtyByAcctProduct.get(acc), acc));
        }
        Map<Id, String> warehouseState = new Map<Id, String>();
        for (Warehouse__c w : [SELECT Id, State__c FROM Warehouse__c WHERE Id IN :warehouseIds]) {
            warehouseState.put(w.Id, w.State__c);
        }
        Map<Id, String> distState = new Map<Id, String>();
        for (Account a : [SELECT Id, BillingState FROM Account WHERE Id IN :distributorIds]) {
            distState.put(a.Id, a.BillingState);
        }

        // 2. Build invoice lines, deduction items, and tax inputs (price fallback applied).
        List<Invoice_Line__c> invoiceLines = new List<Invoice_Line__c>();
        List<DMS_Tax_Service.LineTaxInput> taxInputs = new List<DMS_Tax_Service.LineTaxInput>();
        Map<Id, List<INV_WarehouseStock_Service.StockLineItem>> deductByIndent =
            new Map<Id, List<INV_WarehouseStock_Service.StockLineItem>>();
        Map<Id, Decimal> invoiceBaseById = new Map<Id, Decimal>();

        for (Indent__c ind : fulfillable) {
            Invoice__c inv = invoiceByIndent.get(ind.Id);
            if (inv == null) {
                continue;
            }
            String fromState = ind.Source_Warehouse__c != null ? warehouseState.get(ind.Source_Warehouse__c) : null;
            String toState = ind.Account__c != null ? distState.get(ind.Account__c) : null;
            Map<Id, Decimal> productPrice = priceByAcct.containsKey(ind.Account__c)
                ? priceByAcct.get(ind.Account__c) : new Map<Id, Decimal>();
            List<INV_WarehouseStock_Service.StockLineItem> deductItems =
                new List<INV_WarehouseStock_Service.StockLineItem>();
            Integer lineNo = 1;
            for (Indent_Line__c line : linesByIndent.get(ind.Id)) {
                Decimal qty = line.Approved_Qty__c != null && line.Approved_Qty__c > 0
                    ? line.Approved_Qty__c
                    : (line.Requested_Qty__c != null ? line.Requested_Qty__c : 0);
                if (qty <= 0 || line.Product_Ext__c == null) {
                    continue;
                }
                // Price: indent line price, else fall back to product master price.
                Decimal price = (line.Unit_Price__c != null && line.Unit_Price__c > 0)
                    ? line.Unit_Price__c
                    : (productPrice.get(line.Product_Ext__c) != null ? productPrice.get(line.Product_Ext__c) : 0);
                Decimal baseAmt = qty * price;
                invoiceLines.add(new Invoice_Line__c(
                    Invoice__c     = inv.Id,
                    Product_Ext__c = line.Product_Ext__c,
                    Quantity__c    = qty,
                    Unit_Price__c  = price,
                    Line_Number__c = lineNo,
                    Total_Amount__c = baseAmt
                ));
                taxInputs.add(new DMS_Tax_Service.LineTaxInput(line.Product_Ext__c, baseAmt, fromState, toState));
                deductItems.add(new INV_WarehouseStock_Service.StockLineItem(
                    line.Product_Ext__c, null, qty
                ));
                invoiceBaseById.put(inv.Id,
                    (invoiceBaseById.containsKey(inv.Id) ? invoiceBaseById.get(inv.Id) : 0) + baseAmt);
                lineNo++;
            }
            deductByIndent.put(ind.Id, deductItems);
        }

        // 2a. GST per line (applied before insert), rolled up per invoice.
        Map<Id, Decimal> invoiceTaxById = new Map<Id, Decimal>();
        List<DMS_Tax_Service.LineTax> taxes = DMS_Tax_Service.calculate(taxInputs);
        for (Integer i = 0; i < invoiceLines.size(); i++) {
            Invoice_Line__c il = invoiceLines[i];
            DMS_Tax_Service.LineTax t = taxes[i];
            il.Tax_Rate__c = t.taxRate;
            il.CGST__c = t.cgst;
            il.SGST__c = t.sgst;
            il.IGST__c = t.igst;
            il.Tax_Amount__c = t.totalTax;
            invoiceTaxById.put(il.Invoice__c,
                (invoiceTaxById.containsKey(il.Invoice__c) ? invoiceTaxById.get(il.Invoice__c) : 0) + t.totalTax);
        }
        if (!invoiceLines.isEmpty()) {
            insert invoiceLines;
        }

        // 2b. Header amounts = base + GST (drives the distributor's outstanding).
        List<Invoice__c> invoiceAmountUpdates = new List<Invoice__c>();
        for (Id invId : invoiceBaseById.keySet()) {
            Decimal base = invoiceBaseById.get(invId);
            Decimal tax = invoiceTaxById.containsKey(invId) ? invoiceTaxById.get(invId) : 0;
            Decimal total = base + tax;
            invoiceAmountUpdates.add(new Invoice__c(
                Id = invId,
                Subtotal__c = base,
                Tax_Amount__c = tax,
                Total_Amount__c = total,
                Balance_Due__c = total
            ));
        }
        if (!invoiceAmountUpdates.isEmpty()) {
            update invoiceAmountUpdates;
        }

        // 2c. Accrue distributor scheme payouts on the primary invoices (on taxable base).
        Map<Id, Id> accountByInvoice = new Map<Id, Id>();
        for (Indent__c ind : fulfillable) {
            Invoice__c inv = invoiceByIndent.get(ind.Id);
            if (inv != null && invoiceBaseById.containsKey(inv.Id)) {
                accountByInvoice.put(inv.Id, ind.Account__c);
            }
        }
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(invoiceBaseById, accountByInvoice);

        // 3. Deduct source-warehouse stock per indent.
        for (Indent__c ind : fulfillable) {
            List<INV_WarehouseStock_Service.StockLineItem> items = deductByIndent.get(ind.Id);
            Invoice__c inv = invoiceByIndent.get(ind.Id);
            if (items != null && !items.isEmpty() && inv != null) {
                INV_WarehouseStock_Service.adjustDeduct(ind.Source_Warehouse__c, items, inv.Id);
            }
        }

        // 4. Link invoice + advance indent to Dispatched (bypass own trigger).
        List<Indent__c> indentUpdates = new List<Indent__c>();
        for (Indent__c ind : fulfillable) {
            Invoice__c inv = invoiceByIndent.get(ind.Id);
            if (inv == null) {
                continue;
            }
            indentUpdates.add(new Indent__c(
                Id = ind.Id,
                Invoice__c = inv.Id,
                Status__c = DMS_Constants.INDENT_DISPATCHED
            ));
        }
        if (!indentUpdates.isEmpty()) {
            TriggerHandler.bypass('DMS_Indent_TriggerHandler');
            try {
                update indentUpdates;
            } finally {
                TriggerHandler.clearBypass('DMS_Indent_TriggerHandler');
            }
        }

        // 5. Refresh distributor outstanding/credit so the new primary invoices count.
        //    (distributorIds was already collected above for tax-state resolution.)
        if (!distributorIds.isEmpty()) {
            MDM_Account_TriggerHandler.recalculateCreditUtilization(distributorIds);
        }
    }
}