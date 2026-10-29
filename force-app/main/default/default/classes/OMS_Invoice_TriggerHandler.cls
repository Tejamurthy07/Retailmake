/**
 * @description Trigger handler for Invoice__c. Manages invoice lifecycle events
 *              including status updates, payment tracking, account credit
 *              utilisation adjustments, and warehouse stock operations.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class OMS_Invoice_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    /**
     * @description Sets default values on new invoices.
     */
    protected override void beforeInsert() {
        List<Invoice__c> newRecords = (List<Invoice__c>) Trigger.new;
        for (Invoice__c inv : newRecords) {
            if (String.isBlank(inv.Status__c)) {
                inv.Status__c = 'Draft';
            }
            if (inv.Invoice_Date__c == null) {
                inv.Invoice_Date__c = Date.today();
            }
            if (inv.Balance_Due__c == null) {
                inv.Balance_Due__c = inv.Total_Amount__c;
            }
        }
    }

    // ── After Insert ──────────────────────────────────────────────────────────

    /**
     * @description Posts each new invoice to the distributor ledger as a debit
     *              (DMS ledger-posting toggle; inert otherwise). The amount is
     *              refreshed by afterUpdate once the header totals are rolled up.
     */
    protected override void afterInsert() {
        DMS_InvoiceLedger_Service.syncInvoiceEntries((List<Invoice__c>) Trigger.new);
    }

    // ── After Update ──────────────────────────────────────────────────────────

    /**
     * @description Handles invoice status changes. When confirmed, updates
     *              account credit utilisation and reserves warehouse stock.
     *              When dispatched, deducts warehouse stock. When cancelled,
     *              releases credit and stock reservations.
     */
    protected override void afterUpdate() {
        List<Invoice__c> newRecords = (List<Invoice__c>) Trigger.new;
        Map<Id, Invoice__c> oldMap = (Map<Id, Invoice__c>) Trigger.oldMap;

        Map<Id, Decimal> creditByAccount = new Map<Id, Decimal>();
        List<Invoice__c> confirmedInvoices = new List<Invoice__c>();
        List<Invoice__c> dispatchedInvoices = new List<Invoice__c>();
        List<Invoice__c> cancelledFromConfirmed = new List<Invoice__c>();

        for (Invoice__c inv : newRecords) {
            Invoice__c oldInv = oldMap.get(inv.Id);

            // When invoice is confirmed/finalized, add to credit utilization
            if (inv.Status__c == 'Confirmed' && oldInv.Status__c != 'Confirmed' &&
                inv.Account__c != null && inv.Total_Amount__c != null) {
                Decimal current = creditByAccount.containsKey(inv.Account__c)
                    ? creditByAccount.get(inv.Account__c) : 0;
                creditByAccount.put(inv.Account__c, current + inv.Total_Amount__c);

                // Reserve warehouse stock
                if (inv.Warehouse__c != null && !ownedByPrimaryFulfilment(inv)) {
                    confirmedInvoices.add(inv);
                }
            }

            // When invoice is dispatched, deduct warehouse stock
            if (inv.Status__c == 'Dispatched' && oldInv.Status__c != 'Dispatched' &&
                inv.Warehouse__c != null && !ownedByPrimaryFulfilment(inv)) {
                dispatchedInvoices.add(inv);
            }

            // When invoice is cancelled, release credit
            if (inv.Status__c == 'Cancelled' && oldInv.Status__c != 'Cancelled' &&
                inv.Account__c != null && inv.Total_Amount__c != null) {
                Decimal current = creditByAccount.containsKey(inv.Account__c)
                    ? creditByAccount.get(inv.Account__c) : 0;
                creditByAccount.put(inv.Account__c, current - inv.Total_Amount__c);

                // Release stock reservation if previously confirmed
                if (inv.Warehouse__c != null && oldInv.Status__c == 'Confirmed'
                        && !ownedByPrimaryFulfilment(inv)) {
                    cancelledFromConfirmed.add(inv);
                }
            }
        }

        if (!creditByAccount.isEmpty()) {
            updateAccountCredit(creditByAccount);
        }

        // Warehouse stock operations
        if (!confirmedInvoices.isEmpty()) {
            processWarehouseStock(confirmedInvoices, 'reserve');
        }
        if (!dispatchedInvoices.isEmpty()) {
            processWarehouseStock(dispatchedInvoices, 'deduct');
        }
        if (!cancelledFromConfirmed.isEmpty()) {
            processWarehouseStock(cancelledFromConfirmed, 'release');
        }

        // Refresh the ledger debit entry (amount/date/account change, or reverse
        // it on cancellation). DMS ledger-posting toggle; inert otherwise.
        DMS_InvoiceLedger_Service.syncInvoiceEntries(newRecords);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Updates account credit utilisation based on invoice changes.
     * @param creditByAccount Map of Account ID to credit adjustment amount.
     */
    private void updateAccountCredit(Map<Id, Decimal> creditByAccount) {
        List<Account> accounts = [
            SELECT Id, Credit_Utilized__c
            FROM Account
            WHERE Id IN :creditByAccount.keySet()
        ];

        for (Account acct : accounts) {
            Decimal adjustment = creditByAccount.get(acct.Id);
            Decimal currentUtilised = acct.Credit_Utilized__c != null
                ? acct.Credit_Utilized__c : 0;
            acct.Credit_Utilized__c = Math.max(0, currentUtilised + adjustment);
        }

        if (!accounts.isEmpty()) {
            update accounts;
        }
    }

    /**
     * @description A primary invoice's warehouse stock is moved exactly once, at order
     *              fulfilment (DMS_PrimaryOrderFulfillment_Service deducts from the source
     *              warehouse when the order is approved). Reserving on Confirmed and
     *              deducting again on Dispatched here would double-count the same movement
     *              and leak Qty_Reserved, so primary invoices are excluded: one movement,
     *              one writer.
     */
    private static Boolean ownedByPrimaryFulfilment(Invoice__c inv) {
        return inv.Order_Type__c == DMS_Constants.ORDER_TYPE_PRIMARY;
    }

    /**
     * @description Processes warehouse stock operations for invoice status changes.
     *              Reserves stock on confirmation, deducts on dispatch, releases on cancel.
     * @param invoices The invoices to process.
     * @param operation The operation type: 'reserve', 'deduct', or 'release'.
     */
    private void processWarehouseStock(List<Invoice__c> invoices, String operation) {
        Set<Id> invoiceIds = new Set<Id>();
        Map<Id, Invoice__c> invoiceMap = new Map<Id, Invoice__c>();
        for (Invoice__c inv : invoices) {
            invoiceIds.add(inv.Id);
            invoiceMap.put(inv.Id, inv);
        }

        // Query invoice line items
        List<Invoice_Line__c> allLines = [
            SELECT Id, Invoice__c, Product_Ext__c, Quantity__c, Batch_No__c
            FROM Invoice_Line__c
            WHERE Invoice__c IN :invoiceIds
        ];

        // Group lines by invoice
        Map<Id, List<Invoice_Line__c>> linesByInvoice = new Map<Id, List<Invoice_Line__c>>();
        for (Invoice_Line__c line : allLines) {
            if (!linesByInvoice.containsKey(line.Invoice__c)) {
                linesByInvoice.put(line.Invoice__c, new List<Invoice_Line__c>());
            }
            linesByInvoice.get(line.Invoice__c).add(line);
        }

        // Process each invoice
        for (Invoice__c inv : invoices) {
            List<Invoice_Line__c> lines = linesByInvoice.get(inv.Id);
            if (lines == null || lines.isEmpty()) {
                continue;
            }

            List<INV_WarehouseStock_Service.StockLineItem> stockItems =
                new List<INV_WarehouseStock_Service.StockLineItem>();
            for (Invoice_Line__c line : lines) {
                if (line.Product_Ext__c != null && line.Quantity__c != null && line.Quantity__c > 0) {
                    stockItems.add(new INV_WarehouseStock_Service.StockLineItem(
                        line.Product_Ext__c, line.Batch_No__c, line.Quantity__c
                    ));
                }
            }

            if (stockItems.isEmpty()) {
                continue;
            }

            if (operation == 'reserve') {
                INV_WarehouseStock_Service.reserveStock(inv.Warehouse__c, stockItems, inv.Id);
            } else if (operation == 'deduct') {
                INV_WarehouseStock_Service.deductStock(inv.Warehouse__c, stockItems, inv.Id, 'Invoice');
            } else if (operation == 'release') {
                INV_WarehouseStock_Service.releaseReservation(inv.Warehouse__c, stockItems, inv.Id);
            }
        }
    }
}