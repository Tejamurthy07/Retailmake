/**
 * @description Scheduler for automated incentive calculation.
 *
 *              Runs for the most recently ended period of each type:
 *              - Monthly: runs on 1st of every month for previous month
 *              - Quarterly: runs on 1st of Jan/Apr/Jul/Oct for previous quarter
 *              - Annual: runs on 1st of April for previous financial year
 *
 *              Schedule:
 *              System.schedule('TAM Monthly Incentive Calc', '0 0 2 1 * ?', new TAM_IncentiveCalculation_Scheduler());
 */
public class TAM_IncentiveCalculation_Scheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        Date today = Date.today();

        // Find the most recently ended active period
        List<Target_Period__c> periods = [
            SELECT Id, Name, Type__c, Is_Cumulative__c, Parent_Period__c
            FROM Target_Period__c
            WHERE End_Date__c < :today
            AND Is_Active__c = true
            ORDER BY End_Date__c DESC
            LIMIT 1
        ];

        if (!periods.isEmpty()) {
            Target_Period__c period = periods[0];

            // For yearly periods, also calculate annual bonus
            Boolean calcBonus = (period.Type__c == 'Yearly');

            Database.executeBatch(
                new TAM_IncentiveCalculation_Batch(period.Id, calcBonus), 50
            );
        }
    }
}