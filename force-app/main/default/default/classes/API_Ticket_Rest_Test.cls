@isTest
private class API_Ticket_Rest_Test {

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
            Employee_Code__c = 'CPC0026',
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

        Account acc = TestDataFactory.createAndInsertAccount('Happy Traders', 'Retailer');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Beat 1', 'B001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        Visit__c visit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        visit.Visit_Date__c = Date.today();
        insert visit;

        // Seed three tickets exercising the three Priority__c colour branches
        // and the Closed status colour branch in /list.
        String pHigh = pickPicklistValue('Ticket__c', 'Priority__c',
            new List<String>{ 'High' });
        String pMedium = pickPicklistValue('Ticket__c', 'Priority__c',
            new List<String>{ 'Medium' });
        String pLow = pickPicklistValue('Ticket__c', 'Priority__c',
            new List<String>{ 'Low' });
        String sClosed = pickPicklistValue('Ticket__c', 'Status__c',
            new List<String>{ 'Closed' });
        String catVal = pickPicklistValue('Ticket__c', 'Category__c',
            new List<String>{ 'Complaint', 'Request', 'Query', 'Other' });

        List<Ticket__c> seedTickets = new List<Ticket__c>();
        if (pHigh != null) {
            seedTickets.add(new Ticket__c(
                Reported_By__c = UserInfo.getUserId(),
                Account__c = acc.Id,
                Visit__c = visit.Id,
                Subject__c = 'High prio',
                Category__c = catVal,
                Priority__c = pHigh,
                Description__c = 'desc'
            ));
        }
        if (pMedium != null) {
            seedTickets.add(new Ticket__c(
                Reported_By__c = UserInfo.getUserId(),
                Account__c = acc.Id,
                Visit__c = visit.Id,
                Subject__c = 'Med prio',
                Category__c = catVal,
                Priority__c = pMedium,
                Description__c = 'desc'
            ));
        }
        if (pLow != null) {
            Ticket__c t = new Ticket__c(
                Reported_By__c = UserInfo.getUserId(),
                Account__c = acc.Id,
                Visit__c = visit.Id,
                Subject__c = 'Low prio closed',
                Category__c = catVal,
                Priority__c = pLow,
                Description__c = 'desc'
            );
            if (sClosed != null) t.Status__c = sClosed;
            seedTickets.add(t);
        }
        if (!seedTickets.isEmpty()) insert seedTickets;
    }

    private static void prepareRest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    // ── /create ───────────────────────────────────────────────────────────

    @isTest
    static void testCreateTicket_Success() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        String cat = pickPicklistValue('Ticket__c', 'Category__c',
            new List<String>{ 'Complaint', 'Request', 'Query', 'Other' });
        String pri = pickPicklistValue('Ticket__c', 'Priority__c',
            new List<String>{ 'High', 'Medium', 'Low' });

        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountName' => 'Happy Traders',
            'visitId' => visit.Name,
            'subject' => 'Stock issue',
            'category' => cat,
            'priority' => pri,
            'description' => 'Out of stock',
            'source' => 'Mobile'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));

        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            RestContext.response.responseBody.toString());
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
    }

    @isTest
    static void testCreateTicket_MissingUserId() {
        prepareRest('/services/apexrest/ticket/create', '{}');
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_MissingAccountName() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId()
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_MissingVisitId() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountName' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_MissingSubject() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountName' => 'Happy Traders',
            'visitId' => 'V-1'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_MissingCategory() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountName' => 'Happy Traders',
            'visitId' => 'V-1',
            'subject' => 'x'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_MissingPriority() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountName' => 'Happy Traders',
            'visitId' => 'V-1',
            'subject' => 'x',
            'category' => 'Complaint'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_EmployeeNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'accountName' => 'Happy Traders',
            'visitId' => 'V-1',
            'subject' => 'x',
            'category' => 'Complaint',
            'priority' => 'High'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_AccountNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountName' => 'No Such Account ' + System.currentTimeMillis(),
            'visitId' => 'V-1',
            'subject' => 'x',
            'category' => 'Complaint',
            'priority' => 'High'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreateTicket_VisitNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountName' => 'Happy Traders',
            'visitId' => 'V-DOES-NOT-EXIST',
            'subject' => 'x',
            'category' => 'Complaint',
            'priority' => 'High'
        };
        prepareRest('/services/apexrest/ticket/create', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── /list ─────────────────────────────────────────────────────────────

    @isTest
    static void testListTickets_Success() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => visit.Name,
            'accountId' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/ticket/list', JSON.serialize(body));

        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
        Map<String, Object> data = (Map<String, Object>) result.get('data');
        System.assertNotEquals(null, data.get('tickets'));
    }

    @isTest
    static void testListTickets_MissingUserId() {
        prepareRest('/services/apexrest/ticket/list', '{}');
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testListTickets_MissingSiteVisitId() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId()
        };
        prepareRest('/services/apexrest/ticket/list', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testListTickets_MissingAccountId() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => 'V-1'
        };
        prepareRest('/services/apexrest/ticket/list', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testListTickets_EmployeeNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'siteVisitId' => 'V-1',
            'accountId' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/ticket/list', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testListTickets_AccountNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => 'V-1',
            'accountId' => 'No Such Account ' + System.currentTimeMillis()
        };
        prepareRest('/services/apexrest/ticket/list', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testListTickets_VisitNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => 'V-DOES-NOT-EXIST',
            'accountId' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/ticket/list', JSON.serialize(body));
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── dispatch / top-level ──────────────────────────────────────────────

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/ticket/unknown', '{}');
        Test.startTest();
        API_Ticket_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_Ticket_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}