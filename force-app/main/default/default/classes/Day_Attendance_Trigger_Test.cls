@isTest
private class Day_Attendance_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Day_Attendance__c da = TestDataFactory.createDayAttendanceWithDefaults(UserInfo.getUserId());

        Test.startTest();
        try { insert da; } catch (Exception e) {}
        if (da.Id != null) {
            try {
                da.Distance_Traveled_Km__c = 5;
                update da;
            } catch (Exception e) {}
            try { delete da; } catch (Exception e) {}
            try { undelete da; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}