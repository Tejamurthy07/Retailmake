/**
 * @description Notification routing for Claim lifecycle. Partial approvals
 *              are treated as Approved for notification purposes.
 */
trigger Claim_Notification_Trigger on Claim__c (after insert, after update) {
    Set<String> SUBMITTED = new Set<String>{ 'Submitted', 'Under Review' };
    Set<String> APPROVED  = new Set<String>{ 'Approved', 'Partially Approved', 'Settled' };
    Set<String> REJECTED  = new Set<String>{ 'Rejected' };

    if (Trigger.isInsert) {
        NotificationTriggerHelper.fromInsert(
            'Claim__c', Trigger.new, 'Status__c', SUBMITTED
        );
    } else {
        NotificationTriggerHelper.fromUpdate(
            'Claim__c', Trigger.new, Trigger.oldMap,
            'Status__c', SUBMITTED, APPROVED, REJECTED
        );
    }
}