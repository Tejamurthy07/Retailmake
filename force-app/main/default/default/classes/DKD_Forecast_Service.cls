/**
 * @description Forecasts future metric values using simple linear regression
 *              on historical time-series data. Also computes growth rate,
 *              R² goodness-of-fit, and confidence intervals. Designed to
 *              feed the Dynamic KPI Dashboard forecast widget.
 *
 *              Algorithm: Ordinary Least Squares (OLS) linear regression.
 *              For a set of points (xi, yi):
 *                  slope = Σ((xi-x̄)(yi-ȳ)) / Σ((xi-x̄)²)
 *                  intercept = ȳ - slope*x̄
 *              Forecast: y(x) = slope*x + intercept
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class DKD_Forecast_Service {

    private static final Decimal Z_95 = 1.96; // 95% confidence multiplier

    // ── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Takes a historical series and projects N future periods.
     * @param historical      List of {period, label, value} rows (oldest first).
     * @param forecastPeriods Number of future periods to project.
     * @return Map containing historical array, forecast array, and stats.
     */
    public static Map<String, Object> forecast(
        List<Map<String, Object>> historical,
        Integer forecastPeriods
    ) {
        Map<String, Object> result = new Map<String, Object>();

        if (historical == null || historical.size() < 2 || forecastPeriods == null || forecastPeriods <= 0) {
            result.put('historical', historical != null ? historical : new List<Map<String, Object>>());
            result.put('forecast', new List<Map<String, Object>>());
            result.put('slope', 0);
            result.put('intercept', 0);
            result.put('rSquared', 0);
            result.put('growthRatePercent', 0);
            result.put('standardError', 0);
            result.put('insight', historical == null || historical.isEmpty()
                ? 'No historical data to forecast from.'
                : 'Need at least 2 data points to generate a forecast.');
            return result;
        }

        // Build x/y arrays — x is the time index (0, 1, 2, ...), y is the metric value
        Integer n = historical.size();
        List<Decimal> xs = new List<Decimal>();
        List<Decimal> ys = new List<Decimal>();
        for (Integer i = 0; i < n; i++) {
            xs.add((Decimal) i);
            ys.add(toDecimal(historical[i].get('value')));
        }

        // Linear regression
        Decimal xMean = mean(xs);
        Decimal yMean = mean(ys);

        Decimal numerator = 0;
        Decimal denominator = 0;
        for (Integer i = 0; i < n; i++) {
            Decimal dx = xs[i] - xMean;
            Decimal dy = ys[i] - yMean;
            numerator += dx * dy;
            denominator += dx * dx;
        }

        Decimal slope = denominator == 0 ? 0 : numerator / denominator;
        Decimal intercept = yMean - slope * xMean;

        // R² (coefficient of determination) and standard error
        Decimal ssTotal = 0;
        Decimal ssResidual = 0;
        for (Integer i = 0; i < n; i++) {
            Decimal predicted = slope * xs[i] + intercept;
            ssResidual += (ys[i] - predicted) * (ys[i] - predicted);
            ssTotal += (ys[i] - yMean) * (ys[i] - yMean);
        }
        Decimal rSquared = ssTotal == 0 ? 1 : Math.max(0, 1 - (ssResidual / ssTotal));
        Decimal standardError = n > 2
            ? Decimal.valueOf(Math.sqrt(Double.valueOf(ssResidual / (n - 2))))
            : 0;

        // Historical growth rate (first vs last observation)
        Decimal firstVal = ys[0];
        Decimal lastVal = ys[n - 1];
        Decimal growthRate = 0;
        if (firstVal != 0) {
            growthRate = ((lastVal - firstVal) / Math.abs(firstVal)) * 100;
        }

        // Project future periods
        List<Map<String, Object>> forecastRows = new List<Map<String, Object>>();
        for (Integer i = 0; i < forecastPeriods; i++) {
            Decimal x = (Decimal) n + i;
            Decimal projected = slope * x + intercept;
            // Floor negative projections at 0 (metrics usually can't go below 0)
            if (projected < 0) projected = 0;

            Decimal confidenceRange = standardError * Z_95;
            Decimal upper = projected + confidenceRange;
            Decimal lower = Math.max(0, projected - confidenceRange);

            Map<String, Object> row = new Map<String, Object>();
            row.put('periodIndex', x);
            row.put('label', 'F' + String.valueOf(i + 1));
            row.put('value', projected.setScale(2, RoundingMode.HALF_UP));
            row.put('upper', upper.setScale(2, RoundingMode.HALF_UP));
            row.put('lower', lower.setScale(2, RoundingMode.HALF_UP));
            forecastRows.add(row);
        }

        // Build insight text
        String insight = buildInsight(slope, growthRate, rSquared, lastVal, forecastRows);

        result.put('historical', historical);
        result.put('forecast', forecastRows);
        result.put('slope', slope.setScale(4, RoundingMode.HALF_UP));
        result.put('intercept', intercept.setScale(4, RoundingMode.HALF_UP));
        result.put('rSquared', rSquared.setScale(4, RoundingMode.HALF_UP));
        result.put('growthRatePercent', growthRate.setScale(2, RoundingMode.HALF_UP));
        result.put('standardError', standardError.setScale(2, RoundingMode.HALF_UP));
        result.put('insight', insight);
        return result;
    }

    /**
     * @description Convenience method that runs the forecast directly against
     *              a live metric. Calls DKD_QueryEngine_Service.queryTimeSeries
     *              then forecast() in one call.
     */
    @AuraEnabled
    public static Map<String, Object> forecastMetric(
        String metricKey,
        String filtersJson,
        Date dateFrom,
        Date dateTo,
        String interval,
        Integer forecastPeriods,
        String userScope
    ) {
        List<Map<String, Object>> historical = DKD_QueryEngine_Service.queryTimeSeries(
            metricKey, filtersJson, dateFrom, dateTo, interval, userScope
        );
        return forecast(historical, forecastPeriods != null ? forecastPeriods : 6);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static Decimal mean(List<Decimal> values) {
        if (values == null || values.isEmpty()) return 0;
        Decimal sum = 0;
        for (Decimal v : values) sum += v;
        return sum / values.size();
    }

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

    private static String buildInsight(
        Decimal slope,
        Decimal growthRate,
        Decimal rSquared,
        Decimal lastValue,
        List<Map<String, Object>> forecastRows
    ) {
        String trend;
        if (slope > 0) {
            trend = 'increasing';
        } else if (slope < 0) {
            trend = 'decreasing';
        } else {
            trend = 'flat';
        }

        String confidence;
        if (rSquared >= 0.85) {
            confidence = 'high';
        } else if (rSquared >= 0.5) {
            confidence = 'moderate';
        } else {
            confidence = 'low';
        }

        String direction = slope >= 0 ? 'up' : 'down';
        String growthStr = growthRate.setScale(1, RoundingMode.HALF_UP).toPlainString();

        Decimal lastForecast = 0;
        if (!forecastRows.isEmpty()) {
            lastForecast = toDecimal(forecastRows[forecastRows.size() - 1].get('value'));
        }
        Decimal changeFromLast = 0;
        if (lastValue != 0 && lastForecast != 0) {
            changeFromLast = ((lastForecast - lastValue) / Math.abs(lastValue)) * 100;
        }

        return 'Trend: ' + trend +
               ' (' + direction + ' ' + growthStr + '% over the observed window). ' +
               'Forecast confidence: ' + confidence + ' (R²=' + rSquared.setScale(2).toPlainString() + '). ' +
               'Projected change over forecast horizon: ' +
               changeFromLast.setScale(1, RoundingMode.HALF_UP).toPlainString() + '%.';
    }
}