/**
 * @description Turns raw trigger activity into the canonical notification
 *              events (Created / Updated / Submitted / Approved / Rejected)
 *              that Notification_Setting__c rows subscribe to.
 *
 * This used to require every trigger to hand-code its own status field name
 * and status-value sets, which meant onboarding an object was a code change —
 * and in practice nothing ever called it, so no notification ever fired from a
 * trigger. It is now fully configuration-driven and invoked centrally from
 * TriggerHandler.run(), so every object using the framework participates
 * automatically.
 *
 * Where the status mapping comes from, in order of preference:
 *   1. The approval matrix for that object — Approval_Rule__c already declares
 *      Status_Field_API_Name__c plus the values meaning submitted / approved /
 *      rejected, so approvals and notifications stay in step by construction.
 *   2. A conventional fallback of Status__c with the usual value names, so an
 *      object with notifications but no approval rules still raises events.
 *
 * Everything is lazily loaded and cached per transaction, and the whole path
 * short-circuits when no active Notification_Setting__c targets the object —
 * so a trigger on an object nobody has configured costs one cached query.
 */
public with sharing class NotificationTriggerHelper {

    private static final Set<String> DEFAULT_SUBMITTED =
        new Set<String>{ 'Submitted', 'Pending Approval', 'In Approval' };
    private static final Set<String> DEFAULT_APPROVED =
        new Set<String>{ 'Approved' };
    private static final Set<String> DEFAULT_REJECTED =
        new Set<String>{ 'Rejected', 'Declined' };

    /** Objects that have at least one active notification setting. */
    private static Set<String> configuredObjects;

    /** Resolved status mapping per object. */
    private static Map<String, StatusMap> statusMapByObject;

    /** Guards against double-firing when an object has more than one handler. */
    private static Map<String, Set<Id>> dispatchedByKey = new Map<String, Set<Id>>();

    public class StatusMap {
        public String field;
        public Set<String> submitted = new Set<String>();
        public Set<String> approved  = new Set<String>();
        public Set<String> rejected  = new Set<String>();
    }

    // ── Central entry points (called from TriggerHandler.run) ──────────

    /**
     * @description Fires Created for every new record, plus Submitted for any
     *              record that lands directly in a submitted state on insert.
     */
    public static void handleInsert(String objectApiName, List<SObject> newRecords) {
        if (!isConfigured(objectApiName) || newRecords == null || newRecords.isEmpty()) return;

        List<SObject> fresh = takeUndispatched(objectApiName + '|INSERT', newRecords);
        if (fresh.isEmpty()) return;

        NotificationDispatcher.dispatch(objectApiName, 'Created', fresh);

        StatusMap sm = statusMapFor(objectApiName);
        if (sm == null || String.isBlank(sm.field) || sm.submitted.isEmpty()) return;

        List<SObject> submitted = new List<SObject>();
        for (SObject rec : fresh) {
            Object v = safeGet(rec, sm.field);
            if (v != null && sm.submitted.contains(String.valueOf(v))) submitted.add(rec);
        }
        if (!submitted.isEmpty()) {
            NotificationDispatcher.dispatch(objectApiName, 'Submitted', submitted);
        }
    }

    /**
     * @description Detects status transitions and fires the matching canonical
     *              event for each batch. Records whose status did not change
     *              raise the generic Updated event.
     */
    public static void handleUpdate(String objectApiName, List<SObject> newRecords,
                                    Map<Id, SObject> oldMap) {
        if (!isConfigured(objectApiName) || newRecords == null || newRecords.isEmpty()) return;

        List<SObject> fresh = takeUndispatched(objectApiName + '|UPDATE', newRecords);
        if (fresh.isEmpty()) return;

        StatusMap sm = statusMapFor(objectApiName);
        String statusField = (sm == null) ? null : sm.field;

        List<SObject> updated   = new List<SObject>();
        List<SObject> submitted = new List<SObject>();
        List<SObject> approved  = new List<SObject>();
        List<SObject> rejected  = new List<SObject>();

        for (SObject rec : fresh) {
            if (String.isBlank(statusField)) { updated.add(rec); continue; }

            SObject old = (oldMap == null) ? null : oldMap.get((Id) rec.get('Id'));
            Object newStatus = safeGet(rec, statusField);
            Object oldStatus = (old == null) ? null : safeGet(old, statusField);

            if (newStatus == oldStatus) { updated.add(rec); continue; }

            String s = (newStatus == null) ? null : String.valueOf(newStatus);
            if (s == null)                        { updated.add(rec); }
            else if (sm.submitted.contains(s))    { submitted.add(rec); }
            else if (sm.approved.contains(s))     { approved.add(rec); }
            else if (sm.rejected.contains(s))     { rejected.add(rec); }
            else                                  { updated.add(rec); }
        }

        if (!updated.isEmpty())   NotificationDispatcher.dispatch(objectApiName, 'Updated',   updated);
        if (!submitted.isEmpty()) NotificationDispatcher.dispatch(objectApiName, 'Submitted', submitted);
        if (!approved.isEmpty())  NotificationDispatcher.dispatch(objectApiName, 'Approved',  approved);
        if (!rejected.isEmpty())  NotificationDispatcher.dispatch(objectApiName, 'Rejected',  rejected);
    }

    // ── Explicit-control entry points (retained) ──────────────────────

    /**
     * @description Explicit variant for callers that want to state the status
     *              field and value sets rather than rely on configuration.
     */
    public static void fromInsert(String objectApiName, List<SObject> newRecords,
                                  String statusField, Set<String> submittedStatuses) {
        if (newRecords == null || newRecords.isEmpty()) return;

        NotificationDispatcher.dispatch(objectApiName, 'Created', newRecords);

        if (String.isBlank(statusField) || submittedStatuses == null || submittedStatuses.isEmpty()) return;
        List<SObject> submitted = new List<SObject>();
        for (SObject rec : newRecords) {
            Object v = safeGet(rec, statusField);
            if (v != null && submittedStatuses.contains(String.valueOf(v))) submitted.add(rec);
        }
        if (!submitted.isEmpty()) {
            NotificationDispatcher.dispatch(objectApiName, 'Submitted', submitted);
        }
    }

    /**
     * @description Explicit variant of handleUpdate.
     */
    public static void fromUpdate(String objectApiName, List<SObject> newRecords,
                                  Map<Id, SObject> oldMap, String statusField,
                                  Set<String> submittedStatuses,
                                  Set<String> approvedStatuses,
                                  Set<String> rejectedStatuses) {
        if (newRecords == null || newRecords.isEmpty()) return;

        List<SObject> updated   = new List<SObject>();
        List<SObject> submitted = new List<SObject>();
        List<SObject> approved  = new List<SObject>();
        List<SObject> rejected  = new List<SObject>();

        for (SObject rec : newRecords) {
            SObject old = (oldMap == null) ? null : oldMap.get((Id) rec.get('Id'));
            Object newStatus = safeGet(rec, statusField);
            Object oldStatus = (old == null) ? null : safeGet(old, statusField);

            if (newStatus == oldStatus) { updated.add(rec); continue; }

            String s = (newStatus == null) ? null : String.valueOf(newStatus);
            if (s == null) { updated.add(rec); continue; }

            if (submittedStatuses != null && submittedStatuses.contains(s)) submitted.add(rec);
            else if (approvedStatuses != null && approvedStatuses.contains(s)) approved.add(rec);
            else if (rejectedStatuses != null && rejectedStatuses.contains(s)) rejected.add(rec);
            else updated.add(rec);
        }

        if (!updated.isEmpty())   NotificationDispatcher.dispatch(objectApiName, 'Updated',   updated);
        if (!submitted.isEmpty()) NotificationDispatcher.dispatch(objectApiName, 'Submitted', submitted);
        if (!approved.isEmpty())  NotificationDispatcher.dispatch(objectApiName, 'Approved',  approved);
        if (!rejected.isEmpty())  NotificationDispatcher.dispatch(objectApiName, 'Rejected',  rejected);
    }

    // ── Configuration lookup ──────────────────────────────────────────

    /**
     * @description True when at least one active notification setting targets
     *              this object. One aggregate query per transaction keeps the
     *              cost of the central trigger hook negligible for the many
     *              objects nobody has configured.
     */
    @TestVisible
    private static Boolean isConfigured(String objectApiName) {
        if (String.isBlank(objectApiName)) return false;
        if (configuredObjects == null) {
            configuredObjects = new Set<String>();
            try {
                for (AggregateResult ar : [
                    SELECT Event_Object__c obj
                    FROM Notification_Setting__c
                    WHERE Is_Active__c = true
                    GROUP BY Event_Object__c
                ]) {
                    Object v = ar.get('obj');
                    if (v != null) configuredObjects.add(String.valueOf(v));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'NotificationTriggerHelper: settings lookup failed - ' + e.getMessage());
            }
        }
        return configuredObjects.contains(objectApiName);
    }

    /**
     * @description Resolves the status field and the values that mean
     *              submitted / approved / rejected for an object, preferring
     *              the approval matrix so both engines agree on what a status
     *              transition means.
     */
    @TestVisible
    private static StatusMap statusMapFor(String objectApiName) {
        if (statusMapByObject == null) {
            statusMapByObject = new Map<String, StatusMap>();
            try {
                for (Approval_Rule__c r : [
                    SELECT Object_Process__c, Status_Field_API_Name__c,
                           Status_Value_On_Submit__c, Status_Value_On_Approve__c,
                           Status_Value_On_Reject__c
                    FROM Approval_Rule__c
                    WHERE Is_Active__c = true AND Status_Field_API_Name__c != null
                ]) {
                    if (String.isBlank(r.Object_Process__c)) continue;
                    StatusMap sm = statusMapByObject.get(r.Object_Process__c);
                    if (sm == null) {
                        sm = new StatusMap();
                        sm.field = r.Status_Field_API_Name__c;
                        statusMapByObject.put(r.Object_Process__c, sm);
                    }
                    if (String.isNotBlank(r.Status_Value_On_Submit__c))  sm.submitted.add(r.Status_Value_On_Submit__c);
                    if (String.isNotBlank(r.Status_Value_On_Approve__c)) sm.approved.add(r.Status_Value_On_Approve__c);
                    if (String.isNotBlank(r.Status_Value_On_Reject__c))  sm.rejected.add(r.Status_Value_On_Reject__c);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'NotificationTriggerHelper: approval rule lookup failed - ' + e.getMessage());
            }
        }

        StatusMap found = statusMapByObject.get(objectApiName);
        if (found != null) return found;

        // No approval rules for this object — fall back to the conventional
        // Status__c field if the object actually has one.
        StatusMap fallback = new StatusMap();
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
        if (t != null && t.getDescribe().fields.getMap().containsKey('status__c')) {
            fallback.field = 'Status__c';
            fallback.submitted.addAll(DEFAULT_SUBMITTED);
            fallback.approved.addAll(DEFAULT_APPROVED);
            fallback.rejected.addAll(DEFAULT_REJECTED);
        }
        statusMapByObject.put(objectApiName, fallback);
        return fallback;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    /**
     * @description Returns only the records not already dispatched for this
     *              object + context in this transaction. Several objects have
     *              two trigger handlers (DMS and OMS variants of Return Order,
     *              for one) and without this every notification on those
     *              objects would go out twice.
     */
    private static List<SObject> takeUndispatched(String key, List<SObject> records) {
        Set<Id> seen = dispatchedByKey.get(key);
        if (seen == null) {
            seen = new Set<Id>();
            dispatchedByKey.put(key, seen);
        }
        List<SObject> fresh = new List<SObject>();
        for (SObject r : records) {
            Id rid = (Id) safeGet(r, 'Id');
            if (rid == null || seen.contains(rid)) continue;
            seen.add(rid);
            fresh.add(r);
        }
        return fresh;
    }

    private static Object safeGet(SObject rec, String field) {
        if (rec == null || String.isBlank(field)) return null;
        try { return rec.get(field); } catch (Exception e) { return null; }
    }

    /** Clears the per-transaction caches. Test support. */
    @TestVisible
    private static void resetCache() {
        configuredObjects = null;
        statusMapByObject = null;
        dispatchedByKey = new Map<String, Set<Id>>();
    }
}