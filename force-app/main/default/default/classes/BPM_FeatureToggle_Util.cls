/**
 * @description Utility class for checking BPM feature toggle status.
 *              Queries Feature_Toggle__mdt custom metadata and caches results
 *              for the duration of the transaction.
 * @author  SFA Development Team
 * @date    2024
 */
public class BPM_FeatureToggle_Util {

    @TestVisible
    private static Map<String, Boolean> toggleCache = new Map<String, Boolean>();

    /**
     * @description Checks if a feature is enabled by its Feature_Code__c value.
     * @param featureCode The feature code (e.g., 'BPM-001', 'BPM-002')
     * @return True if the feature is enabled, false otherwise or if not found.
     */
    public static Boolean isEnabled(String featureCode) {
        if (toggleCache.containsKey(featureCode)) {
            return toggleCache.get(featureCode);
        }

        List<Feature_Toggle__mdt> toggles = [
            SELECT Is_Enabled__c
            FROM Feature_Toggle__mdt
            WHERE Feature_Code__c = :featureCode
            LIMIT 1
        ];

        Boolean enabled = !toggles.isEmpty() && toggles[0].Is_Enabled__c;
        toggleCache.put(featureCode, enabled);
        return enabled;
    }

    /**
     * @description Clears the toggle cache. Useful for testing.
     */
    @TestVisible
    private static void clearCache() {
        toggleCache.clear();
    }
}