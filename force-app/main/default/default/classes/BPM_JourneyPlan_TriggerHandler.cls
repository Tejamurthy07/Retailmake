/**
 * @description Trigger handler for Journey_Plan__c. Manages the journey plan
 *              lifecycle including default population, status transition
 *              enforcement, deprecated field synchronization, and effective
 *              date calculation.
 *
 * Status Flow:
 *   Draft -> Submitted -> Approved -> Active
 *                      -> Rejected -> Draft
 *   (Any non-terminal) -> Cancelled
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class BPM_JourneyPlan_TriggerHandler extends TriggerHandler {

    private static final Map<String, Set<String>> VALID_TRANSITIONS = new Map<String, Set<String>>{
        'Draft'     => new Set<String>{ 'Submitted', 'Cancelled' },
        'Submitted' => new Set<String>{ 'Approved', 'Rejected', 'Cancelled' },
        'Approved'  => new Set<String>{ 'Active', 'Cancelled' },
        'Rejected'  => new Set<String>{ 'Draft', 'Cancelled' },
        'Active'    => new Set<String>{ 'Cancelled' },
        'Cancelled' => new Set<String>()
    };

    private static final Map<String, Integer> MONTH_MAP = new Map<String, Integer>{
        'January' => 1, 'February' => 2, 'March' => 3, 'April' => 4,
        'May' => 5, 'June' => 6, 'July' => 7, 'August' => 8,
        'September' => 9, 'October' => 10, 'November' => 11, 'December' => 12
    };

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        if (!BPM_FeatureToggle_Util.isEnabled('BPM-002')) {
            return;
        }
        List<Journey_Plan__c> newRecords = (List<Journey_Plan__c>) Trigger.new;
        setDefaults(newRecords);
        syncDeprecatedFields(newRecords);
        calculateEffectiveDates(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled('BPM-002')) {
            return;
        }
        List<Journey_Plan__c> newRecords = (List<Journey_Plan__c>) Trigger.new;
        Map<Id, Journey_Plan__c> oldMap = (Map<Id, Journey_Plan__c>) Trigger.oldMap;
        validateStatusTransitions(newRecords, oldMap);
        syncDeprecatedFields(newRecords);
        handleApproval(newRecords, oldMap);
    }

    // ── Private helper methods ──────────────────────────────────────────────

    private void setDefaults(List<Journey_Plan__c> records) {
        for (Journey_Plan__c rec : records) {
            if (String.isBlank(rec.Status__c)) {
                rec.Status__c = 'Draft';
            }
            if (rec.Plan_Date__c == null) {
                rec.Plan_Date__c = Date.today();
            }
            if (rec.Total_Planned_Visits__c == null) {
                rec.Total_Planned_Visits__c = 0;
            }
            if (rec.Total_Planned_Days__c == null) {
                rec.Total_Planned_Days__c = 0;
            }
        }
    }

    private void syncDeprecatedFields(List<Journey_Plan__c> records) {
        for (Journey_Plan__c rec : records) {
            if (rec.Salesperson__c != null) {
                rec.User__c = rec.Salesperson__c;
            }
        }
    }

    private void calculateEffectiveDates(List<Journey_Plan__c> records) {
        for (Journey_Plan__c rec : records) {
            if (rec.Effective_From__c == null &&
                String.isNotBlank(rec.Month__c) &&
                String.isNotBlank(rec.Year__c)) {

                Integer monthNum = MONTH_MAP.get(rec.Month__c);
                Integer yearNum = Integer.valueOf(rec.Year__c);
                if (monthNum != null && yearNum != null) {
                    rec.Effective_From__c = Date.newInstance(yearNum, monthNum, 1);
                    rec.Effective_To__c = rec.Effective_From__c.addMonths(1).addDays(-1);
                }
            }
        }
    }

    private void validateStatusTransitions(
        List<Journey_Plan__c> newRecords,
        Map<Id, Journey_Plan__c> oldMap
    ) {
        for (Journey_Plan__c rec : newRecords) {
            Journey_Plan__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c == oldRec.Status__c) {
                continue;
            }

            String currentStatus = oldRec.Status__c;
            String newStatus = rec.Status__c;

            if (!VALID_TRANSITIONS.containsKey(currentStatus)) {
                rec.Status__c.addError(
                    'Unknown current status: ' + currentStatus + '. Cannot determine valid transitions.'
                );
                continue;
            }

            Set<String> allowedNext = VALID_TRANSITIONS.get(currentStatus);
            if (!allowedNext.contains(newStatus)) {
                rec.Status__c.addError(
                    'Invalid status transition from \'' + currentStatus +
                    '\' to \'' + newStatus + '\'. Allowed transitions: ' +
                    String.join(new List<String>(allowedNext), ', ') + '.'
                );
            }
        }
    }

    private void handleApproval(
        List<Journey_Plan__c> newRecords,
        Map<Id, Journey_Plan__c> oldMap
    ) {
        for (Journey_Plan__c rec : newRecords) {
            Journey_Plan__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c == 'Approved' && oldRec.Status__c != 'Approved') {
                if (rec.Approval_Date__c == null) {
                    rec.Approval_Date__c = Date.today();
                }
                if (rec.Approved_By__c == null) {
                    rec.Approved_By__c = UserInfo.getUserId();
                }
            }
        }
    }
}