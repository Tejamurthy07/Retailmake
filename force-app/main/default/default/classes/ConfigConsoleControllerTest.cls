/**
 * @description Tests for ConfigConsoleController — the read + delete layer
 * behind the Configuration Console LWC.
 *
 * The controller is deliberately narrow (create/edit happens client-side in
 * lightning-record-edit-form), so the contract worth pinning down is:
 *   - each getter returns the fields the console table binds to, including the
 *     resolved lookup names it renders instead of raw ids;
 *   - each getter returns them in the order the table relies on;
 *   - deleteRecord works for any object without being told which one, and
 *     surfaces failures as AuraHandledException rather than a raw DmlException.
 *
 * No test users are created anywhere here — the running user is used for every
 * lookup, which keeps the whole class free of setup-object DML and therefore
 * of MIXED_DML_OPERATION.
 */
@isTest
private class ConfigConsoleControllerTest {

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Notification_Setting__c setting(String obj, String eventType) {
        return new Notification_Setting__c(
            Event_Object__c = obj,
            Event_Type__c = eventType,
            Recipient_Type__c = 'Specific User',
            Recipient_User__c = UserInfo.getUserId(),
            Channel_InApp__c = true,
            Channel_Email__c = false,
            Channel_SMS__c = false,
            Channel_WhatsApp__c = false,
            Is_Active__c = true
        );
    }

    private static Approval_Rule__c rule(String obj, Decimal level) {
        return new Approval_Rule__c(
            Object_Process__c = obj,
            Approval_Level__c = level,
            Approver_Type__c = 'User',
            User__c = UserInfo.getUserId(),
            Auto_Approve__c = false,
            Is_Active__c = true
        );
    }

    private static Approval_Request__c request(String recordName, Datetime submitted) {
        return new Approval_Request__c(
            Object_Type__c = 'Lead',
            Record_Id__c = '00Q000000000000',
            Record_Name__c = recordName,
            Status__c = 'Pending',
            Current_Level__c = 1,
            Total_Levels__c = 2,
            Current_Approver__c = UserInfo.getUserId(),
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_Date__c = submitted
        );
    }

    // ── getNotificationSettings ───────────────────────────────────────

    @isTest
    static void notificationSettings_emptyOrg_returnsEmptyList() {
        Test.startTest();
        List<Notification_Setting__c> rows = ConfigConsoleController.getNotificationSettings();
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'An unconfigured console renders an empty table');
    }

    @isTest
    static void notificationSettings_returnsRowsOrderedByObjectThenEventType() {
        insert new List<Notification_Setting__c>{
            setting('Sales_Order__c', 'Rejected'),
            setting('Approval_Request__c', 'Approved'),
            setting('Sales_Order__c', 'Approved')
        };

        Test.startTest();
        List<Notification_Setting__c> rows = ConfigConsoleController.getNotificationSettings();
        Test.stopTest();

        System.assertEquals(3, rows.size(), 'Every setting is listed — the console has no filter');
        System.assertEquals('Approval_Request__c', rows[0].Event_Object__c, 'Ordered by object first');
        System.assertEquals('Sales_Order__c', rows[1].Event_Object__c, 'Then the Sales Order rows');
        System.assertEquals('Approved', rows[1].Event_Type__c, 'Event type breaks the tie');
        System.assertEquals('Rejected', rows[2].Event_Type__c, 'Rejected sorts after Approved');
    }

    @isTest
    static void notificationSettings_carryChannelFlagsAndRecipientName() {
        Notification_Setting__c s = setting('Claim__c', 'Submitted');
        s.Channel_Email__c = true;
        s.Channel_WhatsApp__c = true;
        s.Recipient_Reference__c = 'Sales_Manager';
        s.Is_Active__c = false;
        insert s;

        Test.startTest();
        List<Notification_Setting__c> rows = ConfigConsoleController.getNotificationSettings();
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'One setting configured');
        Notification_Setting__c row = rows[0];
        System.assertEquals(UserInfo.getName(), row.Recipient_User__r.Name,
            'The table shows a person, not a raw user id');
        System.assertEquals('Sales_Manager', row.Recipient_Reference__c, 'Reference surfaced');
        System.assertEquals(true, row.Channel_InApp__c, 'In-app channel flag surfaced');
        System.assertEquals(true, row.Channel_Email__c, 'Email channel flag surfaced');
        System.assertEquals(true, row.Channel_WhatsApp__c, 'WhatsApp channel flag surfaced');
        System.assertEquals(false, row.Channel_SMS__c, 'SMS stays off');
        System.assertEquals(false, row.Is_Active__c,
            'Inactive settings still list, so an admin can find and re-enable them');
    }

    @isTest
    static void notificationSettings_withNoRecipientUser_returnsNullRelationship() {
        Notification_Setting__c s = setting('Leave_Request__c', 'Created');
        s.Recipient_Type__c = 'Record Owner';
        s.Recipient_User__c = null;
        insert s;

        Test.startTest();
        List<Notification_Setting__c> rows = ConfigConsoleController.getNotificationSettings();
        Test.stopTest();

        System.assertEquals(null, rows[0].Recipient_User__r,
            'A recipient type that needs no user leaves the lookup empty rather than failing');
        System.assertEquals('Record Owner', rows[0].Recipient_Type__c, 'The type still renders');
    }

    // ── getApprovalRules ──────────────────────────────────────────────

    @isTest
    static void approvalRules_emptyOrg_returnsEmptyList() {
        Test.startTest();
        List<Approval_Rule__c> rows = ConfigConsoleController.getApprovalRules();
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'No rules configured yet');
    }

    @isTest
    static void approvalRules_returnsRowsOrderedByObjectThenLevel() {
        insert new List<Approval_Rule__c>{
            rule('Sales_Order__c', 2),
            rule('Claim__c', 1),
            rule('Sales_Order__c', 1)
        };

        Test.startTest();
        List<Approval_Rule__c> rows = ConfigConsoleController.getApprovalRules();
        Test.stopTest();

        System.assertEquals(3, rows.size(), 'Every rule is listed');
        System.assertEquals('Claim__c', rows[0].Object_Process__c, 'Ordered by object first');
        System.assertEquals(1, rows[1].Approval_Level__c, 'Level 1 before level 2 within an object');
        System.assertEquals(2, rows[2].Approval_Level__c, 'Level 2 last');
    }

    @isTest
    static void approvalRules_carryApproverNameAndValueBand() {
        Approval_Rule__c r = rule('Return_Order__c', 1);
        r.Condition_Field__c = 'Total_Amount__c';
        r.Min_Value__c = 1000;
        r.Max_Value__c = 50000;
        r.Auto_Approve__c = true;
        r.Approver_Role_Queue__c = 'Finance_Queue';
        insert r;

        Test.startTest();
        List<Approval_Rule__c> rows = ConfigConsoleController.getApprovalRules();
        Test.stopTest();

        Approval_Rule__c row = rows[0];
        System.assertEquals(UserInfo.getName(), row.User__r.Name,
            'The approver renders as a name in the console table');
        System.assertEquals('Total_Amount__c', row.Condition_Field__c, 'Condition field surfaced');
        System.assertEquals(1000, row.Min_Value__c, 'Band floor surfaced');
        System.assertEquals(50000, row.Max_Value__c, 'Band ceiling surfaced');
        System.assertEquals(true, row.Auto_Approve__c, 'Auto-approve flag surfaced');
        System.assertEquals('Finance_Queue', row.Approver_Role_Queue__c, 'Role/queue surfaced');
    }

    // ── getApprovalRequests ───────────────────────────────────────────

    @isTest
    static void approvalRequests_emptyOrg_returnsEmptyList() {
        Test.startTest();
        List<Approval_Request__c> rows = ConfigConsoleController.getApprovalRequests();
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'Nothing has been submitted yet');
    }

    @isTest
    static void approvalRequests_returnsNewestFirstWithUnsubmittedLast() {
        insert new List<Approval_Request__c>{
            request('Older', Datetime.now().addDays(-5)),
            request('Newest', Datetime.now()),
            request('Never submitted', null)
        };

        Test.startTest();
        List<Approval_Request__c> rows = ConfigConsoleController.getApprovalRequests();
        Test.stopTest();

        System.assertEquals(3, rows.size(), 'All three are listed');
        System.assertEquals('Newest', rows[0].Record_Name__c, 'The monitoring tab leads with the newest');
        System.assertEquals('Older', rows[1].Record_Name__c, 'Then the older one');
        System.assertEquals('Never submitted', rows[2].Record_Name__c,
            'NULLS LAST keeps requests with no submitted date at the bottom');
    }

    @isTest
    static void approvalRequests_carryProgressAndResolvedNames() {
        Approval_Request__c req = request('Order 4471', Datetime.now());
        req.Completed_Date__c = Datetime.now().addHours(2);
        req.Status__c = 'Approved';
        insert req;

        Test.startTest();
        List<Approval_Request__c> rows = ConfigConsoleController.getApprovalRequests();
        Test.stopTest();

        Approval_Request__c row = rows[0];
        System.assertEquals('Order 4471', row.Record_Name__c, 'Source record name surfaced');
        System.assertEquals('Lead', row.Object_Type__c, 'Object type surfaced');
        System.assertEquals('Approved', row.Status__c, 'Status surfaced');
        System.assertEquals(1, row.Current_Level__c, 'Progress numerator');
        System.assertEquals(2, row.Total_Levels__c, 'Progress denominator');
        System.assertEquals(UserInfo.getName(), row.Current_Approver__r.Name,
            'Approver renders as a name');
        System.assertEquals(UserInfo.getName(), row.Submitted_By__r.Name,
            'Submitter renders as a name');
        System.assertNotEquals(null, row.Completed_Date__c, 'Completion time surfaced');
    }

    // ── deleteRecord ──────────────────────────────────────────────────

    @isTest
    static void deleteRecord_removesANotificationSetting() {
        Notification_Setting__c s = setting('Scheme__c', 'Approved');
        insert s;

        Test.startTest();
        ConfigConsoleController.deleteRecord(s.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Notification_Setting__c],
            'The setting is gone without the controller being told its object type');
    }

    @isTest
    static void deleteRecord_removesAnApprovalRuleAndItsConditions() {
        Approval_Rule__c r = rule('Sales_Order__c', 1);
        insert r;
        insert new Approval_Rule_Condition__c(
            Approval_Rule__c = r.Id,
            Field_API_Name__c = 'Status__c',
            Operator__c = 'equals',
            Value__c = 'Draft',
            Sequence__c = 0
        );

        Test.startTest();
        ConfigConsoleController.deleteRecord(r.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Approval_Rule__c],
            'The same method deletes a second object type just as happily');
        System.assertEquals(0, [SELECT COUNT() FROM Approval_Rule_Condition__c],
            'Master-detail children go with the parent');
    }

    @isTest
    static void deleteRecord_leavesOtherRecordsAlone() {
        List<Notification_Setting__c> settings = new List<Notification_Setting__c>{
            setting('Claim__c', 'Approved'),
            setting('Claim__c', 'Rejected')
        };
        insert settings;

        Test.startTest();
        ConfigConsoleController.deleteRecord(settings[0].Id);
        Test.stopTest();

        List<Notification_Setting__c> left = [SELECT Id FROM Notification_Setting__c];
        System.assertEquals(1, left.size(), 'Only the targeted row is deleted');
        System.assertEquals(settings[1].Id, left[0].Id, 'And it is the right one that survives');
    }

    @isTest
    static void deleteRecord_nullId_throwsHandledException() {
        Test.startTest();
        Boolean threw = false;
        try {
            ConfigConsoleController.deleteRecord(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'A missing id must reach the LWC as an AuraHandledException, not a raw NPE');
    }

    @isTest
    static void deleteRecord_recordThatNoLongerExists_throwsHandledException() {
        Approval_Rule__c r = rule('Claim__c', 1);
        insert r;
        Id goneId = r.Id;
        delete r;

        Test.startTest();
        Boolean threw = false;
        try {
            // Two admins on the console at once: the row was deleted in the
            // other tab before this click landed.
            ConfigConsoleController.deleteRecord(goneId);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A stale row id surfaces as a handled error, not an unhandled DML failure');
    }
}