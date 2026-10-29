public class TAM_TargetAllocation_Controller {

    public class DataBox {
        @AuraEnabled public List<User> userList;
        @AuraEnabled public List<Target_Period__c> periodsList;
        @AuraEnabled public List<Target_Period__c> currentPeriods;
        @AuraEnabled public String period;
        @AuraEnabled public List<Target_Criteria__c> targetCriterias;
        @AuraEnabled public String currentUserId;
        @AuraEnabled public List<Target_Actual__c> targetActuals;
        @AuraEnabled public Boolean isAdmin;
        @AuraEnabled public Map<Id, Decimal> parentToTotalTargetValueMap;
    }

    @AuraEnabled
    public static DataBox getAllData() {
        DataBox dx = new DataBox();

        Set<ID> userIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(UserInfo.getUserId());

        dx.userList = [
            SELECT Id, Name, ManagerId, Manager.ManagerId, Profile.Name
            FROM User
            WHERE Id IN :userIds
            AND IsActive = true
            ORDER BY Name
        ];

        // Check if current user is in the hierarchy list
        Boolean isCurrentUserPresent = false;
        for (User u : dx.userList) {
            if (u.Id == UserInfo.getUserId()) {
                isCurrentUserPresent = true;
                break;
            }
        }
        dx.currentUserId = isCurrentUserPresent ? UserInfo.getUserId() : '';

        // Admin status via Custom Permission (managed-package portable)
        // Fallback checks the "Modify All Data" permission on the user's profile,
        // which is a license-level flag that doesn't depend on profile naming.
        if (FeatureManagement.checkPermission('TAM_Admin_Access')) {
            dx.isAdmin = true;
        } else {
            List<User> adminCheck = [
                SELECT Profile.PermissionsModifyAllData
                FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
            ];
            dx.isAdmin = !adminCheck.isEmpty()
                && adminCheck[0].Profile.PermissionsModifyAllData == true;
        }

        dx.periodsList = [
            SELECT Id, Name, Start_Date__c, End_Date__c
            FROM Target_Period__c
            WHERE Is_Active__c = true
            ORDER BY Start_Date__c DESC
            LIMIT 20
        ];

        // Find default period first, then fall back to current date match
        List<Target_Period__c> currentPeriodList = [
            SELECT Id FROM Target_Period__c
            WHERE Is_Default__c = true AND Is_Active__c = true
            LIMIT 1
        ];
        if (currentPeriodList.isEmpty()) {
            currentPeriodList = [
                SELECT Id FROM Target_Period__c
                WHERE Start_Date__c <= TODAY AND End_Date__c >= TODAY
                AND Is_Active__c = true
                ORDER BY Type__c ASC
                LIMIT 1
            ];
        }
        dx.period = currentPeriodList.isEmpty() ? '' : currentPeriodList[0].Id;

        if (String.isNotBlank(dx.period)) {
            dx.targetActuals = queryTargetActuals(dx.period, userIds);
        } else {
            dx.targetActuals = new List<Target_Actual__c>();
        }

        // Current and future periods for admin target creation
        dx.currentPeriods = [
            SELECT Id, Name, Start_Date__c, End_Date__c
            FROM Target_Period__c
            WHERE End_Date__c >= TODAY AND Is_Active__c = true
            ORDER BY Start_Date__c
        ];

        return dx;
    }

    @AuraEnabled
    public static List<Target_Actual__c> getTargetActuals(String period, String userId) {
        if (String.isBlank(period)) {
            List<Target_Period__c> currentPeriodList = [
                SELECT Id FROM Target_Period__c
                WHERE Is_Default__c = true AND Is_Active__c = true
                LIMIT 1
            ];
            period = currentPeriodList.isEmpty() ? '' : currentPeriodList[0].Id;
        }
        if (String.isBlank(period)) return new List<Target_Actual__c>();

        String currentUserId = String.isNotBlank(userId) ? userId : UserInfo.getUserId();
        Set<ID> userIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(currentUserId);

        return queryTargetActuals(period, userIds);
    }

    @AuraEnabled
    public static DataBox getUserTargets(String period, String userId) {
        DataBox dx = new DataBox();
        if (String.isBlank(period)) {
            List<Target_Period__c> currentPeriodList = [
                SELECT Id FROM Target_Period__c
                WHERE Is_Default__c = true AND Is_Active__c = true
                LIMIT 1
            ];
            period = currentPeriodList.isEmpty() ? '' : currentPeriodList[0].Id;
        }
        if (String.isBlank(period)) return dx;

        dx.targetCriterias = [
            SELECT Id, Name, Object__c, Field__c, Operator__c, Date_Field__c, User_Field__c, Category__c
            FROM Target_Criteria__c
            WHERE Active__c = true
            ORDER BY Name
        ];

        dx.targetActuals = [
            SELECT Id, Target_Period__c, Target_Value__c, Achievement_Value__c, Target_Criteria__c,
                   Target_Criteria__r.Name, User__c, User__r.Name, Parent_Target__c,
                   Teams_Target__c, Teams_Achievement__c, Pending_Target__c
            FROM Target_Actual__c
            WHERE Target_Criteria__r.Active__c = true
            AND (Target_Period__c = :period OR Parent_Target__r.Target_Period__c = :period)
            AND User__c = :userId
            ORDER BY Target_Criteria__r.Name
        ];

        // Calculate subordinate totals per parent target
        if (!dx.targetActuals.isEmpty()) {
            List<Id> parentIds = new List<Id>();
            for (Target_Actual__c ta : dx.targetActuals) {
                parentIds.add(ta.Id);
            }

            dx.parentToTotalTargetValueMap = new Map<Id, Decimal>();

            if (!parentIds.isEmpty()) {
                // Alias the grouped field (pid) so the AggregateResult key is
                // namespace-independent (ftretailmake__Parent_Target__c otherwise
                // breaks ar.get in the managed package).
                AggregateResult[] groupedResults = [
                    SELECT Parent_Target__c pid, SUM(Target_Value__c) totalTargetValue
                    FROM Target_Actual__c
                    WHERE Parent_Target__c IN :parentIds
                    GROUP BY Parent_Target__c
                ];

                for (AggregateResult ar : groupedResults) {
                    Id parentId = (Id) ar.get('pid');
                    Decimal totalValue = (Decimal) ar.get('totalTargetValue');
                    dx.parentToTotalTargetValueMap.put(parentId, totalValue);
                }
            }
        }

        return dx;
    }

    @AuraEnabled
    public static List<Target_Actual__c> saveTargets(String targetList, String selectedPeriod) {
        List<Target_Actual__c> targetActualList = (List<Target_Actual__c>) JSON.deserialize(targetList, List<Target_Actual__c>.class);

        String currentUserId = UserInfo.getUserId();
        Set<ID> userIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(currentUserId);

        List<Target_Actual__c> itemsToUpdate = new List<Target_Actual__c>();

        for (Target_Actual__c itm : targetActualList) {
            if (itm.Target_Value__c != null && itm.Target_Value__c != 0) {
                Target_Actual__c item1 = new Target_Actual__c();
                item1.Target_Criteria__c = itm.Target_Criteria__c;
                item1.Target_Value__c = itm.Target_Value__c;
                item1.Parent_Target__c = itm.Parent_Target__c;
                item1.Target_Period__c = selectedPeriod;
                item1.User__c = itm.User__c;
                item1.OwnerId = itm.User__c;

                if (itm.Id != null) {
                    item1.Id = itm.Id;
                }

                itemsToUpdate.add(item1);
            }
        }

        if (!itemsToUpdate.isEmpty()) {
            upsert itemsToUpdate;
            TAM_Rollup_Service.run(itemsToUpdate);
        }

        return queryTargetActuals(selectedPeriod, userIds);
    }

    @AuraEnabled
    public static List<Target_Actual__c> saveAdminTargets(List<Target_Actual__c> targetActuals, String selectedAdminPeriod, String selectedPeriod, String userId) {
        if (!targetActuals.isEmpty()) {
            for (Target_Actual__c ta : targetActuals) {
                ta.Target_Period__c = selectedAdminPeriod;
                ta.User__c = userId;
                ta.OwnerId = userId;
                if (ta.Achievement_Value__c == null) {
                    ta.Achievement_Value__c = 0;
                }
            }
            upsert targetActuals;
        }

        Set<ID> userIds = TAM_RoleHierarchy_Service.getRoleSubordinateUsers(UserInfo.getUserId());
        return queryTargetActuals(selectedPeriod, userIds);
    }

    // ===== INLINE EDIT: Save single target value =====
    @AuraEnabled
    public static Target_Actual__c saveInlineTarget(Id targetId, Decimal targetValue) {
        Target_Actual__c ta = [
            SELECT Id, Target_Value__c
            FROM Target_Actual__c
            WHERE Id = :targetId
        ];
        ta.Target_Value__c = targetValue;
        update ta;

        return [
            SELECT Id, Target_Period__c, Target_Value__c, Achievement_Value__c, Target_Criteria__c,
                   Target_Criteria__r.Name, User__c, User__r.Name, Parent_Target__c,
                   Teams_Target__c, Teams_Achievement__c, Pending_Target__c
            FROM Target_Actual__c
            WHERE Id = :targetId
        ];
    }

    @AuraEnabled
    public static String syncAchievements(String periodId) {
        if (String.isBlank(periodId)) {
            throw new AuraHandledException('Please select a period first.');
        }
        Database.executeBatch(new TAM_Achievement_Batch(periodId), 50);
        return 'Achievement sync started. Click refresh in a few seconds to see updated values.';
    }

    // Shared query method
    private static List<Target_Actual__c> queryTargetActuals(String period, Set<Id> userIds) {
        return [
            SELECT Id, Target_Period__c, Target_Value__c, Achievement_Value__c, Target_Criteria__c,
                   Target_Criteria__r.Name, User__c, User__r.Name, Parent_Target__c,
                   Teams_Target__c, Teams_Achievement__c, Pending_Target__c
            FROM Target_Actual__c
            WHERE Target_Criteria__r.Active__c = true
            AND (Target_Period__c = :period OR Parent_Target__r.Target_Period__c = :period)
            AND User__c IN :userIds
            ORDER BY Target_Criteria__r.Name
        ];
    }
}