public with sharing class MDM_EmployeeCategory_TriggerHandler {

    public void beforeInsert(List<Employee_Category__c> newList) {
        setDefaults(newList);
        preventDuplicates(newList, null);
    }

    public void beforeUpdate(List<Employee_Category__c> newList, Map<Id, Employee_Category__c> oldMap) {
        preventDuplicates(newList, oldMap);
    }

    private void setDefaults(List<Employee_Category__c> records) {
        for (Employee_Category__c ec : records) {
            if (ec.Assigned_By__c == null) {
                ec.Assigned_By__c = UserInfo.getUserId();
            }
        }
    }

    private void preventDuplicates(List<Employee_Category__c> newList, Map<Id, Employee_Category__c> oldMap) {
        Set<Id> employeeIds = new Set<Id>();
        Set<Id> categoryIds = new Set<Id>();

        for (Employee_Category__c ec : newList) {
            if (!ec.Is_Active__c) continue;
            employeeIds.add(ec.Employee__c);
            categoryIds.add(ec.Category__c);
        }

        if (employeeIds.isEmpty()) return;

        Set<Id> excludeIds = new Set<Id>();
        if (oldMap != null) {
            excludeIds = oldMap.keySet();
        }

        List<Employee_Category__c> existingMappings = [
            SELECT Id, Employee__c, Category__c, Effective_From__c, Effective_To__c
            FROM Employee_Category__c
            WHERE Employee__c IN :employeeIds
            AND Category__c IN :categoryIds
            AND Is_Active__c = true
            AND Id NOT IN :excludeIds
        ];

        for (Employee_Category__c ec : newList) {
            if (!ec.Is_Active__c) continue;
            for (Employee_Category__c existing : existingMappings) {
                if (existing.Employee__c == ec.Employee__c
                    && existing.Category__c == ec.Category__c
                    && datesOverlap(ec.Effective_From__c, ec.Effective_To__c,
                                    existing.Effective_From__c, existing.Effective_To__c)) {
                    ec.addError('An active mapping already exists for this Employee and Category with overlapping dates.');
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