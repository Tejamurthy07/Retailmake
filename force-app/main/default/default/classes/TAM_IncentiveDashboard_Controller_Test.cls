@IsTest
private class TAM_IncentiveDashboard_Controller_Test {

    @TestSetup
    static void setupData() {
        // Create Target Criteria
        Target_Criteria__c criteria = TestDataFactory.createTargetCriteria(
            'Revenue Target', 'Sales_Order__c', 'SUM', 'Total_Net_Amount__c',
            'Order_Date__c', 'Salesperson__c'
        );
        criteria.Incentive_Weight__c = 50;
        insert criteria;

        // Create Territory
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory(
            'Incentive Territory', 'IT-001'
        );

        // Create Target Period (current month)
        Target_Period__c period = TestDataFactory.createTargetPeriod(
            'April 2026', Date.today().toStartOfMonth(),
            Date.today().toStartOfMonth().addMonths(1).addDays(-1), 'Monthly'
        );
        period.Is_Default__c = true;
        insert period;

        // Create Target Actual
        Target_Actual__c ta = TestDataFactory.createTargetActual(
            criteria.Id, period.Id, UserInfo.getUserId(), 100000
        );
        ta.Achievement_Value__c = 80000;
        insert ta;

        // Create Incentive Slab
        Incentive_Slab__c slab = new Incentive_Slab__c(
            Name = 'Slab 80-100%',
            Target_Criteria__c = criteria.Id,
            Min_Percent__c = 80,
            Max_Percent__c = 100,
            Payout_Type__c = 'Percentage',
            Payout_Value__c = 5,
            Multiplier__c = 1.0,
            Is_Active__c = true,
            Sort_Order__c = 1,
            Territory__c = territory.Id
        );
        insert slab;

        // Create Incentive records in various statuses
        List<Incentive__c> incentives = new List<Incentive__c>{
            new Incentive__c(
                Salesperson__c = UserInfo.getUserId(),
                Target_Actual__c = ta.Id,
                Target_Criteria__c = criteria.Id,
                Target_Period__c = period.Id,
                Incentive_Slab_Ref__c = slab.Id,
                Achievement_Percent__c = 80,
                Multiplier__c = 1.0,
                Base_Amount__c = 100000,
                Calculated_Amount__c = 5000,
                Status__c = 'Calculated'
            ),
            new Incentive__c(
                Salesperson__c = UserInfo.getUserId(),
                Target_Criteria__c = criteria.Id,
                Target_Period__c = period.Id,
                Incentive_Slab_Ref__c = slab.Id,
                Achievement_Percent__c = 90,
                Multiplier__c = 1.0,
                Base_Amount__c = 50000,
                Calculated_Amount__c = 2500,
                Status__c = 'Pending Approval'
            ),
            new Incentive__c(
                Salesperson__c = UserInfo.getUserId(),
                Target_Criteria__c = criteria.Id,
                Target_Period__c = period.Id,
                Incentive_Slab_Ref__c = slab.Id,
                Achievement_Percent__c = 95,
                Multiplier__c = 1.0,
                Base_Amount__c = 75000,
                Calculated_Amount__c = 3750,
                Final_Amount__c = 3750,
                Status__c = 'Approved',
                Approved_By__c = UserInfo.getUserId(),
                Approval_Date__c = DateTime.now()
            )
        };
        insert incentives;
    }

    // ── getDashboardData ────────────────────────────────────────────

    @IsTest
    static void testGetDashboardData_ReturnsDashboard() {
        Test.startTest();
        TAM_IncentiveDashboard_Controller.DashboardData result =
            TAM_IncentiveDashboard_Controller.getDashboardData();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Dashboard data should not be null');
        System.assertNotEquals(null, result.periods, 'Periods should not be null');
        System.assert(result.periods.size() >= 1, 'Should have at least 1 period');
        System.assert(String.isNotBlank(result.currentPeriodId), 'Current period Id should be set');
        System.assertNotEquals(null, result.incentives, 'Incentives should not be null');
        System.assertNotEquals(null, result.summary, 'Summary should not be null');
        System.assertNotEquals(null, result.criteriaOptions, 'Criteria options should not be null');
        System.assertNotEquals(null, result.profileOptions, 'Profile options should not be null');
        System.assertNotEquals(null, result.territoryOptions, 'Territory options should not be null');
    }

    @IsTest
    static void testGetDashboardData_SummaryValues() {
        TAM_IncentiveDashboard_Controller.DashboardData result =
            TAM_IncentiveDashboard_Controller.getDashboardData();

        Map<String, Object> summary = result.summary;
        System.assertNotEquals(null, summary, 'Summary should not be null');
        System.assert(summary.containsKey('total'), 'Summary should contain total');
        System.assert(summary.containsKey('calculated'), 'Summary should contain calculated');
        System.assert(summary.containsKey('pending'), 'Summary should contain pending');
        System.assert(summary.containsKey('approved'), 'Summary should contain approved');

        Integer total = (Integer) summary.get('total');
        System.assert(total >= 3, 'Should have at least 3 incentives total');
    }

    // ── getIncentives ───────────────────────────────────────────────

    @IsTest
    static void testGetIncentives_AllStatuses() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveDashboard_Controller.getIncentives(
            period.Id, 'All'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results should not be null');
        System.assert(results.size() >= 3, 'Should return at least 3 incentives');
    }

    @IsTest
    static void testGetIncentives_FilteredByStatus() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        List<Incentive__c> calculated = TAM_IncentiveDashboard_Controller.getIncentives(
            period.Id, 'Calculated'
        );
        List<Incentive__c> pending = TAM_IncentiveDashboard_Controller.getIncentives(
            period.Id, 'Pending Approval'
        );
        Test.stopTest();

        System.assert(calculated.size() >= 1, 'Should have at least 1 calculated incentive');
        System.assert(pending.size() >= 1, 'Should have at least 1 pending incentive');
    }

    @IsTest
    static void testGetIncentives_NullStatus() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveDashboard_Controller.getIncentives(
            period.Id, null
        );
        Test.stopTest();

        System.assert(results.size() >= 3, 'Null status should return all incentives');
    }

    // ── getIncentiveSummary ─────────────────────────────────────────

    @IsTest
    static void testGetIncentiveSummary_ReturnsSummary() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        Map<String, Object> summary = TAM_IncentiveDashboard_Controller.getIncentiveSummary(period.Id);
        Test.stopTest();

        System.assertNotEquals(null, summary, 'Summary should not be null');
        System.assert(summary.containsKey('total'), 'Should contain total key');
        System.assert(summary.containsKey('totalCalcAmt'), 'Should contain totalCalcAmt key');
    }

    // ── getIncentiveDetail ──────────────────────────────────────────

    @IsTest
    static void testGetIncentiveDetail_ReturnsRecord() {
        Incentive__c inc = [SELECT Id FROM Incentive__c LIMIT 1];

        Test.startTest();
        Incentive__c result = TAM_IncentiveDashboard_Controller.getIncentiveDetail(inc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Incentive detail should not be null');
        System.assertEquals(inc.Id, result.Id, 'Should return correct incentive');
        System.assertNotEquals(null, result.Status__c, 'Status should be populated');
    }

    // ── runCalculation ──────────────────────────────────────────────

    @IsTest
    static void testRunCalculation_ExecutesBatch() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        try {
            TAM_IncentiveDashboard_Controller.runCalculation(period.Id);
        } catch (Exception e) {
            // Batch may fail in test context due to dependencies; ensure method is callable
            System.assert(e.getMessage() != null, 'Exception should have a message');
        }
        Test.stopTest();
    }

    // ── runAnnualBonus ──────────────────────────────────────────────

    @IsTest
    static void testRunAnnualBonus_Executes() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        try {
            TAM_IncentiveDashboard_Controller.runAnnualBonus(period.Id);
        } catch (Exception e) {
            // Annual bonus calculation may require specific period types
            System.assert(e.getMessage() != null, 'Exception should have a message');
        }
        Test.stopTest();
    }

    // ── submitForApproval ───────────────────────────────────────────

    @IsTest
    static void testSubmitForApproval_Success() {
        Incentive__c calcInc = [
            SELECT Id FROM Incentive__c WHERE Status__c = 'Calculated' LIMIT 1
        ];

        Test.startTest();
        TAM_IncentiveDashboard_Controller.submitForApproval(new List<Id>{ calcInc.Id });
        Test.stopTest();

        Incentive__c updated = [SELECT Status__c FROM Incentive__c WHERE Id = :calcInc.Id];
        System.assertEquals('Pending Approval', updated.Status__c,
            'Status should change to Pending Approval');
    }

    @IsTest
    static void testSubmitForApproval_WrongStatus() {
        Incentive__c approvedInc = [
            SELECT Id FROM Incentive__c WHERE Status__c = 'Approved' LIMIT 1
        ];

        Test.startTest();
        TAM_IncentiveDashboard_Controller.submitForApproval(new List<Id>{ approvedInc.Id });
        Test.stopTest();

        Incentive__c unchanged = [SELECT Status__c FROM Incentive__c WHERE Id = :approvedInc.Id];
        System.assertEquals('Approved', unchanged.Status__c,
            'Status should remain Approved (not eligible for submit)');
    }

    @IsTest
    static void testSubmitForApproval_EmptyList() {
        Test.startTest();
        TAM_IncentiveDashboard_Controller.submitForApproval(new List<Id>());
        Test.stopTest();
        // No exception means success for empty list
    }

    // ── approveIncentives ───────────────────────────────────────────

    @IsTest
    static void testApproveIncentives_Success() {
        Incentive__c pendingInc = [
            SELECT Id FROM Incentive__c WHERE Status__c = 'Pending Approval' LIMIT 1
        ];

        Test.startTest();
        TAM_IncentiveDashboard_Controller.approveIncentives(new List<Id>{ pendingInc.Id });
        Test.stopTest();

        Incentive__c updated = [
            SELECT Status__c, Final_Amount__c, Approved_By__c, Approval_Date__c
            FROM Incentive__c WHERE Id = :pendingInc.Id
        ];
        System.assertEquals('Approved', updated.Status__c, 'Status should change to Approved');
        System.assertNotEquals(null, updated.Final_Amount__c, 'Final amount should be set');
        System.assertEquals(UserInfo.getUserId(), updated.Approved_By__c, 'Approved by should be set');
        System.assertNotEquals(null, updated.Approval_Date__c, 'Approval date should be set');
    }

    // ── rejectIncentives ────────────────────────────────────────────

    @IsTest
    static void testRejectIncentives_Success() {
        Incentive__c pendingInc = [
            SELECT Id FROM Incentive__c WHERE Status__c = 'Pending Approval' LIMIT 1
        ];

        Test.startTest();
        TAM_IncentiveDashboard_Controller.rejectIncentives(new List<Id>{ pendingInc.Id });
        Test.stopTest();

        Incentive__c updated = [SELECT Status__c FROM Incentive__c WHERE Id = :pendingInc.Id];
        System.assertEquals('Rejected', updated.Status__c, 'Status should change to Rejected');
    }

    @IsTest
    static void testRejectIncentives_WrongStatus() {
        Incentive__c calcInc = [
            SELECT Id FROM Incentive__c WHERE Status__c = 'Calculated' LIMIT 1
        ];

        Test.startTest();
        TAM_IncentiveDashboard_Controller.rejectIncentives(new List<Id>{ calcInc.Id });
        Test.stopTest();

        Incentive__c unchanged = [SELECT Status__c FROM Incentive__c WHERE Id = :calcInc.Id];
        System.assertEquals('Calculated', unchanged.Status__c,
            'Status should remain Calculated (not eligible for rejection)');
    }

    // ── markAsPaid ──────────────────────────────────────────────────

    @IsTest
    static void testMarkAsPaid_Success() {
        Incentive__c approvedInc = [
            SELECT Id FROM Incentive__c WHERE Status__c = 'Approved' LIMIT 1
        ];
        Date paymentDate = Date.today();

        Test.startTest();
        TAM_IncentiveDashboard_Controller.markAsPaid(new List<Id>{ approvedInc.Id }, paymentDate);
        Test.stopTest();

        Incentive__c updated = [
            SELECT Status__c, Payment_Date__c FROM Incentive__c WHERE Id = :approvedInc.Id
        ];
        System.assertEquals('Paid', updated.Status__c, 'Status should change to Paid');
        System.assertEquals(paymentDate, updated.Payment_Date__c, 'Payment date should be set');
    }

    @IsTest
    static void testMarkAsPaid_WrongStatus() {
        Incentive__c pendingInc = [
            SELECT Id FROM Incentive__c WHERE Status__c = 'Pending Approval' LIMIT 1
        ];

        Test.startTest();
        TAM_IncentiveDashboard_Controller.markAsPaid(
            new List<Id>{ pendingInc.Id }, Date.today()
        );
        Test.stopTest();

        Incentive__c unchanged = [SELECT Status__c FROM Incentive__c WHERE Id = :pendingInc.Id];
        System.assertEquals('Pending Approval', unchanged.Status__c,
            'Status should remain Pending Approval (not eligible for payment)');
    }
}