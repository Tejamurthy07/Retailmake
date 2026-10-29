@IsTest
private class SalesOrderPDFController_Test {

    @TestSetup
    static void setupData() {
        Account acc = TestDataFactory.createAndInsertAccount('Test Customer', 'Retailer');

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Gross_Amount__c = 10000;
        so.Total_Discount__c = 500;
        so.Total_Tax__c = 1710;
        so.Total_Net_Amount__c = 11210;
        so.Total_Items__c = 2;
        insert so;

        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(2);

        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>();
        lineItems.add(TestDataFactory.createOrderLineItem(so.Id, products[0].Id, 10, 500));
        lineItems.add(TestDataFactory.createOrderLineItem(so.Id, products[1].Id, 5, 1000));
        insert lineItems;
    }

    @IsTest
    static void testConstructorPopulatesAllFields() {
        Sales_Order__c so = [SELECT Id FROM Sales_Order__c LIMIT 1];

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assertNotEquals(null, controller.salesOrder, 'salesOrder should be populated');
        System.assertNotEquals(null, controller.salesOrder.Account__r.Name, 'Account name should be queried');
        System.assertEquals(11210, controller.salesOrder.Total_Net_Amount__c, 'Net amount should match');
        System.assertNotEquals(null, controller.lineItems, 'lineItems should be populated');
        System.assertEquals(2, controller.lineItems.size(), 'Should have 2 line items');
        System.assertNotEquals(null, controller.amountInWords, 'amountInWords should be populated');
        System.assertNotEquals('Zero', controller.amountInWords, 'amountInWords should not be Zero for non-zero amount');
    }

    @IsTest
    static void testLineItemWrapperIndex() {
        Sales_Order__c so = [SELECT Id FROM Sales_Order__c LIMIT 1];

        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);

        System.assertEquals(1, controller.lineItems[0].index, 'First line item index should be 1');
        System.assertEquals(2, controller.lineItems[1].index, 'Second line item index should be 2');
        System.assertNotEquals(null, controller.lineItems[0].line, 'Line item record should be populated');
    }

    @IsTest
    static void testAmountInWordsZero() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = 0;
        insert so;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assertEquals('Zero', controller.amountInWords, 'Zero amount should return "Zero"');
    }

    @IsTest
    static void testAmountInWordsNull() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = null;
        insert so;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assertEquals('Zero', controller.amountInWords, 'Null amount should return "Zero"');
    }

    @IsTest
    static void testAmountInWordsLargeNumber() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = 1234567;
        insert so;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assert(controller.amountInWords.contains('Lakh'), 'Large amounts should contain "Lakh"');
    }

    @IsTest
    static void testNoLineItems() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = 100;
        insert so;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assertEquals(0, controller.lineItems.size(), 'Should have no line items');
    }

    @IsTest
    static void testAmountInWordsCroreRange() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = 15000000;
        insert so;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assert(controller.amountInWords.contains('Crore'), 'Crore-range amounts should contain "Crore"');
    }

    @IsTest
    static void testAmountInWordsHundredRange() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = 350;
        insert so;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assert(controller.amountInWords.contains('Hundred'), 'Hundreds should contain "Hundred"');
    }

    @IsTest
    static void testAmountInWordsThousandRange() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Total_Net_Amount__c = 45000;
        insert so;

        Test.startTest();
        ApexPages.StandardController stdCtrl = new ApexPages.StandardController(so);
        SalesOrderPDFController controller = new SalesOrderPDFController(stdCtrl);
        Test.stopTest();

        System.assert(controller.amountInWords.contains('Thousand'), 'Thousands should contain "Thousand"');
    }
}