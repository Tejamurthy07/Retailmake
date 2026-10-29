/**
 * @description The single runtime approval engine for the product.
 *
 * Reads Approval_Rule__c rows, creates Approval_Request__c + Approval_Step__c
 * records on submit, resolves approvers (Manager/Role/Queue/User), runs auto-
 * approve cascades, advances or rejects, and writes status back to the source
 * record dynamically via the per-rule Status_Field_API_Name__c mapping.
 *
 * One generic class drives EVERY object. Object_Process__c is plain text, so
 * onboarding a new object is a configuration row — never a deploy.
 *
 * Capabilities driven purely by configuration:
 *   - multi-level chains (Approval_Level__c)
 *   - Sequential / Parallel-Any / Parallel-All levels (Approval_Mode__c)
 *   - multi-condition entry criteria with AND/OR logic (Criteria_Logic__c)
 *   - numeric value bands (Min_Value__c / Max_Value__c)
 *   - auto-approve levels (Auto_Approve__c)
 *   - time-based escalation (Escalation_Hours__c / Escalation_Approver__c)
 *   - rule versioning (Effective_From__c / Effective_To__c)
 *
 * Notifications are raised twice on purpose: a guaranteed in-app bell so the
 * engine works out of the box with zero notification config, plus a
 * configurable event dispatched against the Approval_Request__c record so
 * admins can add Email/SMS/WhatsApp from the Notification Settings window
 * (recipient "Field on Record" -> Current_Approver__c or Submitted_By__c).
 */
public with sharing class ApprovalRouter {

    private static final String NOTIF_TYPE_DEV_NAME = 'FMCG_Notification';
    private static final String APPROVAL_OBJECT     = 'Approval_Request__c';

    private static final String MODE_SEQUENTIAL   = 'Sequential';
    private static final String MODE_PARALLEL_ANY = 'Parallel Any';

    public class ApprovalException extends Exception {}

    // ── Flow entry point ──────────────────────────────────────────────

    public class SubmitRequest {
        @InvocableVariable(required=true label='Record Id') public Id recordId;
        @InvocableVariable(label='Comments') public String comments;
    }

    @InvocableMethod(label='Submit For Approval'
        description='Routes a record through the dynamic approval matrix.')
    public static void submitForApprovalFlow(List<SubmitRequest> requests) {
        if (requests == null) return;
        for (SubmitRequest r : requests) {
            if (r.recordId == null) continue;
            try {
                submitInternal(r.recordId, r.comments);
            } catch (Exception e) {
                // A Flow-driven submit must not roll back the caller's whole
                // transaction because one record had no matching rule.
                System.debug(LoggingLevel.WARN,
                    'Flow submit skipped for ' + r.recordId + ': ' + e.getMessage());
            }
        }
    }

    // ── Submit ────────────────────────────────────────────────────────

    @AuraEnabled
    public static Id submit(Id recordId, String comments) {
        if (recordId == null) {
            throw new AuraHandledException('Record Id is required.');
        }

        Savepoint sp = Database.setSavepoint();
        try {
            return submitInternal(recordId, comments);
        } catch (DmlException e) {
            Database.rollback(sp);
            // DmlException stack traces are unhelpful in toast form — strip to
            // just the validation/permission message so the admin sees the
            // real cause (e.g. "Invalid status transition from Draft to Submitted").
            String msg = e.getDmlMessage(0);
            if (String.isBlank(msg)) msg = e.getMessage();
            throw new AuraHandledException('Submission blocked: ' + msg);
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Submission failed: ' + e.getMessage());
        }
    }

    private static Id submitInternal(Id recordId, String comments) {
        String objectType = recordId.getSObjectType().getDescribe().getName();

        List<Approval_Rule__c> rules = loadRules(objectType);
        if (rules.isEmpty()) {
            throw new AuraHandledException('No active approval rules for ' + objectType
                + '. Configure one in the Approval Rules window.');
        }

        // Block re-submission while a pending request exists
        Integer pending = [
            SELECT COUNT() FROM Approval_Request__c
            WHERE Record_Id__c = :String.valueOf(recordId) AND Status__c = 'Pending'
        ];
        if (pending > 0) {
            throw new AuraHandledException('A pending approval request already exists for this record.');
        }

        SObject record = loadRecord(objectType, recordId, rules);

        List<Approval_Rule__c> applicable = new List<Approval_Rule__c>();
        for (Approval_Rule__c r : rules) {
            if (matchesCondition(record, r)) applicable.add(r);
        }
        if (applicable.isEmpty()) {
            throw new AuraHandledException('No approval rules match this record\'s field values.');
        }

        // Group the matching rules by level. Multiple rules at the same level
        // means that level has several approvers — Approval_Mode__c decides
        // whether one of them or all of them must sign off.
        Map<Decimal, List<Approval_Rule__c>> byLevel = new Map<Decimal, List<Approval_Rule__c>>();
        for (Approval_Rule__c r : applicable) {
            Decimal lvl = (r.Approval_Level__c == null) ? 1 : r.Approval_Level__c;
            if (!byLevel.containsKey(lvl)) byLevel.put(lvl, new List<Approval_Rule__c>());
            byLevel.get(lvl).add(r);
        }
        List<Decimal> levels = new List<Decimal>(byLevel.keySet());
        levels.sort();

        Approval_Rule__c firstRule = byLevel.get(levels[0])[0];
        Id ownerId = (Id) record.get('OwnerId');

        // Resolve every approver BEFORE creating anything. A rule whose approver
        // resolves to null would otherwise produce a step no one can ever act on
        // — loadStepForAction requires the running user to BE the approver — so
        // the record would sit in Submitted forever with no way forward. Failing
        // here, naming the rule, is far kinder than stranding the record.
        Map<Id, Id> approverByRule = new Map<Id, Id>();
        List<String> unresolved = new List<String>();
        for (Decimal lvl : levels) {
            for (Approval_Rule__c r : byLevel.get(lvl)) {
                Id approverId = resolveApprover(r, ownerId);
                approverByRule.put(r.Id, approverId);
                if (approverId == null && r.Auto_Approve__c != true) {
                    unresolved.add(r.Name + ' (level ' + lvl + ', approver type '
                        + r.Approver_Type__c + ')');
                }
            }
        }
        if (!unresolved.isEmpty()) {
            throw new AuraHandledException(
                'Cannot route for approval — no approver could be resolved for: '
                + String.join(unresolved, '; ')
                + '. Check the rule\'s approver setup: "Manager" needs a Manager on the '
                + 'record owner\'s user, "Role"/"Queue" need at least one active member.');
        }

        Approval_Request__c request = new Approval_Request__c(
            Object_Type__c = objectType,
            Record_Id__c = String.valueOf(recordId),
            Record_Name__c = String.valueOf(record.get('Name')),
            Status__c = 'Pending',
            Current_Level__c = levels[0],
            Total_Levels__c = levels.size(),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_Date__c = Datetime.now(),
            Comments__c = comments,
            Approval_Mode__c = String.isBlank(firstRule.Approval_Mode__c)
                ? MODE_SEQUENTIAL : firstRule.Approval_Mode__c,
            Status_Field_API_Name__c = firstRule.Status_Field_API_Name__c,
            Status_Value_On_Approve__c = firstRule.Status_Value_On_Approve__c,
            Status_Value_On_Reject__c = firstRule.Status_Value_On_Reject__c
        );
        insert request;

        List<Approval_Step__c> steps = new List<Approval_Step__c>();
        for (Decimal lvl : levels) {
            for (Approval_Rule__c r : byLevel.get(lvl)) {
                steps.add(new Approval_Step__c(
                    Approval_Request__c = request.Id,
                    Approval_Rule__c = r.Id,
                    Level__c = lvl,
                    Approver__c = approverByRule.get(r.Id),
                    Approver_Type__c = r.Approver_Type__c,
                    Approver_Reference__c = r.Approver_Role_Queue__c,
                    Auto_Approve__c = (r.Auto_Approve__c == true),
                    Status__c = 'Pending',
                    Is_Current__c = false
                ));
            }
        }
        insert steps;

        // Stamp source record with the "Submitted" status value.
        // Lets validation-rule failures bubble up — the savepoint in
        // submit() rolls back the Request + Steps so we never leave a
        // half-submitted state.
        if (String.isNotBlank(firstRule.Status_Field_API_Name__c)
            && String.isNotBlank(firstRule.Status_Value_On_Submit__c)) {
            updateSourceStatus(String.valueOf(recordId),
                firstRule.Status_Field_API_Name__c, firstRule.Status_Value_On_Submit__c);
        }

        fireApprovalEvent(request.Id, 'Submitted');

        // Activate the first level, cascading through any auto-approve levels.
        processChain(request.Id);

        return request.Id;
    }

    // ── Approve ───────────────────────────────────────────────────────

    @AuraEnabled
    public static void approve(Id stepId, String comments) {
        Savepoint sp = Database.setSavepoint();
        try {
            approveInternal(stepId, comments);
        } catch (DmlException e) {
            Database.rollback(sp);
            String msg = e.getDmlMessage(0);
            if (String.isBlank(msg)) msg = e.getMessage();
            throw new AuraHandledException('Approval blocked: ' + msg);
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Approval failed: ' + e.getMessage());
        }
    }

    private static void approveInternal(Id stepId, String comments) {
        Approval_Step__c step = loadStepForAction(stepId);
        step.Status__c = 'Approved';
        step.Is_Current__c = false;
        step.Decision_Date__c = Datetime.now();
        step.Comments__c = comments;
        update step;

        Approval_Request__c req = [
            SELECT Id, Approval_Mode__c FROM Approval_Request__c
            WHERE Id = :step.Approval_Request__c
        ];

        // "Parallel Any" means one signature closes the level — retire the
        // sibling steps so they stop appearing in anyone's inbox.
        if (req.Approval_Mode__c == MODE_PARALLEL_ANY) {
            List<Approval_Step__c> siblings = [
                SELECT Id FROM Approval_Step__c
                WHERE Approval_Request__c = :step.Approval_Request__c
                  AND Level__c = :step.Level__c
                  AND Status__c = 'Pending'
            ];
            for (Approval_Step__c s : siblings) {
                s.Status__c = 'Skipped';
                s.Is_Current__c = false;
            }
            if (!siblings.isEmpty()) update siblings;
        }

        processChain(step.Approval_Request__c);
    }

    // ── Reject ────────────────────────────────────────────────────────

    @AuraEnabled
    public static void reject(Id stepId, String comments) {
        Savepoint sp = Database.setSavepoint();
        try {
            rejectInternal(stepId, comments);
        } catch (DmlException e) {
            Database.rollback(sp);
            String msg = e.getDmlMessage(0);
            if (String.isBlank(msg)) msg = e.getMessage();
            throw new AuraHandledException('Rejection blocked: ' + msg);
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Rejection failed: ' + e.getMessage());
        }
    }

    private static void rejectInternal(Id stepId, String comments) {
        Approval_Step__c step = loadStepForAction(stepId);
        step.Status__c = 'Rejected';
        step.Is_Current__c = false;
        step.Decision_Date__c = Datetime.now();
        step.Comments__c = comments;
        update step;

        Approval_Request__c req = [
            SELECT Id, Record_Id__c, Status_Field_API_Name__c, Status_Value_On_Reject__c
            FROM Approval_Request__c WHERE Id = :step.Approval_Request__c
        ];
        req.Status__c = 'Rejected';
        req.Completed_Date__c = Datetime.now();
        req.Current_Approver__c = null;
        update req;

        updateSourceStatus(req.Record_Id__c, req.Status_Field_API_Name__c, req.Status_Value_On_Reject__c);

        List<Approval_Step__c> remaining = [
            SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :req.Id AND Status__c = 'Pending'
        ];
        for (Approval_Step__c s : remaining) {
            s.Status__c = 'Skipped';
            s.Is_Current__c = false;
        }
        if (!remaining.isEmpty()) update remaining;

        fireApprovalEvent(req.Id, 'Rejected');
    }

    // ── Recall (submitter withdraws) ─────────────────────────────────

    @AuraEnabled
    public static void recall(Id requestId) {
        Approval_Request__c req = [
            SELECT Id, Submitted_By__c, Status__c
            FROM Approval_Request__c WHERE Id = :requestId
        ];
        if (req.Submitted_By__c != UserInfo.getUserId()) {
            throw new AuraHandledException('Only the submitter can recall this request.');
        }
        if (req.Status__c != 'Pending') {
            throw new AuraHandledException('Only pending requests can be recalled.');
        }
        req.Status__c = 'Recalled';
        req.Completed_Date__c = Datetime.now();
        req.Current_Approver__c = null;
        update req;

        List<Approval_Step__c> pending = [
            SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :requestId AND Status__c = 'Pending'
        ];
        for (Approval_Step__c s : pending) {
            s.Status__c = 'Skipped';
            s.Is_Current__c = false;
        }
        if (!pending.isEmpty()) update pending;

        fireApprovalEvent(requestId, 'Recalled');
    }

    // ── Approver inbox ────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Approval_Step__c> getMyApprovals() {
        return [
            SELECT Id, Level__c, Approver_Type__c, Status__c, Due_Date__c, Escalated__c,
                   Approval_Request__r.Name, Approval_Request__r.Record_Name__c,
                   Approval_Request__r.Object_Type__c, Approval_Request__r.Record_Id__c,
                   Approval_Request__r.Condition_Value__c,
                   Approval_Request__r.Submitted_By__r.Name,
                   Approval_Request__r.Submitted_Date__c
            FROM Approval_Step__c
            WHERE Approver__c = :UserInfo.getUserId()
              AND Status__c = 'Pending'
              AND Is_Current__c = true
              AND Approval_Request__r.Status__c = 'Pending'
            ORDER BY Approval_Request__r.Submitted_Date__c ASC
            LIMIT 200
        ];
    }

    // ── Simulation ────────────────────────────────────────────────────

    /**
     * @description Answers "who would approve this record, and why?" without
     *              creating anything. This is what lets an admin trust the
     *              matrix before switching it on. Returns the matched rules in
     *              level order with their resolved approver names, plus the
     *              rules that were evaluated and skipped.
     */
    @AuraEnabled
    public static Map<String, Object> simulate(Id recordId) {
        Map<String, Object> out = new Map<String, Object>();
        if (recordId == null) {
            out.put('error', 'Record Id is required.');
            return out;
        }
        String objectType = recordId.getSObjectType().getDescribe().getName();
        out.put('objectType', objectType);

        List<Approval_Rule__c> rules = loadRules(objectType);
        if (rules.isEmpty()) {
            out.put('error', 'No active approval rules for ' + objectType + '.');
            return out;
        }

        SObject record = loadRecord(objectType, recordId, rules);
        if (record == null) {
            out.put('error', 'Record not found.');
            return out;
        }
        out.put('recordName', String.valueOf(record.get('Name')));
        Id ownerId = (Id) record.get('OwnerId');

        List<Map<String, Object>> matched = new List<Map<String, Object>>();
        List<Map<String, Object>> skipped = new List<Map<String, Object>>();

        // Resolve every approver up front so the name lookup is one query.
        Map<Id, Id> approverByRule = new Map<Id, Id>();
        Set<Id> approverIds = new Set<Id>();
        for (Approval_Rule__c r : rules) {
            Id aid = resolveApprover(r, ownerId);
            approverByRule.put(r.Id, aid);
            if (aid != null) approverIds.add(aid);
        }
        Map<Id, User> userById = approverIds.isEmpty()
            ? new Map<Id, User>()
            : new Map<Id, User>([SELECT Id, Name FROM User WHERE Id IN :approverIds]);

        for (Approval_Rule__c r : rules) {
            Id aid = approverByRule.get(r.Id);
            Map<String, Object> row = new Map<String, Object>{
                'ruleId'       => r.Id,
                'ruleName'     => r.Name,
                'level'        => r.Approval_Level__c,
                'approverType' => r.Approver_Type__c,
                'approverId'   => aid,
                'approverName' => aid != null && userById.containsKey(aid)
                                    ? userById.get(aid).Name : null,
                'autoApprove'  => (r.Auto_Approve__c == true),
                'mode'         => String.isBlank(r.Approval_Mode__c)
                                    ? MODE_SEQUENTIAL : r.Approval_Mode__c
            };
            if (matchesCondition(record, r)) {
                if (aid == null && r.Auto_Approve__c != true) {
                    row.put('warning', 'No approver could be resolved for this rule.');
                }
                matched.add(row);
            } else {
                row.put('reason', 'Entry criteria not met');
                skipped.add(row);
            }
        }

        out.put('matched', matched);
        out.put('skipped', skipped);
        out.put('willRoute', !matched.isEmpty());
        return out;
    }

    // ── Escalation ────────────────────────────────────────────────────

    /**
     * @description Reassigns overdue steps. Call from a scheduled job (hourly
     *              is typical) or from the admin UI. Bulk-safe and bounded.
     *              A step escalates to the rule's Escalation Approver, or to
     *              the current approver's manager when that is blank.
     */
    @AuraEnabled
    public static Integer processEscalations() {
        List<Approval_Step__c> due = [
            SELECT Id, Approver__c, Level__c, Approval_Request__c, Due_Date__c,
                   Approval_Rule__r.Escalation_Approver__c,
                   Approval_Rule__r.Escalation_Hours__c
            FROM Approval_Step__c
            WHERE Status__c = 'Pending'
              AND Is_Current__c = true
              AND Escalated__c = false
              AND Due_Date__c != null
              AND Due_Date__c < :Datetime.now()
              AND Approval_Request__r.Status__c = 'Pending'
            LIMIT 200
        ];
        if (due.isEmpty()) return 0;

        // Bulk-resolve managers for every step that has no explicit escalation
        // approver, so the loop below does no queries.
        Set<Id> needManager = new Set<Id>();
        for (Approval_Step__c s : due) {
            if (s.Approval_Rule__r == null || s.Approval_Rule__r.Escalation_Approver__c == null) {
                if (s.Approver__c != null) needManager.add(s.Approver__c);
            }
        }
        Map<Id, Id> managerOf = new Map<Id, Id>();
        if (!needManager.isEmpty()) {
            for (User u : [SELECT Id, ManagerId FROM User WHERE Id IN :needManager]) {
                managerOf.put(u.Id, u.ManagerId);
            }
        }

        List<Approval_Step__c> toUpdate = new List<Approval_Step__c>();
        Map<Id, Id> newApproverByRequest = new Map<Id, Id>();

        for (Approval_Step__c s : due) {
            Id target = (s.Approval_Rule__r != null)
                ? s.Approval_Rule__r.Escalation_Approver__c : null;
            if (target == null) target = managerOf.get(s.Approver__c);
            // Nobody to escalate to, or it would be a no-op — leave it alone
            // rather than silently marking it escalated.
            if (target == null || target == s.Approver__c) continue;

            s.Original_Approver__c = s.Approver__c;
            s.Approver__c = target;
            s.Escalated__c = true;
            Decimal hrs = (s.Approval_Rule__r == null) ? null : s.Approval_Rule__r.Escalation_Hours__c;
            s.Due_Date__c = (hrs == null) ? null
                : Datetime.now().addMinutes(Integer.valueOf(hrs * 60));
            toUpdate.add(s);
            newApproverByRequest.put(s.Approval_Request__c, target);
        }

        if (toUpdate.isEmpty()) return 0;
        update toUpdate;

        List<Approval_Request__c> reqs = new List<Approval_Request__c>();
        for (Id reqId : newApproverByRequest.keySet()) {
            reqs.add(new Approval_Request__c(
                Id = reqId, Current_Approver__c = newApproverByRequest.get(reqId)));
        }
        update reqs;

        for (Id reqId : newApproverByRequest.keySet()) {
            fireApprovalEvent(reqId, 'Escalated');
        }
        return toUpdate.size();
    }

    // ── Internals ─────────────────────────────────────────────────────

    /**
     * @description Loads the active, in-date rules for an object in level order.
     */
    private static List<Approval_Rule__c> loadRules(String objectType) {
        Date today = Date.today();
        // Match rules stored under EITHER the namespaced or the unqualified
        // object name — rule data may carry either form once the app runs inside
        // the managed-package (ftretailmake) namespace.
        Set<String> objectNames = new Set<String>{ objectType, unqualify(objectType) };
        return [
            SELECT Id, Name, Approval_Level__c, Approver_Type__c, User__c, Approver_Role_Queue__c,
                   Auto_Approve__c, Condition_Field__c, Min_Value__c, Max_Value__c,
                   Approval_Mode__c, Criteria_Logic__c,
                   Escalation_Hours__c, Escalation_Approver__c,
                   Status_Field_API_Name__c, Status_Value_On_Submit__c,
                   Status_Value_On_Approve__c, Status_Value_On_Reject__c,
                   (SELECT Field_API_Name__c, Operator__c, Value__c, Sequence__c
                    FROM Conditions__r ORDER BY Sequence__c NULLS LAST)
            FROM Approval_Rule__c
            WHERE Object_Process__c IN :objectNames
              AND Is_Active__c = true
              AND (Effective_From__c = null OR Effective_From__c <= :today)
              AND (Effective_To__c = null OR Effective_To__c >= :today)
            ORDER BY Approval_Level__c ASC NULLS FIRST
        ];
    }

    /**
     * @description Pulls the source record with every field any rule
     *              references — the legacy Condition_Field__c, the status
     *              field, and each per-condition Field_API_Name__c. Unknown
     *              field names are dropped rather than blowing up the query,
     *              because a rule can outlive the field it was written against.
     */
    private static SObject loadRecord(String objectType, Id recordId, List<Approval_Rule__c> rules) {
        Map<String, Schema.SObjectField> fmap =
            Schema.getGlobalDescribe().get(objectType).getDescribe().fields.getMap();

        Set<String> fieldsToQuery = new Set<String>{ 'Id', 'OwnerId' };
        if (fmap.containsKey('name')) fieldsToQuery.add('Name');

        for (Approval_Rule__c r : rules) {
            addIfReal(fieldsToQuery, fmap, r.Condition_Field__c);
            addIfReal(fieldsToQuery, fmap, r.Status_Field_API_Name__c);
            if (r.Conditions__r == null) continue;
            for (Approval_Rule_Condition__c c : r.Conditions__r) {
                addIfReal(fieldsToQuery, fmap, c.Field_API_Name__c);
            }
        }

        String soql = 'SELECT ' + String.join(new List<String>(fieldsToQuery), ', ')
            + ' FROM ' + objectType + ' WHERE Id = :recordId LIMIT 1';
        List<SObject> recs = Database.query(soql);
        return recs.isEmpty() ? null : recs[0];
    }

    private static void addIfReal(Set<String> acc, Map<String, Schema.SObjectField> fmap, String field) {
        if (String.isBlank(field)) return;
        if (field.contains('.')) return; // relationship paths aren't supported in criteria
        // Resolve the stored (possibly unqualified) name to the object's real
        // field API name so the query works in the managed-package namespace.
        String real = realFieldName(fmap, field);
        if (real != null) acc.add(real);
    }

    /**
     * @description Resolve a stored condition-field name (which may be
     *              unqualified, e.g. 'Total_Net_Amount__c') to the object's
     *              actual field API name (e.g. 'ftretailmake__Total_Net_Amount__c'
     *              in the managed-package namespace). Namespace-agnostic: works
     *              whether the org carries the namespace or not.
     */
    private static String realFieldName(Map<String, Schema.SObjectField> fmap, String stored) {
        if (String.isBlank(stored) || stored.contains('.')) return null;
        if (fmap.containsKey(stored.toLowerCase())) {
            return fmap.get(stored.toLowerCase()).getDescribe().getName();
        }
        String bare = unqualify(stored).toLowerCase();
        for (String key : fmap.keySet()) {
            if (unqualify(key).equalsIgnoreCase(bare)) {
                return fmap.get(key).getDescribe().getName();
            }
        }
        return null;
    }

    /** Strip a leading '<namespace>__' from a custom API name (ns__X__c -> X__c). */
    private static String unqualify(String api) {
        if (String.isBlank(api)) return api;
        if (api.endsWithIgnoreCase('__c') && api.split('__').size() >= 3) {
            return api.substringAfter('__');
        }
        return api;
    }

    private static Approval_Step__c loadStepForAction(Id stepId) {
        if (stepId == null) throw new AuraHandledException('Step Id is required.');
        Approval_Step__c step = [
            SELECT Id, Approval_Request__c, Status__c, Is_Current__c,
                   Approver__c, Level__c
            FROM Approval_Step__c WHERE Id = :stepId LIMIT 1
        ];
        if (step.Status__c != 'Pending') {
            throw new AuraHandledException('This step is already ' + step.Status__c + '.');
        }
        if (!step.Is_Current__c) {
            throw new AuraHandledException('This is not the current step.');
        }
        if (step.Approver__c != UserInfo.getUserId()) {
            throw new AuraHandledException('You are not the approver for this step.');
        }
        return step;
    }

    /**
     * @description Advances the request to whichever level should be active
     *              next, auto-approving any level whose steps are all flagged
     *              Auto_Approve__c, and completing the request when nothing
     *              pending remains. Single pass — no re-query loop.
     */
    private static void processChain(Id requestId) {
        Approval_Request__c req = [
            SELECT Id, Status__c, Current_Level__c, Total_Levels__c, Record_Id__c,
                   Status_Field_API_Name__c, Status_Value_On_Approve__c
            FROM Approval_Request__c WHERE Id = :requestId
        ];
        if (req.Status__c != 'Pending') return;

        List<Approval_Step__c> steps = [
            SELECT Id, Level__c, Status__c, Approver__c, Auto_Approve__c, Is_Current__c,
                   Approval_Rule__r.Escalation_Hours__c
            FROM Approval_Step__c
            WHERE Approval_Request__c = :requestId
            ORDER BY Level__c ASC
        ];

        // Collect the pending steps per level, preserving level order.
        Map<Decimal, List<Approval_Step__c>> pendingByLevel = new Map<Decimal, List<Approval_Step__c>>();
        List<Decimal> levelOrder = new List<Decimal>();
        for (Approval_Step__c s : steps) {
            if (s.Status__c != 'Pending') continue;
            Decimal lvl = (s.Level__c == null) ? 1 : s.Level__c;
            if (!pendingByLevel.containsKey(lvl)) {
                pendingByLevel.put(lvl, new List<Approval_Step__c>());
                levelOrder.add(lvl);
            }
            pendingByLevel.get(lvl).add(s);
        }
        levelOrder.sort();

        List<Approval_Step__c> toUpdate = new List<Approval_Step__c>();
        List<Approval_Step__c> activated = new List<Approval_Step__c>();
        Decimal activeLevel = null;

        for (Decimal lvl : levelOrder) {
            List<Approval_Step__c> atLevel = pendingByLevel.get(lvl);

            Boolean allAuto = true;
            for (Approval_Step__c s : atLevel) {
                if (s.Auto_Approve__c != true) { allAuto = false; break; }
            }

            if (allAuto) {
                for (Approval_Step__c s : atLevel) {
                    s.Status__c = 'Auto-Approved';
                    s.Is_Current__c = false;
                    s.Decision_Date__c = Datetime.now();
                    s.Comments__c = 'Auto-approved (rule condition matched)';
                    toUpdate.add(s);
                }
                continue; // whole level cleared — look at the next one
            }

            // Mixed level: auto-approve the flagged steps, activate the rest.
            for (Approval_Step__c s : atLevel) {
                if (s.Auto_Approve__c == true) {
                    s.Status__c = 'Auto-Approved';
                    s.Is_Current__c = false;
                    s.Decision_Date__c = Datetime.now();
                    s.Comments__c = 'Auto-approved (rule condition matched)';
                } else {
                    s.Is_Current__c = true;
                    Decimal hrs = (s.Approval_Rule__r == null)
                        ? null : s.Approval_Rule__r.Escalation_Hours__c;
                    if (hrs != null && hrs > 0) {
                        s.Due_Date__c = Datetime.now().addMinutes(Integer.valueOf(hrs * 60));
                    }
                    activated.add(s);
                }
                toUpdate.add(s);
            }
            activeLevel = lvl;
            break;
        }

        if (!toUpdate.isEmpty()) update toUpdate;

        if (activeLevel == null) {
            // Nothing left to approve — the chain is complete.
            req.Status__c = 'Approved';
            req.Completed_Date__c = Datetime.now();
            req.Current_Approver__c = null;
            update req;
            updateSourceStatus(req.Record_Id__c, req.Status_Field_API_Name__c,
                req.Status_Value_On_Approve__c);
            fireApprovalEvent(req.Id, 'Approved');
            return;
        }

        req.Current_Level__c = activeLevel;
        req.Current_Approver__c = activated.isEmpty() ? null : activated[0].Approver__c;
        update req;
        fireApprovalEvent(req.Id, 'Approval Assigned');
    }

    /**
     * @description Returns true if the rule's entry criteria are satisfied.
     *              Condition rows honour Criteria_Logic__c (AND / OR). When a
     *              rule has no condition rows it falls back to the legacy
     *              single-field Min/Max band so older rules still work.
     */
    private static Boolean matchesCondition(SObject record, Approval_Rule__c rule) {
        if (record == null) return false;

        // Field map of the record's object, so stored (possibly unqualified)
        // condition-field names resolve to the real namespaced API name.
        Map<String, Schema.SObjectField> fmap =
            record.getSObjectType().getDescribe().fields.getMap();

        if (rule.Conditions__r != null && !rule.Conditions__r.isEmpty()) {
            Boolean useOr = (rule.Criteria_Logic__c == 'OR');
            Boolean sawOne = false;
            for (Approval_Rule_Condition__c c : rule.Conditions__r) {
                if (String.isBlank(c.Field_API_Name__c) || String.isBlank(c.Operator__c)) continue;
                sawOne = true;
                String realName = realFieldName(fmap, c.Field_API_Name__c);
                Object fieldValue;
                try { fieldValue = (realName == null) ? null : record.get(realName); }
                catch (Exception e) { fieldValue = null; }
                Boolean hit = evalCondition(fieldValue, c.Operator__c, c.Value__c);
                if (useOr && hit) return true;
                if (!useOr && !hit) return false;
            }
            // AND with all rows passing -> true. OR with none passing -> false.
            return sawOne ? !useOr : true;
        }

        // Legacy fallback — single field with Min/Max range
        if (String.isBlank(rule.Condition_Field__c)) return true;
        String realCond = realFieldName(fmap, rule.Condition_Field__c);
        Object raw;
        try { raw = (realCond == null) ? null : record.get(realCond); }
        catch (Exception e) { return false; }
        if (raw == null) return (rule.Min_Value__c == null && rule.Max_Value__c == null);
        Decimal num = tryDecimal(String.valueOf(raw));
        if (num == null) return false;
        if (rule.Min_Value__c != null && num < rule.Min_Value__c) return false;
        if (rule.Max_Value__c != null && num > rule.Max_Value__c) return false;
        return true;
    }

    /**
     * @description Evaluates a single Field op Value comparison. Uses the
     *              operator labels surfaced in the LWC (equals, not equal to,
     *              starts with, contains, does not contain, less/greater than,
     *              less/greater or equal, includes, excludes, is null,
     *              is not null).
     */
    private static Boolean evalCondition(Object fieldValue, String op, String compareValue) {
        if (op == 'is null')     return fieldValue == null
            || String.isBlank(String.valueOf(fieldValue));
        if (op == 'is not null') return fieldValue != null
            && String.isNotBlank(String.valueOf(fieldValue));

        if (fieldValue == null) return false;
        String fvStr = String.valueOf(fieldValue);
        String cvStr = compareValue == null ? '' : compareValue;
        Decimal fvNum = tryDecimal(fvStr);
        Decimal cvNum = tryDecimal(cvStr);

        if (op == 'equals')           return fvStr == cvStr;
        if (op == 'not equal to')     return fvStr != cvStr;
        if (op == 'starts with')      return fvStr.startsWith(cvStr);
        if (op == 'contains')         return fvStr.contains(cvStr);
        if (op == 'does not contain') return !fvStr.contains(cvStr);
        if (op == 'less than'         && fvNum != null && cvNum != null) return fvNum < cvNum;
        if (op == 'greater than'      && fvNum != null && cvNum != null) return fvNum > cvNum;
        if (op == 'less or equal'     && fvNum != null && cvNum != null) return fvNum <= cvNum;
        if (op == 'greater or equal'  && fvNum != null && cvNum != null) return fvNum >= cvNum;
        if (op == 'includes')         return fvStr.contains(cvStr);
        if (op == 'excludes')         return !fvStr.contains(cvStr);
        return false;
    }

    private static Decimal tryDecimal(String s) {
        if (String.isBlank(s)) return null;
        try { return Decimal.valueOf(s); } catch (Exception e) { return null; }
    }

    private static Id resolveApprover(Approval_Rule__c rule, Id ownerId) {
        String type = rule.Approver_Type__c;
        if (type == 'User') {
            return rule.User__c;
        }
        if (type == 'Manager') {
            if (ownerId == null) return null;
            List<User> mgr = [SELECT ManagerId FROM User WHERE Id = :ownerId LIMIT 1];
            return mgr.isEmpty() ? null : mgr[0].ManagerId;
        }
        if (type == 'Role') {
            String roleName = rule.Approver_Role_Queue__c;
            if (String.isBlank(roleName)) return null;
            List<User> users = [
                SELECT Id FROM User
                WHERE IsActive = true
                  AND UserRoleId IN (SELECT Id FROM UserRole WHERE DeveloperName = :roleName)
                ORDER BY Name LIMIT 1
            ];
            return users.isEmpty() ? null : users[0].Id;
        }
        if (type == 'Queue') {
            String queueName = rule.Approver_Role_Queue__c;
            if (String.isBlank(queueName)) return null;
            List<GroupMember> members = [
                SELECT UserOrGroupId FROM GroupMember
                WHERE Group.Type = 'Queue' AND Group.DeveloperName = :queueName
                LIMIT 50
            ];
            for (GroupMember gm : members) {
                if (gm.UserOrGroupId != null
                    && gm.UserOrGroupId.getSObjectType() == User.SObjectType) {
                    return gm.UserOrGroupId;
                }
            }
            return null;
        }
        return rule.User__c;
    }

    private static void updateSourceStatus(String recordIdStr, String fieldName, String value) {
        if (String.isBlank(recordIdStr) || String.isBlank(fieldName) || String.isBlank(value)) return;
        Id recordId = Id.valueOf(recordIdStr);

        // A rule can outlive the field it names, and a field can be made
        // read-only. Either way, silently skipping beats throwing mid-approval.
        Map<String, Schema.SObjectField> fmap =
            recordId.getSObjectType().getDescribe().fields.getMap();
        Schema.SObjectField f = fmap.get(fieldName.toLowerCase());
        if (f == null || !f.getDescribe().isUpdateable()) {
            System.debug(LoggingLevel.WARN,
                'Approval status writeback skipped — ' + fieldName + ' is missing or not updateable.');
            return;
        }

        SObject rec = recordId.getSObjectType().newSObject(recordId);
        rec.put(fieldName, value);
        try {
            update rec;
        } catch (DmlException e) {
            // The source record's own validation rules / flows / triggers
            // can refuse a status update for reasons that have nothing to do
            // with approval (e.g. Sales Order's must-sell products flow). We
            // can't block the entire approval workflow on those — the
            // Approval_Request__c itself is already the source of truth for
            // "is this approved?" — so swallow the FIELD_CUSTOM_VALIDATION
            // exceptions and let the approval finish. The status field on
            // the source just won't move; admin can either fix the
            // validation rule, blank out the rule's Status Mapping, or sync
            // the field manually.
            if (e.getDmlType(0) == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION) {
                System.debug(LoggingLevel.WARN,
                    'Approval status writeback blocked by source validation: '
                    + e.getDmlMessage(0));
                return;
            }
            throw e;
        }
    }

    // ── Notifications ─────────────────────────────────────────────────

    /**
     * @description Raises an approval event two ways: a guaranteed in-app bell
     *              so the engine is useful with zero notification config, and
     *              a configurable dispatch against the Approval_Request__c
     *              record so admins can attach Email/SMS/WhatsApp themselves.
     */
    private static void fireApprovalEvent(Id requestId, String eventType) {
        Approval_Request__c req;
        try {
            req = [
                SELECT Id, Record_Name__c, Object_Type__c, Record_Id__c,
                       Current_Approver__c, Current_Level__c, Submitted_By__c, OwnerId
                FROM Approval_Request__c WHERE Id = :requestId LIMIT 1
            ];
        } catch (Exception e) {
            return;
        }

        Id bellTarget;
        String title;
        String body;
        if (eventType == 'Approval Assigned' || eventType == 'Escalated') {
            bellTarget = req.Current_Approver__c;
            title = 'Approval needed: ' + req.Record_Name__c;
            body  = 'Level ' + req.Current_Level__c + ' approval pending on '
                  + req.Object_Type__c + ' ' + req.Record_Name__c + '.';
        } else if (eventType == 'Approved' || eventType == 'Rejected') {
            bellTarget = req.Submitted_By__c;
            title = 'Approval ' + eventType + ': ' + req.Record_Name__c;
            body  = 'Your ' + req.Object_Type__c + ' ' + req.Record_Name__c
                  + ' was ' + eventType.toLowerCase() + '.';
        }

        if (bellTarget != null) {
            sendBell(title, body, req.Record_Id__c,
                new Set<String>{ String.valueOf(bellTarget) });
        }

        // Configurable channels. Never let a notification problem roll back an
        // approval decision that has already been recorded.
        try {
            NotificationDispatcher.dispatch(
                APPROVAL_OBJECT, eventType, new List<SObject>{ req });
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Approval notification dispatch failed: ' + e.getMessage());
        }
    }

    private static void sendBell(String title, String body, String targetId, Set<String> recipients) {
        Id notifTypeId = getCustomNotificationTypeId();
        if (notifTypeId == null || recipients == null || recipients.isEmpty()) return;
        try {
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(notifTypeId);
            n.setTitle(title);
            n.setBody(body);
            if (String.isNotBlank(targetId)) n.setTargetId(targetId);
            n.send(recipients);
        } catch (Exception e) {
            System.debug('Approval notification failed: ' + e.getMessage());
        }
    }

    private static Id cachedNotifTypeId;
    private static Boolean notifTypeLoaded = false;
    private static Id getCustomNotificationTypeId() {
        if (notifTypeLoaded) return cachedNotifTypeId;
        notifTypeLoaded = true;
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = :NOTIF_TYPE_DEV_NAME LIMIT 1
        ];
        cachedNotifTypeId = types.isEmpty() ? null : types[0].Id;
        return cachedNotifTypeId;
    }
}