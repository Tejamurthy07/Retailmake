/**
 * @description Notification routing for Return Order lifecycle.
 */
trigger Return_Order_Notification_Trigger on Return_Order__c (after insert, after update) {
    Set<String> SUBMITTED = new Set<String>{ 'Submitted' };
    Set<String> APPROVED  = new Set<String>{ 'Approved', 'Credit Note Issued' };
    Set<String> REJECTED  = new Set<String>{ 'Rejected' };

    if (Trigger.isInsert) {
        NotificationTriggerHelper.fromInsert(
            'Return_Order__c', Trigger.new, 'Status__c', SUBMITTED
        );
    } else {
        NotificationTriggerHelper.fromUpdate(
            'Return_Order__c', Trigger.new, Trigger.oldMap,
            'Status__c', SUBMITTED, APPROVED, REJECTED
        );
    }
}