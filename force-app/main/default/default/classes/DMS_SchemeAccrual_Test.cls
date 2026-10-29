/**
 * @description Tests for DMS scheme accrual on primary invoices and reconciliation
 *              of approved scheme claims against open accruals.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_SchemeAccrual_Test {

    private static void enableSchemeClaim() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SCHEME_CLAIM, true);
    }

    private static Scheme__c createPercentScheme(Decimal percent) {
        // Is_Active__c is a formula (Status = Active AND within date range), so drive
        // it via Status + dates rather than writing it directly.
        Scheme__c sch = new Scheme__c(
            Name = 'Primary 5pct',
            Scheme_Code__c = 'SCH-DMS-' + String.valueOf(Datetime.now().getTime()),
            Status__c = 'Active',
            Start_Date__c = Date.today().addDays(-1),
            End_Date__c = Date.today().addDays(30),
            Discount_Percent__c = percent,
            Budget_Amount__c = 1000000 // Scheme validation rule requires Budget Amount > 0
        );
        insert sch;
        return sch;
    }

    @isTest
    static void accruesPercentOfPrimaryInvoiceValue() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SA', 'Distributor');
        Scheme__c scheme = createPercentScheme(5);

        // A standalone primary invoice (value 1000) to accrue against.
        Invoice__c inv = new Invoice__c(
            Account__c = dist.Id, Order_Type__c = 'Primary', Invoice_Date__c = Date.today(),
            Invoice_Number__c = 'PINV-SA-1', Status__c = 'Draft', Total_Amount__c = 1000,
            Balance_Due__c = 1000
        );
        insert inv;

        enableSchemeClaim();
        Test.startTest();
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(
            new Map<Id, Decimal>{ inv.Id => 1000 },
            new Map<Id, Id>{ inv.Id => dist.Id });
        Test.stopTest();

        List<Scheme_Accrual__c> accruals = [
            SELECT Accrued_Amount__c, Status__c, Scheme__c FROM Scheme_Accrual__c WHERE Invoice__c = :inv.Id
        ];
        System.assertEquals(1, accruals.size(), 'One accrual for the applicable scheme');
        System.assertEquals(50, accruals[0].Accrued_Amount__c, '5% of 1000');
        System.assertEquals('Open', accruals[0].Status__c, 'Accrual is Open');
        System.assertEquals(scheme.Id, accruals[0].Scheme__c, 'Linked to scheme');
    }

    @isTest
    static void claimReconciliation_marksAccrualsClaimed() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SA2', 'Distributor');
        Scheme__c scheme = createPercentScheme(10);

        enableSchemeClaim();
        // Seed an open accrual directly.
        Scheme_Accrual__c accrual = new Scheme_Accrual__c(
            Account__c = dist.Id, Scheme__c = scheme.Id,
            Accrued_Amount__c = 200, Accrual_Date__c = Date.today(), Status__c = 'Open'
        );
        insert accrual;

        Claim__c claim = new Claim__c(
            Account__c = dist.Id, Scheme__c = scheme.Id, Claim_Type__c = 'Scheme Claim',
            Claim_Date__c = Date.today(), Total_Amount__c = 200, Status__c = 'Submitted'
        );
        insert claim;

        Test.startTest();
        update new Claim__c(Id = claim.Id, Status__c = 'Approved', Approved_Amount__c = 200);
        Test.stopTest();

        Scheme_Accrual__c after = [
            SELECT Status__c, Claim__c FROM Scheme_Accrual__c WHERE Id = :accrual.Id
        ];
        System.assertEquals('Claimed', after.Status__c, 'Accrual marked Claimed');
        System.assertEquals(claim.Id, after.Claim__c, 'Accrual linked to claim');

        // Claim settlement also posts a credit-note ledger entry (Phase 4 behavior).
        System.assertEquals(1, [SELECT COUNT() FROM Ledger_Entry__c WHERE Reference_Id__c = :claim.Id],
            'Credit-note ledger entry posted');
    }

    @isTest
    static void togglesOff_noAccrual() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SA3', 'Distributor');
        createPercentScheme(5);
        Invoice__c inv = new Invoice__c(
            Account__c = dist.Id, Order_Type__c = 'Primary', Invoice_Date__c = Date.today(),
            Invoice_Number__c = 'PINV-SA-3', Status__c = 'Draft', Total_Amount__c = 1000,
            Balance_Due__c = 1000
        );
        insert inv;

        // Explicitly disable in the cache (the org enables the DMS toggles as real
        // Feature_Toggle__mdt, which are visible in tests).
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SCHEME_CLAIM, false);
        Test.startTest();
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(
            new Map<Id, Decimal>{ inv.Id => 1000 },
            new Map<Id, Id>{ inv.Id => dist.Id });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Scheme_Accrual__c WHERE Invoice__c = :inv.Id],
            'No accrual when DMS disabled');
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage: applicability filters, accrual arithmetic and
    //  the reconciliation guard clauses.
    // ══════════════════════════════════════════════════════════════════

    private static Integer schemeSeq = 0;

    /** A scheme with no discount configured; callers set what they need. */
    private static Scheme__c newScheme() {
        schemeSeq++;
        return new Scheme__c(
            Name = 'SA Scheme ' + schemeSeq,
            Scheme_Code__c = 'SCH-SA-' + schemeSeq + '-' + String.valueOf(Datetime.now().getTime()),
            Status__c = 'Active',
            Start_Date__c = Date.today().addDays(-1),
            End_Date__c = Date.today().addDays(30),
            Budget_Amount__c = 1000000
        );
    }

    private static Invoice__c newInvoice(Id accountId, String invoiceNumber, Decimal amount) {
        Invoice__c inv = new Invoice__c(
            Account__c = accountId, Order_Type__c = 'Primary', Invoice_Date__c = Date.today(),
            Invoice_Number__c = invoiceNumber, Status__c = 'Draft',
            Total_Amount__c = amount, Balance_Due__c = amount
        );
        insert inv;
        return inv;
    }

    private static void accrue(Id invoiceId, Decimal value, Id accountId) {
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(
            new Map<Id, Decimal>{ invoiceId => value },
            new Map<Id, Id>{ invoiceId => accountId });
    }

    private static List<Scheme_Accrual__c> accrualsFor(Id invoiceId) {
        return [
            SELECT Accrued_Amount__c, Status__c, Scheme__c
            FROM Scheme_Accrual__c WHERE Invoice__c = :invoiceId
        ];
    }

    // ── Nothing to accrue against ─────────────────────────────────────

    @isTest
    static void noActiveSchemes_accruesNothing() {
        Account dist = TestDataFactory.createAndInsertAccount('SA None', 'Distributor');
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-NONE', 1000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 1000, dist.Id);
        Test.stopTest();

        System.assertEquals(0, accrualsFor(inv.Id).size(),
            'With no live scheme there is no pool to accrue into');
    }

    @isTest
    static void invoiceForAnUnknownAccountIsSkipped() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Ghost', 'Distributor');
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-GHOST', 1000);
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 5;
        insert sch;
        enableSchemeClaim();

        // The invoice maps to an account id that does not resolve — a stale
        // reference must be skipped rather than throwing mid-batch.
        Id ghost = Id.valueOf(Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        accrue(inv.Id, 1000, ghost);
        Test.stopTest();

        System.assertEquals(0, accrualsFor(inv.Id).size(), 'No account context, no accrual');
    }

    @isTest
    static void zeroOrNegativeInvoiceValueIsSkipped() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Zero', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 5;
        insert sch;
        Invoice__c zero = newInvoice(dist.Id, 'PINV-SA-ZERO', 0);
        Invoice__c negative = newInvoice(dist.Id, 'PINV-SA-NEG', 0);
        enableSchemeClaim();

        Test.startTest();
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(
            new Map<Id, Decimal>{ zero.Id => 0, negative.Id => -500 },
            new Map<Id, Id>{ zero.Id => dist.Id, negative.Id => dist.Id });
        Test.stopTest();

        System.assertEquals(0, accrualsFor(zero.Id).size(), 'A zero-value invoice accrues nothing');
        System.assertEquals(0, accrualsFor(negative.Id).size(),
            'And a credit-side value must never create a payout');
    }

    @isTest
    static void schemeWithNoDiscountConfiguredAccruesNothing() {
        Account dist = TestDataFactory.createAndInsertAccount('SA NoDisc', 'Distributor');
        insert newScheme(); // neither percent nor flat amount set
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-NODISC', 1000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 1000, dist.Id);
        Test.stopTest();

        System.assertEquals(0, accrualsFor(inv.Id).size(),
            'A scheme with no payout defined produces no accrual row rather than a zero one');
    }

    // ── Accrual arithmetic ────────────────────────────────────────────

    @isTest
    static void flatAmountSchemeAccruesTheFlatAmount() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Flat', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Amount__c = 750;
        insert sch;
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-FLAT', 10000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 10000, dist.Id);
        Test.stopTest();

        List<Scheme_Accrual__c> accruals = accrualsFor(inv.Id);
        System.assertEquals(1, accruals.size(), 'One accrual');
        System.assertEquals(750, accruals[0].Accrued_Amount__c,
            'A flat scheme pays its fixed amount regardless of invoice size');
    }

    @isTest
    static void percentTakesPrecedenceOverFlatAmount() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Both', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 2;
        sch.Discount_Amount__c = 999;
        insert sch;
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-BOTH', 10000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 10000, dist.Id);
        Test.stopTest();

        System.assertEquals(200, accrualsFor(inv.Id)[0].Accrued_Amount__c,
            'When both are configured the percentage wins — the flat amount is the fallback');
    }

    @isTest
    static void accrualIsCappedAtTheMaximum() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Cap', 'Distributor');
        Scheme__c capped = newScheme();
        capped.Discount_Percent__c = 10;
        capped.Max_Discount_Cap__c = 500;
        insert capped;
        Invoice__c big = newInvoice(dist.Id, 'PINV-SA-CAP', 100000);
        enableSchemeClaim();

        Test.startTest();
        accrue(big.Id, 100000, dist.Id);
        Test.stopTest();

        System.assertEquals(500, accrualsFor(big.Id)[0].Accrued_Amount__c,
            '10% of 100,000 is 10,000 but the cap holds the payout at 500 — without this the '
            + 'scheme budget is unbounded');
    }

    @isTest
    static void accrualBelowTheCapIsLeftAlone() {
        Account dist = TestDataFactory.createAndInsertAccount('SA UnderCap', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 10;
        sch.Max_Discount_Cap__c = 5000;
        insert sch;
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-UNDERCAP', 1000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 1000, dist.Id);
        Test.stopTest();

        System.assertEquals(100, accrualsFor(inv.Id)[0].Accrued_Amount__c,
            'A payout under the ceiling is paid in full');
    }

    // ── Applicability: invoice-value threshold ────────────────────────

    @isTest
    static void invoiceBelowTheThresholdDoesNotAccrue() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Thresh', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 5;
        sch.Invoice_Val_Threshold__c = 5000;
        insert sch;
        Invoice__c small = newInvoice(dist.Id, 'PINV-SA-SMALL', 4999);
        Invoice__c atThreshold = newInvoice(dist.Id, 'PINV-SA-AT', 5000);
        enableSchemeClaim();

        Test.startTest();
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(
            new Map<Id, Decimal>{ small.Id => 4999, atThreshold.Id => 5000 },
            new Map<Id, Id>{ small.Id => dist.Id, atThreshold.Id => dist.Id });
        Test.stopTest();

        System.assertEquals(0, accrualsFor(small.Id).size(),
            'One rupee short of the qualifying value earns nothing');
        System.assertEquals(250, accrualsFor(atThreshold.Id)[0].Accrued_Amount__c,
            'The threshold is inclusive — hitting it exactly qualifies');
    }

    // ── Applicability: channel ────────────────────────────────────────

    @isTest
    static void schemeScopedToAnotherChannelDoesNotApply() {
        // TestDataFactory puts every account on the GT channel.
        Account dist = TestDataFactory.createAndInsertAccount('SA Chan', 'Distributor');
        Scheme__c gt = newScheme();
        gt.Discount_Percent__c = 5;
        gt.Applicable_Channel__c = 'GT';
        Scheme__c mt = newScheme();
        mt.Discount_Percent__c = 50;
        mt.Applicable_Channel__c = 'MT';
        insert new List<Scheme__c>{ gt, mt };
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-CHAN', 1000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 1000, dist.Id);
        Test.stopTest();

        List<Scheme_Accrual__c> accruals = accrualsFor(inv.Id);
        System.assertEquals(1, accruals.size(),
            'Only the matching channel accrues — a modern-trade scheme must not pay a '
            + 'general-trade distributor');
        System.assertEquals(gt.Id, accruals[0].Scheme__c, 'And it is the GT scheme');
        System.assertEquals(50, accruals[0].Accrued_Amount__c, '5% of 1000');
    }

    @isTest
    static void schemeWithNoChannelAppliesEverywhere() {
        Account dist = TestDataFactory.createAndInsertAccount('SA AnyChan', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 5;   // Applicable_Channel__c left blank
        insert sch;
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-ANYCHAN', 1000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 1000, dist.Id);
        Test.stopTest();

        System.assertEquals(1, accrualsFor(inv.Id).size(),
            'A blank channel means no channel restriction, so every distributor qualifies');
    }

    /**
     * KNOWN DEFECT — Applicable_Channel__c is a MULTI-select picklist, but
     * isApplicable compares it to Account.Channel__c with a plain !=. A
     * multi-select stores its values semicolon-joined ('GT;MT'), which never
     * equals 'GT', and the picklist's own "All" option never equals any real
     * channel either. So the two configurations an admin would reach for to
     * widen a scheme — picking several channels, or picking "All" — silently
     * make it apply to nobody, while leaving the field blank works.
     *
     * These assertions pin the current behaviour so the defect is visible. When
     * isApplicable is fixed to split on ';' and honour 'All', this test should
     * fail and be rewritten.
     */
    @isTest
    static void multiChannelAndAllSchemesSilentlyApplyToNobody() {
        Account dist = TestDataFactory.createAndInsertAccount('SA MultiChan', 'Distributor');
        Scheme__c multi = newScheme();
        multi.Discount_Percent__c = 5;
        multi.Applicable_Channel__c = 'GT;MT';
        Scheme__c all = newScheme();
        all.Discount_Percent__c = 5;
        all.Applicable_Channel__c = 'All';
        insert new List<Scheme__c>{ multi, all };
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-MULTI', 1000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 1000, dist.Id);
        Test.stopTest();

        System.assertEquals(0, accrualsFor(inv.Id).size(),
            'A GT distributor gets nothing from a scheme marked "GT;MT" or "All", because the '
            + 'multi-select value is compared as a single string');
    }

    // ── Applicability: region ─────────────────────────────────────────

    /**
     * KNOWN DEFECT, and not a quiet one — Scheme__c.Applicable_Region__c is a
     * Lookup to Company_Hierarchy__c (its value is a record Id) while
     * Account.Region__c is plain Text (its value is a name like 'West').
     * isApplicable compares them directly, and Apex does not treat that as
     * merely unequal: it tries to coerce the text into an Id and throws
     * System.StringException: Invalid id: West.
     *
     * Nothing catches it, so the exception escapes accrueForPrimaryInvoices and
     * takes the caller's whole transaction with it. Any org that has a
     * region-scoped scheme AND distributors carrying a region name cannot raise
     * a primary invoice at all.
     *
     * A region-scoped scheme is only harmless while every account's Region__c is
     * blank, because an Id compared to null is simply unequal.
     *
     * Pinned here so the failure mode is visible. Once the comparison is fixed —
     * by resolving the hierarchy record's name, or by making both fields the same
     * type — this test should fail and be rewritten to assert that a West scheme
     * actually accrues for a West distributor.
     */
    @isTest
    static void regionScopedSchemeThrowsWhenTheDistributorHasARegionName() {
        Company_Hierarchy__c region = new Company_Hierarchy__c(
            Name = 'West', Code__c = 'RGN-WEST', Is_Active__c = true);
        insert region;

        Account dist = TestDataFactory.createAndInsertAccount('SA Region', 'Distributor');
        update new Account(Id = dist.Id, Region__c = 'West');

        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 5;
        sch.Applicable_Region__c = region.Id;
        insert sch;
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-REGION', 1000);
        enableSchemeClaim();

        Test.startTest();
        Boolean threw = false;
        String message = '';
        try {
            accrue(inv.Id, 1000, dist.Id);
        } catch (Exception e) {
            threw = true;
            message = e.getMessage();
        }
        Test.stopTest();

        System.assert(threw,
            'Comparing the scheme region lookup to the account region text must be expected '
            + 'to blow up — it does not degrade to "no match"');
        System.assert(message.contains('Invalid id'),
            'Expected the Id coercion failure, got: ' + message);
        System.assertEquals(0, accrualsFor(inv.Id).size(),
            'And the accrual insert is never reached, so the invoice gets no scheme payout');
    }

    @isTest
    static void regionScopedSchemeIsHarmlessWhileTheDistributorHasNoRegion() {
        Company_Hierarchy__c region = new Company_Hierarchy__c(
            Name = 'South', Code__c = 'RGN-SOUTH', Is_Active__c = true);
        insert region;

        // Region__c left blank — an Id compared to null is simply unequal, so the
        // coercion never happens and the scheme is skipped without incident.
        Account dist = TestDataFactory.createAndInsertAccount('SA NoRegion', 'Distributor');
        Scheme__c scoped = newScheme();
        scoped.Discount_Percent__c = 5;
        scoped.Applicable_Region__c = region.Id;
        Scheme__c open = newScheme();
        open.Discount_Percent__c = 3;
        insert new List<Scheme__c>{ scoped, open };
        Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-NOREGION', 1000);
        enableSchemeClaim();

        Test.startTest();
        accrue(inv.Id, 1000, dist.Id);
        Test.stopTest();

        List<Scheme_Accrual__c> accruals = accrualsFor(inv.Id);
        System.assertEquals(1, accruals.size(),
            'Only the unscoped scheme accrues; the region-scoped one is skipped quietly');
        System.assertEquals(30, accruals[0].Accrued_Amount__c, '3% of 1000 from the open scheme');
    }

    // ── Bulk ──────────────────────────────────────────────────────────

    @isTest
    static void everyInvoiceAccruesAgainstEveryApplicableScheme() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Bulk', 'Distributor');
        Scheme__c first = newScheme();
        first.Discount_Percent__c = 5;
        Scheme__c second = newScheme();
        second.Discount_Amount__c = 100;
        insert new List<Scheme__c>{ first, second };

        Map<Id, Decimal> values = new Map<Id, Decimal>();
        Map<Id, Id> accountByInvoice = new Map<Id, Id>();
        for (Integer i = 0; i < 5; i++) {
            Invoice__c inv = newInvoice(dist.Id, 'PINV-SA-BULK-' + i, 1000);
            values.put(inv.Id, 1000);
            accountByInvoice.put(inv.Id, dist.Id);
        }
        enableSchemeClaim();

        Test.startTest();
        DMS_SchemeAccrual_Service.accrueForPrimaryInvoices(values, accountByInvoice);
        Test.stopTest();

        System.assertEquals(10, [
            SELECT COUNT() FROM Scheme_Accrual__c WHERE Invoice__c IN :values.keySet()
        ], 'Five invoices against two applicable schemes is ten accruals, inserted in one DML');
    }

    // ── reconcileClaim guards ─────────────────────────────────────────

    @isTest
    static void reconcileClaim_withNothingOpen_returnsZero() {
        Account dist = TestDataFactory.createAndInsertAccount('SA Rec0', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 5;
        insert sch;
        Claim__c claim = new Claim__c(
            Account__c = dist.Id, Scheme__c = sch.Id, Claim_Type__c = 'Scheme Claim',
            Claim_Date__c = Date.today(), Total_Amount__c = 100, Status__c = 'Submitted');
        insert claim;
        enableSchemeClaim();

        Test.startTest();
        Decimal reconciled = DMS_SchemeAccrual_Service.reconcileClaim(claim);
        Test.stopTest();

        System.assertEquals(0, reconciled,
            'A claim with no open accrual behind it reconciles nothing rather than failing');
    }

    @isTest
    static void reconcileClaim_withIncompleteClaim_returnsZero() {
        Account dist = TestDataFactory.createAndInsertAccount('SA RecBad', 'Distributor');
        enableSchemeClaim();

        Claim__c noAccount = new Claim__c(Scheme__c = null, Account__c = null);
        Claim__c noScheme = new Claim__c(Account__c = dist.Id, Scheme__c = null);

        Test.startTest();
        Decimal fromNull = DMS_SchemeAccrual_Service.reconcileClaim(null);
        Decimal fromNoAccount = DMS_SchemeAccrual_Service.reconcileClaim(noAccount);
        Decimal fromNoScheme = DMS_SchemeAccrual_Service.reconcileClaim(noScheme);
        Test.stopTest();

        System.assertEquals(0, fromNull, 'A null claim reconciles nothing');
        System.assertEquals(0, fromNoAccount, 'Without an account there is no ledger to search');
        System.assertEquals(0, fromNoScheme, 'Without a scheme there is no pool to draw from');
    }

    @isTest
    static void reconcileClaim_whenDisabled_returnsZero() {
        Account dist = TestDataFactory.createAndInsertAccount('SA RecOff', 'Distributor');
        Scheme__c sch = newScheme();
        sch.Discount_Percent__c = 5;
        insert sch;
        Claim__c claim = new Claim__c(
            Account__c = dist.Id, Scheme__c = sch.Id, Claim_Type__c = 'Scheme Claim',
            Claim_Date__c = Date.today(), Total_Amount__c = 100, Status__c = 'Submitted');
        insert claim;
        insert new Scheme_Accrual__c(
            Account__c = dist.Id, Scheme__c = sch.Id, Accrued_Amount__c = 300,
            Accrual_Date__c = Date.today(), Status__c = DMS_Constants.ACCRUAL_OPEN);

        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SCHEME_CLAIM, false);

        Test.startTest();
        Decimal reconciled = DMS_SchemeAccrual_Service.reconcileClaim(claim);
        Test.stopTest();

        System.assertEquals(0, reconciled, 'The toggle gates reconciliation as well as accrual');
        System.assertEquals(DMS_Constants.ACCRUAL_OPEN, [
            SELECT Status__c FROM Scheme_Accrual__c WHERE Account__c = :dist.Id
        ].Status__c, 'And the accrual is left untouched');
    }

    @isTest
    static void reconcileClaim_sumsEveryOpenAccrualForThatScheme() {
        Account dist = TestDataFactory.createAndInsertAccount('SA RecSum', 'Distributor');
        Scheme__c mine = newScheme();
        mine.Discount_Percent__c = 5;
        Scheme__c other = newScheme();
        other.Discount_Percent__c = 5;
        insert new List<Scheme__c>{ mine, other };

        insert new List<Scheme_Accrual__c>{
            new Scheme_Accrual__c(Account__c = dist.Id, Scheme__c = mine.Id,
                Accrued_Amount__c = 120, Accrual_Date__c = Date.today(),
                Status__c = DMS_Constants.ACCRUAL_OPEN),
            new Scheme_Accrual__c(Account__c = dist.Id, Scheme__c = mine.Id,
                Accrued_Amount__c = 80, Accrual_Date__c = Date.today(),
                Status__c = DMS_Constants.ACCRUAL_OPEN),
            new Scheme_Accrual__c(Account__c = dist.Id, Scheme__c = mine.Id,
                Accrued_Amount__c = 500, Accrual_Date__c = Date.today(),
                Status__c = DMS_Constants.ACCRUAL_CLAIMED),
            new Scheme_Accrual__c(Account__c = dist.Id, Scheme__c = other.Id,
                Accrued_Amount__c = 900, Accrual_Date__c = Date.today(),
                Status__c = DMS_Constants.ACCRUAL_OPEN)
        };

        Claim__c claim = new Claim__c(
            Account__c = dist.Id, Scheme__c = mine.Id, Claim_Type__c = 'Scheme Claim',
            Claim_Date__c = Date.today(), Total_Amount__c = 200, Status__c = 'Submitted');
        insert claim;
        enableSchemeClaim();

        Test.startTest();
        Decimal reconciled = DMS_SchemeAccrual_Service.reconcileClaim(claim);
        Test.stopTest();

        System.assertEquals(200, reconciled,
            'Only the open accruals for this scheme are drawn down — an already-claimed row '
            + 'must not be paid twice, and another scheme pool is not raided');
        System.assertEquals(1, [
            SELECT COUNT() FROM Scheme_Accrual__c
            WHERE Scheme__c = :other.Id AND Status__c = :DMS_Constants.ACCRUAL_OPEN
        ], 'The other scheme pool is still open');
    }
}