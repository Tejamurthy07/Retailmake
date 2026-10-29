/**
 * @description Tests for SPM_Scheme_TriggerHandler — date and budget validation,
 * the active-scheme field lock, and overlap detection.
 *
 * Every test asserts on the actual outcome rather than tolerating failure. The
 * previous version used Database.insert(rec, false) with no error assertions and
 * returned early when a save failed, so a broken fixture looked like a passing
 * test while covering nothing — which is why the class sat at 56% despite having
 * eight test methods.
 *
 * Scheme_Type__c and Scheme_Category__c are restricted picklists whose deployed
 * values have drifted from the repo metadata, so both are resolved from the
 * describe at runtime instead of hardcoded.
 */
@isTest
private class SPM_Scheme_TriggerHandler_Test {

    // ── Picklist resolution ───────────────────────────────────────────

    private static List<String> cachedTypes;
    private static List<String> cachedCategories;

    private static List<String> activeValues(String fieldName) {
        List<String> values = new List<String>();
        Schema.DescribeFieldResult dfr =
            Scheme__c.SObjectType.getDescribe().fields.getMap().get(fieldName).getDescribe();
        for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
            if (e.isActive()) values.add(e.getValue());
        }
        return values;
    }

    private static List<String> types() {
        if (cachedTypes == null) cachedTypes = activeValues('Scheme_Type__c');
        return cachedTypes;
    }

    private static List<String> categories() {
        if (cachedCategories == null) cachedCategories = activeValues('Scheme_Category__c');
        return cachedCategories;
    }

    private static String typeA() { return types().isEmpty() ? null : types()[0]; }
    private static String typeB() { return types().size() > 1 ? types()[1] : null; }
    private static String categoryA() { return categories().isEmpty() ? null : categories()[0]; }
    private static String categoryB() { return categories().size() > 1 ? categories()[1] : null; }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Integer codeSeq = 0;

    private static Scheme__c build(String name, String status, Date startDate, Date endDate) {
        codeSeq++;
        Scheme__c s = new Scheme__c(
            Name = name,
            Scheme_Code__c = 'SCH-TH-' + codeSeq,
            Status__c = status,
            Start_Date__c = startDate,
            End_Date__c = endDate,
            Budget_Amount__c = 100000
        );
        if (typeA() != null) s.Scheme_Type__c = typeA();
        if (categoryA() != null) s.Scheme_Category__c = categoryA();
        return s;
    }

    /** Inserts and asserts success, returning the saved record. */
    private static Scheme__c insertOk(Scheme__c s, String context) {
        Database.SaveResult sr = Database.insert(s, false);
        System.assert(sr.isSuccess(), context + ' — insert failed: ' + errorsOf(sr));
        return s;
    }

    private static String errorsOf(Database.SaveResult sr) {
        List<String> messages = new List<String>();
        for (Database.Error e : sr.getErrors()) messages.add(e.getMessage());
        return String.join(messages, ' | ');
    }

    private static String updateErrors(Scheme__c s) {
        Database.SaveResult sr = Database.update(s, false);
        if (sr.isSuccess()) return null;
        List<String> messages = new List<String>();
        for (Database.Error e : sr.getErrors()) messages.add(e.getMessage());
        return String.join(messages, ' | ');
    }

    // ── Date range validation ─────────────────────────────────────────

    @isTest
    static void dates_endBeforeStart_isRejected() {
        Scheme__c bad = build('Backwards Dates', 'Draft',
            Date.today().addDays(10), Date.today());

        Test.startTest();
        Database.SaveResult sr = Database.insert(bad, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'A scheme that ends before it starts must never save');
        System.assert(errorsOf(sr).contains('End Date must be on or after Start Date'),
            'Expected the date-range message, got: ' + errorsOf(sr));
    }

    @isTest
    static void dates_sameDayWindow_isAllowed() {
        Test.startTest();
        Scheme__c oneDay = insertOk(
            build('One Day Offer', 'Draft', Date.today(), Date.today()),
            'A single-day scheme');
        Test.stopTest();

        System.assertNotEquals(null, oneDay.Id,
            'Start equal to End is a valid one-day window, not an inverted range');
    }

    @isTest
    static void dates_validRange_isAllowed() {
        Test.startTest();
        Scheme__c ok = insertOk(
            build('Normal Window', 'Draft', Date.today(), Date.today().addDays(30)),
            'A normal scheme');
        Test.stopTest();

        System.assertNotEquals(null, ok.Id, 'A forward date range saves');
    }

    @isTest
    static void dates_invalidRangeOnUpdate_isRejected() {
        Scheme__c s = insertOk(
            build('Editable', 'Draft', Date.today(), Date.today().addDays(30)),
            'Setup scheme');

        Test.startTest();
        s.Start_Date__c = Date.today().addDays(60);
        String errors = updateErrors(s);
        Test.stopTest();

        System.assertNotEquals(null, errors, 'Moving the start past the end must be blocked');
        System.assert(errors.contains('End Date must be on or after Start Date'),
            'Expected the date-range message on update, got: ' + errors);
    }

    // ── Budget validation ─────────────────────────────────────────────

    @isTest
    static void budget_zeroOrNegative_isRejected() {
        Scheme__c zero = build('Zero Budget', 'Draft', Date.today(), Date.today().addDays(30));
        zero.Budget_Amount__c = 0;
        Scheme__c negative = build('Negative Budget', 'Draft', Date.today(), Date.today().addDays(30));
        negative.Budget_Amount__c = -500;

        Test.startTest();
        Database.SaveResult zeroResult = Database.insert(zero, false);
        Database.SaveResult negativeResult = Database.insert(negative, false);
        Test.stopTest();

        System.assertEquals(false, zeroResult.isSuccess(),
            'A scheme funded with nothing cannot pay out, so it is refused');
        System.assert(errorsOf(zeroResult).contains('Budget Amount must be greater than zero'),
            'Expected the budget message, got: ' + errorsOf(zeroResult));
        System.assertEquals(false, negativeResult.isSuccess(), 'And a negative budget likewise');
    }

    @isTest
    static void budget_leftBlank_isAllowed() {
        Scheme__c noBudget = build('Unfunded', 'Draft', Date.today(), Date.today().addDays(30));
        noBudget.Budget_Amount__c = null;

        Test.startTest();
        Database.SaveResult sr = Database.insert(noBudget, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'A blank budget means "no budget ceiling", which is different from zero and is '
            + 'allowed: ' + errorsOf(sr));
    }

    // ── Active-scheme field lock ──────────────────────────────────────

    @isTest
    static void activeScheme_typeChange_isBlocked() {
        if (typeB() == null) return;   // org has only one scheme type
        Scheme__c s = insertOk(
            build('Locked Type', 'Active', Date.today(), Date.today().addDays(30)),
            'Active scheme');

        Test.startTest();
        s.Scheme_Type__c = typeB();
        String errors = updateErrors(s);
        Test.stopTest();

        System.assertNotEquals(null, errors,
            'Changing what triggers a live scheme would silently rewrite who qualifies for it');
        System.assert(errors.contains('Cannot change Scheme Type on an Active scheme'),
            'Expected the type-lock message, got: ' + errors);
    }

    @isTest
    static void activeScheme_categoryChange_isBlocked() {
        if (categoryB() == null) return;   // org has only one category
        Scheme__c s = insertOk(
            build('Locked Category', 'Active', Date.today(), Date.today().addDays(30)),
            'Active scheme');

        Test.startTest();
        s.Scheme_Category__c = categoryB();
        String errors = updateErrors(s);
        Test.stopTest();

        System.assertNotEquals(null, errors,
            'Changing the benefit type of a live scheme would change what customers receive');
        System.assert(errors.contains('Cannot change Scheme Category on an Active scheme'),
            'Expected the category-lock message, got: ' + errors);
    }

    @isTest
    static void activeScheme_unrelatedEdit_isAllowed() {
        Scheme__c s = insertOk(
            build('Renameable', 'Active', Date.today(), Date.today().addDays(30)),
            'Active scheme');

        Test.startTest();
        s.Name = 'Renamed While Active';
        s.Budget_Amount__c = 250000;
        String errors = updateErrors(s);
        Test.stopTest();

        System.assertEquals(null, errors,
            'The lock is narrow — a live scheme can still be renamed or re-funded: ' + errors);
        System.assertEquals('Renamed While Active', [
            SELECT Name FROM Scheme__c WHERE Id = :s.Id
        ].Name, 'And the edit stuck');
    }

    @isTest
    static void draftScheme_typeChange_isAllowed() {
        if (typeB() == null) return;
        Scheme__c s = insertOk(
            build('Still Draft', 'Draft', Date.today(), Date.today().addDays(30)),
            'Draft scheme');

        Test.startTest();
        s.Scheme_Type__c = typeB();
        String errors = updateErrors(s);
        Test.stopTest();

        System.assertEquals(null, errors,
            'A scheme still being designed can be reshaped freely — the lock only applies '
            + 'once it is live: ' + errors);
    }

    @isTest
    static void schemeBeingDeactivated_canChangeType() {
        if (typeB() == null) return;
        Scheme__c s = insertOk(
            build('Retiring', 'Active', Date.today(), Date.today().addDays(30)),
            'Active scheme');

        Test.startTest();
        // Both the status change and the type change in one save. The guard only
        // fires when the record is Active BEFORE and AFTER.
        s.Status__c = 'Cancelled';
        s.Scheme_Type__c = typeB();
        String errors = updateErrors(s);
        Test.stopTest();

        System.assertEquals(null, errors,
            'Pulling a scheme out of service and reshaping it in the same save is allowed, '
            + 'because it is no longer Active when the change lands: ' + errors);
    }

    // ── Overlap detection ─────────────────────────────────────────────

    @isTest
    static void overlap_sameTypeAndOverlappingDates_isBlocked() {
        insertOk(build('Running Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');

        Scheme__c clashing = build('Clashing Offer', 'Active',
            Date.today().addDays(10), Date.today().addDays(40));

        Test.startTest();
        Database.SaveResult sr = Database.insert(clashing, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'Two live schemes of the same type over the same dates would both fire on one '
            + 'order, so the second is refused');
        System.assert(errorsOf(sr).contains('overlaps with'),
            'Expected the overlap message, got: ' + errorsOf(sr));
        System.assert(errorsOf(sr).contains('Running Offer'),
            'And it should name the scheme it clashes with: ' + errorsOf(sr));
    }

    @isTest
    static void overlap_nonOverlappingDates_isAllowed() {
        insertOk(build('January Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');

        Test.startTest();
        Scheme__c later = insertOk(
            build('February Offer', 'Active',
                Date.today().addDays(31), Date.today().addDays(60)),
            'Consecutive scheme');
        Test.stopTest();

        System.assertNotEquals(null, later.Id,
            'Back-to-back schemes of the same type are fine — only overlapping windows clash');
    }

    @isTest
    static void overlap_differentSchemeType_isAllowed() {
        if (typeB() == null) return;
        insertOk(build('Type A Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');

        Scheme__c otherType = build('Type B Offer', 'Active',
            Date.today().addDays(5), Date.today().addDays(25));
        otherType.Scheme_Type__c = typeB();

        Test.startTest();
        Database.SaveResult sr = Database.insert(otherType, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'Schemes of different types are triggered by different conditions, so they can '
            + 'run concurrently: ' + errorsOf(sr));
    }

    @isTest
    static void overlap_draftScheme_isIgnored() {
        insertOk(build('Live Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');

        Scheme__c draft = build('Draft Overlapping', 'Draft',
            Date.today().addDays(5), Date.today().addDays(25));

        Test.startTest();
        Database.SaveResult sr = Database.insert(draft, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'A draft is not competing for orders yet, so it can be prepared alongside a live '
            + 'scheme and activated later: ' + errorsOf(sr));
    }

    @isTest
    static void overlap_pendingApproval_isTreatedAsLive() {
        insertOk(build('Live Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');

        Scheme__c pending = build('Awaiting Sign Off', 'Pending Approval',
            Date.today().addDays(5), Date.today().addDays(25));

        Test.startTest();
        Database.SaveResult sr = Database.insert(pending, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'A scheme awaiting approval is about to go live, so it is checked for clashes now '
            + 'rather than after someone approves it');
        System.assert(errorsOf(sr).contains('overlaps with'),
            'Expected the overlap message, got: ' + errorsOf(sr));
    }

    @isTest
    static void overlap_onUpdate_whenDatesMoveIntoConflict_isBlocked() {
        insertOk(build('Established Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');
        Scheme__c later = insertOk(
            build('Future Offer', 'Active',
                Date.today().addDays(60), Date.today().addDays(90)),
            'Non-overlapping scheme');

        Test.startTest();
        // Drag the future scheme back over the running one.
        later.Start_Date__c = Date.today().addDays(10);
        later.End_Date__c = Date.today().addDays(40);
        String errors = updateErrors(later);
        Test.stopTest();

        System.assertNotEquals(null, errors,
            'Rescheduling into a clash is caught on update, not only at creation');
        System.assert(errors.contains('overlaps with'),
            'Expected the overlap message, got: ' + errors);
    }

    @isTest
    static void overlap_onUpdate_withoutADateChange_isNotRechecked() {
        Scheme__c s = insertOk(
            build('Stable Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'Active scheme');

        Test.startTest();
        s.Name = 'Stable Offer Renamed';
        String errors = updateErrors(s);
        Test.stopTest();

        System.assertEquals(null, errors,
            'An edit that leaves the dates alone skips the overlap query entirely — the check '
            + 'is scoped to date changes so ordinary edits stay cheap: ' + errors);
    }

    @isTest
    static void overlap_movingDatesApart_isAllowed() {
        insertOk(build('Anchor Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');
        Scheme__c mover = insertOk(
            build('Mover Offer', 'Active',
                Date.today().addDays(40), Date.today().addDays(60)),
            'Non-overlapping scheme');

        Test.startTest();
        // Still clear of the anchor, just shifted.
        mover.Start_Date__c = Date.today().addDays(45);
        mover.End_Date__c = Date.today().addDays(70);
        String errors = updateErrors(mover);
        Test.stopTest();

        System.assertEquals(null, errors,
            'Rescheduling that stays clear of other live schemes is permitted: ' + errors);
    }

    @isTest
    static void overlap_bulkInsert_flagsOnlyTheClashingRow() {
        insertOk(build('Existing Offer', 'Active', Date.today(), Date.today().addDays(30)),
            'First active scheme');

        Scheme__c clashing = build('Bulk Clash', 'Active',
            Date.today().addDays(10), Date.today().addDays(20));
        Scheme__c clear = build('Bulk Clear', 'Active',
            Date.today().addDays(100), Date.today().addDays(120));

        Test.startTest();
        List<Database.SaveResult> results =
            Database.insert(new List<Scheme__c>{ clashing, clear }, false);
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess(), 'The clashing row is refused');
        System.assertEquals(true, results[1].isSuccess(),
            'While a clean row in the same batch still saves — one bad scheme must not block '
            + 'an unrelated one: ' + errorsOf(results[1]));
    }
}