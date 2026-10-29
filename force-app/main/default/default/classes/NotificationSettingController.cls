/**
 * @description Backs the Notification Settings admin tab. CRUD plus the
 * describe metadata that lets an admin configure notifications for ANY object
 * without a developer.
 *
 * Event_Object__c is plain Text rather than a restricted picklist, for the same
 * reason Approval_Rule__c.Object_Process__c is: a picklist meant onboarding an
 * object required a deploy. The selectable object list, field lists and
 * picklist values are all produced from the live schema, and are shared with
 * the Approval Rules window via ApprovalRuleController so the two admin
 * surfaces cannot drift apart.
 *
 * The engine that reads these rows and actually delivers is
 * NotificationDispatcher.
 */
public with sharing class NotificationSettingController {

    private static final String ALL_FIELDS =
        'Id, Name, Event_Object__c, Event_Type__c, ' +
        'Recipient_Type__c, Recipient_User__c, Recipient_User__r.Name, ' +
        'Recipient_Reference__c, Recipient_Field__c, Additional_Emails__c, ' +
        'Criteria_Field__c, Criteria_Operator__c, Criteria_Value__c, ' +
        'Channel_Email__c, Channel_InApp__c, Channel_WhatsApp__c, Channel_SMS__c, ' +
        'Subject_Template__c, Body_Template__c, ' +
        'Is_Active__c, Description__c, LastModifiedDate';

    @AuraEnabled(cacheable=true)
    public static List<Notification_Setting__c> getAllSettings() {
        return Database.query(
            'SELECT ' + ALL_FIELDS + ' FROM Notification_Setting__c ' +
            'ORDER BY Event_Object__c, Event_Type__c, CreatedDate DESC'
        );
    }

    @AuraEnabled
    public static Notification_Setting__c saveSetting(Notification_Setting__c setting) {
        if (setting == null) {
            throw new AuraHandledException('Setting is required.');
        }

        // Event_Object__c is free text now, so a typo would otherwise create a
        // setting that silently never fires. Fail loudly at save time instead.
        Schema.SObjectType targetType;
        if (String.isNotBlank(setting.Event_Object__c)) {
            targetType = Schema.getGlobalDescribe().get(setting.Event_Object__c);
            if (targetType == null) {
                throw new AuraHandledException(
                    '"' + setting.Event_Object__c + '" is not an object in this org.');
            }
        }

        // Same reasoning for the field-name slots: a bad API name here produces
        // a rule that either never matches or never resolves a recipient, and
        // that is painful to diagnose from the outside.
        if (targetType != null) {
            Map<String, Schema.SObjectField> fmap = targetType.getDescribe().fields.getMap();
            validateFieldName(fmap, setting.Criteria_Field__c, 'Criteria Field', setting.Event_Object__c);
            validateFieldName(fmap, setting.Recipient_Field__c, 'Recipient Field', setting.Event_Object__c);

            if (setting.Recipient_Type__c == 'Field on Record'
                && String.isBlank(setting.Recipient_Field__c)) {
                throw new AuraHandledException(
                    'Recipient Type "Field on Record" needs a Recipient Field.');
            }
        }

        upsert setting;
        return Database.query(
            'SELECT ' + ALL_FIELDS + ' FROM Notification_Setting__c WHERE Id = :setting.Id'
        );
    }

    /**
     * @description Rejects a field name that does not exist on the target
     *              object. Relationship paths are accepted on their root
     *              segment only — validating the full path would mean walking
     *              every hop, and the dispatcher already degrades safely on a
     *              broken tail.
     */
    private static void validateFieldName(Map<String, Schema.SObjectField> fmap,
                                          String fieldName, String label, String objectName) {
        if (String.isBlank(fieldName)) return;
        String root = fieldName.contains('.') ? fieldName.substringBefore('.') : fieldName;
        String key = fieldName.contains('.')
            ? root.replace('__r', '__c').toLowerCase()
            : root.toLowerCase();
        if (!fmap.containsKey(key)) {
            throw new AuraHandledException(
                label + ' "' + fieldName + '" does not exist on ' + objectName + '.');
        }
    }

    @AuraEnabled
    public static void deleteSetting(Id settingId) {
        if (settingId == null) return;
        delete new Notification_Setting__c(Id = settingId);
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, List<Map<String, String>>> getPicklistOptions() {
        Map<String, List<Map<String, String>>> result = new Map<String, List<Map<String, String>>>();
        // Event_Object__c is Text, not a picklist — options come from the live schema.
        result.put('Event_Object__c', ApprovalRuleController.getConfigurableObjects());
        result.put('Event_Type__c', describePicklist('Event_Type__c'));
        result.put('Recipient_Type__c', describePicklist('Recipient_Type__c'));
        result.put('Criteria_Operator__c', describePicklist('Criteria_Operator__c'));
        return result;
    }

    /**
     * @description Fields on the selected event object, for the Criteria Field
     *              and Recipient Field pickers. Delegates to the shared
     *              describe provider so both admin windows offer identical
     *              field lists.
     *
     *              fieldTypeFilter 'reference' narrows to lookup fields, which
     *              is what the Recipient Field picker wants.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectFields(String objectName, String fieldTypeFilter) {
        if (fieldTypeFilter == 'reference') {
            List<Map<String, String>> refs = new List<Map<String, String>>();
            if (String.isBlank(objectName)) return refs;
            Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName);
            if (t == null) return refs;

            List<ApprovalRuleController.FieldOption> opts =
                new List<ApprovalRuleController.FieldOption>();
            for (Schema.SObjectField sf : t.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult f = sf.getDescribe();
                if (f.getType() != Schema.DisplayType.Reference) continue;
                if (!f.isAccessible()) continue;
                // Only lookups that can actually hold a User are useful as a
                // notification recipient.
                Boolean pointsAtUser = false;
                for (Schema.SObjectType ref : f.getReferenceTo()) {
                    if (ref == User.SObjectType) { pointsAtUser = true; break; }
                }
                if (!pointsAtUser) continue;
                opts.add(new ApprovalRuleController.FieldOption(
                    f.getLabel(), f.getName(), String.valueOf(f.getType())));
            }
            opts.sort();
            for (ApprovalRuleController.FieldOption o : opts) {
                refs.add(new Map<String, String>{
                    'label' => o.label, 'value' => o.value, 'type' => o.fieldType
                });
            }
            return refs;
        }
        return ApprovalRuleController.getObjectFields(objectName, fieldTypeFilter);
    }

    /** Picklist values for a field on the selected event object. */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getFieldPicklistValues(String objectName, String fieldName) {
        return ApprovalRuleController.getPicklistValues(objectName, fieldName);
    }

    private static List<Map<String, String>> describePicklist(String fieldName) {
        List<Map<String, String>> values = new List<Map<String, String>>();
        Schema.DescribeFieldResult f = Notification_Setting__c.SObjectType
            .getDescribe().fields.getMap().get(fieldName).getDescribe();
        for (Schema.PicklistEntry e : f.getPicklistValues()) {
            if (e.isActive()) {
                values.add(new Map<String, String>{
                    'label' => e.getLabel(),
                    'value' => e.getValue()
                });
            }
        }
        return values;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchUsers(String searchTerm) {
        List<User> users;
        if (String.isBlank(searchTerm)) {
            users = [
                SELECT Id, Name, Email, Username
                FROM User
                WHERE IsActive = true
                ORDER BY Name
                LIMIT 20
            ];
        } else {
            String pattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            users = [
                SELECT Id, Name, Email, Username
                FROM User
                WHERE IsActive = true
                  AND (Name LIKE :pattern OR Email LIKE :pattern OR Username LIKE :pattern)
                ORDER BY Name
                LIMIT 20
            ];
        }
        List<Map<String, String>> result = new List<Map<String, String>>();
        for (User u : users) {
            result.add(new Map<String, String>{
                'value' => u.Id,
                'label' => u.Name,
                'subtitle' => u.Email
            });
        }
        return result;
    }

    /**
     * @description Fires a notification rule immediately using the most recent
     * record of the rule's event object. Lets admins verify a rule end-to-end
     * from the UI without leaving the tab. Returns a short status string for
     * the toast message.
     */
    @AuraEnabled
    public static String testFireRule(Id settingId) {
        if (settingId == null) {
            throw new AuraHandledException('Setting Id is required.');
        }
        Notification_Setting__c rule = [
            SELECT Id, Event_Object__c, Event_Type__c, Is_Active__c
            FROM Notification_Setting__c
            WHERE Id = :settingId
            LIMIT 1
        ];
        if (!rule.Is_Active__c) {
            throw new AuraHandledException('Rule is inactive — toggle it on first.');
        }
        if (String.isBlank(rule.Event_Object__c)) {
            throw new AuraHandledException('Rule has no Event Object configured.');
        }

        // Pull the most recent record of the rule's event object so we have
        // something realistic to merge into the template. Include OwnerId so
        // the dispatcher can resolve Owner/Owner's Manager recipients.
        String soql = 'SELECT Id, OwnerId FROM ' + String.escapeSingleQuotes(rule.Event_Object__c)
            + ' ORDER BY CreatedDate DESC LIMIT 1';
        List<SObject> records;
        try {
            records = Database.query(soql);
        } catch (Exception e) {
            throw new AuraHandledException('Cannot query ' + rule.Event_Object__c + ': ' + e.getMessage());
        }
        if (records.isEmpty()) {
            throw new AuraHandledException('No records exist on ' + rule.Event_Object__c + ' yet. Create one first, then test.');
        }

        Integer logsBefore = [SELECT COUNT() FROM Notification_Log__c];
        NotificationDispatcher.dispatch(rule.Event_Object__c, rule.Event_Type__c, records);
        Integer logsAfter = [SELECT COUNT() FROM Notification_Log__c];
        Integer created = logsAfter - logsBefore;

        if (created == 0) {
            return 'Rule fired but nothing was dispatched. Check the record filter '
                 + '(Criteria) and the recipient setup — e.g. the Owner has no Manager.';
        }
        return 'Test sent — ' + created + ' notification(s) dispatched. See Notification Log for details.';
    }

    /**
     * @description Recent delivery attempts, newest first. This is the answer
     *              to "why didn't my alert arrive?" — skips and failures are
     *              logged with their reason, not just successes.
     */
    @AuraEnabled(cacheable=true)
    public static List<Notification_Log__c> getRecentLogs(Integer rowLimit) {
        Integer lim = (rowLimit == null || rowLimit <= 0 || rowLimit > 200) ? 50 : rowLimit;
        return [
            SELECT Id, Name, Channel__c, Status__c, Event_Type__c, Subject__c,
                   Error_Message__c, Sent_At__c, Source_Record_Id__c,
                   Recipient_User__r.Name, Notification_Setting__r.Name
            FROM Notification_Log__c
            ORDER BY Sent_At__c DESC NULLS LAST
            LIMIT :lim
        ];
    }
}