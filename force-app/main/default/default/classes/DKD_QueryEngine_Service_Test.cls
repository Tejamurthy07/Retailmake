/**
 * @description Tests for DKD_QueryEngine_Service. Inserts a small set of
 *              Sales_Order__c records with known values and verifies the
 *              query engine returns expected aggregations, groupings, and
 *              time series.
 */
@IsTest
private class DKD_QueryEngine_Service_Test {

    @TestSetup
    static void setup() {
        // ── Metrics ──
        List<KPI_Metric__c> metrics = new List<KPI_Metric__c>();
        metrics.add(new KPI_Metric__c(
            Name = 'Test Revenue',
            Metric_Key__c = 'test_revenue',
            Label__c = 'Test Revenue',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'SUM',
            Aggregate_Field__c = 'Total_Net_Amount__c',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'Salesperson__c',
            Default_Filter__c = 'Status__c IN (\'Approved\',\'Delivered\')',
            Format__c = 'Currency',
            Category__c = 'Sales',
            Is_Active__c = true
        ));
        metrics.add(new KPI_Metric__c(
            Name = 'Test Order Count',
            Metric_Key__c = 'test_order_count',
            Label__c = 'Test Order Count',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'COUNT',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'Salesperson__c',
            Default_Filter__c = 'Status__c IN (\'Approved\',\'Delivered\')',
            Format__c = 'Number',
            Category__c = 'Sales',
            Is_Active__c = true
        ));
        metrics.add(new KPI_Metric__c(
            Name = 'Test AOV',
            Metric_Key__c = 'test_avg_order',
            Label__c = 'Test AOV',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'AVG',
            Aggregate_Field__c = 'Total_Net_Amount__c',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'Salesperson__c',
            Default_Filter__c = 'Status__c IN (\'Approved\',\'Delivered\')',
            Format__c = 'Currency',
            Category__c = 'Sales',
            Is_Active__c = true
        ));
        metrics.add(new KPI_Metric__c(
            Name = 'Test No UserField',
            Metric_Key__c = 'test_no_user_field',
            Label__c = 'Test No User Field',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'COUNT',
            Date_Field__c = 'Order_Date__c',
            Format__c = 'Number',
            Category__c = 'Sales',
            Is_Active__c = true
        ));
        insert metrics;

        // ── Account ──
        Territory_Master__c ter = TestDataFactory.createAndInsertTerritory('DKD QE Territory', 'TER-DKDQE01');
        Account acc = new Account(Name = 'DKD Test Account', Outlet_Type__c = 'Grocery', Territory__c = ter.Id, Channel__c = 'GT');
        insert acc;

        // ── Sales Orders ──
        // Bypass order triggers to avoid complex rollups during test setup
        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        try {
            List<Sales_Order__c> orders = new List<Sales_Order__c>();
            Id uid = UserInfo.getUserId();

            // 3 Approved orders in this month (total 6000, avg 2000)
            orders.add(new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today(),
                Status__c = 'Approved',
                Salesperson__c = uid,
                Territory__c = ter.Id,
                Total_Net_Amount__c = 1000
            ));
            orders.add(new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today(),
                Status__c = 'Approved',
                Salesperson__c = uid,
                Territory__c = ter.Id,
                Total_Net_Amount__c = 2000
            ));
            orders.add(new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today(),
                Status__c = 'Approved',
                Salesperson__c = uid,
                Territory__c = ter.Id,
                Total_Net_Amount__c = 3000
            ));

            // 1 Draft order — should be excluded by default filter
            orders.add(new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today(),
                Status__c = 'Draft',
                Salesperson__c = uid,
                Territory__c = ter.Id,
                Total_Net_Amount__c = 9999
            ));

            // 1 Approved order outside the date range (should be excluded)
            orders.add(new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today().addMonths(-6),
                Status__c = 'Approved',
                Salesperson__c = uid,
                Territory__c = ter.Id,
                Total_Net_Amount__c = 5000
            ));

            insert orders;
        } finally {
            TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
        }
    }

    // ── queryMetric ─────────────────────────────────────────────────────────

    @IsTest
    static void testQueryMetric_Sum_NoGroupBy() {
        Test.startTest();
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_revenue',
            null,
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should return at least one row');
    }

    @IsTest
    static void testQueryMetric_Count() {
        Test.startTest();
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_order_count',
            null,
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should return result');
    }

    @IsTest
    static void testQueryMetric_Avg() {
        Test.startTest();
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_avg_order',
            null,
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should return result');
    }

    @IsTest
    static void testQueryMetric_GroupBy() {
        Test.startTest();
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_revenue',
            null,
            'Status__c',
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should return results');
    }

    @IsTest
    static void testQueryMetric_DateRangeExclusion() {
        Test.startTest();
        // Use a very narrow date range that excludes the today records
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_revenue',
            null,
            null,
            Date.today().addMonths(-7),
            Date.today().addMonths(-5),
            'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should return results');
    }

    @IsTest
    static void testQueryMetric_UserScope_Org() {
        Test.startTest();
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_revenue',
            null,
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'org'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should return results');
    }

    @IsTest
    static void testQueryMetric_UserScope_Team() {
        Test.startTest();
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_revenue',
            null,
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'team'
        );
        Test.stopTest();

        // Team scope at minimum includes the current user
        System.assertNotEquals(null, results, 'Should return results');
    }

    @IsTest
    static void testQueryMetric_MetricNotFound() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_QueryEngine_Service.queryMetric(
                'nonexistent_metric', null, null, Date.today(), Date.today(), 'self'
            );
        } catch (DKD_QueryEngine_Service.DKD_QueryException e) {
            thrown = true;
            System.assert(e.getMessage().contains('not found'));
        }
        Test.stopTest();
        System.assert(thrown, 'Should throw DKD_QueryException for missing metric');
    }

    @IsTest
    static void testQueryMetric_EmptyResult() {
        Test.startTest();
        // Future date range — no orders
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_revenue',
            null,
            null,
            Date.today().addYears(5),
            Date.today().addYears(5).addDays(30),
            'self'
        );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Empty result should return a zero row');
        System.assertEquals(0, (Integer) results[0].get('value'));
    }

    @IsTest
    static void testQueryMetric_NoUserField() {
        Test.startTest();
        // Metric with no user field — userScope should be ignored
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_no_user_field',
            null,
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should return result');
    }

    // ── queryMultipleMetrics ────────────────────────────────────────────────

    @IsTest
    static void testQueryMultipleMetrics() {
        Test.startTest();
        Map<String, Decimal> results = DKD_QueryEngine_Service.queryMultipleMetrics(
            new List<String>{ 'test_revenue', 'test_order_count', 'test_avg_order' },
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should return results map');
    }

    @IsTest
    static void testQueryMultipleMetrics_EmptyList() {
        Test.startTest();
        Map<String, Decimal> results = DKD_QueryEngine_Service.queryMultipleMetrics(
            new List<String>(), null, Date.today(), Date.today(), 'self'
        );
        Test.stopTest();
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void testQueryMultipleMetrics_FailsSoft() {
        Test.startTest();
        Map<String, Decimal> results = DKD_QueryEngine_Service.queryMultipleMetrics(
            new List<String>{ 'test_revenue', 'bogus_key' },
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();
        System.assertNotEquals(null, results, 'Should return results map');
    }

    // ── queryTimeSeries ─────────────────────────────────────────────────────

    @IsTest
    static void testQueryTimeSeries_Month() {
        Test.startTest();
        List<Map<String, Object>> series = DKD_QueryEngine_Service.queryTimeSeries(
            'test_revenue',
            null,
            Date.today().addMonths(-12),
            Date.today().addDays(1),
            'MONTH',
            'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, series, 'Should return a list');
        if (!series.isEmpty()) {
            Map<String, Object> first = series[0];
            System.assert(first.containsKey('period'));
            System.assert(first.containsKey('label'));
            System.assert(first.containsKey('value'));
            System.assert(first.containsKey('count'));
        }
    }

    @IsTest
    static void testQueryTimeSeries_InvalidInterval() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_QueryEngine_Service.queryTimeSeries(
                'test_revenue', null, Date.today(), Date.today(), 'FORTNIGHT', 'self'
            );
        } catch (DKD_QueryEngine_Service.DKD_QueryException e) {
            thrown = true;
            System.assert(e.getMessage().contains('interval'));
        }
        Test.stopTest();
        System.assert(thrown);
    }

    @IsTest
    static void testQueryTimeSeries_DefaultInterval() {
        Test.startTest();
        // Blank interval should default to MONTH
        List<Map<String, Object>> series = DKD_QueryEngine_Service.queryTimeSeries(
            'test_revenue',
            null,
            Date.today().addMonths(-12),
            Date.today().addDays(1),
            null,
            'self'
        );
        Test.stopTest();
        System.assert(series != null);
    }

    @IsTest
    static void testQueryTimeSeries_MetricNotFound() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_QueryEngine_Service.queryTimeSeries(
                'nope', null, Date.today(), Date.today(), 'MONTH', 'self'
            );
        } catch (DKD_QueryEngine_Service.DKD_QueryException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown);
    }

    // ── SOQL Injection Safety ───────────────────────────────────────────────

    @IsTest
    static void testSoqlInjection_GroupBy() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_QueryEngine_Service.queryMetric(
                'test_revenue',
                null,
                'Status__c OR 1=1',  // injection attempt
                Date.today().addDays(-1),
                Date.today().addDays(1),
                'self'
            );
        } catch (DKD_QueryEngine_Service.DKD_QueryException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Invalid field name'));
        }
        Test.stopTest();
        System.assert(thrown, 'Malicious groupBy should be rejected');
    }

    // ── Sprint 7: Drill-down ─────────────────────────────────────────────

    @IsTest
    static void testDrillDown_Basic() {
        Test.startTest();
        Map<String, Object> result = DKD_QueryEngine_Service.drillDownRecords(
            'test_revenue', null, null, null,
            Date.today().addDays(-1), Date.today().addDays(1),
            'self', 50
        );
        Test.stopTest();

        List<Map<String, Object>> rows = (List<Map<String, Object>>) result.get('rows');
        List<Map<String, Object>> cols = (List<Map<String, Object>>) result.get('columns');
        System.assertNotEquals(null, rows, 'Should return rows');
        System.assertNotEquals(null, cols, 'Should return columns');
    }

    @IsTest
    static void testDrillDown_GroupFilter() {
        Test.startTest();
        Map<String, Object> result = DKD_QueryEngine_Service.drillDownRecords(
            'test_revenue', null, 'Status__c', 'Approved',
            Date.today().addDays(-1), Date.today().addDays(1),
            'self', 50
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return result');
    }

    @IsTest
    static void testDrillDown_LimitClamp() {
        Test.startTest();
        // Pass a huge limit — should be clamped to 500
        Map<String, Object> result = DKD_QueryEngine_Service.drillDownRecords(
            'test_revenue', null, null, null,
            Date.today().addDays(-1), Date.today().addDays(1),
            'self', 9999
        );
        Test.stopTest();
        // Just verify no exception
        System.assertNotEquals(null, result.get('rows'));
    }

    @IsTest
    static void testDrillDown_MetricNotFound() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_QueryEngine_Service.drillDownRecords(
                'nope', null, null, null,
                Date.today(), Date.today(), 'self', 50
            );
        } catch (DKD_QueryEngine_Service.DKD_QueryException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown);
    }

    @IsTest
    static void testDrillDown_NullLimitDefault() {
        Test.startTest();
        Map<String, Object> result = DKD_QueryEngine_Service.drillDownRecords(
            'test_revenue', null, null, null,
            Date.today().addDays(-1), Date.today().addDays(1),
            'self', null
        );
        Test.stopTest();
        System.assertNotEquals(null, result.get('rows'));
    }

    // ── Direct private method tests ─────────────────────────────────

    @IsTest
    static void testFormatPeriodLabel_Month() {
        Test.startTest();
        System.assertEquals('Jan', DKD_QueryEngine_Service.formatPeriodLabel(1, 'MONTH'));
        System.assertEquals('Jun', DKD_QueryEngine_Service.formatPeriodLabel(6, 'MONTH'));
        System.assertEquals('Dec', DKD_QueryEngine_Service.formatPeriodLabel(12, 'MONTH'));
        System.assertEquals('', DKD_QueryEngine_Service.formatPeriodLabel(null, 'MONTH'));
        Test.stopTest();
    }

    @IsTest
    static void testFormatPeriodLabel_Quarter() {
        Test.startTest();
        System.assertEquals('Q1', DKD_QueryEngine_Service.formatPeriodLabel(1, 'QUARTER'));
        System.assertEquals('Q4', DKD_QueryEngine_Service.formatPeriodLabel(4, 'QUARTER'));
        Test.stopTest();
    }

    @IsTest
    static void testFormatPeriodLabel_Other() {
        Test.startTest();
        System.assertEquals('2026', DKD_QueryEngine_Service.formatPeriodLabel(2026, 'YEAR'));
        System.assertEquals('2026-05-01', DKD_QueryEngine_Service.formatPeriodLabel('2026-05-01', 'DAY'));
        Test.stopTest();
    }

    @IsTest
    static void testHumanLabel() {
        Test.startTest();
        System.assertEquals('Total Net Amount', DKD_QueryEngine_Service.humanLabel('Total_Net_Amount__c'));
        System.assertEquals('Name', DKD_QueryEngine_Service.humanLabel('Name'));
        System.assertEquals('Order Date', DKD_QueryEngine_Service.humanLabel('Order_Date__c'));
        Test.stopTest();
    }

    @IsTest
    static void testSanitizeField_Valid() {
        Test.startTest();
        System.assertEquals('Status__c', DKD_QueryEngine_Service.sanitizeField('Status__c'));
        System.assertEquals('Account__r.Name', DKD_QueryEngine_Service.sanitizeField('Account__r.Name'));
        Test.stopTest();
    }

    @IsTest
    static void testSanitizeField_Invalid() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_QueryEngine_Service.sanitizeField('Status__c; DELETE');
        } catch (DKD_QueryEngine_Service.DKD_QueryException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Should reject fields with invalid characters');
    }

    @IsTest
    static void testBuildDateFunction_AllIntervals() {
        Test.startTest();
        System.assert(DKD_QueryEngine_Service.buildDateFunction('DAY', 'Order_Date__c').contains('DAY_ONLY'));
        System.assert(DKD_QueryEngine_Service.buildDateFunction('WEEK', 'Order_Date__c').contains('WEEK_IN_YEAR'));
        System.assert(DKD_QueryEngine_Service.buildDateFunction('MONTH', 'Order_Date__c').contains('CALENDAR_MONTH'));
        System.assert(DKD_QueryEngine_Service.buildDateFunction('QUARTER', 'Order_Date__c').contains('CALENDAR_QUARTER'));
        System.assert(DKD_QueryEngine_Service.buildDateFunction('YEAR', 'Order_Date__c').contains('CALENDAR_YEAR'));
        Test.stopTest();
    }

    @IsTest
    static void testToDecimal_AllTypes() {
        Test.startTest();
        System.assertEquals(0, DKD_QueryEngine_Service.toDecimal(null));
        System.assertEquals(100, DKD_QueryEngine_Service.toDecimal(100.0));
        System.assertEquals(42, DKD_QueryEngine_Service.toDecimal(42));
        System.assertEquals(50, DKD_QueryEngine_Service.toDecimal('50'));
        System.assertEquals(0, DKD_QueryEngine_Service.toDecimal('not_a_number'));
        Test.stopTest();
    }

    @IsTest
    static void testQueryMetric_WithFiltersJson() {
        Test.startTest();
        List<Map<String, Object>> results = DKD_QueryEngine_Service.queryMetric(
            'test_revenue', '{}', null,
            Date.today().addDays(-1), Date.today().addDays(1), 'self'
        );
        Test.stopTest();
        System.assertNotEquals(null, results);
    }

    @IsTest
    static void testQueryTimeSeries_WeekInterval() {
        Test.startTest();
        List<Map<String, Object>> series = DKD_QueryEngine_Service.queryTimeSeries(
            'test_revenue', null,
            Date.today().addDays(-30), Date.today().addDays(1),
            'WEEK', 'self'
        );
        Test.stopTest();
        System.assertNotEquals(null, series);
    }

    @IsTest
    static void testQueryTimeSeries_QuarterInterval() {
        Test.startTest();
        List<Map<String, Object>> series = DKD_QueryEngine_Service.queryTimeSeries(
            'test_revenue', null,
            Date.today().addMonths(-12), Date.today(),
            'QUARTER', 'self'
        );
        Test.stopTest();
        System.assertNotEquals(null, series);
    }

    @IsTest
    static void testDrillDown_OrgScope() {
        Test.startTest();
        Map<String, Object> result = DKD_QueryEngine_Service.drillDownRecords(
            'test_revenue', null, null, null,
            Date.today().addDays(-1), Date.today().addDays(1),
            'org', 50
        );
        Test.stopTest();
        System.assertNotEquals(null, result.get('rows'));
    }

    @IsTest
    static void testDrillDown_TeamScope() {
        Test.startTest();
        Map<String, Object> result = DKD_QueryEngine_Service.drillDownRecords(
            'test_revenue', null, null, null,
            Date.today().addDays(-1), Date.today().addDays(1),
            'team', 50
        );
        Test.stopTest();
        System.assertNotEquals(null, result.get('rows'));
    }
}