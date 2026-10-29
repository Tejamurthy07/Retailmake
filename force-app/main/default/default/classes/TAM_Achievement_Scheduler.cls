/**
 * @description Schedulable class to run the TAM Achievement Batch on a recurring basis.
 *              Calculates achievement values for all active Target_Actual__c records
 *              where the Target_Period covers the current date.
 *
 * Usage (Execute Anonymous):
 *   // Schedule daily at 6 AM
 *   System.schedule('TAM Achievement Calculation', '0 0 6 * * ?', new TAM_Achievement_Scheduler());
 *
 *   // Schedule every 4 hours
 *   System.schedule('TAM Achievement Calculation', '0 0 0/4 * * ?', new TAM_Achievement_Scheduler());
 *
 * @author  SFA Development Team
 */
public class TAM_Achievement_Scheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        Database.executeBatch(new TAM_Achievement_Batch(), 50);
    }
}