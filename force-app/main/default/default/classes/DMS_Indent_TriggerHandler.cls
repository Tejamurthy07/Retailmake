/**
 * @description Trigger handler for Indent__c. On approval, hands the indent to
 *              the DMS primary-fulfillment service (invoice + warehouse deduction
 *              + dispatch). Inert unless the DMS toggles are enabled.
 * @author  SFA Development Team
 * @date    2024
 */
public class DMS_Indent_TriggerHandler extends TriggerHandler {

    protected override void beforeUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_CREDIT_ENFORCEMENT)) {
            return;
        }
        List<Indent__c> newRecords = (List<Indent__c>) Trigger.new;
        Map<Id, Indent__c> oldMap = (Map<Id, Indent__c>) Trigger.oldMap;

        List<Indent__c> approving = new List<Indent__c>();
        Set<Id> accountIds = new Set<Id>();
        for (Indent__c ind : newRecords) {
            Indent__c oldInd = oldMap.get(ind.Id);
            if (ind.Status__c == DMS_Constants.INDENT_APPROVED &&
                oldInd.Status__c != DMS_Constants.INDENT_APPROVED &&
                ind.Account__c != null) {
                approving.add(ind);
                accountIds.add(ind.Account__c);
            }
        }
        if (approving.isEmpty()) {
            return;
        }

        // Distributor credit position.
        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Credit_Limit__c, Outstanding_Balance__c FROM Account WHERE Id IN :accountIds
        ]);

        // Indent value from its lines (Approved else Requested qty * price).
        Map<Id, Decimal> valueByIndent = new Map<Id, Decimal>();
        for (Indent_Line__c line : [
            SELECT Indent__c, Approved_Qty__c, Requested_Qty__c, Unit_Price__c
            FROM Indent_Line__c WHERE Indent__c IN :approving
        ]) {
            Decimal qty = line.Approved_Qty__c != null && line.Approved_Qty__c > 0
                ? line.Approved_Qty__c
                : (line.Requested_Qty__c != null ? line.Requested_Qty__c : 0);
            Decimal price = line.Unit_Price__c != null ? line.Unit_Price__c : 0;
            valueByIndent.put(line.Indent__c,
                (valueByIndent.containsKey(line.Indent__c) ? valueByIndent.get(line.Indent__c) : 0) + qty * price);
        }

        for (Indent__c ind : approving) {
            Account acct = accounts.get(ind.Account__c);
            Decimal creditLimit = (acct != null && acct.Credit_Limit__c != null) ? acct.Credit_Limit__c : 0;
            if (creditLimit <= 0) {
                continue; // No ceiling configured.
            }
            Decimal outstanding = (acct != null && acct.Outstanding_Balance__c != null) ? acct.Outstanding_Balance__c : 0;
            Decimal indentValue = valueByIndent.containsKey(ind.Id) ? valueByIndent.get(ind.Id) : 0;
            if (outstanding + indentValue > creditLimit) {
                ind.addError('Cannot approve: distributor credit limit exceeded. Limit ' + creditLimit +
                    ', Outstanding ' + outstanding + ', This indent ' + indentValue + '.');
            }
        }
    }

    protected override void afterUpdate() {
        List<Indent__c> newRecords = (List<Indent__c>) Trigger.new;
        Map<Id, Indent__c> oldMap = (Map<Id, Indent__c>) Trigger.oldMap;

        Set<Id> newlyApproved = new Set<Id>();
        for (Indent__c ind : newRecords) {
            Indent__c oldInd = oldMap.get(ind.Id);
            if (ind.Status__c == DMS_Constants.INDENT_APPROVED &&
                oldInd.Status__c != DMS_Constants.INDENT_APPROVED) {
                newlyApproved.add(ind.Id);
            }
        }

        if (!newlyApproved.isEmpty()) {
            DMS_IndentFulfillment_Service.fulfillApprovedIndents(newlyApproved);
        }
    }
}