/**
 * @description Test class for API_Competitor_Rest. Covers every branch:
 *               - handlePost dispatch (/create, /list, invalid endpoint,
 *                 top-level catch)
 *               - doCreateCompetitors: success, each validation throw (blank
 *                 accountId/userId/visitId/competitors, blank competitorName,
 *                 blank productId, product-not-found), employee/account/
 *                 visit not-found, invalid JSON
 *               - doListCompetitors: success, blank userId/siteVisitId/
 *                 accountId, employee/account/visit not-found, invalid JSON
 *
 *              Defensive @TestSetup builds Employee + Account + Visit +
 *              Product_Extension__c with HSN_SAC_Code__c (the controller
 *              looks up products by HSN code, not Id).
 */
@isTest
private class API_Competitor_Rest_Test {

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
            Name = 'API Comp Terr',
            Territory_Code__c = 'APICOMPTERR',
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        insert terr;

        Employee__c emp = new Employee__c(
            First_Name__c = 'Competitor',
            Last_Name__c = 'Tester',
            Employee_Code__c = 'EMP-COMP-' + String.valueOf(DateTime.now().getTime()).right(6),
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Territory__c = terr.Id,
            Email__c = 'comp@test.com',
            Phone__c = '9999999999',
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Band__c = 'Band 1',
            Date_of_Joining__c = Date.today().addYears(-1)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;

        String channel = pickPicklistValue('Account', 'Channel__c',
            new List<String>{ 'GT', 'MT', 'E-Commerce' });
        Account acc = new Account(
            Name = 'Competitor Test Outlet',
            Is_Active__c = true,
            Credit_Limit__c = 1000000,
            Credit_Utilized__c = 0
        );
        try { acc.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
        try { acc.put('Territory__c', terr.Id); } catch (Exception e) {}
        if (channel != null) try { acc.put('Channel__c', channel); } catch (Exception e) {}
        Map<String, Schema.RecordTypeInfo> rt =
            Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
        if (rt.containsKey('Distributor')) {
            acc.RecordTypeId = rt.get('Distributor').getRecordTypeId();
        }
        insert acc;

        Beat__c beat = new Beat__c(
            Name = 'Comp Beat', Beat_Code__c = 'COMPBEAT',
            Territory__c = terr.Id, Is_Active__c = true,
            Frequency__c = 'Weekly', Day_of_Week__c = 'Monday'
        );
        insert beat;

        Day_Attendance__c da = new Day_Attendance__c(
            Salesperson__c = UserInfo.getUserId(),
            Attendance_Date__c = Date.today(),
            Day_Start_Time__c = DateTime.now().addHours(-2),
            Start_Location_Lat__c = 19.0760,
            Start_Location_Long__c = 72.8777,
            Status__c = 'Started'
        );
        insert da;

        Visit__c v = new Visit__c(
            Account__c = acc.Id,
            Salesperson__c = UserInfo.getUserId(),
            Day_Attendance__c = da.Id,
            Beat__c = beat.Id,
            Visit_Date__c = Date.today(),
            Check_In_Time__c = DateTime.now(),
            Check_In_Lat__c = 19.0760,
            Check_In_Long__c = 72.8777,
            Visit_Status__c = 'Checked In',
            Is_Planned__c = true
        );
        insert v;

        // Product_Extension - the controller looks up by HSN_SAC_Code__c
        Product_Extension__c prod = new Product_Extension__c(
            Name = 'Comp Test Product', Is_Active__c = true
        );
        try { prod.put('SKU_Code__c', 'SKU-COMP-1'); } catch (Exception e) {}
        try { prod.put('HSN_SAC_Code__c', 'HSN-12345'); } catch (Exception e) {}
        insert prod;
    }

    private static void prepareRest(String uri, String requestJson) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = requestJson != null ? Blob.valueOf(requestJson) : Blob.valueOf('');
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    private static Account getAccount() { return [SELECT Id, Name FROM Account WHERE Name = 'Competitor Test Outlet' LIMIT 1]; }
    private static Visit__c getVisit() { return [SELECT Id, Name FROM Visit__c LIMIT 1]; }

    // ── doCreateCompetitors ─────────────────────────────────────────────────

    @isTest
    static void testCreate_Success() {
        Account acc = getAccount();
        Visit__c v = getVisit();

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Name,
            'userId' => UserInfo.getUserId(),
            'visitId' => v.Name,
            'competitors' => new List<Object>{
                new Map<String, Object>{
                    'competitorName' => 'RivalCo',
                    'productId' => 'HSN-12345',
                    'productName' => 'Rival product',
                    'discountPercentage' => 10,
                    'price' => 99.99,
                    'remarks' => 'Aggressive pricing'
                }
            }
        };
        prepareRest('/services/apexrest/competitor/create', JSON.serialize(payload));

        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Create succeeds. Body: ' + RestContext.response.responseBody.toString());
    }

    @isTest
    static void testCreate_BlankAccountId() {
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{ 'userId' => UserInfo.getUserId() }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_BlankUserId() {
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{ 'accountId' => 'X' }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_BlankVisitId() {
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => 'X', 'userId' => UserInfo.getUserId()
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_EmptyCompetitors() {
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => 'X', 'userId' => UserInfo.getUserId(), 'visitId' => 'V'
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_EmployeeNotFound() {
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => 'X',
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'visitId' => 'V',
                'competitors' => new List<Object>{ new Map<String, Object>{ 'competitorName' => 'A', 'productId' => 'B' } }
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_AccountNotFound() {
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => 'No-Such-Account-' + System.currentTimeMillis(),
                'userId' => UserInfo.getUserId(),
                'visitId' => 'V',
                'competitors' => new List<Object>{ new Map<String, Object>{ 'competitorName' => 'A', 'productId' => 'B' } }
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_VisitNotFound() {
        Account acc = getAccount();
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => acc.Name,
                'userId' => UserInfo.getUserId(),
                'visitId' => 'No-Such-Visit-' + System.currentTimeMillis(),
                'competitors' => new List<Object>{ new Map<String, Object>{ 'competitorName' => 'A', 'productId' => 'B' } }
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_BlankCompetitorName() {
        Account acc = getAccount();
        Visit__c v = getVisit();
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => acc.Name,
                'userId' => UserInfo.getUserId(),
                'visitId' => v.Name,
                'competitors' => new List<Object>{
                    new Map<String, Object>{ 'competitorName' => '', 'productId' => 'HSN-12345' }
                }
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_BlankProductId() {
        Account acc = getAccount();
        Visit__c v = getVisit();
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => acc.Name,
                'userId' => UserInfo.getUserId(),
                'visitId' => v.Name,
                'competitors' => new List<Object>{
                    new Map<String, Object>{ 'competitorName' => 'A', 'productId' => '' }
                }
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_ProductNotFound() {
        Account acc = getAccount();
        Visit__c v = getVisit();
        prepareRest('/services/apexrest/competitor/create',
            JSON.serialize(new Map<String, Object>{
                'accountId' => acc.Name,
                'userId' => UserInfo.getUserId(),
                'visitId' => v.Name,
                'competitors' => new List<Object>{
                    new Map<String, Object>{ 'competitorName' => 'A', 'productId' => 'HSN-NO-MATCH' }
                }
            }));
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_InvalidJson() {
        prepareRest('/services/apexrest/competitor/create', '{ bad json');
        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();
        System.assertEquals(500, RestContext.response.statusCode);
    }

    // ── doListCompetitors ───────────────────────────────────────────────────

    @isTest
    static void testList_Success() {
        Account acc = getAccount();
        Visit__c v = getVisit();

        // Seed a competitor first so the list returns rows.
        try {
            Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE HSN_SAC_Code__c = 'HSN-12345' LIMIT 1];
            Competitor__c c = new Competitor__c(
                Name = 'Pre-Listed RivalCo',
                Account__c = acc.Id,
                Visit__c = v.Id,
                Own_Product_Ext__c = p.Id,
                Shelf_Percent__c = 30,
                Competitor_Price__c = 88
            );
            insert c;
        } catch (Exception e) {}

        prepareRest('/services/apexrest/competitor/list',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => v.Name,
                'accountId' => acc.Name
            }));

        Test.startTest();
        API_Competitor_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'List succeeds. Body: ' + RestContext.response.responseBody.toString());
    }

    @isTest
    static void testList_BlankUserId() {
        prepareRest('/services/apexrest/competitor/list',
            JSON.serialize(new Map<String, Object>{ 'siteVisitId' => 'V' }));
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_BlankSiteVisitId() {
        prepareRest('/services/apexrest/competitor/list',
            JSON.serialize(new Map<String, Object>{ 'userId' => UserInfo.getUserId() }));
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_BlankAccountId() {
        prepareRest('/services/apexrest/competitor/list',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(), 'siteVisitId' => 'V'
            }));
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_EmployeeNotFound() {
        prepareRest('/services/apexrest/competitor/list',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'siteVisitId' => 'V', 'accountId' => 'X'
            }));
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_AccountNotFound() {
        prepareRest('/services/apexrest/competitor/list',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => 'V',
                'accountId' => 'No-Such-Account-' + System.currentTimeMillis()
            }));
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_VisitNotFound() {
        Account acc = getAccount();
        prepareRest('/services/apexrest/competitor/list',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => 'No-Such-Visit-' + System.currentTimeMillis(),
                'accountId' => acc.Name
            }));
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testList_InvalidJson() {
        prepareRest('/services/apexrest/competitor/list', '{ bad json');
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(500, RestContext.response.statusCode);
    }

    // ── Dispatch ───────────────────────────────────────────────────────────

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/competitor/unknown',
            JSON.serialize(new Map<String, Object>()));
        Test.startTest(); API_Competitor_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_Competitor_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}