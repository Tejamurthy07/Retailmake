public with sharing class TAM_RoleHierarchy_Service {

    private static Map<Id, Set<Id>> subordinateCache = new Map<Id, Set<Id>>();
    private static Map<Id, Set<Id>> managerToDirects;

    public static Set<Id> getRoleSubordinateUsers(Id userId) {
        if (subordinateCache.containsKey(userId)) {
            return subordinateCache.get(userId);
        }

        ensureHierarchyLoaded();

        Set<Id> allSubs = new Set<Id>();
        Set<Id> currentLevel = new Set<Id>();
        if (managerToDirects.containsKey(userId)) {
            currentLevel.addAll(managerToDirects.get(userId));
        }

        Integer depth = 0;
        while (!currentLevel.isEmpty() && depth < 8) {
            allSubs.addAll(currentLevel);
            Set<Id> nextLevel = new Set<Id>();
            for (Id uid : currentLevel) {
                if (managerToDirects.containsKey(uid)) {
                    nextLevel.addAll(managerToDirects.get(uid));
                }
            }
            nextLevel.removeAll(allSubs);
            currentLevel = nextLevel;
            depth++;
        }

        allSubs.add(userId);
        subordinateCache.put(userId, allSubs);
        return allSubs;
    }

    private static void ensureHierarchyLoaded() {
        if (managerToDirects != null) return;
        managerToDirects = new Map<Id, Set<Id>>();
        for (User u : [
            SELECT Id, ManagerId
            FROM User
            WHERE IsActive = true
            AND ManagerId != null
        ]) {
            if (!managerToDirects.containsKey(u.ManagerId)) {
                managerToDirects.put(u.ManagerId, new Set<Id>());
            }
            managerToDirects.get(u.ManagerId).add(u.Id);
        }
    }

    public static void clearCache() {
        subordinateCache = new Map<Id, Set<Id>>();
        managerToDirects = null;
    }
}