/**
 * @description DEPRECATED — retained only as a compatibility shim.
 *
 * This class used to be a second notification engine alongside
 * NotificationDispatcher. The two diverged in ways that mattered: this one
 * looked up a CustomNotificationType named 'FSCRM_Notification' (which does
 * not exist, so every in-app send silently no-opped), resolved a narrower set
 * of recipient types, wrote no Notification_Log__c audit rows, and could not
 * follow relationship merge paths.
 *
 * NotificationDispatcher is now the single engine. Every method here forwards
 * to it so that any Flow or org-side customisation still bound to
 * NotificationDispatchService keeps working unchanged.
 *
 * New code should call NotificationDispatcher directly.
 */
public with sharing class NotificationDispatchService {

    // ---------- Event-driven entry points ----------

    /** Apex: NotificationDispatchService.dispatch(recordId, 'Approved'); */
    public static void dispatch(Id recordId, String eventType) {
        NotificationDispatcher.dispatch(recordId, eventType);
    }

    /** Bulk-safe Apex entry point. */
    public static void dispatch(Map<Id, String> recordIdToEvent) {
        NotificationDispatcher.dispatch(recordIdToEvent);
    }

    /** Flow / Record-Triggered Flow entry point. */
    @InvocableMethod(label='Send Dynamic Notification'
        description='Sends notifications defined in Notification Setting records for a record + event.')
    public static void dispatchFromFlow(List<Request> requests) {
        if (requests == null) return;
        Map<Id, String> m = new Map<Id, String>();
        for (Request r : requests) {
            if (r.recordId != null && String.isNotBlank(r.eventType)) {
                m.put(r.recordId, r.eventType);
            }
        }
        NotificationDispatcher.dispatch(m);
    }

    public class Request {
        @InvocableVariable(required=true label='Record Id') public Id recordId;
        @InvocableVariable(required=true label='Event Type') public String eventType;
    }

    // ---------- Direct send ----------

    /**
     * @description Sends a one-off In-App + Email notification to specific users.
     */
    public static void notify(Set<Id> userIds, Id targetId, String subject, String body) {
        NotificationDispatcher.notifyUsers(userIds, targetId, subject, body);
    }
}