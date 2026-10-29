@isTest
private class SPM_SchemeProduct_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        Product_Extension__c prod = TestDataFactory.createProduct('Active Product', 'AP-0001');
        insert prod;

        Product_Extension__c inactiveProd = TestDataFactory.createProduct('Inactive Product', 'IP-0001');
        inactiveProd.Is_Active__c = false;
        insert inactiveProd;

        Scheme__c scheme = TestDataFactory.createScheme('Product Scheme', 'SCH-PROD-001', 'Free Products', 'Same Product (QTY)');
        scheme.Budget_Amount__c = 25000;
        insert scheme;
    }

    @isTest
    static void testValidProductInsert() {
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'AP-0001' LIMIT 1];
        Scheme__c scheme = [SELECT Id FROM Scheme__c LIMIT 1];

        Scheme_Product__c sp = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product_Ext__c = prod.Id,
            Is_Buy_Product__c = true,
            Min_Quantity__c = 5
        );

        Test.startTest();
        insert sp;
        Test.stopTest();

        System.assertNotEquals(null, sp.Id);
    }

    @isTest
    static void testInactiveProductBlocked() {
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'IP-0001' LIMIT 1];
        Scheme__c scheme = [SELECT Id FROM Scheme__c LIMIT 1];

        Scheme_Product__c sp = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product_Ext__c = prod.Id,
            Is_Buy_Product__c = true
        );

        Test.startTest();
        try {
            insert sp;
            System.assert(false, 'Should have thrown error');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('inactive'));
        }
        Test.stopTest();
    }

    @isTest
    static void testDuplicateProductBlocked() {
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'AP-0001' LIMIT 1];
        Scheme__c scheme = [SELECT Id FROM Scheme__c LIMIT 1];

        Scheme_Product__c sp1 = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product_Ext__c = prod.Id,
            Is_Buy_Product__c = true
        );
        insert sp1;

        Scheme_Product__c sp2 = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product_Ext__c = prod.Id,
            Is_Buy_Product__c = false
        );

        Test.startTest();
        try {
            insert sp2;
            System.assert(false, 'Should have thrown error');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('already added'));
        }
        Test.stopTest();
    }
}