/**
 * @description The single notification engine for the product.
 *
 * Reads Notification_Setting__c rows and delivers the configured notifications
 * for a given object + event across Email, In-App, SMS and WhatsApp. Behaviour
 * is entirely configuration-driven: Event_Object__c is plain text, so any
 * object can raise notifications without a deploy.
 *
 * Per setting an admin controls:
 *   - which object + event fires it (Event_Object__c / Event_Type__c)
 *   - an optional record filter (Criteria_Field/Operator/Value) so a rule can
 *     fire for "Amount > 50000" rather than every record
 *   - who receives it (Recipient_Type__c, including a User lookup field on the
 *     record itself, plus Additional_Emails__c for fixed addresses)
 *   - which channels carry it (Channel_Email/InApp/SMS/WhatsApp)
 *   - the merged Subject/Body templates, supporting {!Field__c} and
 *     {!Relationship__r.Field__c} paths
 *
 * Every send is written to Notification_Log__c — including skips and failures,
 * which is what makes "why didn't my alert arrive?" answerable.
 *
 * SMS and WhatsApp deliver through the Integrations window: when the matching
 * integration is enabled and credentialed the send is enqueued as a real REST
 * callout, otherwise it is logged as Skipped rather than silently dropped.
 */
public with sharing class NotificationDispatcher implements Queueable, Database.AllowsCallouts {

    private static final String NOTIF_TYPE_DEV_NAME = 'FMCG_Notification';
    private static final Pattern TOKEN = Pattern.compile('\\{!([A-Za-z0-9_\\.]+)\\}');

    private static final String CHANNEL_SMS      = 'SMS';
    private static final String CHANNEL_WHATSAPP = 'WhatsApp';
    private static final String INTEGRATION_SMS      = 'sms';
    private static final String INTEGRATION_WHATSAPP = 'whatsapp';

    // ── Entry points ──────────────────────────────────────────────────

    /**
     * @description Main entry point. Triggers call this to fire any matching rules.
     */
    public static void dispatch(String objectApiName, String eventType, List<SObject> records) {
        if (String.isBlank(objectApiName) || String.isBlank(eventType)
            || records == null || records.isEmpty()) {
            return;
        }

        List<Notification_Setting__c> rules = [
            SELECT Id,
                   Event_Object__c, Event_Type__c,
                   Recipient_Type__c, Recipient_User__c, Recipient_Reference__c,
                   Recipient_Field__c, Additional_Emails__c,
                   Criteria_Field__c, Criteria_Operator__c, Criteria_Value__c,
                   Channel_Email__c, Channel_InApp__c, Channel_WhatsApp__c, Channel_SMS__c,
                   Subject_Template__c, Body_Template__c,
                   Is_Active__c
            FROM Notification_Setting__c
            WHERE Event_Object__c = :objectApiName
              AND Event_Type__c = :eventType
              AND Is_Active__c = true
        ];

        if (rules.isEmpty()) return;

        // Re-query records with all merge-field paths populated. Trigger.new only
        // carries directly-set fields, so {!Owner.Name} / {!Account__r.Name} etc.
        // resolve to null otherwise. Parse all templates, collect referenced
        // field paths, and re-query records using a dynamic SOQL.
        records = reloadRecordsWithMergeFields(objectApiName, records, rules);

        Set<Id> ownerIds = new Set<Id>();
        for (SObject rec : records) {
            Object ownerId = safeGet(rec, 'OwnerId');
            if (ownerId != null) ownerIds.add((Id) ownerId);
        }
        Map<Id, User> ownerMap = ownerIds.isEmpty()
            ? new Map<Id, User>()
            : new Map<Id, User>([SELECT Id, ManagerId, Email FROM User WHERE Id IN :ownerIds]);

        Id notifTypeId = getCustomNotificationTypeId();

        List<Notification_Log__c> logs = new List<Notification_Log__c>();

        for (Notification_Setting__c rule : rules) {
            for (SObject rec : records) {
                // Record-level filter: a rule with criteria only fires for the
                // records that satisfy it.
                if (!matchesCriteria(rule, rec)) continue;

                Set<Id> recipients = resolveRecipients(rule, rec, ownerMap);
                List<String> extraEmails = parseEmails(rule.Additional_Emails__c);
                if (recipients.isEmpty() && extraEmails.isEmpty()) continue;

                String subject = mergeTemplate(rule.Subject_Template__c, rec);
                String body    = mergeTemplate(rule.Body_Template__c, rec);

                if (rule.Channel_Email__c) {
                    logs.addAll(sendEmail(rule, rec, recipients, extraEmails, subject, body, eventType));
                }
                if (rule.Channel_InApp__c && notifTypeId != null && !recipients.isEmpty()) {
                    logs.addAll(sendInApp(rule, rec, recipients, subject, body, notifTypeId, eventType));
                }
                if (rule.Channel_SMS__c && !recipients.isEmpty()) {
                    logs.addAll(sendGatewayChannel(
                        rule, rec, recipients, subject, body, eventType,
                        CHANNEL_SMS, INTEGRATION_SMS));
                }
                if (rule.Channel_WhatsApp__c && !recipients.isEmpty()) {
                    logs.addAll(sendGatewayChannel(
                        rule, rec, recipients, subject, body, eventType,
                        CHANNEL_WHATSAPP, INTEGRATION_WHATSAPP));
                }
            }
        }

        if (!logs.isEmpty()) {
            try {
                insert logs;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'NotificationDispatcher: log insert failed - ' + e.getMessage());
            }
        }
    }

    /** Convenience overload: one record, one event. */
    public static void dispatch(Id recordId, String eventType) {
        if (recordId == null || String.isBlank(eventType)) return;
        String objApi = recordId.getSObjectType().getDescribe().getName();
        List<SObject> recs = Database.query(
            'SELECT Id FROM ' + objApi + ' WHERE Id = :recordId LIMIT 1');
        if (!recs.isEmpty()) dispatch(objApi, eventType, recs);
    }

    /** Bulk overload keyed by record. Groups by object + event so each
     *  distinct combination costs one dispatch rather than one per record. */
    public static void dispatch(Map<Id, String> recordIdToEvent) {
        if (recordIdToEvent == null || recordIdToEvent.isEmpty()) return;
        Map<String, List<Id>> byObjectAndEvent = new Map<String, List<Id>>();
        for (Id recId : recordIdToEvent.keySet()) {
            String evt = recordIdToEvent.get(recId);
            if (String.isBlank(evt)) continue;
            String key = recId.getSObjectType().getDescribe().getName() + '|' + evt;
            if (!byObjectAndEvent.containsKey(key)) byObjectAndEvent.put(key, new List<Id>());
            byObjectAndEvent.get(key).add(recId);
        }
        for (String key : byObjectAndEvent.keySet()) {
            List<String> parts = key.split('\\|');
            List<Id> ids = byObjectAndEvent.get(key);
            List<SObject> recs = Database.query(
                'SELECT Id FROM ' + parts[0] + ' WHERE Id IN :ids');
            if (!recs.isEmpty()) dispatch(parts[0], parts[1], recs);
        }
    }

    /**
     * @description Direct, unconfigured send to specific users. Used where the
     *              recipient is known from context rather than from a rule.
     */
    public static void notifyUsers(Set<Id> userIds, Id targetId, String subject, String body) {
        if (userIds == null || userIds.isEmpty()) return;
        Id notifTypeId = getCustomNotificationTypeId();
        if (notifTypeId != null) {
            try {
                Messaging.CustomNotification n = new Messaging.CustomNotification();
                n.setNotificationTypeId(notifTypeId);
                n.setTitle(String.isBlank(subject) ? 'FMCG Notification' : subject.left(250));
                n.setBody(String.isBlank(body) ? subject : body.left(750));
                if (targetId != null) n.setTargetId(targetId);
                Set<String> recipients = new Set<String>();
                for (Id uid : userIds) recipients.add(String.valueOf(uid));
                n.send(recipients);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Direct in-app notify failed: ' + e.getMessage());
            }
        }

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        for (Id uid : userIds) {
            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setTargetObjectId(uid);
            msg.setSaveAsActivity(false);
            msg.setSubject(String.isBlank(subject) ? 'FMCG Notification' : subject);
            msg.setPlainTextBody(String.isBlank(body) ? subject : body);
            emails.add(msg);
        }
        try {
            if (!emails.isEmpty()) Messaging.sendEmail(emails, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Direct email notify failed: ' + e.getMessage());
        }
    }

    // ── Record-level criteria ─────────────────────────────────────────

    /**
     * @description Applies the setting's optional record filter. Operator
     *              semantics deliberately mirror the approval matrix so an
     *              admin learns one comparison vocabulary for both windows.
     */
    @TestVisible
    private static Boolean matchesCriteria(Notification_Setting__c rule, SObject rec) {
        if (String.isBlank(rule.Criteria_Field__c) || String.isBlank(rule.Criteria_Operator__c)) {
            return true; // no filter configured -> always fire
        }
        Object fieldValue = resolveTokenValue(rec, rule.Criteria_Field__c);
        String op = rule.Criteria_Operator__c;
        String cv = rule.Criteria_Value__c;

        if (op == 'is null')     return fieldValue == null || String.isBlank(String.valueOf(fieldValue));
        if (op == 'is not null') return fieldValue != null && String.isNotBlank(String.valueOf(fieldValue));
        if (fieldValue == null) return false;

        String fv = String.valueOf(fieldValue);
        String cvStr = cv == null ? '' : cv;
        Decimal fvNum = tryDecimal(fv);
        Decimal cvNum = tryDecimal(cvStr);

        if (op == 'equals')           return fv == cvStr;
        if (op == 'not equal to')     return fv != cvStr;
        if (op == 'contains')         return fv.contains(cvStr);
        if (op == 'does not contain') return !fv.contains(cvStr);
        if (op == 'starts with')      return fv.startsWith(cvStr);
        if (op == 'greater than'      && fvNum != null && cvNum != null) return fvNum > cvNum;
        if (op == 'less than'         && fvNum != null && cvNum != null) return fvNum < cvNum;
        if (op == 'greater or equal'  && fvNum != null && cvNum != null) return fvNum >= cvNum;
        if (op == 'less or equal'     && fvNum != null && cvNum != null) return fvNum <= cvNum;
        return false;
    }

    private static Decimal tryDecimal(String s) {
        if (String.isBlank(s)) return null;
        try { return Decimal.valueOf(s); } catch (Exception e) { return null; }
    }

    // ── Recipient resolution ───────────────────────────────────────────

    private static Set<Id> resolveRecipients(Notification_Setting__c rule, SObject rec, Map<Id, User> ownerMap) {
        Set<Id> result = new Set<Id>();
        String type = rule.Recipient_Type__c;
        if (String.isBlank(type)) return result;

        if (type == 'Specific User' && rule.Recipient_User__c != null) {
            result.add(rule.Recipient_User__c);

        } else if (type == 'Record Owner') {
            Object oid = safeGet(rec, 'OwnerId');
            if (isUserId(oid)) result.add((Id) oid);

        } else if (type == 'Owners Manager') {
            Object oid = safeGet(rec, 'OwnerId');
            if (oid != null && ownerMap.containsKey((Id) oid)) {
                User owner = ownerMap.get((Id) oid);
                if (owner.ManagerId != null) result.add(owner.ManagerId);
            }

        } else if (type == 'Field on Record') {
            // The single most useful recipient type in practice: send to
            // whoever a User lookup on the record points at (Sales_Rep__c,
            // Assigned_To__c, Current_Approver__c, ...).
            if (String.isNotBlank(rule.Recipient_Field__c)) {
                Object v = resolveTokenValue(rec, rule.Recipient_Field__c);
                if (isUserId(v)) result.add((Id) v);
            }

        } else if (type == 'Submitter') {
            Object v = safeGet(rec, 'Submitted_By__c');
            if (v == null) v = safeGet(rec, 'CreatedById');
            if (isUserId(v)) result.add((Id) v);

        } else if (type == 'Role' && String.isNotBlank(rule.Recipient_Reference__c)) {
            for (User u : [
                SELECT Id FROM User
                WHERE IsActive = true
                  AND UserRole.DeveloperName = :rule.Recipient_Reference__c
                LIMIT 200
            ]) { result.add(u.Id); }

        } else if (type == 'Profile' && String.isNotBlank(rule.Recipient_Reference__c)) {
            for (User u : [
                SELECT Id FROM User
                WHERE IsActive = true
                  AND Profile.Name = :rule.Recipient_Reference__c
                LIMIT 200
            ]) { result.add(u.Id); }

        } else if (type == 'Public Group' && String.isNotBlank(rule.Recipient_Reference__c)) {
            for (GroupMember gm : [
                SELECT UserOrGroupId FROM GroupMember
                WHERE Group.DeveloperName = :rule.Recipient_Reference__c
                  AND Group.Type = 'Regular'
                LIMIT 200
            ]) {
                if (isUserId(gm.UserOrGroupId)) result.add(gm.UserOrGroupId);
            }

        } else if (type == 'Queue' && String.isNotBlank(rule.Recipient_Reference__c)) {
            for (GroupMember gm : [
                SELECT UserOrGroupId FROM GroupMember
                WHERE Group.DeveloperName = :rule.Recipient_Reference__c
                  AND Group.Type = 'Queue'
                LIMIT 200
            ]) {
                if (isUserId(gm.UserOrGroupId)) result.add(gm.UserOrGroupId);
            }
        }
        return result;
    }

    private static Boolean isUserId(Object v) {
        if (v == null) return false;
        try {
            Id i = (Id) v;
            return i.getSObjectType() == User.SObjectType;
        } catch (Exception e) {
            return false;
        }
    }

    private static List<String> parseEmails(String raw) {
        List<String> out = new List<String>();
        if (String.isBlank(raw)) return out;
        for (String part : raw.split(',')) {
            String e = part.trim();
            if (String.isNotBlank(e) && e.contains('@')) out.add(e);
        }
        return out;
    }

    // ── Reload records with all merge-field paths populated ───────────

    private static List<SObject> reloadRecordsWithMergeFields(
        String objectApiName, List<SObject> records, List<Notification_Setting__c> rules
    ) {
        Set<String> fieldPaths = new Set<String>{ 'Id', 'OwnerId' };
        for (Notification_Setting__c rule : rules) {
            for (String tpl : new List<String>{ rule.Subject_Template__c, rule.Body_Template__c }) {
                if (String.isBlank(tpl)) continue;
                Matcher m = TOKEN.matcher(tpl);
                while (m.find()) {
                    String token = m.group(1);
                    if (String.isNotBlank(token)) fieldPaths.add(token);
                }
            }
            // Criteria and recipient fields must be queried too, or the filter
            // silently evaluates against null and the rule never fires.
            if (String.isNotBlank(rule.Criteria_Field__c))  fieldPaths.add(rule.Criteria_Field__c.trim());
            if (String.isNotBlank(rule.Recipient_Field__c)) fieldPaths.add(rule.Recipient_Field__c.trim());
        }

        // Recipient type "Submitter" needs one of these present.
        //
        // The describe is taken from the records themselves rather than by
        // looking objectApiName up in getGlobalDescribe(). Once the org gained a
        // namespace, the global describe became keyed by the prefixed name
        // (ftretailmake__Sales_Order__c), so the unqualified name callers pass
        // in returned null and the following getDescribe() threw a
        // NullPointerException, rolling back the whole order insert.
        Map<String, Schema.SObjectField> fmap = new Map<String, Schema.SObjectField>();
        if (!records.isEmpty() && records[0] != null) {
            fmap = records[0].getSObjectType().getDescribe().fields.getMap();
        }
        if (fmap.containsKey('submitted_by__c')) fieldPaths.add('Submitted_By__c');
        fieldPaths.add('CreatedById');

        Set<Id> ids = new Set<Id>();
        for (SObject rec : records) {
            Id rid = (Id) rec.get('Id');
            if (rid != null) ids.add(rid);
        }
        if (ids.isEmpty()) return records;

        String soql = 'SELECT ' + String.join(new List<String>(fieldPaths), ', ') +
                      ' FROM ' + objectApiName + ' WHERE Id IN :ids';
        try {
            return Database.query(soql);
        } catch (Exception e) {
            // A template can reference a field that has since been renamed or
            // deleted. Rather than losing every notification for the object,
            // retry with only the paths that still describe cleanly.
            System.debug(LoggingLevel.WARN,
                'NotificationDispatcher: reload SOQL failed (' + e.getMessage() +
                '). Retrying with validated fields only.');
            Set<String> safeFields = new Set<String>{ 'Id', 'OwnerId', 'CreatedById' };
            for (String path : fieldPaths) {
                String root = path.contains('.') ? path.substringBefore('.') : path;
                String lookupKey = path.contains('.')
                    ? root.replace('__r', '__c').toLowerCase()
                    : root.toLowerCase();
                if (fmap.containsKey(lookupKey)) safeFields.add(path);
            }
            try {
                return Database.query('SELECT ' + String.join(new List<String>(safeFields), ', ') +
                                      ' FROM ' + objectApiName + ' WHERE Id IN :ids');
            } catch (Exception e2) {
                System.debug(LoggingLevel.ERROR,
                    'NotificationDispatcher: fallback reload also failed - ' + e2.getMessage());
                return records;
            }
        }
    }

    // ── Merge field replacement ────────────────────────────────────────

    @TestVisible
    private static String mergeTemplate(String tpl, SObject rec) {
        if (String.isBlank(tpl)) return '';
        Matcher m = TOKEN.matcher(tpl);
        String result = tpl;
        Set<String> tokens = new Set<String>();
        while (m.find()) tokens.add(m.group(1));
        for (String token : tokens) {
            Object v = resolveTokenValue(rec, token);
            result = result.replace('{!' + token + '}', v == null ? '' : String.valueOf(v));
        }
        return result;
    }

    /** Resolves a field path, walking __r relationships where present. */
    private static Object resolveTokenValue(SObject rec, String token) {
        if (rec == null || String.isBlank(token)) return null;
        try {
            String path = token.trim();
            if (path.contains('.')) {
                List<String> parts = path.split('\\.');
                SObject current = rec;
                for (Integer i = 0; i < parts.size() - 1; i++) {
                    current = current.getSObject(parts[i]);
                    if (current == null) return null;
                }
                return current.get(parts[parts.size() - 1]);
            }
            return rec.get(path);
        } catch (Exception e) {
            return null;
        }
    }

    private static Object safeGet(SObject rec, String field) {
        if (rec == null || String.isBlank(field)) return null;
        try { return rec.get(field); } catch (Exception e) { return null; }
    }

    // ── Email send ─────────────────────────────────────────────────────

    private static List<Notification_Log__c> sendEmail(Notification_Setting__c rule, SObject rec,
                                                       Set<Id> recipients, List<String> extraEmails,
                                                       String subject, String body, String eventType) {
        List<Notification_Log__c> logs = new List<Notification_Log__c>();
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        List<Id> recipientList = new List<Id>(recipients);

        for (Id uid : recipientList) {
            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setTargetObjectId(uid);
            msg.setSaveAsActivity(false);
            msg.setSubject(String.isBlank(subject) ? 'FMCG Notification' : subject);
            msg.setPlainTextBody(String.isBlank(body) ? subject : body);
            emails.add(msg);
        }
        if (!extraEmails.isEmpty()) {
            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(extraEmails);
            msg.setSaveAsActivity(false);
            msg.setSubject(String.isBlank(subject) ? 'FMCG Notification' : subject);
            msg.setPlainTextBody(String.isBlank(body) ? subject : body);
            emails.add(msg);
        }
        if (emails.isEmpty()) return logs;

        try {
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(emails, false);
            for (Integer i = 0; i < results.size(); i++) {
                Boolean ok = results[i].isSuccess();
                // Indexes past the user list correspond to the Additional Emails message.
                Id who = (i < recipientList.size()) ? recipientList[i] : null;
                logs.add(buildLog(rule, rec, who, 'Email',
                    ok ? 'Sent' : 'Failed',
                    ok ? null : firstError(results[i]), subject, eventType));
            }
        } catch (Exception e) {
            for (Id uid : recipientList) {
                logs.add(buildLog(rule, rec, uid, 'Email', 'Failed', e.getMessage(), subject, eventType));
            }
        }
        return logs;
    }

    private static String firstError(Messaging.SendEmailResult r) {
        if (r.getErrors() == null || r.getErrors().isEmpty()) return 'Unknown error';
        return r.getErrors()[0].getMessage();
    }

    // ── In-App send ────────────────────────────────────────────────────

    private static List<Notification_Log__c> sendInApp(Notification_Setting__c rule, SObject rec,
                                                       Set<Id> recipients, String subject, String body,
                                                       Id notifTypeId, String eventType) {
        List<Notification_Log__c> logs = new List<Notification_Log__c>();
        Set<String> recipientIds = new Set<String>();
        for (Id uid : recipients) recipientIds.add(uid);
        try {
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(notifTypeId);
            n.setTitle(String.isBlank(subject) ? 'FMCG Notification' : subject.left(250));
            n.setBody(String.isBlank(body) ? subject : body.left(750));
            n.setTargetId(rec.Id);
            n.send(recipientIds);
            for (Id uid : recipients) {
                logs.add(buildLog(rule, rec, uid, 'In-App', 'Sent', null, subject, eventType));
            }
        } catch (Exception e) {
            for (Id uid : recipients) {
                logs.add(buildLog(rule, rec, uid, 'In-App', 'Failed', e.getMessage(), subject, eventType));
            }
        }
        return logs;
    }

    // ── SMS / WhatsApp via the Integrations window ─────────────────────

    /**
     * @description Delivers through a messaging gateway configured in the
     *              Integrations window. When the integration is not enabled or
     *              has no credential, the attempt is logged as Skipped with the
     *              reason — never silently dropped, and never faked as Sent.
     */
    private static List<Notification_Log__c> sendGatewayChannel(
        Notification_Setting__c rule, SObject rec, Set<Id> recipients,
        String subject, String body, String eventType,
        String channel, String integrationKey
    ) {
        List<Notification_Log__c> logs = new List<Notification_Log__c>();

        IntegrationTypes.Context ctx;
        try {
            ctx = IntegrationRuntime.contextFor(integrationKey);
        } catch (Exception e) {
            ctx = null;
        }

        if (ctx == null || !ctx.enabled) {
            for (Id uid : recipients) {
                logs.add(buildLog(rule, rec, uid, channel, 'Skipped',
                    channel + ' integration is not enabled in the Integrations window.',
                    subject, eventType));
            }
            return logs;
        }
        if (ctx.requiresCredential && !ctx.credentialSet) {
            for (Id uid : recipients) {
                logs.add(buildLog(rule, rec, uid, channel, 'Skipped',
                    channel + ' integration has no stored credential.', subject, eventType));
            }
            return logs;
        }

        // Resolve phone numbers. No number means no send — log it against the
        // user so the gap is visible rather than mysterious.
        Map<Id, String> phoneByUser = new Map<Id, String>();
        for (User u : [SELECT Id, MobilePhone, Phone FROM User WHERE Id IN :recipients]) {
            String p = String.isNotBlank(u.MobilePhone) ? u.MobilePhone : u.Phone;
            if (String.isNotBlank(p)) phoneByUser.put(u.Id, p);
        }

        List<String> numbers = new List<String>();
        for (Id uid : recipients) {
            if (phoneByUser.containsKey(uid)) {
                numbers.add(phoneByUser.get(uid));
            } else {
                logs.add(buildLog(rule, rec, uid, channel, 'Skipped',
                    'No mobile number on the user record.', subject, eventType));
            }
        }
        if (numbers.isEmpty()) return logs;

        String text = String.isBlank(body) ? subject : body;

        // Callouts cannot run in the same transaction as pending DML, and this
        // is nearly always reached from a trigger — so hand off to the async
        // path, which writes its own log rows with the real outcome.
        if (System.isQueueable() || System.isFuture() || System.isBatch()) {
            // Already async and nested enqueues are capped — send inline.
            logs.addAll(deliver(integrationKey, channel, numbers, text, rule.Id,
                String.valueOf(rec.get('Id')), subject, eventType));
        } else {
            System.enqueueJob(new NotificationDispatcher(
                integrationKey, channel, numbers, text, rule.Id,
                String.valueOf(rec.get('Id')), subject, eventType));
        }
        return logs;
    }

    // ── Queueable payload (async gateway delivery) ─────────────────────

    private String qIntegrationKey;
    private String qChannel;
    private List<String> qNumbers;
    private String qText;
    private Id qRuleId;
    private String qRecordId;
    private String qSubject;
    private String qEventType;

    public NotificationDispatcher() {}

    private NotificationDispatcher(String integrationKey, String channel, List<String> numbers,
                                   String text, Id ruleId, String recordId,
                                   String subject, String eventType) {
        this.qIntegrationKey = integrationKey;
        this.qChannel   = channel;
        this.qNumbers   = numbers;
        this.qText      = text;
        this.qRuleId    = ruleId;
        this.qRecordId  = recordId;
        this.qSubject   = subject;
        this.qEventType = eventType;
    }

    public void execute(QueueableContext context) {
        List<Notification_Log__c> logs = deliver(
            qIntegrationKey, qChannel, qNumbers, qText, qRuleId, qRecordId, qSubject, qEventType);
        if (!logs.isEmpty()) {
            try {
                insert logs;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Gateway log insert failed: ' + e.getMessage());
            }
        }
    }

    /**
     * @description Generic REST send against the configured gateway. The
     *              endpoint path and payload field names come from the
     *              integration's settings, so a new provider is configuration
     *              rather than code:
     *                send_path  (default '/send')
     *                to_field   (default 'to')
     *                body_field (default 'message')
     *              Providers with a materially different contract get a
     *              dedicated connector class instead — this covers the common
     *              "POST JSON with a recipient and a message" shape.
     */
    private static List<Notification_Log__c> deliver(
        String integrationKey, String channel, List<String> numbers, String text,
        Id ruleId, String recordId, String subject, String eventType
    ) {
        List<Notification_Log__c> logs = new List<Notification_Log__c>();

        IntegrationTypes.Context ctx;
        try {
            ctx = IntegrationRuntime.contextFor(integrationKey);
        } catch (Exception e) {
            ctx = null;
        }
        if (ctx == null || !ctx.enabled) {
            logs.add(buildLogRaw(ruleId, recordId, null, channel, 'Skipped',
                'Integration became unavailable before send.', subject, eventType));
            return logs;
        }

        String sendPath  = settingOr(ctx, 'send_path', '/send');
        String toField   = settingOr(ctx, 'to_field', 'to');
        String bodyField = settingOr(ctx, 'body_field', 'message');

        String endpoint;
        if (String.isNotBlank(ctx.namedCredential)) {
            endpoint = 'callout:' + ctx.namedCredential + sendPath;
        } else if (String.isNotBlank(ctx.baseUrl)) {
            endpoint = ctx.baseUrl.removeEnd('/') + sendPath;
        } else {
            logs.add(buildLogRaw(ruleId, recordId, null, channel, 'Skipped',
                'No base URL or named credential resolved for ' + integrationKey + '.',
                subject, eventType));
            return logs;
        }

        for (String msisdn : numbers) {
            try {
                Map<String, Object> payload = new Map<String, Object>{
                    toField   => msisdn,
                    bodyField => text
                };
                HttpRequest req = new HttpRequest();
                req.setEndpoint(endpoint);
                req.setMethod('POST');
                req.setHeader('Content-Type', 'application/json');
                req.setTimeout(30000);
                req.setBody(JSON.serialize(payload));

                HttpResponse res = new Http().send(req);
                Boolean ok = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
                logs.add(buildLogRaw(ruleId, recordId, null, channel,
                    ok ? 'Sent' : 'Failed',
                    ok ? null : ('HTTP ' + res.getStatusCode() + ': ' + res.getStatus()),
                    subject, eventType));
            } catch (Exception e) {
                logs.add(buildLogRaw(ruleId, recordId, null, channel, 'Failed',
                    e.getMessage(), subject, eventType));
            }
        }
        return logs;
    }

    private static String settingOr(IntegrationTypes.Context ctx, String key, String fallback) {
        if (ctx.settings == null) return fallback;
        Object v = ctx.settings.get(key);
        return (v == null || String.isBlank(String.valueOf(v))) ? fallback : String.valueOf(v);
    }

    // ── Log helpers ────────────────────────────────────────────────────

    private static Notification_Log__c buildLog(Notification_Setting__c rule, SObject rec, Id recipientId,
                                                String channel, String status, String error,
                                                String subject, String eventType) {
        return buildLogRaw(rule.Id, String.valueOf(rec.get('Id')), recipientId,
                           channel, status, error, subject, eventType);
    }

    private static Notification_Log__c buildLogRaw(Id ruleId, String recordId, Id recipientId,
                                                   String channel, String status, String error,
                                                   String subject, String eventType) {
        return new Notification_Log__c(
            Notification_Setting__c = ruleId,
            Source_Record_Id__c = recordId,
            Recipient_User__c = recipientId,
            Channel__c = channel,
            Status__c = status,
            Error_Message__c = error == null ? null : error.left(255),
            Subject__c = subject == null ? null : subject.left(255),
            Event_Type__c = eventType == null ? null : eventType.left(100),
            Sent_At__c = Datetime.now()
        );
    }

    // ── Custom Notification Type lookup ────────────────────────────────

    private static Id cachedNotifTypeId;
    private static Boolean notifTypeLoaded = false;
    private static Id getCustomNotificationTypeId() {
        if (notifTypeLoaded) return cachedNotifTypeId;
        notifTypeLoaded = true;
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = :NOTIF_TYPE_DEV_NAME
            LIMIT 1
        ];
        cachedNotifTypeId = types.isEmpty() ? null : types[0].Id;
        return cachedNotifTypeId;
    }
}