/**
 * @description Tests for LoyaltyService — the reward-points wallet ledger.
 *
 * KNOWN GAP (main-class / wiring): recordWalletMovements and
 * reverseWalletMovements have NO callers anywhere. LoyaltyRedemptionController
 * only reads getBalance; no trigger handler references LoyaltyService; and
 * neither method is @InvocableMethod, so a Flow cannot call them. The comment
 * "credited when the order reaches Approved status" describes wiring that does
 * not exist — in production the wallet is never credited or debited on order
 * approval, and cancellations reverse nothing. Fix: call
 * LoyaltyService.recordWalletMovements from the Sales Order handler on the
 * transition to Approved, and reverseWalletMovements on cancellation of an
 * approved order. These tests exercise the service directly, so they hold
 * before and after that wiring lands — see wallet_isNeverWrittenByTheOrderFlow
 * for the pin on today's behaviour.
 */
@isTest
private class LoyaltyServiceTest {

    @testSetup
    static void setupTestData() {
        insert TestDataFactory.createAccount('Loyalty Outlet', 'Retailer');
    }

    private static Integer orderSeq = 0;

    private static Account theAccount() {
        return [SELECT Id FROM Account WHERE Name = 'Loyalty Outlet' LIMIT 1];
    }

    /** An approved-flow order carrying reward figures; date-spaced to dodge the
        duplicate-order guard. */
    private static Sales_Order__c orderWithPoints(Decimal earned, Decimal redeemed) {
        Sales_Order__c o = TestDataFactory.createSalesOrder(
            theAccount().Id, UserInfo.getUserId(), null);
        o.Total_Reward_Points__c = earned;
        o.Reward_Points_Redeemed__c = redeemed;
        orderSeq++;
        o.Order_Date__c = Date.today().addDays(-orderSeq);
        insert o;
        return [SELECT Id, Name, Account__c FROM Sales_Order__c WHERE Id = :o.Id];
    }

    private static Loyalty_Points__c seedRow(Id accountId, Decimal points, String ref) {
        return new Loyalty_Points__c(
            Account__c = accountId, Points__c = points, Balance_After__c = points,
            Transaction_Type__c = 'Earned', Transaction_Date__c = Date.today().addDays(-30),
            Reference__c = ref);
    }

    // ── recordWalletMovements ─────────────────────────────────────────

    @isTest
    static void record_creditsEarnedDebitsRedeemed_withRunningBalances() {
        Account acct = theAccount();
        insert seedRow(acct.Id, 100, 'SEED');   // wallet opens at 100
        Sales_Order__c o = orderWithPoints(50, 20);

        Test.startTest();
        LoyaltyService.recordWalletMovements(new Set<Id>{ o.Id });
        Test.stopTest();

        List<Loyalty_Points__c> rows = [
            SELECT Points__c, Balance_After__c, Transaction_Type__c, Reference__c
            FROM Loyalty_Points__c WHERE Reference__c = :o.Name
            ORDER BY Points__c DESC];
        System.assertEquals(2, rows.size(), 'One earned row, one redeemed row');
        System.assertEquals(50, rows[0].Points__c, 'Earned stored positive');
        System.assertEquals('Earned', rows[0].Transaction_Type__c, 'Typed Earned');
        System.assertEquals(150, rows[0].Balance_After__c,
            'Running balance snapshots 100 + 50 at the moment of the credit');
        System.assertEquals(-20, rows[1].Points__c,
            'Redemption stored NEGATIVE so the balance is a plain SUM over the ledger');
        System.assertEquals(130, rows[1].Balance_After__c, 'Then 150 - 20');
        System.assertEquals(130, LoyaltyService.getBalance(acct.Id),
            'And the read API agrees with the last snapshot');
    }

    @isTest
    static void record_isIdempotentAcrossRetries() {
        Sales_Order__c o = orderWithPoints(50, 20);

        Test.startTest();
        LoyaltyService.recordWalletMovements(new Set<Id>{ o.Id });
        LoyaltyService.recordWalletMovements(new Set<Id>{ o.Id });   // retry
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Loyalty_Points__c
            WHERE Reference__c = :o.Name],
            'A retried approval event must not double-credit the customer');
        System.assertEquals(30, LoyaltyService.getBalance(theAccount().Id),
            'Balance stays 50 - 20 no matter how many times the order is processed');
    }

    @isTest
    static void record_zeroPointOrdersAndEmptyInput_writeNothing() {
        Sales_Order__c pointless = orderWithPoints(0, null);

        Test.startTest();
        LoyaltyService.recordWalletMovements(new Set<Id>{ pointless.Id });
        LoyaltyService.recordWalletMovements(null);
        LoyaltyService.recordWalletMovements(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Loyalty_Points__c],
            'No points, no ledger rows — and null/empty input is a quiet no-op');
    }

    @isTest
    static void record_redemptionOnly_writesASingleNegativeRow() {
        Sales_Order__c o = orderWithPoints(null, 40);

        Test.startTest();
        LoyaltyService.recordWalletMovements(new Set<Id>{ o.Id });
        Test.stopTest();

        List<Loyalty_Points__c> rows = [
            SELECT Points__c, Balance_After__c, Transaction_Type__c
            FROM Loyalty_Points__c WHERE Reference__c = :o.Name];
        System.assertEquals(1, rows.size(), 'Only the redemption row');
        System.assertEquals(-40, rows[0].Points__c, 'Debited');
        System.assertEquals(-40, rows[0].Balance_After__c,
            'Pinned: with no prior balance the wallet goes negative — the service does '
            + 'not guard against redeeming points the customer does not have');
    }

    @isTest
    static void record_twoOrdersOneAccount_chainTheBalanceInOnePass() {
        Sales_Order__c first = orderWithPoints(30, 0);
        Sales_Order__c second = orderWithPoints(70, 0);

        Test.startTest();
        LoyaltyService.recordWalletMovements(new Set<Id>{ first.Id, second.Id });
        Test.stopTest();

        System.assertEquals(100, LoyaltyService.getBalance(theAccount().Id),
            'Both credits land: 30 + 70');
        System.assertEquals(2, [SELECT COUNT() FROM Loyalty_Points__c
            WHERE Transaction_Type__c = 'Earned'], 'One row per order');
        System.assertEquals(1, [SELECT COUNT() FROM Loyalty_Points__c
            WHERE Balance_After__c = 100],
            'Exactly one row carries the final 100 — the running balance chains '
            + 'across orders inside a single batch instead of both reading the same start');
    }

    // ── reverseWalletMovements ────────────────────────────────────────

    @isTest
    static void reverse_compensatesBothMovements_restoringTheWallet() {
        Account acct = theAccount();
        insert seedRow(acct.Id, 100, 'SEED');
        Sales_Order__c o = orderWithPoints(50, 20);
        LoyaltyService.recordWalletMovements(new Set<Id>{ o.Id });   // balance 130

        Test.startTest();
        LoyaltyService.reverseWalletMovements(new Set<Id>{ o.Id });
        Test.stopTest();

        List<Loyalty_Points__c> reversals = [
            SELECT Points__c, Transaction_Type__c, Reference__c
            FROM Loyalty_Points__c
            WHERE Transaction_Type__c = 'Adjusted' ORDER BY Points__c];
        System.assertEquals(2, reversals.size(), 'One compensating row per original');
        System.assertEquals(-50, reversals[0].Points__c, 'The earned credit is clawed back');
        System.assertEquals(20, reversals[1].Points__c,
            'And the redeemed points are RETURNED to the customer — a cancelled order '
            + 'must not eat the points they spent on it');
        System.assert(reversals[0].Reference__c.contains('(reversal)'),
            'Reversals carry a distinct reference for idempotency and audit');
        System.assertEquals(100, LoyaltyService.getBalance(acct.Id),
            'The wallet is exactly back at its pre-order 100');
    }

    @isTest
    static void reverse_isIdempotent_andNoOpWithoutOriginals() {
        Sales_Order__c recorded = orderWithPoints(50, 0);
        LoyaltyService.recordWalletMovements(new Set<Id>{ recorded.Id });
        Sales_Order__c neverRecorded = orderWithPoints(60, 0);

        Test.startTest();
        LoyaltyService.reverseWalletMovements(new Set<Id>{ recorded.Id });
        LoyaltyService.reverseWalletMovements(new Set<Id>{ recorded.Id });   // retry
        LoyaltyService.reverseWalletMovements(new Set<Id>{ neverRecorded.Id });
        LoyaltyService.reverseWalletMovements(null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Loyalty_Points__c
            WHERE Transaction_Type__c = 'Adjusted'],
            'One reversal, however many times the cancellation is retried');
        System.assertEquals(0, [SELECT COUNT() FROM Loyalty_Points__c
            WHERE Reference__c LIKE :('%' + neverRecorded.Name + '%')
              AND Transaction_Type__c = 'Adjusted'],
            'An order that never credited anything has nothing to reverse');
    }

    // ── Read APIs ─────────────────────────────────────────────────────

    @isTest
    static void balanceAndLedger_readBackScopedAndOrdered() {
        Account acct = theAccount();
        insert new List<Loyalty_Points__c>{
            seedRow(acct.Id, 10, 'OLD'),
            new Loyalty_Points__c(Account__c = acct.Id, Points__c = 20, Balance_After__c = 30,
                Transaction_Type__c = 'Earned', Transaction_Date__c = Date.today().addDays(-10),
                Reference__c = 'MID'),
            new Loyalty_Points__c(Account__c = acct.Id, Points__c = -5, Balance_After__c = 25,
                Transaction_Type__c = 'Redeemed', Transaction_Date__c = Date.today(),
                Reference__c = 'NEW')
        };

        Test.startTest();
        Decimal balance = LoyaltyService.getBalance(acct.Id);
        List<Loyalty_Points__c> topTwo = LoyaltyService.getLedger(acct.Id, 2);
        List<Loyalty_Points__c> defaulted = LoyaltyService.getLedger(acct.Id, null);
        Decimal nullBalance = LoyaltyService.getBalance(null);
        List<Loyalty_Points__c> nullLedger = LoyaltyService.getLedger(null, 5);
        Test.stopTest();

        System.assertEquals(25, balance, '10 + 20 - 5 across all transaction types');
        System.assertEquals(2, topTwo.size(), 'The row limit is honoured');
        System.assertEquals('NEW', topTwo[0].Reference__c, 'Newest transaction first');
        System.assertEquals('MID', topTwo[1].Reference__c, 'Then the next');
        System.assertEquals(3, defaulted.size(), 'A null limit falls back to the default 20');
        System.assertEquals(0, nullBalance, 'No account reads as zero, not an error');
        System.assertEquals(0, nullLedger.size(), 'And an empty ledger');
    }

    // ── The wiring gap, pinned ────────────────────────────────────────

    /**
     * KNOWN GAP — see the class comment. When the Sales Order handler is wired
     * to call recordWalletMovements on approval, this test will FAIL: rewrite it
     * to assert the ledger rows ARE written by the transition, then delete the
     * gap note.
     */
    @isTest
    static void wallet_isNeverWrittenByTheOrderFlow() {
        Sales_Order__c o = orderWithPoints(50, 20);
        // Territory_Required_On_Submit VR: supply it with the transition.
        Territory_Master__c terr =
            TestDataFactory.createAndInsertTerritory('Loyalty Terr', 'LOY-T01');

        Test.startTest();
        update new Sales_Order__c(Id = o.Id, Status__c = 'Submitted', Territory__c = terr.Id);
        update new Sales_Order__c(Id = o.Id, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Loyalty_Points__c],
            'Pinned current behaviour: approving an order with reward points writes NO '
            + 'wallet rows — recordWalletMovements has no callers, so points are never '
            + 'actually credited in production');
    }
}