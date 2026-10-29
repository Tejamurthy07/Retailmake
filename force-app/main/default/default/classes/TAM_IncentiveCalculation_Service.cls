/**
 * @description Service class for computing incentive payouts from target achievements
 *              and incentive slab configurations. Supports:
 *              - 4-tier slab matching (Criteria + Profile + Territory → Universal)
 *              - 3 payout types (Percentage, Fixed Amount, Salary Percentage)
 *              - KPI weightage
 *              - Prerequisite eligibility rules
 *              - Cumulative quarterly/annual calculation
 *              - Annual bonus (best 3 of 4 quarters)
 */
public with sharing class TAM_IncentiveCalculation_Service {

    // ═══════════════════════════════════════════════════════════════
    // MAIN ENTRY: Calculate incentives for a period
    // ═══════════════════════════════════════════════════════════════

    public static List<Incentive__c> calculateForTargetActuals(List<Target_Actual__c> actuals, Id periodId) {
        if (actuals == null || actuals.isEmpty()) return new List<Incentive__c>();

        // Load period for type detection
        Target_Period__c period = [
            SELECT Id, Type__c, Is_Cumulative__c
            FROM Target_Period__c WHERE Id = :periodId
        ];

        // Load all active slabs with new fields
        List<Incentive_Slab__c> allSlabs = [
            SELECT Id, Name, Target_Criteria__c, Min_Percent__c, Max_Percent__c,
                   Payout_Type__c, Payout_Value__c, Multiplier__c,
                   Is_Active__c, Effective_From__c, Effective_To__c,
                   Profile_Name__c, Territory__c
            FROM Incentive_Slab__c
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c ASC, Min_Percent__c ASC
        ];

        if (allSlabs.isEmpty()) return new List<Incentive__c>();

        // Collect user IDs and criteria IDs
        Set<Id> userIds = new Set<Id>();
        Set<Id> criteriaIds = new Set<Id>();
        for (Target_Actual__c ta : actuals) {
            userIds.add(ta.User__c);
            criteriaIds.add(ta.Target_Criteria__c);
        }

        // Load user profiles for profile-based slab matching
        Map<Id, String> userProfileMap = new Map<Id, String>();
        for (User u : [SELECT Id, Profile.Name FROM User WHERE Id IN :userIds]) {
            userProfileMap.put(u.Id, u.Profile.Name);
        }

        // Load user salaries for salary-based payout (via Employee__c)
        Map<Id, Decimal> userSalaryMap = loadUserSalaries(userIds);

        // Load user territories for territory-based slab matching
        Map<Id, Id> userTerritoryMap = loadUserTerritories(userIds);

        // Load criteria with prerequisite and weight info
        Map<Id, Target_Criteria__c> criteriaMap = new Map<Id, Target_Criteria__c>([
            SELECT Id, Name, Incentive_Weight__c,
                   Prerequisite_Criteria__c, Prerequisite_Min_Percent__c
            FROM Target_Criteria__c
            WHERE Id IN :criteriaIds
        ]);

        // Build achievement map for prerequisite checking (userId+criteriaId → %)
        Map<String, Decimal> achievementPercentMap = new Map<String, Decimal>();
        for (Target_Actual__c ta : actuals) {
            Decimal tv = ta.Target_Value__c != null ? ta.Target_Value__c : 0;
            Decimal av = ta.Achievement_Value__c != null ? ta.Achievement_Value__c : 0;
            Decimal pct = tv > 0 ? (av / tv) * 100 : 0;
            achievementPercentMap.put(ta.User__c + '-' + ta.Target_Criteria__c, pct);
        }

        // If cumulative, load child period achievements and sum them
        if (period.Is_Cumulative__c == true) {
            actuals = getCumulativeActuals(periodId, userIds, criteriaIds);
            // Rebuild achievement map with cumulative values
            achievementPercentMap.clear();
            for (Target_Actual__c ta : actuals) {
                Decimal tv = ta.Target_Value__c != null ? ta.Target_Value__c : 0;
                Decimal av = ta.Achievement_Value__c != null ? ta.Achievement_Value__c : 0;
                Decimal pct = tv > 0 ? (av / tv) * 100 : 0;
                achievementPercentMap.put(ta.User__c + '-' + ta.Target_Criteria__c, pct);
            }
        }

        // Load existing incentives for upsert
        Map<String, Incentive__c> existingMap = new Map<String, Incentive__c>();
        for (Incentive__c inc : [
            SELECT Id, Salesperson__c, Target_Actual__c, Target_Criteria__c, Target_Period__c
            FROM Incentive__c
            WHERE Target_Period__c = :periodId
            AND Salesperson__c IN :userIds
            AND Target_Criteria__c IN :criteriaIds
            AND Is_Annual_Bonus__c = false
        ]) {
            existingMap.put(inc.Salesperson__c + '-' + inc.Target_Criteria__c, inc);
        }

        // Determine salary multiplier based on period type
        Decimal salaryPeriodMultiplier = 1;
        if (period.Type__c == 'Quarterly') salaryPeriodMultiplier = 3;
        else if (period.Type__c == 'Yearly') salaryPeriodMultiplier = 12;

        Date today = Date.today();
        List<Incentive__c> results = new List<Incentive__c>();
        List<String> skipReasons = new List<String>();

        for (Target_Actual__c ta : actuals) {
            Decimal targetValue = ta.Target_Value__c != null ? ta.Target_Value__c : 0;
            Decimal achievementValue = ta.Achievement_Value__c != null ? ta.Achievement_Value__c : 0;
            if (targetValue == 0) {
                skipReasons.add(ta.Target_Criteria__r.Name + ': target is 0');
                continue;
            }

            Decimal achievementPercent = (achievementValue / targetValue) * 100;

            // Get criteria config
            Target_Criteria__c criteria = criteriaMap.get(ta.Target_Criteria__c);
            if (criteria == null) {
                skipReasons.add(ta.Target_Criteria__r.Name + ': criteria not found');
                continue;
            }

            // ── PREREQUISITE CHECK ──
            if (criteria.Prerequisite_Criteria__c != null) {
                String prereqKey = ta.User__c + '-' + criteria.Prerequisite_Criteria__c;
                Decimal prereqPct = achievementPercentMap.containsKey(prereqKey)
                    ? achievementPercentMap.get(prereqKey) : 0;
                Decimal minRequired = criteria.Prerequisite_Min_Percent__c != null
                    ? criteria.Prerequisite_Min_Percent__c : 90;

                if (prereqPct < minRequired) {
                    skipReasons.add(ta.Target_Criteria__r.Name + ': prerequisite not met (' + prereqPct.setScale(1) + '% < ' + minRequired + '% required)');
                    continue; // Skip — prerequisite not met
                }
            }

            // ── 4-TIER SLAB MATCHING ──
            String userProfile = userProfileMap.get(ta.User__c);
            Id userTerritory = userTerritoryMap.get(ta.User__c);

            Incentive_Slab__c matchedSlab = findMatchingSlab(
                achievementPercent, ta.Target_Criteria__c,
                userProfile, userTerritory, allSlabs, today
            );

            if (matchedSlab == null) {
                skipReasons.add(ta.Target_Criteria__r.Name + ': no slab matches ' + achievementPercent.setScale(1) + '% for profile=' + userProfile + ', territory=' + userTerritory);
                continue;
            }

            // ── COMPUTE PAYOUT ──
            Decimal salary = userSalaryMap.containsKey(ta.User__c)
                ? userSalaryMap.get(ta.User__c) : 0;

            Decimal payout = computePayout(
                targetValue, achievementPercent, matchedSlab,
                salary, salaryPeriodMultiplier
            );

            // ── APPLY KPI WEIGHTAGE ──
            if (criteria.Incentive_Weight__c != null && criteria.Incentive_Weight__c > 0) {
                payout = payout * (criteria.Incentive_Weight__c / 100);
            }

            // ── BUILD INCENTIVE RECORD ──
            String key = ta.User__c + '-' + ta.Target_Criteria__c;
            Incentive__c inc;
            if (existingMap.containsKey(key)) {
                inc = existingMap.get(key);
            } else {
                inc = new Incentive__c();
                inc.Salesperson__c = ta.User__c;
                inc.Target_Criteria__c = ta.Target_Criteria__c;
                inc.Target_Period__c = periodId;
            }

            inc.OwnerId = ta.User__c;
            inc.Target_Actual__c = ta.Id;
            inc.Achievement_Percent__c = achievementPercent.setScale(2, RoundingMode.HALF_UP);
            inc.Incentive_Slab_Ref__c = matchedSlab.Id;
            inc.Multiplier__c = matchedSlab.Multiplier__c;
            inc.Base_Amount__c = targetValue;
            inc.Calculated_Amount__c = payout.setScale(2, RoundingMode.HALF_UP);
            inc.Status__c = 'Calculated';
            inc.Is_Annual_Bonus__c = false;

            results.add(inc);
        }

        if (!results.isEmpty()) {
            upsert results;
        }

        if (!skipReasons.isEmpty()) {
            System.debug('Skipped targets: ' + String.join(skipReasons, ' | '));
            lastSkipReasons = skipReasons;
        }

        return results;
    }

    public static List<String> lastSkipReasons = new List<String>();

    // ═══════════════════════════════════════════════════════════════
    // 4-TIER SLAB MATCHING
    // Priority: Criteria+Profile+Territory → Criteria+Profile →
    //           Criteria only → Universal
    // ═══════════════════════════════════════════════════════════════

    public static Incentive_Slab__c findMatchingSlab(
        Decimal achievementPercent, Id criteriaId,
        String userProfile, Id userTerritory,
        List<Incentive_Slab__c> allSlabs, Date today
    ) {
        // Tier 1: Criteria + Profile + Territory
        for (Incentive_Slab__c slab : allSlabs) {
            if (slab.Target_Criteria__c != criteriaId) continue;
            if (!profileMatches(slab.Profile_Name__c, userProfile)) continue;
            if (slab.Territory__c == null || slab.Territory__c != userTerritory) continue;
            if (isSlabMatch(slab, achievementPercent, today)) return slab;
        }

        // Tier 2: Criteria + Profile (any territory)
        for (Incentive_Slab__c slab : allSlabs) {
            if (slab.Target_Criteria__c != criteriaId) continue;
            if (!profileMatches(slab.Profile_Name__c, userProfile)) continue;
            if (slab.Territory__c != null) continue;
            if (isSlabMatch(slab, achievementPercent, today)) return slab;
        }

        // Tier 3: Criteria only (any profile, any territory)
        for (Incentive_Slab__c slab : allSlabs) {
            if (slab.Target_Criteria__c != criteriaId) continue;
            if (String.isNotBlank(slab.Profile_Name__c)) continue;
            if (slab.Territory__c != null) continue;
            if (isSlabMatch(slab, achievementPercent, today)) return slab;
        }

        // Tier 4: Universal (no criteria, no profile, no territory)
        for (Incentive_Slab__c slab : allSlabs) {
            if (slab.Target_Criteria__c != null) continue;
            if (String.isNotBlank(slab.Profile_Name__c)) continue;
            if (slab.Territory__c != null) continue;
            if (isSlabMatch(slab, achievementPercent, today)) return slab;
        }

        return null;
    }

    private static Boolean profileMatches(String slabProfile, String userProfile) {
        if (String.isBlank(slabProfile)) return false; // Blank = universal, not a match for specific tier
        return slabProfile.equalsIgnoreCase(userProfile);
    }

    private static Boolean isSlabMatch(Incentive_Slab__c slab, Decimal achievementPercent, Date today) {
        if (achievementPercent < slab.Min_Percent__c || achievementPercent > slab.Max_Percent__c) {
            return false;
        }
        if (slab.Effective_From__c != null && today < slab.Effective_From__c) return false;
        if (slab.Effective_To__c != null && today > slab.Effective_To__c) return false;
        return true;
    }

    // ═══════════════════════════════════════════════════════════════
    // PAYOUT COMPUTATION (3 types)
    // ═══════════════════════════════════════════════════════════════

    public static Decimal computePayout(Decimal targetValue, Decimal achievementPercent,
                                         Incentive_Slab__c slab, Decimal monthlySalary,
                                         Decimal salaryPeriodMultiplier) {
        Decimal multiplier = slab.Multiplier__c != null ? slab.Multiplier__c : 1;
        Decimal payoutValue = slab.Payout_Value__c != null ? slab.Payout_Value__c : 0;

        if (slab.Payout_Type__c == 'Percentage') {
            return targetValue * (payoutValue / 100) * multiplier;
        } else if (slab.Payout_Type__c == 'Salary Percentage') {
            Decimal periodSalary = monthlySalary * salaryPeriodMultiplier;
            return periodSalary * (payoutValue / 100) * multiplier;
        } else {
            // Fixed Amount
            return payoutValue * multiplier;
        }
    }

    // Backward-compatible overload (no salary)
    public static Decimal computePayout(Decimal targetValue, Decimal achievementPercent, Incentive_Slab__c slab) {
        return computePayout(targetValue, achievementPercent, slab, 0, 1);
    }

    // ═══════════════════════════════════════════════════════════════
    // CUMULATIVE CALCULATION
    // Aggregates achievements from child periods
    // ═══════════════════════════════════════════════════════════════

    public static List<Target_Actual__c> getCumulativeActuals(Id parentPeriodId, Set<Id> userIds, Set<Id> criteriaIds) {
        // Get child period IDs
        List<Target_Period__c> childPeriods = [
            SELECT Id FROM Target_Period__c
            WHERE Parent_Period__c = :parentPeriodId
        ];

        Set<Id> childPeriodIds = new Set<Id>();
        for (Target_Period__c cp : childPeriods) {
            childPeriodIds.add(cp.Id);
        }

        if (childPeriodIds.isEmpty()) {
            // No children — fall back to direct period actuals
            return [
                SELECT Id, User__c, Target_Criteria__c, Target_Criteria__r.Name,
                       Target_Value__c, Achievement_Value__c,
                       Teams_Target__c, Teams_Achievement__c, Target_Period__c
                FROM Target_Actual__c
                WHERE Target_Period__c = :parentPeriodId
                AND User__c IN :userIds
                AND Target_Criteria__r.Active__c = true
            ];
        }

        // Aggregate across child periods
        List<AggregateResult> aggs = [
            SELECT User__c userId, Target_Criteria__c criteriaId,
                   SUM(Target_Value__c) totalTarget,
                   SUM(Achievement_Value__c) totalAchievement,
                   SUM(Teams_Target__c) totalTeamsTarget,
                   SUM(Teams_Achievement__c) totalTeamsAchievement
            FROM Target_Actual__c
            WHERE Target_Period__c IN :childPeriodIds
            AND User__c IN :userIds
            AND Target_Criteria__c IN :criteriaIds
            AND Target_Criteria__r.Active__c = true
            GROUP BY User__c, Target_Criteria__c
        ];

        // Convert to Target_Actual__c-like records
        List<Target_Actual__c> cumulativeActuals = new List<Target_Actual__c>();
        for (AggregateResult ar : aggs) {
            Target_Actual__c ta = new Target_Actual__c();
            ta.User__c = (Id) ar.get('userId');
            ta.Target_Criteria__c = (Id) ar.get('criteriaId');
            ta.Target_Value__c = (Decimal) ar.get('totalTarget');
            ta.Achievement_Value__c = (Decimal) ar.get('totalAchievement');
            ta.Teams_Target__c = (Decimal) ar.get('totalTeamsTarget');
            ta.Teams_Achievement__c = (Decimal) ar.get('totalTeamsAchievement');
            ta.Target_Period__c = parentPeriodId;
            cumulativeActuals.add(ta);
        }

        return cumulativeActuals;
    }

    // ═══════════════════════════════════════════════════════════════
    // ANNUAL BONUS CALCULATION
    // Average of best 3 out of 4 quarterly incentives
    // ═══════════════════════════════════════════════════════════════

    public static List<Incentive__c> calculateAnnualBonus(Id annualPeriodId) {
        // Get quarterly child periods
        List<Target_Period__c> quarterlyPeriods = [
            SELECT Id FROM Target_Period__c
            WHERE Parent_Period__c = :annualPeriodId
            AND Type__c = 'Quarterly'
        ];

        if (quarterlyPeriods.isEmpty()) return new List<Incentive__c>();

        Set<Id> quarterlyIds = new Set<Id>();
        for (Target_Period__c qp : quarterlyPeriods) {
            quarterlyIds.add(qp.Id);
        }

        // Get all quarterly incentives grouped by user
        List<AggregateResult> userTotals = [
            SELECT Salesperson__c userId,
                   Target_Period__c periodId,
                   SUM(Calculated_Amount__c) totalAmount
            FROM Incentive__c
            WHERE Target_Period__c IN :quarterlyIds
            AND Is_Annual_Bonus__c = false
            AND Status__c != 'Rejected'
            GROUP BY Salesperson__c, Target_Period__c
            ORDER BY Salesperson__c, SUM(Calculated_Amount__c) DESC
        ];

        // Group by user: userId → list of quarterly totals (sorted desc)
        Map<Id, List<Decimal>> userQuarterlyTotals = new Map<Id, List<Decimal>>();
        for (AggregateResult ar : userTotals) {
            Id userId = (Id) ar.get('userId');
            Decimal amount = (Decimal) ar.get('totalAmount');
            if (!userQuarterlyTotals.containsKey(userId)) {
                userQuarterlyTotals.put(userId, new List<Decimal>());
            }
            userQuarterlyTotals.get(userId).add(amount != null ? amount : 0);
        }

        // Load existing annual bonus records for upsert
        Map<Id, Incentive__c> existingBonusMap = new Map<Id, Incentive__c>();
        for (Incentive__c inc : [
            SELECT Id, Salesperson__c FROM Incentive__c
            WHERE Target_Period__c = :annualPeriodId AND Is_Annual_Bonus__c = true
        ]) {
            existingBonusMap.put(inc.Salesperson__c, inc);
        }

        List<Incentive__c> bonusRecords = new List<Incentive__c>();

        for (Id userId : userQuarterlyTotals.keySet()) {
            List<Decimal> totals = userQuarterlyTotals.get(userId);
            if (totals == null || totals.isEmpty()) continue;
            totals.sort();

            // Need at least 3 quarters to qualify
            if (totals.size() < 3) continue;

            // Take top 3 (list is ascending, so take last 3)
            Decimal sum = 0;
            Integer count = Math.min(3, totals.size());
            for (Integer i = totals.size() - count; i < totals.size(); i++) {
                sum += totals[i];
            }
            Decimal bonus = sum / count;

            Incentive__c inc;
            if (existingBonusMap.containsKey(userId)) {
                inc = existingBonusMap.get(userId);
            } else {
                inc = new Incentive__c();
                inc.Salesperson__c = userId;
                inc.Target_Period__c = annualPeriodId;
                inc.Is_Annual_Bonus__c = true;
            }

            inc.Annual_Bonus__c = bonus.setScale(2, RoundingMode.HALF_UP);
            inc.Calculated_Amount__c = bonus.setScale(2, RoundingMode.HALF_UP);
            inc.Status__c = 'Calculated';

            bonusRecords.add(inc);
        }

        if (!bonusRecords.isEmpty()) {
            upsert bonusRecords;
        }

        return bonusRecords;
    }

    // ═══════════════════════════════════════════════════════════════
    // HELPER: Load user salaries from Employee__c
    // ═══════════════════════════════════════════════════════════════

    private static Map<Id, Decimal> loadUserSalaries(Set<Id> userIds) {
        Map<Id, Decimal> salaryMap = new Map<Id, Decimal>();

        // Map Employee__c to User via the User__c lookup field
        for (Employee__c emp : [
            SELECT Id, Gross_Salary__c, User__c
            FROM Employee__c
            WHERE User__c IN :userIds
            AND Is_Active__c = true
        ]) {
            if (emp.Gross_Salary__c != null && emp.User__c != null) {
                salaryMap.put(emp.User__c, emp.Gross_Salary__c);
            }
        }

        return salaryMap;
    }

    // ═══════════════════════════════════════════════════════════════
    // HELPER: Load user territories
    // ═══════════════════════════════════════════════════════════════

    private static Map<Id, Id> loadUserTerritories(Set<Id> userIds) {
        Map<Id, Id> territoryMap = new Map<Id, Id>();

        for (Employee__c emp : [
            SELECT Id, User__c, Territory__c
            FROM Employee__c
            WHERE User__c IN :userIds
            AND Is_Active__c = true
            AND Territory__c != null
        ]) {
            territoryMap.put(emp.User__c, emp.Territory__c);
        }

        return territoryMap;
    }
}