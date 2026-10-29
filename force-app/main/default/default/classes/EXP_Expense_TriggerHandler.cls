/**
 * @description Trigger handler for Expense__c. Extends the TriggerHandler
 *              framework. Validates status transitions on the expense record.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public class EXP_Expense_TriggerHandler extends TriggerHandler {

    override protected void beforeUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_EXPENSE)) {
            return;
        }

        List<Expense__c> newExpenses = (List<Expense__c>) Trigger.new;
        Map<Id, Expense__c> oldMap = (Map<Id, Expense__c>) Trigger.oldMap;

        for (Expense__c expense : newExpenses) {
            Expense__c oldExpense = oldMap.get(expense.Id);

            if (expense.Status__c != oldExpense.Status__c) {
                if (!EXP_Expense_Service.isValidTransition(oldExpense.Status__c, expense.Status__c)) {
                    expense.addError(
                        'Invalid status transition from ' + oldExpense.Status__c +
                        ' to ' + expense.Status__c + '.'
                    );
                }
            }
        }
    }
}