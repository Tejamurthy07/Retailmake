/**
 * @description Tests for NotificationDispatcher — the configuration-driven
 * notification engine. Assertions read Notification_Log__c (the audit trail)
 * and the platform email-invocation counter; the @TestVisible seams
 * (matchesCriteria / mergeTemplate) get direct unit tests for their matrices.
 *
 * The SMS/WhatsApp gateway is asserted on its SKIPPED paths, which are the
 * deterministic ones in a test org (no Integrations-window config): the engine
 * must log why nothing went out rather than dropping the send silently.
 */
@isTest
private class NotificationDispatcherTest {

    @testSetup
    static void setupTestData() {
        insert TestDataFactory.createAccount('Dispatch Outlet', 'Retailer');
    }

    private static Account theAccount() {
        return [SELECT Id, Name, OwnerId, CreatedById FROM Account
                WHERE Name = 'Dispatch Outlet' LIMIT 1];
    }

    private static Notification_Setting__c rule(String eventType, String recipientType) {
        return new Notification_Setting__c(
            Event_Object__c = 'Account',
            Event_Type__c = eventType,
            Recipient_Type__c = recipientType,
            Recipient_User__c = recipientType == 'Specific User' ? UserInfo.getUserId() : null,
            Channel_Email__c = true,
            Is_Active__c = true
        );
    }

    private static List<Notification_Log__c> logs() {
        return [SELECT Recipient_User__c, Channel__c, Status__c, Subject__c,
                       Error_Message__c, Event_Type__c
                FROM Notification_Log__c];
    }

    // ── matchesCriteria: the operator matrix, unit-tested directly ────

    @isTest
    static void criteria_textOperatorsJudgeCorrectly() {
        Account rec = new Account(Name = 'Alpha Retail Store');
        Notification_Setting__c r = new Notification_Setting__c(
            Criteria_Field__c = 'Name');

        Test.startTest();
        r.Criteria_Operator__c = 'equals'; r.Criteria_Value__c = 'Alpha Retail Store';
        System.assert(NotificationDispatcher.matchesCriteria(r, rec), 'equals hit');
        r.Criteria_Value__c = 'Other';
        System.assert(!NotificationDispatcher.matchesCriteria(r, rec), 'equals miss');
        r.Criteria_Operator__c = 'not equal to';
        System.assert(NotificationDispatcher.matchesCriteria(r, rec), 'not-equal hit');
        r.Criteria_Operator__c = 'contains'; r.Criteria_Value__c = 'Retail';
        System.assert(NotificationDispatcher.matchesCriteria(r, rec), 'contains hit');
        r.Criteria_Operator__c = 'does not contain'; r.Criteria_Value__c = 'Wholesale';
        System.assert(NotificationDispatcher.matchesCriteria(r, rec), 'not-contains hit');
        r.Criteria_Operator__c = 'starts with'; r.Criteria_Value__c = 'Alpha';
        System.assert(NotificationDispatcher.matchesCriteria(r, rec), 'starts-with hit');
        Test.stopTest();
    }

    @isTest
    static void criteria_numericAndNullOperatorsJudgeCorrectly() {
        Account rich = new Account(Name = 'Rich', Credit_Limit__c = 60000);
        Account bare = new Account(Name = 'Bare');
        Notification_Setting__c r = new Notification_Setting__c(
            Criteria_Field__c = 'Credit_Limit__c');

        Test.startTest();
        r.Criteria_Operator__c = 'greater than'; r.Criteria_Value__c = '50000';
        System.assert(NotificationDispatcher.matchesCriteria(r, rich),
            '60000 > 50000 — the "big order" rule fires only past the threshold');
        System.assert(!NotificationDispatcher.matchesCriteria(r, bare),
            'A null field can never satisfy a comparison');
        r.Criteria_Operator__c = 'less or equal'; r.Criteria_Value__c = '60000';
        System.assert(NotificationDispatcher.matchesCriteria(r, rich), '<= boundary hit');
        r.Criteria_Operator__c = 'is null';
        System.assert(NotificationDispatcher.matchesCriteria(r, bare), 'is-null hit');
        System.assert(!NotificationDispatcher.matchesCriteria(r, rich), 'is-null miss');
        r.Criteria_Operator__c = 'is not null';
        System.assert(NotificationDispatcher.matchesCriteria(r, rich), 'is-not-null hit');
        r.Criteria_Operator__c = 'no such operator';
        System.assert(!NotificationDispatcher.matchesCriteria(r, rich),
            'An unknown operator fails closed rather than firing for everyone');
        r.Criteria_Field__c = null;
        System.assert(NotificationDispatcher.matchesCriteria(r, rich),
            'No filter configured means the rule always fires');
        Test.stopTest();
    }

    // ── mergeTemplate ─────────────────────────────────────────────────

    @isTest
    static void merge_replacesTokensAndBlanksUnknowns() {
        Account rec = [SELECT Id, Name, Owner.Name FROM Account
                       WHERE Name = 'Dispatch Outlet' LIMIT 1];

        Test.startTest();
        String merged = NotificationDispatcher.mergeTemplate(
            'Order for {!Name} owned by {!Owner.Name} ({!No_Such_Field__c})', rec);
        String blank = NotificationDispatcher.mergeTemplate(null, rec);
        Test.stopTest();

        System.assert(merged.contains('Dispatch Outlet'), 'Plain field token merged');
        System.assert(merged.contains(rec.Owner.Name),
            'Relationship-path token walked through __r/standard lookups');
        System.assert(merged.contains('()'),
            'An unresolvable token renders as empty, never as the raw {!token}');
        System.assertEquals('', blank, 'A null template is an empty string');
    }

    // ── End-to-end dispatch: recipients, criteria, logs ───────────────

    @isTest
    static void dispatch_criteriaGatesWhichRecordsFire() {
        Notification_Setting__c r = rule('Approved', 'Specific User');
        r.Criteria_Field__c = 'Name';
        r.Criteria_Operator__c = 'contains';
        r.Criteria_Value__c = 'Dispatch';
        insert r;
        Account matching = theAccount();
        Account other = TestDataFactory.createAndInsertAccount('Quiet Outlet', 'Retailer');

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ matching, other });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(1, written.size(),
            'Only the record satisfying the criteria fires — one log, not two');
        System.assertEquals('Email', written[0].Channel__c, 'On the configured channel');
        System.assertEquals('Sent', written[0].Status__c, 'Recorded as sent');
        System.assertEquals(UserInfo.getUserId(), written[0].Recipient_User__c,
            'To the configured user');
    }

    @isTest
    static void dispatch_recordOwnerAndFieldOnRecord_resolveFromTheRecord() {
        Notification_Setting__c ownerRule = rule('Created', 'Record Owner');
        Notification_Setting__c fieldRule = rule('Created', 'Field on Record');
        fieldRule.Recipient_Field__c = 'OwnerId';   // a User lookup on the record
        insert new List<Notification_Setting__c>{ ownerRule, fieldRule };

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Created',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(2, written.size(), 'Both rules fired for the one record');
        for (Notification_Log__c l : written) {
            System.assertEquals(theAccount().OwnerId, l.Recipient_User__c,
                'Both resolution types land on the record\'s owner: one via OwnerId '
                + 'directly, one via the configured User-lookup field');
        }
    }

    @isTest
    static void dispatch_submitterFallsBackToCreatedBy() {
        // Account has no Submitted_By__c, so the Submitter type must fall back
        // to CreatedById rather than resolving nobody.
        insert rule('Submitted', 'Submitter');

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Submitted',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(1, written.size(), 'The submitter rule fired');
        System.assertEquals(theAccount().CreatedById, written[0].Recipient_User__c,
            'Falling back to whoever created the record');
    }

    @isTest
    static void dispatch_additionalEmailsAloneStillSend() {
        Notification_Setting__c r = rule('Approved', 'Specific User');
        r.Recipient_User__c = null;    // no user recipient at all
        r.Additional_Emails__c = 'ops@example.com, finance@example.com, not-an-email';
        r.Subject_Template__c = 'Account {!Name} approved';
        insert r;

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Integer emailCalls = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(1, emailCalls,
            'The fixed-address list alone is enough to send — one message to the '
            + 'valid addresses, the entry without an @ discarded');
        List<Notification_Log__c> written = logs();
        System.assertEquals(1, written.size(), 'Logged once for the address message');
        System.assertEquals(null, written[0].Recipient_User__c,
            'With no user attached — it went to raw addresses');
        System.assert(written[0].Subject__c.contains('Dispatch Outlet'),
            'And the log carries the MERGED subject, proving template resolution ran');
    }

    @isTest
    static void dispatch_ruleWithNoResolvableRecipient_writesNothing() {
        Notification_Setting__c r = rule('Approved', 'Specific User');
        r.Recipient_User__c = null;   // nobody configured, no extra emails
        insert r;

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        System.assertEquals(0, logs().size(),
            'No recipients resolve, nothing sends, nothing is logged as sent');
    }

    @isTest
    static void dispatch_badTemplateToken_survivesViaTheFallbackReload() {
        Notification_Setting__c r = rule('Approved', 'Specific User');
        // A token naming a field that does not exist makes the merge-field
        // reload SOQL invalid; the engine must retry with validated fields and
        // still deliver rather than losing the notification.
        r.Subject_Template__c = 'For {!Name} value {!Deleted_Field__c}';
        insert r;

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(1, written.size(),
            'A stale template field must not kill every notification on the object');
        System.assert(written[0].Subject__c.contains('Dispatch Outlet'),
            'The valid token still merged');
    }

    // ── Guard rails ───────────────────────────────────────────────────

    @isTest
    static void dispatch_blankArgsAndNoRules_areSilentNoOps() {
        Test.startTest();
        NotificationDispatcher.dispatch(null, 'Approved', new List<SObject>{ theAccount() });
        NotificationDispatcher.dispatch('Account', '', new List<SObject>{ theAccount() });
        NotificationDispatcher.dispatch('Account', 'Approved', null);
        NotificationDispatcher.dispatch('Account', 'Approved', new List<SObject>());
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });   // valid call, but no rule exists
        Test.stopTest();

        System.assertEquals(0, logs().size(), 'Nothing configured, nothing logged');
    }

    // ── SMS / WhatsApp gateway: the skip ledger ───────────────────────

    @isTest
    static void gateway_unconfiguredIntegration_logsSkippedNotSilent() {
        Notification_Setting__c r = rule('Approved', 'Specific User');
        r.Channel_Email__c = false;
        r.Channel_SMS__c = true;
        r.Channel_WhatsApp__c = true;
        insert r;

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(2, written.size(),
            'One row per gateway channel — the attempt is on the record even though '
            + 'nothing could send');
        for (Notification_Log__c l : written) {
            System.assertEquals('Skipped', l.Status__c,
                'Skipped, never faked as Sent and never silently dropped');
            System.assertNotEquals(null, l.Error_Message__c,
                'With the reason, so "why did no SMS arrive?" is answerable from the log');
        }
    }

    // ═══════════ Wave 2: gateway delivery, In-App, overloads, groups ═══════════

    /** Captures the outbound gateway request so the payload can be asserted. */
    private class GatewayMock implements HttpCalloutMock {
        Integer statusCode;
        String lastEndpoint;
        String lastBody;
        GatewayMock(Integer statusCode) { this.statusCode = statusCode; }
        public HttpResponse respond(HttpRequest req) {
            lastEndpoint = req.getEndpoint();
            lastBody = req.getBody();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setStatus(statusCode == 200 ? 'OK' : 'Server Error');
            res.setBody('{"ok":' + (statusCode == 200) + '}');
            return res;
        }
    }

    private static void enableSms(Boolean credentialSet) {
        insert new Integration_Setting__c(
            Integration_Key__c = 'sms',
            Is_Enabled__c = true,
            Credential_Set__c = credentialSet,
            Mode__c = 'Sandbox'
        );
    }

    private static void setMyMobile(String number_x) {
        User me = new User(Id = UserInfo.getUserId(), MobilePhone = number_x, Phone = number_x);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update me;
        }
    }

    private static Notification_Setting__c smsRule(String eventType) {
        Notification_Setting__c r = rule(eventType, 'Specific User');
        r.Channel_Email__c = false;
        r.Channel_SMS__c = true;
        return r;
    }

    @isTest
    static void gateway_missingCredential_skipsWithTheReason() {
        enableSms(false);   // enabled, but no stored credential
        insert smsRule('Approved');

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(1, written.size(), 'The attempt is logged');
        System.assertEquals('Skipped', written[0].Status__c, 'As skipped');
        System.assert(written[0].Error_Message__c.contains('credential'),
            'Naming the missing credential as the reason');
    }

    @isTest
    static void gateway_recipientWithoutAPhone_skipsPerUser() {
        enableSms(true);
        setMyMobile(null);   // no number anywhere on the user
        insert smsRule('Approved');

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(1, written.size(), 'The gap is on record');
        System.assertEquals('Skipped', written[0].Status__c, 'Skipped');
        System.assert(written[0].Error_Message__c.contains('No mobile number'),
            'Attributed to the user\'s missing number, not to the gateway');
    }

    @isTest
    static void gateway_configured_deliversThroughTheQueueableCallout() {
        enableSms(true);
        setMyMobile('+919876543210');
        insert smsRule('Approved');
        GatewayMock mock = new GatewayMock(200);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();   // runs the enqueued job -> real (mocked) callout

        List<Notification_Log__c> written = [
            SELECT Status__c, Channel__c FROM Notification_Log__c WHERE Channel__c = 'SMS'];
        System.assertEquals(1, written.size(), 'The async delivery wrote its own log');
        System.assertEquals('Sent', written[0].Status__c, 'Marked sent on HTTP 200');
        System.assert(mock.lastEndpoint.contains('callout:Integration_SMS'),
            'Sent through the definition\'s Named Credential');
        System.assert(mock.lastBody.contains('+919876543210'),
            'With the recipient\'s number in the payload');
    }

    @isTest
    static void gateway_httpFailure_logsFailedWithTheStatus() {
        enableSms(true);
        setMyMobile('+919876543210');
        insert smsRule('Approved');
        Test.setMock(HttpCalloutMock.class, new GatewayMock(500));

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = [
            SELECT Status__c, Error_Message__c FROM Notification_Log__c
            WHERE Channel__c = 'SMS'];
        System.assertEquals(1, written.size(), 'The failure is on record');
        System.assertEquals('Failed', written[0].Status__c,
            'A gateway 500 is a Failed delivery, never faked as Sent');
        System.assert(written[0].Error_Message__c.contains('500'),
            'With the HTTP status for diagnosis');
    }

    @isTest
    static void inApp_channelSendsAndLogs() {
        Notification_Setting__c r = rule('Approved', 'Specific User');
        r.Channel_Email__c = false;
        r.Channel_InApp__c = true;
        r.Subject_Template__c = '{!Name} approved';
        insert r;

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Approved',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        List<Notification_Log__c> written = logs();
        System.assertEquals(1, written.size(), 'One in-app notification logged');
        System.assertEquals('In-App', written[0].Channel__c, 'On the bell channel');
        System.assertEquals('Sent', written[0].Status__c, 'Delivered');
        System.assert(written[0].Subject__c.contains('Dispatch Outlet'), 'Subject merged');
    }

    @isTest
    static void overloads_byRecordIdAndByMap_routeToTheEngine() {
        insert rule('Approved', 'Specific User');
        Account acct = theAccount();

        Test.startTest();
        NotificationDispatcher.dispatch(acct.Id, 'Approved');
        NotificationDispatcher.dispatch(new Map<Id, String>{ acct.Id => 'Approved' });
        NotificationDispatcher.dispatch((Id) null, 'Approved');
        NotificationDispatcher.dispatch(acct.Id, '');
        NotificationDispatcher.dispatch((Map<Id, String>) null);
        NotificationDispatcher.dispatch(new Map<Id, String>{ acct.Id => '' });
        Test.stopTest();

        System.assertEquals(2, logs().size(),
            'The id overload and the map overload each dispatched once; every '
            + 'blank/null variant was a quiet no-op');
    }

    @isTest
    static void recipients_publicGroupAndQueue_expandToTheirMembers() {
        Group publicGroup = new Group(Name = 'NDT Group', DeveloperName = 'NDT_Group',
            Type = 'Regular');
        Group queue = new Group(Name = 'NDT Queue', DeveloperName = 'NDT_Queue',
            Type = 'Queue');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<Group>{ publicGroup, queue };
            insert new List<GroupMember>{
                new GroupMember(GroupId = publicGroup.Id, UserOrGroupId = UserInfo.getUserId()),
                new GroupMember(GroupId = queue.Id, UserOrGroupId = UserInfo.getUserId())
            };
        }
        Notification_Setting__c groupRule = rule('Escalated', 'Public Group');
        groupRule.Recipient_User__c = null;
        groupRule.Recipient_Reference__c = 'NDT_Group';
        Notification_Setting__c queueRule = rule('Overdue', 'Queue');
        queueRule.Recipient_User__c = null;
        queueRule.Recipient_Reference__c = 'NDT_Queue';
        insert new List<Notification_Setting__c>{ groupRule, queueRule };

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Escalated',
            new List<SObject>{ theAccount() });
        NotificationDispatcher.dispatch('Account', 'Overdue',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Notification_Log__c
            WHERE Event_Type__c = 'Escalated' AND Recipient_User__c = :UserInfo.getUserId()],
            'The public group expands to its user members');
        System.assertEquals(1, [SELECT COUNT() FROM Notification_Log__c
            WHERE Event_Type__c = 'Overdue' AND Recipient_User__c = :UserInfo.getUserId()],
            'And the queue does too');
    }

    @isTest
    static void recipients_profileExpandsToItsActiveUsers() {
        String myProfile = [SELECT Profile.Name FROM User
                            WHERE Id = :UserInfo.getUserId()].Profile.Name;
        Notification_Setting__c r = rule('Recalled', 'Profile');
        r.Recipient_User__c = null;
        r.Recipient_Reference__c = myProfile;
        insert r;

        Test.startTest();
        NotificationDispatcher.dispatch('Account', 'Recalled',
            new List<SObject>{ theAccount() });
        Test.stopTest();

        System.assert([SELECT COUNT() FROM Notification_Log__c
            WHERE Event_Type__c = 'Recalled' AND Recipient_User__c = :UserInfo.getUserId()] == 1,
            'A profile-typed rule reaches every active user of that profile — '
            + 'including the running user, which is the deterministic part');
    }
}