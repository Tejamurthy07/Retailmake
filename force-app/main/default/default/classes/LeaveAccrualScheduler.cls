/**
 * @description Scheduler for monthly leave accrual and yearly reset.
 *
 *              Monthly accrual: System.schedule('Leave Monthly Accrual', '0 0 1 1 * ?', new LeaveAccrualScheduler());
 *              Yearly reset: System.schedule('Leave Yearly Reset', '0 0 0 1 4 ?', new LeaveAccrualScheduler());
 *
 *              On April 1st, it auto-initializes balances for the new fiscal year.
 *              On the 1st of every other month, it runs monthly accrual.
 */
public class LeaveAccrualScheduler implements Schedulable {

    public void execute(SchedulableContext sc) {
        String currentYear = LeaveBalanceService.getCurrentFiscalYear();
        Integer currentMonth = Date.today().month();

        // April 1st = fiscal year start → initialize new year balances
        if (currentMonth == 4) {
            Database.executeBatch(new LeaveYearlyResetBatch(currentYear), 200);
        }

        // Run monthly accrual every month
        Database.executeBatch(new LeaveAccrualBatch(currentYear), 200);
    }
}