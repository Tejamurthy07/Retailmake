/**
 * @description Trigger handler for Beat_Outlet__c. Manages automatic rollup
 *              of Total_Outlets__c on the parent Beat__c record by counting
 *              active child Beat_Outlet__c records.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class BPM_BeatOutlet_TriggerHandler extends TriggerHandler {

    // ── Before Insert ───────────────────────────────────────────────────────

    protected override void beforeInsert() {
        List<Beat_Outlet__c> newRecords = (List<Beat_Outlet__c>) Trigger.new;
        validateUniqueness(newRecords, null);
    }

    // ── Before Update ───────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        List<Beat_Outlet__c> newRecords = (List<Beat_Outlet__c>) Trigger.new;
        Map<Id, Beat_Outlet__c> oldMap = (Map<Id, Beat_Outlet__c>) Trigger.oldMap;
        validateUniqueness(newRecords, oldMap);
    }

    // ── After Insert ────────────────────────────────────────────────────────

    protected override void afterInsert() {
        recalculateBeatOutletCounts(getAffectedBeatIds(Trigger.new, null));
    }

    // ── After Update ────────────────────────────────────────────────────────

    protected override void afterUpdate() {
        Map<Id, Beat_Outlet__c> oldMap = (Map<Id, Beat_Outlet__c>) Trigger.oldMap;
        Set<Id> affectedBeatIds = getAffectedBeatIds(Trigger.new, oldMap);
        if (!affectedBeatIds.isEmpty()) {
            recalculateBeatOutletCounts(affectedBeatIds);
        }
    }

    // ── After Delete ────────────────────────────────────────────────────────

    protected override void afterDelete() {
        recalculateBeatOutletCounts(getAffectedBeatIds(Trigger.old, null));
    }

    // ── Private helper methods ──────────────────────────────────────────────

    /**
     * @description Validates that the same Account is not assigned to the same Beat
     *              more than once (active records only). Checks both the incoming
     *              batch and existing database records.
     */
    private void validateUniqueness(List<Beat_Outlet__c> records, Map<Id, Beat_Outlet__c> oldMap) {
        Set<Id> beatIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();

        for (Beat_Outlet__c rec : records) {
            if (rec.Beat__c != null) beatIds.add(rec.Beat__c);
            if (rec.Account__c != null) accountIds.add(rec.Account__c);
        }

        if (beatIds.isEmpty() || accountIds.isEmpty()) return;

        // Query existing active assignments
        Set<String> existingKeys = new Set<String>();
        for (Beat_Outlet__c existing : [
            SELECT Beat__c, Account__c
            FROM Beat_Outlet__c
            WHERE Beat__c IN :beatIds
              AND Account__c IN :accountIds
              AND Is_Active__c = true
        ]) {
            existingKeys.add(String.valueOf(existing.Beat__c) + '|' + String.valueOf(existing.Account__c));
        }

        // Check for duplicates (batch + database)
        Set<String> batchKeys = new Set<String>();
        for (Beat_Outlet__c rec : records) {
            if (rec.Beat__c == null || rec.Account__c == null || !rec.Is_Active__c) continue;

            // Skip if key fields unchanged on update
            if (oldMap != null && oldMap.get(rec.Id) != null) {
                Beat_Outlet__c oldRec = oldMap.get(rec.Id);
                if (oldRec.Beat__c == rec.Beat__c && oldRec.Account__c == rec.Account__c
                    && oldRec.Is_Active__c == rec.Is_Active__c) {
                    continue;
                }
            }

            String key = String.valueOf(rec.Beat__c) + '|' + String.valueOf(rec.Account__c);

            // Check within batch
            if (batchKeys.contains(key)) {
                rec.addError('This outlet is already assigned to this beat within the same batch.');
                continue;
            }
            batchKeys.add(key);

            // Check against existing (exclude self on update)
            if (existingKeys.contains(key)) {
                // On update, the record itself may be in the existing set
                if (oldMap == null || oldMap.get(rec.Id) == null) {
                    rec.addError('This outlet is already assigned to this beat.');
                } else {
                    Beat_Outlet__c oldRec = oldMap.get(rec.Id);
                    String oldKey = String.valueOf(oldRec.Beat__c) + '|' + String.valueOf(oldRec.Account__c);
                    if (oldKey != key) {
                        rec.addError('This outlet is already assigned to this beat.');
                    }
                }
            }
        }
    }

    private Set<Id> getAffectedBeatIds(List<SObject> records, Map<Id, Beat_Outlet__c> oldMap) {
        Set<Id> beatIds = new Set<Id>();
        for (SObject sobj : records) {
            Beat_Outlet__c rec = (Beat_Outlet__c) sobj;
            if (rec.Beat__c != null) {
                beatIds.add(rec.Beat__c);
            }
            // If beat was changed, also include the old beat
            if (oldMap != null) {
                Beat_Outlet__c oldRec = oldMap.get(rec.Id);
                if (oldRec != null && oldRec.Beat__c != null && oldRec.Beat__c != rec.Beat__c) {
                    beatIds.add(oldRec.Beat__c);
                }
            }
        }
        return beatIds;
    }

    private void recalculateBeatOutletCounts(Set<Id> beatIds) {
        if (beatIds.isEmpty()) {
            return;
        }

        // Count active outlets per beat
        Map<Id, Integer> countByBeat = new Map<Id, Integer>();
        for (Id beatId : beatIds) {
            countByBeat.put(beatId, 0);
        }

        // Alias the grouped field (bid) so the AggregateResult key is
        // namespace-independent — in the ftretailmake managed package an
        // unaliased Beat__c comes back keyed as ftretailmake__Beat__c and
        // ar.get('Beat__c') throws "Invalid field Beat__c for AggregateResult".
        for (AggregateResult ar : [
            SELECT Beat__c bid, COUNT(Id) cnt
            FROM Beat_Outlet__c
            WHERE Beat__c IN :beatIds
              AND Is_Active__c = true
            GROUP BY Beat__c
        ]) {
            Id beatId = (Id) ar.get('bid');
            countByBeat.put(beatId, (Integer) ar.get('cnt'));
        }

        // Update parent beats
        List<Beat__c> beatsToUpdate = new List<Beat__c>();
        for (Id beatId : countByBeat.keySet()) {
            beatsToUpdate.add(new Beat__c(
                Id = beatId,
                Total_Outlets__c = countByBeat.get(beatId)
            ));
        }

        if (!beatsToUpdate.isEmpty()) {
            update beatsToUpdate;
        }
    }
}