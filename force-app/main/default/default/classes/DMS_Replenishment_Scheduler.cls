/**
 * @description Scheduler for DMS replenishment. Generates draft replenishment
 *              orders (Primary_Order__c) across all distributors on a recurring
 *              schedule.
 * @author  SFA Development Team
 * @date    2024
 */
public class DMS_Replenishment_Scheduler implements Schedulable {

    /** Default daily run time: 6am. */
    public static final String DEFAULT_CRON = '0 0 6 * * ?';
    public static final String JOB_NAME = 'DMS Replenishment';

    public void execute(SchedulableContext sc) {
        DMS_Replenishment_Service.generateAll();
    }

    /**
     * @description One-time registration helper — run once from an admin
     *              (Execute Anonymous) to enrol the daily replenishment job:
     *              `DMS_Replenishment_Scheduler.schedule();`
     * @return The scheduled job (CronTrigger) id.
     */
    public static Id schedule() {
        return System.schedule(JOB_NAME, DEFAULT_CRON, new DMS_Replenishment_Scheduler());
    }
}