/**
 * @description Notification routing for Expense lifecycle. Expense uses a
 *              two-stage approval (Manager Approved, then Finance Approved);
 *              both map to the canonical Approved event.
 */
trigger Expense_Notification_Trigger on Expense__c (after insert, after update) {
    Set<String> SUBMITTED = new Set<String>{ 'Submitted' };
    Set<String> APPROVED  = new Set<String>{ 'Manager Approved', 'Finance Approved', 'Paid' };
    Set<String> REJECTED  = new Set<String>{ 'Rejected' };

    if (Trigger.isInsert) {
        NotificationTriggerHelper.fromInsert(
            'Expense__c', Trigger.new, 'Status__c', SUBMITTED
        );
    } else {
        NotificationTriggerHelper.fromUpdate(
            'Expense__c', Trigger.new, Trigger.oldMap,
            'Status__c', SUBMITTED, APPROVED, REJECTED
        );
    }
}