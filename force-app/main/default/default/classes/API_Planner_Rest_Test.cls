@isTest
private class API_Planner_Rest_Test {

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            Schema.DescribeFieldResult dfr = Schema.getGlobalDescribe()
                .get(sObjectName).getDescribe().fields.getMap()
                .get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) { active.add(pe.getValue()); }
            }
            for (String p : preferred) {
                if (active.contains(p)) { return p; }
            }
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) { return pe.getValue(); }
            }
        } catch (Exception e) {}
        return null;
    }

    @TestSetup
    static void setup() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('West', 'WEST-001');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Test',
            Last_Name__c = 'User',
            Phone__c = '9876543210',
            Email__c = 'test@example.com',
            Employee_Code__c = 'CPC0024',
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Band__c = 'Band 1',
            Territory__c = territory.Id,
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Date_of_Joining__c = Date.today().addYears(-1)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;

        Account acc1 = TestDataFactory.createAndInsertAccount('Happy Traders', 'Retailer');
        try { acc1.put('BillingStreet', '12 Main St'); } catch (Exception e) {}
        try { acc1.put('BillingCity', 'Mumbai'); } catch (Exception e) {}
        update acc1;

        // Second account without billing address fields - exercises buildAddress empty branch.
        Account acc2 = TestDataFactory.createAndInsertAccount('ABC Distributors', 'Retailer');

        Beat__c beat = TestDataFactory.createAndInsertBeat('Beat 1', 'B001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        String visitStatus = pickPicklistValue('Visit__c', 'Visit_Status__c',
            new List<String>{ 'Pending', 'Planned', 'Scheduled' });

        // Three visits across three dates so group-by-date returns multiple entries.
        Visit__c v1 = TestDataFactory.createVisit(acc1.Id, UserInfo.getUserId(), da.Id, beat.Id);
        v1.Visit_Date__c = Date.today();
        v1.Is_Planned__c = true;
        if (visitStatus != null) v1.Visit_Status__c = visitStatus;
        v1.Check_In_Time__c = DateTime.now();
        insert v1;

        Visit__c v2 = new Visit__c(
            Account__c = acc2.Id,
            Salesperson__c = UserInfo.getUserId(),
            Beat__c = beat.Id,
            Visit_Date__c = Date.today().addDays(1),
            Is_Planned__c = true
        );
        if (visitStatus != null) v2.Visit_Status__c = visitStatus;
        insert v2;

        Visit__c v3 = new Visit__c(
            Account__c = acc1.Id,
            Salesperson__c = UserInfo.getUserId(),
            Beat__c = beat.Id,
            Visit_Date__c = Date.today().addDays(2),
            Is_Planned__c = true
        );
        if (visitStatus != null) v3.Visit_Status__c = visitStatus;
        insert v3;
    }

    private static void prepareRest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    @isTest
    static void testPlannerList() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'fromDate' => String.valueOf(Date.today()),
            'toDate' => String.valueOf(Date.today().addDays(7)),
            'pageSize' => 0,
            'search' => ''
        };
        prepareRest('/services/apexrest/mobile/planner/list', JSON.serialize(body));

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
        List<Object> data = (List<Object>) result.get('data');
        System.assert(data.size() > 0, 'Should have at least one day entry');
    }

    @isTest
    static void testPlannerListWithSearch() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'fromDate' => String.valueOf(Date.today()),
            'toDate' => String.valueOf(Date.today().addDays(7)),
            'pageSize' => 50,
            'search' => 'Happy'
        };
        prepareRest('/services/apexrest/mobile/planner/list', JSON.serialize(body));

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testPlannerListExplicitPageSize() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'fromDate' => String.valueOf(Date.today()),
            'toDate' => String.valueOf(Date.today().addDays(7)),
            'pageSize' => 10
        };
        prepareRest('/services/apexrest/mobile/planner/list', JSON.serialize(body));

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testPlannerListDefaultDates() {
        prepareRest('/services/apexrest/mobile/planner/list',
            '{"userId":"' + UserInfo.getUserId() + '"}');

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testPlannerListInvalidDateFallback() {
        // Triggers the try/catch fallback to today + 7 days.
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'fromDate' => 'not-a-date',
            'toDate' => 'also-bad'
        };
        prepareRest('/services/apexrest/mobile/planner/list', JSON.serialize(body));

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Invalid date falls back to defaults');
    }

    @isTest
    static void testPlannerListMissingUserId() {
        prepareRest('/services/apexrest/mobile/planner/list', '{}');

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testPlannerListUserNotFound() {
        prepareRest('/services/apexrest/mobile/planner/list',
            '{"userId":"no-such-user-' + System.currentTimeMillis() + '"}');

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Unknown user returns 400');
    }

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/mobile/planner/unknown', '{}');

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_InvalidJson() {
        prepareRest('/services/apexrest/mobile/planner/list', '{ broken json');

        Test.startTest();
        API_Planner_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode,
            'Malformed JSON returns 500 via top-level catch');
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_Planner_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}