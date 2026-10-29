/**
 * @description DMS ledger & AR helpers. Posts distributor credit-note ledger
 *              entries (e.g. from approved claims) using the same Ledger_Entry__c
 *              pattern as collections/returns, and computes an AR aging statement
 *              from open invoices. Collections and returns continue to be posted
 *              by their existing handlers; this service does not duplicate them.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_Ledger_Service {

    /** Aging bucket keys. */
    public static final String BUCKET_CURRENT = 'Current';
    public static final String BUCKET_1_30    = '1-30';
    public static final String BUCKET_31_60   = '31-60';
    public static final String BUCKET_61_90   = '61-90';
    public static final String BUCKET_90_PLUS = '90+';

    /**
     * @description Posts a 'Credit Note' ledger entry for each given amount.
     * @param entries Ledger requests to post.
     */
    public static void postCreditNotes(List<CreditNoteRequest> entries) {
        if (entries == null || entries.isEmpty()) {
            return;
        }
        List<Ledger_Entry__c> ledger = new List<Ledger_Entry__c>();
        Set<Id> accountIds = new Set<Id>();
        for (CreditNoteRequest r : entries) {
            if (r.accountId == null || r.amount == null || r.amount <= 0) {
                continue;
            }
            ledger.add(new Ledger_Entry__c(
                Account__c        = r.accountId,
                Entry_Type__c     = 'Credit Note',
                Amount__c         = r.amount,
                // Unified convention: a credit note is a CREDIT (reduces AR).
                Credit_Amount__c  = r.amount,
                Debit_Amount__c   = 0,
                Reference_Type__c = r.referenceType,
                Reference_Id__c   = r.referenceId,
                Reference_Number__c = r.referenceNumber,
                Entry_Date__c     = Date.today(),
                Description__c    = r.description,
                Status__c         = 'Posted'
            ));
            accountIds.add(r.accountId);
        }
        if (!ledger.isEmpty()) {
            insert ledger;
            recalculateRunningBalance(accountIds);
        }
    }

    /**
     * @description Recomputes Running_Balance__c for every ledger entry of the
     *              given accounts, chronologically, as cumulative (debit - credit).
     *              This is the single authority for the running balance so all
     *              posting paths (invoice, collection, credit note, adjustment)
     *              stay coherent regardless of which one wrote the entry.
     * @param accountIds Accounts whose ledgers should be recomputed.
     */
    public static void recalculateRunningBalance(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return;
        }
        Map<Id, Decimal> runningByAccount = new Map<Id, Decimal>();
        List<Ledger_Entry__c> toUpdate = new List<Ledger_Entry__c>();
        for (Ledger_Entry__c e : [
            SELECT Id, Account__c, Debit_Amount__c, Credit_Amount__c, Running_Balance__c
            FROM Ledger_Entry__c
            WHERE Account__c IN :accountIds
            ORDER BY Entry_Date__c ASC, CreatedDate ASC
        ]) {
            Decimal bal = runningByAccount.containsKey(e.Account__c) ? runningByAccount.get(e.Account__c) : 0;
            Decimal debit = e.Debit_Amount__c != null ? e.Debit_Amount__c : 0;
            Decimal credit = e.Credit_Amount__c != null ? e.Credit_Amount__c : 0;
            bal = bal + debit - credit;
            runningByAccount.put(e.Account__c, bal);
            if (e.Running_Balance__c != bal) {
                e.Running_Balance__c = bal;
                toUpdate.add(e);
            }
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    /**
     * @description AR aging for a distributor, bucketed by how overdue each open
     *              invoice is (relative to Due_Date, falling back to Invoice_Date).
     * @param accountId The distributor account.
     * @return Map of bucket label to total open Balance_Due in that bucket.
     */
    public static Map<String, Decimal> getAging(Id accountId) {
        Map<String, Decimal> buckets = new Map<String, Decimal>{
            BUCKET_CURRENT => 0, BUCKET_1_30 => 0, BUCKET_31_60 => 0,
            BUCKET_61_90 => 0, BUCKET_90_PLUS => 0
        };
        if (accountId == null) {
            return buckets;
        }
        Date today = Date.today();
        for (Invoice__c inv : [
            SELECT Balance_Due__c, Due_Date__c, Invoice_Date__c
            FROM Invoice__c
            WHERE Account__c = :accountId
              AND Balance_Due__c > 0
              AND Status__c NOT IN ('Cancelled', 'Fully Paid')
        ]) {
            Date dueDate = inv.Due_Date__c != null ? inv.Due_Date__c : inv.Invoice_Date__c;
            Integer daysOverdue = (dueDate == null) ? 0 : dueDate.daysBetween(today);
            String bucket = bucketFor(daysOverdue);
            buckets.put(bucket, buckets.get(bucket) + inv.Balance_Due__c);
        }
        return buckets;
    }

    private static String bucketFor(Integer daysOverdue) {
        if (daysOverdue <= 0) { return BUCKET_CURRENT; }
        if (daysOverdue <= 30) { return BUCKET_1_30; }
        if (daysOverdue <= 60) { return BUCKET_31_60; }
        if (daysOverdue <= 90) { return BUCKET_61_90; }
        return BUCKET_90_PLUS;
    }

    /**
     * @description Org-wide AR aging across ALL open invoices (internal/admin view).
     */
    public static Map<String, Decimal> getAgingAll() {
        Map<String, Decimal> buckets = new Map<String, Decimal>{
            BUCKET_CURRENT => 0, BUCKET_1_30 => 0, BUCKET_31_60 => 0,
            BUCKET_61_90 => 0, BUCKET_90_PLUS => 0
        };
        Date today = Date.today();
        for (Invoice__c inv : [
            SELECT Balance_Due__c, Due_Date__c, Invoice_Date__c
            FROM Invoice__c
            WHERE Balance_Due__c > 0 AND Status__c NOT IN ('Cancelled', 'Fully Paid')
        ]) {
            Date dueDate = inv.Due_Date__c != null ? inv.Due_Date__c : inv.Invoice_Date__c;
            Integer daysOverdue = (dueDate == null) ? 0 : dueDate.daysBetween(today);
            String bucket = bucketFor(daysOverdue);
            buckets.put(bucket, buckets.get(bucket) + inv.Balance_Due__c);
        }
        return buckets;
    }

    /** Request payload for a credit-note ledger posting. */
    public class CreditNoteRequest {
        public Id accountId;
        public Decimal amount;
        public String referenceType;
        public Id referenceId;
        public String referenceNumber;
        public String description;

        public CreditNoteRequest(Id accountId, Decimal amount, String referenceType,
                                 Id referenceId, String referenceNumber, String description) {
            this.accountId = accountId;
            this.amount = amount;
            this.referenceType = referenceType;
            this.referenceId = referenceId;
            this.referenceNumber = referenceNumber;
            this.description = description;
        }
    }
}