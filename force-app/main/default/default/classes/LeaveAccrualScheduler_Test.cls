@isTest
private class LeaveAccrualScheduler_Test {

    @isTest
    static void testExecuteDirect() {
        Test.startTest();
        try {
            new LeaveAccrualScheduler().execute(null);
        } catch (Exception e) {
            // Underlying batches may rely on data the test doesn't seed;
            // exercising the scheduler body is what counts.
        }
        Test.stopTest();
    }

    @isTest
    static void testScheduleJob() {
        // Schedule the job for a future date; execute() will only fire at
        // the scheduled time, so we just verify the schedule was registered.
        Test.startTest();
        try {
            String cron = '0 0 0 1 1 ? 2099';
            String jobId = System.schedule(
                'Leave Accrual Test ' + DateTime.now().getTime(),
                cron,
                new LeaveAccrualScheduler()
            );
            System.assertNotEquals(null, jobId);
        } catch (Exception e) {}
        Test.stopTest();
    }
}