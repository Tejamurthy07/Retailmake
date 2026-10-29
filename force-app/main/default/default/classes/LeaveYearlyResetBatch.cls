/**
 * @description Batch job to initialize leave balances for a new fiscal year.
 *              Creates Leave_Balance__c records for all active employees based
 *              on Leave_Policy__c records. Handles carry forward from previous year.
 *
 *              Usage: Database.executeBatch(new LeaveYearlyResetBatch('2026'), 200);
 *              Schedule: Run once at the start of each fiscal year (April 1st).
 */
public class LeaveYearlyResetBatch implements Database.Batchable<SObject>, Database.Stateful {

    private String year;
    private Integer totalCreated = 0;

    public LeaveYearlyResetBatch(String year) {
        this.year = year;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Designation__c FROM Employee__c WHERE Is_Active__c = true
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Employee__c> scope) {
        // Load policies
        List<Leave_Policy__c> policies = [
            SELECT Id, Leave_Type__c, Designation__c, Annual_Entitlement__c,
                   Monthly_Accrual__c, Max_Carry_Forward__c
            FROM Leave_Policy__c
            WHERE Is_Active__c = true
            AND (Effective_Year__c = :year OR Effective_Year__c = null)
            ORDER BY Designation__c NULLS LAST
        ];

        if (policies.isEmpty()) return;

        // Get employee IDs in scope
        Set<Id> empIds = new Set<Id>();
        for (Employee__c e : scope) empIds.add(e.Id);

        // Load previous year balances
        String prevYear = String.valueOf(Integer.valueOf(year) - 1);
        Map<String, Leave_Balance__c> prevMap = new Map<String, Leave_Balance__c>();
        for (Leave_Balance__c lb : [
            SELECT Employee__c, Leave_Type__c, Available__c
            FROM Leave_Balance__c
            WHERE Employee__c IN :empIds AND Year__c = :prevYear
        ]) {
            prevMap.put(lb.Employee__c + '-' + lb.Leave_Type__c, lb);
        }

        // Check existing for this year
        Set<String> existing = new Set<String>();
        for (Leave_Balance__c lb : [
            SELECT Employee__c, Leave_Type__c FROM Leave_Balance__c
            WHERE Employee__c IN :empIds AND Year__c = :year
        ]) {
            existing.add(lb.Employee__c + '-' + lb.Leave_Type__c);
        }

        List<Leave_Balance__c> toInsert = new List<Leave_Balance__c>();

        for (Employee__c emp : scope) {
            Set<String> matchedTypes = new Set<String>();

            for (Leave_Policy__c policy : policies) {
                // Designation matching: specific first, then universal
                if (policy.Designation__c != null &&
                    !policy.Designation__c.equalsIgnoreCase(emp.Designation__c)) continue;

                String key = emp.Id + '-' + policy.Leave_Type__c;
                if (existing.contains(key) || matchedTypes.contains(policy.Leave_Type__c)) continue;

                Decimal entitlement = policy.Annual_Entitlement__c != null ? policy.Annual_Entitlement__c : 0;
                Decimal monthlyAccrual = policy.Monthly_Accrual__c != null ? policy.Monthly_Accrual__c : 0;
                Decimal maxCarry = policy.Max_Carry_Forward__c != null ? policy.Max_Carry_Forward__c : 0;

                Decimal carryForward = 0;
                if (maxCarry > 0 && prevMap.containsKey(key)) {
                    Decimal unused = prevMap.get(key).Available__c;
                    carryForward = Math.min(unused != null ? Math.max(unused, 0) : 0, maxCarry);
                }

                Decimal initialAccrued = (monthlyAccrual == 0) ? entitlement : 0;

                toInsert.add(new Leave_Balance__c(
                    Employee__c = emp.Id,
                    Leave_Type__c = policy.Leave_Type__c,
                    Year__c = year,
                    Entitled__c = entitlement,
                    Accrued__c = initialAccrued,
                    Carry_Forward__c = carryForward,
                    Used__c = 0,
                    Pending__c = 0,
                    Leave_Policy__c = policy.Id
                ));

                matchedTypes.add(policy.Leave_Type__c);
            }
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
            totalCreated += toInsert.size();
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('LeaveYearlyResetBatch completed. Created ' + totalCreated + ' balances for year ' + year);
    }
}