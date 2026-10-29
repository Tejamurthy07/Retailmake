/**
 * @description Primary_Order__c automation:
 *   - before update: enforce the distributor's credit limit on approval.
 *   - after update:  on approval, dispatch via DMS_PrimaryOrderFulfillment_Service
 *                    (creates the primary invoice, deducts warehouse stock).
 */
trigger Primary_Order_Trigger on Primary_Order__c (before update, after update) {

    if (Trigger.isBefore) {
        // Credit enforcement is gated by the DMS master + credit-enforcement toggles
        // (consistent with DMS_Indent_TriggerHandler); off => no credit block.
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_CREDIT_ENFORCEMENT)) {
            return;
        }
        // Credit enforcement: block approval if outstanding + order value > limit.
        Set<Id> accountIds = new Set<Id>();
        List<Primary_Order__c> approving = new List<Primary_Order__c>();
        for (Primary_Order__c o : Trigger.new) {
            Primary_Order__c old = Trigger.oldMap.get(o.Id);
            if (o.Status__c == DMS_Constants.INDENT_APPROVED &&
                old.Status__c != DMS_Constants.INDENT_APPROVED && o.Account__c != null) {
                approving.add(o);
                accountIds.add(o.Account__c);
            }
        }
        if (!approving.isEmpty()) {
            Map<Id, Account> accts = new Map<Id, Account>([
                SELECT Id, Credit_Limit__c, Outstanding_Balance__c FROM Account WHERE Id IN :accountIds
            ]);
            // Order value: compute from the LINES, and fall back to the header only
            // when an order has none. This used to prefer the header total, which
            // made a credit control depend on a denormalised field nothing kept in
            // sync — a cloned order carried its template's 56k while its real lines
            // came to ~11.4 lakh, and the check passed it. The lines are the order.
            Map<Id, Decimal> valueByOrder = new Map<Id, Decimal>();
            Set<Id> needLines = new Set<Id>();
            for (Primary_Order__c o : approving) { needLines.add(o.Id); }
            if (!needLines.isEmpty()) {
                for (Primary_Order_Line__c l : [
                    SELECT Primary_Order__c, Quantity__c, Base_Quantity__c, Unit_Price__c
                    FROM Primary_Order_Line__c WHERE Primary_Order__c IN :needLines
                ]) {
                    Decimal qty = (l.Base_Quantity__c != null && l.Base_Quantity__c > 0)
                        ? l.Base_Quantity__c
                        : (l.Quantity__c != null ? l.Quantity__c : 0);
                    Decimal price = l.Unit_Price__c != null ? l.Unit_Price__c : 0;
                    valueByOrder.put(l.Primary_Order__c,
                        (valueByOrder.containsKey(l.Primary_Order__c) ? valueByOrder.get(l.Primary_Order__c) : 0) + qty * price);
                }
            }
            // Only an order with no lines at all falls back to its header total.
            for (Primary_Order__c o : approving) {
                if (!valueByOrder.containsKey(o.Id)
                    && o.Total_Amount__c != null && o.Total_Amount__c > 0) {
                    valueByOrder.put(o.Id, o.Total_Amount__c);
                }
            }
            for (Primary_Order__c o : approving) {
                Account acct = accts.get(o.Account__c);
                Decimal limitAmt = (acct != null && acct.Credit_Limit__c != null) ? acct.Credit_Limit__c : 0;
                if (limitAmt <= 0) { continue; } // no ceiling configured
                Decimal outstanding = (acct != null && acct.Outstanding_Balance__c != null) ? acct.Outstanding_Balance__c : 0;
                Decimal orderValue = valueByOrder.containsKey(o.Id) ? valueByOrder.get(o.Id) : 0;
                if (outstanding + orderValue > limitAmt) {
                    o.addError('Cannot approve: distributor credit limit exceeded. Limit ' + limitAmt +
                        ', Outstanding ' + outstanding + ', This order ' + orderValue + '.');
                }
            }
        }
        return;
    }

    // after update: dispatch newly-approved orders.
    Set<Id> newlyApproved = new Set<Id>();
    for (Primary_Order__c o : Trigger.new) {
        Primary_Order__c old = Trigger.oldMap.get(o.Id);
        if (o.Status__c == DMS_Constants.INDENT_APPROVED &&
            old.Status__c != DMS_Constants.INDENT_APPROVED) {
            newlyApproved.add(o.Id);
        }
    }
    if (!newlyApproved.isEmpty()) {
        DMS_PrimaryOrderFulfillment_Service.fulfillApproved(newlyApproved);
    }
}