/**
 * @description Tests for DMS_InvoiceLedger_Service — posting invoices to the
 *              distributor ledger as debit entries (Option A), gated by the
 *              opt-in DMS-013 toggle, and the getLedgerStatement dedup that keeps
 *              posted invoices from being counted twice.
 */
@isTest
private class DMS_InvoiceLedger_Test {

    private static void enablePosting() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_INVOICE_LEDGER, true);
    }

    private static Invoice__c newInvoice(Id acctId, Decimal total, String num) {
        return new Invoice__c(
            Account__c = acctId,
            Invoice_Number__c = num,
            Invoice_Date__c = Date.today(),
            Status__c = 'Draft',
            Order_Type__c = 'Primary',
            Total_Amount__c = total,
            Balance_Due__c = total
        );
    }

    private static Integer invoiceEntryCount(Id invId) {
        return [SELECT COUNT() FROM Ledger_Entry__c
                WHERE Invoice__c = :invId AND Entry_Type__c = 'Invoice'];
    }

    @isTest
    static void postsDebitOnInsert() {
        Account dist = TestDataFactory.createAndInsertAccount('IL Dist A', 'Distributor');
        enablePosting();
        Test.startTest();
        Invoice__c inv = newInvoice(dist.Id, 1000, 'INV-IL-A');
        insert inv;
        Test.stopTest();

        List<Ledger_Entry__c> entries = [
            SELECT Debit_Amount__c, Amount__c, Account__c
            FROM Ledger_Entry__c WHERE Invoice__c = :inv.Id AND Entry_Type__c = 'Invoice'
        ];
        System.assertEquals(1, entries.size(), 'One invoice debit entry posted');
        System.assertEquals(1000, entries[0].Debit_Amount__c, 'Debit = invoice total');
        System.assertEquals(dist.Id, entries[0].Account__c, 'Scoped to the invoice account');
    }

    @isTest
    static void refreshesOnUpdateAndStaysIdempotent() {
        Account dist = TestDataFactory.createAndInsertAccount('IL Dist B', 'Distributor');
        enablePosting();
        Invoice__c inv = newInvoice(dist.Id, 1000, 'INV-IL-B');
        insert inv;

        Test.startTest();
        inv.Total_Amount__c = 1500;
        update inv;
        Test.stopTest();

        List<Ledger_Entry__c> entries = [
            SELECT Debit_Amount__c FROM Ledger_Entry__c
            WHERE Invoice__c = :inv.Id AND Entry_Type__c = 'Invoice'
        ];
        System.assertEquals(1, entries.size(), 'Still exactly one entry (idempotent)');
        System.assertEquals(1500, entries[0].Debit_Amount__c, 'Amount refreshed to the new total');
    }

    @isTest
    static void reversesOnCancel() {
        Account dist = TestDataFactory.createAndInsertAccount('IL Dist C', 'Distributor');
        enablePosting();
        Invoice__c inv = newInvoice(dist.Id, 1000, 'INV-IL-C');
        insert inv;
        System.assertEquals(1, invoiceEntryCount(inv.Id), 'Entry exists after insert');

        Test.startTest();
        inv.Status__c = 'Cancelled';
        update inv;
        Test.stopTest();

        System.assertEquals(0, invoiceEntryCount(inv.Id), 'Entry removed on cancel');
    }

    @isTest
    static void inertWhenToggleOff() {
        Account dist = TestDataFactory.createAndInsertAccount('IL Dist D', 'Distributor');
        // Master on, invoice-ledger posting off → inert.
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_INVOICE_LEDGER, false);
        Test.startTest();
        Invoice__c inv = newInvoice(dist.Id, 1000, 'INV-IL-D');
        insert inv;
        Test.stopTest();
        System.assertEquals(0, invoiceEntryCount(inv.Id),
            'No invoice ledger entry when posting is disabled');
    }

    @isTest
    static void statementCountsPostedInvoiceOnce() {
        Account dist = TestDataFactory.createAndInsertAccount('IL Dist E', 'Distributor');
        enablePosting();
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_PORTAL, true);
        Invoice__c inv = newInvoice(dist.Id, 1000, 'INV-IL-E');
        insert inv; // auto-posts an 'Invoice' debit entry

        DMS_PortalController.testAccountIdOverride = dist.Id;
        Test.startTest();
        DMS_PortalController.LedgerStatement st = DMS_PortalController.getLedgerStatement(
            Date.today().addDays(-5), Date.today().addDays(5));
        Test.stopTest();

        // Counted once (via the ledger entry), not twice (ledger + direct read).
        System.assertEquals(1000, st.totalDebit, 'Invoice debit counted exactly once');
        System.assertEquals(1000, st.closingBalance, 'Closing = 1000 Dr');
        System.assertEquals(1, st.rows.size(), 'Single debit row, no duplicate');
    }

    @isTest
    static void backfillPostsMissingEntries() {
        Account dist = TestDataFactory.createAndInsertAccount('IL Dist F', 'Distributor');
        // Insert with posting OFF, so no entry is created up front.
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_INVOICE_LEDGER, false);
        Invoice__c inv = newInvoice(dist.Id, 800, 'INV-IL-F');
        insert inv;
        System.assertEquals(0, invoiceEntryCount(inv.Id), 'No entry before backfill');

        Test.startTest();
        // The backfill worker is toggle-independent.
        DMS_InvoiceLedger_Service.sync(new List<Invoice__c>{ [
            SELECT Id, Account__c, Total_Amount__c, Invoice_Date__c, Invoice_Number__c,
                   Order_Type__c, Status__c
            FROM Invoice__c WHERE Id = :inv.Id
        ] });
        Test.stopTest();

        System.assertEquals(1, invoiceEntryCount(inv.Id), 'Backfill posts the missing entry');
    }
}