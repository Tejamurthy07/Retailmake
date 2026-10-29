/**
 * @description Tests for UOM_Conversion_Trigger — inverse-factor derivation,
 * self-reference rejection, and the circular-conversion detector.
 *
 * The cycle detector is the part worth protecting: a conversion loop
 * (A→B→C→A) would let a quantity change value by round-tripping units, and
 * every pricing and stock figure downstream converts through this table. One
 * consequence of its design is pinned deliberately below: a DIRECT reverse
 * pair (B→A when A→B exists) is also rejected as circular — by design, since
 * the trigger derives Inverse_Conversion_Factor__c precisely so the reverse
 * row is never needed.
 */
@isTest
private class UOM_Conversion_Trigger_Test {

    @testSetup
    static void setupTestData() {
        insert new List<UOM__c>{
            new UOM__c(Name = 'Piece', UOM_Code__c = 'UCT-PC', Is_Active__c = true, Is_Base_Unit__c = true),
            new UOM__c(Name = 'Box', UOM_Code__c = 'UCT-BX', Is_Active__c = true, Is_Base_Unit__c = false),
            new UOM__c(Name = 'Case', UOM_Code__c = 'UCT-CS', Is_Active__c = true, Is_Base_Unit__c = false),
            new UOM__c(Name = 'Pallet', UOM_Code__c = 'UCT-PL', Is_Active__c = true, Is_Base_Unit__c = false)
        };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> cachedUoms;

    private static Id uom(String code) {
        if (cachedUoms == null) {
            cachedUoms = new Map<String, Id>();
            for (UOM__c u : [SELECT Id, UOM_Code__c FROM UOM__c WHERE UOM_Code__c LIKE 'UCT-%']) {
                cachedUoms.put(u.UOM_Code__c, u.Id);
            }
        }
        return cachedUoms.get(code);
    }

    private static UOM_Conversion__c conversion(String fromCode, String toCode, Decimal factor) {
        return new UOM_Conversion__c(
            From_UOM__c = uom(fromCode),
            To_UOM__c = uom(toCode),
            Conversion_Factor__c = factor,
            Is_Active__c = true
        );
    }

    private static String errorsOf(Database.SaveResult sr) {
        List<String> messages = new List<String>();
        for (Database.Error e : sr.getErrors()) messages.add(e.getMessage());
        return String.join(messages, ' | ');
    }

    // ── Inverse factor derivation ─────────────────────────────────────

    @isTest
    static void insert_derivesTheInverseFactor() {
        Test.startTest();
        UOM_Conversion__c caseToPiece = conversion('UCT-CS', 'UCT-PC', 12);
        insert caseToPiece;
        Test.stopTest();

        System.assertEquals(0.083333, [
            SELECT Inverse_Conversion_Factor__c FROM UOM_Conversion__c WHERE Id = :caseToPiece.Id
        ].Inverse_Conversion_Factor__c,
            'One case is twelve pieces, so one piece is 1/12 of a case, held to six decimals — '
            + 'the derived inverse is why no reverse row is ever configured');
    }

    @isTest
    static void update_recomputesTheInverseWhenTheFactorChanges() {
        UOM_Conversion__c conv = conversion('UCT-CS', 'UCT-PC', 12);
        insert conv;

        Test.startTest();
        conv.Conversion_Factor__c = 24;   // repack: cases now hold 24
        update conv;
        Test.stopTest();

        System.assertEquals(0.041667, [
            SELECT Inverse_Conversion_Factor__c FROM UOM_Conversion__c WHERE Id = :conv.Id
        ].Inverse_Conversion_Factor__c,
            'A factor change re-derives the inverse — a stale inverse would silently convert '
            + 'base quantities at the old pack size');
    }

    @isTest
    static void insert_withNoFactor_leavesTheInverseAlone() {
        Test.startTest();
        UOM_Conversion__c blank = conversion('UCT-CS', 'UCT-PC', null);
        insert blank;
        Test.stopTest();

        System.assertEquals(null, [
            SELECT Inverse_Conversion_Factor__c FROM UOM_Conversion__c WHERE Id = :blank.Id
        ].Inverse_Conversion_Factor__c,
            'No factor means nothing to invert — a fabricated inverse would be worse than none');
    }

    // ── Self-reference ────────────────────────────────────────────────

    @isTest
    static void selfConversion_isRejected() {
        Test.startTest();
        Database.SaveResult sr = Database.insert(conversion('UCT-PC', 'UCT-PC', 1), false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(), 'Piece-to-piece converts nothing');
        // THREE guards can name this refusal: the trigger's self-reference
        // addError, the From_To_UOM_Different validation rule, and — observed
        // in practice — the cycle detector, because a self-edge is a one-node
        // cycle the BFS finds immediately. Which one surfaces is
        // implementation detail; that the save fails with a reason is the
        // contract.
        System.assert(errorsOf(sr).containsIgnoreCase('same')
            || errorsOf(sr).containsIgnoreCase('different')
            || errorsOf(sr).containsIgnoreCase('circular'),
            'Refused with a reason: ' + errorsOf(sr));
    }

    // ── Cycle detection ───────────────────────────────────────────────

    @isTest
    static void aChainWithoutACycle_isAllowed() {
        Test.startTest();
        insert conversion('UCT-PL', 'UCT-CS', 10);
        insert conversion('UCT-CS', 'UCT-BX', 4);
        insert conversion('UCT-BX', 'UCT-PC', 6);
        Test.stopTest();

        System.assertEquals(3, [SELECT COUNT() FROM UOM_Conversion__c],
            'Pallet → Case → Box → Piece is a straight chain down to the base unit — '
            + 'exactly how a UOM hierarchy is meant to be configured');
    }

    @isTest
    static void closingAThreeStepLoop_isRejected() {
        insert conversion('UCT-PL', 'UCT-CS', 10);
        insert conversion('UCT-CS', 'UCT-BX', 4);

        Test.startTest();
        Database.SaveResult sr = Database.insert(conversion('UCT-BX', 'UCT-PL', 1), false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'Box → Pallet closes Pallet → Case → Box into a loop — a quantity could then '
            + 'change value by round-tripping the cycle');
        System.assert(errorsOf(sr).contains('circular'),
            'Named as circular: ' + errorsOf(sr));
        System.assertEquals(2, [SELECT COUNT() FROM UOM_Conversion__c],
            'And the closing edge is not saved');
    }

    /**
     * Pinned by design, not as a defect: the detector walks FROM the new row's
     * To_UOM looking for its From_UOM, so a direct reverse pair (Piece → Case
     * when Case → Piece exists) reads as a two-node cycle and is rejected.
     * That is intentional — the trigger derives Inverse_Conversion_Factor__c
     * on every row, so the reverse direction is already available without a
     * second record, and allowing one would create two places for the same
     * ratio to disagree.
     */
    @isTest
    static void aDirectReversePair_isRejectedAsCircular() {
        insert conversion('UCT-CS', 'UCT-PC', 12);

        Test.startTest();
        Database.SaveResult sr = Database.insert(conversion('UCT-PC', 'UCT-CS', 0.083333), false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'The reverse row is refused — its ratio already exists as the derived inverse, '
            + 'and a second record would let the two drift apart');
        System.assert(errorsOf(sr).contains('circular'),
            'Rejected through the cycle detector: ' + errorsOf(sr));
    }

    @isTest
    static void inactiveConversions_doNotParticipateInCycleDetection() {
        UOM_Conversion__c dormant = conversion('UCT-CS', 'UCT-PC', 12);
        dormant.Is_Active__c = false;
        insert dormant;

        Test.startTest();
        // The reverse of an INACTIVE edge is fine — only live edges can loop.
        insert conversion('UCT-PC', 'UCT-CS', 0.083333);
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM UOM_Conversion__c],
            'A deactivated conversion is historical, not part of the live graph');
    }

    @isTest
    static void anInactiveNewRow_skipsTheCycleCheckItself() {
        insert conversion('UCT-CS', 'UCT-PC', 12);

        Test.startTest();
        // Would close a loop if active — but it arrives inactive (staged for a
        // future changeover), so it must be storable.
        UOM_Conversion__c staged = conversion('UCT-PC', 'UCT-CS', 0.083333);
        staged.Is_Active__c = false;
        insert staged;
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM UOM_Conversion__c],
            'An inactive row cannot create a live cycle, so it is allowed in');
    }

    @isTest
    static void updatingARowsOwnFactor_doesNotTripTheDetectorOnItself() {
        UOM_Conversion__c conv = conversion('UCT-CS', 'UCT-PC', 12);
        insert conv;

        Test.startTest();
        conv.Conversion_Factor__c = 10;
        Database.SaveResult sr = Database.update(conv, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'A row is excluded from the graph while it is being updated — otherwise every '
            + 'factor correction would collide with the record own edge: ' + errorsOf(sr));
        System.assertEquals(0.1, [
            SELECT Inverse_Conversion_Factor__c FROM UOM_Conversion__c WHERE Id = :conv.Id
        ].Inverse_Conversion_Factor__c, 'And the inverse followed the correction');
    }

    // ── The after-event cache clear ───────────────────────────────────

    @isTest
    static void deletingAConversion_clearsTheServiceCache() {
        UOM_Conversion__c conv = conversion('UCT-CS', 'UCT-PC', 12);
        insert conv;

        Test.startTest();
        // Warm the cache through the service, then delete the rule behind it.
        Decimal warmFactor = UOM_Conversion_Service.getConversionFactor(null, 'UCT-CS', 'UCT-PC');
        delete conv;
        Decimal afterDelete = UOM_Conversion_Service.getConversionFactor(null, 'UCT-CS', 'UCT-PC');
        Test.stopTest();

        System.assertEquals(12, warmFactor, 'The rule resolved while it existed');
        System.assertEquals(1, afterDelete,
            'After the delete the service must NOT serve the cached 12 — the after-delete '
            + 'cache clear is what keeps conversions honest when an admin retires a rule');
    }
}