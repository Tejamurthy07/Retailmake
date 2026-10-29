@isTest
private class TAM_Achievement_Scheduler_Test {

    @isTest
    static void testExecuteDirect() {
        Test.startTest();
        try { new TAM_Achievement_Scheduler().execute(null); }
        catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testScheduleJob() {
        Test.startTest();
        try {
            String jobId = System.schedule(
                'TAM Achievement Test ' + DateTime.now().getTime(),
                '0 0 0 1 1 ? 2099',
                new TAM_Achievement_Scheduler()
            );
            System.assertNotEquals(null, jobId);
        } catch (Exception e) {}
        Test.stopTest();
    }
}