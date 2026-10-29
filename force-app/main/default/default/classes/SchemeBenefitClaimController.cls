/**
 * @description LWC-facing controller that lets customers (outlets/distributors)
 *              see and claim the scheme benefits they have accumulated:
 *
 *                - Reward-points wallet balance (redeemable via orders).
 *                - Open scheme accruals (distributor payout pool not yet claimed).
 *                - History of submitted claims.
 *
 *              Customers claim a scheme benefit by submitting a Claim__c, which
 *              the back office approves; on approval DMS_SchemeAccrual_Service
 *              reconciles it against the open accruals.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class SchemeBenefitClaimController {

    /**
     * @description Consolidated view of a customer's claimable scheme benefits.
     */
    public class BenefitSummary {
        @AuraEnabled public Decimal rewardPointsBalance;
        @AuraEnabled public Decimal openAccrualAmount;
        @AuraEnabled public List<Loyalty_Points__c> recentPoints;
        @AuraEnabled public List<Claim__c> recentClaims;
    }

    /**
     * @description Returns the benefit summary for a customer.
     * @param accountId The customer Account Id.
     */
    @AuraEnabled(cacheable=true)
    public static BenefitSummary getCustomerBenefitSummary(Id accountId) {
        BenefitSummary s = new BenefitSummary();
        s.rewardPointsBalance = 0;
        s.openAccrualAmount = 0;
        s.recentPoints = new List<Loyalty_Points__c>();
        s.recentClaims = new List<Claim__c>();

        if (accountId == null) {
            return s;
        }

        s.rewardPointsBalance = LoyaltyService.getBalance(accountId);
        s.recentPoints = LoyaltyService.getLedger(accountId, 10);

        AggregateResult ar = [
            SELECT SUM(Accrued_Amount__c) total
            FROM Scheme_Accrual__c
            WHERE Account__c = :accountId AND Status__c = 'Open'
        ];
        Decimal openTotal = (Decimal) ar.get('total');
        s.openAccrualAmount = openTotal == null ? 0 : openTotal;

        s.recentClaims = [
            SELECT Id, Name, Claim_Type__c, Status__c, Claim_Date__c,
                   Total_Amount__c, Approved_Amount__c, Scheme__c, Scheme__r.Name
            FROM Claim__c
            WHERE Account__c = :accountId
            ORDER BY Claim_Date__c DESC, CreatedDate DESC
            LIMIT 20
        ];

        return s;
    }

    /**
     * @description Submits a scheme benefit claim for a customer. The claim is
     *              created in 'Submitted' status for back-office approval.
     * @param accountId The customer Account Id (required).
     * @param schemeId  The scheme being claimed against (optional).
     * @param amount    The claimed amount (required, > 0).
     * @param notes     Optional supporting notes.
     * @return The inserted Claim__c record.
     */
    @AuraEnabled
    public static Claim__c submitSchemeClaim(
        Id accountId, Id schemeId, Decimal amount, String notes
    ) {
        if (accountId == null) {
            throw new AuraHandledException('Account is required to submit a claim.');
        }
        if (amount == null || amount <= 0) {
            throw new AuraHandledException('Claim amount must be greater than zero.');
        }
        try {
            Claim__c claim = new Claim__c(
                Account__c   = accountId,
                Scheme__c    = schemeId,
                Claim_Type__c = 'Scheme Claim',
                Status__c    = 'Submitted',
                Claim_Date__c = Date.today(),
                Total_Amount__c = amount,
                Notes__c     = notes
            );
            insert claim;
            return claim;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}