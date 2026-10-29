/**
 * @description Test class for OVE_Collection_TriggerHandler.
 *              Validates collection processing including ledger entry creation,
 *              invoice balance updates, bounced payment reversals, and confirmed
 *              collection handling.
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class OVE_Collection_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        // Create territory and beat
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Collection Territory', 'TER-C01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Collection Beat', 'BEAT-C01', territory.Id);

        // Create accounts
        Account retailer = TestDataFactory.createAccount('Collection Retailer', 'Retailer');
        retailer.Credit_Limit__c = 100000;
        retailer.Credit_Utilized__c = 20000;
        insert retailer;

        // Create day attendance
        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        // Create visit
        Visit__c visit = TestDataFactory.createVisit(retailer.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        // Create sales orders
        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        Sales_Order__c order1 = TestDataFactory.createSalesOrder(retailer.Id, UserInfo.getUserId(), visit.Id);
        order1.Total_Amount__c = 50000;
        order1.Territory__c = territory.Id; // required once beyond Draft (Territory_Required_On_Submit)
        order1.Status__c = 'Approved';

        Sales_Order__c order2 = TestDataFactory.createSalesOrder(retailer.Id, UserInfo.getUserId(), visit.Id);
        order2.Total_Amount__c = 30000;
        order2.Territory__c = territory.Id;
        order2.Status__c = 'Approved';
        order2.Order_Date__c = Date.today().addDays(-1);

        insert new List<Sales_Order__c>{ order1, order2 };
        TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');

        // Create invoices directly (bypass trigger for clean setup)
        TriggerHandler.bypass('OMS_Invoice_TriggerHandler');
        Invoice__c inv1 = new Invoice__c(
            Sales_Order__c = order1.Id,
            Account__c = retailer.Id,
            Invoice_Date__c = Date.today().addDays(-15),
            Due_Date__c = Date.today().addDays(15),
            Invoice_Number__c = 'INV-TEST-0001',
            Status__c = 'Confirmed',
            Total_Amount__c = 50000,
            Subtotal__c = 42373,
            Tax_Amount__c = 7627,
            Balance_Due__c = 50000
        );

        Invoice__c inv2 = new Invoice__c(
            Sales_Order__c = order2.Id,
            Account__c = retailer.Id,
            Invoice_Date__c = Date.today().addDays(-30),
            Due_Date__c = Date.today(),
            Invoice_Number__c = 'INV-TEST-0002',
            Status__c = 'Confirmed',
            Total_Amount__c = 30000,
            Subtotal__c = 25424,
            Tax_Amount__c = 4576,
            Balance_Due__c = 30000
        );

        insert new List<Invoice__c>{ inv1, inv2 };
        TriggerHandler.clearBypass('OMS_Invoice_TriggerHandler');
    }

    // ── afterInsert Tests ──────────────────────────────────────────────────

    @IsTest
    static void testAfterInsert_createsLedgerEntryAndUpdatesBalance() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c, Total_Amount__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0001'
            LIMIT 1
        ];

        Decimal originalBalance = invoice.Balance_Due__c;
        Decimal paymentAmount = 15000;

        Test.startTest();
        Collection__c collection = TestDataFactory.createCollection(acct.Id, invoice.Id, paymentAmount);
        collection.Status__c = 'Collected';
        collection.Payment_Mode__c = 'Cash';
        insert collection;
        Test.stopTest();

        // Verify ledger entry was created
        List<Ledger_Entry__c> ledgerEntries = [
            SELECT Id, Entry_Type__c, Amount__c, Reference_Type__c, Reference_Id__c,
                   Invoice__c, Account__c, Status__c, Description__c
            FROM Ledger_Entry__c
            WHERE Reference_Id__c = :collection.Id
              AND Reference_Type__c = 'Collection'
        ];

        System.assertEquals(1, ledgerEntries.size(), 'One ledger entry should be created');
        System.assertEquals('Payment', ledgerEntries[0].Entry_Type__c, 'Entry type should be Payment');
        System.assertEquals(paymentAmount, ledgerEntries[0].Amount__c, 'Ledger amount should match collection');
        System.assertEquals(acct.Id, ledgerEntries[0].Account__c, 'Ledger account should match');
        System.assertEquals(invoice.Id, ledgerEntries[0].Invoice__c, 'Ledger invoice should match');

        // Verify invoice balance was reduced
        Invoice__c updatedInvoice = [
            SELECT Id, Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assertEquals(originalBalance - paymentAmount, updatedInvoice.Balance_Due__c,
            'Invoice balance should be reduced by payment amount');
    }

    @IsTest
    static void testAfterInsert_multipleCollections() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0002'
            LIMIT 1
        ];

        Decimal originalBalance = invoice.Balance_Due__c;

        Test.startTest();
        List<Collection__c> collections = new List<Collection__c>();

        Collection__c coll1 = TestDataFactory.createCollection(acct.Id, invoice.Id, 10000);
        coll1.Payment_Mode__c = 'Cash';
        collections.add(coll1);

        Collection__c coll2 = TestDataFactory.createCollection(acct.Id, invoice.Id, 5000);
        coll2.Payment_Mode__c = 'Cheque';
        collections.add(coll2);

        insert collections;
        Test.stopTest();

        // Verify two ledger entries were created
        Integer ledgerCount = [
            SELECT COUNT() FROM Ledger_Entry__c
            WHERE Reference_Type__c = 'Collection'
              AND Invoice__c = :invoice.Id
        ];
        System.assertEquals(2, ledgerCount, 'Two ledger entries should be created');

        // Verify balance was reduced by total of both collections
        Invoice__c updatedInvoice = [
            SELECT Id, Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assertEquals(originalBalance - 15000, updatedInvoice.Balance_Due__c,
            'Balance should be reduced by sum of both payments');
    }

    @IsTest
    static void testAfterInsert_zeroAmountCollection() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0001'
            LIMIT 1
        ];
        Decimal originalBalance = invoice.Balance_Due__c;

        Test.startTest();
        Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, 0);
        insert coll;
        Test.stopTest();

        // Zero amount should not create a ledger entry
        Integer ledgerCount = [
            SELECT COUNT() FROM Ledger_Entry__c
            WHERE Reference_Id__c = :coll.Id AND Reference_Type__c = 'Collection'
        ];
        System.assertEquals(0, ledgerCount, 'Zero amount should not create a ledger entry');

        // Balance should remain unchanged
        Invoice__c updatedInvoice = [
            SELECT Id, Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assertEquals(originalBalance, updatedInvoice.Balance_Due__c,
            'Balance should not change for zero amount collection');
    }

    @IsTest
    static void testAfterInsert_cashCollectionPostsImmediately() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id FROM Invoice__c WHERE Invoice_Number__c = 'INV-TEST-0001' LIMIT 1
        ];

        Test.startTest();
        Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, 5000);
        coll.Payment_Mode__c = 'Cash';
        coll.Status__c = 'Collected';
        insert coll;
        Test.stopTest();

        // A cash collection is realised immediately -> Posted ledger entry.
        Ledger_Entry__c entry = [
            SELECT Status__c FROM Ledger_Entry__c
            WHERE Reference_Id__c = :coll.Id AND Reference_Type__c = 'Collection'
            LIMIT 1
        ];
        System.assertEquals('Posted', entry.Status__c,
            'Cash collection should create a Posted ledger entry');
    }

    // ── afterUpdate - Bounced Collections Tests ────────────────────────────

    @IsTest
    static void testAfterUpdate_bouncedCollection() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c, Total_Amount__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0001'
            LIMIT 1
        ];

        Decimal paymentAmount = 20000;

        // Create and insert collection first
        Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, paymentAmount);
        coll.Payment_Mode__c = 'Cheque';
        coll.Status__c = 'Collected';
        insert coll;

        // Get balance after payment
        Invoice__c invoiceAfterPayment = [
            SELECT Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        Decimal balanceAfterPayment = invoiceAfterPayment.Balance_Due__c;

        Test.startTest();
        // Bounce the collection
        coll.Status__c = 'Bounced';
        update coll;
        Test.stopTest();

        // Verify reversal ledger entry was created (a bounce posts an 'Adjustment'
        // debit that restores the receivable).
        List<Ledger_Entry__c> reversalEntries = [
            SELECT Id, Entry_Type__c, Amount__c, Debit_Amount__c, Status__c
            FROM Ledger_Entry__c
            WHERE Reference_Id__c = :coll.Id
              AND Reference_Type__c = 'Collection'
              AND Entry_Type__c = 'Adjustment'
        ];

        System.assertEquals(1, reversalEntries.size(), 'One reversal entry should be created');
        System.assertEquals(paymentAmount, reversalEntries[0].Amount__c,
            'Reversal amount should match original payment');
        System.assertEquals(paymentAmount, reversalEntries[0].Debit_Amount__c,
            'Reversal posts a debit that restores AR');
        System.assertEquals('Posted', reversalEntries[0].Status__c,
            'Reversal entry should be Posted');

        // Verify invoice balance was restored
        Invoice__c updatedInvoice = [
            SELECT Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assertEquals(balanceAfterPayment + paymentAmount, updatedInvoice.Balance_Due__c,
            'Invoice balance should be restored after bounce');
    }

    @IsTest
    static void testAfterUpdate_bouncedDoesNotExceedTotal() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c, Total_Amount__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0002'
            LIMIT 1
        ];

        Decimal totalAmount = invoice.Total_Amount__c;

        // Create a collection for a large amount
        Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, 10000);
        coll.Payment_Mode__c = 'Cheque';
        coll.Status__c = 'Collected';
        insert coll;

        Test.startTest();
        coll.Status__c = 'Bounced';
        update coll;
        Test.stopTest();

        // Verify the balance does not exceed total amount after bounce restoration
        Invoice__c updatedInvoice = [
            SELECT Balance_Due__c, Total_Amount__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assert(updatedInvoice.Balance_Due__c <= updatedInvoice.Total_Amount__c,
            'Balance should not exceed total amount after bounce');
    }

    // ── afterUpdate - Confirmed Collections Tests ──────────────────────────

    @IsTest
    static void testAfterUpdate_chequeClears() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id FROM Invoice__c WHERE Invoice_Number__c = 'INV-TEST-0001' LIMIT 1
        ];

        // A cheque collection is Pending until it clears.
        Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, 8000);
        coll.Payment_Mode__c = 'Cheque';
        coll.Status__c = 'Collected';
        insert coll;

        Ledger_Entry__c pendingEntry = [
            SELECT Id, Status__c FROM Ledger_Entry__c
            WHERE Reference_Id__c = :coll.Id AND Reference_Type__c = 'Collection'
            LIMIT 1
        ];
        System.assertEquals('Pending', pendingEntry.Status__c,
            'Cheque ledger entry should be Pending initially');

        Test.startTest();
        coll.Status__c = 'Cleared';
        update coll;
        Test.stopTest();

        // The cleared cheque realises the ledger entry.
        Ledger_Entry__c clearedEntry = [
            SELECT Status__c FROM Ledger_Entry__c WHERE Id = :pendingEntry.Id
        ];
        System.assertEquals('Posted', clearedEntry.Status__c,
            'Ledger entry should be Posted once the cheque clears');
    }

    // ── processNewCollections edge cases ────────────────────────────────────

    @IsTest
    static void testProcessNewCollections_noInvoice() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];

        Test.startTest();
        // Collection without an invoice
        Collection__c coll = new Collection__c(
            Account__c = acct.Id,
            Collection_Date__c = Date.today(),
            Amount__c = 5000,
            Payment_Mode__c = 'Cash',
            Status__c = 'Collected'
        );
        insert coll;
        Test.stopTest();

        // Ledger entry should still be created (just without invoice link)
        List<Ledger_Entry__c> entries = [
            SELECT Id, Invoice__c FROM Ledger_Entry__c
            WHERE Reference_Id__c = :coll.Id AND Reference_Type__c = 'Collection'
        ];
        System.assertEquals(1, entries.size(), 'Ledger entry should be created even without invoice');
    }

    @IsTest
    static void testProcessNewCollections_paymentModeInDescription() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id FROM Invoice__c WHERE Invoice_Number__c = 'INV-TEST-0001' LIMIT 1
        ];

        Test.startTest();
        Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, 7000);
        coll.Payment_Mode__c = 'UPI';
        insert coll;
        Test.stopTest();

        Ledger_Entry__c entry = [
            SELECT Description__c FROM Ledger_Entry__c
            WHERE Reference_Id__c = :coll.Id AND Reference_Type__c = 'Collection'
            LIMIT 1
        ];
        System.assert(entry.Description__c.contains('UPI'),
            'Ledger entry description should contain the payment mode');
    }

    // ── updateInvoiceBalances Tests ─────────────────────────────────────────

    @IsTest
    static void testUpdateInvoiceBalances_balanceGoesToZero() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c, Total_Amount__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0002'
            LIMIT 1
        ];

        Decimal fullBalance = invoice.Balance_Due__c;

        Test.startTest();
        // Pay the full balance
        Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, fullBalance);
        insert coll;
        Test.stopTest();

        Invoice__c updatedInvoice = [
            SELECT Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assertEquals(0, updatedInvoice.Balance_Due__c,
            'Balance should be zero after full payment');
    }

    @IsTest
    static void testUpdateInvoiceBalances_overpaymentClampsToZero() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c, Total_Amount__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0002'
            LIMIT 1
        ];

        Test.startTest();
        // Pay more than the balance
        Collection__c coll = TestDataFactory.createCollection(
            acct.Id, invoice.Id, invoice.Balance_Due__c + 5000
        );
        insert coll;
        Test.stopTest();

        Invoice__c updatedInvoice = [
            SELECT Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assertEquals(0, updatedInvoice.Balance_Due__c,
            'Balance should be clamped to zero (not negative)');
    }

    // ── Bulk Tests ─────────────────────────────────────────────────────────

    @IsTest
    static void testBulkCollectionInsert() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c
            FROM Invoice__c
            WHERE Invoice_Number__c = 'INV-TEST-0001'
            LIMIT 1
        ];

        Decimal originalBalance = invoice.Balance_Due__c;

        Test.startTest();
        List<Collection__c> collections = new List<Collection__c>();
        for (Integer i = 0; i < 20; i++) {
            Collection__c coll = TestDataFactory.createCollection(acct.Id, invoice.Id, 100);
            coll.Payment_Mode__c = 'Cash';
            collections.add(coll);
        }
        insert collections;
        Test.stopTest();

        // Verify all ledger entries were created
        Integer ledgerCount = [
            SELECT COUNT() FROM Ledger_Entry__c
            WHERE Invoice__c = :invoice.Id AND Entry_Type__c = 'Payment'
        ];
        System.assertEquals(20, ledgerCount, 'All 20 ledger entries should be created');

        // Verify balance
        Invoice__c updatedInvoice = [
            SELECT Balance_Due__c FROM Invoice__c WHERE Id = :invoice.Id
        ];
        System.assertEquals(originalBalance - 2000, updatedInvoice.Balance_Due__c,
            'Balance should be reduced by total of all collections (20 * 100)');
    }
}