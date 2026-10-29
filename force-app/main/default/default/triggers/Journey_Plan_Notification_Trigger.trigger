/**
 * @description Notification routing for Journey Plan lifecycle.
 */
trigger Journey_Plan_Notification_Trigger on Journey_Plan__c (after insert, after update) {
    Set<String> SUBMITTED = new Set<String>{ 'Submitted' };
    Set<String> APPROVED  = new Set<String>{ 'Approved', 'Active' };
    Set<String> REJECTED  = new Set<String>{ 'Rejected', 'Cancelled' };

    if (Trigger.isInsert) {
        NotificationTriggerHelper.fromInsert(
            'Journey_Plan__c', Trigger.new, 'Status__c', SUBMITTED
        );
    } else {
        NotificationTriggerHelper.fromUpdate(
            'Journey_Plan__c', Trigger.new, Trigger.oldMap,
            'Status__c', SUBMITTED, APPROVED, REJECTED
        );
    }
}