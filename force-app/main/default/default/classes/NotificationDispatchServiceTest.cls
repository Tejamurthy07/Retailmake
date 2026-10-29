/**
 * @description Tests for NotificationDispatchService, the deprecated shim in
 * front of NotificationDispatcher.
 *
 * A forwarding class is worth testing for one reason: to prove it still
 * forwards. Nothing in Apex calls it — it survives for Flows and org
 * customisations bound to the old name, which the compiler cannot see. So each
 * test drives the shim and asserts against what the REAL engine produces:
 * Notification_Log__c rows (the dispatcher logs every send, including skips)
 * and, for the direct-notify path, the email invocation the platform counts.
 */
@isTest
private class NotificationDispatchServiceTest {

    @testSetup
    static void setupTestData() {
        insert new List<Account>{
            TestDataFactory.createAccount('NDS Outlet One', 'Retailer'),
            TestDataFactory.createAccount('NDS Outlet Two', 'Retailer')
        };

        // One active rule: Account + Approved → in-app to the running user.
        // Everything the shim dispatches in these tests routes through it.
        insert new Notification_Setting__c(
            Event_Object__c = 'Account',
            Event_Type__c = 'Approved',
            Recipient_Type__c = 'Specific User',
            Recipient_User__c = UserInfo.getUserId(),
            Channel_InApp__c = true,
            Channel_Email__c = false,
            Channel_SMS__c = false,
            Channel_WhatsApp__c = false,
            Is_Active__c = true
        );
    }

    private static Id outlet(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1].Id;
    }

    private static List<Notification_Log__c> logs() {
        return [
            SELECT Event_Type__c, Source_Record_Id__c, Recipient_User__c, Channel__c, Status__c
            FROM Notification_Log__c
        ];
    }

    // ── dispatch(recordId, eventType) ─────────────────────────────────

    @isTest
    static void dispatchSingle_reachesTheEngineAndWritesTheAuditLog() {
        Id acct = outlet('NDS Outlet One');

        Test.startTest();
        NotificationDispatchService.dispatch(acct, 'Approved');
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assert(!written.isEmpty(),
            'The configured rule fired through the shim — the audit row is the proof the '
            + 'forward happened, whatever the delivery outcome');
        System.assertEquals('Approved', written[0].Event_Type__c, 'For the right event');
        System.assertEquals(String.valueOf(acct), written[0].Source_Record_Id__c,
            'Against the dispatched record');
        System.assertEquals(UserInfo.getUserId(), written[0].Recipient_User__c,
            'To the rule\'s resolved recipient');
    }

    @isTest
    static void dispatchSingle_withNoMatchingRule_writesNothing() {
        Id acct = outlet('NDS Outlet One');

        Test.startTest();
        NotificationDispatchService.dispatch(acct, 'Rejected');   // no rule for Rejected
        Test.stopTest();

        System.assertEquals(0, logs().size(),
            'An event nobody configured dispatches nothing and logs nothing');
    }

    @isTest
    static void dispatchSingle_withMissingArguments_isANoOp() {
        Test.startTest();
        NotificationDispatchService.dispatch(null, 'Approved');
        NotificationDispatchService.dispatch(outlet('NDS Outlet One'), '');
        Test.stopTest();

        System.assertEquals(0, logs().size(),
            'A null record or blank event exits before the engine, throwing nothing');
    }

    // ── dispatch(Map) ─────────────────────────────────────────────────

    @isTest
    static void dispatchBulk_coversEveryRecordInTheMap() {
        Id first = outlet('NDS Outlet One');
        Id second = outlet('NDS Outlet Two');

        Test.startTest();
        NotificationDispatchService.dispatch(new Map<Id, String>{
            first => 'Approved',
            second => 'Approved'
        });
        Test.stopTest();

        Set<String> sources = new Set<String>();
        for (Notification_Log__c l : logs()) sources.add(l.Source_Record_Id__c);
        System.assert(sources.contains(String.valueOf(first)),
            'The first record was dispatched');
        System.assert(sources.contains(String.valueOf(second)),
            'And the second — the bulk overload groups by object + event but must still '
            + 'notify per record');
    }

    @isTest
    static void dispatchBulk_skipsBlankEventsAndHandlesNullMap() {
        Id acct = outlet('NDS Outlet One');

        Test.startTest();
        NotificationDispatchService.dispatch((Map<Id, String>) null);
        NotificationDispatchService.dispatch(new Map<Id, String>{ acct => '' });
        Test.stopTest();

        System.assertEquals(0, logs().size(),
            'A null map and a blank-event entry both dispatch nothing');
    }

    // ── dispatchFromFlow ──────────────────────────────────────────────

    @isTest
    static void flowEntry_forwardsUsableRequestsAndDropsBlankRows() {
        Id acct = outlet('NDS Outlet One');

        NotificationDispatchService.Request good = new NotificationDispatchService.Request();
        good.recordId = acct;
        good.eventType = 'Approved';
        NotificationDispatchService.Request noRecord = new NotificationDispatchService.Request();
        noRecord.recordId = null;
        noRecord.eventType = 'Approved';
        NotificationDispatchService.Request noEvent = new NotificationDispatchService.Request();
        noEvent.recordId = acct;
        noEvent.eventType = '  ';

        Test.startTest();
        NotificationDispatchService.dispatchFromFlow(
            new List<NotificationDispatchService.Request>{ good, noRecord, noEvent });
        NotificationDispatchService.dispatchFromFlow(null);
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assert(!written.isEmpty(),
            'The usable Flow row dispatched — a Flow loop that produced empty rows must not '
            + 'stop the good ones');
        for (Notification_Log__c l : written) {
            System.assertEquals(String.valueOf(acct), l.Source_Record_Id__c,
                'Only the usable row produced logs');
        }
    }

    // ── notify (direct send) ──────────────────────────────────────────

    @isTest
    static void notify_sendsTheDirectEmailThroughTheEngine() {
        Test.startTest();
        NotificationDispatchService.notify(
            new Set<Id>{ UserInfo.getUserId() },
            outlet('NDS Outlet One'),
            'Direct subject', 'Direct body');
        Integer emailCalls = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(1, emailCalls,
            'The shim reached notifyUsers, which sent the direct email — the platform '
            + 'invocation count is the observable proof, since test emails are not delivered');
    }

    @isTest
    static void notify_withNoRecipients_sendsNothing() {
        Test.startTest();
        NotificationDispatchService.notify(new Set<Id>(), null, 'Subject', 'Body');
        NotificationDispatchService.notify(null, null, 'Subject', 'Body');
        Integer emailCalls = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(0, emailCalls,
            'No recipients means no send attempt at all, and no exception either');
    }
}