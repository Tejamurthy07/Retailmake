/**
 * @description Trigger handler for Beat__c. Manages beat lifecycle including
 *              default population, beat code uniqueness validation, deprecated
 *              field synchronization, and deactivation protection.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class BPM_Beat_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        if (!BPM_FeatureToggle_Util.isEnabled('BPM-001')) {
            return;
        }
        List<Beat__c> newRecords = (List<Beat__c>) Trigger.new;
        setDefaults(newRecords);
        validateBeatCodeUniqueness(newRecords);
        syncDeprecatedFields(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled('BPM-001')) {
            return;
        }
        List<Beat__c> newRecords = (List<Beat__c>) Trigger.new;
        Map<Id, Beat__c> oldMap = (Map<Id, Beat__c>) Trigger.oldMap;
        syncDeprecatedFields(newRecords);
        validateBeatCodeUniqueness(newRecords);
        preventDeactivationWithFuturePlans(newRecords, oldMap);
    }

    // ── Private helper methods ──────────────────────────────────────────────

    private void setDefaults(List<Beat__c> records) {
        for (Beat__c rec : records) {
            if (rec.Is_Active__c == null) {
                rec.Is_Active__c = true;
            }
        }
    }

    private void syncDeprecatedFields(List<Beat__c> records) {
        for (Beat__c rec : records) {
            // Sync Day_of_Week__c -> Beat_Day__c (deprecated)
            if (rec.Day_of_Week__c != null) {
                rec.Beat_Day__c = rec.Day_of_Week__c;
            }
            // Sync Frequency__c -> Beat_Frequency__c (deprecated)
            if (rec.Frequency__c != null) {
                rec.Beat_Frequency__c = rec.Frequency__c;
            }
        }
    }

    private void validateBeatCodeUniqueness(List<Beat__c> records) {
        Set<String> newCodes = new Set<String>();
        for (Beat__c rec : records) {
            if (String.isNotBlank(rec.Beat_Code__c)) {
                if (newCodes.contains(rec.Beat_Code__c.toUpperCase())) {
                    rec.Beat_Code__c.addError('Duplicate Beat Code in this batch: ' + rec.Beat_Code__c);
                }
                newCodes.add(rec.Beat_Code__c.toUpperCase());
            }
        }

        if (newCodes.isEmpty()) {
            return;
        }

        // Check against existing records
        Set<Id> currentIds = new Set<Id>();
        for (Beat__c rec : records) {
            if (rec.Id != null) {
                currentIds.add(rec.Id);
            }
        }

        List<Beat__c> existing = [
            SELECT Id, Beat_Code__c
            FROM Beat__c
            WHERE Beat_Code__c IN :newCodes
              AND Id NOT IN :currentIds
        ];

        Set<String> existingCodes = new Set<String>();
        for (Beat__c ex : existing) {
            existingCodes.add(ex.Beat_Code__c.toUpperCase());
        }

        for (Beat__c rec : records) {
            if (String.isNotBlank(rec.Beat_Code__c) &&
                existingCodes.contains(rec.Beat_Code__c.toUpperCase())) {
                rec.Beat_Code__c.addError(
                    'Beat Code \'' + rec.Beat_Code__c + '\' is already in use. Please choose a unique code.'
                );
            }
        }
    }

    private void preventDeactivationWithFuturePlans(
        List<Beat__c> newRecords,
        Map<Id, Beat__c> oldMap
    ) {
        Set<Id> deactivatingBeatIds = new Set<Id>();
        for (Beat__c rec : newRecords) {
            Beat__c oldRec = oldMap.get(rec.Id);
            if (oldRec.Is_Active__c && !rec.Is_Active__c) {
                deactivatingBeatIds.add(rec.Id);
            }
        }

        if (deactivatingBeatIds.isEmpty()) {
            return;
        }

        // Auto-remove future journey plan days for deactivated beats
        List<Journey_Plan_Day__c> futureDays = [
            SELECT Id FROM Journey_Plan_Day__c
            WHERE Beat__c IN :deactivatingBeatIds
              AND Plan_Date__c >= TODAY
        ];
        if (!futureDays.isEmpty()) {
            delete futureDays;
        }
    }
}