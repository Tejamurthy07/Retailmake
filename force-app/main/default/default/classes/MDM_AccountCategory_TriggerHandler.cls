public with sharing class MDM_AccountCategory_TriggerHandler {

    public void beforeInsert(List<Account_Category__c> newList) {
        setDefaults(newList);
        preventDuplicates(newList, null);
    }

    public void beforeUpdate(List<Account_Category__c> newList, Map<Id, Account_Category__c> oldMap) {
        preventDuplicates(newList, oldMap);
    }

    private void setDefaults(List<Account_Category__c> records) {
        for (Account_Category__c ac : records) {
            if (ac.Assigned_By__c == null) {
                ac.Assigned_By__c = UserInfo.getUserId();
            }
        }
    }

    private void preventDuplicates(List<Account_Category__c> newList, Map<Id, Account_Category__c> oldMap) {
        Map<String, List<Account_Category__c>> groupedByKey = new Map<String, List<Account_Category__c>>();
        Set<Id> accountIds = new Set<Id>();
        Set<Id> categoryIds = new Set<Id>();

        for (Account_Category__c ac : newList) {
            if (!ac.Is_Active__c) continue;
            accountIds.add(ac.Account__c);
            categoryIds.add(ac.Category__c);
            String key = ac.Account__c + ':' + ac.Category__c;
            if (!groupedByKey.containsKey(key)) {
                groupedByKey.put(key, new List<Account_Category__c>());
            }
            groupedByKey.get(key).add(ac);
        }

        if (groupedByKey.isEmpty()) return;

        Set<Id> excludeIds = new Set<Id>();
        if (oldMap != null) {
            excludeIds = oldMap.keySet();
        }

        List<Account_Category__c> existingMappings = [
            SELECT Id, Account__c, Category__c, Effective_From__c, Effective_To__c
            FROM Account_Category__c
            WHERE Account__c IN :accountIds
            AND Category__c IN :categoryIds
            AND Is_Active__c = true
            AND Id NOT IN :excludeIds
        ];

        for (Account_Category__c ac : newList) {
            if (!ac.Is_Active__c) continue;
            for (Account_Category__c existing : existingMappings) {
                if (existing.Account__c == ac.Account__c
                    && existing.Category__c == ac.Category__c
                    && datesOverlap(ac.Effective_From__c, ac.Effective_To__c,
                                    existing.Effective_From__c, existing.Effective_To__c)) {
                    ac.addError('An active mapping already exists for this Account and Category with overlapping dates.');
                    break;
                }
            }
        }
    }

    private Boolean datesOverlap(Date fromA, Date toA, Date fromB, Date toB) {
        Date startA = fromA != null ? fromA : Date.newInstance(1900, 1, 1);
        Date endA = toA != null ? toA : Date.newInstance(2999, 12, 31);
        Date startB = fromB != null ? fromB : Date.newInstance(1900, 1, 1);
        Date endB = toB != null ? toB : Date.newInstance(2999, 12, 31);
        return startA <= endB && startB <= endA;
    }
}