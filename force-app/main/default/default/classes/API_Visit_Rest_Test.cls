@isTest
private class API_Visit_Rest_Test {

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
            Employee_Code__c = 'CPC0027',
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
        try { acc.put('BillingStreet', '12 Main St'); } catch (Exception e) {}
        try { acc.put('BillingCity', 'Mumbai'); } catch (Exception e) {}
        try { acc.put('BillingState', 'MH'); } catch (Exception e) {}
        try { acc.put('BillingPostalCode', '400001'); } catch (Exception e) {}
        update acc;

        Beat__c beat = TestDataFactory.createAndInsertBeat('Beat 1', 'B001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        String status = pickPicklistValue('Visit__c', 'Visit_Status__c',
            new List<String>{ 'Pending', 'Planned', 'Scheduled' });

        Visit__c visit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        if (status != null) visit.Visit_Status__c = status;
        visit.Visit_Date__c = Date.today();
        visit.Is_Planned__c = true;
        visit.Check_In_Latitude__c = 25.5941;
        visit.Check_In_Longitude__c = 85.1376;
        // Seed Check_In_Time__c so the /checkout test can satisfy the
        // "Check-Out Time must be after Check-In Time" validation.
        visit.Check_In_Time__c = DateTime.newInstanceGmt(2026, 4, 6, 15, 0, 0);
        insert visit;
    }

    private static void prepareRest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    // ── /list ─────────────────────────────────────────────────────────────

    @isTest
    static void testVisitList() {
        prepareRest('/services/apexrest/mobile/visit/list',
            '{"userId":"' + UserInfo.getUserId() + '","schdduleDate":"","status":"","pageSize":0}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitListWithFilters() {
        String status = [SELECT Visit_Status__c FROM Visit__c LIMIT 1].Visit_Status__c;
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'schdduleDate' => String.valueOf(Date.today()),
            'status' => status,
            'pageSize' => 10
        };
        prepareRest('/services/apexrest/mobile/visit/list', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitListAltDateKey() {
        // Use 'scheduleDate' (the non-typo key) to exercise the fallback path.
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'scheduleDate' => String.valueOf(Date.today())
        };
        prepareRest('/services/apexrest/mobile/visit/list', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitListInvalidDate() {
        // Invalid date triggers the catch and returns all visits.
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'schdduleDate' => 'not-a-date'
        };
        prepareRest('/services/apexrest/mobile/visit/list', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitListMissingUserId() {
        prepareRest('/services/apexrest/mobile/visit/list', '{}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitListUserNotFound() {
        prepareRest('/services/apexrest/mobile/visit/list',
            '{"userId":"no-such-user-' + System.currentTimeMillis() + '"}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── /detail ───────────────────────────────────────────────────────────

    @isTest
    static void testVisitDetail() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => visit.Name
        };
        prepareRest('/services/apexrest/mobile/visit/detail', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode,
            RestContext.response.responseBody.toString());
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        Map<String, Object> data = (Map<String, Object>) result.get('data');
        System.assertEquals('Happy Traders', data.get('outletName'));
    }

    @isTest
    static void testVisitDetailMissingUserId() {
        prepareRest('/services/apexrest/mobile/visit/detail', '{}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitDetailMissingSiteVisitId() {
        prepareRest('/services/apexrest/mobile/visit/detail',
            '{"userId":"' + UserInfo.getUserId() + '"}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitDetailUserNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'siteVisitId' => 'V-1'
        };
        prepareRest('/services/apexrest/mobile/visit/detail', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testVisitDetailNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'siteVisitId' => 'V-DOES-NOT-EXIST'
        };
        prepareRest('/services/apexrest/mobile/visit/detail', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── /add ──────────────────────────────────────────────────────────────

    @isTest
    static void testAddVisit() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountId' => acc.Id,
            'purpose' => 'Sales Call',
            'Notes' => 'Follow up on order'
        };
        prepareRest('/services/apexrest/mobile/visit/add', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode,
            RestContext.response.responseBody.toString());
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
    }

    @isTest
    static void testAddVisitMissingUserId() {
        prepareRest('/services/apexrest/mobile/visit/add', '{}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAddVisitMissingAccountId() {
        prepareRest('/services/apexrest/mobile/visit/add',
            '{"userId":"' + UserInfo.getUserId() + '"}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAddVisitUserNotFound() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'accountId' => acc.Id
        };
        prepareRest('/services/apexrest/mobile/visit/add', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testAddVisitAccountNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountId' => '001000000000000AAA'
        };
        prepareRest('/services/apexrest/mobile/visit/add', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── /checkin ──────────────────────────────────────────────────────────

    @isTest
    static void testCheckInVisit() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => visit.Name,
            'outletName' => 'Happy Traders',
            'checkInTime' => '2026-04-06T15:30:00Z',
            'checkInlatitude' => 25.5941,
            'checkInlongitude' => 85.1376,
            'CheckInaccuracy' => 10,
            'distanceFromOutlet' => 5,
            'isWithinGeofence' => true,
            'geofenceMessage' => 'Within geofence'
        };
        prepareRest('/services/apexrest/mobile/visit/checkin', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode,
            RestContext.response.responseBody.toString());
    }

    @isTest
    static void testCheckInVisitInvalidTime() {
        // Invalid time format triggers parse catch (sets local var to null,
        // then update proceeds without setting Check_In_Time__c).
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => visit.Name,
            'outletName' => 'Happy Traders',
            'checkInTime' => 'not-a-time'
        };
        prepareRest('/services/apexrest/mobile/visit/checkin', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckInVisitMissingUserId() {
        prepareRest('/services/apexrest/mobile/visit/checkin', '{}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckInVisitMissingVisitId() {
        prepareRest('/services/apexrest/mobile/visit/checkin',
            '{"userId":"' + UserInfo.getUserId() + '"}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckInVisitMissingOutletName() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => 'V-1'
        };
        prepareRest('/services/apexrest/mobile/visit/checkin', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckInVisitUserNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'visitId' => 'V-1',
            'outletName' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/mobile/visit/checkin', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckInVisitNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => 'V-DOES-NOT-EXIST',
            'outletName' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/mobile/visit/checkin', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── /checkout ─────────────────────────────────────────────────────────

    @isTest
    static void testCheckOutVisit() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => visit.Name,
            'outletName' => 'Happy Traders',
            'checkOutTime' => '2026-04-06T16:30:00Z',
            'checkOutlatitude' => 25.5941,
            'checkOutlongitude' => 85.1376,
            'comments' => 'All good'
        };
        prepareRest('/services/apexrest/mobile/visit/checkout', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode,
            RestContext.response.responseBody.toString());
    }

    @isTest
    static void testCheckOutVisitInvalidTime() {
        Visit__c visit = [SELECT Name FROM Visit__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => visit.Name,
            'outletName' => 'Happy Traders',
            'checkOutTime' => 'not-a-time'
        };
        prepareRest('/services/apexrest/mobile/visit/checkout', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckOutVisitMissingUserId() {
        prepareRest('/services/apexrest/mobile/visit/checkout', '{}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckOutVisitMissingVisitId() {
        prepareRest('/services/apexrest/mobile/visit/checkout',
            '{"userId":"' + UserInfo.getUserId() + '"}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckOutVisitMissingOutletName() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => 'V-1'
        };
        prepareRest('/services/apexrest/mobile/visit/checkout', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckOutVisitUserNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => 'no-such-user-' + System.currentTimeMillis(),
            'visitId' => 'V-1',
            'outletName' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/mobile/visit/checkout', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCheckOutVisitNotFound() {
        Map<String, Object> body = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'visitId' => 'V-DOES-NOT-EXIST',
            'outletName' => 'Happy Traders'
        };
        prepareRest('/services/apexrest/mobile/visit/checkout', JSON.serialize(body));
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── dispatch / top-level ──────────────────────────────────────────────

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/mobile/visit/unknown', '{}');
        Test.startTest();
        API_Visit_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_Visit_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}