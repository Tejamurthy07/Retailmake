/**
 * @description Single trigger for Expense__c. Delegates all logic to
 *              EXP_Expense_TriggerHandler via the TriggerHandler framework.
 */
trigger Expense_Trigger on Expense__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new EXP_Expense_TriggerHandler().run();
}