/**
 * @description Trigger handler for Journey_Plan_Day__c. Manages default values
 *              and automatic rollup of Total_Planned_Days__c and 
 *              Total_Planned_Visits__c on the parent Journey_Plan__c.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class BPM_JourneyPlanDay_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        List<Journey_Plan_Day__c> newRecords = (List<Journey_Plan_Day__c>) Trigger.new;
        setDefaults(newRecords);
    }

    // ── After Insert ────────────────────────────────────────────────────────

    protected override void afterInsert() {
        rollupToParentPlan(getAffectedPlanIds(Trigger.new, null));
    }

    // ── After Update ────────────────────────────────────────────────────────

    protected override void afterUpdate() {
        Set<Id> affectedPlanIds = getAffectedPlanIds(Trigger.new, (Map<Id, Journey_Plan_Day__c>) Trigger.oldMap);
        if (!affectedPlanIds.isEmpty()) {
            rollupToParentPlan(affectedPlanIds);
        }
    }

    // ── After Delete ────────────────────────────────────────────────────────

    protected override void afterDelete() {
        rollupToParentPlan(getAffectedPlanIds(Trigger.old, null));
    }

    // ── Private helper methods ──────────────────────────────────────────────

    private void setDefaults(List<Journey_Plan_Day__c> records) {
        // Collect beat IDs for name lookup
        Set<Id> beatIds = new Set<Id>();
        for (Journey_Plan_Day__c rec : records) {
            if (rec.Beat__c != null && String.isBlank(rec.Beat_Name__c)) {
                beatIds.add(rec.Beat__c);
            }
            if (String.isBlank(rec.Status__c)) {
                rec.Status__c = 'Planned';
            }
            if (rec.Planned_Outlets__c == null) {
                rec.Planned_Outlets__c = 0;
            }
            if (rec.Visited_Outlets__c == null) {
                rec.Visited_Outlets__c = 0;
            }
        }

        // Populate Beat_Name__c from Beat__r.Name
        if (!beatIds.isEmpty()) {
            Map<Id, Beat__c> beatMap = new Map<Id, Beat__c>([
                SELECT Id, Name FROM Beat__c WHERE Id IN :beatIds
            ]);
            for (Journey_Plan_Day__c rec : records) {
                if (rec.Beat__c != null && String.isBlank(rec.Beat_Name__c) &&
                    beatMap.containsKey(rec.Beat__c)) {
                    rec.Beat_Name__c = beatMap.get(rec.Beat__c).Name;
                }
            }
        }
    }

    private Set<Id> getAffectedPlanIds(List<SObject> records, Map<Id, Journey_Plan_Day__c> oldMap) {
        Set<Id> planIds = new Set<Id>();
        for (SObject sobj : records) {
            Journey_Plan_Day__c rec = (Journey_Plan_Day__c) sobj;
            if (rec.Journey_Plan__c != null) {
                planIds.add(rec.Journey_Plan__c);
            }
            if (oldMap != null) {
                Journey_Plan_Day__c oldRec = oldMap.get(rec.Id);
                if (oldRec != null && oldRec.Journey_Plan__c != null &&
                    oldRec.Journey_Plan__c != rec.Journey_Plan__c) {
                    planIds.add(oldRec.Journey_Plan__c);
                }
            }
        }
        return planIds;
    }

    private void rollupToParentPlan(Set<Id> planIds) {
        if (planIds.isEmpty()) {
            return;
        }

        // Calculate aggregates
        Map<Id, Integer> dayCount = new Map<Id, Integer>();
        Map<Id, Decimal> visitSum = new Map<Id, Decimal>();
        for (Id planId : planIds) {
            dayCount.put(planId, 0);
            visitSum.put(planId, 0);
        }

        // Alias the grouped field (pid) so the AggregateResult key is
        // namespace-independent — unaliased Journey_Plan__c comes back keyed as
        // ftretailmake__Journey_Plan__c in the managed package and ar.get throws.
        for (AggregateResult ar : [
            SELECT Journey_Plan__c pid, COUNT(Id) cnt, SUM(Planned_Outlets__c) totalVisits
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c IN :planIds
            GROUP BY Journey_Plan__c
        ]) {
            Id planId = (Id) ar.get('pid');
            dayCount.put(planId, (Integer) ar.get('cnt'));
            Decimal total = (Decimal) ar.get('totalVisits');
            visitSum.put(planId, total != null ? total : 0);
        }

        // Update parent plans
        List<Journey_Plan__c> plansToUpdate = new List<Journey_Plan__c>();
        for (Id planId : planIds) {
            plansToUpdate.add(new Journey_Plan__c(
                Id = planId,
                Total_Planned_Days__c = dayCount.get(planId),
                Total_Planned_Visits__c = visitSum.get(planId)
            ));
        }

        if (!plansToUpdate.isEmpty()) {
            update plansToUpdate;
        }
    }
}