/**
 * @description Backs the Approval Rules admin tab. CRUD plus the describe
 * metadata that lets an admin build an approval matrix for ANY object without
 * a developer.
 *
 * Object_Process__c is deliberately a plain Text field rather than a picklist:
 * a restricted picklist meant onboarding a new object required a metadata
 * deploy, which is the opposite of a configurable product. The object list in
 * the UI is therefore produced at runtime from the org's own schema by
 * getConfigurableObjects(), so a newly created object is immediately routable.
 *
 * This class doubles as the shared describe provider for the Notification
 * Settings window — both admin surfaces need "list the objects", "list the
 * fields on an object" and "list a picklist's values", and duplicating that
 * logic is how the two windows would drift apart.
 *
 * The engine that reads these rules at runtime is ApprovalRouter.
 */
public with sharing class ApprovalRuleController {

    /**
     * Standard objects worth offering alongside the custom ones. Everything
     * else standard is noise in an FMCG context and makes the picker unusable.
     */
    private static final Set<String> STANDARD_ALLOWED = new Set<String>{
        'Account', 'Contact', 'Lead', 'Opportunity', 'Case', 'Task', 'Event', 'User'
    };

    /** Suffixes that identify system-generated sibling objects, never routable. */
    private static final List<String> SYSTEM_SUFFIXES = new List<String>{
        '__History', '__Share', '__Feed', '__ChangeEvent', '__Tag', '__e', '__mdt', '__b'
    };

    @AuraEnabled(cacheable=true)
    public static List<Approval_Rule__c> getAllRules() {
        return [
            SELECT Id, Name,
                   Object_Process__c, Approval_Level__c,
                   Approver_Type__c, User__c, User__r.Name,
                   Approver_Role_Queue__c,
                   Auto_Approve__c, Approval_Mode__c, Criteria_Logic__c,
                   Escalation_Hours__c, Escalation_Approver__c, Escalation_Approver__r.Name,
                   Effective_From__c, Effective_To__c,
                   Condition_Field__c, Min_Value__c, Max_Value__c,
                   Status_Field_API_Name__c,
                   Status_Value_On_Submit__c,
                   Status_Value_On_Approve__c,
                   Status_Value_On_Reject__c,
                   Is_Active__c, Description__c,
                   LastModifiedDate,
                   (SELECT Id, Field_API_Name__c, Operator__c, Value__c, Sequence__c
                    FROM Conditions__r ORDER BY Sequence__c NULLS LAST)
            FROM Approval_Rule__c
            ORDER BY Object_Process__c, Approval_Level__c, CreatedDate DESC
        ];
    }

    /**
     * @description Every object an approval or notification rule can target,
     *              derived from the org schema at runtime. This is what makes
     *              onboarding a new object configuration rather than a deploy.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getConfigurableObjects() {
        List<FieldOption> opts = new List<FieldOption>();
        for (Schema.SObjectType t : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult d;
            try { d = t.getDescribe(); } catch (Exception e) { continue; }

            String api = d.getName();
            if (!d.isQueryable() || !d.isUpdateable() || d.isCustomSetting()) continue;
            if (!d.isCustom() && !STANDARD_ALLOWED.contains(api)) continue;

            Boolean isSystemSibling = false;
            for (String suffix : SYSTEM_SUFFIXES) {
                if (api.endsWith(suffix)) { isSystemSibling = true; break; }
            }
            if (isSystemSibling) continue;

            opts.add(new FieldOption(d.getLabel() + ' (' + api + ')', api, 'SObject'));
        }
        opts.sort();

        List<Map<String, String>> result = new List<Map<String, String>>();
        for (FieldOption o : opts) {
            result.add(new Map<String, String>{ 'label' => o.label, 'value' => o.value });
        }
        return result;
    }

    /**
     * @description Returns the configured matrix for one object as an ordered
     *              grid: one entry per level, each carrying the rules that sit
     *              at that level. Lets the UI render the matrix as a matrix
     *              rather than as a flat list of records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getMatrix(String objectName) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (String.isBlank(objectName)) return out;

        Map<Decimal, List<Map<String, Object>>> byLevel = new Map<Decimal, List<Map<String, Object>>>();
        for (Approval_Rule__c r : [
            SELECT Id, Name, Approval_Level__c, Approver_Type__c, Approver_Role_Queue__c,
                   User__r.Name, Auto_Approve__c, Approval_Mode__c, Is_Active__c,
                   Condition_Field__c, Min_Value__c, Max_Value__c,
                   Escalation_Hours__c, Effective_From__c, Effective_To__c,
                   (SELECT Field_API_Name__c, Operator__c, Value__c
                    FROM Conditions__r ORDER BY Sequence__c NULLS LAST)
            FROM Approval_Rule__c
            WHERE Object_Process__c = :objectName
            ORDER BY Approval_Level__c ASC NULLS FIRST
        ]) {
            Decimal lvl = (r.Approval_Level__c == null) ? 1 : r.Approval_Level__c;

            List<String> criteria = new List<String>();
            if (r.Conditions__r != null) {
                for (Approval_Rule_Condition__c c : r.Conditions__r) {
                    criteria.add(c.Field_API_Name__c + ' ' + c.Operator__c + ' ' + c.Value__c);
                }
            }
            if (criteria.isEmpty() && String.isNotBlank(r.Condition_Field__c)) {
                String band = r.Condition_Field__c + ' between '
                    + (r.Min_Value__c == null ? '—' : String.valueOf(r.Min_Value__c)) + ' and '
                    + (r.Max_Value__c == null ? '—' : String.valueOf(r.Max_Value__c));
                criteria.add(band);
            }

            String approver = r.Approver_Type__c;
            if (r.Approver_Type__c == 'User' && r.User__r != null) {
                approver = r.User__r.Name;
            } else if (String.isNotBlank(r.Approver_Role_Queue__c)) {
                approver = r.Approver_Type__c + ': ' + r.Approver_Role_Queue__c;
            }

            if (!byLevel.containsKey(lvl)) byLevel.put(lvl, new List<Map<String, Object>>());
            byLevel.get(lvl).add(new Map<String, Object>{
                'ruleId'          => r.Id,
                'ruleName'        => r.Name,
                'approver'        => approver,
                'autoApprove'     => (r.Auto_Approve__c == true),
                'mode'            => r.Approval_Mode__c,
                'isActive'        => (r.Is_Active__c == true),
                'criteria'        => String.join(criteria, ' AND '),
                'escalationHours' => r.Escalation_Hours__c,
                'effectiveFrom'   => r.Effective_From__c,
                'effectiveTo'     => r.Effective_To__c
            });
        }

        List<Decimal> levels = new List<Decimal>(byLevel.keySet());
        levels.sort();
        for (Decimal lvl : levels) {
            out.add(new Map<String, Object>{
                'level' => lvl,
                'rules' => byLevel.get(lvl)
            });
        }
        return out;
    }

    @AuraEnabled
    public static Approval_Rule__c saveRule(String ruleJson, String conditionsJson) {
        if (String.isBlank(ruleJson)) {
            throw new AuraHandledException('Rule is required.');
        }
        // Received as JSON (not a typed SObject) so the LWC's unqualified field keys
        // survive the hop — in the managed-package namespace an SObject param silently
        // drops any value whose key lacks the ftretailmake__ prefix. Build the records
        // server-side with the real field API names instead.
        Approval_Rule__c rule = (Approval_Rule__c) buildSObject(
            Approval_Rule__c.SObjectType,
            (Map<String, Object>) JSON.deserializeUntyped(ruleJson));
        List<Approval_Rule_Condition__c> conditions = new List<Approval_Rule_Condition__c>();
        if (String.isNotBlank(conditionsJson)) {
            for (Object o : (List<Object>) JSON.deserializeUntyped(conditionsJson)) {
                conditions.add((Approval_Rule_Condition__c) buildSObject(
                    Approval_Rule_Condition__c.SObjectType, (Map<String, Object>) o));
            }
        }
        return saveRuleInternal(rule, conditions);
    }

    public static Approval_Rule__c saveRuleInternal(Approval_Rule__c rule, List<Approval_Rule_Condition__c> conditions) {
        if (rule == null) {
            throw new AuraHandledException('Rule is required.');
        }

        // Object_Process__c is free text now, so a typo would otherwise create
        // a rule that silently never fires. Fail loudly at save time instead.
        if (String.isNotBlank(rule.Object_Process__c)
            && resolveType(rule.Object_Process__c) == null) {
            throw new AuraHandledException(
                '"' + rule.Object_Process__c + '" is not an object in this org.');
        }

        // Validate conditions before any DML so a bad value doesn't leave the
        // rule half-saved. For picklist fields, the Value must match an active
        // picklist entry — anything else would silently never match at runtime.
        if (conditions != null && !conditions.isEmpty() && String.isNotBlank(rule.Object_Process__c)) {
            validateConditions(rule.Object_Process__c, conditions);
        }

        upsert rule;

        // Replace the rule's conditions: delete existing then insert fresh.
        // Simpler and safer than diffing — keeps the LWC payload trivial.
        if (rule.Id != null) {
            List<Approval_Rule_Condition__c> existing = [
                SELECT Id FROM Approval_Rule_Condition__c WHERE Approval_Rule__c = :rule.Id
            ];
            if (!existing.isEmpty()) delete existing;
        }

        if (conditions != null && !conditions.isEmpty()) {
            List<Approval_Rule_Condition__c> toInsert = new List<Approval_Rule_Condition__c>();
            Integer seq = 0;
            for (Approval_Rule_Condition__c c : conditions) {
                // Skip blank rows — the editor sends an empty condition for an
                // "Always" rule, which would otherwise fail REQUIRED_FIELD_MISSING.
                if (String.isBlank(c.Field_API_Name__c) || String.isBlank(c.Operator__c)) continue;
                c.Approval_Rule__c = rule.Id;
                c.Sequence__c = seq;
                seq++;
                toInsert.add(c);
            }
            if (!toInsert.isEmpty()) insert toInsert;
        }

        return [
            SELECT Id, Name,
                   Object_Process__c, Approval_Level__c,
                   Approver_Type__c, User__c, User__r.Name,
                   Approver_Role_Queue__c,
                   Auto_Approve__c, Approval_Mode__c, Criteria_Logic__c,
                   Escalation_Hours__c, Escalation_Approver__c, Escalation_Approver__r.Name,
                   Effective_From__c, Effective_To__c,
                   Condition_Field__c, Min_Value__c, Max_Value__c,
                   Status_Field_API_Name__c,
                   Status_Value_On_Submit__c,
                   Status_Value_On_Approve__c,
                   Status_Value_On_Reject__c,
                   Is_Active__c, Description__c,
                   LastModifiedDate,
                   (SELECT Id, Field_API_Name__c, Operator__c, Value__c, Sequence__c
                    FROM Conditions__r ORDER BY Sequence__c NULLS LAST)
            FROM Approval_Rule__c
            WHERE Id = :rule.Id
        ];
    }

    @AuraEnabled
    public static void deleteRule(Id ruleId) {
        if (ruleId == null) return;
        delete new Approval_Rule__c(Id = ruleId);
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, List<Map<String, String>>> getPicklistOptions() {
        Map<String, List<Map<String, String>>> result = new Map<String, List<Map<String, String>>>();
        // Object_Process__c is Text, not a picklist — its options come from the
        // live schema so any object is selectable without a deploy.
        result.put('Object_Process__c', getConfigurableObjects());
        result.put('Approver_Type__c', describePicklist('Approver_Type__c'));
        result.put('Approval_Mode__c', describePicklist('Approval_Mode__c'));
        result.put('Criteria_Logic__c', describePicklist('Criteria_Logic__c'));
        return result;
    }

    /**
     * @description Save-time guard: for each condition row referencing a
     *              Picklist or MultiPicklist field on the rule's object,
     *              verify that the typed Value matches an active picklist
     *              entry. Throws a single AuraHandledException listing all
     *              the bad rows so the admin can fix them in one pass.
     *              Non-picklist fields (text, number, date, lookup, etc.)
     *              skip validation — any value is fair game for those.
     */
    /**
     * @description Namespace-tolerant object resolver. Once the app runs inside
     *              the ftretailmake managed-package namespace, getGlobalDescribe()
     *              keys and getName() carry the prefix (ftretailmake__Sales_Order__c),
     *              but rule data may store the unqualified name (Sales_Order__c) —
     *              or vice-versa. Match either way so saving/validation never
     *              wrongly reports "not an object in this org".
     */
    private static Schema.SObjectType resolveType(String name) {
        if (String.isBlank(name)) return null;
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Schema.SObjectType t = gd.get(name);            // exact (standard, or already-correct)
        if (t != null) return t;
        String bare = unqualify(name);
        for (String key : gd.keySet()) {
            if (unqualify(key).equalsIgnoreCase(bare)) return gd.get(key);
        }
        return null;
    }

    /** Namespace-tolerant field resolver on an object's field map. */
    private static Schema.SObjectField resolveField(Map<String, Schema.SObjectField> fieldMap, String name) {
        if (String.isBlank(name) || fieldMap == null) return null;
        Schema.SObjectField f = fieldMap.get(name);     // getMap() is case-insensitive
        if (f != null) return f;
        String bare = unqualify(name);
        for (String key : fieldMap.keySet()) {
            if (unqualify(key).equalsIgnoreCase(bare)) return fieldMap.get(key);
        }
        return null;
    }

    /** Strip a leading '<namespace>__' from a custom API name (ns__X__c -> X__c);
     *  standard and already-unqualified names are returned unchanged. */
    private static String unqualify(String api) {
        if (String.isBlank(api)) return api;
        if (api.endsWithIgnoreCase('__c') && api.split('__').size() >= 3) {
            return api.substringAfter('__');
        }
        return api;
    }

    /**
     * @description Build an SObject from a JSON-derived map whose keys may be
     *              unqualified (Object_Process__c) — each value is re-applied under
     *              the object's REAL (namespaced) field API name with the right
     *              type. This is what lets the LWC stay namespace-agnostic.
     */
    private static SObject buildSObject(Schema.SObjectType t, Map<String, Object> m) {
        SObject rec = t.newSObject();
        if (m == null) return rec;
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();
        for (String key : m.keySet()) {
            if (key == 'sobjectType' || key == 'attributes' || m.get(key) == null) continue;
            Schema.SObjectField sf = resolveField(fmap, key);
            if (sf == null) continue; // unknown field or relationship (__r) — skip
            Schema.DescribeFieldResult dfr = sf.getDescribe();
            try { rec.put(dfr.getName(), coerceValue(dfr.getType(), m.get(key))); }
            catch (Exception e) { /* skip an un-coercible value rather than fail the save */ }
        }
        return rec;
    }

    /** Coerce a JSON-deserialized value to the type expected by an SObject field. */
    private static Object coerceValue(Schema.DisplayType t, Object val) {
        if (val == null) return null;
        String s = String.valueOf(val);
        if (String.isBlank(s)) return null;
        if (t == Schema.DisplayType.Boolean) return (val instanceof Boolean) ? val : Boolean.valueOf(s);
        if (t == Schema.DisplayType.Date) return Date.valueOf(s.substring(0, 10));
        if (t == Schema.DisplayType.DateTime) return Datetime.valueOf(s.replace('T', ' ').replace('Z', ''));
        if (t == Schema.DisplayType.Double || t == Schema.DisplayType.Currency
            || t == Schema.DisplayType.Percent) return Decimal.valueOf(s);
        if (t == Schema.DisplayType.Integer) return Integer.valueOf(s);
        if (t == Schema.DisplayType.Reference || t == Schema.DisplayType.Id) return (Id) s;
        return s;
    }

    private static void validateConditions(String objectApiName, List<Approval_Rule_Condition__c> conditions) {
        Schema.SObjectType sobjType = resolveType(objectApiName);
        if (sobjType == null) return;
        Map<String, Schema.SObjectField> fieldMap = sobjType.getDescribe().fields.getMap();

        // Cache picklist values per field so we don't re-describe inside the loop
        Map<String, Set<String>> picklistValueCache = new Map<String, Set<String>>();
        List<String> errors = new List<String>();

        for (Approval_Rule_Condition__c c : conditions) {
            if (String.isBlank(c.Field_API_Name__c)) continue;
            if (String.isBlank(c.Value__c)) continue; // empty value is treated as "no filter"

            Schema.SObjectField field = resolveField(fieldMap, c.Field_API_Name__c);
            if (field == null) {
                errors.add('Field "' + c.Field_API_Name__c + '" does not exist on ' + objectApiName + '.');
                continue;
            }
            Schema.DescribeFieldResult f = field.getDescribe();
            Schema.DisplayType t = f.getType();
            if (t != Schema.DisplayType.Picklist && t != Schema.DisplayType.MultiPicklist) continue;

            Set<String> validValues = picklistValueCache.get(c.Field_API_Name__c);
            if (validValues == null) {
                validValues = new Set<String>();
                for (Schema.PicklistEntry e : f.getPicklistValues()) {
                    if (e.isActive()) validValues.add(e.getValue());
                }
                picklistValueCache.put(c.Field_API_Name__c, validValues);
            }

            if (!validValues.contains(c.Value__c)) {
                List<String> sorted = new List<String>(validValues);
                sorted.sort();
                errors.add('"' + c.Value__c + '" is not a valid value for ' + f.getLabel() +
                    ' (' + c.Field_API_Name__c + '). Valid values: ' + String.join(sorted, ', '));
            }
        }

        if (!errors.isEmpty()) {
            throw new AuraHandledException(String.join(errors, '\n'));
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getOperatorOptions() {
        List<Map<String, String>> values = new List<Map<String, String>>();
        // Namespace-safe: get('Operator__c') returns null when the field map is
        // keyed with the ftretailmake__ prefix — deref would NPE.
        Schema.SObjectField opField = resolveField(
            Approval_Rule_Condition__c.SObjectType.getDescribe().fields.getMap(), 'Operator__c');
        if (opField == null) return values;
        Schema.DescribeFieldResult f = opField.getDescribe();
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

    private static List<Map<String, String>> describePicklist(String fieldName) {
        List<Map<String, String>> values = new List<Map<String, String>>();
        Schema.SObjectField fld = resolveField(
            Approval_Rule__c.SObjectType.getDescribe().fields.getMap(), fieldName);
        if (fld == null) return values;
        Schema.DescribeFieldResult f = fld.getDescribe();
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

    /**
     * @description Returns selectable fields from the given object for use in
     * the rule editor's Condition Field / Status Field dropdowns. The
     * fieldTypeFilter narrows the result so admins only see fields that make
     * sense for the slot they're filling:
     *   'numeric' → Number / Currency / Percent / Integer / Double (Min/Max
     *               comparison only makes sense against numeric values)
     *   'status'  → Picklist / String / TextArea (typical status holders)
     *   anything else / blank → all readable fields
     *
     * Fields are returned sorted by their UI label so the list reads
     * predictably, and we include the API name as the value plus the type so
     * the LWC can chain further behaviour (e.g. fetch picklist values for a
     * Picklist field).
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectFields(String objectName, String fieldTypeFilter) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        if (String.isBlank(objectName)) return result;

        Schema.SObjectType sobjType = resolveType(objectName);
        if (sobjType == null) return result;

        Set<Schema.DisplayType> allowed = null;
        if (fieldTypeFilter == 'numeric') {
            allowed = new Set<Schema.DisplayType>{
                Schema.DisplayType.Double,
                Schema.DisplayType.Integer,
                Schema.DisplayType.Currency,
                Schema.DisplayType.Percent
            };
        } else if (fieldTypeFilter == 'status') {
            allowed = new Set<Schema.DisplayType>{
                Schema.DisplayType.Picklist,
                Schema.DisplayType.String,
                Schema.DisplayType.TextArea
            };
        }

        Map<String, Schema.SObjectField> fieldMap = sobjType.getDescribe().fields.getMap();
        List<FieldOption> options = new List<FieldOption>();
        for (String apiName : fieldMap.keySet()) {
            Schema.DescribeFieldResult f = fieldMap.get(apiName).getDescribe();
            if (allowed != null && !allowed.contains(f.getType())) continue;
            if (!f.isAccessible()) continue;
            options.add(new FieldOption(f.getLabel(), f.getName(), String.valueOf(f.getType())));
        }
        options.sort();
        for (FieldOption o : options) {
            result.add(new Map<String, String>{
                'label' => o.label, 'value' => o.value, 'type' => o.fieldType
            });
        }
        return result;
    }

    /**
     * @description When the Status Field dropdown lands on a picklist, the
     * three Status_Value_On_* dropdowns should offer only that picklist's
     * actual values rather than a free-text input. Returns an empty list for
     * non-picklist fields — the LWC falls back to free text in that case.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getPicklistValues(String objectName, String fieldName) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        if (String.isBlank(objectName) || String.isBlank(fieldName)) return result;
        Schema.SObjectType sobjType = resolveType(objectName);
        if (sobjType == null) return result;
        Schema.SObjectField field = resolveField(sobjType.getDescribe().fields.getMap(), fieldName);
        if (field == null) return result;
        Schema.DescribeFieldResult f = field.getDescribe();
        if (f.getType() != Schema.DisplayType.Picklist
            && f.getType() != Schema.DisplayType.MultiPicklist) return result;
        for (Schema.PicklistEntry e : f.getPicklistValues()) {
            if (!e.isActive()) continue;
            result.add(new Map<String, String>{
                'label' => e.getLabel(), 'value' => e.getValue()
            });
        }
        return result;
    }

    /** Wrapper class — Apex's List.sort() needs a Comparable element. */
    public class FieldOption implements Comparable {
        public String label;
        public String value;
        public String fieldType;
        public FieldOption(String label, String value, String fieldType) {
            this.label = label;
            this.value = value;
            this.fieldType = fieldType;
        }
        public Integer compareTo(Object other) {
            FieldOption o = (FieldOption) other;
            return this.label.compareTo(o.label);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchUsers(String searchTerm) {
        if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return new List<Map<String, String>>();
        }
        String pattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<User> users = [
            SELECT Id, Name, Email, Username
            FROM User
            WHERE IsActive = true
              AND (Name LIKE :pattern OR Email LIKE :pattern OR Username LIKE :pattern)
            ORDER BY Name
            LIMIT 20
        ];
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
     * @description One-shot migration helper. Reads existing
     * Approval_Matrix__mdt records and inserts equivalent Approval_Rule__c
     * records. Idempotent — skips rows already present for the same object
     * + level combo.
     */
    @AuraEnabled
    public static Integer migrateFromMetadata() {
        Set<String> existing = new Set<String>();
        for (Approval_Rule__c r : [
            SELECT Object_Process__c, Approval_Level__c FROM Approval_Rule__c
        ]) {
            existing.add(r.Object_Process__c + '|' + String.valueOf(r.Approval_Level__c));
        }

        List<Approval_Rule__c> toInsert = new List<Approval_Rule__c>();
        for (Approval_Matrix__mdt md : [
            SELECT Object_Type__c, Approval_Level__c, Approver_Role__c,
                   Condition_Field__c, Min_Value__c, Max_Value__c, Is_Active__c
            FROM Approval_Matrix__mdt
        ]) {
            String key = md.Object_Type__c + '|' + String.valueOf(md.Approval_Level__c);
            if (existing.contains(key)) continue;

            toInsert.add(new Approval_Rule__c(
                Object_Process__c = md.Object_Type__c,
                Approval_Level__c = md.Approval_Level__c,
                Approver_Type__c = 'Role',
                Approver_Role_Queue__c = md.Approver_Role__c,
                Condition_Field__c = md.Condition_Field__c,
                Min_Value__c = md.Min_Value__c,
                Max_Value__c = md.Max_Value__c,
                Auto_Approve__c = false,
                Is_Active__c = md.Is_Active__c,
                Description__c = 'Migrated from Approval_Matrix__mdt'
            ));
        }

        if (!toInsert.isEmpty()) insert toInsert;
        return toInsert.size();
    }
}