/**
 * @description Trigger handler for Return_Order__c. Validates return quantities
 *              against original invoiced quantities and generates credit notes
 *              (Ledger_Entry__c) upon approval.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class OMS_ReturnOrder_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    /**
     * @description Validates that the return quantity does not exceed the
     *              original invoiced quantity for each referenced invoice line.
     */
    protected override void beforeInsert() {
        List<Return_Order__c> newRecords = (List<Return_Order__c>) Trigger.new;
        validateReturnQuantity(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    /**
     * @description Re-validates return quantity when quantities or invoice
     *              references change.
     */
    protected override void beforeUpdate() {
        List<Return_Order__c> newRecords = (List<Return_Order__c>) Trigger.new;
        Map<Id, Return_Order__c> oldMap = (Map<Id, Return_Order__c>) Trigger.oldMap;

        List<Return_Order__c> changed = new List<Return_Order__c>();
        Long stamp = Datetime.now().getTime();
        Integer seq = 0;
        for (Return_Order__c rec : newRecords) {
            Return_Order__c oldRec = oldMap.get(rec.Id);
            if (rec.Return_Quantity__c != oldRec.Return_Quantity__c ||
                rec.Invoice__c != oldRec.Invoice__c ||
                rec.Invoice_Line__c != oldRec.Invoice_Line__c) {
                changed.add(rec);
            }
            // On approval, stamp a credit-note number + approval date (the credit-note
            // ledger entry generated in afterUpdate references this number).
            if (rec.Status__c == 'Approved' && oldRec.Status__c != 'Approved') {
                if (String.isBlank(rec.Credit_Note_Number__c)) {
                    rec.Credit_Note_Number__c = 'CRN-' + String.valueOf(stamp + seq);
                    seq++;
                }
                if (rec.Approval_Date__c == null) {
                    rec.Approval_Date__c = Date.today();
                }
            }
        }

        if (!changed.isEmpty()) {
            validateReturnQuantity(changed);
        }
    }

    // ── After Update ──────────────────────────────────────────────────────────

    /**
     * @description When a return order is approved, generates a credit note
     *              ledger entry and updates the related invoice balance.
     */
    protected override void afterUpdate() {
        List<Return_Order__c> newRecords = (List<Return_Order__c>) Trigger.new;
        Map<Id, Return_Order__c> oldMap = (Map<Id, Return_Order__c>) Trigger.oldMap;

        List<Return_Order__c> approved = new List<Return_Order__c>();
        for (Return_Order__c rec : newRecords) {
            Return_Order__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c == 'Approved' && oldRec.Status__c != 'Approved') {
                approved.add(rec);
            }
        }

        if (!approved.isEmpty()) {
            generateCreditNotes(approved);
            // Secondary returns go back into distributor inventory (handled by
            // DMS_ReturnOrder_TriggerHandler), not the company warehouse.
            List<Return_Order__c> warehouseReturns = new List<Return_Order__c>();
            for (Return_Order__c ret : approved) {
                if (ret.Return_Type__c != DMS_Constants.RETURN_TYPE_SECONDARY) {
                    warehouseReturns.add(ret);
                }
            }
            returnStockToWarehouse(warehouseReturns);
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Validates that the return quantity does not exceed the
     *              available (invoiced minus already-returned) quantity.
     * @param records The Return_Order__c records to validate.
     */
    private void validateReturnQuantity(List<Return_Order__c> records) {
        // Collect invoice line IDs
        Set<Id> invoiceLineIds = new Set<Id>();
        Set<Id> invoiceIds = new Set<Id>();
        for (Return_Order__c rec : records) {
            if (rec.Invoice_Line__c != null) {
                invoiceLineIds.add(rec.Invoice_Line__c);
            }
            if (rec.Invoice__c != null) {
                invoiceIds.add(rec.Invoice__c);
            }
        }

        // Get invoiced quantities from invoice lines
        Map<Id, Invoice_Line__c> invoiceLineMap = new Map<Id, Invoice_Line__c>();
        if (!invoiceLineIds.isEmpty()) {
            invoiceLineMap = new Map<Id, Invoice_Line__c>([
                SELECT Id, Quantity__c, Product_Ext__c
                FROM Invoice_Line__c
                WHERE Id IN :invoiceLineIds
            ]);
        }

        // Get already-returned quantities (excluding current records on update)
        Map<Id, Decimal> alreadyReturnedByLine = new Map<Id, Decimal>();
        Set<Id> currentRecordIds = new Set<Id>();
        for (Return_Order__c rec : records) {
            if (rec.Id != null) {
                currentRecordIds.add(rec.Id);
            }
        }

        if (!invoiceLineIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Invoice_Line__c lineId, SUM(Return_Quantity__c) totalReturned
                FROM Return_Order__c
                WHERE Invoice_Line__c IN :invoiceLineIds
                  AND Status__c NOT IN ('Rejected', 'Cancelled')
                  AND Id NOT IN :currentRecordIds
                GROUP BY Invoice_Line__c
            ]) {
                Id lineId = (Id) ar.get('lineId');
                Decimal totalReturned = (Decimal) ar.get('totalReturned');
                alreadyReturnedByLine.put(lineId, totalReturned != null ? totalReturned : 0);
            }
        }

        // Validate each return order
        for (Return_Order__c rec : records) {
            if (rec.Return_Quantity__c == null || rec.Return_Quantity__c <= 0) {
                rec.Return_Quantity__c.addError('Return quantity must be greater than zero.');
                continue;
            }

            if (rec.Invoice_Line__c == null) {
                continue;
            }

            Invoice_Line__c invoiceLine = invoiceLineMap.get(rec.Invoice_Line__c);
            if (invoiceLine == null) {
                rec.Invoice_Line__c.addError('Referenced invoice line not found.');
                continue;
            }

            Decimal invoicedQty = invoiceLine.Quantity__c != null ? invoiceLine.Quantity__c : 0;
            Decimal alreadyReturned = alreadyReturnedByLine.containsKey(rec.Invoice_Line__c)
                ? alreadyReturnedByLine.get(rec.Invoice_Line__c) : 0;
            Decimal availableForReturn = invoicedQty - alreadyReturned;

            if (rec.Return_Quantity__c > availableForReturn) {
                rec.Return_Quantity__c.addError(
                    'Return quantity (' + rec.Return_Quantity__c +
                    ') exceeds available returnable quantity (' +
                    availableForReturn + '). Invoiced: ' + invoicedQty +
                    ', Already returned: ' + alreadyReturned + '.'
                );
            }
        }
    }

    /**
     * @description Generates credit note ledger entries for approved return orders
     *              and updates the related invoice balance.
     * @param approvedReturns The approved Return_Order__c records.
     */
    private void generateCreditNotes(List<Return_Order__c> approvedReturns) {
        List<Ledger_Entry__c> ledgerEntries = new List<Ledger_Entry__c>();
        Map<Id, Decimal> creditByInvoice = new Map<Id, Decimal>();
        Set<Id> accountIds = new Set<Id>();

        for (Return_Order__c ret : approvedReturns) {
            Decimal creditAmount = ret.Return_Amount__c != null ? ret.Return_Amount__c : 0;

            // Create credit note ledger entry. Unified convention: a credit note is a
            // CREDIT (reduces AR), carrying both Amount__c and Credit/Debit amounts.
            ledgerEntries.add(new Ledger_Entry__c(
                Account__c          = ret.Account__c,
                Entry_Type__c       = 'Credit Note',
                Amount__c           = creditAmount,
                Credit_Amount__c    = creditAmount,
                Debit_Amount__c     = 0,
                Reference_Type__c   = 'Return Order',
                Reference_Id__c     = ret.Id,
                Reference_Number__c = ret.Credit_Note_Number__c,
                Invoice__c          = ret.Invoice__c,
                Entry_Date__c       = Date.today(),
                Description__c      = 'Credit note for return order: ' + ret.Name,
                Status__c           = 'Posted'
            ));
            if (ret.Account__c != null) {
                accountIds.add(ret.Account__c);
            }

            // Track credit amounts by invoice for balance update
            if (ret.Invoice__c != null) {
                Decimal current = creditByInvoice.containsKey(ret.Invoice__c)
                    ? creditByInvoice.get(ret.Invoice__c) : 0;
                creditByInvoice.put(ret.Invoice__c, current + creditAmount);
            }
        }

        if (!ledgerEntries.isEmpty()) {
            insert ledgerEntries;
            DMS_Ledger_Service.recalculateRunningBalance(accountIds);
        }

        // Update invoice balances
        if (!creditByInvoice.isEmpty()) {
            List<Invoice__c> invoicesToUpdate = [
                SELECT Id, Balance_Due__c
                FROM Invoice__c
                WHERE Id IN :creditByInvoice.keySet()
            ];

            for (Invoice__c inv : invoicesToUpdate) {
                Decimal credit = creditByInvoice.get(inv.Id);
                Decimal currentBalance = inv.Balance_Due__c != null ? inv.Balance_Due__c : 0;
                inv.Balance_Due__c = Math.max(0, currentBalance - credit);
            }

            if (!invoicesToUpdate.isEmpty()) {
                update invoicesToUpdate;
            }
        }
    }

    /**
     * @description Returns stock to the warehouse when return orders are approved.
     *              Looks up the Invoice's Warehouse and adds stock back via the
     *              INV_WarehouseStock_Service.
     * @param approvedReturns The approved Return_Order__c records.
     */
    private void returnStockToWarehouse(List<Return_Order__c> approvedReturns) {
        // Collect invoice IDs and invoice line IDs
        Set<Id> invoiceIds = new Set<Id>();
        Set<Id> invoiceLineIds = new Set<Id>();
        for (Return_Order__c ret : approvedReturns) {
            if (ret.Invoice__c != null) {
                invoiceIds.add(ret.Invoice__c);
            }
            if (ret.Invoice_Line__c != null) {
                invoiceLineIds.add(ret.Invoice_Line__c);
            }
        }

        if (invoiceIds.isEmpty()) {
            return;
        }

        // Query invoices to get warehouse assignments
        Map<Id, Invoice__c> invoiceMap = new Map<Id, Invoice__c>([
            SELECT Id, Warehouse__c
            FROM Invoice__c
            WHERE Id IN :invoiceIds
              AND Warehouse__c != null
        ]);

        if (invoiceMap.isEmpty()) {
            return;
        }

        // Query invoice lines to get product references
        Map<Id, Invoice_Line__c> invoiceLineMap = new Map<Id, Invoice_Line__c>();
        if (!invoiceLineIds.isEmpty()) {
            invoiceLineMap = new Map<Id, Invoice_Line__c>([
                SELECT Id, Product_Ext__c
                FROM Invoice_Line__c
                WHERE Id IN :invoiceLineIds
                  AND Product_Ext__c != null
            ]);
        }

        // Group return items by warehouse
        Map<Id, List<INV_WarehouseStock_Service.StockLineItem>> itemsByWarehouse =
            new Map<Id, List<INV_WarehouseStock_Service.StockLineItem>>();
        Map<Id, String> referenceByWarehouse = new Map<Id, String>();

        for (Return_Order__c ret : approvedReturns) {
            if (ret.Invoice__c == null || ret.Return_Quantity__c == null || ret.Return_Quantity__c <= 0) {
                continue;
            }

            Invoice__c inv = invoiceMap.get(ret.Invoice__c);
            if (inv == null || inv.Warehouse__c == null) {
                continue;
            }

            // Get product from the related invoice line
            if (ret.Invoice_Line__c == null) {
                continue;
            }
            Invoice_Line__c line = invoiceLineMap.get(ret.Invoice_Line__c);
            if (line == null || line.Product_Ext__c == null) {
                continue;
            }
            Id productId = line.Product_Ext__c;

            Id warehouseId = inv.Warehouse__c;
            if (!itemsByWarehouse.containsKey(warehouseId)) {
                itemsByWarehouse.put(warehouseId, new List<INV_WarehouseStock_Service.StockLineItem>());
            }

            itemsByWarehouse.get(warehouseId).add(
                new INV_WarehouseStock_Service.StockLineItem(productId, null, ret.Return_Quantity__c)
            );
            referenceByWarehouse.put(warehouseId, ret.Id);
        }

        // Add stock back to each warehouse
        for (Id warehouseId : itemsByWarehouse.keySet()) {
            INV_WarehouseStock_Service.addStock(
                warehouseId,
                itemsByWarehouse.get(warehouseId),
                referenceByWarehouse.get(warehouseId),
                'Return_Order'
            );
        }
    }
}