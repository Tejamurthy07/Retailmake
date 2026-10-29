/**
 * @description Tests for Target_Trigger — derives Period_Month__c and
 * Period_Year__c from Period_Start__c.
 *
 * The rule is fill-don't-correct: each field is only written when it is null,
 * so a value an admin typed is never overwritten. That is a deliberate choice
 * and worth pinning, because it has a consequence — changing Period_Start__c on
 * an existing record does NOT move the month and year that were derived from
 * the old date. Those tests are named so the behaviour is discoverable rather
 * than something the next person has to infer from the code.
 *
 * Period_Month__c is a restricted picklist holding exactly the twelve names the
 * trigger writes, so a wrong name here is a save-time failure rather than a
 * silent mislabel — which is why one test walks all twelve.
 */
@isTest
private class Target_Trigger_Test {

    @testSetup
    static void setupTestData() {
        TestDataFactory.createAndInsertTerritory('TT Territory', 'TER-TT01');
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    /**
     * Cached deliberately: newTarget() is called once per record, so querying
     * here would spend one SOQL call per row and blow the governor limit on the
     * 200-record bulk test.
     */
    private static Id cachedTerritoryId;

    private static Id territoryId() {
        if (cachedTerritoryId == null) {
            cachedTerritoryId = [
                SELECT Id FROM Territory_Master__c WHERE Territory_Code__c = 'TER-TT01' LIMIT 1
            ].Id;
        }
        return cachedTerritoryId;
    }

    private static Target__c newTarget(Date periodStart) {
        return new Target__c(
            Salesperson__c = UserInfo.getUserId(),
            Territory__c = territoryId(),
            Period_Start__c = periodStart,
            Target_Value__c = 100000,
            Achievement_Value__c = 0
        );
    }

    private static Target__c reload(Id targetId) {
        return [
            SELECT Id, Period_Start__c, Period_Month__c, Period_Year__c
            FROM Target__c WHERE Id = :targetId
        ];
    }

    // ── Derivation on insert ──────────────────────────────────────────

    @isTest
    static void insert_derivesMonthAndYearFromThePeriodStart() {
        Target__c target = newTarget(Date.newInstance(2026, 3, 15));

        Test.startTest();
        insert target;
        Test.stopTest();

        Target__c saved = reload(target.Id);
        System.assertEquals('March', saved.Period_Month__c,
            'The month name is derived so reports can group without parsing a date');
        System.assertEquals('2026', saved.Period_Year__c, 'And the year as text');
    }

    @isTest
    static void insert_derivesEveryMonthCorrectly() {
        Map<Integer, String> expected = new Map<Integer, String>{
            1 => 'January', 2 => 'February', 3 => 'March', 4 => 'April',
            5 => 'May', 6 => 'June', 7 => 'July', 8 => 'August',
            9 => 'September', 10 => 'October', 11 => 'November', 12 => 'December'
        };
        List<Target__c> targets = new List<Target__c>();
        for (Integer m = 1; m <= 12; m++) {
            targets.add(newTarget(Date.newInstance(2026, m, 1)));
        }

        Test.startTest();
        insert targets;
        Test.stopTest();

        for (Target__c saved : [
            SELECT Period_Start__c, Period_Month__c FROM Target__c WHERE Id IN :targets
        ]) {
            System.assertEquals(expected.get(saved.Period_Start__c.month()), saved.Period_Month__c,
                'Month ' + saved.Period_Start__c.month() + ' must map to its name — the field is '
                + 'a restricted picklist, so an off-by-one here is a save failure, not a typo');
        }
    }

    @isTest
    static void insert_handlesTheYearBoundary() {
        Target__c december = newTarget(Date.newInstance(2025, 12, 31));
        Target__c january = newTarget(Date.newInstance(2026, 1, 1));

        Test.startTest();
        insert new List<Target__c>{ december, january };
        Test.stopTest();

        Target__c dec = reload(december.Id);
        Target__c jan = reload(january.Id);
        System.assertEquals('December', dec.Period_Month__c, 'Last day of the year');
        System.assertEquals('2025', dec.Period_Year__c, 'Stays in the old year');
        System.assertEquals('January', jan.Period_Month__c, 'First day of the next');
        System.assertEquals('2026', jan.Period_Year__c, 'And rolls the year over');
    }

    @isTest
    static void insert_withNoPeriodStart_leavesBothBlank() {
        Target__c target = newTarget(null);

        Test.startTest();
        insert target;
        Test.stopTest();

        Target__c saved = reload(target.Id);
        System.assertEquals(null, saved.Period_Month__c,
            'With no start date there is nothing to derive from, so the target saves as typed');
        System.assertEquals(null, saved.Period_Year__c, 'Same for the year');
    }

    // ── Fill, do not overwrite ────────────────────────────────────────

    @isTest
    static void insert_keepsAMonthTheUserSuppliedEvenIfItDisagrees() {
        Target__c target = newTarget(Date.newInstance(2026, 3, 15));
        target.Period_Month__c = 'July';

        Test.startTest();
        insert target;
        Test.stopTest();

        System.assertEquals('July', reload(target.Id).Period_Month__c,
            'The trigger fills gaps, it does not correct — a month typed by hand wins over '
            + 'the one implied by the date');
    }

    @isTest
    static void insert_keepsAYearTheUserSupplied() {
        Target__c target = newTarget(Date.newInstance(2026, 3, 15));
        target.Period_Year__c = '2099';

        Test.startTest();
        insert target;
        Test.stopTest();

        System.assertEquals('2099', reload(target.Id).Period_Year__c,
            'Same for the year — an explicit value is left alone');
    }

    @isTest
    static void insert_fillsOnlyTheFieldThatIsMissing() {
        Target__c target = newTarget(Date.newInstance(2026, 3, 15));
        target.Period_Month__c = 'July';   // supplied
        // Period_Year__c left null

        Test.startTest();
        insert target;
        Test.stopTest();

        Target__c saved = reload(target.Id);
        System.assertEquals('July', saved.Period_Month__c, 'The supplied month is untouched');
        System.assertEquals('2026', saved.Period_Year__c,
            'While the missing year is still derived — the two fields are decided independently');
    }

    // ── Update behaviour ──────────────────────────────────────────────

    @isTest
    static void update_refillsAMonthThatWasCleared() {
        Target__c target = newTarget(Date.newInstance(2026, 3, 15));
        insert target;

        Test.startTest();
        target.Period_Month__c = null;
        target.Period_Year__c = null;
        update target;
        Test.stopTest();

        Target__c saved = reload(target.Id);
        System.assertEquals('March', saved.Period_Month__c,
            'Blanking the field hands it back to the trigger, so it repopulates on save');
        System.assertEquals('2026', saved.Period_Year__c, 'Same for the year');
    }

    /**
     * Documents a real consequence of fill-don't-correct: moving the start date
     * on an existing record leaves the month and year describing the OLD date.
     * A target moved from March to July still reads "March" until someone clears
     * the field. If that is not wanted, the trigger would need to compare against
     * the old value rather than checking for null.
     */
    @isTest
    static void update_doesNotRestateAMonthWhenTheStartDateMoves() {
        Target__c target = newTarget(Date.newInstance(2026, 3, 15));
        insert target;
        System.assertEquals('March', reload(target.Id).Period_Month__c, 'Derived on insert');

        Test.startTest();
        target.Period_Start__c = Date.newInstance(2026, 7, 20);
        update target;
        Test.stopTest();

        Target__c saved = reload(target.Id);
        System.assertEquals(Date.newInstance(2026, 7, 20), saved.Period_Start__c,
            'The new start date is stored');
        System.assertEquals('March', saved.Period_Month__c,
            'But the month still describes the old date — it is only filled when null, never '
            + 'corrected, so a rescheduled target reports under the wrong month');
    }

    @isTest
    static void update_thatTouchesNeitherFieldChangesNothing() {
        Target__c target = newTarget(Date.newInstance(2026, 3, 15));
        insert target;

        Test.startTest();
        target.Target_Value__c = 250000;
        update target;
        Test.stopTest();

        Target__c saved = reload(target.Id);
        System.assertEquals('March', saved.Period_Month__c, 'An unrelated edit leaves it alone');
        System.assertEquals('2026', saved.Period_Year__c, 'And the year too');
    }

    // ── Bulk ──────────────────────────────────────────────────────────

    @isTest
    static void bulkInsert_derivesForEveryRecord() {
        List<Target__c> targets = new List<Target__c>();
        for (Integer i = 0; i < 200; i++) {
            // Cycle through the months so the whole map is exercised in bulk.
            targets.add(newTarget(Date.newInstance(2026, Math.mod(i, 12) + 1, 1)));
        }

        Test.startTest();
        insert targets;
        Test.stopTest();

        Integer derived = [
            SELECT COUNT() FROM Target__c
            WHERE Id IN :targets AND Period_Month__c != null AND Period_Year__c != null
        ];
        System.assertEquals(200, derived,
            'Every record in a 200-row load gets its period filled — the loop does no SOQL '
            + 'or DML, so batch size cannot break it');
    }

    @isTest
    static void bulkInsert_mixesSuppliedAndDerivedRows() {
        List<Target__c> targets = new List<Target__c>();
        for (Integer i = 0; i < 10; i++) {
            Target__c t = newTarget(Date.newInstance(2026, 3, 1));
            if (Math.mod(i, 2) == 0) {
                t.Period_Month__c = 'December';   // supplied on the even rows
            }
            targets.add(t);
        }

        Test.startTest();
        insert targets;
        Test.stopTest();

        Integer supplied = [
            SELECT COUNT() FROM Target__c WHERE Id IN :targets AND Period_Month__c = 'December'
        ];
        Integer derived = [
            SELECT COUNT() FROM Target__c WHERE Id IN :targets AND Period_Month__c = 'March'
        ];
        System.assertEquals(5, supplied, 'The rows that carried a month keep it');
        System.assertEquals(5, derived,
            'And the rows that did not get one derived — each row is decided on its own');
    }
}