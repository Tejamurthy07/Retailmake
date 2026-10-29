@IsTest
private class CollectionReceiptController_Test {

    @TestSetup
    static void setupData() {
        Account acc = TestDataFactory.createAndInsertAccount('Test Customer', 'Retailer');

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = 11800;
        insert so;

        Invoice__c inv = TestDataFactory.createInvoice(so.Id, acc.Id);
        insert inv;

        Collection__c col = TestDataFactory.createCollection(acc.Id, inv.Id, 5000);
        col.Receipt_Number__c = 'RCP-0001';
        insert col;

        // Create allocation records
        Collection_Allocation__c alloc = new Collection_Allocation__c(
            Collection__c = col.Id,
            Invoice__c = inv.Id,
            Allocated_Amount__c = 3000
        );
        insert alloc;
    }

    @IsTest
    static void testConstructorPopulatesAllFields() {
        Collection__c col = [SELECT Id FROM Collection__c LIMIT 1];

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(col);
        CollectionReceiptController controller = new CollectionReceiptController(stdCtrl);
        Test.stopTest();

        System.assertNotEquals(null, controller.collection, 'collection should be populated');
        System.assertNotEquals(null, controller.collection.Account__r.Name, 'Account name should be queried');
        System.assertNotEquals(null, controller.amountInWords, 'amountInWords should be populated');
        System.assertNotEquals('Zero', controller.amountInWords, 'amountInWords should not be Zero');
    }

    @IsTest
    static void testAllocationsPopulated() {
        Collection__c col = [SELECT Id FROM Collection__c LIMIT 1];

        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(col);
        CollectionReceiptController controller = new CollectionReceiptController(stdCtrl);

        System.assertEquals(true, controller.hasAllocations, 'hasAllocations should be true');
        System.assertNotEquals(null, controller.allocations, 'allocations should be populated');
        System.assertEquals(1, controller.allocations.size(), 'Should have 1 allocation');
        System.assertEquals(3000, controller.totalAllocated, 'totalAllocated should be 3000');
    }

    @IsTest
    static void testOnAccountAmount() {
        Collection__c col = [SELECT Id FROM Collection__c LIMIT 1];

        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(col);
        CollectionReceiptController controller = new CollectionReceiptController(stdCtrl);

        // Amount = 5000, allocated = 3000, so on-account = 2000
        System.assertEquals(2000, controller.onAccountAmount, 'onAccountAmount should be 2000');
        System.assertEquals(true, controller.hasOnAccountPortion, 'hasOnAccountPortion should be true');
    }

    @IsTest
    static void testBalanceDueFromInvoice() {
        Collection__c col = [SELECT Id FROM Collection__c LIMIT 1];

        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(col);
        CollectionReceiptController controller = new CollectionReceiptController(stdCtrl);

        System.assertNotEquals(null, controller.balanceDue, 'balanceDue should be populated');
    }

    @IsTest
    static void testCollectionWithNoInvoice() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Collection__c col = new Collection__c(
            Account__c = acc.Id,
            Collection_Date__c = Date.today(),
            Amount__c = 2000,
            Payment_Mode__c = 'Cash',
            Status__c = 'Collected',
            Is_On_Account__c = true
        );
        insert col;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(col);
        CollectionReceiptController controller = new CollectionReceiptController(stdCtrl);
        Test.stopTest();

        System.assertEquals(0, controller.balanceDue, 'Balance due should be 0 when no invoice');
        System.assertEquals(false, controller.hasAllocations, 'Should have no allocations');
        System.assertEquals(2000, controller.onAccountAmount, 'Full amount should be on-account');
    }

    @IsTest
    static void testZeroAmountCollection() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Collection__c col = new Collection__c(
            Account__c = acc.Id,
            Collection_Date__c = Date.today(),
            Amount__c = 0,
            Payment_Mode__c = 'Cash',
            Status__c = 'Collected'
        );
        insert col;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(col);
        CollectionReceiptController controller = new CollectionReceiptController(stdCtrl);
        Test.stopTest();

        System.assertEquals('Zero', controller.amountInWords, 'Zero amount should return "Zero"');
        System.assertEquals(0, controller.onAccountAmount, 'On-account should be 0');
    }

    @IsTest
    static void testAmountInWordsVariousRanges() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        // Test a Lakh-range amount
        Collection__c col = new Collection__c(
            Account__c = acc.Id,
            Collection_Date__c = Date.today(),
            Amount__c = 150000,
            Payment_Mode__c = 'Cash',
            Status__c = 'Collected'
        );
        insert col;

        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(col);
        CollectionReceiptController controller = new CollectionReceiptController(stdCtrl);

        System.assert(controller.amountInWords.contains('Lakh'), 'Should contain "Lakh" for 150000');
    }
}