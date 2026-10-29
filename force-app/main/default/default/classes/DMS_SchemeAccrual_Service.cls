/**
 * @description DMS scheme accrual. On primary invoices, accrues the distributor
 *              scheme payout (the pool that scheme claims later reconcile against)
 *              into Scheme_Accrual__c, and reconciles approved scheme claims back
 *              against open accruals. Gated by the DMS master + scheme/claim toggles.
 *
 *              Accrual is a transparent, primary-invoice-level computation
 *              (percentage or flat amount of invoice value for applicable active
 *              schemes); it deliberately does not reuse the order-line scheme
 *              engine, which targets secondary/tertiary order evaluation.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_SchemeAccrual_Service {

    /**
     * @description Accrues scheme payouts for the given primary invoices.
     * @param invoiceValueById  Primary invoice id -> invoice value.
     * @param accountByInvoice  Primary invoice id -> distributor account id.
     */
    public static void accrueForPrimaryInvoices(
        Map<Id, Decimal> invoiceValueById, Map<Id, Id> accountByInvoice
    ) {
        if (!enabled() || invoiceValueById == null || invoiceValueById.isEmpty()) {
            return;
        }

        // Distributor channel/region for applicability matching.
        Set<Id> accountIds = new Set<Id>(accountByInvoice.values());
        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Channel__c, Region__c FROM Account WHERE Id IN :accountIds
        ]);

        List<Scheme__c> activeSchemes = [
            SELECT Id, Applicable_Channel__c, Applicable_Region__c, Discount_Percent__c,
                   Discount_Amount__c, Max_Discount_Cap__c, Invoice_Val_Threshold__c
            FROM Scheme__c
            WHERE Is_Active__c = true
              AND (Start_Date__c = null OR Start_Date__c <= TODAY)
              AND (End_Date__c = null OR End_Date__c >= TODAY)
        ];
        if (activeSchemes.isEmpty()) {
            return;
        }

        List<Scheme_Accrual__c> accruals = new List<Scheme_Accrual__c>();
        for (Id invoiceId : invoiceValueById.keySet()) {
            Id accountId = accountByInvoice.get(invoiceId);
            Account acct = accounts.get(accountId);
            if (acct == null) {
                continue;
            }
            Decimal invoiceValue = invoiceValueById.get(invoiceId);
            if (invoiceValue == null || invoiceValue <= 0) {
                continue;
            }

            for (Scheme__c sch : activeSchemes) {
                if (!isApplicable(sch, acct, invoiceValue)) {
                    continue;
                }
                Decimal accrued = computeAccrual(sch, invoiceValue);
                if (accrued <= 0) {
                    continue;
                }
                accruals.add(new Scheme_Accrual__c(
                    Account__c       = accountId,
                    Scheme__c        = sch.Id,
                    Invoice__c       = invoiceId,
                    Accrued_Amount__c = accrued,
                    Accrual_Date__c  = Date.today(),
                    Status__c        = DMS_Constants.ACCRUAL_OPEN
                ));
            }
        }

        if (!accruals.isEmpty()) {
            insert accruals;
        }
    }

    /**
     * @description Reconciles an approved scheme claim against the distributor's
     *              open accruals for the same scheme: marks matched accruals as
     *              Claimed and links them to the claim.
     * @param claim Approved claim with Account + Scheme populated.
     * @return Total accrued amount reconciled.
     */
    public static Decimal reconcileClaim(Claim__c claim) {
        if (!enabled() || claim == null || claim.Account__c == null || claim.Scheme__c == null) {
            return 0;
        }
        List<Scheme_Accrual__c> open = [
            SELECT Id, Accrued_Amount__c
            FROM Scheme_Accrual__c
            WHERE Account__c = :claim.Account__c
              AND Scheme__c = :claim.Scheme__c
              AND Status__c = :DMS_Constants.ACCRUAL_OPEN
        ];
        if (open.isEmpty()) {
            return 0;
        }
        Decimal total = 0;
        for (Scheme_Accrual__c a : open) {
            a.Status__c = DMS_Constants.ACCRUAL_CLAIMED;
            a.Claim__c = claim.Id;
            total += a.Accrued_Amount__c != null ? a.Accrued_Amount__c : 0;
        }
        update open;
        return total;
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static Boolean isApplicable(Scheme__c sch, Account acct, Decimal invoiceValue) {
        if (String.isNotBlank(sch.Applicable_Channel__c) &&
            sch.Applicable_Channel__c != acct.Channel__c) {
            return false;
        }
        if (String.isNotBlank(sch.Applicable_Region__c) &&
            sch.Applicable_Region__c != acct.Region__c) {
            return false;
        }
        if (sch.Invoice_Val_Threshold__c != null &&
            invoiceValue < sch.Invoice_Val_Threshold__c) {
            return false;
        }
        return true;
    }

    private static Decimal computeAccrual(Scheme__c sch, Decimal invoiceValue) {
        Decimal accrued = 0;
        if (sch.Discount_Percent__c != null && sch.Discount_Percent__c > 0) {
            accrued = invoiceValue * sch.Discount_Percent__c / 100;
        } else if (sch.Discount_Amount__c != null && sch.Discount_Amount__c > 0) {
            accrued = sch.Discount_Amount__c;
        }
        if (sch.Max_Discount_Cap__c != null && sch.Max_Discount_Cap__c > 0 &&
            accrued > sch.Max_Discount_Cap__c) {
            accrued = sch.Max_Discount_Cap__c;
        }
        return accrued;
    }

    private static Boolean enabled() {
        return BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) &&
               BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_SCHEME_CLAIM);
    }
}