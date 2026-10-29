/**
 * @description Posts each invoice to the distributor ledger as a DEBIT
 *              Ledger_Entry__c (Entry_Type 'Invoice'), so Ledger_Entry__c becomes
 *              a complete, single source of truth for the statement of account —
 *              payments, collections and credit notes already post their own
 *              credit entries, but invoices (the debits that create the
 *              receivable) were never posted.
 *
 *              Idempotent: exactly one 'Invoice' entry per invoice, keyed by the
 *              Invoice__c lookup. Refreshes the amount / date / account when the
 *              invoice changes, and removes the entry when the invoice is
 *              cancelled (or loses its account). Gated by the DMS master + ledger
 *              toggles, so it stays inert unless DMS ledger posting is enabled.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_InvoiceLedger_Service {

    private static Boolean enabled() {
        return BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER)
            && BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_INVOICE_LEDGER);
    }

    /**
     * Trigger entry point — creates / refreshes / reverses the ledger debit entry
     * for each invoice. Safe to call from after-insert and after-update; bulk-safe.
     * No-op unless DMS ledger posting is enabled.
     */
    public static void syncInvoiceEntries(List<Invoice__c> invoices) {
        if (!enabled()) { return; }
        sync(invoices);
    }

    /**
     * Toggle-independent worker (also used by the one-time backfill script).
     * Posts one debit entry per non-cancelled invoice, keyed by the Invoice__c
     * lookup so re-running is idempotent.
     */
    public static void sync(List<Invoice__c> invoices) {
        if (invoices == null || invoices.isEmpty()) { return; }

        Set<Id> invIds = new Set<Id>();
        for (Invoice__c inv : invoices) {
            if (inv.Id != null) { invIds.add(inv.Id); }
        }
        if (invIds.isEmpty()) { return; }

        Map<Id, Ledger_Entry__c> existingByInv = new Map<Id, Ledger_Entry__c>();
        for (Ledger_Entry__c e : [
            SELECT Id, Invoice__c, Account__c, Amount__c, Debit_Amount__c, Entry_Date__c
            FROM Ledger_Entry__c
            WHERE Entry_Type__c = 'Invoice' AND Invoice__c IN :invIds
        ]) {
            existingByInv.put(e.Invoice__c, e);
        }

        List<Ledger_Entry__c> toInsert = new List<Ledger_Entry__c>();
        List<Ledger_Entry__c> toUpdate = new List<Ledger_Entry__c>();
        List<Ledger_Entry__c> toDelete = new List<Ledger_Entry__c>();

        for (Invoice__c inv : invoices) {
            if (inv.Id == null) { continue; }
            Ledger_Entry__c existing = existingByInv.get(inv.Id);

            // A cancelled invoice (or one without an account) is no receivable —
            // remove any entry that was posted for it.
            if (inv.Status__c == 'Cancelled' || inv.Account__c == null) {
                if (existing != null) { toDelete.add(existing); }
                continue;
            }

            Decimal amt = inv.Total_Amount__c != null ? inv.Total_Amount__c : 0;
            Date entryDate = inv.Invoice_Date__c != null ? inv.Invoice_Date__c : Date.today();

            if (existing == null) {
                toInsert.add(new Ledger_Entry__c(
                    Account__c          = inv.Account__c,
                    Entry_Type__c       = 'Invoice',
                    Entry_Date__c       = entryDate,
                    Amount__c           = amt,
                    Debit_Amount__c     = amt,
                    Invoice__c          = inv.Id,
                    Reference_Type__c   = 'Invoice',
                    Reference_Id__c     = inv.Id,
                    Reference_Number__c = inv.Invoice_Number__c,
                    Description__c      = (String.isNotBlank(inv.Order_Type__c)
                                            ? inv.Order_Type__c + ' ' : '') + 'invoice',
                    Status__c           = 'Posted'
                ));
            } else if (existing.Account__c != inv.Account__c
                       || existing.Amount__c != amt
                       || existing.Debit_Amount__c != amt
                       || existing.Entry_Date__c != entryDate) {
                existing.Account__c      = inv.Account__c;
                existing.Amount__c       = amt;
                existing.Debit_Amount__c = amt;
                existing.Entry_Date__c   = entryDate;
                toUpdate.add(existing);
            }
        }

        if (!toInsert.isEmpty()) { insert toInsert; }
        if (!toUpdate.isEmpty()) { update toUpdate; }
        if (!toDelete.isEmpty()) { delete toDelete; }

        // Keep the running balance coherent after invoice debits change.
        Set<Id> accountIds = new Set<Id>();
        for (Invoice__c inv : invoices) {
            if (inv.Account__c != null) { accountIds.add(inv.Account__c); }
        }
        DMS_Ledger_Service.recalculateRunningBalance(accountIds);
    }
}