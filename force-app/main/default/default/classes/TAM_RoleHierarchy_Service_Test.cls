/**
 * @description Test class for TAM_RoleHierarchy_Service.
 *              Validates role hierarchy subordinate user retrieval.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class TAM_RoleHierarchy_Service_Test {

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
            Object__c = 'Sales_Order__c',
            Operator__c = 'SUM',
            Field__c = 'Amount__c',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'OwnerId',
            Active__c = true
        );
        insert criteria;
    }

    @isTest
    static void testGetRoleSubordinateUsers_CurrentUser() {
        Id currentUserId = UserInfo.getUserId();

        Test.startTest();
        Set<Id> result = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(currentUserId);
        Test.stopTest();

        System.assert(result.contains(currentUserId),
            'Running user should be included in the result set');
    }

    @isTest
    static void testGetRoleSubordinateUsers_NotNull() {
        Id currentUserId = UserInfo.getUserId();

        Test.startTest();
        Set<Id> result = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(currentUserId);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should never be null');
        System.assert(result.size() > 0, 'Result should contain at least one user');
    }
}