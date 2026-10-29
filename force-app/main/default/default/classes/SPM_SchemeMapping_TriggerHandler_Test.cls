@isTest
private class SPM_SchemeMapping_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createTerritory('Test Territory', 'TT-001');
        insert territory;

        Scheme__c scheme = TestDataFactory.createScheme('Mapping Scheme', 'SCH-MAP-001', 'Discount in %', 'Same Product (QTY)');
        scheme.Budget_Amount__c = 25000;
        insert scheme;
    }

    @isTest
    static void testValidMappingInsert() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c LIMIT 1];
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Scheme_Mapping__c mapping = new Scheme_Mapping__c(
            Scheme__c = scheme.Id,
            Territory__c = territory.Id,
            Customer_Type__c = 'Retailer',
            Is_Active__c = true
        );

        Test.startTest();
        insert mapping;
        Test.stopTest();

        System.assertNotEquals(null, mapping.Id);
    }

    @isTest
    static void testDuplicateMappingBlocked() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c LIMIT 1];
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Scheme_Mapping__c mapping1 = new Scheme_Mapping__c(
            Scheme__c = scheme.Id,
            Territory__c = territory.Id,
            Customer_Type__c = 'Retailer',
            Is_Active__c = true
        );
        insert mapping1;

        Scheme_Mapping__c mapping2 = new Scheme_Mapping__c(
            Scheme__c = scheme.Id,
            Territory__c = territory.Id,
            Customer_Type__c = 'Retailer',
            Is_Active__c = true
        );

        Test.startTest();
        try {
            insert mapping2;
            System.assert(false, 'Should have thrown error');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('already exists'));
        }
        Test.stopTest();
    }
}