/**
 * @description LWC controller for the Integrations configuration window. Merges the shipped
 *              catalog (Integration_Definition__mdt) with this org's saved state
 *              (Integration_Setting__c) and exposes save / save-credentials / test-connection.
 *
 *              Secrets are NEVER stored on Integration_Setting__c or returned to the client — they
 *              go straight to the External Credential via IntegrationCredentialService, and the
 *              record only remembers WHETHER a secret is set (Credential_Set__c).
 */
public with sharing class IntegrationConfigController {

    // ── View DTOs ──────────────────────────────────────────────────────────
    public class SettingField {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String type;          // text | number | select | password
        @AuraEnabled public Boolean required = false;
        @AuraEnabled public Boolean secret = false;
        @AuraEnabled public List<String> options;
        @AuraEnabled public String help;
    }

    public class ProviderOption {
        @AuraEnabled public String name;
        @AuraEnabled public String sandboxUrl;
        @AuraEnabled public String liveUrl;
        @AuraEnabled public String docsUrl;
    }

    public class IntegrationView {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String category;
        @AuraEnabled public String description;
        @AuraEnabled public String icon;
        @AuraEnabled public String docsUrl;
        @AuraEnabled public List<String> providerOptions = new List<String>();
        @AuraEnabled public List<ProviderOption> providers = new List<ProviderOption>();
        @AuraEnabled public List<SettingField> schema = new List<SettingField>();
        @AuraEnabled public Boolean requiresCredential = false;
        // saved state
        @AuraEnabled public Boolean enabled = false;
        @AuraEnabled public String provider;
        @AuraEnabled public String mode = 'Sandbox';
        @AuraEnabled public Map<String, Object> settings = new Map<String, Object>();  // non-secret only
        @AuraEnabled public Boolean credentialSet = false;
        @AuraEnabled public String status = 'Not Configured';
        @AuraEnabled public Datetime lastTested;
        @AuraEnabled public String lastTestResult;
    }

    // ── Read: catalog ⨝ per-org state ──────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<IntegrationView> getIntegrations() {
        Map<String, Integration_Setting__c> settingByKey = new Map<String, Integration_Setting__c>();
        for (Integration_Setting__c s : [
            SELECT Integration_Key__c, Is_Enabled__c, Provider__c, Mode__c, Settings_JSON__c,
                   Credential_Set__c, Status__c, Last_Tested__c, Last_Test_Result__c
            FROM Integration_Setting__c
        ]) {
            settingByKey.put(s.Integration_Key__c, s);
        }

        // Provider URL overlay: active provider records grouped by integration key, in order.
        Map<String, List<Integration_Provider__mdt>> providersByKey = new Map<String, List<Integration_Provider__mdt>>();
        for (Integration_Provider__mdt p : [
            SELECT Integration_Key__c, Provider_Name__c, Sandbox_Base_URL__c, Live_Base_URL__c,
                   Docs_URL__c, Is_Active__c
            FROM Integration_Provider__mdt
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c NULLS LAST, Provider_Name__c
        ]) {
            if (!providersByKey.containsKey(p.Integration_Key__c)) {
                providersByKey.put(p.Integration_Key__c, new List<Integration_Provider__mdt>());
            }
            providersByKey.get(p.Integration_Key__c).add(p);
        }

        List<IntegrationView> views = new List<IntegrationView>();
        for (Integration_Definition__mdt def : [
            SELECT DeveloperName, MasterLabel, Category__c, Description__c, Icon__c, Docs_URL__c,
                   Provider_Options__c, Settings_Schema__c, Requires_Credential__c
            FROM Integration_Definition__mdt
            ORDER BY Sort_Order__c NULLS LAST, MasterLabel
        ]) {
            IntegrationView v = new IntegrationView();
            v.key = def.DeveloperName;
            v.label = def.MasterLabel;
            v.category = def.Category__c;
            v.description = def.Description__c;
            v.icon = def.Icon__c;
            v.docsUrl = def.Docs_URL__c;
            v.requiresCredential = def.Requires_Credential__c == true;
            v.providers = buildProviders(def.Provider_Options__c, providersByKey.get(def.DeveloperName));
            for (ProviderOption po : v.providers) { v.providerOptions.add(po.name); }
            v.schema = parseSchema(def.Settings_Schema__c);

            Integration_Setting__c s = settingByKey.get(def.DeveloperName);
            if (s != null) {
                v.enabled = s.Is_Enabled__c == true;
                v.provider = s.Provider__c;
                v.mode = String.isBlank(s.Mode__c) ? 'Sandbox' : s.Mode__c;
                v.settings = parseSettings(s.Settings_JSON__c);
                v.credentialSet = s.Credential_Set__c == true;
                v.status = String.isBlank(s.Status__c) ? 'Not Configured' : s.Status__c;
                v.lastTested = s.Last_Tested__c;
                v.lastTestResult = s.Last_Test_Result__c;
            } else if (v.providerOptions.size() == 1) {
                v.provider = v.providerOptions[0];   // sensible default for single-provider integrations
            }
            views.add(v);
        }
        return views;
    }

    // ── Save non-secret configuration ──────────────────────────────────────
    @AuraEnabled
    public static void saveIntegration(String key, Boolean enabled, String provider, String mode, String settingsJson) {
        Integration_Definition__mdt def = definitionFor(key);

        // Defence in depth: strip any secret-typed key so a secret can never land in Settings_JSON,
        // even if the client mistakenly includes one.
        Set<String> secretKeys = secretKeysOf(def.Settings_Schema__c);
        Map<String, Object> incoming = parseSettings(settingsJson);
        for (String sk : secretKeys) { incoming.remove(sk); }

        Integration_Setting__c s = existingFor(key);
        if (s == null) {
            s = new Integration_Setting__c(Integration_Key__c = key);
        }
        s.Name = def.MasterLabel;
        s.Is_Enabled__c = enabled == true;
        s.Provider__c = provider;
        s.Mode__c = String.isBlank(mode) ? 'Sandbox' : mode;
        s.Settings_JSON__c = incoming.isEmpty() ? null : JSON.serialize(incoming);
        s.Status__c = computeStatus(s, def);
        upsert s Integration_Key__c;
    }

    // ── Save secret(s) → External Credential (Option A) ────────────────────
    @AuraEnabled
    public static void saveCredentials(String key, String secretsJson) {
        Integration_Definition__mdt def = definitionFor(key);
        if (def.Requires_Credential__c != true) {
            throw new AuraHandledException('This integration does not use credentials.');
        }

        Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(
            String.isBlank(secretsJson) ? '{}' : secretsJson);
        Map<String, String> secrets = new Map<String, String>();
        for (String k : raw.keySet()) {
            String val = raw.get(k) == null ? null : String.valueOf(raw.get(k));
            if (String.isNotBlank(val)) { secrets.put(k, val); }
        }

        IntegrationCredentialService.storeSecret(def.Named_Credential_Name__c, key, secrets);

        Integration_Setting__c s = existingFor(key);
        if (s == null) {
            s = new Integration_Setting__c(Integration_Key__c = key, Name = def.MasterLabel);
        }
        s.Credential_Set__c = true;
        s.Status__c = computeStatus(s, def);
        upsert s Integration_Key__c;
    }

    // ── Test connection ────────────────────────────────────────────────────
    @AuraEnabled
    public static IntegrationTypes.ConnectionResult testConnection(String key) {
        Integration_Definition__mdt def = definitionFor(key);
        Integration_Setting__c s = existingFor(key);

        IntegrationTypes.Context ctx = new IntegrationTypes.Context();
        ctx.key = key;
        ctx.requiresCredential = def.Requires_Credential__c == true;
        ctx.credentialSet = s != null && s.Credential_Set__c == true;
        ctx.provider = s != null ? s.Provider__c : null;
        ctx.mode = s != null ? s.Mode__c : 'Sandbox';
        ctx.settings = s != null ? parseSettings(s.Settings_JSON__c) : new Map<String, Object>();

        IntegrationConnector connector = resolveConnector(def.Connector_Class__c);
        IntegrationTypes.ConnectionResult result = connector.testConnection(ctx);

        if (s == null) {
            s = new Integration_Setting__c(Integration_Key__c = key, Name = def.MasterLabel);
        }
        s.Last_Tested__c = Datetime.now();
        s.Last_Test_Result__c = result == null ? null : abbreviate(result.message, 255);
        if (s.Is_Enabled__c == true) {
            s.Status__c = (result != null && result.ok == true) ? 'Connected' : 'Error';
        }
        upsert s Integration_Key__c;
        return result;
    }

    // ── Helpers ────────────────────────────────────────────────────────────
    private static Integration_Definition__mdt definitionFor(String key) {
        List<Integration_Definition__mdt> defs = [
            SELECT DeveloperName, MasterLabel, Requires_Credential__c, Named_Credential_Name__c,
                   Connector_Class__c, Settings_Schema__c
            FROM Integration_Definition__mdt WHERE DeveloperName = :key LIMIT 1
        ];
        if (defs.isEmpty()) {
            throw new AuraHandledException('Unknown integration: ' + key);
        }
        return defs[0];
    }

    private static Integration_Setting__c existingFor(String key) {
        List<Integration_Setting__c> rows = [
            SELECT Id, Integration_Key__c, Name, Is_Enabled__c, Provider__c, Mode__c, Settings_JSON__c,
                   Credential_Set__c, Status__c, Last_Tested__c, Last_Test_Result__c
            FROM Integration_Setting__c WHERE Integration_Key__c = :key LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /** Enabled + (credential present when needed) → keep a proven 'Connected', else 'Not Configured'. */
    private static String computeStatus(Integration_Setting__c s, Integration_Definition__mdt def) {
        if (s.Is_Enabled__c != true) { return 'Disabled'; }
        if (def.Requires_Credential__c == true && s.Credential_Set__c != true) { return 'Not Configured'; }
        return s.Status__c == 'Connected' ? 'Connected' : 'Not Configured';
    }

    private static IntegrationConnector resolveConnector(String className) {
        if (String.isBlank(className)) {
            return new StubConnector();
        }
        Type t = Type.forName(className);
        if (t == null) {
            throw new AuraHandledException('Connector class not found: ' + className);
        }
        Object inst = t.newInstance();
        if (!(inst instanceof IntegrationConnector)) {
            throw new AuraHandledException(className + ' does not implement IntegrationConnector.');
        }
        return (IntegrationConnector) inst;
    }

    private static Set<String> secretKeysOf(String schemaJson) {
        Set<String> keys = new Set<String>();
        for (SettingField f : parseSchema(schemaJson)) {
            if (f.secret == true && String.isNotBlank(f.key)) { keys.add(f.key); }
        }
        return keys;
    }

    /**
     * Provider dropdown = the definition's simple name list (enriched with URLs where a provider
     * record matches by name) UNION any provider added purely as a record. So an admin can add a
     * provider by editing the list, by adding a record (with URLs), or both.
     */
    private static List<ProviderOption> buildProviders(String optionsCsv, List<Integration_Provider__mdt> records) {
        Map<String, Integration_Provider__mdt> byName = new Map<String, Integration_Provider__mdt>();
        if (records != null) {
            for (Integration_Provider__mdt r : records) {
                if (String.isNotBlank(r.Provider_Name__c)) { byName.put(r.Provider_Name__c, r); }
            }
        }
        List<ProviderOption> out = new List<ProviderOption>();
        Set<String> seen = new Set<String>();
        for (String name : splitOptions(optionsCsv)) {
            if (seen.contains(name)) { continue; }
            out.add(toProviderOption(name, byName.get(name)));
            seen.add(name);
        }
        if (records != null) {
            for (Integration_Provider__mdt r : records) {
                if (String.isNotBlank(r.Provider_Name__c) && !seen.contains(r.Provider_Name__c)) {
                    out.add(toProviderOption(r.Provider_Name__c, r));
                    seen.add(r.Provider_Name__c);
                }
            }
        }
        return out;
    }

    private static ProviderOption toProviderOption(String name, Integration_Provider__mdt r) {
        ProviderOption po = new ProviderOption();
        po.name = name;
        if (r != null) {
            po.sandboxUrl = r.Sandbox_Base_URL__c;
            po.liveUrl = r.Live_Base_URL__c;
            po.docsUrl = r.Docs_URL__c;
        }
        return po;
    }

    private static List<String> splitOptions(String csv) {
        List<String> out = new List<String>();
        if (String.isBlank(csv)) { return out; }
        for (String part : csv.split(';')) {
            if (String.isNotBlank(part)) { out.add(part.trim()); }
        }
        return out;
    }

    private static List<SettingField> parseSchema(String body) {
        if (String.isBlank(body)) { return new List<SettingField>(); }
        try {
            return (List<SettingField>) JSON.deserialize(body, List<SettingField>.class);
        } catch (Exception e) {
            return new List<SettingField>();
        }
    }

    private static Map<String, Object> parseSettings(String body) {
        if (String.isBlank(body)) { return new Map<String, Object>(); }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static String abbreviate(String v, Integer max) {
        if (v == null) { return null; }
        return v.length() > max ? v.substring(0, max) : v;
    }
}