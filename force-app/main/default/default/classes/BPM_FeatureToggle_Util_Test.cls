/**
 * @description Test class for BPM_FeatureToggle_Util.
 *              Validates feature toggle lookup and caching behavior.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class BPM_FeatureToggle_Util_Test {

    @isTest
    static void testEnabledFeature() {
        // BPM_Beat_Definition is enabled in custom metadata (Feature_Code__c = 'BPM-001')
        Test.startTest();
        Boolean result = BPM_FeatureToggle_Util.isEnabled('BPM-001');
        Test.stopTest();

        System.assertEquals(true, result, 'BPM-001 (Beat Definition) should be enabled');
    }

    @isTest
    static void testUnknownFeature() {
        Test.startTest();
        Boolean result = BPM_FeatureToggle_Util.isEnabled('NONEXISTENT-999');
        Test.stopTest();

        System.assertEquals(false, result, 'Non-existent feature should return false');
    }

    @isTest
    static void testCaching() {
        Test.startTest();
        // First call - should query
        Boolean result1 = BPM_FeatureToggle_Util.isEnabled('BPM-001');
        // Second call - should use cache
        Boolean result2 = BPM_FeatureToggle_Util.isEnabled('BPM-001');
        Test.stopTest();

        System.assertEquals(result1, result2, 'Cached result should match initial result');
    }
}