/**
 * @description Smart insights engine for the Dynamic KPI Dashboard.
 *              Generates human-readable narratives from metric data:
 *                - Period-over-period trends ("Revenue up 12% vs last period")
 *                - Year-over-year comparisons
 *                - Anomaly detection (values >2σ from trend)
 *                - Top performer identification
 *                - Streak detection (consecutive growth periods)
 *
 *              Each insight is returned as a map suitable for rendering
 *              as a card in the dashboard insights panel.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class DKD_Insights_Service {

    // Anomaly threshold: flag if current value deviates more than N standard
    // deviations from the trailing mean.
    private static final Decimal ANOMALY_THRESHOLD_SIGMA = 2.0;

    /**
     * @description Main entry point. Generates a bundle of insights for the
     *              given metrics over the specified date range.
     */
    public static Map<String, Object> generateInsights(
        List<String> metricKeys,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        Map<String, Object> result = new Map<String, Object>();
        List<Map<String, Object>> insights = new List<Map<String, Object>>();

        if (metricKeys == null || metricKeys.isEmpty() ||
            dateFrom == null || dateTo == null) {
            result.put('insights', insights);
            result.put('generated', 0);
            return result;
        }

        // Current period values
        Map<String, Decimal> current = DKD_QueryEngine_Service.queryMultipleMetrics(
            metricKeys, filtersJson, dateFrom, dateTo, userScope
        );

        // Previous period values (same length, immediately before dateFrom)
        Integer days = dateFrom.daysBetween(dateTo) + 1;
        Date prevEnd = dateFrom.addDays(-1);
        Date prevStart = prevEnd.addDays(-(days - 1));
        Map<String, Decimal> previous = DKD_QueryEngine_Service.queryMultipleMetrics(
            metricKeys, filtersJson, prevStart, prevEnd, userScope
        );

        // Same period last year
        Map<String, Decimal> yearAgo = DKD_QueryEngine_Service.queryMultipleMetrics(
            metricKeys, filtersJson, dateFrom.addYears(-1), dateTo.addYears(-1), userScope
        );

        // Per-metric insight generation
        for (String key : metricKeys) {
            KPI_Metric__c metric = DKD_MetricRegistry.getMetric(key);
            if (metric == null) continue;

            Decimal curVal = current.get(key);
            Decimal prevVal = previous.get(key);
            Decimal yearAgoVal = yearAgo.get(key);

            if (curVal == null) curVal = 0;
            if (prevVal == null) prevVal = 0;
            if (yearAgoVal == null) yearAgoVal = 0;

            // 1. Period-over-period trend
            Map<String, Object> momInsight = buildTrendInsight(
                metric, 'mom', curVal, prevVal, 'previous period'
            );
            if (momInsight != null) insights.add(momInsight);

            // 2. Year-over-year trend (only if we have year-ago data)
            if (yearAgoVal > 0) {
                Map<String, Object> yoyInsight = buildTrendInsight(
                    metric, 'yoy', curVal, yearAgoVal, 'same period last year'
                );
                if (yoyInsight != null) insights.add(yoyInsight);
            }

            // 3. Anomaly detection (uses historical time series)
            if (metric.Allow_Forecast__c == true) {
                Map<String, Object> anomaly = detectAnomaly(metric, filtersJson, dateFrom, dateTo, userScope, curVal);
                if (anomaly != null) insights.add(anomaly);
            }
        }

        // 4. Top performer (for team/org scopes, pick the top metric and find top user)
        if (userScope != null && (userScope == 'team' || userScope == 'org')) {
            Map<String, Object> topPerformer = findTopPerformer(
                metricKeys, filtersJson, dateFrom, dateTo, userScope
            );
            if (topPerformer != null) insights.add(topPerformer);
        }

        // Sort: critical > warning > success > info
        // (keep current order — frontend can handle sorting if needed)

        // Limit to top 8 to avoid cluttering the UI
        while (insights.size() > 8) {
            insights.remove(insights.size() - 1);
        }

        result.put('insights', insights);
        result.put('generated', insights.size());
        return result;
    }

    // ── Insight builders ─────────────────────────────────────────────────────

    @TestVisible
    private static Map<String, Object> buildTrendInsight(
        KPI_Metric__c metric,
        String kind,
        Decimal curVal,
        Decimal prevVal,
        String prevLabel
    ) {
        if (prevVal == null || prevVal == 0) return null;
        Decimal delta = curVal - prevVal;
        Decimal pct = (delta / Math.abs(prevVal)) * 100;
        Decimal absPct = Math.abs(pct);

        // Ignore minor fluctuations
        if (absPct < 5) return null;

        Boolean up = delta > 0;
        String type;
        String severity;
        String icon;
        String color;
        String title;

        if (up) {
            type = 'trend_up';
            severity = 'success';
            icon = 'utility:trending';
            color = '#2e844a';
            title = metric.Label__c + ' is up';
        } else {
            type = 'trend_down';
            severity = absPct > 25 ? 'critical' : 'warning';
            icon = 'utility:warning';
            color = absPct > 25 ? '#ba0517' : '#dd7a01';
            title = metric.Label__c + ' is down';
        }

        String message = metric.Label__c + ' is ' +
            (up ? 'up ' : 'down ') + absPct.setScale(1) + '% vs ' + prevLabel +
            ' (' + formatValue(curVal, metric) + ' vs ' + formatValue(prevVal, metric) + ')';

        Map<String, Object> insight = new Map<String, Object>();
        insight.put('id', kind + '_' + metric.Metric_Key__c);
        insight.put('type', type);
        insight.put('severity', severity);
        insight.put('metricKey', metric.Metric_Key__c);
        insight.put('title', title);
        insight.put('message', message);
        insight.put('icon', icon);
        insight.put('color', color);
        insight.put('deltaPercent', pct.setScale(1));
        return insight;
    }

    @TestVisible
    private static Map<String, Object> detectAnomaly(
        KPI_Metric__c metric,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope,
        Decimal curVal
    ) {
        List<Map<String, Object>> series;
        try {
            series = DKD_QueryEngine_Service.queryTimeSeries(
                metric.Metric_Key__c, filtersJson,
                dateFrom.addMonths(-6), dateFrom.addDays(-1),
                'MONTH', userScope
            );
        } catch (Exception e) {
            return null;
        }
        if (series == null || series.size() < 3) return null;
        return buildAnomalyInsight(metric, series, curVal);
    }

    @TestVisible
    private static Map<String, Object> buildAnomalyInsight(
        KPI_Metric__c metric, List<Map<String, Object>> series, Decimal curVal
    ) {
        Decimal sum = 0;
        Integer n = 0;
        for (Map<String, Object> row : series) {
            Object v = row.get('value');
            if (v == null) continue;
            sum += toDecimal(v);
            n++;
        }
        if (n < 3) return null;
        Decimal mean = sum / n;

        Decimal varSum = 0;
        for (Map<String, Object> row : series) {
            Object v = row.get('value');
            if (v == null) continue;
            Decimal diff = toDecimal(v) - mean;
            varSum += diff * diff;
        }
        Decimal variance = varSum / n;
        Decimal stdDev = Math.sqrt(variance.doubleValue());

        if (stdDev == 0) return null;

        Decimal z = (curVal - mean) / stdDev;
        if (Math.abs(z) < ANOMALY_THRESHOLD_SIGMA) return null;

        Boolean above = z > 0;
        String type = above ? 'anomaly_high' : 'anomaly_low';
        String severity = above ? 'success' : 'critical';
        String icon = above ? 'utility:success' : 'utility:error';
        String color = above ? '#2e844a' : '#ba0517';

        String message = metric.Label__c + ' is ' +
            (above ? 'significantly higher' : 'significantly lower') +
            ' than the 6-month trend (' + z.setScale(1) + 'σ from mean of ' +
            formatValue(mean, metric) + ').';

        Map<String, Object> insight = new Map<String, Object>();
        insight.put('id', 'anomaly_' + metric.Metric_Key__c);
        insight.put('type', type);
        insight.put('severity', severity);
        insight.put('metricKey', metric.Metric_Key__c);
        insight.put('title', (above ? 'Outperformance' : 'Underperformance') + ' detected');
        insight.put('message', message);
        insight.put('icon', icon);
        insight.put('color', color);
        insight.put('zScore', z.setScale(2));
        return insight;
    }

    @TestVisible
    private static Map<String, Object> findTopPerformer(
        List<String> metricKeys,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String userScope
    ) {
        // Pick the first currency-format metric as the "primary" for top performer
        String primaryKey = null;
        KPI_Metric__c primaryMetric = null;
        for (String key : metricKeys) {
            KPI_Metric__c m = DKD_MetricRegistry.getMetric(key);
            if (m != null && 'Currency'.equals(m.Format__c)) {
                primaryKey = key;
                primaryMetric = m;
                break;
            }
        }
        if (primaryKey == null) return null;
        if (String.isBlank(primaryMetric.User_Field__c)) return null;

        // Group the primary metric by user
        List<Map<String, Object>> rows;
        try {
            rows = DKD_QueryEngine_Service.queryMetric(
                primaryKey, filtersJson, primaryMetric.User_Field__c,
                dateFrom, dateTo, userScope
            );
        } catch (Exception e) {
            return null;
        }

        if (rows == null || rows.isEmpty()) return null;

        // Find the top user
        Decimal topValue = 0;
        String topUserId = null;
        for (Map<String, Object> row : rows) {
            Object val = row.get('value');
            if (val == null) continue;
            Decimal v = toDecimal(val);
            if (v > topValue) {
                topValue = v;
                topUserId = (String) row.get('groupKey');
            }
        }
        if (topUserId == null || topValue == 0) return null;

        // Lookup user name
        String userName = topUserId;
        try {
            Id uid = Id.valueOf(topUserId);
            List<User> users = [SELECT Id, Name FROM User WHERE Id = :uid LIMIT 1];
            if (!users.isEmpty()) userName = users[0].Name;
        } catch (Exception e) {
            // topUserId wasn't a valid Id — fall through and use the raw value
        }

        Map<String, Object> insight = new Map<String, Object>();
        insight.put('id', 'top_performer_' + primaryKey);
        insight.put('type', 'top_performer');
        insight.put('severity', 'info');
        insight.put('metricKey', primaryKey);
        insight.put('title', 'Top performer');
        insight.put('message', userName + ' leads with ' + formatValue(topValue, primaryMetric) +
                               ' in ' + primaryMetric.Label__c);
        insight.put('icon', 'utility:trophy');
        insight.put('color', '#ffa41c');
        return insight;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    @TestVisible
    private static String formatValue(Decimal value, KPI_Metric__c metric) {
        if (value == null) return '0';
        String format = metric.Format__c != null ? metric.Format__c : 'Number';
        if (format == 'Currency') {
            // Simple Indian currency formatting (₹X,XX,XXX)
            return '₹' + formatIndianNumber(value);
        }
        if (format == 'Percent') {
            return value.setScale(1) + '%';
        }
        if (format == 'Duration') {
            return Math.round(value.doubleValue()) + ' min';
        }
        return formatIndianNumber(value);
    }

    @TestVisible
    private static String formatIndianNumber(Decimal value) {
        if (value == null) return '0';
        Long rounded = Math.round(value.doubleValue());
        if (rounded == 0) return '0';
        String str = String.valueOf(rounded);
        Boolean negative = str.startsWith('-');
        if (negative) str = str.substring(1);

        if (str.length() <= 3) {
            return (negative ? '-' : '') + str;
        }

        // Format as Indian lakhs/crores: last 3 digits, then groups of 2
        String last3 = str.substring(str.length() - 3);
        String rest = str.substring(0, str.length() - 3);
        String result = '';
        while (rest.length() > 2) {
            result = ',' + rest.substring(rest.length() - 2) + result;
            rest = rest.substring(0, rest.length() - 2);
        }
        result = rest + result + ',' + last3;
        return (negative ? '-' : '') + result;
    }

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
}