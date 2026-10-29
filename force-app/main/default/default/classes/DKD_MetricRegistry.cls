/**
 * @description Registry for KPI_Metric__c records used by the Dynamic KPI
 *              Dashboard. Provides cached lookups and a catalog endpoint for
 *              LWC consumption. Admins can create/edit metrics from the
 *              KPI Metrics tab without code changes.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class DKD_MetricRegistry {

    // ── Per-transaction cache ────────────────────────────────────────────────
    private static Map<String, KPI_Metric__c> metricByKeyCache;
    private static List<KPI_Metric__c> allMetricsCache;

    // ── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Returns all active KPI metrics ordered by Category then Sort Order.
     * @return List of KPI_Metric__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<KPI_Metric__c> getAllMetrics() {
        if (allMetricsCache != null) {
            return allMetricsCache;
        }
        allMetricsCache = [
            SELECT Id, Name, Metric_Key__c, Label__c, Description__c,
                   Source_Object__c, Aggregation__c, Aggregate_Field__c,
                   Date_Field__c, User_Field__c, Default_Filter__c,
                   Filters_JSON__c, Filter_Logic__c,
                   Format__c, Icon__c, Color__c, Category__c,
                   Allow_Forecast__c, Is_Active__c, Sort_Order__c
            FROM KPI_Metric__c
            WHERE Is_Active__c = true
            ORDER BY Category__c ASC, Sort_Order__c ASC NULLS LAST, Label__c ASC
        ];
        return allMetricsCache;
    }

    /**
     * @description Returns a single metric by its unique Metric_Key__c.
     * @param metricKey The unique key (e.g., revenue_total).
     * @return The matching KPI_Metric__c, or null if not found / inactive.
     */
    @AuraEnabled(cacheable=true)
    public static KPI_Metric__c getMetric(String metricKey) {
        if (String.isBlank(metricKey)) return null;
        ensureKeyCache();
        return metricByKeyCache.get(metricKey);
    }

    /**
     * @description Returns the metric catalog grouped by category, suitable
     *              for populating a metric picker dropdown in LWC. Each entry
     *              is a lightweight map to minimize payload size.
     * @return List of catalog entry maps with key/label/category/icon/format.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getCatalog() {
        List<Map<String, Object>> catalog = new List<Map<String, Object>>();
        for (KPI_Metric__c m : getAllMetrics()) {
            Map<String, Object> entry = new Map<String, Object>();
            entry.put('key', m.Metric_Key__c);
            entry.put('label', m.Label__c);
            entry.put('description', m.Description__c);
            entry.put('category', m.Category__c);
            entry.put('icon', m.Icon__c);
            entry.put('color', m.Color__c);
            entry.put('format', m.Format__c);
            entry.put('aggregation', m.Aggregation__c);
            entry.put('sourceObject', m.Source_Object__c);
            entry.put('allowForecast', m.Allow_Forecast__c);
            catalog.add(entry);
        }
        return catalog;
    }

    /**
     * @description Returns metrics filtered by category. Useful for grouping
     *              the picker UI by Sales / Visits / Collections etc.
     * @param category The Category__c value to filter by.
     * @return List of metric catalog entries in that category.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getMetricsByCategory(String category) {
        List<Map<String, Object>> filtered = new List<Map<String, Object>>();
        if (String.isBlank(category)) return filtered;
        for (Map<String, Object> entry : getCatalog()) {
            if (category.equals((String) entry.get('category'))) {
                filtered.add(entry);
            }
        }
        return filtered;
    }

    /**
     * @description Returns the list of distinct categories that have at least
     *              one active metric. Used to build the category filter in LWC.
     * @return Sorted list of category strings.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getCategories() {
        Set<String> unique = new Set<String>();
        for (KPI_Metric__c m : getAllMetrics()) {
            if (String.isNotBlank(m.Category__c)) {
                unique.add(m.Category__c);
            }
        }
        List<String> result = new List<String>(unique);
        result.sort();
        return result;
    }

    /**
     * @description Validates the configuration of a KPI metric record without
     *              executing a full query. Used by admin UI or triggers to
     *              catch misconfigured metrics early.
     * @param metric The KPI_Metric__c record to validate.
     * @return List of human-readable validation error messages (empty if valid).
     */
    public static List<String> validateMetric(KPI_Metric__c metric) {
        List<String> errors = new List<String>();
        if (metric == null) {
            errors.add('Metric record is null.');
            return errors;
        }
        if (String.isBlank(metric.Metric_Key__c)) {
            errors.add('Metric Key is required.');
        }
        if (String.isBlank(metric.Label__c)) {
            errors.add('Label is required.');
        }
        if (String.isBlank(metric.Source_Object__c)) {
            errors.add('Source Object is required.');
        }
        if (String.isBlank(metric.Aggregation__c)) {
            errors.add('Aggregation is required.');
        } else if (!metric.Aggregation__c.equals('COUNT') &&
                   String.isBlank(metric.Aggregate_Field__c)) {
            errors.add('Aggregate Field is required when Aggregation is ' + metric.Aggregation__c + '.');
        }
        if (String.isBlank(metric.Date_Field__c)) {
            errors.add('Date Field is required.');
        }
        // Verify source object exists in this org
        if (String.isNotBlank(metric.Source_Object__c)) {
            Schema.SObjectType sobj = Schema.getGlobalDescribe().get(metric.Source_Object__c);
            if (sobj == null) {
                errors.add('Source Object ' + metric.Source_Object__c + ' does not exist in this org.');
            } else {
                // Verify fields exist on the object
                Map<String, Schema.SObjectField> fields = sobj.getDescribe().fields.getMap();
                if (String.isNotBlank(metric.Date_Field__c) && !fields.containsKey(metric.Date_Field__c.toLowerCase())) {
                    errors.add('Date Field ' + metric.Date_Field__c + ' does not exist on ' + metric.Source_Object__c + '.');
                }
                if (String.isNotBlank(metric.Aggregate_Field__c) && !fields.containsKey(metric.Aggregate_Field__c.toLowerCase())) {
                    errors.add('Aggregate Field ' + metric.Aggregate_Field__c + ' does not exist on ' + metric.Source_Object__c + '.');
                }
                if (String.isNotBlank(metric.User_Field__c) && !fields.containsKey(metric.User_Field__c.toLowerCase())) {
                    errors.add('User Field ' + metric.User_Field__c + ' does not exist on ' + metric.Source_Object__c + '.');
                }
            }
        }
        return errors;
    }

    /**
     * @description Clears the per-transaction cache. Useful in tests when
     *              inserting new metric records within the same transaction.
     */
    public static void clearCache() {
        metricByKeyCache = null;
        allMetricsCache = null;
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private static void ensureKeyCache() {
        if (metricByKeyCache != null) return;
        metricByKeyCache = new Map<String, KPI_Metric__c>();
        for (KPI_Metric__c m : getAllMetrics()) {
            if (String.isNotBlank(m.Metric_Key__c)) {
                metricByKeyCache.put(m.Metric_Key__c, m);
            }
        }
    }
}