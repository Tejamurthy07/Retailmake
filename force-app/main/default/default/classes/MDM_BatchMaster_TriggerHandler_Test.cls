@isTest
private class MDM_BatchMaster_TriggerHandler_Test {

    @isTest
    static void testValidBatchInsert() {
        Product_Extension__c prod = TestDataFactory.createProduct('Test Product', 'TP-001');
        insert prod;

        Batch_Master__c batch = new Batch_Master__c(
            Batch_Number__c = 'BATCH-001',
            Product_Ext__c = prod.Id,
            Manufacturing_Date__c = Date.today().addDays(-30),
            Expiry_Date__c = Date.today().addDays(365),
            Status__c = 'Active'
        );

        Test.startTest();
        insert batch;
        Test.stopTest();

        System.assertNotEquals(null, batch.Id);
    }

    @isTest
    static void testInvalidExpiryDate() {
        Product_Extension__c prod = TestDataFactory.createProduct('Test Product', 'TP-001');
        insert prod;

        Batch_Master__c batch = new Batch_Master__c(
            Batch_Number__c = 'BATCH-002',
            Product_Ext__c = prod.Id,
            Manufacturing_Date__c = Date.today(),
            Expiry_Date__c = Date.today().addDays(-10),
            Status__c = 'Active'
        );

        Test.startTest();
        try {
            insert batch;
            System.assert(false, 'Should have thrown error');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Expiry Date'));
        }
        Test.stopTest();
    }

    @isTest
    static void testDuplicateBatchNumber() {
        Product_Extension__c prod = TestDataFactory.createProduct('Test Product', 'TP-001');
        insert prod;

        Batch_Master__c batch1 = new Batch_Master__c(
            Batch_Number__c = 'BATCH-DUP',
            Product_Ext__c = prod.Id,
            Manufacturing_Date__c = Date.today().addDays(-30),
            Expiry_Date__c = Date.today().addDays(365),
            Status__c = 'Active'
        );
        insert batch1;

        Batch_Master__c batch2 = new Batch_Master__c(
            Batch_Number__c = 'BATCH-DUP',
            Product_Ext__c = prod.Id,
            Manufacturing_Date__c = Date.today(),
            Expiry_Date__c = Date.today().addDays(180),
            Status__c = 'Active'
        );

        Test.startTest();
        try {
            insert batch2;
            System.assert(false, 'Should have thrown error');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('already exists'));
        }
        Test.stopTest();
    }
}