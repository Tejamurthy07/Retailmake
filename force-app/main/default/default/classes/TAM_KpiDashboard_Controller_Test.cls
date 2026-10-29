@IsTest
private class TAM_KpiDashboard_Controller_Test {

    @TestSetup
    static void setupData() {
        // Create Target Criteria (multiple for KPI variety)
        Target_Criteria__c criteria1 = TestDataFactory.createTargetCriteria(
            'Revenue', 'Sales_Order__c', 'SUM', 'Total_Net_Amount__c',
            'Order_Date__c', 'Salesperson__c'
        );
        criteria1.Incentive_Weight__c = 60;
        criteria1.Category__c = 'Sales';

        Target_Criteria__c criteria2 = TestDataFactory.createTargetCriteria(
            'Visits', 'Visit__c', 'COUNT', 'Id',
            'Visit_Date__c', 'Salesperson__c'
        );
        criteria2.Incentive_Weight__c = 40;
        criteria2.Category__c = 'Activity';

        insert new List<Target_Criteria__c>{ criteria1, criteria2 };

        // Create current monthly period
        Target_Period__c currentPeriod = TestDataFactory.createTargetPeriod(
            'April 2026', Date.today().toStartOfMonth(),
            Date.today().toStartOfMonth().addMonths(1).addDays(-1), 'Monthly'
        );
        currentPeriod.Is_Default__c = true;
        insert currentPeriod;

        // Create prior monthly periods for trend data
        List<Target_Period__c> priorPeriods = new List<Target_Period__c>();
        Date monthStart = Date.today().toStartOfMonth();
        for (Integer i = 1; i <= 5; i++) {
            Date priorStart = monthStart.addMonths(-i);
            Date priorEnd = priorStart.addMonths(1).addDays(-1);
            priorPeriods.add(TestDataFactory.createTargetPeriod(
                'Period -' + i, priorStart, priorEnd, 'Monthly'
            ));
        }
        insert priorPeriods;

        // Create Target Actuals for current period
        Id userId = UserInfo.getUserId();

        Target_Actual__c ta1 = TestDataFactory.createTargetActual(
            criteria1.Id, currentPeriod.Id, userId, 100000
        );
        ta1.Achievement_Value__c = 85000;

        Target_Actual__c ta2 = TestDataFactory.createTargetActual(
            criteria2.Id, currentPeriod.Id, userId, 200
        );
        ta2.Achievement_Value__c = 180;

        insert new List<Target_Actual__c>{ ta1, ta2 };

        // Create Target Actuals for prior periods (trend data)
        List<Target_Actual__c> priorActuals = new List<Target_Actual__c>();
        for (Target_Period__c pp : priorPeriods) {
            Target_Actual__c priorTa = TestDataFactory.createTargetActual(
                criteria1.Id, pp.Id, userId, 90000
            );
            priorTa.Achievement_Value__c = 75000;
            priorActuals.add(priorTa);
        }
        insert priorActuals;

        // Create Incentive records for the current period
        Incentive__c inc = new Incentive__c(
            Salesperson__c = userId,
            Target_Criteria__c = criteria1.Id,
            Target_Period__c = currentPeriod.Id,
            Target_Actual__c = ta1.Id,
            Achievement_Percent__c = 85,
            Multiplier__c = 1.0,
            Base_Amount__c = 100000,
            Calculated_Amount__c = 4250,
            Status__c = 'Calculated'
        );
        insert inc;
    }

    // ── getDashboardData (self view) ────────────────────────────────

    @IsTest
    static void testGetDashboardData_SelfView_WithPeriod() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Test.startTest();
        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(period.Id, 'self');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.containsKey('periods'), 'Should contain periods');
        System.assert(result.containsKey('currentPeriodId'), 'Should contain currentPeriodId');
        System.assert(result.containsKey('currentUserId'), 'Should contain currentUserId');
        System.assert(result.containsKey('kpis'), 'Should contain kpis');
        System.assert(result.containsKey('grandTarget'), 'Should contain grandTarget');
        System.assert(result.containsKey('grandActual'), 'Should contain grandActual');
        System.assert(result.containsKey('grandPercent'), 'Should contain grandPercent');
        System.assert(result.containsKey('incentiveSummary'), 'Should contain incentiveSummary');
        System.assert(result.containsKey('trend'), 'Should contain trend');
        System.assert(result.containsKey('leaderboard'), 'Should contain leaderboard');

        // Self view should NOT have team data
        System.assertEquals(null, result.get('team'), 'Self view should not have team data');
    }

    @IsTest
    static void testGetDashboardData_SelfView_KpiValues() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(period.Id, 'self');

        List<Map<String, Object>> kpis = (List<Map<String, Object>>) result.get('kpis');
        System.assert(kpis.size() >= 2, 'Should have at least 2 KPIs');

        Decimal grandTarget = (Decimal) result.get('grandTarget');
        Decimal grandActual = (Decimal) result.get('grandActual');
        System.assert(grandTarget > 0, 'Grand target should be greater than 0');
        System.assert(grandActual > 0, 'Grand actual should be greater than 0');
    }

    @IsTest
    static void testGetDashboardData_SelfView_NullPeriod() {
        Test.startTest();
        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(null, 'self');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Should auto-detect current period since Is_Default__c is true
        String periodId = (String) result.get('currentPeriodId');
        System.assert(String.isNotBlank(periodId), 'Should auto-detect current period');
    }

    @IsTest
    static void testGetDashboardData_SelfView_BlankPeriod() {
        Test.startTest();
        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData('', 'self');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    // ── getDashboardData (team view) ────────────────────────────────

    @IsTest
    static void testGetDashboardData_TeamView() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Test.startTest();
        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(period.Id, 'team');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Team view should include team data
        System.assert(result.containsKey('team'), 'Team view should contain team data');
    }

    // ── getDashboardData (incentive summary) ────────────────────────

    @IsTest
    static void testGetDashboardData_IncentiveSummary() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(period.Id, 'self');
        Map<String, Object> incSummary = (Map<String, Object>) result.get('incentiveSummary');

        System.assertNotEquals(null, incSummary, 'Incentive summary should not be null');
        System.assert(incSummary.containsKey('total_count'), 'Should contain total_count');
        System.assert(incSummary.containsKey('total_amount'), 'Should contain total_amount');

        Integer totalCount = (Integer) incSummary.get('total_count');
        System.assert(totalCount >= 1, 'Should have at least 1 incentive');
    }

    // ── getDashboardData (trend data) ───────────────────────────────

    @IsTest
    static void testGetDashboardData_TrendData() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(period.Id, 'self');
        List<Map<String, Object>> trend = (List<Map<String, Object>>) result.get('trend');

        System.assertNotEquals(null, trend, 'Trend data should not be null');
        // We created 5 prior monthly periods plus the current one
        System.assert(trend.size() >= 1, 'Should have at least 1 trend period');

        for (Map<String, Object> row : trend) {
            System.assert(row.containsKey('label'), 'Trend row should have label');
            System.assert(row.containsKey('periodId'), 'Trend row should have periodId');
            System.assert(row.containsKey('target'), 'Trend row should have target');
            System.assert(row.containsKey('actual'), 'Trend row should have actual');
        }
    }

    // ── getDashboardData (leaderboard) ──────────────────────────────

    @IsTest
    static void testGetDashboardData_Leaderboard() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(period.Id, 'self');
        List<Map<String, Object>> leaderboard = (List<Map<String, Object>>) result.get('leaderboard');

        System.assertNotEquals(null, leaderboard, 'Leaderboard should not be null');
        // Current user should appear with target > 0 and achievement > 0
        System.assert(leaderboard.size() >= 1, 'Should have at least 1 entry in leaderboard');

        // Verify leaderboard is sorted by percent descending
        if (leaderboard.size() > 1) {
            Decimal firstPct = (Decimal) leaderboard[0].get('percent');
            Decimal secondPct = (Decimal) leaderboard[1].get('percent');
            System.assert(firstPct >= secondPct, 'Leaderboard should be sorted descending by percent');
        }
    }

    // ── getDashboardData (no period found) ──────────────────────────

    @IsTest
    static void testGetDashboardData_NoPeriodExists() {
        // Delete all periods to test the empty-period scenario
        delete [SELECT Id FROM Target_Actual__c];
        delete [SELECT Id FROM Incentive__c];
        delete [SELECT Id FROM Target_Period__c];

        Test.startTest();
        Map<String, Object> result = TAM_KpiDashboard_Controller.getDashboardData(null, 'self');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null even with no periods');
        String periodId = (String) result.get('currentPeriodId');
        System.assertEquals('', periodId, 'Current period should be empty string');
    }

    // ── getComparisonKpis ───────────────────────────────────────────

    @IsTest
    static void testGetComparisonKpis_SelfView() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> results = TAM_KpiDashboard_Controller.getComparisonKpis(
            period.Id, 'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results should not be null');
        System.assert(results.size() >= 2, 'Should return at least 2 KPIs');

        for (Map<String, Object> kpi : results) {
            System.assert(kpi.containsKey('name'), 'KPI should have name');
            System.assert(kpi.containsKey('target'), 'KPI should have target');
            System.assert(kpi.containsKey('actual'), 'KPI should have actual');
            System.assert(kpi.containsKey('percent'), 'KPI should have percent');
        }
    }

    @IsTest
    static void testGetComparisonKpis_TeamView() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> results = TAM_KpiDashboard_Controller.getComparisonKpis(
            period.Id, 'team'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results should not be null');
    }

    @IsTest
    static void testGetComparisonKpis_BlankPeriod() {
        Test.startTest();
        List<Map<String, Object>> results = TAM_KpiDashboard_Controller.getComparisonKpis('', 'self');
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results should not be null');
        System.assertEquals(0, results.size(), 'Should return empty list for blank period');
    }

    @IsTest
    static void testGetComparisonKpis_NullPeriod() {
        Test.startTest();
        List<Map<String, Object>> results = TAM_KpiDashboard_Controller.getComparisonKpis(null, 'self');
        Test.stopTest();

        System.assertNotEquals(null, results, 'Results should not be null');
        System.assertEquals(0, results.size(), 'Should return empty list for null period');
    }
}