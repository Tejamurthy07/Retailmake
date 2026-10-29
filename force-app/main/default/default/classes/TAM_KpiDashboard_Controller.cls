/**
 * @description Unified KPI Dashboard Controller. Combines targets, actuals,
 *              incentives, and team performance for salesperson, manager,
 *              and leadership views.
 */
public with sharing class TAM_KpiDashboard_Controller {

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getDashboardData(String periodId, String viewType) {
        Map<String, Object> result = new Map<String, Object>();

        // Init data
        result.put('periods', [
            SELECT Id, Name, Type__c, Start_Date__c, End_Date__c
            FROM Target_Period__c WHERE Is_Active__c = true
            ORDER BY Start_Date__c DESC LIMIT 24
        ]);

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
            periodId = current.isEmpty() ? '' : current[0].Id;
        }
        result.put('currentPeriodId', periodId);
        result.put('currentUserId', UserInfo.getUserId());

        if (String.isBlank(periodId)) return result;

        Id userId = UserInfo.getUserId();

        // Determine scope based on view type
        Set<Id> scopeUserIds = new Set<Id>();
        if (viewType == 'self') {
            scopeUserIds.add(userId);
        } else {
            scopeUserIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(userId);
        }

        // ── KPI Summary (aggregated across scope) ──
        // Load criteria weights separately (Percent fields can't be grouped)
        Map<Id, Decimal> criteriaWeightMap = new Map<Id, Decimal>();
        for (Target_Criteria__c tc : [
            SELECT Id, Incentive_Weight__c FROM Target_Criteria__c WHERE Active__c = true
        ]) {
            criteriaWeightMap.put(tc.Id, tc.Incentive_Weight__c);
        }

        List<AggregateResult> kpiAggs = [
            SELECT Target_Criteria__c criteriaId,
                   Target_Criteria__r.Name criteriaName,
                   Target_Criteria__r.Category__c category,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalActual
            FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND User__c IN :scopeUserIds
            AND Target_Criteria__r.Active__c = true
            GROUP BY Target_Criteria__c, Target_Criteria__r.Name,
                     Target_Criteria__r.Category__c
            ORDER BY Target_Criteria__r.Name
        ];

        List<Map<String, Object>> kpiList = new List<Map<String, Object>>();
        Decimal grandTarget = 0, grandActual = 0;

        for (AggregateResult ar : kpiAggs) {
            Decimal tt = (Decimal) ar.get('totalTarget');
            Decimal ta = (Decimal) ar.get('totalActual');
            tt = tt != null ? tt : 0;
            ta = ta != null ? ta : 0;

            Map<String, Object> kpi = new Map<String, Object>();
            Id critId = (Id) ar.get('criteriaId');
            kpi.put('criteriaId', critId);
            kpi.put('name', (String) ar.get('criteriaName'));
            kpi.put('category', (String) ar.get('category'));
            kpi.put('weight', criteriaWeightMap.get(critId));
            kpi.put('target', tt);
            kpi.put('actual', ta);
            kpi.put('percent', tt > 0 ? (ta / tt * 100).setScale(1, RoundingMode.HALF_UP) : 0);
            kpiList.add(kpi);

            grandTarget += tt;
            grandActual += ta;
        }

        result.put('kpis', kpiList);
        result.put('grandTarget', grandTarget);
        result.put('grandActual', grandActual);
        result.put('grandPercent', grandTarget > 0
            ? (grandActual / grandTarget * 100).setScale(1, RoundingMode.HALF_UP) : 0);

        // ── Incentive Summary ──
        List<AggregateResult> incAggs = [
            SELECT Status__c status,
                   COUNT(Id) cnt,
                   SUM(Calculated_Amount__c) totalCalc,
                   SUM(Final_Amount__c) totalFinal
            FROM Incentive__c
            WHERE Target_Period__c = :periodId
            AND Salesperson__c IN :scopeUserIds
            GROUP BY Status__c
        ];

        Map<String, Object> incSummary = new Map<String, Object>();
        Decimal totalIncentive = 0;
        Integer totalIncCount = 0;

        for (AggregateResult ar : incAggs) {
            String status = (String) ar.get('status');
            Integer cnt = (Integer) ar.get('cnt');
            Decimal calc = (Decimal) ar.get('totalCalc');
            calc = calc != null ? calc : 0;

            incSummary.put(status + '_count', cnt);
            incSummary.put(status + '_amount', calc);
            totalIncentive += calc;
            totalIncCount += cnt;
        }
        incSummary.put('total_count', totalIncCount);
        incSummary.put('total_amount', totalIncentive);
        result.put('incentiveSummary', incSummary);

        // ── Team Performance (per user breakdown) ──
        if (viewType != 'self') {
            List<AggregateResult> teamAggs = [
                SELECT User__c userId, User__r.Name userName,
                       User__r.Profile.Name profileName,
                       SUM(Target_Value__c) totalTarget,
                       SUM(Achievement_Value__c) totalActual
                FROM Target_Actual__c
                WHERE Target_Period__c = :periodId
                AND User__c IN :scopeUserIds
                AND Target_Criteria__r.Active__c = true
                GROUP BY User__c, User__r.Name, User__r.Profile.Name
                ORDER BY SUM(Achievement_Value__c) DESC
            ];

            // Pre-load all incentive totals per user in ONE query (avoids SOQL in loop)
            Map<Id, Decimal> userIncentiveMap = new Map<Id, Decimal>();
            for (AggregateResult incAr : [
                SELECT Salesperson__c userId, SUM(Calculated_Amount__c) totalInc
                FROM Incentive__c
                WHERE Target_Period__c = :periodId
                AND Salesperson__c IN :scopeUserIds
                AND Status__c != 'Rejected'
                GROUP BY Salesperson__c
            ]) {
                Decimal total = (Decimal) incAr.get('totalInc');
                userIncentiveMap.put((Id) incAr.get('userId'), total != null ? total : 0);
            }

            List<Map<String, Object>> team = new List<Map<String, Object>>();
            for (AggregateResult ar : teamAggs) {
                Decimal tt = (Decimal) ar.get('totalTarget');
                Decimal ta = (Decimal) ar.get('totalActual');
                tt = tt != null ? tt : 0;
                ta = ta != null ? ta : 0;

                Id teamUserId = (Id) ar.get('userId');
                Map<String, Object> row = new Map<String, Object>();
                row.put('userId', teamUserId);
                row.put('name', (String) ar.get('userName'));
                row.put('profile', (String) ar.get('profileName'));
                row.put('target', tt);
                row.put('actual', ta);
                row.put('percent', tt > 0 ? (ta / tt * 100).setScale(1, RoundingMode.HALF_UP) : 0);
                row.put('incentive', userIncentiveMap.containsKey(teamUserId) ? userIncentiveMap.get(teamUserId) : 0);

                team.add(row);
            }
            result.put('team', team);
        }

        // ── Trend Data (last 6 periods) ──
        List<Target_Period__c> recentPeriods = [
            SELECT Id, Name, Start_Date__c
            FROM Target_Period__c
            WHERE Is_Active__c = true AND Type__c = 'Monthly'
            AND Start_Date__c <= TODAY
            ORDER BY Start_Date__c DESC LIMIT 6
        ];

        // Reverse to chronological order
        List<Target_Period__c> chronological = new List<Target_Period__c>();
        for (Integer i = recentPeriods.size() - 1; i >= 0; i--) {
            chronological.add(recentPeriods[i]);
        }

        Set<Id> trendPeriodIds = new Set<Id>();
        for (Target_Period__c p : chronological) trendPeriodIds.add(p.Id);

        Map<Id, Map<String, Decimal>> trendMap = new Map<Id, Map<String, Decimal>>();
        for (AggregateResult ar : [
            SELECT Target_Period__c periodId,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalActual
            FROM Target_Actual__c
            WHERE Target_Period__c IN :trendPeriodIds
            AND User__c IN :scopeUserIds
            AND Target_Criteria__r.Active__c = true
            GROUP BY Target_Period__c
        ]) {
            Map<String, Decimal> d = new Map<String, Decimal>();
            d.put('target', (Decimal) ar.get('totalTarget'));
            d.put('actual', (Decimal) ar.get('totalActual'));
            trendMap.put((Id) ar.get('periodId'), d);
        }

        List<Map<String, Object>> trend = new List<Map<String, Object>>();
        for (Target_Period__c p : chronological) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('label', p.Name);
            row.put('periodId', p.Id);
            if (trendMap.containsKey(p.Id)) {
                row.put('target', trendMap.get(p.Id).get('target'));
                row.put('actual', trendMap.get(p.Id).get('actual'));
            } else {
                row.put('target', 0);
                row.put('actual', 0);
            }
            trend.add(row);
        }
        result.put('trend', trend);

        // ── Top Performers (Leaderboard) ──
        List<AggregateResult> lbAggs = [
            SELECT User__c userId, User__r.Name userName,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalAchievement
            FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND Target_Criteria__r.Active__c = true
            AND Target_Value__c > 0
            GROUP BY User__c, User__r.Name
            HAVING SUM(Achievement_Value__c) > 0
        ];

        List<Map<String, Object>> leaderboard = new List<Map<String, Object>>();
        for (AggregateResult ar : lbAggs) {
            Decimal tt = (Decimal) ar.get('totalTarget');
            Decimal ta = (Decimal) ar.get('totalAchievement');
            tt = tt != null ? tt : 0;
            ta = ta != null ? ta : 0;

            Map<String, Object> row = new Map<String, Object>();
            row.put('userId', (Id) ar.get('userId'));
            row.put('name', (String) ar.get('userName'));
            row.put('target', tt);
            row.put('actual', ta);
            row.put('percent', tt > 0 ? (ta / tt * 100).setScale(1, RoundingMode.HALF_UP) : 0);
            leaderboard.add(row);
        }

        leaderboard.sort(new LeaderboardComparator());
        while (leaderboard.size() > 10) {
            leaderboard.remove(leaderboard.size() - 1);
        }
        result.put('leaderboard', leaderboard);

        return result;
    }

    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getComparisonKpis(String periodId, String viewType) {
        if (String.isBlank(periodId)) return new List<Map<String, Object>>();

        Id userId = UserInfo.getUserId();
        Set<Id> scopeUserIds = new Set<Id>();
        if (viewType == 'self') {
            scopeUserIds.add(userId);
        } else {
            scopeUserIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(userId);
        }

        List<AggregateResult> aggs = [
            SELECT Target_Criteria__r.Name criteriaName,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalActual
            FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND User__c IN :scopeUserIds
            AND Target_Criteria__r.Active__c = true
            GROUP BY Target_Criteria__r.Name
        ];

        List<Map<String, Object>> kpis = new List<Map<String, Object>>();
        for (AggregateResult ar : aggs) {
            Decimal tt = (Decimal) ar.get('totalTarget');
            Decimal ta = (Decimal) ar.get('totalActual');
            tt = tt != null ? tt : 0;
            ta = ta != null ? ta : 0;

            Map<String, Object> kpi = new Map<String, Object>();
            kpi.put('name', (String) ar.get('criteriaName'));
            kpi.put('target', tt);
            kpi.put('actual', ta);
            kpi.put('percent', tt > 0 ? (ta / tt * 100).setScale(1, RoundingMode.HALF_UP) : 0);
            kpis.add(kpi);
        }
        return kpis;
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