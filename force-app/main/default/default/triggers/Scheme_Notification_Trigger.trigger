/**
 * @description Notification routing for Scheme lifecycle. "Pending Approval"
 *              is the equivalent of Submitted for this object.
 */
trigger Scheme_Notification_Trigger on Scheme__c (after insert, after update) {
    Set<String> SUBMITTED = new Set<String>{ 'Pending Approval' };
    Set<String> APPROVED  = new Set<String>{ 'Active' };
    Set<String> REJECTED  = new Set<String>{ 'Cancelled', 'Expired' };

    if (Trigger.isInsert) {
        NotificationTriggerHelper.fromInsert(
            'Scheme__c', Trigger.new, 'Status__c', SUBMITTED
        );
    } else {
        NotificationTriggerHelper.fromUpdate(
            'Scheme__c', Trigger.new, Trigger.oldMap,
            'Status__c', SUBMITTED, APPROVED, REJECTED
        );
    }
}