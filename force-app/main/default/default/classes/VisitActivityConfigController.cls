/**
 * @description Backs the Visit Activity Settings admin window: the catalogue,
 * the rules that scope it by Profile and Outlet Type, and a preview that shows
 * exactly what a rep would get.
 *
 * The preview deliberately calls the same VisitActivityConfig.resolve() the
 * runtime uses, so an admin can never be shown a preview that disagrees with
 * what the rep sees.
 */
public with sharing class VisitActivityConfigController {

    /** A catalogue row plus its current org-level availability. */
    public class ActivityRow {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String icon;
        @AuraEnabled public String toggleCode;
        @AuraEnabled public Boolean featureAvailable;
        @AuraEnabled public Integer sortOrder;
    }

    /**
     * @description The activity catalogue, each flagged with whether its
     *              feature toggle currently licenses it. An activity whose
     *              toggle is off cannot be enabled by any rule, and the UI
     *              greys it out rather than letting an admin configure
     *              something that will never appear.
     */
    @AuraEnabled(cacheable=true)
    public static List<ActivityRow> getCatalog() {
        List<ActivityRow> rows = new List<ActivityRow>();
        for (VisitActivityConfig.ActivityDef d : VisitActivityConfig.CATALOG) {
            ActivityRow r = new ActivityRow();
            r.key = d.key;
            r.label = d.label;
            r.icon = d.icon;
            r.toggleCode = d.toggleCode;
            r.sortOrder = d.sortOrder;
            r.featureAvailable = String.isBlank(d.toggleCode)
                || BPM_FeatureToggle_Util.isEnabled(d.toggleCode);
            rows.add(r);
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static List<Visit_Activity_Rule__c> getRules() {
        return [
            SELECT Id, Name, Activity_Key__c, Profile_Name__c, Outlet_Type__c,
                   Is_Enabled__c, Is_Active__c, Sort_Order__c, Description__c,
                   LastModifiedDate
            FROM Visit_Activity_Rule__c
            ORDER BY Activity_Key__c, Profile_Name__c NULLS FIRST, Outlet_Type__c NULLS FIRST
        ];
    }

    /** Profiles and outlet types an admin can scope a rule to. */
    @AuraEnabled(cacheable=true)
    public static Map<String, List<Map<String, String>>> getScopeOptions() {
        Map<String, List<Map<String, String>>> out = new Map<String, List<Map<String, String>>>();

        List<Map<String, String>> profiles = new List<Map<String, String>>();
        for (Profile p : [SELECT Name FROM Profile ORDER BY Name LIMIT 500]) {
            profiles.add(new Map<String, String>{ 'label' => p.Name, 'value' => p.Name });
        }
        out.put('profiles', profiles);

        // Outlet types come from the live picklist, so a new outlet type is
        // immediately scopeable without touching this class.
        List<Map<String, String>> outletTypes = new List<Map<String, String>>();
        Schema.DescribeFieldResult f = Account.Outlet_Type__c.getDescribe();
        for (Schema.PicklistEntry e : f.getPicklistValues()) {
            if (!e.isActive()) continue;
            outletTypes.add(new Map<String, String>{ 'label' => e.getLabel(), 'value' => e.getValue() });
        }
        out.put('outletTypes', outletTypes);

        return out;
    }

    /**
     * @description Saves one rule. A blank Profile or Outlet Type means "all",
     *              which is the whole point of the precedence model, so blanks
     *              are normalised to null rather than empty string — otherwise
     *              '' would never match and the rule would silently do nothing.
     */
    @AuraEnabled
    public static Visit_Activity_Rule__c saveRule(Visit_Activity_Rule__c rule) {
        if (rule == null || String.isBlank(rule.Activity_Key__c)) {
            throw new AuraHandledException('Pick an activity for this rule.');
        }

        Set<String> validKeys = new Set<String>();
        for (VisitActivityConfig.ActivityDef d : VisitActivityConfig.CATALOG) {
            validKeys.add(d.key);
        }
        if (!validKeys.contains(rule.Activity_Key__c)) {
            throw new AuraHandledException(
                '"' + rule.Activity_Key__c + '" is not a known activity.');
        }

        if (String.isBlank(rule.Profile_Name__c)) rule.Profile_Name__c = null;
        if (String.isBlank(rule.Outlet_Type__c))  rule.Outlet_Type__c = null;

        // One rule per activity + scope, so an admin can't create two rules that
        // contradict each other at the same specificity.
        List<Visit_Activity_Rule__c> clashes = [
            SELECT Id FROM Visit_Activity_Rule__c
            WHERE Activity_Key__c = :rule.Activity_Key__c
              AND Profile_Name__c = :rule.Profile_Name__c
              AND Outlet_Type__c = :rule.Outlet_Type__c
        ];
        for (Visit_Activity_Rule__c c : clashes) {
            if (c.Id != rule.Id) {
                throw new AuraHandledException(
                    'A rule already exists for that activity and scope. Edit that one instead.');
            }
        }

        upsert rule;
        return [
            SELECT Id, Name, Activity_Key__c, Profile_Name__c, Outlet_Type__c,
                   Is_Enabled__c, Is_Active__c, Sort_Order__c, Description__c,
                   LastModifiedDate
            FROM Visit_Activity_Rule__c WHERE Id = :rule.Id
        ];
    }

    @AuraEnabled
    public static void deleteRule(Id ruleId) {
        if (ruleId == null) return;
        delete new Visit_Activity_Rule__c(Id = ruleId);
    }

    /**
     * @description Bulk-sets the enabled flag for a whole scope in one go —
     *              what the matrix's toggles call. Creates a rule where none
     *              exists, updates it where one does, and deletes it when the
     *              admin returns the activity to its default, so the object
     *              doesn't fill up with rules that say "behave normally".
     */
    @AuraEnabled
    public static void setActivityForScope(
        String activityKey, String profileName, String outletType,
        Boolean enabled, Boolean useDefault
    ) {
        if (String.isBlank(activityKey)) {
            throw new AuraHandledException('Activity is required.');
        }
        String prof = String.isBlank(profileName) ? null : profileName;
        String outlet = String.isBlank(outletType) ? null : outletType;

        List<Visit_Activity_Rule__c> existing = [
            SELECT Id FROM Visit_Activity_Rule__c
            WHERE Activity_Key__c = :activityKey
              AND Profile_Name__c = :prof
              AND Outlet_Type__c = :outlet
        ];

        if (useDefault == true) {
            if (!existing.isEmpty()) delete existing;
            return;
        }

        if (existing.isEmpty()) {
            insert new Visit_Activity_Rule__c(
                Activity_Key__c = activityKey,
                Profile_Name__c = prof,
                Outlet_Type__c = outlet,
                Is_Enabled__c = (enabled == true),
                Is_Active__c = true
            );
        } else {
            Visit_Activity_Rule__c r = existing[0];
            r.Is_Enabled__c = (enabled == true);
            r.Is_Active__c = true;
            update r;
        }
    }

    /**
     * @description What a rep on this Profile, visiting this Outlet Type, would
     *              actually see — produced by the same resolver the runtime uses.
     */
    @AuraEnabled
    public static List<VisitActivityConfig.Resolution> preview(String profileName, String outletType) {
        return VisitActivityConfig.resolve(
            String.isBlank(profileName) ? null : profileName,
            String.isBlank(outletType) ? null : outletType
        );
    }
}