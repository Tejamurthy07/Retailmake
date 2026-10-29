/**
 * @description Batch job for bulk incentive calculation. Supports:
 *              - Standard period calculation (Monthly/Quarterly/Yearly)
 *              - Cumulative quarterly/annual calculation
 *              - Annual bonus calculation (best 3 of 4 quarters)
 *
 *              Usage:
 *              Database.executeBatch(new TAM_IncentiveCalculation_Batch(periodId), 50);
 *              Database.executeBatch(new TAM_IncentiveCalculation_Batch(periodId, true), 50); // with annual bonus
 */
public class TAM_IncentiveCalculation_Batch implements Database.Batchable<SObject>, Database.Stateful {

    private Id periodId;
    private Boolean calculateAnnualBonus;
    private Integer totalProcessed = 0;
    private Integer totalIncentivesCreated = 0;

    public TAM_IncentiveCalculation_Batch(Id periodId) {
        this.periodId = periodId;
        this.calculateAnnualBonus = false;
    }

    public TAM_IncentiveCalculation_Batch(Id periodId, Boolean calculateAnnualBonus) {
        this.periodId = periodId;
        this.calculateAnnualBonus = calculateAnnualBonus;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // For cumulative periods, the service handles child period aggregation internally
        // We still query the parent period's direct actuals as the starting scope
        return Database.getQueryLocator([
            SELECT Id, User__c, Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Criteria__r.Incentive_Weight__c,
                   Target_Criteria__r.Prerequisite_Criteria__c,
                   Target_Criteria__r.Prerequisite_Min_Percent__c,
                   Target_Value__c, Achievement_Value__c,
                   Teams_Target__c, Teams_Achievement__c,
                   Target_Period__c, Target_Period__r.Start_Date__c,
                   Target_Period__r.End_Date__c, Target_Period__r.Type__c
            FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND Target_Criteria__r.Active__c = true
            AND Target_Value__c > 0
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Target_Actual__c> scope) {
        if (scope.isEmpty()) return;

        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(scope, periodId);

        totalProcessed += scope.size();
        totalIncentivesCreated += results.size();
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('TAM_IncentiveCalculation_Batch completed. Processed: ' +
            totalProcessed + ', Incentives created/updated: ' + totalIncentivesCreated);

        // Calculate annual bonus if requested and this is a yearly period
        if (calculateAnnualBonus) {
            List<Incentive__c> bonuses = TAM_IncentiveCalculation_Service.calculateAnnualBonus(periodId);
            System.debug('Annual bonuses calculated: ' + bonuses.size());
        }
    }
}