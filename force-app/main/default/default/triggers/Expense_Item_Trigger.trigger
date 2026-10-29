/**
 * @description Single trigger for Expense_Item__c. Delegates all logic to
 *              EXP_ExpenseItem_TriggerHandler via the TriggerHandler framework.
 */
trigger Expense_Item_Trigger on Expense_Item__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new EXP_ExpenseItem_TriggerHandler().run();
}