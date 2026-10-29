@isTest
private class SalesOrderPdfMobileController_Test {

    @isTest
    static void generatePdf_createsContentVersion() {
        Account acc = TestDataFactory.createAccountWithGeoData('Test Outlet', 'Distributor', 19.0760, 72.8777);
        acc.put('Outlet_Type__c', 'Grocery');
        insert acc;

        Sales_Order__c so = new Sales_Order__c(
            Account__c = acc.Id,
            Order_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert so;

        Test.startTest();
        String cvId = SalesOrderPdfMobileController.generatePdf(so.Id);
        Test.stopTest();

        System.assertNotEquals(null, cvId, 'Should return a ContentVersion Id');
    }

    @isTest
    static void generatePdf_throwsOnNull() {
        Boolean threw = false;
        try {
            SalesOrderPdfMobileController.generatePdf(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw);
    }
}