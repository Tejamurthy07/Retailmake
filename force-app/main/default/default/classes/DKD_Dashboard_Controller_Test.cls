/**
 * @description Tests for DKD_Dashboard_Controller.
 */
@IsTest
private class DKD_Dashboard_Controller_Test {

    @TestSetup
    static void setup() {
        // Seed metrics
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
            Is_Active__c = true,
            Sort_Order__c = 1
        ));
        metrics.add(new KPI_Metric__c(
            Name = 'Test Count',
            Metric_Key__c = 'test_count',
            Label__c = 'Test Count',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'COUNT',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'Salesperson__c',
            Default_Filter__c = 'Status__c IN (\'Approved\',\'Delivered\')',
            Format__c = 'Number',
            Category__c = 'Sales',
            Is_Active__c = true,
            Sort_Order__c = 2
        ));
        insert metrics;

        // Seed territory
        Territory_Master__c terr = new Territory_Master__c(
            Name = 'Test Territory DKD',
            Territory_Code__c = 'TER-DKD-TEST',
            Is_Active__c = true
        );
        insert terr;
    }

    @IsTest
    static void testGetInitData() {
        Test.startTest();
        Map<String, Object> init = DKD_Dashboard_Controller.getInitData();
        Test.stopTest();

        System.assertNotEquals(null, init);
        System.assert(init.containsKey('metrics'), 'Should include metrics');
        System.assert(init.containsKey('categories'), 'Should include categories');
        System.assert(init.containsKey('territories'), 'Should include territories');
        System.assert(init.containsKey('currentUser'), 'Should include currentUser');
        System.assert(init.containsKey('defaultScope'), 'Should include defaultScope');
        System.assert(init.containsKey('defaultDateRange'), 'Should include defaultDateRange');
        System.assert(init.containsKey('defaultMetricKeys'), 'Should include defaultMetricKeys');

        List<Map<String, Object>> metrics = (List<Map<String, Object>>) init.get('metrics');
        System.assertEquals(2, metrics.size());

        List<Map<String, Object>> territories = (List<Map<String, Object>>) init.get('territories');
        System.assert(territories.size() >= 1);

        List<String> defaultKeys = (List<String>) init.get('defaultMetricKeys');
        System.assert(defaultKeys.size() > 0, 'Should pick at least one default Sales metric');
    }

    @IsTest
    static void testGetKpiValues() {
        Territory_Master__c ter = TestDataFactory.createAndInsertTerritory('DKD Territory', 'TER-DKD01');
        Account acc = new Account(Name = 'DKD Ctrl Test', Type = 'Distributor', Outlet_Type__c = 'Grocery', Territory__c = ter.Id, Channel__c = 'GT');
        insert acc;

        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        try {
            insert new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today(),
                Status__c = 'Approved',
                Salesperson__c = UserInfo.getUserId(),
                Territory__c = ter.Id,
                Total_Net_Amount__c = 7500
            );
        } finally {
            TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
        }

        Test.startTest();
        Map<String, Decimal> result = DKD_Dashboard_Controller.getKpiValues(
            new List<String>{ 'test_revenue', 'test_count' },
            null,
            Date.today().addDays(-1),
            Date.today().addDays(1),
            'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    @IsTest
    static void testGetMetricData() {
        Test.startTest();
        List<Map<String, Object>> rows = DKD_Dashboard_Controller.getMetricData(
            'test_revenue', null, null,
            Date.today().addYears(5), Date.today().addYears(5).addDays(1), 'self'
        );
        Test.stopTest();
        System.assertEquals(1, rows.size());
    }

    @IsTest
    static void testGetTimeSeries() {
        Test.startTest();
        List<Map<String, Object>> series = DKD_Dashboard_Controller.getTimeSeries(
            'test_revenue', null,
            Date.today().addMonths(-6), Date.today(), 'MONTH', 'self'
        );
        Test.stopTest();
        System.assertNotEquals(null, series);
    }

    @IsTest
    static void testGetPreviousPeriodValues() {
        Territory_Master__c ter2 = TestDataFactory.createAndInsertTerritory('DKD Territory2', 'TER-DKD02');
        Account acc = new Account(Name = 'DKD Prev Test', Type = 'Distributor', Outlet_Type__c = 'Grocery', Territory__c = ter2.Id, Channel__c = 'GT');
        insert acc;

        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        try {
            insert new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today().addDays(-15),
                Status__c = 'Approved',
                Salesperson__c = UserInfo.getUserId(),
                Territory__c = ter2.Id,
                Total_Net_Amount__c = 3000
            );
        } finally {
            TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
        }

        Test.startTest();
        Map<String, Decimal> prev = DKD_Dashboard_Controller.getPreviousPeriodValues(
            new List<String>{ 'test_revenue' },
            null,
            Date.today().addDays(-9),
            Date.today(),
            'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, prev, 'Result should not be null');
    }

    @IsTest
    static void testGetPreviousPeriodValues_NullDates() {
        Test.startTest();
        Map<String, Decimal> result = DKD_Dashboard_Controller.getPreviousPeriodValues(
            new List<String>{ 'test_revenue' }, null, null, null, 'self'
        );
        Test.stopTest();
        System.assertEquals(0, result.size(), 'Null dates should return empty map');
    }
}