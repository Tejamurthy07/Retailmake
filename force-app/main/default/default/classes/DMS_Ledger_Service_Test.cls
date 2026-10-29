/**
 * @description Tests for DMS_Ledger_Service — credit-note posting, the running
 * balance authority, and AR aging.
 *
 * Two behaviours carry real money risk and get the most attention here:
 *
 *   1. Sign convention. A credit note must reduce receivables, so it posts to
 *      Credit_Amount__c and the running balance subtracts it. Flip that and
 *      every distributor statement overstates what they owe.
 *   2. The running balance is cumulative and chronological, and this method is
 *      described as the single authority for it — invoices, collections,
 *      returns and credit notes all post through different handlers and then
 *      call back here. So the ordering and the per-account isolation matter
 *      more than any individual entry.
 *
 * Note on fixtures: inserting an Invoice__c fires Invoice_Trigger, whose
 * afterInsert calls DMS_InvoiceLedger_Service.syncInvoiceEntries and creates
 * ledger rows of its own. The running-balance tests therefore build
 * Ledger_Entry__c records directly and never insert an invoice, so the numbers
 * under test are only the ones the test wrote.
 */
@isTest
private class DMS_Ledger_Service_Test {

    @testSetup
    static void setupTestData() {
        insert new List<Account>{
            TestDataFactory.createAccount('LED Distributor A', 'Distributor'),
            TestDataFactory.createAccount('LED Distributor B', 'Distributor')
        };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> accounts() {
        Map<String, Id> byName = new Map<String, Id>();
        for (Account a : [SELECT Id, Name FROM Account WHERE Name LIKE 'LED Distributor%']) {
            byName.put(a.Name, a.Id);
        }
        return byName;
    }

    private static Id accA() { return accounts().get('LED Distributor A'); }
    private static Id accB() { return accounts().get('LED Distributor B'); }

    private static Ledger_Entry__c entry(Id accountId, Decimal debit, Decimal credit, Date entryDate) {
        return new Ledger_Entry__c(
            Account__c = accountId,
            Entry_Type__c = debit != null && debit > 0 ? 'Invoice' : 'Payment',
            Debit_Amount__c = debit,
            Credit_Amount__c = credit,
            Amount__c = debit != null ? debit : credit,
            Entry_Date__c = entryDate,
            Status__c = 'Posted'
        );
    }

    private static Invoice__c invoice(Id accountId, String invoiceNumber, Decimal balance, Date dueDate) {
        return new Invoice__c(
            Account__c = accountId,
            Invoice_Number__c = invoiceNumber,
            Invoice_Date__c = Date.today(),
            Due_Date__c = dueDate,
            Balance_Due__c = balance,
            Total_Amount__c = balance,
            Status__c = 'Draft'
        );
    }

    private static Map<Id, Decimal> balancesByEntryId(Id accountId) {
        Map<Id, Decimal> byId = new Map<Id, Decimal>();
        for (Ledger_Entry__c e : [
            SELECT Id, Running_Balance__c FROM Ledger_Entry__c WHERE Account__c = :accountId
        ]) {
            byId.put(e.Id, e.Running_Balance__c);
        }
        return byId;
    }

    // ── postCreditNotes ───────────────────────────────────────────────

    @isTest
    static void postCreditNotes_withNoRequests_doesNothing() {
        Test.startTest();
        DMS_Ledger_Service.postCreditNotes(null);
        DMS_Ledger_Service.postCreditNotes(new List<DMS_Ledger_Service.CreditNoteRequest>());
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Ledger_Entry__c],
            'Nothing to post means no ledger rows and no DML');
    }

    @isTest
    static void postCreditNotes_writesACreditThatReducesReceivables() {
        Id acc = accA();

        Test.startTest();
        DMS_Ledger_Service.postCreditNotes(new List<DMS_Ledger_Service.CreditNoteRequest>{
            new DMS_Ledger_Service.CreditNoteRequest(
                acc, 1500, 'Claim', acc, 'CLM-0001', 'Damage claim settlement')
        });
        Test.stopTest();

        List<Ledger_Entry__c> posted = [
            SELECT Entry_Type__c, Amount__c, Credit_Amount__c, Debit_Amount__c,
                   Reference_Type__c, Reference_Id__c, Reference_Number__c,
                   Entry_Date__c, Description__c, Status__c, Running_Balance__c
            FROM Ledger_Entry__c WHERE Account__c = :acc
        ];
        System.assertEquals(1, posted.size(), 'One request, one entry');
        Ledger_Entry__c e = posted[0];
        System.assertEquals('Credit Note', e.Entry_Type__c, 'Typed as a credit note');
        System.assertEquals(1500, e.Amount__c, 'Face value recorded');
        System.assertEquals(1500, e.Credit_Amount__c,
            'A credit note is a CREDIT — posting it as a debit would inflate what the '
            + 'distributor owes');
        System.assertEquals(0, e.Debit_Amount__c, 'And never a debit');
        System.assertEquals(-1500, e.Running_Balance__c,
            'The running balance is recomputed on the way out, so the credit lands immediately');
        System.assertEquals('Claim', e.Reference_Type__c, 'Source type kept for the audit trail');
        System.assertEquals('CLM-0001', e.Reference_Number__c, 'Source number kept');
        System.assertEquals(Date.today(), e.Entry_Date__c, 'Dated today');
        System.assertEquals('Posted', e.Status__c, 'Posted, not left pending');
    }

    @isTest
    static void postCreditNotes_skipsRequestsThatCarryNoMoney() {
        Id acc = accA();

        Test.startTest();
        DMS_Ledger_Service.postCreditNotes(new List<DMS_Ledger_Service.CreditNoteRequest>{
            new DMS_Ledger_Service.CreditNoteRequest(null, 100, 'Claim', null, 'NO-ACCOUNT', ''),
            new DMS_Ledger_Service.CreditNoteRequest(acc, null, 'Claim', null, 'NO-AMOUNT', ''),
            new DMS_Ledger_Service.CreditNoteRequest(acc, 0, 'Claim', null, 'ZERO', ''),
            new DMS_Ledger_Service.CreditNoteRequest(acc, -50, 'Claim', null, 'NEGATIVE', '')
        });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Ledger_Entry__c],
            'A request with no account, no amount, or a non-positive amount is dropped — '
            + 'a negative credit note would silently become a debit');
    }

    @isTest
    static void postCreditNotes_postsOnlyTheValidRowsOfAMixedBatch() {
        Id acc = accA();

        Test.startTest();
        DMS_Ledger_Service.postCreditNotes(new List<DMS_Ledger_Service.CreditNoteRequest>{
            new DMS_Ledger_Service.CreditNoteRequest(acc, 200, 'Claim', null, 'GOOD-1', ''),
            new DMS_Ledger_Service.CreditNoteRequest(acc, 0, 'Claim', null, 'BAD', ''),
            new DMS_Ledger_Service.CreditNoteRequest(acc, 300, 'Claim', null, 'GOOD-2', '')
        });
        Test.stopTest();

        List<Ledger_Entry__c> posted = [
            SELECT Reference_Number__c FROM Ledger_Entry__c WHERE Account__c = :acc
            ORDER BY Reference_Number__c
        ];
        System.assertEquals(2, posted.size(), 'One bad row does not block the good ones');
        System.assertEquals('GOOD-1', posted[0].Reference_Number__c, 'First valid row posted');
        System.assertEquals('GOOD-2', posted[1].Reference_Number__c, 'Second valid row posted');
    }

    @isTest
    static void postCreditNotes_recalculatesEachAffectedAccountSeparately() {
        Id a = accA();
        Id b = accB();
        insert new List<Ledger_Entry__c>{
            entry(a, 1000, 0, Date.today().addDays(-10)),
            entry(b, 400, 0, Date.today().addDays(-10))
        };

        Test.startTest();
        DMS_Ledger_Service.postCreditNotes(new List<DMS_Ledger_Service.CreditNoteRequest>{
            new DMS_Ledger_Service.CreditNoteRequest(a, 250, 'Claim', null, 'CN-A', ''),
            new DMS_Ledger_Service.CreditNoteRequest(b, 100, 'Claim', null, 'CN-B', '')
        });
        Test.stopTest();

        System.assertEquals(750, [
            SELECT Running_Balance__c FROM Ledger_Entry__c
            WHERE Account__c = :a AND Reference_Number__c = 'CN-A'
        ].Running_Balance__c, 'Distributor A: 1000 owed less a 250 credit');
        System.assertEquals(300, [
            SELECT Running_Balance__c FROM Ledger_Entry__c
            WHERE Account__c = :b AND Reference_Number__c = 'CN-B'
        ].Running_Balance__c, 'Distributor B is computed on its own ledger, not the combined one');
    }

    // ── recalculateRunningBalance ─────────────────────────────────────

    @isTest
    static void recalculate_withNoAccounts_doesNothing() {
        insert entry(accA(), 500, 0, Date.today());

        Test.startTest();
        DMS_Ledger_Service.recalculateRunningBalance(null);
        DMS_Ledger_Service.recalculateRunningBalance(new Set<Id>());
        Test.stopTest();

        System.assertEquals(null, [
            SELECT Running_Balance__c FROM Ledger_Entry__c WHERE Account__c = :accA()
        ].Running_Balance__c, 'No accounts asked for means nothing recomputed');
    }

    @isTest
    static void recalculate_accumulatesDebitsAndCreditsInDateOrder() {
        Id acc = accA();
        insert new List<Ledger_Entry__c>{
            entry(acc, 1000, 0, Date.today().addDays(-30)),  // invoice   -> 1000
            entry(acc, 0, 400, Date.today().addDays(-20)),   // payment   ->  600
            entry(acc, 500, 0, Date.today().addDays(-10)),   // invoice   -> 1100
            entry(acc, 0, 100, Date.today())                 // credit    -> 1000
        };

        Test.startTest();
        DMS_Ledger_Service.recalculateRunningBalance(new Set<Id>{ acc });
        Test.stopTest();

        List<Ledger_Entry__c> ledger = [
            SELECT Running_Balance__c FROM Ledger_Entry__c
            WHERE Account__c = :acc ORDER BY Entry_Date__c ASC
        ];
        System.assertEquals(1000, ledger[0].Running_Balance__c, 'Opening invoice');
        System.assertEquals(600, ledger[1].Running_Balance__c, 'Payment reduces the balance');
        System.assertEquals(1100, ledger[2].Running_Balance__c, 'Second invoice adds to it');
        System.assertEquals(1000, ledger[3].Running_Balance__c, 'Credit note reduces it again');
    }

    @isTest
    static void recalculate_treatsMissingAmountsAsZero() {
        Id acc = accA();
        insert new List<Ledger_Entry__c>{
            entry(acc, 800, null, Date.today().addDays(-5)),
            entry(acc, null, 300, Date.today())
        };

        Test.startTest();
        DMS_Ledger_Service.recalculateRunningBalance(new Set<Id>{ acc });
        Test.stopTest();

        List<Ledger_Entry__c> ledger = [
            SELECT Running_Balance__c FROM Ledger_Entry__c
            WHERE Account__c = :acc ORDER BY Entry_Date__c ASC
        ];
        System.assertEquals(800, ledger[0].Running_Balance__c,
            'A blank credit side counts as zero, not as a broken sum');
        System.assertEquals(500, ledger[1].Running_Balance__c, 'And a blank debit side likewise');
    }

    @isTest
    static void recalculate_leavesOtherAccountsAlone() {
        Id a = accA();
        Id b = accB();
        insert new List<Ledger_Entry__c>{
            entry(a, 1000, 0, Date.today()),
            entry(b, 700, 0, Date.today())
        };

        Test.startTest();
        DMS_Ledger_Service.recalculateRunningBalance(new Set<Id>{ a });
        Test.stopTest();

        System.assertEquals(1000, [
            SELECT Running_Balance__c FROM Ledger_Entry__c WHERE Account__c = :a
        ].Running_Balance__c, 'The requested account is recomputed');
        System.assertEquals(null, [
            SELECT Running_Balance__c FROM Ledger_Entry__c WHERE Account__c = :b
        ].Running_Balance__c, 'An account nobody asked about is not touched');
    }

    @isTest
    static void recalculate_isStableWhenRunTwice() {
        Id acc = accA();
        insert new List<Ledger_Entry__c>{
            entry(acc, 1000, 0, Date.today().addDays(-5)),
            entry(acc, 0, 250, Date.today())
        };
        DMS_Ledger_Service.recalculateRunningBalance(new Set<Id>{ acc });
        Map<Id, Decimal> afterFirst = balancesByEntryId(acc);

        Test.startTest();
        DMS_Ledger_Service.recalculateRunningBalance(new Set<Id>{ acc });
        Test.stopTest();

        Map<Id, Decimal> afterSecond = balancesByEntryId(acc);
        System.assertEquals(afterFirst.size(), afterSecond.size(), 'Same entries');
        for (Id entryId : afterFirst.keySet()) {
            System.assertEquals(afterFirst.get(entryId), afterSecond.get(entryId),
                'Recomputing an already-correct ledger changes nothing — the method skips '
                + 'rows whose balance already matches, so a repeat run is not a mass update');
        }
    }

    @isTest
    static void recalculate_handlesAnAccountWithNoEntries() {
        Test.startTest();
        DMS_Ledger_Service.recalculateRunningBalance(new Set<Id>{ accA() });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Ledger_Entry__c],
            'An empty ledger is not an error');
    }

    // ── getAging ──────────────────────────────────────────────────────

    @isTest
    static void aging_withNullAccount_returnsAllBucketsAtZero() {
        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAging(null);
        Test.stopTest();

        System.assertEquals(5, buckets.size(), 'Every bucket is present so the UI can render it');
        for (String bucket : buckets.keySet()) {
            System.assertEquals(0, buckets.get(bucket), bucket + ' starts at zero');
        }
    }

    @isTest
    static void aging_placesEachInvoiceInTheRightBucketAtTheBoundaries() {
        Id acc = accA();
        // One invoice of 100 at each boundary the bucketing switches on.
        insert new List<Invoice__c>{
            invoice(acc, 'AGE-FUTURE', 100, Date.today().addDays(10)),
            invoice(acc, 'AGE-000', 100, Date.today()),
            invoice(acc, 'AGE-001', 100, Date.today().addDays(-1)),
            invoice(acc, 'AGE-030', 100, Date.today().addDays(-30)),
            invoice(acc, 'AGE-031', 100, Date.today().addDays(-31)),
            invoice(acc, 'AGE-060', 100, Date.today().addDays(-60)),
            invoice(acc, 'AGE-061', 100, Date.today().addDays(-61)),
            invoice(acc, 'AGE-090', 100, Date.today().addDays(-90)),
            invoice(acc, 'AGE-091', 100, Date.today().addDays(-91))
        };

        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAging(acc);
        Test.stopTest();

        System.assertEquals(200, buckets.get(DMS_Ledger_Service.BUCKET_CURRENT),
            'Not yet due and due today are both Current');
        System.assertEquals(200, buckets.get(DMS_Ledger_Service.BUCKET_1_30),
            'Day 1 and day 30 are the ends of the first overdue bucket');
        System.assertEquals(200, buckets.get(DMS_Ledger_Service.BUCKET_31_60),
            'Day 31 and day 60');
        System.assertEquals(200, buckets.get(DMS_Ledger_Service.BUCKET_61_90),
            'Day 61 and day 90');
        System.assertEquals(100, buckets.get(DMS_Ledger_Service.BUCKET_90_PLUS),
            'Day 91 tips into the worst bucket');
    }

    @isTest
    static void aging_fallsBackToInvoiceDateWhenNoDueDate() {
        Id acc = accA();
        Invoice__c noDueDate = invoice(acc, 'AGE-NO-DUE', 400, null);
        noDueDate.Invoice_Date__c = Date.today().addDays(-45);
        insert noDueDate;

        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAging(acc);
        Test.stopTest();

        System.assertEquals(400, buckets.get(DMS_Ledger_Service.BUCKET_31_60),
            'With no payment term agreed, the invoice date is when the clock started');
        System.assertEquals(0, buckets.get(DMS_Ledger_Service.BUCKET_CURRENT),
            'It is not treated as current just because a due date is missing');
    }

    @isTest
    static void aging_excludesCancelledAndSettledInvoices() {
        Id acc = accA();
        Invoice__c cancelled = invoice(acc, 'AGE-CANCELLED', 500, Date.today().addDays(-40));
        cancelled.Status__c = 'Cancelled';
        Invoice__c settled = invoice(acc, 'AGE-SETTLED', 0, Date.today().addDays(-40));
        Invoice__c live = invoice(acc, 'AGE-LIVE', 250, Date.today().addDays(-40));
        insert new List<Invoice__c>{ cancelled, settled, live };

        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAging(acc);
        Test.stopTest();

        System.assertEquals(250, buckets.get(DMS_Ledger_Service.BUCKET_31_60),
            'Only the live, unpaid invoice is chased — a cancelled one is not a receivable, '
            + 'and a zero balance is already settled');
    }

    @isTest
    static void aging_isScopedToOneDistributor() {
        insert new List<Invoice__c>{
            invoice(accA(), 'AGE-A', 100, Date.today().addDays(-10)),
            invoice(accB(), 'AGE-B', 900, Date.today().addDays(-10))
        };

        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAging(accA());
        Test.stopTest();

        System.assertEquals(100, buckets.get(DMS_Ledger_Service.BUCKET_1_30),
            'A statement shows one distributor debt, never the whole book');
    }

    // ── getAgingAll ───────────────────────────────────────────────────

    @isTest
    static void agingAll_sumsAcrossEveryDistributor() {
        insert new List<Invoice__c>{
            invoice(accA(), 'ALL-A1', 100, Date.today().addDays(-10)),
            invoice(accA(), 'ALL-A2', 250, Date.today().addDays(-45)),
            invoice(accB(), 'ALL-B1', 400, Date.today().addDays(-10)),
            invoice(accB(), 'ALL-B2', 700, Date.today().addDays(-120))
        };

        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAgingAll();
        Test.stopTest();

        System.assertEquals(500, buckets.get(DMS_Ledger_Service.BUCKET_1_30),
            'Both distributors 1-30 debt is combined for the internal view');
        System.assertEquals(250, buckets.get(DMS_Ledger_Service.BUCKET_31_60), '31-60 across the book');
        System.assertEquals(700, buckets.get(DMS_Ledger_Service.BUCKET_90_PLUS), '90+ across the book');
        System.assertEquals(0, buckets.get(DMS_Ledger_Service.BUCKET_CURRENT), 'Nothing is current');
    }

    @isTest
    static void agingAll_withNoOpenInvoices_returnsAllZeroes() {
        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAgingAll();
        Test.stopTest();

        System.assertEquals(5, buckets.size(), 'All five buckets are always returned');
        for (String bucket : buckets.keySet()) {
            System.assertEquals(0, buckets.get(bucket), bucket + ' is empty');
        }
    }

    @isTest
    static void agingAll_appliesTheSameExclusionsAsThePerAccountView() {
        Invoice__c cancelled = invoice(accA(), 'ALL-CANCELLED', 500, Date.today().addDays(-10));
        cancelled.Status__c = 'Cancelled';
        insert new List<Invoice__c>{
            cancelled,
            invoice(accB(), 'ALL-LIVE', 300, Date.today().addDays(-10))
        };

        Test.startTest();
        Map<String, Decimal> buckets = DMS_Ledger_Service.getAgingAll();
        Test.stopTest();

        System.assertEquals(300, buckets.get(DMS_Ledger_Service.BUCKET_1_30),
            'The org-wide view must not count cancelled invoices either');
    }
}