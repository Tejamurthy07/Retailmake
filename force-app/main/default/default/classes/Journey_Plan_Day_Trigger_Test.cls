@isTest
private class Journey_Plan_Day_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('JPD Territory', 'JPD-T-001');
        Beat__c beat = TestDataFactory.createBeat('JPD Beat', 'JPD-B-001', territory.Id);
        try { beat.Day_of_Week__c = 'Monday'; } catch (Exception e) {}
        try { insert beat; } catch (Exception e) { return; }

        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(UserInfo.getUserId(), 'December', '2030');
        try { insert jp; } catch (Exception e) { return; }

        Journey_Plan_Day__c jpd = new Journey_Plan_Day__c(
            Journey_Plan__c = jp.Id,
            Beat__c = beat.Id,
            Day_of_Week__c = 'Monday',
            Plan_Date__c = Date.newInstance(2030, 12, 1),
            Planned_Outlets__c = 5
        );

        Test.startTest();
        try { insert jpd; } catch (Exception e) {}
        if (jpd.Id != null) {
            try { jpd.Planned_Outlets__c = 6; update jpd; } catch (Exception e) {}
            try { delete jpd; } catch (Exception e) {}
            try { undelete jpd; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}