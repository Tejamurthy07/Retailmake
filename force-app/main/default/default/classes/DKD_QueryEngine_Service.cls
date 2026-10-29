/**
 * @description Executes KPI_Metric__c definitions against live data. Given a
 *              metric key plus filters, date range, and user scope, builds a
 *              dynamic SOQL query and returns aggregated results suitable for
 *              the Dynamic KPI Dashboard (KPI cards, charts, tables).
 *
 *              Depends on:
 *              - DKD_MetricRegistry for metric definitions
 *              - TAM_FilterEngine_Service for filter WHERE clauses
 *              - TAM_RoleHierarchy_Service for team/org user scoping
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class DKD_QueryEngine_Service {

    // ── Constants ────────────────────────────────────────────────────────────
    private static final Set<String> ALLOWED_AGGREGATIONS = new Set<String>{
        'COUNT', 'SUM', 'AVG', 'MIN', 'MAX'
    };
    private static final Set<String> TIME_INTERVALS = new Set<String>{
        'DAY', 'WEEK', 'MONTH', 'QUARTER', 'YEAR'
    };

    // ── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Executes a single metric with optional grouping. Returns a
     *              list of {label, value, count, rawValue} rows. When groupBy
     *              is blank, returns exactly one row (the grand total).
     *
     * @param metricKey     Metric_Key__c of the KPI_Metric__c to run.
     * @param filtersJson   Optional JSON filters (TAM_FilterEngine format).
     * @param groupBy       Optional field to group by (e.g., Salesperson__c).
     * @param dateFrom      Start date (inclusive).
     * @param dateTo        End date (inclusive).
     * @param userScope     'self' | 'team' | 'org' (default 'self').
     * @return List of result rows.
     */
    @AuraEnabled
    public static List<Map<String, Object>> queryMetric(
        String metricKey,
        String filtersJson,
        String groupBy,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        KPI_Metric__c metric = DKD_MetricRegistry.getMetric(metricKey);
        if (metric == null) {
            throw new DKD_QueryException('Metric not found or inactive: ' + metricKey);
        }

        String query = buildQuery(metric, filtersJson, groupBy, dateFrom, dateTo, userScope);
        List<AggregateResult> results;
        try {
            results = Database.query(query);
        } catch (Exception e) {
            throw new DKD_QueryException(
                'Query failed for metric ' + metricKey + ': ' + e.getMessage() +
                ' (SOQL: ' + query + ')'
            );
        }

        return formatResults(results, metric, groupBy);
    }

    /**
     * @description Runs multiple metrics with the same filter set and returns
     *              a map of metric key → scalar total. Optimized for KPI card
     *              grids where one filter applies to many cards at once.
     *
     * @param metricKeys   List of Metric_Key__c values.
     * @param filtersJson  Shared filter JSON (optional).
     * @param dateFrom     Start date.
     * @param dateTo       End date.
     * @param userScope    'self' | 'team' | 'org'.
     * @return Map of metricKey → aggregated value.
     */
    @AuraEnabled
    public static Map<String, Decimal> queryMultipleMetrics(
        List<String> metricKeys,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        Map<String, Decimal> results = new Map<String, Decimal>();
        if (metricKeys == null || metricKeys.isEmpty()) return results;

        for (String key : metricKeys) {
            try {
                List<Map<String, Object>> rows = queryMetric(
                    key, filtersJson, null, dateFrom, dateTo, userScope
                );
                Decimal total = 0;
                if (!rows.isEmpty()) {
                    total = toDecimal(rows[0].get('value'));
                }
                results.put(key, total);
            } catch (Exception e) {
                // Fail-soft: don't let one bad metric break the whole dashboard
                System.debug(LoggingLevel.WARN, 'Metric ' + key + ' failed: ' + e.getMessage());
                results.put(key, 0);
            }
        }
        return results;
    }

    /**
     * @description Safely converts an Object (Integer, Long, Double, Decimal,
     *              or numeric String) to Decimal. Handles the case where
     *              AggregateResult.get(alias) returns Integer for COUNT and
     *              Decimal for SUM/AVG/MIN/MAX.
     */
    @TestVisible
    private static Decimal toDecimal(Object value) {
        if (value == null) return 0;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf((Integer) value);
        if (value instanceof Long) return Decimal.valueOf((Long) value);
        if (value instanceof Double) return Decimal.valueOf((Double) value);
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return 0;
        }
    }

    /**
     * @description Returns a time series for a metric, grouped by calendar
     *              interval (DAY / WEEK / MONTH / QUARTER / YEAR). Used by
     *              trend line charts and forecast widgets.
     *
     * @param metricKey   Metric_Key__c of the KPI_Metric__c.
     * @param filtersJson Optional filter JSON.
     * @param dateFrom    Start date.
     * @param dateTo      End date.
     * @param interval    DAY / WEEK / MONTH / QUARTER / YEAR.
     * @param userScope   'self' | 'team' | 'org'.
     * @return Ordered list of {label, value, period} rows.
     */
    @AuraEnabled
    public static List<Map<String, Object>> queryTimeSeries(
        String metricKey,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String interval,
        String userScope
    ) {
        KPI_Metric__c metric = DKD_MetricRegistry.getMetric(metricKey);
        if (metric == null) {
            throw new DKD_QueryException('Metric not found or inactive: ' + metricKey);
        }

        String tInterval = String.isBlank(interval) ? 'MONTH' : interval.toUpperCase();
        if (!TIME_INTERVALS.contains(tInterval)) {
            throw new DKD_QueryException('Invalid time interval: ' + tInterval);
        }

        String dateFunc = buildDateFunction(tInterval, metric.Date_Field__c);
        String aggExpr = buildAggregateExpression(metric);

        String whereClause = buildWhereClause(metric, filtersJson, dateFrom, dateTo, userScope);

        String query = 'SELECT ' + dateFunc + ' period, ' + aggExpr + ' aggValue, COUNT(Id) rowCount ' +
                       'FROM ' + metric.Source_Object__c + ' ' +
                       'WHERE ' + whereClause + ' ' +
                       'GROUP BY ' + dateFunc + ' ' +
                       'ORDER BY ' + dateFunc + ' ASC ' +
                       'LIMIT 2000';

        List<AggregateResult> results;
        try {
            results = Database.query(query);
        } catch (Exception e) {
            throw new DKD_QueryException(
                'Time series query failed: ' + e.getMessage() + ' (SOQL: ' + query + ')'
            );
        }

        List<Map<String, Object>> output = new List<Map<String, Object>>();
        for (AggregateResult ar : results) {
            Map<String, Object> row = new Map<String, Object>();
            Object periodVal = ar.get('period');
            row.put('period', periodVal);
            row.put('label', formatPeriodLabel(periodVal, tInterval));
            Object val = ar.get('aggValue');
            row.put('value', val != null ? val : 0);
            row.put('count', ar.get('rowCount'));
            output.add(row);
        }
        return output;
    }

    // ── Query Building ───────────────────────────────────────────────────────

    private static String buildQuery(
        KPI_Metric__c metric,
        String filtersJson,
        String groupBy,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        String aggExpr = buildAggregateExpression(metric);
        String whereClause = buildWhereClause(metric, filtersJson, dateFrom, dateTo, userScope);

        String selectClause;
        String groupByClause = '';

        if (String.isBlank(groupBy)) {
            selectClause = 'SELECT ' + aggExpr + ' aggValue, COUNT(Id) rowCount';
        } else {
            String safeGroupBy = sanitizeField(groupBy);
            selectClause = 'SELECT ' + safeGroupBy + ' groupKey, ' + aggExpr + ' aggValue, COUNT(Id) rowCount';
            groupByClause = ' GROUP BY ' + safeGroupBy;
        }

        // LIMIT only allowed on grouped aggregate queries
        String limitClause = String.isNotBlank(groupByClause) ? ' LIMIT 2000' : '';

        return selectClause +
               ' FROM ' + metric.Source_Object__c +
               ' WHERE ' + whereClause +
               groupByClause +
               limitClause;
    }

    private static String buildAggregateExpression(KPI_Metric__c metric) {
        String agg = metric.Aggregation__c != null ? metric.Aggregation__c.toUpperCase() : 'COUNT';
        if (!ALLOWED_AGGREGATIONS.contains(agg)) {
            throw new DKD_QueryException('Unsupported aggregation: ' + agg);
        }
        if (agg == 'COUNT') {
            return 'COUNT(Id)';
        }
        if (String.isBlank(metric.Aggregate_Field__c)) {
            throw new DKD_QueryException(
                'Aggregate Field required for ' + agg + ' on metric ' + metric.Metric_Key__c
            );
        }
        return agg + '(' + sanitizeField(metric.Aggregate_Field__c) + ')';
    }

    private static String buildWhereClause(
        KPI_Metric__c metric,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        List<String> clauses = new List<String>();

        // 1. Date range filter (always applied)
        String dateField = sanitizeField(metric.Date_Field__c);
        Boolean isDateTimeField = isDateTimeType(metric.Source_Object__c, metric.Date_Field__c);
        if (dateFrom != null) {
            clauses.add(dateField + ' >= ' + formatDateLiteral(dateFrom, isDateTimeField));
        }
        if (dateTo != null) {
            clauses.add(dateField + ' <= ' + formatDateLiteral(dateTo, isDateTimeField));
        }

        // 2. Metric default filter (from KPI_Metric__c.Default_Filter__c)
        if (String.isNotBlank(metric.Default_Filter__c)) {
            clauses.add('(' + metric.Default_Filter__c + ')');
        }

        // 2b. Structured metric filters (from Filters_JSON__c + Filter_Logic__c)
        if (String.isNotBlank(metric.Filters_JSON__c)) {
            String metricFilterWhere = TAM_FilterEngine_Service.buildWhereClause(
                metric.Filters_JSON__c, metric.Filter_Logic__c
            );
            if (String.isNotBlank(metricFilterWhere)) {
                clauses.add('(' + metricFilterWhere + ')');
            }
        }

        // 3. User-provided filters (JSON)
        if (String.isNotBlank(filtersJson)) {
            String filterWhere = TAM_FilterEngine_Service.buildWhereClause(filtersJson, null);
            if (String.isNotBlank(filterWhere)) {
                clauses.add(filterWhere);
            }
        }

        // 4. User scope filter (self / team / org)
        String scopeClause = buildUserScopeClause(metric, userScope);
        if (String.isNotBlank(scopeClause)) {
            clauses.add(scopeClause);
        }

        return clauses.isEmpty() ? 'Id != null' : String.join(clauses, ' AND ');
    }

    private static String buildUserScopeClause(KPI_Metric__c metric, String userScope) {
        if (String.isBlank(metric.User_Field__c)) return '';
        String scope = String.isBlank(userScope) ? 'self' : userScope.toLowerCase();
        String userField = sanitizeField(metric.User_Field__c);
        Id currentUserId = UserInfo.getUserId();

        if (scope == 'org') {
            return ''; // No user filter
        }
        if (scope == 'team') {
            Set<Id> teamUserIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(currentUserId);
            if (teamUserIds.isEmpty()) {
                return userField + ' = \'' + currentUserId + '\'';
            }
            List<String> quotedIds = new List<String>();
            for (Id uid : teamUserIds) {
                quotedIds.add('\'' + uid + '\'');
            }
            return userField + ' IN (' + String.join(quotedIds, ',') + ')';
        }
        // Default: self
        return userField + ' = \'' + currentUserId + '\'';
    }

    // ── Time Series Helpers ──────────────────────────────────────────────────

    @TestVisible
    private static String buildDateFunction(String interval, String dateField) {
        String safeField = sanitizeField(dateField);
        if (interval == 'DAY') return 'DAY_ONLY(' + safeField + ')';
        if (interval == 'WEEK') return 'WEEK_IN_YEAR(' + safeField + ')';
        if (interval == 'MONTH') return 'CALENDAR_MONTH(' + safeField + ')';
        if (interval == 'QUARTER') return 'CALENDAR_QUARTER(' + safeField + ')';
        if (interval == 'YEAR') return 'CALENDAR_YEAR(' + safeField + ')';
        return 'CALENDAR_MONTH(' + safeField + ')';
    }

    @TestVisible
    private static String formatPeriodLabel(Object periodVal, String interval) {
        if (periodVal == null) return '';
        String raw = String.valueOf(periodVal);
        if (interval == 'MONTH') {
            List<String> monthNames = new List<String>{
                '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
            };
            try {
                Integer m = Integer.valueOf(raw);
                if (m >= 1 && m <= 12) return monthNames[m];
            } catch (Exception e) { /* fall through */ }
        }
        if (interval == 'QUARTER') {
            return 'Q' + raw;
        }
        return raw;
    }

    // ── Result Formatting ────────────────────────────────────────────────────

    private static List<Map<String, Object>> formatResults(
        List<AggregateResult> results,
        KPI_Metric__c metric,
        String groupBy
    ) {
        List<Map<String, Object>> output = new List<Map<String, Object>>();
        if (results == null || results.isEmpty()) {
            Map<String, Object> empty = new Map<String, Object>();
            empty.put('label', metric.Label__c);
            empty.put('value', 0);
            empty.put('count', 0);
            output.add(empty);
            return output;
        }

        // Collect group keys to resolve lookup IDs to names
        Set<Id> lookupIds = new Set<Id>();
        Boolean isLookupGroup = String.isNotBlank(groupBy);

        for (AggregateResult ar : results) {
            if (isLookupGroup) {
                Object gk = ar.get('groupKey');
                if (gk != null) {
                    try {
                        lookupIds.add((Id) gk);
                    } catch (Exception e) {
                        isLookupGroup = false;
                    }
                }
            }
        }

        Map<Id, String> nameMap = new Map<Id, String>();
        if (isLookupGroup && !lookupIds.isEmpty()) {
            nameMap = resolveLookupNames(lookupIds);
        }

        for (AggregateResult ar : results) {
            Map<String, Object> row = new Map<String, Object>();
            Object val = ar.get('aggValue');
            Object rowCount = ar.get('rowCount');

            row.put('value', val != null ? val : 0);
            row.put('count', rowCount != null ? rowCount : 0);

            if (String.isBlank(groupBy)) {
                row.put('label', metric.Label__c);
                row.put('groupKey', null);
            } else {
                Object groupKey = ar.get('groupKey');
                row.put('groupKey', groupKey);
                String label = groupKey != null ? String.valueOf(groupKey) : '(blank)';
                if (groupKey instanceof Id && nameMap.containsKey((Id) groupKey)) {
                    label = nameMap.get((Id) groupKey);
                }
                row.put('label', label);
            }
            output.add(row);
        }
        return output;
    }

    private static Map<Id, String> resolveLookupNames(Set<Id> recordIds) {
        Map<Id, String> nameMap = new Map<Id, String>();
        if (recordIds.isEmpty()) return nameMap;

        Id sampleId = new List<Id>(recordIds)[0];
        String objectName = sampleId.getSObjectType().getDescribe().getName();

        try {
            String soql = 'SELECT Id, Name FROM ' + String.escapeSingleQuotes(objectName) +
                          ' WHERE Id IN :recordIds';
            for (SObject rec : Database.query(soql)) {
                nameMap.put(rec.Id, (String) rec.get('Name'));
            }
        } catch (Exception e) {
            // Object may not have a Name field — fall back to IDs
        }
        return nameMap;
    }

    // ── Drill-Down ───────────────────────────────────────────────────────────

    /**
     * @description Fetches the raw records behind a metric value with all
     *              the metric's filters applied, optionally narrowed to a
     *              single group key. Returns a list of row maps plus column
     *              metadata for rendering a drill-down table.
     */
    public static Map<String, Object> drillDownRecords(
        String metricKey,
        String filtersJson,
        String groupBy,
        String groupKey,
        Date dateFrom,
        Date dateTo,
        String userScope,
        Integer recordLimit
    ) {
        KPI_Metric__c metric = DKD_MetricRegistry.getMetric(metricKey);
        if (metric == null) {
            throw new DKD_QueryException('Metric not found: ' + metricKey);
        }

        // Build a safe SELECT list based on the source object
        List<String> fieldList = buildDrillDownFieldList(metric);
        String whereClause = buildWhereClause(metric, filtersJson, dateFrom, dateTo, userScope);

        // Add groupKey narrow filter if present
        if (String.isNotBlank(groupBy) && groupKey != null) {
            String safeGroupBy = sanitizeField(groupBy);
            if (groupKey == '(blank)' || groupKey == '') {
                whereClause += ' AND ' + safeGroupBy + ' = null';
            } else {
                String safeValue = String.escapeSingleQuotes(groupKey);
                whereClause += ' AND ' + safeGroupBy + ' = \'' + safeValue + '\'';
            }
        }

        String orderBy = String.isNotBlank(metric.Date_Field__c)
            ? ' ORDER BY ' + sanitizeField(metric.Date_Field__c) + ' DESC'
            : '';

        Integer safeLimit = (recordLimit != null && recordLimit > 0 && recordLimit <= 500)
            ? recordLimit : 100;

        String query = 'SELECT ' + String.join(fieldList, ', ') +
                       ' FROM ' + metric.Source_Object__c +
                       ' WHERE ' + whereClause +
                       orderBy +
                       ' LIMIT ' + safeLimit;

        List<SObject> records;
        try {
            records = Database.query(query);
        } catch (Exception e) {
            throw new DKD_QueryException(
                'Drill-down query failed: ' + e.getMessage() + ' (SOQL: ' + query + ')'
            );
        }

        // Serialize each record as a map of {field: value}
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (SObject r : records) {
            Map<String, Object> row = new Map<String, Object>();
            for (String f : fieldList) {
                try {
                    row.put(f, r.get(f));
                } catch (Exception e) {
                    row.put(f, null);
                }
            }
            row.put('_id', r.Id);
            rows.add(row);
        }

        // Column metadata for the front-end table
        List<Map<String, Object>> columns = new List<Map<String, Object>>();
        for (String f : fieldList) {
            Map<String, Object> col = new Map<String, Object>();
            col.put('field', f);
            col.put('label', humanLabel(f));
            columns.add(col);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('rows', rows);
        result.put('columns', columns);
        result.put('recordCount', rows.size());
        result.put('metricLabel', metric.Label__c);
        result.put('sourceObject', metric.Source_Object__c);
        return result;
    }

    private static List<String> buildDrillDownFieldList(KPI_Metric__c metric) {
        List<String> fields = new List<String>{ 'Id' };
        Set<String> seen = new Set<String>{ 'id' };

        if (String.isNotBlank(metric.Date_Field__c) && !seen.contains(metric.Date_Field__c.toLowerCase())) {
            fields.add(sanitizeField(metric.Date_Field__c));
            seen.add(metric.Date_Field__c.toLowerCase());
        }
        if (String.isNotBlank(metric.Aggregate_Field__c) && !seen.contains(metric.Aggregate_Field__c.toLowerCase())) {
            fields.add(sanitizeField(metric.Aggregate_Field__c));
            seen.add(metric.Aggregate_Field__c.toLowerCase());
        }
        if (String.isNotBlank(metric.User_Field__c) && !seen.contains(metric.User_Field__c.toLowerCase())) {
            fields.add(sanitizeField(metric.User_Field__c));
            seen.add(metric.User_Field__c.toLowerCase());
        }

        // Add "Name" if the object supports it (most standard + custom do)
        Schema.SObjectType sobj = Schema.getGlobalDescribe().get(metric.Source_Object__c);
        if (sobj != null) {
            Map<String, Schema.SObjectField> objFields = sobj.getDescribe().fields.getMap();
            if (objFields.containsKey('name') && !seen.contains('name')) {
                fields.add(0, 'Name'); // Insert after Id
                seen.add('name');
            }
            // Status__c is ubiquitous across FMCG transactional objects
            if (objFields.containsKey('status__c') && !seen.contains('status__c')) {
                fields.add('Status__c');
                seen.add('status__c');
            }
        }
        return fields;
    }

    @TestVisible
    private static String humanLabel(String field) {
        if (String.isBlank(field)) return '';
        String cleaned = field.replace('__c', '').replace('__r', '').replace('_', ' ');
        // Title case the first letter of each word
        List<String> words = cleaned.split(' ');
        List<String> titled = new List<String>();
        for (String w : words) {
            if (String.isBlank(w)) continue;
            titled.add(w.substring(0, 1).toUpperCase() + (w.length() > 1 ? w.substring(1) : ''));
        }
        return String.join(titled, ' ');
    }

    // ── Safety Helpers ───────────────────────────────────────────────────────

    /**
     * @description Sanitizes a field name to prevent SOQL injection. Allows
     *              only letters, numbers, underscore, and dot (for relationship
     *              fields like Account.Territory__r.Name).
     */
    @TestVisible
    private static String sanitizeField(String field) {
        if (String.isBlank(field)) {
            throw new DKD_QueryException('Field name cannot be blank');
        }
        String trimmed = field.trim();
        if (!Pattern.matches('^[A-Za-z0-9_\\.]+$', trimmed)) {
            throw new DKD_QueryException('Invalid field name: ' + field);
        }
        return trimmed;
    }

    private static String formatDateLiteral(Date d, Boolean asDateTime) {
        Integer y = d.year();
        Integer m = d.month();
        Integer day = d.day();
        String datePart = y + '-' + (m < 10 ? '0' : '') + m + '-' + (day < 10 ? '0' : '') + day;
        // DateTime fields require ISO 8601 format: YYYY-MM-DDT00:00:00Z
        return asDateTime ? datePart + 'T00:00:00Z' : datePart;
    }

    private static Boolean isDateTimeType(String objectName, String fieldName) {
        if (String.isBlank(objectName) || String.isBlank(fieldName)) return false;
        Schema.SObjectType sobj = Schema.getGlobalDescribe().get(objectName);
        if (sobj == null) return false;
        Schema.SObjectField fld = sobj.getDescribe().fields.getMap().get(fieldName.toLowerCase());
        if (fld == null) return false;
        Schema.DisplayType dt = fld.getDescribe().getType();
        return dt == Schema.DisplayType.DATETIME;
    }

    // ── Custom Exception ─────────────────────────────────────────────────────
    public class DKD_QueryException extends Exception {}
}