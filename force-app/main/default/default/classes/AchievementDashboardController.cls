/**
 * @description Controller for the Achievement Dashboard LWC component.
 *              Provides targets vs achievements, leaderboard ranking, territory
 *              drill-down, and monthly trend data using the dynamic Target_Actual__c model.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class AchievementDashboardController {

    // ── Get Targets and Achievements ────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getTargetsAndAchievements(Id userId, String periodId) {
        Map<String, Object> result = new Map<String, Object>();

        if (String.isBlank(periodId)) {
            List<Target_Period__c> current = [
                SELECT Id FROM Target_Period__c
                WHERE Is_Default__c = true AND Is_Active__c = true LIMIT 1
            ];
            if (current.isEmpty()) {
                current = [
                    SELECT Id FROM Target_Period__c
                    WHERE Start_Date__c <= TODAY AND End_Date__c >= TODAY
                    AND Is_Active__c = true ORDER BY Type__c ASC LIMIT 1
                ];
            }
            if (current.isEmpty()) return result;
            periodId = current[0].Id;
        }

        List<Target_Actual__c> actuals = [
            SELECT Id, Target_Value__c, Achievement_Value__c,
                   Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Criteria__r.Category__c,
                   Teams_Target__c, Teams_Achievement__c
            FROM Target_Actual__c
            WHERE User__c = :userId
            AND Target_Period__c = :periodId
            AND Target_Criteria__r.Active__c = true
        ];

        // Build per-criteria aggregation
        List<Map<String, Object>> criteriaList = new List<Map<String, Object>>();
        Decimal totalTarget = 0, totalAchievement = 0;

        for (Target_Actual__c ta : actuals) {
            String name = ta.Target_Criteria__r.Name;
            if (String.isBlank(name)) continue;

            Decimal tv = ta.Target_Value__c != null ? ta.Target_Value__c : 0;
            Decimal av = ta.Achievement_Value__c != null ? ta.Achievement_Value__c : 0;
            Decimal ttv = ta.Teams_Target__c != null ? ta.Teams_Target__c : 0;
            Decimal tav = ta.Teams_Achievement__c != null ? ta.Teams_Achievement__c : 0;
            Decimal pct = tv > 0 ? (av / tv * 100).setScale(1, RoundingMode.HALF_UP) : 0;

            Map<String, Object> item = new Map<String, Object>();
            item.put('name', name);
            item.put('category', ta.Target_Criteria__r.Category__c);
            item.put('target', tv);
            item.put('actual', av);
            item.put('teamsTarget', ttv);
            item.put('teamsActual', tav);
            item.put('percent', pct);
            criteriaList.add(item);

            totalTarget += tv;
            totalAchievement += av;
        }

        result.put('criteria', criteriaList);
        result.put('totalTarget', totalTarget);
        result.put('totalAchievement', totalAchievement);
        result.put('totalPercent', totalTarget > 0
            ? (totalAchievement / totalTarget * 100).setScale(1, RoundingMode.HALF_UP) : 0);

        return result;
    }

    // ── Get Monthly Trend Data (REAL data, not random) ──────────────

    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getTrendData(Id userId, Integer year) {
        List<Map<String, Object>> trend = new List<Map<String, Object>>();

        // Get all monthly periods for the year
        Date yearStart = Date.newInstance(year, 1, 1);
        Date yearEnd = Date.newInstance(year, 12, 31);

        List<Target_Period__c> monthlyPeriods = [
            SELECT Id, Name, Start_Date__c
            FROM Target_Period__c
            WHERE Type__c = 'Monthly' AND Is_Active__c = true
            AND Start_Date__c >= :yearStart
            AND End_Date__c <= :yearEnd
            ORDER BY Start_Date__c ASC
        ];

        if (monthlyPeriods.isEmpty()) return trend;

        Set<Id> periodIds = new Set<Id>();
        for (Target_Period__c p : monthlyPeriods) periodIds.add(p.Id);

        // Aggregate target and achievement by period
        List<AggregateResult> aggs = [
            SELECT Target_Period__c periodId,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalActual
            FROM Target_Actual__c
            WHERE User__c = :userId
            AND Target_Period__c IN :periodIds
            AND Target_Criteria__r.Active__c = true
            GROUP BY Target_Period__c
        ];

        Map<Id, Map<String, Decimal>> periodDataMap = new Map<Id, Map<String, Decimal>>();
        for (AggregateResult ar : aggs) {
            Id pid = (Id) ar.get('periodId');
            Map<String, Decimal> data = new Map<String, Decimal>();
            data.put('target', (Decimal) ar.get('totalTarget'));
            data.put('actual', (Decimal) ar.get('totalActual'));
            periodDataMap.put(pid, data);
        }

        String[] monthNames = new String[]{
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        };

        for (Target_Period__c p : monthlyPeriods) {
            Map<String, Object> row = new Map<String, Object>();
            Integer monthIndex = p.Start_Date__c.month() - 1;
            row.put('label', monthNames[monthIndex]);
            row.put('periodId', p.Id);

            if (periodDataMap.containsKey(p.Id)) {
                Map<String, Decimal> data = periodDataMap.get(p.Id);
                row.put('target', data.get('target') != null ? data.get('target') : 0);
                row.put('actual', data.get('actual') != null ? data.get('actual') : 0);
            } else {
                row.put('target', 0);
                row.put('actual', 0);
            }

            trend.add(row);
        }

        return trend;
    }

    // ── Get Leaderboard ─────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getLeaderboard(String periodId) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        if (String.isBlank(periodId)) return results;

        List<AggregateResult> aggResults = [
            SELECT User__c userId,
                   User__r.Name userName,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalAchievement
            FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND Target_Criteria__r.Active__c = true
            AND Target_Value__c > 0
            GROUP BY User__c, User__r.Name
            HAVING SUM(Achievement_Value__c) > 0
        ];

        for (AggregateResult ar : aggResults) {
            Map<String, Object> row = new Map<String, Object>();
            Decimal tt = (Decimal) ar.get('totalTarget');
            Decimal ta = (Decimal) ar.get('totalAchievement');
            tt = tt != null ? tt : 0;
            ta = ta != null ? ta : 0;

            row.put('userId', (Id) ar.get('userId'));
            row.put('name', (String) ar.get('userName'));
            row.put('target', tt);
            row.put('actual', ta);
            row.put('percent', tt > 0 ? (ta / tt * 100).setScale(1, RoundingMode.HALF_UP) : 0);

            results.add(row);
        }

        results.sort(new LeaderboardComparator());
        while (results.size() > 20) {
            results.remove(results.size() - 1);
        }

        return results;
    }

    // ── Get Team Drill-Down ─────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getDrillDown(Id userId, String periodId) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        if (String.isBlank(periodId)) return results;

        Set<Id> subordinateIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(userId);
        subordinateIds.remove(userId); // Exclude self

        if (subordinateIds.isEmpty()) return results;

        // Aggregate per subordinate across all criteria
        List<AggregateResult> aggs = [
            SELECT User__c userId, User__r.Name userName,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalAchievement
            FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND User__c IN :subordinateIds
            AND Target_Criteria__r.Active__c = true
            GROUP BY User__c, User__r.Name
            ORDER BY User__r.Name
        ];

        for (AggregateResult ar : aggs) {
            Map<String, Object> row = new Map<String, Object>();
            Decimal tt = (Decimal) ar.get('totalTarget');
            Decimal ta = (Decimal) ar.get('totalAchievement');
            tt = tt != null ? tt : 0;
            ta = ta != null ? ta : 0;

            row.put('userId', (Id) ar.get('userId'));
            row.put('name', (String) ar.get('userName'));
            row.put('target', tt);
            row.put('actual', ta);
            row.put('percent', tt > 0 ? (ta / tt * 100).setScale(1, RoundingMode.HALF_UP) : 0);

            results.add(row);
        }

        return results;
    }

    // ── Get Dashboard Init Data ─────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getDashboardInit() {
        Map<String, Object> result = new Map<String, Object>();

        result.put('periods', [
            SELECT Id, Name, Type__c, Start_Date__c, End_Date__c
            FROM Target_Period__c
            WHERE Is_Active__c = true
            ORDER BY Start_Date__c DESC
            LIMIT 24
        ]);

        List<Target_Period__c> current = [
            SELECT Id FROM Target_Period__c
            WHERE Is_Default__c = true AND Is_Active__c = true
            LIMIT 1
        ];
        if (current.isEmpty()) {
            current = [
                SELECT Id FROM Target_Period__c
                WHERE Start_Date__c <= TODAY AND End_Date__c >= TODAY
                AND Is_Active__c = true ORDER BY Type__c ASC LIMIT 1
            ];
        }
        result.put('currentPeriodId', current.isEmpty() ? '' : current[0].Id);
        result.put('currentUserId', UserInfo.getUserId());
        result.put('currentYear', Date.today().year());

        return result;
    }

    @AuraEnabled
    public static String runAchievementCalculation(String periodId) {
        if (String.isBlank(periodId)) {
            throw new AuraHandledException('Please select a period before running calculation.');
        }
        Target_Period__c period = [SELECT Id, Name FROM Target_Period__c WHERE Id = :periodId LIMIT 1];
        Database.executeBatch(new TAM_Achievement_Batch(periodId), 50);
        return 'Achievement calculation started for ' + period.Name + '. Results will update shortly.';
    }

    private class LeaderboardComparator implements Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Decimal pa = (Decimal) a.get('percent');
            Decimal pb = (Decimal) b.get('percent');
            if (pb > pa) return 1;
            if (pb < pa) return -1;
            return 0;
        }
    }
}