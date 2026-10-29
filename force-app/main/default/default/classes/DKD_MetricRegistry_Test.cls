/**
 * @description Tests for DKD_MetricRegistry.
 */
@IsTest
private class DKD_MetricRegistry_Test {

    @TestSetup
    static void setup() {
        List<KPI_Metric__c> metrics = new List<KPI_Metric__c>();
        metrics.add(new KPI_Metric__c(
            Name = 'Total Revenue',
            Metric_Key__c = 'revenue_total',
            Label__c = 'Total Revenue',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'SUM',
            Aggregate_Field__c = 'Total_Net_Amount__c',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'Salesperson__c',
            Default_Filter__c = 'Status__c IN (\'Approved\',\'Delivered\')',
            Format__c = 'Currency',
            Icon__c = 'utility:money',
            Color__c = '#0176d3',
            Category__c = 'Sales',
            Allow_Forecast__c = true,
            Is_Active__c = true,
            Sort_Order__c = 1
        ));
        metrics.add(new KPI_Metric__c(
            Name = 'Order Count',
            Metric_Key__c = 'order_count',
            Label__c = 'Order Count',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'COUNT',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'Salesperson__c',
            Format__c = 'Number',
            Icon__c = 'standard:orders',
            Color__c = '#2e844a',
            Category__c = 'Sales',
            Is_Active__c = true,
            Sort_Order__c = 2
        ));
        metrics.add(new KPI_Metric__c(
            Name = 'Inactive Metric',
            Metric_Key__c = 'inactive_metric',
            Label__c = 'Should Not Appear',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'COUNT',
            Date_Field__c = 'Order_Date__c',
            Format__c = 'Number',
            Category__c = 'Custom',
            Is_Active__c = false
        ));
        insert metrics;
    }

    @IsTest
    static void testGetAllMetrics() {
        Test.startTest();
        List<KPI_Metric__c> result = DKD_MetricRegistry.getAllMetrics();
        Test.stopTest();

        System.assertEquals(2, result.size(), 'Should return only active metrics');
        // Verify ordering: Sales category comes first (alphabetical)
        System.assertEquals('Sales', result[0].Category__c);
    }

    @IsTest
    static void testGetMetricByKey() {
        Test.startTest();
        KPI_Metric__c metric = DKD_MetricRegistry.getMetric('revenue_total');
        KPI_Metric__c missing = DKD_MetricRegistry.getMetric('nonexistent');
        KPI_Metric__c blank = DKD_MetricRegistry.getMetric('');
        Test.stopTest();

        System.assertNotEquals(null, metric, 'revenue_total should be found');
        System.assertEquals('Total Revenue', metric.Label__c);
        System.assertEquals('SUM', metric.Aggregation__c);
        System.assertEquals(null, missing, 'nonexistent should return null');
        System.assertEquals(null, blank, 'blank key should return null');
    }

    @IsTest
    static void testGetMetricIgnoresInactive() {
        Test.startTest();
        KPI_Metric__c metric = DKD_MetricRegistry.getMetric('inactive_metric');
        Test.stopTest();
        System.assertEquals(null, metric, 'Inactive metrics should not be returned');
    }

    @IsTest
    static void testGetCatalog() {
        Test.startTest();
        List<Map<String, Object>> catalog = DKD_MetricRegistry.getCatalog();
        Test.stopTest();

        System.assertEquals(2, catalog.size(), 'Catalog should have 2 active entries');
        Map<String, Object> first = catalog[0];
        System.assert(first.containsKey('key'), 'Entry should have key');
        System.assert(first.containsKey('label'), 'Entry should have label');
        System.assert(first.containsKey('category'), 'Entry should have category');
        System.assert(first.containsKey('format'), 'Entry should have format');
    }

    @IsTest
    static void testGetMetricsByCategory() {
        Test.startTest();
        List<Map<String, Object>> sales = DKD_MetricRegistry.getMetricsByCategory('Sales');
        List<Map<String, Object>> empty = DKD_MetricRegistry.getMetricsByCategory('Inventory');
        List<Map<String, Object>> blank = DKD_MetricRegistry.getMetricsByCategory('');
        Test.stopTest();

        System.assertEquals(2, sales.size(), 'Sales category should have 2 metrics');
        System.assertEquals(0, empty.size(), 'Inventory category should have 0 metrics');
        System.assertEquals(0, blank.size(), 'Blank category should return empty list');
    }

    @IsTest
    static void testGetCategories() {
        Test.startTest();
        List<String> categories = DKD_MetricRegistry.getCategories();
        Test.stopTest();

        System.assertEquals(1, categories.size(), 'Only Sales category should be present (Custom is inactive)');
        System.assertEquals('Sales', categories[0]);
    }

    @IsTest
    static void testValidateMetric_Valid() {
        KPI_Metric__c valid = new KPI_Metric__c(
            Metric_Key__c = 'test_valid',
            Label__c = 'Test Valid',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'SUM',
            Aggregate_Field__c = 'Total_Net_Amount__c',
            Date_Field__c = 'Order_Date__c'
        );
        Test.startTest();
        List<String> errors = DKD_MetricRegistry.validateMetric(valid);
        Test.stopTest();
        System.assertEquals(0, errors.size(), 'Valid metric should have no errors');
    }

    @IsTest
    static void testValidateMetric_MissingFields() {
        KPI_Metric__c invalid = new KPI_Metric__c();
        Test.startTest();
        List<String> errors = DKD_MetricRegistry.validateMetric(invalid);
        Test.stopTest();
        System.assert(errors.size() >= 4, 'Should report multiple missing-field errors');
    }

    @IsTest
    static void testValidateMetric_NullInput() {
        Test.startTest();
        List<String> errors = DKD_MetricRegistry.validateMetric(null);
        Test.stopTest();
        System.assertEquals(1, errors.size());
        System.assert(errors[0].contains('null'));
    }

    @IsTest
    static void testValidateMetric_SumWithoutField() {
        KPI_Metric__c invalid = new KPI_Metric__c(
            Metric_Key__c = 'test_sum',
            Label__c = 'Test',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'SUM',
            Date_Field__c = 'Order_Date__c'
            // Aggregate_Field__c intentionally missing
        );
        Test.startTest();
        List<String> errors = DKD_MetricRegistry.validateMetric(invalid);
        Test.stopTest();
        Boolean foundFieldError = false;
        for (String e : errors) {
            if (e.contains('Aggregate Field')) { foundFieldError = true; break; }
        }
        System.assert(foundFieldError, 'Should flag missing aggregate field for SUM');
    }

    @IsTest
    static void testValidateMetric_BadSourceObject() {
        KPI_Metric__c invalid = new KPI_Metric__c(
            Metric_Key__c = 'test_bad',
            Label__c = 'Test',
            Source_Object__c = 'Nonexistent_Object__c',
            Aggregation__c = 'COUNT',
            Date_Field__c = 'CreatedDate'
        );
        Test.startTest();
        List<String> errors = DKD_MetricRegistry.validateMetric(invalid);
        Test.stopTest();
        Boolean foundObjectError = false;
        for (String e : errors) {
            if (e.contains('does not exist')) { foundObjectError = true; break; }
        }
        System.assert(foundObjectError, 'Should flag bad source object');
    }

    @IsTest
    static void testClearCache() {
        DKD_MetricRegistry.getAllMetrics(); // populate cache
        DKD_MetricRegistry.clearCache();
        // After clearing, next call should re-query without error
        Test.startTest();
        List<KPI_Metric__c> result = DKD_MetricRegistry.getAllMetrics();
        Test.stopTest();
        System.assertEquals(2, result.size());
    }
}