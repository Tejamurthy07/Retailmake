/**
 * @description Tests for NotificationSettingController — the Notification
 * Settings admin tab: CRUD with save-time schema validation, the shared
 * describe plumbing, the test-fire button and the delivery log.
 *
 * The save-time guards get the weight. Event_Object__c and the two field-name
 * slots are free text precisely so admins can onboard any object without a
 * deploy — which means a typo would otherwise create a rule that silently
 * never fires or never resolves a recipient. Failing loudly at save time is
 * the whole contract.
 */
@isTest
private class NotificationSettingControllerTest {

    @testSetup
    static void setupTestData() {
        insert TestDataFactory.createAccount('NSC Outlet', 'Retailer');
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Notification_Setting__c setting(String eventObject, String eventType) {
        return new Notification_Setting__c(
            Event_Object__c = eventObject,
            Event_Type__c = eventType,
            Recipient_Type__c = 'Specific User',
            Recipient_User__c = UserInfo.getUserId(),
            Channel_InApp__c = true,
            Is_Active__c = true
        );
    }

    private static Notification_Log__c log(Integer minutesAgo) {
        return new Notification_Log__c(
            Channel__c = 'In-App',
            Status__c = 'Sent',
            Event_Type__c = 'Approved',
            Subject__c = 'Log ' + minutesAgo,
            Sent_At__c = Datetime.now().addMinutes(-minutesAgo)
        );
    }

    private static Boolean saveThrows(Notification_Setting__c s) {
        try {
            NotificationSettingController.saveSetting(s);
            return false;
        } catch (AuraHandledException e) {
            return true;
        }
    }

    /**
     * KNOWN DEFECT — saveSetting cannot complete successfully. After the
     * upsert commits, it re-queries with dynamic SOQL bound as ':setting.Id',
     * and dynamic SOQL only resolves SIMPLE bind variables — a dotted
     * expression throws 'System.QueryException: Variable does not exist:
     * setting.Id'. So every valid save PERSISTS the record and then blows up
     * before returning it, which the UI surfaces as an error toast on a save
     * that actually worked. Fix (one line in saveSetting): hoist the id into
     * a local — `Id savedId = setting.Id;` — and bind ':savedId' in the query.
     * Once fixed, replace calls to this helper with direct saveSetting calls
     * asserting the returned record.
     */
    private static void saveDespiteRequeryDefect(Notification_Setting__c s) {
        try {
            NotificationSettingController.saveSetting(s);
            System.assert(false,
                'KNOWN DEFECT no longer reproduces — saveSetting returned normally. '
                + 'The :setting.Id bind was fixed; simplify these tests to use the return value.');
        } catch (QueryException e) {
            System.assert(e.getMessage().contains('setting.Id'),
                'The failure is the dotted bind variable, nothing else: ' + e.getMessage());
        }
    }

    // ── getAllSettings ────────────────────────────────────────────────

    @isTest
    static void allSettings_orderedByObjectThenEvent_withResolvedNames() {
        insert new List<Notification_Setting__c>{
            setting('Sales_Order__c', 'Rejected'),
            setting('Account', 'Approved'),
            setting('Sales_Order__c', 'Approved')
        };

        Test.startTest();
        List<Notification_Setting__c> rows = NotificationSettingController.getAllSettings();
        Test.stopTest();

        System.assertEquals(3, rows.size(), 'Every setting listed');
        System.assertEquals('Account', rows[0].Event_Object__c, 'Ordered by object first');
        System.assertEquals('Approved', rows[1].Event_Type__c, 'Then by event within Sales Order');
        System.assertEquals('Rejected', rows[2].Event_Type__c, 'Rejected after Approved');
        System.assertNotEquals(null, rows[0].Recipient_User__r.Name,
            'The recipient renders as a person, not an id');
    }

    // ── saveSetting: the schema guards ────────────────────────────────

    @isTest
    static void save_nullSetting_isRejected() {
        Test.startTest();
        System.assert(saveThrows(null), 'Nothing to save');
        Test.stopTest();
    }

    @isTest
    static void save_unknownObject_isRejectedAndNothingPersists() {
        Test.startTest();
        System.assert(saveThrows(setting('Not_An_Object__c', 'Approved')),
            'A typo in the free-text object name must fail loudly, not create a rule that '
            + 'silently never fires');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Notification_Setting__c],
            'Nothing was persisted');
    }

    @isTest
    static void save_unknownCriteriaOrRecipientField_isRejected() {
        Notification_Setting__c badCriteria = setting('Account', 'Approved');
        badCriteria.Criteria_Field__c = 'No_Such_Field__c';
        Notification_Setting__c badRecipient = setting('Account', 'Approved');
        badRecipient.Recipient_Field__c = 'Also_Missing__c';

        Test.startTest();
        System.assert(saveThrows(badCriteria),
            'A criteria field that does not exist would make the rule never match');
        System.assert(saveThrows(badRecipient),
            'And a missing recipient field would make it never resolve anyone');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Notification_Setting__c], 'Neither saved');
    }

    @isTest
    static void save_customRelationshipPath_isAcceptedOnItsRoot() {
        Notification_Setting__c pathed = setting('Account', 'Approved');
        pathed.Criteria_Field__c = 'Territory__r.Name';

        Test.startTest();
        saveDespiteRequeryDefect(pathed);
        Test.stopTest();

        List<Notification_Setting__c> saved =
            [SELECT Criteria_Field__c FROM Notification_Setting__c];
        System.assertEquals(1, saved.size(),
            'The path passed validation and the record committed before the re-query broke');
        System.assertEquals('Territory__r.Name', saved[0].Criteria_Field__c,
            'A custom relationship path validates on its root (Territory__c exists) — the '
            + 'dispatcher degrades safely on a broken tail, so only the root is checked');
    }

    /**
     * KNOWN LIMITATION — validateFieldName maps a path's root via __r -> __c,
     * which only works for CUSTOM relationships. A standard path like
     * 'Owner.Name' keys to 'owner', but the field map holds 'ownerid', so every
     * standard relationship path is rejected even though the dispatcher could
     * follow it. An admin wanting criteria on the owner has to use OwnerId
     * directly. If standard paths should be allowed, the root mapping needs a
     * relationship-name lookup rather than the string replace; this test should
     * then be rewritten to assert acceptance.
     */
    @isTest
    static void save_KNOWN_LIMITATION_standardRelationshipPathIsRejected() {
        Notification_Setting__c pathed = setting('Account', 'Approved');
        pathed.Criteria_Field__c = 'Owner.Name';

        Test.startTest();
        System.assert(saveThrows(pathed),
            'Owner.Name is a valid merge path, but the root check cannot map "Owner" to '
            + '"OwnerId", so the save is refused — pinned as the current behaviour');
        Test.stopTest();
    }

    @isTest
    static void save_fieldOnRecordWithoutTheField_isRejected() {
        Notification_Setting__c incomplete = setting('Account', 'Approved');
        incomplete.Recipient_Type__c = 'Field on Record';
        // Recipient_Field__c deliberately blank.

        Test.startTest();
        System.assert(saveThrows(incomplete),
            '"Field on Record" without naming the field can never resolve a recipient');
        Test.stopTest();
    }

    @isTest
    static void save_fieldOnRecordWithARealLookup_succeeds() {
        Notification_Setting__c complete = setting('Account', 'Approved');
        complete.Recipient_Type__c = 'Field on Record';
        complete.Recipient_Field__c = 'OwnerId';

        Test.startTest();
        saveDespiteRequeryDefect(complete);
        Test.stopTest();

        List<Notification_Setting__c> saved =
            [SELECT Recipient_Field__c FROM Notification_Setting__c];
        System.assertEquals(1, saved.size(), 'A properly wired Field on Record rule commits');
        System.assertEquals('OwnerId', saved[0].Recipient_Field__c, 'With its field kept');
    }

    @isTest
    static void save_updatesAnExistingSettingInPlace() {
        Notification_Setting__c original = setting('Account', 'Approved');
        insert original;

        Test.startTest();
        original.Event_Type__c = 'Rejected';
        saveDespiteRequeryDefect(original);
        Test.stopTest();

        List<Notification_Setting__c> saved =
            [SELECT Event_Type__c FROM Notification_Setting__c];
        System.assertEquals(1, saved.size(), 'Re-saving never duplicates');
        System.assertEquals('Rejected', saved[0].Event_Type__c,
            'The same record carries the new event');
    }

    // ── deleteSetting ─────────────────────────────────────────────────

    @isTest
    static void delete_removesTheSettingAndIgnoresNull() {
        Notification_Setting__c s = setting('Account', 'Approved');
        insert s;

        Test.startTest();
        NotificationSettingController.deleteSetting(null);
        System.assertEquals(1, [SELECT COUNT() FROM Notification_Setting__c],
            'A null id deletes nothing');
        NotificationSettingController.deleteSetting(s.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Notification_Setting__c],
            'The setting is gone');
    }

    // ── Describe plumbing ─────────────────────────────────────────────

    @isTest
    static void picklistOptions_driveAllFourDropdowns() {
        Test.startTest();
        Map<String, List<Map<String, String>>> opts =
            NotificationSettingController.getPicklistOptions();
        Test.stopTest();

        System.assertEquals(4, opts.size(), 'Four dropdowns come from this one call');
        System.assert(!opts.get('Event_Object__c').isEmpty(),
            'Objects come from the live schema, shared with the Approval Rules window');
        Set<String> eventTypes = new Set<String>();
        for (Map<String, String> o : opts.get('Event_Type__c')) eventTypes.add(o.get('value'));
        System.assert(eventTypes.contains('Approved'), 'Event types include Approved');
        System.assert(!opts.get('Recipient_Type__c').isEmpty(), 'Recipient types populated');
        System.assert(!opts.get('Criteria_Operator__c').isEmpty(), 'Operators populated');
    }

    @isTest
    static void objectFields_referenceFilter_returnsOnlyUserPointingLookups() {
        Test.startTest();
        List<Map<String, String>> refs =
            NotificationSettingController.getObjectFields('Account', 'reference');
        List<Map<String, String>> blankObject =
            NotificationSettingController.getObjectFields('', 'reference');
        List<Map<String, String>> unknownObject =
            NotificationSettingController.getObjectFields('Nope__c', 'reference');
        Test.stopTest();

        Set<String> names = new Set<String>();
        for (Map<String, String> r : refs) names.add(r.get('value'));
        System.assert(names.contains('OwnerId'),
            'OwnerId points at User, so it can hold a notification recipient');
        System.assert(!names.contains('ParentId'),
            'ParentId points at Account — a lookup that cannot hold a User is useless as a '
            + 'recipient and must not be offered');
        System.assertEquals(0, blankObject.size(), 'No object, no fields');
        System.assertEquals(0, unknownObject.size(), 'Unknown object handled quietly');
    }

    @isTest
    static void objectFields_otherFiltersDelegateToTheSharedProvider() {
        Test.startTest();
        List<Map<String, String>> numerics =
            NotificationSettingController.getObjectFields('Lead', 'numeric');
        List<Map<String, String>> statusValues =
            NotificationSettingController.getFieldPicklistValues('Lead', 'Status');
        Test.stopTest();

        Set<String> names = new Set<String>();
        for (Map<String, String> f : numerics) names.add(f.get('value'));
        System.assert(names.contains('NumberOfEmployees'),
            'The non-reference path is the same shared describe the Approval window uses');
        System.assert(!statusValues.isEmpty(), 'And picklist values delegate the same way');
    }

    // ── searchUsers ───────────────────────────────────────────────────

    @isTest
    static void searchUsers_blankTermListsActiveUsers_termNarrows() {
        Test.startTest();
        List<Map<String, String>> unfiltered = NotificationSettingController.searchUsers('');
        List<Map<String, String>> noMatch =
            NotificationSettingController.searchUsers('Zzqqxxnobody');
        Test.stopTest();

        System.assert(!unfiltered.isEmpty(),
            'A blank term opens the picker with active users rather than an empty list');
        System.assert(unfiltered.size() <= 20, 'Capped at twenty');
        for (Map<String, String> u : unfiltered) {
            System.assert(String.isNotBlank(u.get('label')), 'Each row is a named person');
        }
        System.assertEquals(0, noMatch.size(), 'A miss is empty, not an error');
    }

    // ── testFireRule ──────────────────────────────────────────────────

    @isTest
    static void testFire_guardsNullInactiveAndEmptyObject() {
        Notification_Setting__c inactive = setting('Account', 'Approved');
        inactive.Is_Active__c = false;
        insert inactive;
        Notification_Setting__c empty = setting('Claim__c', 'Approved');
        insert empty;   // Claim__c exists but has no rows in this test context

        Test.startTest();
        Integer rejected = 0;
        try { NotificationSettingController.testFireRule(null); }
        catch (AuraHandledException e) { rejected++; }
        try { NotificationSettingController.testFireRule(inactive.Id); }
        catch (AuraHandledException e) { rejected++; }
        try { NotificationSettingController.testFireRule(empty.Id); }
        catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(3, rejected,
            'No id, an inactive rule, and an object with no records to test against are '
            + 'each refused with their own explanation');
    }

    @isTest
    static void testFire_dispatchesAgainstTheNewestRecordAndReportsTheCount() {
        Notification_Setting__c rule = setting('Account', 'Approved');
        insert rule;

        Test.startTest();
        String status = NotificationSettingController.testFireRule(rule.Id);
        Test.stopTest();

        System.assert(status.startsWith('Test sent'),
            'The rule fired end-to-end and the toast reports it: ' + status);
        System.assert([SELECT COUNT() FROM Notification_Log__c] > 0,
            'With the dispatch audited in the log — the same trail getRecentLogs reads');
    }

    // ── getRecentLogs ─────────────────────────────────────────────────

    @isTest
    static void recentLogs_newestFirstWithTheLimitClamped() {
        insert new List<Notification_Log__c>{ log(30), log(10), log(20) };

        Test.startTest();
        List<Notification_Log__c> limited = NotificationSettingController.getRecentLogs(2);
        List<Notification_Log__c> defaulted = NotificationSettingController.getRecentLogs(null);
        List<Notification_Log__c> silly = NotificationSettingController.getRecentLogs(9999);
        Test.stopTest();

        System.assertEquals(2, limited.size(), 'The row limit is honoured');
        System.assertEquals('Log 10', limited[0].Subject__c,
            'Newest attempt first — this list answers "why did my alert not arrive?"');
        System.assertEquals('Log 20', limited[1].Subject__c, 'Then the next');
        System.assertEquals(3, defaulted.size(), 'A null limit falls back to the default 50');
        System.assertEquals(3, silly.size(),
            'And a limit beyond 200 is clamped to the default rather than passed to SOQL');
    }
}