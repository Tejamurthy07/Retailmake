/**
 * @description Central, admin-editable configuration for the DMS module. Reads
 *              App_Config__mdt records (Module__c = 'DMS') so per-client behavior
 *              (thresholds, modes, document prefixes, etc.) is configurable as
 *              metadata rather than hardcoded. Every accessor ships a sensible
 *              default, so the system works out-of-the-box with no config rows and
 *              each client overrides only what it needs.
 *
 *              Pattern mirrors the existing App_Config__mdt usage (AdminConfigController),
 *              so DMS settings appear in the same admin config experience.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_Config {

    public static final String MODULE = 'DMS';

    // Config keys (also the App_Config__mdt.Config_Key__c values).
    public static final String KEY_LOW_STOCK_THRESHOLD = 'LOW_STOCK_THRESHOLD';
    public static final String KEY_NEAR_EXPIRY_DAYS     = 'NEAR_EXPIRY_DAYS';
    public static final String KEY_TIER_MODEL           = 'TIER_MODEL';            // TWO_TIER | THREE_TIER
    public static final String KEY_DEFAULT_PERIOD       = 'DEFAULT_DASHBOARD_PERIOD';
    public static final String KEY_DEFAULT_CREDIT_DAYS  = 'DEFAULT_CREDIT_DAYS';
    public static final String KEY_PRIMARY_PREFIX       = 'PRIMARY_INVOICE_PREFIX';
    public static final String KEY_P2_PREFIX            = 'P2_INVOICE_PREFIX';
    public static final String KEY_SECONDARY_PREFIX     = 'SECONDARY_INVOICE_PREFIX';
    public static final String KEY_ENFORCE_CREDIT       = 'ENFORCE_CREDIT';        // true/false
    public static final String KEY_FEFO_ENABLED         = 'FEFO_ENABLED';          // true/false
    // Who supplies a field (SFA) sale to a retailer: the servicing DISTRIBUTOR
    // (distributor-led GTM, the default) or the company WAREHOUSE (direct distribution).
    public static final String KEY_SECONDARY_STOCK_SOURCE = 'SECONDARY_STOCK_SOURCE';

    // ── Typed accessors ───────────────────────────────────────────────────
    public static Integer getInt(String key, Integer dflt) {
        String v = raw(key);
        if (String.isBlank(v)) { return dflt; }
        try { return Integer.valueOf(v.trim()); } catch (Exception e) { return dflt; }
    }
    public static Decimal getDecimal(String key, Decimal dflt) {
        String v = raw(key);
        if (String.isBlank(v)) { return dflt; }
        try { return Decimal.valueOf(v.trim()); } catch (Exception e) { return dflt; }
    }
    public static Boolean getBool(String key, Boolean dflt) {
        String v = raw(key);
        if (String.isBlank(v)) { return dflt; }
        v = v.trim().toLowerCase();
        return (v == 'true' || v == '1' || v == 'yes');
    }
    public static String getString(String key, String dflt) {
        String v = raw(key);
        return String.isBlank(v) ? dflt : v.trim();
    }

    // ── Named helpers (defaults baked in) ─────────────────────────────────
    public static Integer lowStockThreshold() { return getInt(KEY_LOW_STOCK_THRESHOLD, 25); }
    public static Integer nearExpiryDays()     { return getInt(KEY_NEAR_EXPIRY_DAYS, 30); }
    public static String  tierModel()          { return getString(KEY_TIER_MODEL, 'THREE_TIER'); }
    public static Boolean isThreeTier()        { return tierModel() == 'THREE_TIER'; }
    public static String  defaultPeriod()      { return getString(KEY_DEFAULT_PERIOD, 'THIS_JC'); }
    public static Integer defaultCreditDays()  { return getInt(KEY_DEFAULT_CREDIT_DAYS, 30); }
    public static String  secondaryStockSource() { return getString(KEY_SECONDARY_STOCK_SOURCE, 'DISTRIBUTOR').toUpperCase(); }
    /** True when a retailer's field sale is supplied from their servicing distributor's stock. */
    public static Boolean isDistributorSourced() { return secondaryStockSource() == 'DISTRIBUTOR'; }
    public static String  primaryPrefix()      { return getString(KEY_PRIMARY_PREFIX, 'PINV-'); }
    public static String  p2Prefix()           { return getString(KEY_P2_PREFIX, 'P2INV-'); }
    public static String  secondaryPrefix()    { return getString(KEY_SECONDARY_PREFIX, 'SINV-'); }
    public static Boolean enforceCredit()      { return getBool(KEY_ENFORCE_CREDIT, true); }
    public static Boolean fefoEnabled()        { return getBool(KEY_FEFO_ENABLED, true); }

    /** All DMS settings as a key→value map (for the portal/admin to read at once). */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getAll() {
        Map<String, String> m = new Map<String, String>();
        for (App_Config__mdt c : load().values()) {
            m.put(c.Config_Key__c, c.Config_Value__c);
        }
        // Ensure the well-known keys always resolve (defaults) for the UI.
        putDefault(m, KEY_LOW_STOCK_THRESHOLD, String.valueOf(lowStockThreshold()));
        putDefault(m, KEY_NEAR_EXPIRY_DAYS, String.valueOf(nearExpiryDays()));
        putDefault(m, KEY_TIER_MODEL, tierModel());
        putDefault(m, KEY_DEFAULT_PERIOD, defaultPeriod());
        return m;
    }

    // ── Internals ─────────────────────────────────────────────────────────
    @TestVisible private static Map<String, String> overrides; // test hook
    private static Map<String, App_Config__mdt> cache;

    private static Map<String, App_Config__mdt> load() {
        if (cache == null) {
            cache = new Map<String, App_Config__mdt>();
            for (App_Config__mdt c : [
                SELECT Config_Key__c, Config_Value__c, Data_Type__c
                FROM App_Config__mdt WHERE Module__c = :MODULE
            ]) {
                if (String.isNotBlank(c.Config_Key__c)) { cache.put(c.Config_Key__c, c); }
            }
        }
        return cache;
    }

    private static String raw(String key) {
        if (overrides != null && overrides.containsKey(key)) { return overrides.get(key); }
        App_Config__mdt c = load().get(key);
        return c != null ? c.Config_Value__c : null;
    }

    private static void putDefault(Map<String, String> m, String k, String v) {
        if (!m.containsKey(k)) { m.put(k, v); }
    }
}