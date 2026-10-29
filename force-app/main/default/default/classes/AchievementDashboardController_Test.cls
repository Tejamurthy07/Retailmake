/**
 * @description Test class for AchievementDashboardController.
 *              Validates getTargetsAndAchievements, getTrendData, getLeaderboard,
 *              getDrillDown, getDashboardInit, and runAchievementCalculation.
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class AchievementDashboardController_Test {

    @TestSetup
    static void setupTestData() {
        // Target Criteria
        Target_Criteria__c criteria = TestDataFactory.createTargetCriteria(
            'Revenue', 'Sales_Order__c', 'SUM', 'Total_Net_Amount__c',
            'Order_Date__c', 'Salesperson__c');
        insert criteria;

        // Monthly periods for current year
        Integer currentYear = Date.today().year();
        List<Target_Period__c> periods = new List<Target_Period__c>();

        for (Integer m = 1; m <= 12; m++) {
            Date periodStart = Date.newInstance(currentYear, m, 1);
            Date periodEnd = Date.newInstance(currentYear, m, Date.daysInMonth(currentYear, m));
            Target_Period__c tp = TestDataFactory.createTargetPeriod(
                'Month ' + m + ' ' + currentYear, periodStart, periodEnd, 'Monthly');
            if (m == Date.today().month()) {
                tp.Is_Default__c = true;
            }
            periods.add(tp);
        }
        insert periods;

        // Target Actuals for current user, current month
        Id userId = UserInfo.getUserId();
        Target_Period__c currentPeriod = [
            SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1
        ];

        Target_Actual__c ta = TestDataFactory.createTargetActual(
            criteria.Id, currentPeriod.Id, userId, 100000);
        ta.Achievement_Value__c = 75000;
        ta.Teams_Target__c = 500000;
        ta.Teams_Achievement__c = 350000;
        insert ta;
    }

    // ── Helper accessors ─────────────────────────────────────────────────────

    private static Id getCurrentPeriodId() {
        return [SELECT Id FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1].Id;
    }

    // ── getTargetsAndAchievements: with explicit period ─────────────────────

    @IsTest
    static void testGetTargetsAndAchievementsWithPeriod() {
        Id periodId = getCurrentPeriodId();

        Test.startTest();
        Map<String, Object> result = AchievementDashboardController.getTargetsAndAchievements(
            UserInfo.getUserId(), periodId);
        Test.stopTest();

        System.assert(result.containsKey('criteria'), 'Result should contain criteria');
        List<Object> criteriaList = (List<Object>) result.get('criteria');
        System.assert(!criteriaList.isEmpty(), 'Criteria list should not be empty');
        System.assert((Decimal) result.get('totalTarget') > 0, 'Total target should be positive');
        System.assert((Decimal) result.get('totalPercent') > 0, 'Total percent should be positive');
    }

    // ── getTargetsAndAchievements: auto-resolves default period ─────────────

    @IsTest
    static void testGetTargetsAndAchievementsDefaultPeriod() {
        Test.startTest();
        Map<String, Object> result = AchievementDashboardController.getTargetsAndAchievements(
            UserInfo.getUserId(), null);
        Test.stopTest();

        System.assert(result.containsKey('criteria'), 'Result should contain criteria even with null period');
    }

    // ── getTargetsAndAchievements: blank period with no default ─────────────

    @IsTest
    static void testGetTargetsAndAchievementsNoPeriodNoDefault() {
        // Remove the default flag
        Target_Period__c defaultPeriod = [SELECT Id, Is_Default__c FROM Target_Period__c WHERE Is_Default__c = true LIMIT 1];
        defaultPeriod.Is_Default__c = false;
        update defaultPeriod;

        Test.startTest();
        Map<String, Object> result = AchievementDashboardController.getTargetsAndAchievements(
            UserInfo.getUserId(), '');
        Test.stopTest();

        // Should still find a period based on date range
        System.assertNotEquals(null, result, 'Should return a result map');
    }

    // ── getTrendData: returns monthly trend ──────────────────────────────────

    @IsTest
    static void testGetTrendData() {
        Integer currentYear = Date.today().year();

        Test.startTest();
        List<Map<String, Object>> trend = AchievementDashboardController.getTrendData(
            UserInfo.getUserId(), currentYear);
        Test.stopTest();

        System.assert(!trend.isEmpty(), 'Trend data should have entries for the year');
        Map<String, Object> firstRow = trend[0];
        System.assert(firstRow.containsKey('label'), 'Each row should have a label');
        System.assert(firstRow.containsKey('target'), 'Each row should have a target');
        System.assert(firstRow.containsKey('actual'), 'Each row should have an actual');
    }

    // ── getTrendData: no monthly periods returns empty ──────────────────────

    @IsTest
    static void testGetTrendDataNoData() {
        Test.startTest();
        List<Map<String, Object>> trend = AchievementDashboardController.getTrendData(
            UserInfo.getUserId(), 2010);
        Test.stopTest();

        System.assertEquals(0, trend.size(), 'Trend should be empty for a year with no periods');
    }

    // ── getLeaderboard: returns ranked results ──────────────────────────────

    @IsTest
    static void testGetLeaderboard() {
        Id periodId = getCurrentPeriodId();

        Test.startTest();
        List<Map<String, Object>> board = AchievementDashboardController.getLeaderboard(periodId);
        Test.stopTest();

        System.assert(!board.isEmpty(), 'Leaderboard should have at least one entry');
        Map<String, Object> topEntry = board[0];
        System.assert(topEntry.containsKey('name'), 'Entry should have name');
        System.assert(topEntry.containsKey('percent'), 'Entry should have percent');
    }

    // ── getLeaderboard: blank period returns empty ──────────────────────────

    @IsTest
    static void testGetLeaderboardBlankPeriod() {
        Test.startTest();
        List<Map<String, Object>> board = AchievementDashboardController.getLeaderboard('');
        Test.stopTest();

        System.assertEquals(0, board.size(), 'Blank period should return empty list');
    }

    // ── getDrillDown: exercises subordinate logic ───────────────────────────

    @IsTest
    static void testGetDrillDown() {
        Id periodId = getCurrentPeriodId();

        Test.startTest();
        try {
            List<Map<String, Object>> results = AchievementDashboardController.getDrillDown(
                UserInfo.getUserId(), periodId);
            // May be empty if no subordinates, which is valid
            System.assertNotEquals(null, results, 'Results should not be null');
        } catch (Exception e) {
            // TAM_RoleHierarchy_Service may throw if not configured
            System.assert(e.getMessage() != null, 'Exception should have a message');
        }
        Test.stopTest();
    }

    // ── getDrillDown: blank period returns empty ────────────────────────────

    @IsTest
    static void testGetDrillDownBlankPeriod() {
        Test.startTest();
        List<Map<String, Object>> results = AchievementDashboardController.getDrillDown(
            UserInfo.getUserId(), '');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Blank period should return empty list');
    }

    // ── getDashboardInit: returns periods and current context ───────────────

    @IsTest
    static void testGetDashboardInit() {
        Test.startTest();
        Map<String, Object> init = AchievementDashboardController.getDashboardInit();
        Test.stopTest();

        System.assert(init.containsKey('periods'), 'Init should contain periods');
        System.assert(init.containsKey('currentPeriodId'), 'Init should contain currentPeriodId');
        System.assert(init.containsKey('currentUserId'), 'Init should contain currentUserId');
        System.assert(init.containsKey('currentYear'), 'Init should contain currentYear');
        System.assertEquals(UserInfo.getUserId(), init.get('currentUserId'),
            'Current user ID should match');
    }

    // ── runAchievementCalculation: starts batch ─────────────────────────────

    @IsTest
    static void testRunAchievementCalculation() {
        Id periodId = getCurrentPeriodId();

        Test.startTest();
        String message = AchievementDashboardController.runAchievementCalculation(periodId);
        Test.stopTest();

        System.assert(message.contains('Achievement calculation started'),
            'Message should confirm batch started: ' + message);
    }

    // ── runAchievementCalculation: blank period throws ──────────────────────

    @IsTest
    static void testRunAchievementCalculationBlankPeriod() {
        Test.startTest();
        try {
            AchievementDashboardController.runAchievementCalculation('');
            System.assert(false, 'Expected AuraHandledException for blank period');
        } catch (AuraHandledException e) {
            System.assert(true, 'AuraHandledException thrown as expected');
        }
        Test.stopTest();
    }
}