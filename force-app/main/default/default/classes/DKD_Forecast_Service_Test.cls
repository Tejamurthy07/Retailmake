/**
 * @description Tests for DKD_Forecast_Service.
 */
@IsTest
private class DKD_Forecast_Service_Test {

    // Helper: build a historical row map as returned by DKD_QueryEngine_Service.queryTimeSeries
    private static Map<String, Object> row(Integer periodIdx, String label, Decimal value) {
        Map<String, Object> r = new Map<String, Object>();
        r.put('period', periodIdx);
        r.put('label', label);
        r.put('value', value);
        r.put('count', 1);
        return r;
    }

    @IsTest
    static void testPerfectlyLinearSeries() {
        // y = 10x + 5 → slope 10, intercept 5, R² = 1
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 5),
            row(1, 'Feb', 15),
            row(2, 'Mar', 25),
            row(3, 'Apr', 35),
            row(4, 'May', 45)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 3);
        Test.stopTest();

        Decimal slope = (Decimal) result.get('slope');
        Decimal intercept = (Decimal) result.get('intercept');
        Decimal rSq = (Decimal) result.get('rSquared');

        System.assertEquals(10, slope, 'Slope should be 10');
        System.assertEquals(5, intercept, 'Intercept should be 5');
        System.assertEquals(1, rSq, 'R² should be 1 for perfectly linear data');

        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        System.assertEquals(3, forecast.size());
        // Next 3 points: x=5 → 55, x=6 → 65, x=7 → 75
        System.assertEquals(55, (Decimal) forecast[0].get('value'));
        System.assertEquals(65, (Decimal) forecast[1].get('value'));
        System.assertEquals(75, (Decimal) forecast[2].get('value'));
    }

    @IsTest
    static void testFlatSeries() {
        // All same value → slope 0, R² = 1 (perfect constant fit)
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 100),
            row(1, 'Feb', 100),
            row(2, 'Mar', 100),
            row(3, 'Apr', 100)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 3);
        Test.stopTest();

        System.assertEquals(0, (Decimal) result.get('slope'));
        System.assertEquals(100, (Decimal) result.get('intercept'));
        // All forecast points should be 100
        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        for (Map<String, Object> f : forecast) {
            System.assertEquals(100, (Decimal) f.get('value'));
        }
    }

    @IsTest
    static void testDecreasingSeries() {
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 100),
            row(1, 'Feb', 80),
            row(2, 'Mar', 60),
            row(3, 'Apr', 40)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 2);
        Test.stopTest();

        Decimal slope = (Decimal) result.get('slope');
        System.assert(slope < 0, 'Slope should be negative for decreasing series');

        // Next points should continue the downward trend
        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        Decimal firstForecast = (Decimal) forecast[0].get('value');
        System.assert(firstForecast < 40 || firstForecast == 20,
            'First forecast should be below the last historical value');
    }

    @IsTest
    static void testFloorsNegativeAtZero() {
        // Steep downtrend that would project negative values
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 30),
            row(1, 'Feb', 20),
            row(2, 'Mar', 10)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 5);
        Test.stopTest();

        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        for (Map<String, Object> f : forecast) {
            Decimal v = (Decimal) f.get('value');
            System.assert(v >= 0, 'Forecast values should never be negative');
        }
    }

    @IsTest
    static void testGrowthRateCalculation() {
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 100),
            row(1, 'Feb', 120),
            row(2, 'Mar', 140),
            row(3, 'Apr', 150)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 2);
        Test.stopTest();

        Decimal growth = (Decimal) result.get('growthRatePercent');
        // (150 - 100) / 100 * 100 = 50%
        System.assertEquals(50, growth);
    }

    @IsTest
    static void testConfidenceInterval() {
        // Noisy data to generate a non-zero standard error
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 100),
            row(1, 'Feb', 110),
            row(2, 'Mar', 105),
            row(3, 'Apr', 120),
            row(4, 'May', 115),
            row(5, 'Jun', 130)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 3);
        Test.stopTest();

        Decimal stdError = (Decimal) result.get('standardError');
        System.assert(stdError > 0, 'Standard error should be > 0 for noisy data');

        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        for (Map<String, Object> f : forecast) {
            Decimal value = (Decimal) f.get('value');
            Decimal upper = (Decimal) f.get('upper');
            Decimal lower = (Decimal) f.get('lower');
            System.assert(upper >= value, 'Upper bound >= predicted value');
            System.assert(lower <= value, 'Lower bound <= predicted value');
        }
    }

    @IsTest
    static void testInsufficientData() {
        // Only 1 point — cannot forecast
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 100)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 3);
        Test.stopTest();

        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        System.assertEquals(0, forecast.size(), 'Should not produce forecast from 1 point');
        String insight = (String) result.get('insight');
        System.assert(insight.contains('2'), 'Insight should mention needing 2+ points');
    }

    @IsTest
    static void testNullHistorical() {
        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(null, 3);
        Test.stopTest();

        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        System.assertEquals(0, forecast.size());
        System.assertEquals(0, (Decimal) result.get('slope'));
    }

    @IsTest
    static void testZeroForecastPeriods() {
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 100),
            row(1, 'Feb', 200)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 0);
        Test.stopTest();

        List<Map<String, Object>> forecast = (List<Map<String, Object>>) result.get('forecast');
        System.assertEquals(0, forecast.size());
    }

    @IsTest
    static void testInsightText() {
        List<Map<String, Object>> hist = new List<Map<String, Object>>{
            row(0, 'Jan', 100),
            row(1, 'Feb', 110),
            row(2, 'Mar', 120),
            row(3, 'Apr', 130)
        };

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecast(hist, 2);
        Test.stopTest();

        String insight = (String) result.get('insight');
        System.assert(insight.contains('increasing'), 'Insight should mention increasing trend');
        System.assert(insight.contains('R²='), 'Insight should include R² value');
    }

    @IsTest
    static void testForecastMetric_EndToEnd() {
        // Seed a metric + orders, then run full forecast
        insert new KPI_Metric__c(
            Name = 'Forecast Test',
            Metric_Key__c = 'forecast_test_metric',
            Label__c = 'Forecast Test',
            Source_Object__c = 'Sales_Order__c',
            Aggregation__c = 'SUM',
            Aggregate_Field__c = 'Total_Net_Amount__c',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'Salesperson__c',
            Default_Filter__c = 'Status__c IN (\'Approved\',\'Delivered\')',
            Format__c = 'Currency',
            Category__c = 'Sales',
            Is_Active__c = true
        );

        Territory_Master__c ter = TestDataFactory.createAndInsertTerritory('Forecast Territory', 'TER-FCST01');
        Account acc = new Account(Name = 'Forecast Test Account', Outlet_Type__c = 'Grocery', Territory__c = ter.Id, Channel__c = 'GT');
        insert acc;

        Id uid = UserInfo.getUserId();

        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        try {
            List<Sales_Order__c> orders = new List<Sales_Order__c>();
            for (Integer i = 0; i < 6; i++) {
                orders.add(new Sales_Order__c(
                    Account__c = acc.Id,
                    Order_Date__c = Date.today().addMonths(-i),
                    Status__c = 'Approved',
                    Salesperson__c = uid,
                    Territory__c = ter.Id,
                    Total_Net_Amount__c = 1000 + (i * 100)
                ));
            }
            insert orders;
        } finally {
            TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
        }

        Test.startTest();
        Map<String, Object> result = DKD_Forecast_Service.forecastMetric(
            'forecast_test_metric',
            null,
            Date.today().addMonths(-6),
            Date.today(),
            'MONTH',
            3,
            'self'
        );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.containsKey('historical'));
        System.assert(result.containsKey('forecast'));
        System.assert(result.containsKey('insight'));
    }
}