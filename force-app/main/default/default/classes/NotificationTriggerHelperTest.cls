/**
 * @description Tests for NotificationTriggerHelper — the bridge that turns
 * trigger activity into canonical notification events.
 *
 * Every assertion reads Notification_Log__c, the dispatcher's audit trail:
 * a log row per (event, recipient) is the externally observable proof that
 * the right canonical event fired for the right records.
 *
 * Fixture ordering matters and is deliberate: records are inserted BEFORE the
 * notification settings exist (so the central TriggerHandler hook dispatches
 * nothing during setup), then settings are created, then resetCache() clears
 * the per-transaction caches — the configured-objects set AND the dedup
 * guard — so the direct helper calls under test are the only dispatch source.
 */
@isTest
private class NotificationTriggerHelperTest {

    private static final String XFER = 'Stock_Transfer__c';

    @testSetup
    static void setupTestData() {
        insert new List<Warehouse__c>{
            new Warehouse__c(Name = 'NTH Source', Warehouse_Code__c = 'NTH01',
                State__c = 'Maharashtra', Warehouse_Type__c = 'Central', Is_Active__c = true),
            new Warehouse__c(Name = 'NTH Dest', Warehouse_Code__c = 'NTH02',
                State__c = 'Gujarat', Warehouse_Type__c = 'Regional', Is_Active__c = true)
        };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static void setting(String objectApi, String eventType) {
        insert new Notification_Setting__c(
            Event_Object__c = objectApi,
            Event_Type__c = eventType,
            Recipient_Type__c = 'Specific User',
            Recipient_User__c = UserInfo.getUserId(),
            Channel_InApp__c = true,
            Is_Active__c = true
        );
    }

    private static Stock_Transfer__c transfer(String status) {
        Stock_Transfer__c t = new Stock_Transfer__c(
            Source_Warehouse__c = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'NTH01'].Id,
            Destination_Warehouse__c = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'NTH02'].Id,
            Transfer_Date__c = Date.today(),
            Status__c = status
        );
        insert t;
        return t;
    }

    /** In-memory version of a record with a given status — no DML, so even
        values outside the picklist can drive the classification logic. */
    private static Stock_Transfer__c version(Id recordId, String status) {
        return new Stock_Transfer__c(Id = recordId, Status__c = status);
    }

    private static Integer logs(String eventType) {
        return [SELECT COUNT() FROM Notification_Log__c WHERE Event_Type__c = :eventType];
    }

    // ── handleInsert ──────────────────────────────────────────────────

    @isTest
    static void insert_firesCreated_andSubmittedForPreSubmittedRows() {
        Stock_Transfer__c draft = transfer('Draft');
        Stock_Transfer__c preSubmitted = transfer('Submitted');
        setting(XFER, 'Created');
        setting(XFER, 'Submitted');
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        NotificationTriggerHelper.handleInsert(
            XFER, new List<SObject>{ draft, preSubmitted });
        Test.stopTest();

        System.assertEquals(2, logs('Created'), 'Every new record raises Created');
        System.assertEquals(1, logs('Submitted'),
            'A record born in a submitted state ALSO raises Submitted — an insert-time '
            + 'submission must not be invisible to approvers');
    }

    @isTest
    static void insert_unconfiguredObject_dispatchesNothing() {
        Stock_Transfer__c t = transfer('Draft');
        // No setting targets Stock_Transfer__c.
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        NotificationTriggerHelper.handleInsert(XFER, new List<SObject>{ t });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Notification_Log__c],
            'An object nobody configured costs one cached query and zero dispatches');
    }

    @isTest
    static void insert_calledTwice_firesOnlyOnce() {
        Stock_Transfer__c t = transfer('Draft');
        setting(XFER, 'Created');
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        NotificationTriggerHelper.handleInsert(XFER, new List<SObject>{ t });
        NotificationTriggerHelper.handleInsert(XFER, new List<SObject>{ t });
        Test.stopTest();

        System.assertEquals(1, logs('Created'),
            'Objects with two trigger handlers (DMS + OMS variants) run the hook twice — '
            + 'the dedup guard must keep the user\'s inbox at one notification');
    }

    // ── handleUpdate: transition routing ──────────────────────────────

    @isTest
    static void update_routesEachTransitionToItsCanonicalEvent() {
        Stock_Transfer__c a = transfer('Draft');
        Stock_Transfer__c b = transfer('Draft');
        Stock_Transfer__c c = transfer('Draft');
        Stock_Transfer__c d = transfer('Draft');
        Stock_Transfer__c e = transfer('Draft');
        for (String evt : new List<String>{ 'Updated', 'Submitted', 'Approved', 'Rejected' }) {
            setting(XFER, evt);
        }
        NotificationTriggerHelper.resetCache();

        // In-memory old/new pairs — no DML, so the classification is tested in
        // isolation from picklist restrictions and the transfer status machine.
        Map<Id, SObject> oldMap = new Map<Id, SObject>{
            a.Id => version(a.Id, 'Draft'), b.Id => version(b.Id, 'Draft'),
            c.Id => version(c.Id, 'Draft'), d.Id => version(d.Id, 'Draft'),
            e.Id => version(e.Id, 'Draft')
        };
        List<SObject> news = new List<SObject>{
            version(a.Id, 'Submitted'),   // default submitted set
            version(b.Id, 'Approved'),    // default approved set
            version(c.Id, 'Rejected'),    // default rejected set
            version(d.Id, 'In_Transit'),  // a transition no set claims
            version(e.Id, 'Draft')        // unchanged
        };

        Test.startTest();
        NotificationTriggerHelper.handleUpdate(XFER, news, oldMap);
        Test.stopTest();

        System.assertEquals(1, logs('Submitted'), 'Draft to Submitted is a submission');
        System.assertEquals(1, logs('Approved'), 'Draft to Approved is an approval');
        System.assertEquals(1, logs('Rejected'), 'Draft to Rejected is a rejection');
        System.assertEquals(2, logs('Updated'),
            'An unclaimed transition and an unchanged record both fall through to the '
            + 'generic Updated — never silently dropped');
    }

    @isTest
    static void update_approvalMatrixOverridesTheConventionalDefaults() {
        Stock_Transfer__c t = transfer('Draft');
        setting(XFER, 'Approved');
        setting(XFER, 'Updated');
        // The approval matrix declares that for this object, 'Received' is the
        // approved state. The conventional defaults would have filed it under
        // plain Updated.
        insert new Approval_Rule__c(
            Object_Process__c = XFER,
            Approval_Level__c = 1,
            Approver_Type__c = 'Manager',
            Is_Active__c = true,
            Status_Field_API_Name__c = 'Status__c',
            Status_Value_On_Approve__c = 'Received'
        );
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        NotificationTriggerHelper.handleUpdate(
            XFER,
            new List<SObject>{ version(t.Id, 'Received') },
            new Map<Id, SObject>{ t.Id => version(t.Id, 'Draft') });
        Test.stopTest();

        System.assertEquals(1, logs('Approved'),
            'The approval matrix is the source of truth for what a status means — '
            + 'Received counts as Approved because the matrix says so');
        System.assertEquals(0, logs('Updated'),
            'And it does NOT additionally fall through to the generic event');
    }

    @isTest
    static void update_objectWithoutAStatusField_alwaysRaisesUpdated() {
        Account acct = TestDataFactory.createAndInsertAccount('NTH Outlet', 'Retailer');
        setting('Account', 'Updated');
        setting('Account', 'Approved');
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        NotificationTriggerHelper.handleUpdate(
            'Account',
            new List<SObject>{ new Account(Id = acct.Id, Name = 'NTH Outlet 2') },
            new Map<Id, SObject>{ acct.Id => new Account(Id = acct.Id, Name = 'NTH Outlet') });
        Test.stopTest();

        System.assertEquals(1, logs('Updated'),
            'Account has no Status__c, so the fallback map is fieldless and every change '
            + 'is the generic Updated');
        System.assertEquals(0, logs('Approved'),
            'Without a status field nothing can ever look like an approval');
    }

    // ── Explicit-control variants ─────────────────────────────────────

    @isTest
    static void explicit_fromInsert_usesTheCallerSuppliedSets() {
        Stock_Transfer__c t = transfer('Draft');
        setting(XFER, 'Created');
        setting(XFER, 'Submitted');
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        // The caller declares that 'Draft' means submitted — proving the
        // explicit sets are honoured over any configuration or default.
        NotificationTriggerHelper.fromInsert(
            XFER, new List<SObject>{ t }, 'Status__c', new Set<String>{ 'Draft' });
        Test.stopTest();

        System.assertEquals(1, logs('Created'), 'Created always fires');
        System.assertEquals(1, logs('Submitted'),
            'The caller\'s own submitted-set decides, not the conventional one');
    }

    @isTest
    static void explicit_fromUpdate_usesTheCallerSuppliedSets() {
        Stock_Transfer__c t = transfer('Draft');
        setting(XFER, 'Rejected');
        setting(XFER, 'Updated');
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        // Caller says 'In_Transit' means rejected for their process.
        NotificationTriggerHelper.fromUpdate(
            XFER,
            new List<SObject>{ version(t.Id, 'In_Transit') },
            new Map<Id, SObject>{ t.Id => version(t.Id, 'Draft') },
            'Status__c',
            null,
            null,
            new Set<String>{ 'In_Transit' });
        Test.stopTest();

        System.assertEquals(1, logs('Rejected'),
            'The explicit rejected-set routes the transition');
        System.assertEquals(0, logs('Updated'), 'Not double-filed as generic Updated');
    }

    // ── Guard rails ───────────────────────────────────────────────────

    @isTest
    static void emptyAndNullInputs_areSilentNoOps() {
        setting(XFER, 'Created');
        NotificationTriggerHelper.resetCache();

        Test.startTest();
        NotificationTriggerHelper.handleInsert(XFER, null);
        NotificationTriggerHelper.handleInsert(XFER, new List<SObject>());
        NotificationTriggerHelper.handleInsert(null, new List<SObject>{ new Account() });
        NotificationTriggerHelper.handleUpdate(XFER, null, null);
        NotificationTriggerHelper.fromInsert(XFER, null, null, null);
        NotificationTriggerHelper.fromUpdate(XFER, null, null, null, null, null, null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Notification_Log__c],
            'Nothing to dispatch, nothing dispatched, nothing thrown');
    }
}