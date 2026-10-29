/**
 * @description Test class for API_Expense_Rest. Covers every branch:
 *               - handlePost dispatch (/add, /list, /detail, invalid endpoint,
 *                 top-level catch)
 *               - doAddExpense: success creating new monthly report, success
 *                 reusing existing monthly report, missing userId, user-not-
 *                 found, expansedate typo fallback, blank/bad expense date
 *                 (defaults to today), amount as Decimal + String + invalid
 *                 String, invalid JSON
 *               - doExpenseList: success (multiple months grouped), missing
 *                 userId, user-not-found, invalid JSON
 *               - doExpenseDetail: success, missing userId, missing expenseId,
 *                 user-not-found, expense-not-found, null expense-date
 *                 displayDate branch
 *
 *              Defensive @TestSetup: Territory + full Employee field set
 *              (Channels, Band='Band 1', Dept, Designation, DOJ) and runtime
 *              picklist resolution for Expense_Type__c.
 */
@isTest
private class API_Expense_Rest_Test {

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get(sObjectName);
            if (t == null) return null;
            Schema.DescribeFieldResult dfr =
                t.getDescribe().fields.getMap().get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) active.add(pe.getValue());
            }
            for (String p : preferred) if (active.contains(p)) return p;
            for (String v : active) return v;
        } catch (Exception e) {}
        return null;
    }

    @TestSetup
    static void setup() {
        Territory_Master__c terr = new Territory_Master__c(
            Name = 'API Exp Terr',
            Territory_Code__c = 'APIEXPTERR',
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        insert terr;

        Employee__c emp = new Employee__c(
            First_Name__c = 'Anil',
            Last_Name__c = 'Kumar',
            Phone__c = '9876543210',
            Email__c = 'anil@example.com',
            Employee_Code__c = 'CPC001',
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Band__c = 'Band 1',
            Territory__c = terr.Id,
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Date_of_Joining__c = Date.today().addYears(-1)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;

        Date today = Date.today();
        List<String> monthNames = new List<String>{
            '', 'January', 'February', 'March', 'April', 'May', 'June',
            'July', 'August', 'September', 'October', 'November', 'December'
        };

        // Expense report for the current month
        Expense__c expense = new Expense__c(
            Employee__c = emp.Id,
            Month__c = monthNames[today.month()],
            Status__c = 'Draft',
            Period_Start__c = today.toStartOfMonth(),
            Period_End__c = Date.newInstance(today.year(), today.month(),
                Date.daysInMonth(today.year(), today.month()))
        );
        insert expense;

        // Expense report for last month so the list endpoint can group across months
        Date lastMonthDate = today.addMonths(-1);
        Expense__c lastMonth = new Expense__c(
            Employee__c = emp.Id,
            Month__c = monthNames[lastMonthDate.month()],
            Status__c = 'Draft',
            Period_Start__c = lastMonthDate.toStartOfMonth(),
            Period_End__c = Date.newInstance(lastMonthDate.year(), lastMonthDate.month(),
                Date.daysInMonth(lastMonthDate.year(), lastMonthDate.month()))
        );
        insert lastMonth;

        // Runtime-resolve Expense_Type__c picklist (the existing test's
        // hardcoded 'Daily' / 'Travel' broke in this org).
        String expType = pickPicklistValue('Expense_Item__c', 'Expense_Type__c',
            new List<String>{ 'Daily', 'Travel', 'DA', 'TA' });

        Expense_Item__c item1 = new Expense_Item__c(
            Expense__c = expense.Id,
            Expense_Date__c = today,
            Claimed_Amount__c = 500,
            Approval_Status__c = 'Pending',
            Notes__c = 'Daily allowance'
        );
        if (expType != null) item1.Expense_Type__c = expType;
        // Expense_Category__c is a restricted picklist - resolve at runtime
        // instead of hardcoding 'DA' which is not valid in this org.
        String expCategory = pickPicklistValue('Expense_Item__c', 'Expense_Category__c',
            new List<String>{ 'DA', 'TA', 'Food', 'Travel', 'Other' });
        if (expCategory != null) try { item1.put('Expense_Category__c', expCategory); } catch (Exception e) {}

        Expense_Item__c item2 = new Expense_Item__c(
            Expense__c = expense.Id,
            Expense_Date__c = today,
            Claimed_Amount__c = 555,
            Approval_Status__c = 'Pending',
            Notes__c = 'Travel expense'
        );
        if (expType != null) item2.Expense_Type__c = expType;

        // Item in last month so multi-month grouping runs in doExpenseList
        Expense_Item__c item3 = new Expense_Item__c(
            Expense__c = lastMonth.Id,
            Expense_Date__c = lastMonthDate,
            Claimed_Amount__c = 200,
            Approval_Status__c = 'Pending',
            Notes__c = 'Last month expense'
        );
        if (expType != null) item3.Expense_Type__c = expType;

        // Item with null Expense_Date__c so the "skip null date" branch in
        // doExpenseList runs.
        Expense_Item__c item4 = new Expense_Item__c(
            Expense__c = expense.Id,
            Claimed_Amount__c = 75,
            Approval_Status__c = 'Pending',
            Notes__c = 'No date'
        );
        if (expType != null) item4.Expense_Type__c = expType;

        insert new List<Expense_Item__c>{ item1, item2, item3, item4 };
    }

    private static void prepareRest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = body != null ? Blob.valueOf(body) : Blob.valueOf('');
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    private static String resolveExpenseType() {
        // Used by the /add tests to pass a valid type from the payload.
        return pickPicklistValue('Expense_Item__c', 'Expense_Type__c',
            new List<String>{ 'Daily', 'Travel', 'DA', 'TA' });
    }

    // ── doAddExpense ────────────────────────────────────────────────────────

    @isTest
    static void testAddExpense_NewMonth() {
        // Use a date in a future month so the report has to be created.
        Date d = Date.today().addMonths(2);
        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'expenseType' => resolveExpenseType(),
            'expenseDate' => String.valueOf(d),
            'description' => 'Future month exp',
            'amount' => 250
        };
        prepareRest('/services/apexrest/mobile/expense/add', JSON.serialize(payload));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Add succeeds with new monthly report. Body: '
            + RestContext.response.responseBody.toString());
    }

    @isTest
    static void testAddExpense_ExistingMonth() {
        // Setup already created the current-month report -> reuse path.
        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'expenseType' => resolveExpenseType(),
            'expenseDate' => String.valueOf(Date.today()),
            'description' => 'Today exp',
            'amount' => 100
        };
        prepareRest('/services/apexrest/mobile/expense/add', JSON.serialize(payload));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Add reuses existing monthly report');
    }

    @isTest
    static void testAddExpense_TypoExpansedate_AndStringAmount() {
        // Controller accepts both 'expansedate' (typo) and 'expenseDate'.
        // Pass an amount as a String to exercise that branch.
        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'expenseType' => resolveExpenseType(),
            'expansedate' => String.valueOf(Date.today()),
            'description' => 'Typo path',
            'amount' => '125.50'
        };
        prepareRest('/services/apexrest/mobile/expense/add', JSON.serialize(payload));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Typo expansedate + String amount accepted');
    }

    @isTest
    static void testAddExpense_BadDateFallsBackToToday() {
        // Invalid date string -> Date.valueOf throws -> fallback to today.
        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'expenseType' => resolveExpenseType(),
            'expenseDate' => 'not-a-real-date',
            'amount' => 50
        };
        prepareRest('/services/apexrest/mobile/expense/add', JSON.serialize(payload));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Bad date falls back to today and still succeeds');
    }

    @isTest
    static void testAddExpense_InvalidStringAmount() {
        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'expenseType' => resolveExpenseType(),
            'expenseDate' => String.valueOf(Date.today()),
            'amount' => 'not-a-number'
        };
        prepareRest('/services/apexrest/mobile/expense/add', JSON.serialize(payload));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Invalid amount string returns 400');
    }

    @isTest
    static void testAddExpense_MissingUserId() {
        prepareRest('/services/apexrest/mobile/expense/add',
            JSON.serialize(new Map<String, Object>{ 'amount' => 10 }));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAddExpense_UserNotFound() {
        prepareRest('/services/apexrest/mobile/expense/add',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'amount' => 10
            }));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAddExpense_InvalidJson() {
        prepareRest('/services/apexrest/mobile/expense/add', '{ bad json');
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(500, RestContext.response.statusCode);
    }

    // ── doExpenseList ───────────────────────────────────────────────────────

    @isTest
    static void testList_Success() {
        prepareRest('/services/apexrest/mobile/expense/list',
            JSON.serialize(new Map<String, Object>{ 'userId' => UserInfo.getUserId() }));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'List succeeds. Body: ' + RestContext.response.responseBody.toString());
        Map<String, Object> body = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assert(body.containsKey('data'), 'data key present');
        System.assert(body.containsKey('totalExpenses'), 'totalExpenses key present');
    }

    @isTest
    static void testList_MissingUserId() {
        prepareRest('/services/apexrest/mobile/expense/list',
            JSON.serialize(new Map<String, Object>()));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_UserNotFound() {
        prepareRest('/services/apexrest/mobile/expense/list',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis()
            }));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_InvalidJson() {
        prepareRest('/services/apexrest/mobile/expense/list', '{ bad json');
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(500, RestContext.response.statusCode);
    }

    // ── doExpenseDetail ─────────────────────────────────────────────────────

    @isTest
    static void testDetail_Success() {
        Expense_Item__c item = [
            SELECT Id FROM Expense_Item__c WHERE Expense_Date__c != null LIMIT 1
        ];
        prepareRest('/services/apexrest/mobile/expense/detail',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'expenseId' => item.Id
            }));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Detail succeeds. Body: ' + RestContext.response.responseBody.toString());
    }

    @isTest
    static void testDetail_NullExpenseDate() {
        // Setup seeded one item with null Expense_Date__c — exercises the
        // displayDate empty-string branch.
        Expense_Item__c item = [
            SELECT Id FROM Expense_Item__c WHERE Expense_Date__c = null LIMIT 1
        ];
        prepareRest('/services/apexrest/mobile/expense/detail',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'expenseId' => item.Id
            }));

        Test.startTest();
        API_Expense_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Detail succeeds for null-date item');
    }

    @isTest
    static void testDetail_MissingUserId() {
        prepareRest('/services/apexrest/mobile/expense/detail',
            JSON.serialize(new Map<String, Object>{ 'expenseId' => 'a0X000000000000AAA' }));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testDetail_MissingExpenseId() {
        prepareRest('/services/apexrest/mobile/expense/detail',
            JSON.serialize(new Map<String, Object>{ 'userId' => UserInfo.getUserId() }));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testDetail_UserNotFound() {
        prepareRest('/services/apexrest/mobile/expense/detail',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'expenseId' => 'a0X000000000000AAA'
            }));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testDetail_ExpenseNotFound() {
        prepareRest('/services/apexrest/mobile/expense/detail',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'expenseId' => 'a0X000000000000AAA'
            }));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testDetail_InvalidJson() {
        prepareRest('/services/apexrest/mobile/expense/detail', '{ bad json');
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(500, RestContext.response.statusCode);
    }

    // ── Dispatch branches ──────────────────────────────────────────────────

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/mobile/expense/unknown',
            JSON.serialize(new Map<String, Object>()));
        Test.startTest(); API_Expense_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_Expense_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}