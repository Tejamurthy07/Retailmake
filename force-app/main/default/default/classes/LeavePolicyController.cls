/**
 * @description Controller for Leave Policy management and balance initialization.
 */
public with sharing class LeavePolicyController {

    @AuraEnabled(cacheable=false)
    public static List<Leave_Policy__c> getAllPolicies() {
        return [
            SELECT Id, Name, Leave_Type__c, Designation__c, Annual_Entitlement__c,
                   Monthly_Accrual__c, Max_Carry_Forward__c, Encashable__c,
                   Is_Active__c, Effective_Year__c, CreatedDate
            FROM Leave_Policy__c
            ORDER BY Leave_Type__c, Designation__c NULLS LAST
            LIMIT 200
        ];
    }

    @AuraEnabled(cacheable=false)
    public static Leave_Policy__c getPolicy(Id policyId) {
        return [
            SELECT Id, Name, Leave_Type__c, Designation__c, Annual_Entitlement__c,
                   Monthly_Accrual__c, Max_Carry_Forward__c, Encashable__c,
                   Is_Active__c, Effective_Year__c
            FROM Leave_Policy__c WHERE Id = :policyId
        ];
    }

    @AuraEnabled
    public static Leave_Policy__c savePolicy(Leave_Policy__c policy) {
        upsert policy;
        return getPolicy(policy.Id);
    }

    @AuraEnabled
    public static void deletePolicy(Id policyId) {
        delete [SELECT Id FROM Leave_Policy__c WHERE Id = :policyId];
    }

    @AuraEnabled
    public static void toggleActive(Id policyId, Boolean isActive) {
        Leave_Policy__c p = [SELECT Id FROM Leave_Policy__c WHERE Id = :policyId];
        p.Is_Active__c = isActive;
        update p;
    }

    @AuraEnabled
    public static String initializeBalances(String year) {
        LeaveBalanceService.initializeYearlyBalances(year);
        Integer count = [SELECT COUNT() FROM Leave_Balance__c WHERE Year__c = :year];
        return 'Initialized ' + count + ' leave balances for year ' + year;
    }

    @AuraEnabled
    public static String runAccrual(String year) {
        LeaveBalanceService.runMonthlyAccrual(year);
        return 'Monthly accrual completed for year ' + year;
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getBalanceSummary(String year) {
        Map<String, Object> result = new Map<String, Object>();

        result.put('totalBalances', [SELECT COUNT() FROM Leave_Balance__c WHERE Year__c = :year]);
        result.put('totalPolicies', [SELECT COUNT() FROM Leave_Policy__c WHERE Is_Active__c = true]);
        result.put('totalEmployees', [SELECT COUNT() FROM Employee__c WHERE Is_Active__c = true]);

        return result;
    }
}