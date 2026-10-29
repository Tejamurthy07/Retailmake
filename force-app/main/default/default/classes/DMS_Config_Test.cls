/**
 * @description Tests for DMS_Config: built-in defaults, typed parsing, and
 *              metadata overrides via the test hook.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_Config_Test {

    @isTest
    static void defaults_apply() {
        System.assertEquals(25, DMS_Config.lowStockThreshold(), 'Default low-stock threshold');
        System.assertEquals(30, DMS_Config.nearExpiryDays(), 'Default near-expiry days');
        System.assertEquals(true, DMS_Config.isThreeTier(), 'Default tier model is three-tier');
        System.assertEquals('PINV-', DMS_Config.primaryPrefix(), 'Default primary prefix');
        System.assertEquals(true, DMS_Config.enforceCredit(), 'Credit enforced by default');
    }

    @isTest
    static void overrides_apply_and_badValuesFallBack() {
        DMS_Config.overrides = new Map<String, String>{
            DMS_Config.KEY_LOW_STOCK_THRESHOLD => '50',
            DMS_Config.KEY_TIER_MODEL => 'TWO_TIER',
            DMS_Config.KEY_ENFORCE_CREDIT => 'false',
            DMS_Config.KEY_SECONDARY_PREFIX => 'SEC-'
        };
        System.assertEquals(50, DMS_Config.lowStockThreshold(), 'Override applied');
        System.assertEquals(false, DMS_Config.isThreeTier(), 'Two-tier override');
        System.assertEquals(false, DMS_Config.enforceCredit(), 'Credit disabled by config');
        System.assertEquals('SEC-', DMS_Config.secondaryPrefix(), 'Prefix override');

        // Non-numeric value falls back to the built-in default.
        DMS_Config.overrides.put(DMS_Config.KEY_NEAR_EXPIRY_DAYS, 'oops');
        System.assertEquals(30, DMS_Config.nearExpiryDays(), 'Bad value falls back to default');

        Map<String, String> all = DMS_Config.getAll();
        System.assert(all.containsKey(DMS_Config.KEY_TIER_MODEL), 'getAll exposes well-known keys');
    }
}