/**
 * @description Test class for DKD_MetricManager_Controller.
 *              Validates getQueryableObjects, getObjectFields, getAllMetrics,
 *              saveMetric, and deleteMetric methods.
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class DKD_MetricManager_Controller_Test {

    @TestSetup
    static void setupTestData() {
        // Create KPI Metrics for testing
        List<KPI_Metric__c> metrics = new List<KPI_Metric__c>{
            new KPI_Metric__c(
                Name = 'Revenue Total',
                Metric_Key__c = 'revenue_total',
                Label__c = 'Total Revenue',
                Description__c = 'Total revenue from sales orders',
                Source_Object__c = 'Sales_Order__c',
                Aggregation__c = 'SUM',
                Aggregate_Field__c = 'Total_Net_Amount__c',
                Date_Field__c = 'Order_Date__c',
                User_Field__c = 'Salesperson__c',
                Format__c = 'Currency',
                Icon__c = 'standard:opportunity',
                Color__c = '#4CAF50',
                Category__c = 'Sales',
                Is_Active__c = true,
                Sort_Order__c = 1
            ),
            new KPI_Metric__c(
                Name = 'Visit Count',
                Metric_Key__c = 'visit_count',
                Label__c = 'Total Visits',
                Description__c = 'Total visit count',
                Source_Object__c = 'Visit__c',
                Aggregation__c = 'COUNT',
                Date_Field__c = 'Visit_Date__c',
                User_Field__c = 'Salesperson__c',
                Format__c = 'Number',
                Icon__c = 'standard:visit',
                Color__c = '#2196F3',
                Category__c = 'Activity',
                Is_Active__c = true,
                Sort_Order__c = 2
            )
        };
        insert metrics;
    }

    // ── getQueryableObjects: returns accessible objects ──────────────────────

    @IsTest
    static void testGetQueryableObjects() {
        Test.startTest();
        List<Map<String, String>> objects = DKD_MetricManager_Controller.getQueryableObjects();
        Test.stopTest();

        System.assert(!objects.isEmpty(), 'Should return at least some queryable objects');

        // Verify structure
        Map<String, String> firstObj = objects[0];
        System.assert(firstObj.containsKey('api'), 'Each object should have api name');
        System.assert(firstObj.containsKey('label'), 'Each object should have label');

        // Verify known objects appear (Account is standard, always accessible)
        Set<String> apiNames = new Set<String>();
        for (Map<String, String> obj : objects) {
            apiNames.add(obj.get('api'));
        }
        System.assert(apiNames.contains('Account'), 'Account should be in the list');
    }

    // ── getObjectFields: valid object returns field categories ───────────────

    @IsTest
    static void testGetObjectFieldsValid() {
        Test.startTest();
        Map<String, Object> result = DKD_MetricManager_Controller.getObjectFields('Account');
        Test.stopTest();

        System.assert(result.containsKey('dateFields'), 'Result should contain dateFields');
        System.assert(result.containsKey('numberFields'), 'Result should contain numberFields');
        System.assert(result.containsKey('userFields'), 'Result should contain userFields');

        // Account should have at least some date fields (CreatedDate, etc.)
        List<Object> dateFields = (List<Object>) result.get('dateFields');
        System.assert(!dateFields.isEmpty(), 'Account should have date fields');
    }

    // ── getObjectFields: blank object returns empty map ─────────────────────

    @IsTest
    static void testGetObjectFieldsBlank() {
        Test.startTest();
        Map<String, Object> result = DKD_MetricManager_Controller.getObjectFields('');
        Test.stopTest();

        System.assert(result.isEmpty(), 'Blank object name should return empty map');
    }

    // ── getObjectFields: invalid object returns empty map ───────────────────

    @IsTest
    static void testGetObjectFieldsInvalid() {
        Test.startTest();
        Map<String, Object> result = DKD_MetricManager_Controller.getObjectFields('NonExistentObject__c');
        Test.stopTest();

        System.assert(result.isEmpty(), 'Invalid object should return empty map');
    }

    // ── getAllMetrics: returns all metrics ───────────────────────────────────

    @IsTest
    static void testGetAllMetrics() {
        Test.startTest();
        List<KPI_Metric__c> metrics = DKD_MetricManager_Controller.getAllMetrics();
        Test.stopTest();

        System.assertEquals(2, metrics.size(), 'Should return 2 metrics from test setup');

        // Verify fields are populated
        KPI_Metric__c first = metrics[0];
        System.assertNotEquals(null, first.Metric_Key__c, 'Metric Key should be populated');
        System.assertNotEquals(null, first.Label__c, 'Label should be populated');
    }

    // ── saveMetric: insert new metric ───────────────────────────────────────

    @IsTest
    static void testSaveMetricInsert() {
        KPI_Metric__c newMetric = new KPI_Metric__c(
            Name = 'Collection Total',
            Metric_Key__c = 'collection_total',
            Label__c = 'Total Collection',
            Source_Object__c = 'Collection__c',
            Aggregation__c = 'SUM',
            Aggregate_Field__c = 'Amount__c',
            Date_Field__c = 'Collection_Date__c',
            User_Field__c = 'OwnerId',
            Format__c = 'Currency',
            Category__c = 'Finance',
            Is_Active__c = true
        );

        Test.startTest();
        KPI_Metric__c saved = DKD_MetricManager_Controller.saveMetric(newMetric);
        Test.stopTest();

        System.assertNotEquals(null, saved.Id, 'Saved metric should have an Id');

        List<KPI_Metric__c> all = [SELECT Id FROM KPI_Metric__c];
        System.assertEquals(3, all.size(), 'Should now have 3 metrics total');
    }

    // ── saveMetric: update existing metric ──────────────────────────────────

    @IsTest
    static void testSaveMetricUpdate() {
        KPI_Metric__c existing = [SELECT Id, Metric_Key__c, Label__c, Source_Object__c, Aggregation__c, Aggregate_Field__c, Date_Field__c, User_Field__c, Format__c, Category__c, Default_Filter__c, Allow_Forecast__c, Is_Active__c FROM KPI_Metric__c WHERE Metric_Key__c = 'revenue_total' LIMIT 1];
        existing.Label__c = 'Updated Revenue Label';

        Test.startTest();
        KPI_Metric__c saved = DKD_MetricManager_Controller.saveMetric(existing);
        Test.stopTest();

        KPI_Metric__c refreshed = [SELECT Label__c FROM KPI_Metric__c WHERE Id = :saved.Id];
        System.assertEquals('Updated Revenue Label', refreshed.Label__c, 'Label should be updated');
    }

    // ── saveMetric: invalid metric throws exception ─────────────────────────

    @IsTest
    static void testSaveMetricInvalid() {
        KPI_Metric__c invalid = new KPI_Metric__c(
            Name = 'Invalid Metric'
            // Missing required fields: Metric_Key__c, Label__c, Source_Object__c, Aggregation__c, Date_Field__c
        );

        Test.startTest();
        try {
            DKD_MetricManager_Controller.saveMetric(invalid);
            System.assert(false, 'Expected AuraHandledException for invalid metric');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    // ── deleteMetric: removes metric ────────────────────────────────────────

    @IsTest
    static void testDeleteMetric() {
        KPI_Metric__c toDelete = [SELECT Id FROM KPI_Metric__c WHERE Metric_Key__c = 'visit_count' LIMIT 1];

        Test.startTest();
        DKD_MetricManager_Controller.deleteMetric(toDelete.Id);
        Test.stopTest();

        List<KPI_Metric__c> remaining = [SELECT Id FROM KPI_Metric__c];
        System.assertEquals(1, remaining.size(), 'Should have 1 metric after deletion');
    }

    // ── getObjectFields: custom object with known fields ────────────────────

    @IsTest
    static void testGetObjectFieldsCustomObject() {
        Test.startTest();
        Map<String, Object> result = DKD_MetricManager_Controller.getObjectFields('Sales_Order__c');
        Test.stopTest();

        if (!result.isEmpty()) {
            System.assert(result.containsKey('dateFields'), 'Should have dateFields for Sales_Order__c');
            System.assert(result.containsKey('numberFields'), 'Should have numberFields for Sales_Order__c');
        }
    }
}