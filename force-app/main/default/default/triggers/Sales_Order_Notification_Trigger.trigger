/**
 * @description Notification routing for Sales Order lifecycle. Sits alongside
 *              the existing Sales_Order_Trigger which handles business logic;
 *              this one only dispatches to the dynamic NotificationDispatcher.
 */
trigger Sales_Order_Notification_Trigger on Sales_Order__c (after insert, after update) {
    Set<String> SUBMITTED = new Set<String>{ 'Submitted' };
    Set<String> APPROVED  = new Set<String>{ 'Approved' };
    Set<String> REJECTED  = new Set<String>{ 'Rejected', 'Cancelled' };

    if (Trigger.isInsert) {
        NotificationTriggerHelper.fromInsert(
            'Sales_Order__c', Trigger.new, 'Status__c', SUBMITTED
        );
    } else {
        NotificationTriggerHelper.fromUpdate(
            'Sales_Order__c', Trigger.new, Trigger.oldMap,
            'Status__c', SUBMITTED, APPROVED, REJECTED
        );
    }
}