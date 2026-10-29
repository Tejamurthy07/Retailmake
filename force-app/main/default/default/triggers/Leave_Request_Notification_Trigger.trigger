/**
 * @description Routes Leave Request lifecycle events to the dynamic
 *              NotificationDispatcher. Status transitions map to event
 *              types declared in Notification_Setting__c.Event_Type__c.
 *
 *              Named *_Notification_Trigger to avoid clashing with any
 *              existing approval/business-logic trigger on the same object.
 */
trigger Leave_Request_Notification_Trigger on Leave_Request__c (after insert, after update) {
    if (Trigger.isInsert) {
        List<Leave_Request__c> created = new List<Leave_Request__c>();
        List<Leave_Request__c> submitted = new List<Leave_Request__c>();
        for (Leave_Request__c lr : Trigger.new) {
            created.add(lr);
            if (lr.Status__c == 'Submitted') submitted.add(lr);
        }
        NotificationDispatcher.dispatch('Leave_Request__c', 'Created', created);
        if (!submitted.isEmpty()) {
            NotificationDispatcher.dispatch('Leave_Request__c', 'Submitted', submitted);
        }
        return;
    }

    // after update — detect status transitions
    List<Leave_Request__c> submitted = new List<Leave_Request__c>();
    List<Leave_Request__c> approved = new List<Leave_Request__c>();
    List<Leave_Request__c> rejected = new List<Leave_Request__c>();
    List<Leave_Request__c> recalled = new List<Leave_Request__c>();
    List<Leave_Request__c> updated = new List<Leave_Request__c>();

    for (Leave_Request__c lr : Trigger.new) {
        Leave_Request__c old = Trigger.oldMap.get(lr.Id);
        if (lr.Status__c == old.Status__c) {
            updated.add(lr);
            continue;
        }
        if (lr.Status__c == 'Submitted') submitted.add(lr);
        else if (lr.Status__c == 'Approved') approved.add(lr);
        else if (lr.Status__c == 'Rejected') rejected.add(lr);
        else if (lr.Status__c == 'Pending' && old.Status__c == 'Submitted') recalled.add(lr);
    }

    if (!updated.isEmpty())  NotificationDispatcher.dispatch('Leave_Request__c', 'Updated',   updated);
    if (!submitted.isEmpty()) NotificationDispatcher.dispatch('Leave_Request__c', 'Submitted', submitted);
    if (!approved.isEmpty())  NotificationDispatcher.dispatch('Leave_Request__c', 'Approved',  approved);
    if (!rejected.isEmpty())  NotificationDispatcher.dispatch('Leave_Request__c', 'Rejected',  rejected);
    if (!recalled.isEmpty())  NotificationDispatcher.dispatch('Leave_Request__c', 'Recalled',  recalled);
}