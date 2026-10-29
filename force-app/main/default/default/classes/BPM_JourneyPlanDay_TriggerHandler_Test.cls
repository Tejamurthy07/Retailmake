/**
 * @description Test class for BPM_JourneyPlanDay_TriggerHandler.
 *              Validates rollup calculations and default field population.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class BPM_JourneyPlanDay_TriggerHandler_Test {

    @testSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('JPD Test Territory', 'TER-JPD01');
        Beat__c beat = TestDataFactory.createBeat('JPD Beat', 'BEAT-JPD01', territory.Id);
        beat.Day_of_Week__c = 'Monday;Tuesday;Wednesday;Thursday;Friday';
        insert beat;

        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(UserInfo.getUserId(), 'October', '2026');
        insert jp;
    }

    @isTest
    static void testDefaultStatus() {
        Journey_Plan__c jp = [SELECT Id FROM Journey_Plan__c LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];

        Test.startTest();
        Journey_Plan_Day__c jpd = new Journey_Plan_Day__c(
            Journey_Plan__c = jp.Id,
            Beat__c = beat.Id,
            Day_of_Week__c = 'Monday',
            Week_Number__c = 'Week 1',
            Planned_Outlets__c = 5
        );
        insert jpd;
        Test.stopTest();

        Journey_Plan_Day__c inserted = [SELECT Status__c, Beat_Name__c FROM Journey_Plan_Day__c WHERE Id = :jpd.Id];
        System.assertEquals('Planned', inserted.Status__c, 'Default status should be Planned');
        System.assertNotEquals(null, inserted.Beat_Name__c, 'Beat_Name__c should be populated from Beat__r.Name');
    }

    @isTest
    static void testRollupOnInsert() {
        Journey_Plan__c jp = [SELECT Id FROM Journey_Plan__c LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];

        Test.startTest();
        List<Journey_Plan_Day__c> days = new List<Journey_Plan_Day__c>();
        List<String> dayNames = new List<String>{'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'};
        for (Integer i = 0; i < 5; i++) {
            days.add(new Journey_Plan_Day__c(
                Journey_Plan__c = jp.Id,
                Beat__c = beat.Id,
                Day_of_Week__c = dayNames[i],
                Week_Number__c = 'Week 1',
                Planned_Outlets__c = 4
            ));
        }
        insert days;
        Test.stopTest();

        Journey_Plan__c updated = [SELECT Total_Planned_Days__c, Total_Planned_Visits__c FROM Journey_Plan__c WHERE Id = :jp.Id];
        System.assertEquals(5, updated.Total_Planned_Days__c, 'Total_Planned_Days__c should be 5');
        System.assertEquals(20, updated.Total_Planned_Visits__c, 'Total_Planned_Visits__c should be 20 (5*4)');
    }

    @isTest
    static void testRollupOnUpdate() {
        Journey_Plan__c jp = [SELECT Id FROM Journey_Plan__c LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];

        Journey_Plan_Day__c jpd = new Journey_Plan_Day__c(
            Journey_Plan__c = jp.Id,
            Beat__c = beat.Id,
            Day_of_Week__c = 'Monday',
            Week_Number__c = 'Week 1',
            Planned_Outlets__c = 5
        );
        insert jpd;

        Test.startTest();
        jpd.Planned_Outlets__c = 10;
        update jpd;
        Test.stopTest();

        Journey_Plan__c updated = [SELECT Total_Planned_Visits__c FROM Journey_Plan__c WHERE Id = :jp.Id];
        System.assertEquals(10, updated.Total_Planned_Visits__c,
            'Total_Planned_Visits__c should be updated to 10 after changing outlets');
    }

    @isTest
    static void testRollupOnDelete() {
        Journey_Plan__c jp = [SELECT Id FROM Journey_Plan__c LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];

        List<Journey_Plan_Day__c> days = new List<Journey_Plan_Day__c>();
        days.add(new Journey_Plan_Day__c(
            Journey_Plan__c = jp.Id, Beat__c = beat.Id,
            Day_of_Week__c = 'Monday', Week_Number__c = 'Week 1', Planned_Outlets__c = 4
        ));
        days.add(new Journey_Plan_Day__c(
            Journey_Plan__c = jp.Id, Beat__c = beat.Id,
            Day_of_Week__c = 'Tuesday', Week_Number__c = 'Week 1', Planned_Outlets__c = 6
        ));
        insert days;

        Test.startTest();
        delete days[0];
        Test.stopTest();

        Journey_Plan__c updated = [SELECT Total_Planned_Days__c, Total_Planned_Visits__c FROM Journey_Plan__c WHERE Id = :jp.Id];
        System.assertEquals(1, updated.Total_Planned_Days__c, 'Total_Planned_Days__c should be 1 after deleting one day');
        System.assertEquals(6, updated.Total_Planned_Visits__c, 'Total_Planned_Visits__c should be 6 after deleting the 4-outlet day');
    }
}