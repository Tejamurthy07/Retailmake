/**
 * @description Test class for CollectionController.
 */
@isTest
private class CollectionController_Test {

    @testSetup
    static void setupTestData() {
        Account retailer = TestDataFactory.createAccount('Collection Retailer', 'Retailer');
        insert retailer;

        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Collection Territory', 'TER-C01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Collection Beat', 'BEAT-C01', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        Visit__c visit = TestDataFactory.createVisit(retailer.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        List<Sales_Order__c> orders = new List<Sales_Order__c>();
        for (Integer i = 0; i < 4; i++) {
            Sales_Order__c order = TestDataFactory.createSalesOrder(
                retailer.Id, UserInfo.getUserId(), visit.Id
            );
            order.Order_Date__c = Date.today().addDays(-((i + 1) * 30));
            order.Total_Gross_Amount__c = 10000 + (i * 5000);
            order.Total_Net_Amount__c = 10000 + (i * 5000);
            orders.add(order);
        }
        insert orders;

        List<Invoice__c> invoices = new List<Invoice__c>();

        Invoice__c inv1 = TestDataFactory.createInvoice(orders[0].Id, retailer.Id);
        inv1.Invoice_Date__c = Date.today().addDays(-15);
        inv1.Due_Date__c = Date.today().addDays(15);
        inv1.Total_Amount__c = 10000;
        inv1.Net_Amount__c = 11800;
        inv1.Balance_Due__c = 11800;
        invoices.add(inv1);

        Invoice__c inv2 = TestDataFactory.createInvoice(orders[1].Id, retailer.Id);
        inv2.Invoice_Date__c = Date.today().addDays(-45);
        inv2.Due_Date__c = Date.today().addDays(-15);
        inv2.Total_Amount__c = 15000;
        inv2.Net_Amount__c = 17700;
        inv2.Balance_Due__c = 17700;
        invoices.add(inv2);

        Invoice__c inv3 = TestDataFactory.createInvoice(orders[2].Id, retailer.Id);
        inv3.Invoice_Date__c = Date.today().addDays(-75);
        inv3.Due_Date__c = Date.today().addDays(-45);
        inv3.Total_Amount__c = 20000;
        inv3.Net_Amount__c = 23600;
        inv3.Balance_Due__c = 23600;
        invoices.add(inv3);

        Invoice__c inv4 = TestDataFactory.createInvoice(orders[3].Id, retailer.Id);
        inv4.Invoice_Date__c = Date.today().addDays(-120);
        inv4.Due_Date__c = Date.today().addDays(-91);
        inv4.Total_Amount__c = 25000;
        inv4.Net_Amount__c = 29500;
        inv4.Balance_Due__c = 29500;
        invoices.add(inv4);

        insert invoices;
    }

    @isTest
    static void testGetOutstandingInvoices() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];

        Test.startTest();
        List<Invoice__c> outstanding = CollectionController.getOutstandingInvoices(acct.Id);
        Test.stopTest();

        System.assertEquals(4, outstanding.size(), 'Should have 4 outstanding invoices');
        for (Invoice__c inv : outstanding) {
            System.assert(inv.Balance_Due__c > 0, 'Each invoice should have a positive balance');
        }
    }

    @isTest
    static void testCreateCollection() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c
            FROM Invoice__c WHERE Account__c = :acct.Id ORDER BY Due_Date__c ASC LIMIT 1
        ];
        Decimal originalBalance = invoice.Balance_Due__c;

        Collection__c collection = new Collection__c(
            Account__c = acct.Id,
            Invoice__c = invoice.Id,
            Amount__c = 5000,
            Payment_Mode__c = 'Cash',
            Salesperson__c = UserInfo.getUserId()
        );

        Test.startTest();
        Collection__c created = CollectionController.createCollection(collection);
        Test.stopTest();

        System.assertNotEquals(null, created.Id, 'Collection should be created');
        System.assertEquals(5000, created.Amount__c);
    }

    @isTest
    static void testGetAgingSummary() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];

        Test.startTest();
        Map<String, Decimal> aging = CollectionController.getAgingSummary(acct.Id);
        Test.stopTest();

        System.assertNotEquals(null, aging, 'Aging summary should not be null');
        System.assert(aging.get('total') > 0, 'Total aging should be greater than 0');
    }

    @isTest
    static void testGetCollectionHistory() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];

        // Create a collection first
        Invoice__c invoice = [SELECT Id FROM Invoice__c WHERE Account__c = :acct.Id LIMIT 1];
        Collection__c coll = new Collection__c(
            Account__c = acct.Id,
            Invoice__c = invoice.Id,
            Amount__c = 1000,
            Payment_Mode__c = 'Cash',
            Status__c = 'Collected',
            Salesperson__c = UserInfo.getUserId()
        );
        insert coll;

        Test.startTest();
        List<Collection__c> history = CollectionController.getCollectionHistory(acct.Id);
        Test.stopTest();

        System.assert(history.size() > 0, 'Should have collection history');
    }

    @isTest
    static void testCreateCollectionInvalidAmount() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];

        Collection__c collection = new Collection__c(
            Account__c = acct.Id,
            Amount__c = 0,
            Payment_Mode__c = 'Cash',
            Salesperson__c = UserInfo.getUserId()
        );

        Test.startTest();
        try {
            CollectionController.createCollection(collection);
            System.assert(false, 'Should throw for zero amount');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testCreateCollectionExceedsBalance() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c
            FROM Invoice__c WHERE Account__c = :acct.Id ORDER BY Due_Date__c ASC LIMIT 1
        ];

        Collection__c collection = new Collection__c(
            Account__c = acct.Id,
            Invoice__c = invoice.Id,
            Amount__c = invoice.Balance_Due__c + 10000,
            Payment_Mode__c = 'Cash',
            Salesperson__c = UserInfo.getUserId()
        );

        Test.startTest();
        try {
            CollectionController.createCollection(collection);
            System.assert(false, 'Should throw for amount exceeding balance');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testBounceHandling() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Collection Retailer' LIMIT 1];
        Invoice__c invoice = [
            SELECT Id, Balance_Due__c
            FROM Invoice__c WHERE Account__c = :acct.Id ORDER BY Due_Date__c ASC LIMIT 1
        ];

        Collection__c chequeCollection = new Collection__c(
            Account__c = acct.Id,
            Invoice__c = invoice.Id,
            Collection_Date__c = Date.today().addDays(-5),
            Amount__c = 5000,
            Payment_Mode__c = 'Cheque',
            Cheque_Number__c = 'CHQ-123456',
            Cheque_Date__c = Date.today().addDays(-5),
            Bank_Name__c = 'HDFC Bank',
            Status__c = 'Collected',
            Salesperson__c = UserInfo.getUserId()
        );
        insert chequeCollection;

        Test.startTest();
        chequeCollection.Status__c = 'Bounced';
        update chequeCollection;
        Test.stopTest();

        Collection__c bounced = [
            SELECT Id, Status__c FROM Collection__c WHERE Id = :chequeCollection.Id
        ];
        System.assertEquals('Bounced', bounced.Status__c);
    }
}