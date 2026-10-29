@isTest
private class TAM_IncentiveCalculation_Batch_Test {

    @testSetup
    static void setupTestData() {
        Target_Criteria__c criteria = new Target_Criteria__c(
            Name = 'Revenue',
            Object__c = 'Account',
            Operator__c = 'COUNT',
            Date_Field__c = 'CreatedDate',
            User_Field__c = 'OwnerId',
            Active__c = true
        );
        insert criteria;

        Target_Period__c period = new Target_Period__c(
            Name = 'Batch Test Period',
            Start_Date__c = Date.today().toStartOfMonth(),
            End_Date__c = Date.today().toStartOfMonth().addMonths(1).addDays(-1),
            Is_Active__c = true,
            Type__c = 'Monthly'
        );
        insert period;

        // Create multiple target actuals
        List<Target_Actual__c> actuals = new List<Target_Actual__c>();
        actuals.add(new Target_Actual__c(
            Target_Criteria__c = criteria.Id,
            Target_Period__c = period.Id,
            User__c = UserInfo.getUserId(),
            Target_Value__c = 100000,
            Achievement_Value__c = 90000
        ));
        insert actuals;

        // Create slabs
        insert new Incentive_Slab__c(
            Name = 'Standard',
            Min_Percent__c = 80, Max_Percent__c = 99.99,
            Payout_Type__c = 'Percentage', Payout_Value__c = 3,
            Multiplier__c = 1.0, Is_Active__c = true, Sort_Order__c = 1
        );
    }

    @isTest
    static void testBatchExecution() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(new TAM_IncentiveCalculation_Batch(period.Id), 50);
        Test.stopTest();

        List<Incentive__c> incentives = [SELECT Id, Calculated_Amount__c, Status__c FROM Incentive__c];
        System.assert(!incentives.isEmpty(), 'Batch should create incentives');
        System.assertEquals('Calculated', incentives[0].Status__c);
        System.assert(incentives[0].Calculated_Amount__c > 0, 'Amount should be calculated');
    }

    @isTest
    static void testBatchEmptyScope() {
        // Use a non-existent period ID
        Target_Period__c fakePeriod = new Target_Period__c(
            Name = 'Empty Period',
            Start_Date__c = Date.newInstance(2020, 1, 1),
            End_Date__c = Date.newInstance(2020, 1, 31),
            Is_Active__c = true,
            Type__c = 'Monthly'
        );
        insert fakePeriod;

        Test.startTest();
        Database.executeBatch(new TAM_IncentiveCalculation_Batch(fakePeriod.Id), 50);
        Test.stopTest();

        List<Incentive__c> incentives = [SELECT Id FROM Incentive__c WHERE Target_Period__c = :fakePeriod.Id];
        System.assertEquals(0, incentives.size(), 'No incentives for empty period');
    }

    @isTest
    static void testSchedulerExecution() {
        // Create a past period for the scheduler to pick up
        Target_Period__c pastPeriod = new Target_Period__c(
            Name = 'Past Period',
            Start_Date__c = Date.today().addMonths(-2).toStartOfMonth(),
            End_Date__c = Date.today().addMonths(-1).toStartOfMonth().addDays(-1),
            Is_Active__c = true,
            Type__c = 'Monthly'
        );
        insert pastPeriod;

        Test.startTest();
        String jobId = System.schedule(
            'Test Incentive Scheduler',
            '0 0 2 1 * ?',
            new TAM_IncentiveCalculation_Scheduler()
        );
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Scheduler should be scheduled');
    }
}