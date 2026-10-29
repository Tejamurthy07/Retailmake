/**
 * @description Service class for Target and Achievement Management. Provides
 *              methods for calculating achievement values, cascading targets
 *              from parent to child territories, and generating leaderboards.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class TAM_Achievement_Service {

    // ── Inner class: LeaderboardEntry ─────────────────────────────────────────

    /**
     * @description Represents a single entry in the leaderboard ranking.
     */
    public class LeaderboardEntry {
        /** The user's ID. */
        public Id userId { get; set; }
        /** The user's display name. */
        public String userName { get; set; }
        /** The assigned target value. */
        public Decimal targetValue { get; set; }
        /** The current achievement value. */
        public Decimal achievementValue { get; set; }
        /** Achievement as a percentage of target. */
        public Decimal achievementPercent { get; set; }
        /** The leaderboard rank (1 = top performer). */
        public Integer rank { get; set; }

        public LeaderboardEntry() {
            this.targetValue = 0;
            this.achievementValue = 0;
            this.achievementPercent = 0;
            this.rank = 0;
        }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * @description Calculates the current achievement value for a given target
     *              by aggregating actual data (orders, collections, visits, etc.)
     *              and updates the Target__c record in place.
     *
     * @param targetId The Target__c record ID to calculate achievements for.
     */
    public static void calculateAchievement(Id targetId) {
        if (targetId == null) {
            return;
        }

        Target__c target = getTarget(targetId);
        if (target == null) {
            return;
        }

        Decimal achievementValue = 0;

        // Calculate based on target type
        if (target.Target_Type__c == 'Revenue') {
            achievementValue = calculateRevenueAchievement(target);
        } else if (target.Target_Type__c == 'Volume') {
            achievementValue = calculateVolumeAchievement(target);
        } else if (target.Target_Type__c == 'Collection') {
            achievementValue = calculateCollectionAchievement(target);
        } else if (target.Target_Type__c == 'Visits') {
            achievementValue = calculateVisitAchievement(target);
        } else if (target.Target_Type__c == 'Productive Calls') {
            achievementValue = calculateProductiveCallAchievement(target);
        } else if (target.Target_Type__c == 'New Outlets') {
            achievementValue = calculateNewOutletAchievement(target);
        }

        // Calculate achievement percentage
        Decimal targetValue = target.Target_Value__c != null ? target.Target_Value__c : 0;
        Decimal achievementPercent = targetValue > 0
            ? (achievementValue / targetValue * 100).setScale(2, RoundingMode.HALF_UP)
            : 0;

        // Update the target record
        Target__c updateTarget = new Target__c(
            Id = targetId,
            Achievement_Value__c = achievementValue,
            Last_Calculated__c = DateTime.now()
        );
        update updateTarget;
    }

    /**
     * @description Cascades a parent territory target to child territories by
     *              splitting the target value proportionally based on historical
     *              contribution or equally if no history exists.
     *
     * @param parentTargetId The parent Target__c record ID to cascade from.
     */
    public static void cascadeTargets(Id parentTargetId) {
        if (parentTargetId == null) {
            return;
        }

        Target__c parentTarget = getTarget(parentTargetId);
        if (parentTarget == null || parentTarget.Territory__c == null) {
            return;
        }

        // Fetch child territories
       List<Company_Hierarchy__c> parentNodes = [
            SELECT Id FROM Company_Hierarchy__c
            WHERE Territory__c = :parentTarget.Territory__c
              AND Is_Active__c = true
            LIMIT 1
        ];
        if (parentNodes.isEmpty()) {
            return;
        }
        Id parentNodeId = parentNodes[0].Id;

        // Fetch child territories
        List<Company_Hierarchy__c> childTerritories = [
            SELECT Id, Name, Territory__c, Assigned_User__c
            FROM Company_Hierarchy__c
            WHERE Parent_Hierarchy__c = :parentNodeId
              AND Is_Active__c = true
        ];

        if (childTerritories.isEmpty()) {
            return;
        }

        // Calculate split ratios based on historical performance
        Map<Id, Decimal> splitRatios = calculateSplitRatios(
            parentTarget, childTerritories
        );

        // Create or update child targets
        Decimal parentValue = parentTarget.Target_Value__c != null
            ? parentTarget.Target_Value__c : 0;

        // Check for existing child targets
        Set<Id> childTerritoryIds = new Set<Id>();
        for (Company_Hierarchy__c child : childTerritories) {
            childTerritoryIds.add(child.Id);
        }

        Map<Id, Target__c> existingChildTargets = new Map<Id, Target__c>();
        for (Target__c existing : [
            SELECT Id, Territory__c
            FROM Target__c
            WHERE Parent_Target__c = :parentTargetId
              AND Territory__c IN :childTerritoryIds
        ]) {
            existingChildTargets.put(existing.Territory__c, existing);
        }

        List<Target__c> targetsToUpsert = new List<Target__c>();

        for (Company_Hierarchy__c child : childTerritories) {
            Decimal ratio = splitRatios.containsKey(child.Id)
                ? splitRatios.get(child.Id) : 0;
            Decimal childTargetValue = (parentValue * ratio)
                .setScale(2, RoundingMode.HALF_UP);

            Target__c childTarget;
            if (existingChildTargets.containsKey(child.Id)) {
                childTarget = existingChildTargets.get(child.Id);
            } else {
                childTarget = new Target__c();
                childTarget.Territory__c = child.Id;
                childTarget.Parent_Target__c = parentTargetId;
                childTarget.Target_Type__c = parentTarget.Target_Type__c;
                childTarget.Period_Start__c = parentTarget.Period_Start__c;
                childTarget.Period_End__c = parentTarget.Period_End__c;
                childTarget.Month__c = parentTarget.Month__c;
                childTarget.Year__c = parentTarget.Year__c;
                childTarget.User__c = child.Assigned_User__c;
            }

            childTarget.Target_Value__c = childTargetValue;
            childTarget.Status__c = 'Active';
            targetsToUpsert.add(childTarget);
        }

        if (!targetsToUpsert.isEmpty()) {
            upsert targetsToUpsert;
        }
    }

    /**
     * @description Generates a ranked leaderboard of user achievements for a
     *              specified period and target type.
     *
     * @param month      The month (as stored in Target__c.Month__c).
     * @param year       The year (as stored in Target__c.Year__c).
     * @param targetType The target type (Revenue, Volume, Collection, Visits, etc.).
     * @return A list of LeaderboardEntry objects sorted by achievement percentage descending.
     */
    public static List<LeaderboardEntry> getLeaderboard(
        String month,
        String year,
        String targetType
    ) {
        List<LeaderboardEntry> leaderboard = new List<LeaderboardEntry>();

        if (String.isBlank(month) || String.isBlank(year) || String.isBlank(targetType)) {
            return leaderboard;
        }

        List<Target__c> targets = [
            SELECT Id, User__c, User__r.Name,
                   Target_Value__c, Achievement_Value__c, Achievement_Percent__c
            FROM Target__c
            WHERE Month__c = :month
              AND Year__c = :year
              AND Target_Type__c = :targetType
              AND User__c != null
              AND Status__c = 'Active'
            ORDER BY Achievement_Percent__c DESC NULLS LAST
        ];

        Integer rank = 1;
        Decimal previousPercent = null;
        Integer previousRank = 0;

        for (Integer i = 0; i < targets.size(); i++) {
            Target__c target = targets[i];

            LeaderboardEntry entry = new LeaderboardEntry();
            entry.userId = target.User__c;
            entry.userName = target.User__r.Name;
            entry.targetValue = target.Target_Value__c != null
                ? target.Target_Value__c : 0;
            entry.achievementValue = target.Achievement_Value__c != null
                ? target.Achievement_Value__c : 0;
            entry.achievementPercent = target.Achievement_Percent__c != null
                ? target.Achievement_Percent__c : 0;

            // Handle tied ranks
            if (previousPercent != null &&
                entry.achievementPercent == previousPercent) {
                entry.rank = previousRank;
            } else {
                entry.rank = rank;
                previousRank = rank;
            }

            previousPercent = entry.achievementPercent;
            rank++;

            leaderboard.add(entry);
        }

        return leaderboard;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Fetches a Target__c record with all required fields.
     */
    private static Target__c getTarget(Id targetId) {
        List<Target__c> targets = [
            SELECT Id, Target_Type__c, Target_Value__c, Territory__c,
                   User__c, Period_Start__c, Period_End__c,
                   Month__c, Year__c, Achievement_Value__c,
                   Achievement_Percent__c, Product__c, Product_Category__c,
                   Parent_Target__c, Status__c
            FROM Target__c
            WHERE Id = :targetId
            LIMIT 1
        ];
        return targets.isEmpty() ? null : targets[0];
    }

    /**
     * @description Calculates revenue achievement by summing delivered order totals.
     */
    private static Decimal calculateRevenueAchievement(Target__c target) {
        AggregateResult[] results;

        if (target.User__c != null) {
            results = [
                SELECT SUM(Net_Amount__c) totalRevenue
                FROM Sales_Order__c
                WHERE Sales_Rep__c = :target.User__c
                  AND Order_Status__c IN ('Delivered', 'Dispatched', 'Processing')
                  AND Order_Date__c >= :target.Period_Start__c
                  AND Order_Date__c <= :target.Period_End__c
            ];
        } else {
            return 0;
        }

        if (results != null && !results.isEmpty()) {
            Decimal total = (Decimal) results[0].get('totalRevenue');
            return total != null ? total : 0;
        }
        return 0;
    }

    /**
     * @description Calculates volume achievement by summing order line item quantities.
     */
    private static Decimal calculateVolumeAchievement(Target__c target) {
        Id productId = target.Product__c;
        String query = 'SELECT SUM(Quantity__c) totalQuantity' +
            ' FROM Order_Line_Item__c' +
            ' WHERE Sales_Order__r.Sales_Rep__c = :userId' +
            ' AND Sales_Order__r.Order_Status__c IN (\'Delivered\', \'Dispatched\', \'Processing\')' +
            ' AND Sales_Order__r.Order_Date__c >= :periodStart' +
            ' AND Sales_Order__r.Order_Date__c <= :periodEnd';
        if (productId != null) {
            query += ' AND Product__c = :productId';
        }
        Id userId = target.User__c;
        Date periodStart = target.Period_Start__c;
        Date periodEnd = target.Period_End__c;
        AggregateResult[] results = Database.query(query);

        if (results != null && !results.isEmpty()) {
            Decimal total = (Decimal) results[0].get('totalQuantity');
            return total != null ? total : 0;
        }
        return 0;
    }

    /**
     * @description Calculates collection achievement by summing confirmed collections.
     */
    private static Decimal calculateCollectionAchievement(Target__c target) {
        AggregateResult[] results = [
            SELECT SUM(Amount__c) totalCollected
            FROM Collection__c
            WHERE Collected_By__c = :target.User__c
              AND Status__c IN ('Confirmed', 'Pending')
              AND Collection_Date__c >= :target.Period_Start__c
              AND Collection_Date__c <= :target.Period_End__c
        ];

        if (results != null && !results.isEmpty()) {
            Decimal total = (Decimal) results[0].get('totalCollected');
            return total != null ? total : 0;
        }
        return 0;
    }

    /**
     * @description Calculates visit count achievement.
     */
    private static Decimal calculateVisitAchievement(Target__c target) {
        AggregateResult[] results = [
            SELECT COUNT(Id) totalVisits
            FROM Visit__c
            WHERE User__c = :target.User__c
              AND Visit_Date__c >= :target.Period_Start__c
              AND Visit_Date__c <= :target.Period_End__c
              AND Visit_Status__c IN ('Completed', 'In Progress')
        ];

        if (results != null && !results.isEmpty()) {
            Integer total = (Integer) results[0].get('totalVisits');
            return total != null ? total : 0;
        }
        return 0;
    }

    /**
     * @description Calculates productive call achievement.
     */
    private static Decimal calculateProductiveCallAchievement(Target__c target) {
        AggregateResult[] results = [
            SELECT COUNT(Id) productiveCalls
            FROM Visit__c
            WHERE User__c = :target.User__c
              AND Visit_Date__c >= :target.Period_Start__c
              AND Visit_Date__c <= :target.Period_End__c
              AND Visit_Status__c = 'Completed'
              AND Is_Productive__c = true
        ];

        if (results != null && !results.isEmpty()) {
            Integer total = (Integer) results[0].get('productiveCalls');
            return total != null ? total : 0;
        }
        return 0;
    }

    /**
     * @description Calculates new outlet registration achievement.
     */
    private static Decimal calculateNewOutletAchievement(Target__c target) {
        AggregateResult[] results = [
            SELECT COUNT(Id) newOutlets
            FROM Account
            WHERE OwnerId = :target.User__c
              AND CreatedDate >= :target.Period_Start__c
              AND CreatedDate <= :target.Period_End__c
              AND RecordType.DeveloperName = 'Outlet'
        ];

        if (results != null && !results.isEmpty()) {
            Integer total = (Integer) results[0].get('newOutlets');
            return total != null ? total : 0;
        }
        return 0;
    }

    /**
     * @description Calculates split ratios for target cascading based on
     *              historical performance. Falls back to equal distribution
     *              if no history is available.
     */
    private static Map<Id, Decimal> calculateSplitRatios(
        Target__c parentTarget,
        List<Company_Hierarchy__c> childTerritories
    ) {
        Map<Id, Decimal> ratios = new Map<Id, Decimal>();
        Integer childCount = childTerritories.size();

        if (childCount == 0) {
            return ratios;
        }

        // Try to calculate from historical targets
        Set<Id> childIds = new Set<Id>();
        for (Company_Hierarchy__c child : childTerritories) {
            childIds.add(child.Id);
        }

        // Look for previous period's achievement data
        Map<Id, Decimal> historicalValues = new Map<Id, Decimal>();
        Decimal totalHistorical = 0;

        for (Target__c historical : [
            SELECT Territory__c, Achievement_Value__c
            FROM Target__c
            WHERE Territory__c IN :childIds
              AND Target_Type__c = :parentTarget.Target_Type__c
              AND Status__c = 'Active'
              AND Year__c != null
            ORDER BY Year__c DESC, Month__c DESC
            LIMIT 100
        ]) {
            if (!historicalValues.containsKey(historical.Territory__c)) {
                Decimal val = historical.Achievement_Value__c != null
                    ? historical.Achievement_Value__c : 0;
                historicalValues.put(historical.Territory__c, val);
                totalHistorical += val;
            }
        }

        // If we have historical data, use proportional split
        if (totalHistorical > 0 && historicalValues.size() == childCount) {
            for (Company_Hierarchy__c child : childTerritories) {
                Decimal childVal = historicalValues.containsKey(child.Id)
                    ? historicalValues.get(child.Id) : 0;
                ratios.put(child.Id, childVal / totalHistorical);
            }
        } else {
            // Fall back to equal distribution
            Decimal equalRatio = (Decimal) 1.0 / childCount;
            for (Company_Hierarchy__c child : childTerritories) {
                ratios.put(child.Id, equalRatio);
            }
        }

        return ratios;
    }
}