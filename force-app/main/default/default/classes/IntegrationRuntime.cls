/**
 * @description Runtime resolver for the integrations framework: given an integration key, returns
 *              its live configuration (enabled, provider, mode, non-secret settings, resolved base
 *              URL, Named Credential) so any consumer — an e-invoice provider, an SMS sender, etc. —
 *              can decide whether the integration is configured and where to call.
 *
 *              This is the read-side counterpart to IntegrationConfigController (the write/UI side).
 */
public with sharing class IntegrationRuntime {

    /** Full runtime context for an integration, or null if the key isn't in the catalog. */
    public static IntegrationTypes.Context contextFor(String key) {
        List<Integration_Definition__mdt> defs = [
            SELECT DeveloperName, Requires_Credential__c, Named_Credential_Name__c
            FROM Integration_Definition__mdt WHERE DeveloperName = :key LIMIT 1
        ];
        if (defs.isEmpty()) {
            return null;
        }
        Integration_Definition__mdt def = defs[0];

        IntegrationTypes.Context ctx = new IntegrationTypes.Context();
        ctx.key = key;
        ctx.requiresCredential = def.Requires_Credential__c == true;
        ctx.namedCredential = def.Named_Credential_Name__c;
        ctx.mode = 'Sandbox';

        for (Integration_Setting__c s : [
            SELECT Is_Enabled__c, Provider__c, Mode__c, Settings_JSON__c, Credential_Set__c
            FROM Integration_Setting__c WHERE Integration_Key__c = :key LIMIT 1
        ]) {
            ctx.enabled = s.Is_Enabled__c == true;
            ctx.provider = s.Provider__c;
            ctx.mode = String.isBlank(s.Mode__c) ? 'Sandbox' : s.Mode__c;
            ctx.credentialSet = s.Credential_Set__c == true;
            ctx.settings = parse(s.Settings_JSON__c);
        }

        // Resolve the base URL for the selected provider + mode from the provider catalog.
        if (String.isNotBlank(ctx.provider)) {
            for (Integration_Provider__mdt p : [
                SELECT Sandbox_Base_URL__c, Live_Base_URL__c
                FROM Integration_Provider__mdt
                WHERE Integration_Key__c = :key AND Provider_Name__c = :ctx.provider AND Is_Active__c = true
                LIMIT 1
            ]) {
                ctx.baseUrl = (ctx.mode == 'Live') ? p.Live_Base_URL__c : p.Sandbox_Base_URL__c;
            }
        }
        return ctx;
    }

    /** True when the integration is switched on and (if it needs one) has a credential set. */
    public static Boolean isConfigured(String key) {
        IntegrationTypes.Context ctx = contextFor(key);
        return ctx != null && ctx.enabled && (!ctx.requiresCredential || ctx.credentialSet);
    }

    private static Map<String, Object> parse(String body) {
        if (String.isBlank(body)) {
            return new Map<String, Object>();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }
}