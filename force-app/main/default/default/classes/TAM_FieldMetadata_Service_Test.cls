/**
 * @description Test class for TAM_FieldMetadata_Service.
 *              Validates field metadata retrieval, user field detection,
 *              and picklist value population.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class TAM_FieldMetadata_Service_Test {

    @testSetup
    static void setupData() {
        Target_Period__c period = new Target_Period__c(
            Name = 'Test Period',
            Start_Date__c = Date.today().toStartOfMonth(),
            End_Date__c = Date.today().toStartOfMonth().addMonths(1).addDays(-1),
            Is_Active__c = true,
            Type__c = 'Monthly'
        );
        insert period;

        Target_Criteria__c criteria = new Target_Criteria__c(
            Name = 'Test Criteria',
            Object__c = 'Account',
            Operator__c = 'COUNT',
            Date_Field__c = 'CreatedDate',
            User_Field__c = 'OwnerId',
            Active__c = true
        );
        insert criteria;
    }

    @isTest
    static void testGetFields_ValidObject() {
        Test.startTest();
        List<TAM_FieldMetadata_Service.FieldInfo> fields =
            TAM_FieldMetadata_Service.getFields('Account');
        Test.stopTest();

        System.assertNotEquals(0, fields.size(), 'Account should return fields');

        Boolean hasNameField = false;
        for (TAM_FieldMetadata_Service.FieldInfo fi : fields) {
            if (fi.apiName == 'Name') {
                hasNameField = true;
                break;
            }
        }
        System.assertEquals(true, hasNameField, 'Account fields should include Name');
    }

    @isTest
    static void testGetFields_InvalidObject() {
        Test.startTest();
        List<TAM_FieldMetadata_Service.FieldInfo> fields =
            TAM_FieldMetadata_Service.getFields('NonExistent_Object__xyz');
        Test.stopTest();

        System.assertEquals(0, fields.size(), 'Non-existent object should return empty list');
    }

    @isTest
    static void testGetFields_UserFieldDetection() {
        Test.startTest();
        List<TAM_FieldMetadata_Service.FieldInfo> fields =
            TAM_FieldMetadata_Service.getFields('Account');
        Test.stopTest();

        Boolean foundUserField = false;
        for (TAM_FieldMetadata_Service.FieldInfo fi : fields) {
            if (fi.apiName == 'OwnerId' && fi.isUserField == true) {
                foundUserField = true;
                break;
            }
        }
        System.assertEquals(true, foundUserField,
            'OwnerId on Account should be detected as a user field');
    }

    @isTest
    static void testGetFields_PicklistValues() {
        Test.startTest();
        List<TAM_FieldMetadata_Service.FieldInfo> fields =
            TAM_FieldMetadata_Service.getFields('Account');
        Test.stopTest();

        Boolean foundPicklist = false;
        for (TAM_FieldMetadata_Service.FieldInfo fi : fields) {
            if (fi.type == 'Picklist' && fi.picklistValues != null && !fi.picklistValues.isEmpty()) {
                foundPicklist = true;
                break;
            }
        }
        System.assertEquals(true, foundPicklist,
            'Account should have at least one picklist field with populated values');
    }
}