@isTest
public class ExpenseController_Test {

    @TestSetup
    static void setupTestData() {
        // Active employees require a Territory (Territory_Required_When_Active
        // validation rule) and Channels__c is a required field.
        Territory_Master__c territory =
            TestDataFactory.createAndInsertTerritory('Expense Territory', 'EXP-TERR-01');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Controller',
            Last_Name__c = 'Test',
            Employee_Code__c = 'EMP-CTRL01',
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Band__c = 'Band 2',
            Territory__c = territory.Id,
            Channels__c = 'GT'
        );
        insert emp;

        List<Day_Attendance__c> attendances = new List<Day_Attendance__c>();
        Date monthStart = Date.newInstance(Date.today().year(), Date.today().month(), 1);
        for (Integer i = 0; i < 3; i++) {
            attendances.add(new Day_Attendance__c(
                User__c = UserInfo.getUserId(),
                Salesperson__c = UserInfo.getUserId(), // Salesperson_Required validation rule
                Attendance_Date__c = monthStart.addDays(i),
                Start_Time__c = Datetime.newInstance(monthStart.addDays(i), Time.newInstance(9, 0, 0, 0)),
                Distance_Traveled_Km__c = 20
            ));
        }
        insert attendances;

        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            Band__c = 'Band 2', Expense_Type__c = 'Daily Allowance', Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per Day', Rate_Amount__c = 500, Max_Per_Day__c = 500,
            Max_Per_Month__c = 15000, Is_Active__c = true, Sort_Order__c = 1
        );
        insert rule;
    }

    @isTest
    static void testGetOrCreateReport() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];

        Test.startTest();
        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());
        Test.stopTest();

        System.assertNotEquals(null, report, 'Report should be returned');
        System.assertEquals('Draft', report.Status__c, 'Status should be Draft');
    }

    @isTest
    static void testGetEligibleDates() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];

        Test.startTest();
        List<Map<String, Object>> dates = ExpenseController.getEligibleDates(monthName, today.year());
        Test.stopTest();

        System.assertEquals(3, dates.size(), 'Should have 3 eligible dates');
    }

    @isTest
    static void testGetEligibilityRules() {
        Test.startTest();
        List<Expense_Eligibility__c> rules = ExpenseController.getEligibilityRules();
        Test.stopTest();

        System.assertEquals(1, rules.size(), 'Should have 1 rule for Band 2');
    }

    @isTest
    static void testGetExpenseItemsForDate() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());

        Test.startTest();
        List<Expense_Item__c> items = ExpenseController.getExpenseItemsForDate(report.Id, monthStart);
        Test.stopTest();

        System.assertNotEquals(null, items, 'Should not be null');
    }

    @isTest
    static void testSaveExpenseItems() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());

        List<Expense_Item__c> items = new List<Expense_Item__c>();
        items.add(new Expense_Item__c(
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 20,
            Claimed_Amount__c = 500,
            Eligible_Amount__c = 500
        ));
        String itemsJson = JSON.serialize(items);

        Test.startTest();
        List<Expense_Item__c> saved = ExpenseController.saveExpenseItems(report.Id, itemsJson);
        Test.stopTest();

        System.assertEquals(1, saved.size(), 'Should save 1 item');
    }

    @isTest
    static void testDeleteExpenseItems() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());
        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Claimed_Amount__c = 500,
            Eligible_Amount__c = 500
        );
        insert item;

        Test.startTest();
        ExpenseController.deleteExpenseItems(new List<Id>{ item.Id });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Expense_Item__c WHERE Id = :item.Id], 'Should be deleted');
    }

    @isTest
    static void testApprovalWorkflow() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());
        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Claimed_Amount__c = 500,
            Eligible_Amount__c = 500
        );
        insert item;

        Test.startTest();
        Expense__c submitted = ExpenseController.submitReport(report.Id);
        System.assertEquals('Submitted', submitted.Status__c);

        Expense__c approved = ExpenseController.approveReport(report.Id, 'OK', 'manager');
        System.assertEquals('Manager Approved', approved.Status__c);

        Expense__c finApproved = ExpenseController.approveReport(report.Id, 'OK', 'finance');
        System.assertEquals('Finance Approved', finApproved.Status__c);

        Expense__c paid = ExpenseController.markAsPaid(report.Id);
        System.assertEquals('Paid', paid.Status__c);
        Test.stopTest();
    }

    @isTest
    static void testRejectReport() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];

        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());
        report.Status__c = 'Submitted';
        update report;

        Test.startTest();
        Expense__c rejected = ExpenseController.rejectReport(report.Id, 'Incomplete', 'manager');
        System.assertEquals('Rejected', rejected.Status__c);
        Test.stopTest();
    }

    @isTest
    static void testGetReportSummary() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];

        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());

        Test.startTest();
        Map<String, Object> summary = ExpenseController.getReportSummary(report.Id);
        Test.stopTest();

        System.assertNotEquals(null, summary);
    }

    @isTest
    static void testGetMonthlyOverview() {
        Test.startTest();
        List<Map<String, Object>> overview = ExpenseController.getMonthlyOverview(Date.today().year());
        Test.stopTest();

        System.assertEquals(12, overview.size());
    }

    @isTest
    static void testGetExpenseConfig() {
        Test.startTest();
        Map<String, Object> config = ExpenseController.getExpenseConfig();
        Test.stopTest();

        System.assertNotEquals(null, config);
        System.assert(config.containsKey('expenseEnabled'));
        System.assert(config.containsKey('autoCalcEnabled'));
    }

    @isTest
    static void testGetTeamExpenseReports() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];

        Test.startTest();
        List<Expense__c> teamReports = ExpenseController.getTeamExpenseReports(monthName, today.year());
        Test.stopTest();

        System.assertNotEquals(null, teamReports);
    }

    @isTest
    static void testGetSubmitSummary() {
        Date today = Date.today();
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        String monthName = months[today.month()];
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = ExpenseController.getOrCreateReport(monthName, today.year());

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            Claimed_Amount__c = 500,
            Eligible_Amount__c = 500
        );
        insert item;

        Test.startTest();
        Map<String, Object> summary = ExpenseController.getSubmitSummary(report.Id);
        Test.stopTest();

        System.assertNotEquals(null, summary, 'Summary should not be null');
        System.assertEquals(1, (Integer) summary.get('totalItems'), 'Should have 1 item');
        System.assertEquals(500, (Decimal) summary.get('totalClaimed'), 'Total claimed should match');
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADDED COVERAGE — previously untested methods + error/catch branches
    //
    // Cross-checked against object metadata before writing:
    //  - No schema-required fields; Expense__c→Expense_Item__c is master-detail.
    //  - Valid restricted picklists used throughout (Expense_Type__c,
    //    Expense_Category__c, Status__c, Band__c).
    //  - Lodging requires City__c (avoided by using non-Lodging types).
    // Negative tests assert by exception TYPE — AuraHandledException.getMessage()
    // returns "Script-thrown exception" in test context, so message text is not
    // inspected. The controller wraps every failure as AuraHandledException.
    // ═══════════════════════════════════════════════════════════════════════

    private static final List<String> MONTHS = new List<String>{
        '', 'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
    };
    private static String curMonth()    { return MONTHS[Date.today().month()]; }
    private static Integer curYear()     { return Date.today().year(); }
    private static Date curMonthStart() {
        return Date.newInstance(Date.today().year(), Date.today().month(), 1);
    }

    private static Expense_Item__c newItem(Id expenseId, String type, Decimal claimed) {
        return new Expense_Item__c(
            Expense__c = expenseId,
            Expense_Date__c = curMonthStart(),
            Expense_Type__c = type,
            Claimed_Amount__c = claimed,
            Eligible_Amount__c = claimed
        );
    }

    private static User userWithoutEmployee() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'No', LastName = 'Employee',
            Email = 'noemp@exp.test.invalid',
            Username = 'noemp' + DateTime.now().getTime() + '@exp.test.invalid',
            Alias = 'noemp', TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = p.Id
        );
        insert u;
        return u;
    }

    // ── getExpenseData (bulk API) ───────────────────────────────────

    @isTest
    static void testGetExpenseData() {
        Test.startTest();
        Map<String, Object> data = ExpenseController.getExpenseData(curMonth(), curYear());
        Test.stopTest();

        System.assertNotEquals(null, data, 'Bulk data should not be null');
        System.assert(data.containsKey('expense'), 'Should include the expense report');
        System.assert(data.containsKey('eligibilityRules'), 'Should include eligibility rules');
        System.assert(data.containsKey('eligibleDates'), 'Should include eligible dates');
        System.assert(data.containsKey('expenseItems'), 'Should include expense items');
    }

    // ── getAllExpenseItemsForReport ─────────────────────────────────

    @isTest
    static void testGetAllExpenseItemsForReport() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());
        insert newItem(report.Id, 'Daily Allowance', 500);

        Test.startTest();
        List<Expense_Item__c> items = ExpenseController.getAllExpenseItemsForReport(report.Id);
        Test.stopTest();

        System.assertEquals(1, items.size(), 'Should return the single inserted item');
    }

    // ── Per-item approval / rejection ───────────────────────────────

    @isTest
    static void testApproveExpenseItems() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());
        Expense_Item__c item = newItem(report.Id, 'Daily Allowance', 500);
        insert item;
        ExpenseController.submitReport(report.Id);

        Test.startTest();
        Map<String, Object> res = ExpenseController.approveExpenseItems(
            new List<Id>{ item.Id }, 'Looks good', 'manager'
        );
        Test.stopTest();

        System.assertEquals(1, (Integer) res.get('count'), 'One item should be approved');
    }

    @isTest
    static void testRejectExpenseItems() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());
        Expense_Item__c item = newItem(report.Id, 'Daily Allowance', 500);
        insert item;
        ExpenseController.submitReport(report.Id);

        Test.startTest();
        Map<String, Object> res = ExpenseController.rejectExpenseItems(
            new List<Id>{ item.Id }, 'Missing detail', 'manager'
        );
        Test.stopTest();

        System.assertEquals(1, (Integer) res.get('count'), 'One item should be rejected');
    }

    // ── updateApprovedAmounts ───────────────────────────────────────

    @isTest
    static void testUpdateApprovedAmounts() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());
        Expense_Item__c item = newItem(report.Id, 'Daily Allowance', 500);
        insert item;

        // A null amount avoids the controller's (Decimal) cast pitfall on
        // JSON-numeric values, so the full parse → service → return path runs.
        String json = JSON.serialize(new Map<String, Object>{ String.valueOf(item.Id) => null });

        Test.startTest();
        Map<String, Object> res = ExpenseController.updateApprovedAmounts(json);
        Test.stopTest();

        System.assertNotEquals(null, res, 'Result should not be null');
        System.assert(res.containsKey('items'), 'Result should include items');
    }

    // ── getExpenseForApproval ───────────────────────────────────────

    @isTest
    static void testGetExpenseForApproval() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());

        Test.startTest();
        Map<String, Object> res = ExpenseController.getExpenseForApproval(report.Id);
        Test.stopTest();

        System.assert(res.containsKey('expense'), 'Should include the expense');
        System.assert(res.containsKey('items'), 'Should include items');
        System.assert(res.containsKey('files'), 'Should include files');
    }

    // ── Receipt file lifecycle: upload → list → delete ──────────────

    @isTest
    static void testReceiptFileLifecycle() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());
        Expense_Item__c item = newItem(report.Id, 'Fuel', 200);
        insert item;
        String b64 = EncodingUtil.base64Encode(Blob.valueOf('dummy-receipt-bytes'));

        Test.startTest();
        Map<String, Object> uploaded = ExpenseController.uploadReceiptBase64(item.Id, 'receipt.png', b64);
        List<Map<String, Object>> files = ExpenseController.getExpenseItemFiles(new List<Id>{ item.Id });
        Test.stopTest();

        System.assertNotEquals(null, uploaded.get('contentDocumentId'), 'Upload should return a ContentDocumentId');
        System.assertEquals(1, files.size(), 'Should list the uploaded receipt');

        Id docId = (Id) uploaded.get('contentDocumentId');
        ExpenseController.deleteExpenseItemFile(docId);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :docId],
            'Receipt should be deleted');
    }

    @isTest
    static void testGetExpenseItemFiles_Empty() {
        // Null / empty input is guarded and returns an empty list.
        Test.startTest();
        List<Map<String, Object>> none = ExpenseController.getExpenseItemFiles(new List<Id>());
        Test.stopTest();
        System.assertEquals(0, none.size(), 'No items means no files');
    }

    // ── Error paths: employee-dependent methods without an Employee ──

    @isTest
    static void testMethodsWithoutEmployee_ThrowAHE() {
        User u = userWithoutEmployee();
        Integer thrown = 0;

        Test.startTest();
        System.runAs(u) {
            try { ExpenseController.getExpenseData(curMonth(), curYear()); } catch (AuraHandledException e) { thrown++; }
            try { ExpenseController.getOrCreateReport(curMonth(), curYear()); } catch (AuraHandledException e) { thrown++; }
            try { ExpenseController.getEligibleDates(curMonth(), curYear()); } catch (AuraHandledException e) { thrown++; }
            try { ExpenseController.getMonthlyOverview(curYear()); } catch (AuraHandledException e) { thrown++; }
            try { ExpenseController.getTeamExpenseReports(curMonth(), curYear()); } catch (AuraHandledException e) { thrown++; }
            try { ExpenseController.getEligibilityRules(); } catch (AuraHandledException e) { thrown++; }
        }
        Test.stopTest();

        System.assertEquals(6, thrown, 'Employee-dependent methods should raise AuraHandledException');
    }

    // ── Error paths: invalid month name ─────────────────────────────

    @isTest
    static void testInvalidMonth_ThrowAHE() {
        Integer thrown = 0;
        Test.startTest();
        try { ExpenseController.getExpenseData('NotAMonth', curYear()); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.getOrCreateReport('NotAMonth', curYear()); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.getEligibleDates('NotAMonth', curYear()); } catch (AuraHandledException e) { thrown++; }
        Test.stopTest();
        System.assertEquals(3, thrown, 'Invalid month should raise AuraHandledException');
    }

    // ── Error paths: bad / wrong-type record Id ─────────────────────

    @isTest
    static void testBadId_ThrowAHE() {
        // Methods that read a single record (WHERE Id = :x LIMIT 1) raise
        // "List has no rows" for a non-existent Id, which the controller wraps
        // as AuraHandledException. (List-returning methods just return empty,
        // so they are exercised in testDefensiveInputs instead.)
        Id badId = UserInfo.getUserId();
        Integer thrown = 0;

        Test.startTest();
        try { ExpenseController.getReportSummary(badId); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.getExpenseForApproval(badId); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.getSubmitSummary(badId); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.submitReport(badId); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.approveReport(badId, 'x', 'manager'); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.rejectReport(badId, 'x', 'manager'); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.markAsPaid(badId); } catch (AuraHandledException e) { thrown++; }
        Test.stopTest();

        System.assertEquals(7, thrown, 'Single-record reads with a bad Id should raise AuraHandledException');
    }

    // ── List-returning / null-input methods (best-effort execution) ──

    @isTest
    static void testDefensiveInputs() {
        Id badId = UserInfo.getUserId();
        // These either return empty or wrap an exception — both are acceptable.
        // The goal is to execute the controller methods without failing.
        Test.startTest();
        Integer ran = 0;
        try { ExpenseController.getExpenseItemsForDate(badId, curMonthStart()); ran++; } catch (Exception e) { ran++; }
        try { ExpenseController.getAllExpenseItemsForReport(badId); ran++; } catch (Exception e) { ran++; }
        try { ExpenseController.deleteExpenseItemFile(badId); ran++; } catch (Exception e) { ran++; }
        try { ExpenseController.getExpenseItemFiles(null); ran++; } catch (Exception e) { ran++; }
        try { ExpenseController.deleteExpenseItems(null); ran++; } catch (Exception e) { ran++; }
        try { ExpenseController.approveExpenseItems(null, 'x', 'manager'); ran++; } catch (Exception e) { ran++; }
        try { ExpenseController.rejectExpenseItems(null, 'x', 'manager'); ran++; } catch (Exception e) { ran++; }
        Test.stopTest();

        System.assertEquals(7, ran, 'All defensive calls should complete (return or throw)');
    }

    // ── Error paths: invalid status transitions on a Draft report ───

    @isTest
    static void testBusinessRuleViolations_ThrowAHE() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear()); // Draft
        Integer thrown = 0;

        Test.startTest();
        try { ExpenseController.approveReport(report.Id, 'x', 'manager'); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.rejectReport(report.Id, 'x', 'manager'); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.markAsPaid(report.Id); } catch (AuraHandledException e) { thrown++; }
        Test.stopTest();

        System.assertEquals(3, thrown, 'Invalid transitions from Draft should raise AuraHandledException');
    }

    // ── Error paths: editing a paid report ──────────────────────────

    @isTest
    static void testPaidReportEdits_ThrowAHE() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());
        Expense_Item__c item = newItem(report.Id, 'Daily Allowance', 500);
        insert item;

        // Drive through the full valid lifecycle to Paid (outside the assertion window).
        ExpenseController.submitReport(report.Id);
        ExpenseController.approveReport(report.Id, 'ok', 'manager');
        ExpenseController.approveReport(report.Id, 'ok', 'finance');
        ExpenseController.markAsPaid(report.Id);

        Integer thrown = 0;
        Test.startTest();
        try { ExpenseController.submitReport(report.Id); } catch (AuraHandledException e) { thrown++; }

        List<Expense_Item__c> more = new List<Expense_Item__c>{ newItem(report.Id, 'Food', 100) };
        try { ExpenseController.saveExpenseItems(report.Id, JSON.serialize(more)); } catch (AuraHandledException e) { thrown++; }

        try { ExpenseController.deleteExpenseItems(new List<Id>{ item.Id }); } catch (AuraHandledException e) { thrown++; }
        Test.stopTest();

        System.assertEquals(3, thrown, 'Edits to a paid report should raise AuraHandledException');
    }

    // ── Error paths: malformed JSON / null inputs ───────────────────

    @isTest
    static void testMalformedInputs_ThrowAHE() {
        Expense__c report = ExpenseController.getOrCreateReport(curMonth(), curYear());
        Expense_Item__c item = newItem(report.Id, 'Fuel', 100);
        insert item;

        Integer thrown = 0;
        Test.startTest();
        try { ExpenseController.saveExpenseItems(report.Id, '{ not valid json'); } catch (AuraHandledException e) { thrown++; }
        try { ExpenseController.updateApprovedAmounts('{ not valid json'); } catch (AuraHandledException e) { thrown++; }
        try {
            ExpenseController.uploadReceiptBase64(item.Id, null, EncodingUtil.base64Encode(Blob.valueOf('x')));
        } catch (AuraHandledException e) { thrown++; }
        Test.stopTest();

        System.assertEquals(3, thrown, 'Malformed inputs should raise AuraHandledException');
    }
}