/**
 * @description Top-level controller for the Dynamic KPI Dashboard LWC.
 *              Provides initialization context (metrics catalog, categories,
 *              territories, current user info) and a unified query wrapper
 *              that delegates to DKD_QueryEngine_Service.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class DKD_Dashboard_Controller {

    /**
     * @description Returns everything the dashboard LWC needs on initial load:
     *              metric catalog grouped by category, available categories,
     *              territories for the filter panel, and current user context.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getInitData() {
        Map<String, Object> data = new Map<String, Object>();

        // Metric catalog (grouped for the picker)
        List<Map<String, Object>> catalog = DKD_MetricRegistry.getCatalog();
        data.put('metrics', catalog);
        data.put('categories', DKD_MetricRegistry.getCategories());

        // Default metric keys (top Sales metrics) — shown when dashboard loads empty
        List<String> defaultKeys = new List<String>();
        for (Map<String, Object> m : catalog) {
            if ('Sales'.equals((String) m.get('category'))) {
                defaultKeys.add((String) m.get('key'));
                if (defaultKeys.size() >= 4) break;
            }
        }
        data.put('defaultMetricKeys', defaultKeys);

        // Territories for the filter panel
        List<Map<String, Object>> territories = new List<Map<String, Object>>();
        for (Territory_Master__c t : [
            SELECT Id, Name, Territory_Code__c
            FROM Territory_Master__c
            WHERE Is_Active__c = true
            ORDER BY Name ASC
            LIMIT 200
        ]) {
            Map<String, Object> entry = new Map<String, Object>();
            entry.put('id', t.Id);
            entry.put('name', t.Name);
            entry.put('code', t.Territory_Code__c);
            territories.add(entry);
        }
        data.put('territories', territories);

        // Current user context
        User u = [SELECT Id, Name, Email FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        Map<String, Object> userCtx = new Map<String, Object>();
        userCtx.put('id', u.Id);
        userCtx.put('name', u.Name);
        userCtx.put('email', u.Email);
        data.put('currentUser', userCtx);

        // Default user scope — team if the user has subordinates, otherwise self
        String defaultScope = 'self';
        Set<Id> team = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(UserInfo.getUserId());
        if (team != null && team.size() > 1) {
            defaultScope = 'team';
        }
        data.put('defaultScope', defaultScope);

        // Default date range (current month)
        Date today = Date.today();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);
        Date monthEnd = monthStart.addMonths(1).addDays(-1);
        Map<String, Object> defaultRange = new Map<String, Object>();
        defaultRange.put('from', monthStart);
        defaultRange.put('to', monthEnd);
        data.put('defaultDateRange', defaultRange);

        return data;
    }

    /**
     * @description Bulk query wrapper for KPI card grids. Delegates to
     *              DKD_QueryEngine_Service.queryMultipleMetrics() while exposing
     *              a single entry point for the LWC.
     */
    @AuraEnabled
    public static Map<String, Decimal> getKpiValues(
        List<String> metricKeys,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        return DKD_QueryEngine_Service.queryMultipleMetrics(
            metricKeys, filtersJson, dateFrom, dateTo, userScope
        );
    }

    /**
     * @description Single metric query with optional grouping (used by chart widgets).
     */
    @AuraEnabled
    public static List<Map<String, Object>> getMetricData(
        String metricKey,
        String filtersJson,
        String groupBy,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        return DKD_QueryEngine_Service.queryMetric(
            metricKey, filtersJson, groupBy, dateFrom, dateTo, userScope
        );
    }

    /**
     * @description Time series query for trend chart widgets.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getTimeSeries(
        String metricKey,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String interval,
        String userScope
    ) {
        return DKD_QueryEngine_Service.queryTimeSeries(
            metricKey, filtersJson, dateFrom, dateTo, interval, userScope
        );
    }

    /**
     * @description Returns the values from the previous period (same length,
     *              ending immediately before dateFrom). Useful for vs-previous
     *              comparisons on KPI cards.
     */
    @AuraEnabled
    public static Map<String, Decimal> getPreviousPeriodValues(
        List<String> metricKeys,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        if (dateFrom == null || dateTo == null) {
            return new Map<String, Decimal>();
        }
        Integer days = dateFrom.daysBetween(dateTo) + 1;
        Date prevEnd = dateFrom.addDays(-1);
        Date prevStart = prevEnd.addDays(-(days - 1));
        return DKD_QueryEngine_Service.queryMultipleMetrics(
            metricKeys, filtersJson, prevStart, prevEnd, userScope
        );
    }

    /**
     * @description Runs a forecast for the given metric using linear
     *              regression on historical time-series data. Returns the
     *              historical series plus N future projected periods with
     *              confidence intervals and an insight string.
     *
     * @param metricKey       Metric_Key__c of the KPI_Metric__c to forecast.
     * @param filtersJson     Optional filter JSON (TAM_FilterEngine format).
     * @param dateFrom        Start of historical window.
     * @param dateTo          End of historical window.
     * @param interval        DAY / WEEK / MONTH / QUARTER / YEAR.
     * @param forecastPeriods Number of future periods to project (default 6).
     * @param userScope       'self' | 'team' | 'org'.
     */
    @AuraEnabled
    public static Map<String, Object> getForecast(
        String metricKey,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String interval,
        Integer forecastPeriods,
        String userScope
    ) {
        return DKD_Forecast_Service.forecastMetric(
            metricKey, filtersJson, dateFrom, dateTo, interval, forecastPeriods, userScope
        );
    }

    /**
     * @description Returns the raw records behind a metric value, optionally
     *              filtered to a specific group key (e.g., "all Approved
     *              orders" or "all visits by Salesperson X"). Used by chart
     *              drill-down to show underlying data.
     *
     * @param metricKey   Metric_Key__c of the KPI_Metric__c.
     * @param filtersJson Optional user filter JSON.
     * @param groupBy     Optional field whose value the user clicked.
     * @param groupKey    The clicked value (e.g., "Approved") — null for no filter.
     * @param dateFrom    Start date.
     * @param dateTo      End date.
     * @param userScope   'self' | 'team' | 'org'.
     * @param recordLimit Max rows to return (default 100, max 500).
     */
    @AuraEnabled
    public static Map<String, Object> drillDown(
        String metricKey,
        String filtersJson,
        String groupBy,
        String groupKey,
        Date dateFrom,
        Date dateTo,
        String userScope,
        Integer recordLimit
    ) {
        if (recordLimit == null || recordLimit <= 0) recordLimit = 100;
        if (recordLimit > 500) recordLimit = 500;
        return DKD_QueryEngine_Service.drillDownRecords(
            metricKey, filtersJson, groupBy, groupKey, dateFrom, dateTo, userScope, recordLimit
        );
    }

    /**
     * @description Bundled multi-metric query for the smart insights engine.
     *              Returns current period, previous period, and same-period-
     *              last-year values in one call. Also returns anomaly flags
     *              when the current value deviates significantly from trend.
     */
    @AuraEnabled
    public static Map<String, Object> getInsights(
        List<String> metricKeys,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        return DKD_Insights_Service.generateInsights(
            metricKeys, filtersJson, dateFrom, dateTo, userScope
        );
    }
}