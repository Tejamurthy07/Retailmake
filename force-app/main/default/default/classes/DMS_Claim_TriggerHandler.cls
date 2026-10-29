/**
 * @description Trigger handler for Claim__c. On approval/settlement, stamps a
 *              credit-note number + approval date and posts a 'Credit Note'
 *              ledger entry for the distributor (via DMS_Ledger_Service).
 *              Inert unless the DMS master + scheme/claim toggles are enabled.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_Claim_TriggerHandler extends TriggerHandler {

    private static final Set<String> SETTLED_STATUSES = new Set<String>{
        'Approved', 'Partially Approved', 'Settled'
    };

    protected override void beforeUpdate() {
        if (!enabled()) {
            return;
        }
        Map<Id, Claim__c> oldMap = (Map<Id, Claim__c>) Trigger.oldMap;
        for (Claim__c claim : (List<Claim__c>) Trigger.new) {
            if (isNewlySettled(claim, oldMap.get(claim.Id))) {
                if (String.isBlank(claim.Credit_Note_Number__c)) {
                    claim.Credit_Note_Number__c = 'CN-' + String.valueOf(Datetime.now().getTime());
                }
                if (claim.Approval_Date__c == null) {
                    claim.Approval_Date__c = Date.today();
                }
            }
        }
    }

    protected override void afterUpdate() {
        if (!enabled()) {
            return;
        }
        Map<Id, Claim__c> oldMap = (Map<Id, Claim__c>) Trigger.oldMap;
        List<DMS_Ledger_Service.CreditNoteRequest> requests =
            new List<DMS_Ledger_Service.CreditNoteRequest>();

        for (Claim__c claim : (List<Claim__c>) Trigger.new) {
            if (!isNewlySettled(claim, oldMap.get(claim.Id)) || claim.Account__c == null) {
                continue;
            }
            // Reconcile scheme claims against open accruals (marks them Claimed).
            if (claim.Scheme__c != null) {
                DMS_SchemeAccrual_Service.reconcileClaim(claim);
            }
            Decimal amount = claim.Approved_Amount__c != null && claim.Approved_Amount__c > 0
                ? claim.Approved_Amount__c
                : (claim.Total_Amount__c != null ? claim.Total_Amount__c : 0);
            if (amount <= 0) {
                continue;
            }
            requests.add(new DMS_Ledger_Service.CreditNoteRequest(
                claim.Account__c, amount, 'Claim', claim.Id, claim.Credit_Note_Number__c,
                'Claim settlement credit note' +
                    (String.isNotBlank(claim.Claim_Type__c) ? ' (' + claim.Claim_Type__c + ')' : '')
            ));
        }

        if (!requests.isEmpty()) {
            DMS_Ledger_Service.postCreditNotes(requests);
        }
    }

    private Boolean isNewlySettled(Claim__c claim, Claim__c oldClaim) {
        return SETTLED_STATUSES.contains(claim.Status__c) &&
               (oldClaim == null || !SETTLED_STATUSES.contains(oldClaim.Status__c));
    }

    private Boolean enabled() {
        return BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) &&
               BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_SCHEME_CLAIM);
    }
}