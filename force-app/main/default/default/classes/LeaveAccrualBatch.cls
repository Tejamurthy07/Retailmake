/**
 * @description Monthly batch to accrue leave for employees with monthly-accrual
 *              leave types (e.g., Earned Leave = 1.25 days/month).
 *              Increments Accrued__c on Leave_Balance__c, capped at Entitled__c.
 *
 *              Usage: Database.executeBatch(new LeaveAccrualBatch(), 200);
 *              Schedule: Run on 1st of every month.
 *              System.schedule('Leave Monthly Accrual', '0 0 1 1 * ?', new LeaveAccrualScheduler());
 */
public class LeaveAccrualBatch implements Database.Batchable<SObject>, Database.Stateful {

    private String year;
    private Integer totalAccrued = 0;

    public LeaveAccrualBatch() {
        this.year = LeaveBalanceService.getCurrentFiscalYear();
    }

    public LeaveAccrualBatch(String year) {
        this.year = year;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Accrued__c, Entitled__c,
                   Leave_Policy__r.Monthly_Accrual__c
            FROM Leave_Balance__c
            WHERE Year__c = :year
            AND Leave_Policy__r.Monthly_Accrual__c > 0
            AND Leave_Policy__r.Is_Active__c = true
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Leave_Balance__c> scope) {
        List<Leave_Balance__c> toUpdate = new List<Leave_Balance__c>();

        for (Leave_Balance__c lb : scope) {
            Decimal accrualRate = lb.Leave_Policy__r.Monthly_Accrual__c;
            Decimal currentAccrued = lb.Accrued__c != null ? lb.Accrued__c : 0;
            Decimal maxEntitled = lb.Entitled__c != null ? lb.Entitled__c : 0;

            Decimal newAccrued = Math.min(currentAccrued + accrualRate, maxEntitled);

            if (newAccrued != currentAccrued) {
                lb.Accrued__c = newAccrued;
                toUpdate.add(lb);
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
            totalAccrued += toUpdate.size();
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('LeaveAccrualBatch completed. Accrued for ' + totalAccrued + ' balances in year ' + year);
    }
}