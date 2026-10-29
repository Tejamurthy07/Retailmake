/**
 * @description Test class for BPM_JourneyPlan_TriggerHandler.
 *              Validates default values, status transitions, deprecated field sync,
 *              approval handling, and effective date calculation.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class BPM_JourneyPlan_TriggerHandler_Test {

    @testSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('JP Trigger Territory', 'TER-JPT01');
    }

    @isTest
    static void testDefaultValues() {
        Test.startTest();
        Journey_Plan__c jp = new Journey_Plan__c(
            Salesperson__c = UserInfo.getUserId(),
            Month__c = 'March',
            Year__c = '2026'
        );
        insert jp;
        Test.stopTest();

        Journey_Plan__c inserted = [
            SELECT Status__c, Plan_Date__c, Total_Planned_Visits__c, Total_Planned_Days__c, User__c
            FROM Journey_Plan__c WHERE Id = :jp.Id
        ];
        System.assertEquals('Draft', inserted.Status__c, 'Default status should be Draft');
        System.assertEquals(Date.today(), inserted.Plan_Date__c, 'Plan_Date__c should default to today');
        System.assertEquals(0, inserted.Total_Planned_Visits__c, 'Total_Planned_Visits__c should default to 0');
        System.assertEquals(0, inserted.Total_Planned_Days__c, 'Total_Planned_Days__c should default to 0');
    }

    @isTest
    static void testDeprecatedFieldSync() {
        Test.startTest();
        Journey_Plan__c jp = new Journey_Plan__c(
            Salesperson__c = UserInfo.getUserId(),
            Month__c = 'April',
            Year__c = '2026'
        );
        insert jp;
        Test.stopTest();

        Journey_Plan__c inserted = [SELECT User__c, Salesperson__c FROM Journey_Plan__c WHERE Id = :jp.Id];
        System.assertEquals(inserted.Salesperson__c, inserted.User__c,
            'User__c should be synced from Salesperson__c');
    }

    @isTest
    static void testEffectiveDatesAutoCalculated() {
        Test.startTest();
        Journey_Plan__c jp = new Journey_Plan__c(
            Salesperson__c = UserInfo.getUserId(),
            Month__c = 'June',
            Year__c = '2026'
        );
        insert jp;
        Test.stopTest();

        Journey_Plan__c inserted = [SELECT Effective_From__c, Effective_To__c FROM Journey_Plan__c WHERE Id = :jp.Id];
        System.assertEquals(Date.newInstance(2026, 6, 1), inserted.Effective_From__c,
            'Effective_From__c should be first day of June 2026');
        System.assertEquals(Date.newInstance(2026, 6, 30), inserted.Effective_To__c,
            'Effective_To__c should be last day of June 2026');
    }

    @isTest
    static void testValidStatusTransitions() {
        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(UserInfo.getUserId(), 'May', '2026');
        insert jp;

        Test.startTest();
        // Draft -> Submitted
        jp.Status__c = 'Submitted';
        update jp;
        System.assertEquals('Submitted', [SELECT Status__c FROM Journey_Plan__c WHERE Id = :jp.Id].Status__c);

        // Submitted -> Approved
        jp.Status__c = 'Approved';
        update jp;
        System.assertEquals('Approved', [SELECT Status__c FROM Journey_Plan__c WHERE Id = :jp.Id].Status__c);

        // Approved -> Active
        jp.Status__c = 'Active';
        update jp;
        System.assertEquals('Active', [SELECT Status__c FROM Journey_Plan__c WHERE Id = :jp.Id].Status__c);

        // Active -> Cancelled
        jp.Status__c = 'Cancelled';
        update jp;
        System.assertEquals('Cancelled', [SELECT Status__c FROM Journey_Plan__c WHERE Id = :jp.Id].Status__c);
        Test.stopTest();
    }

    @isTest
    static void testInvalidStatusTransition() {
        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(UserInfo.getUserId(), 'July', '2026');
        insert jp;

        Test.startTest();
        try {
            jp.Status__c = 'Approved'; // Draft -> Approved not allowed
            update jp;
            System.assert(false, 'Should have thrown an error for invalid transition');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Invalid status transition'),
                'Error should mention invalid status transition');
        }
        Test.stopTest();
    }

    @isTest
    static void testApprovalFieldsSet() {
        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(UserInfo.getUserId(), 'August', '2026');
        insert jp;

        jp.Status__c = 'Submitted';
        update jp;

        Test.startTest();
        jp.Status__c = 'Approved';
        update jp;
        Test.stopTest();

        Journey_Plan__c approved = [
            SELECT Approval_Date__c, Approved_By__c
            FROM Journey_Plan__c WHERE Id = :jp.Id
        ];
        System.assertEquals(Date.today(), approved.Approval_Date__c,
            'Approval_Date__c should be set to today on approval');
        System.assertNotEquals(null, approved.Approved_By__c,
            'Approved_By__c should be set on approval');
    }

    @isTest
    static void testRejectedToRedraft() {
        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(UserInfo.getUserId(), 'September', '2026');
        insert jp;

        jp.Status__c = 'Submitted';
        update jp;

        jp.Status__c = 'Rejected';
        update jp;

        Test.startTest();
        jp.Status__c = 'Draft';
        update jp;
        Test.stopTest();

        System.assertEquals('Draft', [SELECT Status__c FROM Journey_Plan__c WHERE Id = :jp.Id].Status__c,
            'Rejected plan should be able to return to Draft');
    }
}