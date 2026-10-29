/**
 * @description Trigger handler for Expense_Item__c. Extends the TriggerHandler
 *              framework. Auto-populates GPS distance and calculates eligible
 *              amounts from Expense_Eligibility__c rules.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public class EXP_ExpenseItem_TriggerHandler extends TriggerHandler {

    override protected void beforeInsert() {
        if (!BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_EXPENSE)) {
            return;
        }

        List<Expense_Item__c> newItems = (List<Expense_Item__c>) Trigger.new;

        Map<Id, List<Expense_Item__c>> itemsByExpense = new Map<Id, List<Expense_Item__c>>();
        for (Expense_Item__c item : newItems) {
            if (!itemsByExpense.containsKey(item.Expense__c)) {
                itemsByExpense.put(item.Expense__c, new List<Expense_Item__c>());
            }
            itemsByExpense.get(item.Expense__c).add(item);
        }

        for (Id expenseId : itemsByExpense.keySet()) {
            if (BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_AUTO_CALC)) {
                EXP_Expense_Service.populateEligibilityFields(itemsByExpense.get(expenseId), expenseId);
            }
        }
    }

    override protected void beforeUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_EXPENSE)) {
            return;
        }

        List<Expense_Item__c> newItems = (List<Expense_Item__c>) Trigger.new;
        Map<Id, Expense_Item__c> oldMap = (Map<Id, Expense_Item__c>) Trigger.oldMap;

        Map<Id, List<Expense_Item__c>> changedByExpense = new Map<Id, List<Expense_Item__c>>();
        for (Expense_Item__c item : newItems) {
            Expense_Item__c oldItem = oldMap.get(item.Id);
            Boolean distanceChanged = item.Manual_Distance_KM__c != oldItem.Manual_Distance_KM__c ||
                                      item.GPS_Distance_KM__c != oldItem.GPS_Distance_KM__c;
            Boolean typeChanged = item.Expense_Type__c != oldItem.Expense_Type__c;
            Boolean amountChanged = item.Claimed_Amount__c != oldItem.Claimed_Amount__c;

            if (distanceChanged || typeChanged || amountChanged) {
                if (!changedByExpense.containsKey(item.Expense__c)) {
                    changedByExpense.put(item.Expense__c, new List<Expense_Item__c>());
                }
                changedByExpense.get(item.Expense__c).add(item);
            }
        }

        if (BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_AUTO_CALC)) {
            for (Id expenseId : changedByExpense.keySet()) {
                EXP_Expense_Service.populateEligibilityFields(changedByExpense.get(expenseId), expenseId);
            }
        }
    }
}