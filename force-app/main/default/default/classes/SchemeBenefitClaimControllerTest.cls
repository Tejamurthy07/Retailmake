/**
 * @description Tests for SchemeBenefitClaimController — the customer-facing
 * view of accumulated scheme benefits (points wallet, open accrual pool, claim
 * history) and the claim-submission entry point.
 *
 * The summary is money a customer believes they are owed, so the assertions
 * centre on the arithmetic and the scoping: the balance nets earned against
 * redeemed, the accrual pool counts OPEN rows only, and nothing from another
 * customer's wallet or pool ever leaks into the view.
 */
@isTest
private class SchemeBenefitClaimControllerTest {

    @testSetup
    static void setupTestData() {
        insert new List<Account>{
            TestDataFactory.createAccount('SBC Customer', 'Retailer'),
            TestDataFactory.createAccount('SBC Other Customer', 'Retailer')
        };

        // Scheme_Type__c is a restricted picklist whose deployed values have
        // drifted from the repo, so resolve one at runtime.
        Scheme__c scheme = TestDataFactory.createScheme(
            'SBC Scheme', 'SCH-SBC1', 'Discount in %', 'Flat Discount Percent');
        String schemeType;
        for (Schema.PicklistEntry e : Scheme__c.Scheme_Type__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) { schemeType = e.getValue(); break; }
        }
        if (schemeType != null) scheme.Scheme_Type__c = schemeType;
        scheme.Budget_Amount__c = 100000;   // VR: budget must be positive
        insert scheme;
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Id customer() {
        return [SELECT Id FROM Account WHERE Name = 'SBC Customer' LIMIT 1].Id;
    }

    private static Id otherCustomer() {
        return [SELECT Id FROM Account WHERE Name = 'SBC Other Customer' LIMIT 1].Id;
    }

    private static Id schemeId() {
        return [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SBC1' LIMIT 1].Id;
    }

    private static Loyalty_Points__c points(
            Id accountId, Decimal pts, String txnType, Integer daysAgo) {
        return new Loyalty_Points__c(
            Account__c = accountId,
            Points__c = pts,
            Transaction_Type__c = txnType,
            Transaction_Date__c = Date.today().addDays(-daysAgo)
        );
    }

    private static Scheme_Accrual__c accrual(Id accountId, Decimal amount, String status) {
        return new Scheme_Accrual__c(
            Account__c = accountId,
            Scheme__c = schemeId(),
            Accrued_Amount__c = amount,
            Accrual_Date__c = Date.today(),
            Status__c = status
        );
    }

    // ── getCustomerBenefitSummary ─────────────────────────────────────

    @isTest
    static void summary_withNoAccount_returnsTheZeroedShape() {
        Test.startTest();
        SchemeBenefitClaimController.BenefitSummary s =
            SchemeBenefitClaimController.getCustomerBenefitSummary(null);
        Test.stopTest();

        System.assertEquals(0, s.rewardPointsBalance, 'Zeroed, not null — the LWC binds these');
        System.assertEquals(0, s.openAccrualAmount, 'Same for the pool');
        System.assertEquals(0, s.recentPoints.size(), 'Empty lists, not nulls');
        System.assertEquals(0, s.recentClaims.size(), 'Both of them');
    }

    @isTest
    static void summary_forAFreshCustomer_isAllZeros() {
        Test.startTest();
        SchemeBenefitClaimController.BenefitSummary s =
            SchemeBenefitClaimController.getCustomerBenefitSummary(customer());
        Test.stopTest();

        System.assertEquals(0, s.rewardPointsBalance,
            'A null SUM aggregate is folded to zero rather than surfacing as null');
        System.assertEquals(0, s.openAccrualAmount, 'Same for the accrual pool');
    }

    @isTest
    static void summary_netsThePointsWalletAndListsNewestFirst() {
        Id acct = customer();
        insert new List<Loyalty_Points__c>{
            points(acct, 100, 'Earned', 10),
            points(acct, -40, 'Redeemed', 5),
            points(acct, 10, 'Earned', 1),
            // Another customer's points must not leak into this wallet.
            points(otherCustomer(), 500, 'Earned', 2)
        };

        Test.startTest();
        SchemeBenefitClaimController.BenefitSummary s =
            SchemeBenefitClaimController.getCustomerBenefitSummary(acct);
        Test.stopTest();

        System.assertEquals(70, s.rewardPointsBalance,
            'The balance nets the ledger: 100 earned - 40 redeemed + 10 earned. Counting '
            + 'redemptions as earnings would let points be spent twice');
        System.assertEquals(3, s.recentPoints.size(), 'Only this customer rows');
        System.assertEquals(10, s.recentPoints[0].Points__c,
            'Newest movement first, so the wallet reads like a statement');
        System.assertEquals(-40, s.recentPoints[1].Points__c, 'Then the redemption');
    }

    @isTest
    static void summary_capsTheLedgerAtTenRows() {
        Id acct = customer();
        List<Loyalty_Points__c> many = new List<Loyalty_Points__c>();
        for (Integer i = 0; i < 12; i++) {
            many.add(points(acct, 5, 'Earned', i));
        }
        insert many;

        Test.startTest();
        SchemeBenefitClaimController.BenefitSummary s =
            SchemeBenefitClaimController.getCustomerBenefitSummary(acct);
        Test.stopTest();

        System.assertEquals(10, s.recentPoints.size(),
            'The summary shows the ten most recent movements, not the whole history');
        System.assertEquals(60, s.rewardPointsBalance,
            'While the BALANCE still counts all twelve — the cap is display-only');
    }

    @isTest
    static void summary_countsOnlyOpenAccrualsInThePool() {
        Id acct = customer();
        insert new List<Scheme_Accrual__c>{
            accrual(acct, 200, 'Open'),
            accrual(acct, 300, 'Open'),
            accrual(acct, 500, 'Claimed'),
            accrual(acct, 150, 'Settled'),
            // Another customer's open pool stays theirs.
            accrual(otherCustomer(), 900, 'Open')
        };

        Test.startTest();
        SchemeBenefitClaimController.BenefitSummary s =
            SchemeBenefitClaimController.getCustomerBenefitSummary(acct);
        Test.stopTest();

        System.assertEquals(500, s.openAccrualAmount,
            'Only the two OPEN accruals are claimable — showing already-claimed or settled '
            + 'amounts would invite double claims for money already paid out');
    }

    @isTest
    static void summary_listsThisCustomersClaimsNewestFirst() {
        Id acct = customer();
        insert new List<Claim__c>{
            new Claim__c(Account__c = acct, Scheme__c = schemeId(),
                Claim_Type__c = 'Scheme Claim', Status__c = 'Submitted',
                Claim_Date__c = Date.today().addDays(-10), Total_Amount__c = 250),
            new Claim__c(Account__c = acct, Scheme__c = schemeId(),
                Claim_Type__c = 'Scheme Claim', Status__c = 'Submitted',
                Claim_Date__c = Date.today(), Total_Amount__c = 400),
            new Claim__c(Account__c = otherCustomer(), Scheme__c = schemeId(),
                Claim_Type__c = 'Scheme Claim', Status__c = 'Submitted',
                Claim_Date__c = Date.today(), Total_Amount__c = 999)
        };

        Test.startTest();
        SchemeBenefitClaimController.BenefitSummary s =
            SchemeBenefitClaimController.getCustomerBenefitSummary(acct);
        Test.stopTest();

        System.assertEquals(2, s.recentClaims.size(),
            'The other customer claim never appears in this history');
        System.assertEquals(400, s.recentClaims[0].Total_Amount__c, 'Newest claim first');
        System.assertEquals(250, s.recentClaims[1].Total_Amount__c, 'Older one after');
        System.assertEquals('SBC Scheme', s.recentClaims[0].Scheme__r.Name,
            'With the scheme name resolved for display');
    }

    // ── submitSchemeClaim ─────────────────────────────────────────────

    @isTest
    static void submit_withoutAnAccount_isRejected() {
        Test.startTest();
        Boolean threw = false;
        try {
            SchemeBenefitClaimController.submitSchemeClaim(null, schemeId(), 100, 'notes');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A claim needs a claimant');
        System.assertEquals(0, [SELECT COUNT() FROM Claim__c], 'And nothing was persisted');
    }

    @isTest
    static void submit_withNoOrNegativeAmount_isRejected() {
        Id acct = customer();

        Test.startTest();
        Integer rejected = 0;
        try {
            SchemeBenefitClaimController.submitSchemeClaim(acct, schemeId(), null, null);
        } catch (AuraHandledException e) { rejected++; }
        try {
            SchemeBenefitClaimController.submitSchemeClaim(acct, schemeId(), 0, null);
        } catch (AuraHandledException e) { rejected++; }
        try {
            SchemeBenefitClaimController.submitSchemeClaim(acct, schemeId(), -50, null);
        } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(3, rejected,
            'Null, zero and negative amounts are all refused — a negative claim would be '
            + 'a payment demand in reverse');
        System.assertEquals(0, [SELECT COUNT() FROM Claim__c], 'Nothing saved');
    }

    @isTest
    static void submit_createsTheClaimInSubmittedStatus() {
        Id acct = customer();

        Test.startTest();
        Claim__c returned = SchemeBenefitClaimController.submitSchemeClaim(
            acct, schemeId(), 750, 'Q3 display scheme payout');
        Test.stopTest();

        Claim__c stored = [
            SELECT Account__c, Scheme__c, Claim_Type__c, Status__c,
                   Claim_Date__c, Total_Amount__c, Notes__c
            FROM Claim__c WHERE Id = :returned.Id
        ];
        System.assertEquals(acct, stored.Account__c, 'Claimed by the customer');
        System.assertEquals(schemeId(), stored.Scheme__c, 'Against the scheme');
        System.assertEquals('Scheme Claim', stored.Claim_Type__c, 'Typed for routing');
        System.assertEquals('Submitted', stored.Status__c,
            'Born Submitted — a customer claim always waits for back-office approval, '
            + 'never self-approves');
        System.assertEquals(Date.today(), stored.Claim_Date__c, 'Dated today');
        System.assertEquals(750, stored.Total_Amount__c, 'For the claimed amount');
        System.assertEquals('Q3 display scheme payout', stored.Notes__c, 'Notes carried');
    }

    @isTest
    static void submit_withoutAScheme_stillSaves() {
        Id acct = customer();

        Test.startTest();
        Claim__c returned = SchemeBenefitClaimController.submitSchemeClaim(
            acct, null, 120, null);
        Test.stopTest();

        System.assertEquals(null, [
            SELECT Scheme__c FROM Claim__c WHERE Id = :returned.Id
        ].Scheme__c,
            'The scheme is optional — a general benefit claim can be lodged and the back '
            + 'office attributes it during review');
    }

    @isTest
    static void submit_thenTheClaimAppearsInTheSummary() {
        Id acct = customer();

        Test.startTest();
        SchemeBenefitClaimController.submitSchemeClaim(acct, schemeId(), 300, null);
        SchemeBenefitClaimController.BenefitSummary s =
            SchemeBenefitClaimController.getCustomerBenefitSummary(acct);
        Test.stopTest();

        System.assertEquals(1, s.recentClaims.size(),
            'The claim the customer just lodged shows in their own history immediately');
        System.assertEquals(300, s.recentClaims[0].Total_Amount__c, 'At its amount');
        System.assertEquals('Submitted', s.recentClaims[0].Status__c, 'Awaiting approval');
    }
}