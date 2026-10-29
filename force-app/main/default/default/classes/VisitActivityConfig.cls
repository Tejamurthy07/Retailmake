/**
 * @description Decides which Visit Manager activity tiles a rep sees.
 *
 * Two layers, deliberately kept separate:
 *   Feature toggle  — is this module available to the org at all (packaging tier).
 *                     A toggle that is off hides the activity for everyone; no
 *                     rule can bring it back.
 *   Activity rule   — of the activities the org HAS, who actually sees them,
 *                     resolved by the running user's Profile and the visited
 *                     outlet's Account.Outlet_Type__c.
 *
 * Rule precedence is most-specific-wins, scored so an admin can express
 * "hide Returns everywhere, except Modern Trade" in two rows instead of
 * enumerating every combination:
 *
 *   Profile + Outlet Type  3
 *   Profile only           2
 *   Outlet Type only       1
 *   Neither (global)       0
 *
 * With no rules configured the resolver returns exactly what the feature
 * toggles alone would have returned, so deploying this changes nothing until
 * someone configures a rule.
 *
 * The catalogue lives here rather than in custom metadata on purpose: every
 * activity also needs its own panel in the visitManager LWC, so adding one is a
 * code change regardless. A metadata catalogue would be a second place to
 * maintain without removing that deploy.
 */
public with sharing class VisitActivityConfig {

    /** One activity the product can show, and the toggle that licenses it. */
    public class ActivityDef {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String icon;
        @AuraEnabled public String toggleCode;   // null = always available
        @AuraEnabled public Integer sortOrder;

        public ActivityDef(String key, String label, String icon, String toggleCode, Integer sortOrder) {
            this.key = key;
            this.label = label;
            this.icon = icon;
            this.toggleCode = toggleCode;
            this.sortOrder = sortOrder;
        }
    }

    /**
     * The catalogue, in default display order. Order, Collection and Returns
     * carry no toggle — they are core to a visit — but they ARE rule-eligible,
     * so an admin can still hide them for a specific profile or outlet type.
     */
    public static final List<ActivityDef> CATALOG = new List<ActivityDef>{
        new ActivityDef('order',         'Order',             'standard:orders',          null,      10),
        new ActivityDef('collection',    'Collection',        'standard:payment_gateway', null,      20),
        new ActivityDef('returns',       'Returns',           'standard:return_order',    null,      30),
        // Key stays 'stock_check' — it is the identifier Visit_Activity_Rule__c
        // rows point at, so renaming the label must not disturb it.
        new ActivityDef('stock_check',   'Stock Update',      'standard:product_item',    'OVE-010', 40),
        // Availability & Stock Depth — always licensed (no toggle); admins switch
        // it on/off per profile/outlet-type via Visit_Activity_Rule__c.
        new ActivityDef('availability',  'Availability & Stock Depth', 'standard:products', null,   45),
        new ActivityDef('competitor',    'Competitor',        'standard:account',         'OVE-011', 50),
        new ActivityDef('merchandising', 'Merchandising',     'standard:scan_card',       'OVE-004', 60),
        new ActivityDef('survey',        'Survey',            'standard:survey',          'OVE-005', 70),
        new ActivityDef('scheme',        'Scheme Info',       'standard:reward',          'SPM-001', 80),
        new ActivityDef('ticket',        'Ticket',            'standard:case',            'OVE-012', 90)
    };

    /** The resolved verdict for one activity, including why. */
    public class Resolution {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String icon;
        @AuraEnabled public Integer sortOrder;
        @AuraEnabled public Boolean visible;
        @AuraEnabled public String reason;
    }

    /**
     * @description Resolves the full catalogue for a profile + outlet type.
     *              Used both by the runtime (which keeps only the visible ones)
     *              and by the admin window's preview, so what an admin previews
     *              is produced by the same code the rep gets.
     */
    public static List<Resolution> resolve(String profileName, String outletType) {
        // Best rule found per activity, with the score that won it.
        Map<String, Visit_Activity_Rule__c> bestByKey = new Map<String, Visit_Activity_Rule__c>();
        Map<String, Integer> bestScore = new Map<String, Integer>();

        for (Visit_Activity_Rule__c r : [
            SELECT Activity_Key__c, Profile_Name__c, Outlet_Type__c,
                   Is_Enabled__c, Sort_Order__c
            FROM Visit_Activity_Rule__c
            WHERE Is_Active__c = true AND Activity_Key__c != null
        ]) {
            Boolean profileMatches = String.isBlank(r.Profile_Name__c)
                || (profileName != null && r.Profile_Name__c == profileName);
            Boolean outletMatches = String.isBlank(r.Outlet_Type__c)
                || (outletType != null && r.Outlet_Type__c == outletType);
            if (!profileMatches || !outletMatches) continue;

            Integer score = (String.isBlank(r.Profile_Name__c) ? 0 : 2)
                          + (String.isBlank(r.Outlet_Type__c) ? 0 : 1);

            String k = r.Activity_Key__c;
            if (!bestScore.containsKey(k) || score > bestScore.get(k)) {
                bestScore.put(k, score);
                bestByKey.put(k, r);
            }
        }

        List<Resolution> out = new List<Resolution>();
        for (ActivityDef d : CATALOG) {
            Resolution res = new Resolution();
            res.key = d.key;
            res.label = d.label;
            res.icon = d.icon;
            res.sortOrder = d.sortOrder;

            // Layer 1: the feature toggle is an absolute gate.
            if (String.isNotBlank(d.toggleCode)
                && !BPM_FeatureToggle_Util.isEnabled(d.toggleCode)) {
                res.visible = false;
                res.reason = 'Feature ' + d.toggleCode + ' is off for this org';
                out.add(res);
                continue;
            }

            // Layer 2: the most specific matching rule, if any.
            Visit_Activity_Rule__c rule = bestByKey.get(d.key);
            if (rule == null) {
                res.visible = true;
                res.reason = 'No rule — visible by default';
            } else {
                res.visible = (rule.Is_Enabled__c == true);
                res.reason = describe(rule);
                if (rule.Sort_Order__c != null) {
                    res.sortOrder = Integer.valueOf(rule.Sort_Order__c);
                }
            }
            out.add(res);
        }
        return out;
    }

    private static String describe(Visit_Activity_Rule__c r) {
        List<String> bits = new List<String>();
        if (String.isNotBlank(r.Profile_Name__c)) bits.add('profile ' + r.Profile_Name__c);
        if (String.isNotBlank(r.Outlet_Type__c))  bits.add('outlet type ' + r.Outlet_Type__c);
        String scope = bits.isEmpty() ? 'all profiles and outlet types' : String.join(bits, ' + ');
        return (r.Is_Enabled__c == true ? 'Enabled' : 'Hidden') + ' by rule for ' + scope;
    }

    /**
     * @description The activity keys visible to the running user for a given
     *              outlet type. The runtime entry point.
     */
    public static Set<String> visibleKeys(String outletType) {
        Set<String> keys = new Set<String>();
        for (Resolution r : resolve(currentProfileName(), outletType)) {
            if (r.visible == true) keys.add(r.key);
        }
        return keys;
    }

    /** Sort order per activity key, honouring any rule override. */
    public static Map<String, Integer> sortOrders(String outletType) {
        Map<String, Integer> orders = new Map<String, Integer>();
        for (Resolution r : resolve(currentProfileName(), outletType)) {
            orders.put(r.key, r.sortOrder);
        }
        return orders;
    }

    private static String cachedProfileName;
    public static String currentProfileName() {
        if (cachedProfileName == null) {
            cachedProfileName = [
                SELECT Name FROM Profile WHERE Id = :UserInfo.getProfileId() LIMIT 1
            ].Name;
        }
        return cachedProfileName;
    }
}