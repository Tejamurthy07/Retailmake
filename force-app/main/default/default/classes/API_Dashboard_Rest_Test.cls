@isTest
private class API_Dashboard_Rest_Test {

    @TestSetup
    static void setup() {
        // Territory required by org rule "Active employees must be assigned
        // to a territory".
        Territory_Master__c terr = TestDataFactory.createAndInsertTerritory('West', 'WEST-001');

        // Full Employee field set proven across the suite: First/Last/Code,
        // Phone, Email, Department, Designation, Band, Date_of_Joining,
        // Channels (required), Territory (required by validation rule),
        // plus HQ_City/Region/Zone.
        Employee__c emp = new Employee__c(
            First_Name__c = 'Test',
            Last_Name__c = 'User',
            Phone__c = '9876543210',
            Email__c = 'test@example.com',
            Employee_Code__c = 'CPC0023',
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

        // Use 'Retailer' so TestDataFactory sets Outlet_Type__c='Grocery'
        // (its createAccount leaves Outlet_Type null for other types, and
        // the org's "Outlet Type required" validation fires unconditionally).
        Account acc = TestDataFactory.createAndInsertAccount('Happy Traders', 'Retailer');

        Beat__c beat = TestDataFactory.createAndInsertBeat('Beat 1', 'B001', terr.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        da.Total_Visits__c = 5;
        da.Productive_Calls__c = 3;
        da.Distance_Traveled_Km__c = 25;
        da.Total_Order_Value__c = 50000;
        da.Total_Orders__c = 4;
        insert da;

        Visit__c visit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        visit.Visit_Status__c = 'Completed';
        visit.Is_Planned__c = true;
        visit.Is_Geo_Fenced__c = true;
        visit.Duration_Minutes__c = 30;
        visit.Check_In_Latitude__c = 25.5941;
        visit.Check_In_Longitude__c = 85.1376;
        insert visit;

        // Create a target for current month
        Date today = Date.today();
        List<String> monthNames = new List<String>{
            '', 'January', 'February', 'March', 'April', 'May', 'June',
            'July', 'August', 'September', 'October', 'November', 'December'
        };
        Target__c target = new Target__c(
            Salesperson__c = UserInfo.getUserId(),
            Target_Value__c = 400000,
            Achievement_Value__c = 150000,
          
            Month__c = monthNames[today.month()],
            Year__c = String.valueOf(today.year()),
            Status__c = 'Active',
            Period_Start__c = today.toStartOfMonth(),
            Period_End__c = Date.newInstance(today.year(), today.month(), Date.daysInMonth(today.year(), today.month()))
        );
        insert target;

        // Create expense items
        Expense__c expense = new Expense__c(
            Employee__c = emp.Id,
            Month__c = monthNames[today.month()],
            Status__c = 'Draft',
            Period_Start__c = today.toStartOfMonth(),
            Period_End__c = Date.newInstance(today.year(), today.month(), Date.daysInMonth(today.year(), today.month()))
        );
        insert expense;

        // Expense_Type__c is a restricted picklist - resolve a valid active
        // value at runtime instead of hardcoding 'Daily'.
        String expType;
        try {
            Schema.DescribeFieldResult dfr =
                Expense_Item__c.SObjectType.getDescribe().fields.getMap()
                    .get('Expense_Type__c').getDescribe();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) { expType = pe.getValue(); break; }
            }
        } catch (Exception e) {}

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = expense.Id,
            Expense_Date__c = today,
            Claimed_Amount__c = 500,
            Approval_Status__c = 'Pending'
        );
        if (expType != null) item.Expense_Type__c = expType;
        insert item;
    }

    @isTest
    static void testKpiDashboard() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/mobile/dashboard/kpi';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{"userId":"' + UserInfo.getUserId() + '","summaryRange":"","expenseSummaryRange":""}');

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        API_Dashboard_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
        String body = res.responseBody.toString();
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(body);
        System.assertEquals(true, result.get('status'));

        Map<String, Object> data = (Map<String, Object>) result.get('data');
        System.assertNotEquals(null, data.get('targetSummary'));
        System.assertNotEquals(null, data.get('daySummary'));
        System.assertNotEquals(null, data.get('leaderboard'));
        System.assertNotEquals(null, data.get('productivity'));
        System.assertNotEquals(null, data.get('expenseTimeline'));
        System.assertNotEquals(null, data.get('todayVisits'));
    }

    @isTest
    static void testKpiDashboardMissingUserId() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/mobile/dashboard/kpi';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{}');

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        API_Dashboard_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, res.statusCode);
    }

    @isTest
    static void testInvalidEndpoint() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/mobile/dashboard/unknown';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{}');

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        API_Dashboard_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, res.statusCode);
    }

    @isTest
    static void testKpi_UserNotFound() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/mobile/dashboard/kpi';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(
            '{"userId":"no-such-user-' + System.currentTimeMillis() + '"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        API_Dashboard_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Unknown employee returns 400');
    }

    @isTest
    static void testKpi_NoTodayAttendance() {
        // Delete today's Day_Attendance so buildDaySummary takes the else
        // branch that zeros all summary fields.
        try { delete [SELECT Id FROM Visit__c]; } catch (Exception e) {}
        try { delete [SELECT Id FROM Day_Attendance__c]; } catch (Exception e) {}

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/mobile/dashboard/kpi';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(
            '{"userId":"' + UserInfo.getUserId() + '","expenseSummaryRange":"3M"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        API_Dashboard_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Still returns 200 with zero defaults');
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        Map<String, Object> data = (Map<String, Object>) result.get('data');
        Map<String, Object> day = (Map<String, Object>) data.get('daySummary');
        System.assertEquals(0, day.get('totalVisits'),
            'No attendance -> zeroed totalVisits');
    }

    @isTest
    static void testKpi_ExpenseRange_InvalidDuration() {
        // Force the duration parser fallback to default 6 months.
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/mobile/dashboard/kpi';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(
            '{"userId":"' + UserInfo.getUserId() + '","expenseSummaryRange":"abc"}');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        API_Dashboard_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Invalid duration falls back to 6 months and still returns 200');
    }

    @isTest
    static void testKpi_InvalidJson() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/mobile/dashboard/kpi';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf('{ broken json');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        API_Dashboard_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode,
            'Malformed JSON returns 500 via top-level catch');
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_Dashboard_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}