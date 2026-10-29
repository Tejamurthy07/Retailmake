/**
 * @description Trigger handler for Scheme__c. Validates date ranges,
 *              detects overlapping schemes, and enforces status rules.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class SPM_Scheme_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        List<Scheme__c> newRecords = (List<Scheme__c>) Trigger.new;
        validateDateRanges(newRecords);
        validateBudget(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        List<Scheme__c> newRecords = (List<Scheme__c>) Trigger.new;
        Map<Id, Scheme__c> oldMap = (Map<Id, Scheme__c>) Trigger.oldMap;
        validateDateRanges(newRecords);
        validateBudget(newRecords);
        preventActiveSchemeFieldChanges(newRecords, oldMap);
    }

    // ── After Insert ──────────────────────────────────────────────────────────

    protected override void afterInsert() {
        List<Scheme__c> newRecords = (List<Scheme__c>) Trigger.new;
        detectOverlappingSchemes(newRecords);
    }

    // ── After Update ──────────────────────────────────────────────────────────

    protected override void afterUpdate() {
        List<Scheme__c> newRecords = (List<Scheme__c>) Trigger.new;
        Map<Id, Scheme__c> oldMap = (Map<Id, Scheme__c>) Trigger.oldMap;

        List<Scheme__c> dateChanged = new List<Scheme__c>();
        for (Scheme__c rec : newRecords) {
            Scheme__c oldRec = oldMap.get(rec.Id);
            if (rec.Start_Date__c != oldRec.Start_Date__c ||
                rec.End_Date__c != oldRec.End_Date__c) {
                dateChanged.add(rec);
            }
        }
        if (!dateChanged.isEmpty()) {
            detectOverlappingSchemes(dateChanged);
        }
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private void validateDateRanges(List<Scheme__c> records) {
        for (Scheme__c rec : records) {
            if (rec.Start_Date__c != null && rec.End_Date__c != null &&
                rec.Start_Date__c > rec.End_Date__c) {
                rec.End_Date__c.addError('End Date must be on or after Start Date.');
            }
        }
    }

    private void validateBudget(List<Scheme__c> records) {
        for (Scheme__c rec : records) {
            if (rec.Budget_Amount__c != null && rec.Budget_Amount__c <= 0) {
                rec.Budget_Amount__c.addError('Budget Amount must be greater than zero.');
            }
        }
    }

    private void preventActiveSchemeFieldChanges(List<Scheme__c> newRecords, Map<Id, Scheme__c> oldMap) {
        for (Scheme__c rec : newRecords) {
            Scheme__c oldRec = oldMap.get(rec.Id);
            if (oldRec.Status__c == 'Active' && rec.Status__c == 'Active') {
                if (rec.Scheme_Type__c != oldRec.Scheme_Type__c) {
                    rec.Scheme_Type__c.addError('Cannot change Scheme Type on an Active scheme.');
                }
                if (rec.Scheme_Category__c != oldRec.Scheme_Category__c) {
                    rec.Scheme_Category__c.addError('Cannot change Scheme Category on an Active scheme.');
                }
            }
        }
    }

    private void detectOverlappingSchemes(List<Scheme__c> records) {
        Set<String> schemeTypes = new Set<String>();
        Date minStart = Date.newInstance(2099, 12, 31);
        Date maxEnd = Date.newInstance(2000, 1, 1);
        Set<Id> currentIds = new Set<Id>();

        for (Scheme__c rec : records) {
            if (rec.Status__c == 'Active' || rec.Status__c == 'Pending Approval') {
                schemeTypes.add(rec.Scheme_Type__c);
                if (rec.Start_Date__c != null && rec.Start_Date__c < minStart) {
                    minStart = rec.Start_Date__c;
                }
                if (rec.End_Date__c != null && rec.End_Date__c > maxEnd) {
                    maxEnd = rec.End_Date__c;
                }
                currentIds.add(rec.Id);
            }
        }

        if (schemeTypes.isEmpty()) return;

        List<Scheme__c> overlapping = [
            SELECT Id, Name, Scheme_Code__c, Scheme_Type__c, Start_Date__c, End_Date__c
            FROM Scheme__c
            WHERE Scheme_Type__c IN :schemeTypes
              AND Status__c IN ('Active', 'Pending Approval')
              AND Start_Date__c <= :maxEnd
              AND End_Date__c >= :minStart
              AND Id NOT IN :currentIds
        ];

        if (!overlapping.isEmpty()) {
            Map<String, List<Scheme__c>> byType = new Map<String, List<Scheme__c>>();
            for (Scheme__c s : overlapping) {
                if (!byType.containsKey(s.Scheme_Type__c)) {
                    byType.put(s.Scheme_Type__c, new List<Scheme__c>());
                }
                byType.get(s.Scheme_Type__c).add(s);
            }

            for (Scheme__c rec : records) {
                if (byType.containsKey(rec.Scheme_Type__c)) {
                    for (Scheme__c existing : byType.get(rec.Scheme_Type__c)) {
                        if (rec.Start_Date__c <= existing.End_Date__c &&
                            rec.End_Date__c >= existing.Start_Date__c) {
                            rec.addError('Warning: This scheme overlaps with ' +
                                existing.Name + ' (' + existing.Scheme_Code__c +
                                ') for the date range ' + existing.Start_Date__c +
                                ' to ' + existing.End_Date__c + '.');
                        }
                    }
                }
            }
        }
    }
}