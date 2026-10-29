public class TAM_Rollup_Service {

    /**
     * Scope contains the Target_Actual__c rows for one batch chunk.
     * We roll up only the affected users and their managers.
     */
    public static void run(List<Target_Actual__c> scope) {

        if (scope.isEmpty()) return;

        // ============ 1. Identify Affected Users, Criteria, Periods ============
        Set<Id> affectedUsers = new Set<Id>();
        Set<Id> criteriaIds   = new Set<Id>();
        Set<Id> periodIds     = new Set<Id>();

        for (Target_Actual__c t : scope) {
            affectedUsers.add(t.User__c);
            criteriaIds.add(t.Target_Criteria__c);
            periodIds.add(t.Target_Period__c);
        }

        // ============ 2. Load managers recursively (full hierarchy for affected users) ============
        Set<Id> hierarchyUsers = new Set<Id>();
        hierarchyUsers.addAll(affectedUsers);

        Map<Id, Id> userToManager = new Map<Id, Id>();

        List<User> userRows = [
            SELECT Id, ManagerId
            FROM User
            WHERE Id IN :affectedUsers
        ];

        for (User u : userRows) {
            if (u.ManagerId != null) {
                hierarchyUsers.add(u.ManagerId);
                userToManager.put(u.Id, u.ManagerId);
            }
        }

        // ============ 3. Load all relevant Target_Actual__c rows ============
        List<Target_Actual__c> allRows = [
            SELECT Id, User__c, User__r.ManagerId,
                   Target_Period__c, Target_Criteria__c,
                   Target_Value__c, Achievement_Value__c,
                   Teams_Target__c, Teams_Achievement__c
            FROM Target_Actual__c
            WHERE User__c IN :hierarchyUsers
            AND Target_Criteria__c IN :criteriaIds
            AND Target_Period__c IN :periodIds
        ];

        if (allRows.isEmpty()) return;

        // ============ 4. Group children by (Manager + Criteria + Period) ============
        Map<String, List<Target_Actual__c>> mgrKeyToChildren = new Map<String, List<Target_Actual__c>>();

        for (Target_Actual__c child : allRows) {

            if (child.User__r.ManagerId == null) continue;

            String key = child.User__r.ManagerId
                         + '-' + child.Target_Criteria__c
                         + '-' + child.Target_Period__c;

            if (!mgrKeyToChildren.containsKey(key)) {
                mgrKeyToChildren.put(key, new List<Target_Actual__c>());
            }
            mgrKeyToChildren.get(key).add(child);
        }

        // ============ 5. Update parent Team rollups ============

        Map<Id, Target_Actual__c> idToRow = new Map<Id, Target_Actual__c>();
        for (Target_Actual__c row : allRows) idToRow.put(row.Id, row);

        List<Target_Actual__c> updates = new List<Target_Actual__c>();

        for (Target_Actual__c parent : allRows) {

            String key = parent.User__c
                         + '-' + parent.Target_Criteria__c
                         + '-' + parent.Target_Period__c;

            Decimal teamTarget = 0;
            Decimal teamAch    = 0;

            if (mgrKeyToChildren.containsKey(key)) {

                for (Target_Actual__c child : mgrKeyToChildren.get(key)) {

                    if (child.Target_Value__c != null)
                        teamTarget += child.Target_Value__c;

                    if (child.Achievement_Value__c != null)
                        teamAch += child.Achievement_Value__c;
                }
            }

            parent.Teams_Target__c      = teamTarget;
            parent.Teams_Achievement__c = teamAch;

            updates.add(parent);
        }

        if (!updates.isEmpty()) {
            update updates;
        }
    }
}