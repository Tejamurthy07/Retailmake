@isTest
private class CollectionReceiptMobileController_Test {

    @isTest
    static void generateReceipt_createsContentVersion() {
        Account acc = TestDataFactory.createAccountWithGeoData('Test Outlet', 'Distributor', 19.0760, 72.8777);
        acc.put('Outlet_Type__c', 'Grocery');
        insert acc;

        Collection__c c = new Collection__c(
            Account__c = acc.Id,
            Amount__c = 1000,
            Collection_Date__c = Date.today(),
            
            Payment_Mode__c = 'Cash'
        );
        insert c;

        Test.startTest();
        String cvId = CollectionReceiptMobileController.generateReceipt(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, cvId, 'Should return a ContentVersion Id');
    }

    @isTest
    static void generateReceipt_throwsOnNull() {
        Boolean threw = false;
        try {
            CollectionReceiptMobileController.generateReceipt(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }
}