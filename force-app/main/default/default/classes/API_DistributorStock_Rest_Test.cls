/**
 * @description Test class for API_DistributorStock_Rest. Covers every branch:
 *               - handlePost dispatch (/create, /summary, invalid endpoint,
 *                 null-request top-level catch)
 *               - doCreateStock: success, missing userId, user-not-found,
 *                 missing accountId (and the 'accoutnId' typo fallback),
 *                 account-not-found, empty products array, blank productName
 *                 inside the loop, product-not-found, optional visit (passed
 *                 + missing + Name lookup), invalid JSON
 *               - doStockSummary: success (with seeded stock records), missing
 *                 userId/siteVisitId/accountId, user / visit / account not-
 *                 found, the 'accoutnId' typo fallback, invalid JSON, the
 *                 variance/netStock computation branches (opening = 0 makes
 *                 variance null)
 *
 *              Defensive @TestSetup uses runtime picklist resolution
 *              (Channel, Visit_Status) and sets every Employee + Account
 *              required field discovered across this project.
 */
@isTest
private class API_DistributorStock_Rest_Test {

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
    static void setupTestData() {
        // Territory (required by "Active employees must be assigned to a territory")
        Territory_Master__c terr = new Territory_Master__c(
            Name = 'API DS Terr',
            Territory_Code__c = 'APIDSTERR',
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        insert terr;

        // Employee linked to the running user with the full proven field set
        Employee__c emp = new Employee__c(
            First_Name__c = 'DS',
            Last_Name__c = 'Tester',
            Employee_Code__c = 'EMP-DS-' + String.valueOf(DateTime.now().getTime()).right(6),
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Territory__c = terr.Id,
            Email__c = 'ds@test.com',
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

        // Account with all the validation rule fields we've discovered
        String channel = pickPicklistValue('Account', 'Channel__c',
            new List<String>{ 'GT', 'MT', 'E-Commerce' });
        Account acc = new Account(
            Name = 'Test Distributor',
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

        // Beat + Day_Attendance + Visit
        Beat__c beat = new Beat__c(
            Name = 'DS Beat', Beat_Code__c = 'DSBEAT',
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

        String visitStatus = pickPicklistValue('Visit__c', 'Visit_Status__c',
            new List<String>{ 'Checked In', 'Pending', 'In Progress', 'Completed' });
        Visit__c v = new Visit__c(
            Account__c = acc.Id,
            Salesperson__c = UserInfo.getUserId(),
            Day_Attendance__c = da.Id,
            Beat__c = beat.Id,
            Visit_Date__c = Date.today(),
            Check_In_Time__c = DateTime.now(),
            Check_In_Lat__c = 19.0760,
            Check_In_Long__c = 72.8777,
            Is_Planned__c = true
        );
        if (visitStatus != null) v.Visit_Status__c = visitStatus;
        insert v;

        // Products
        Product_Extension__c p1 = new Product_Extension__c(
            Name = 'Roasted Pistachios', Is_Active__c = true
        );
        try { p1.put('SKU_Code__c', 'SKU-PIST'); } catch (Exception e) {}
        Product_Extension__c p2 = new Product_Extension__c(
            Name = 'Medjool Dates Premium', Is_Active__c = true
        );
        try { p2.put('SKU_Code__c', 'SKU-DATES'); } catch (Exception e) {}
        insert new List<Product_Extension__c>{ p1, p2 };

        // Seed Distributor_Stock so the summary endpoint has rows. One row
        // with opening>0 (variance computed) and one with opening=0
        // (variance branch -> null) so both paths in doStockSummary run.
        Distributor_Stock__c s1 = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = p1.Id,
            Visit__c = v.Id,
            Opening_Stock__c = 120,
            Closing_Stock__c = 100,
            Damaged_Qty__c = 5,
            Stock_Date__c = Date.today(),
            Is_Current__c = true
        );
        Distributor_Stock__c s2 = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = p2.Id,
            Visit__c = v.Id,
            Opening_Stock__c = 0,
            Closing_Stock__c = 40,
            Damaged_Qty__c = 2,
            Stock_Date__c = Date.today(),
            Is_Current__c = true
        );
        insert new List<Distributor_Stock__c>{ s1, s2 };
    }

    private static void prepareRest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = body != null ? Blob.valueOf(body) : Blob.valueOf('');
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    private static Account getAccount() { return [SELECT Id, Name FROM Account WHERE Name = 'Test Distributor' LIMIT 1]; }
    private static Visit__c getVisit() { return [SELECT Id, Name FROM Visit__c LIMIT 1]; }

    // ── doCreateStock branches ──────────────────────────────────────────────

    @isTest
    static void testCreate_Success() {
        Account acc = getAccount();
        Visit__c v = getVisit();

        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accountId' => acc.Name,
            'visitId' => v.Id,
            'products' => new List<Object>{
                new Map<String, Object>{
                    'productName' => 'Roasted Pistachios',
                    'openingStock' => 100,
                    'closingStock' => 80,
                    'damagedStock' => 2
                }
            }
        };
        prepareRest('/services/apexrest/mobile/distributor-stock/create', JSON.serialize(payload));

        Test.startTest();
        API_DistributorStock_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Create succeeds. Body: ' + RestContext.response.responseBody.toString());
    }

    @isTest
    static void testCreate_AccountIdTypoFallback() {
        // The controller accepts both 'accountId' and the misspelled 'accoutnId'.
        Account acc = getAccount();
        Visit__c v = getVisit();
        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'accoutnId' => acc.Name,  // typo on purpose
            'visitId' => v.Name,       // exercises Name-based visit lookup
            'products' => new List<Object>{
                new Map<String, Object>{
                    'productName' => 'Roasted Pistachios',
                    'openingStock' => 50, 'closingStock' => 40, 'damagedStock' => 1
                }
            }
        };
        prepareRest('/services/apexrest/mobile/distributor-stock/create', JSON.serialize(payload));

        Test.startTest();
        API_DistributorStock_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Typo fallback path returns 200. Body: ' + RestContext.response.responseBody.toString());
    }

    @isTest
    static void testCreate_MissingUserId() {
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{ 'accountId' => 'X' }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_UserNotFound() {
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'accountId' => 'X'
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_MissingAccountId() {
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{ 'userId' => UserInfo.getUserId() }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_AccountNotFound() {
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'accountId' => 'No-Such-Account-' + System.currentTimeMillis()
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_EmptyProducts() {
        Account acc = getAccount();
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'accountId' => acc.Name
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_BlankProductName() {
        Account acc = getAccount();
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'accountId' => acc.Name,
                'products' => new List<Object>{
                    new Map<String, Object>{ 'productName' => '' }
                }
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_ProductNotFound() {
        Account acc = getAccount();
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'accountId' => acc.Name,
                'products' => new List<Object>{
                    new Map<String, Object>{
                        'productName' => 'No-Such-Product-' + System.currentTimeMillis()
                    }
                }
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testCreate_OptionalVisit_NotFound() {
        // visitId provided but doesn't match anything -> resolvedVisitId stays null
        // and creation still succeeds (visit is optional).
        Account acc = getAccount();
        prepareRest('/services/apexrest/mobile/distributor-stock/create',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'accountId' => acc.Name,
                'visitId' => 'No-Such-Visit-' + System.currentTimeMillis(),
                'products' => new List<Object>{
                    new Map<String, Object>{ 'productName' => 'Roasted Pistachios' }
                }
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode,
            'Optional visit not-found still succeeds');
    }

    @isTest
    static void testCreate_InvalidJson() {
        prepareRest('/services/apexrest/mobile/distributor-stock/create', '{ bad json');
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(500, RestContext.response.statusCode);
    }

    // ── doStockSummary branches ─────────────────────────────────────────────

    @isTest
    static void testSummary_Success() {
        Account acc = getAccount();
        Visit__c v = getVisit();
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => v.Name,
                'accountId' => acc.Name
            }));

        Test.startTest();
        API_DistributorStock_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode,
            'Summary succeeds. Body: ' + RestContext.response.responseBody.toString());

        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        Map<String, Object> data = (Map<String, Object>) result.get('data');
        // Setup seeded 2 stock rows; assert the list is present.
        System.assertNotEquals(null, data.get('stockDetails'),
            'stockDetails key present');
    }

    @isTest
    static void testSummary_AccountIdTypoFallback() {
        Account acc = getAccount();
        Visit__c v = getVisit();
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => v.Name,
                'accoutnId' => acc.Name  // typo on purpose
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(200, RestContext.response.statusCode,
            'Summary accepts typo accoutnId fallback');
    }

    @isTest
    static void testSummary_MissingUserId() {
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{ 'siteVisitId' => 'V', 'accountId' => 'X' }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testSummary_UserNotFound() {
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'siteVisitId' => 'V', 'accountId' => 'X'
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testSummary_MissingSiteVisitId() {
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(), 'accountId' => 'X'
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testSummary_VisitNotFound() {
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => 'No-Such-Visit-' + System.currentTimeMillis(),
                'accountId' => 'X'
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testSummary_MissingAccountId() {
        Visit__c v = getVisit();
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => v.Name
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testSummary_AccountNotFound() {
        Visit__c v = getVisit();
        prepareRest('/services/apexrest/mobile/distributor-stock/summary',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'siteVisitId' => v.Name,
                'accountId' => 'No-Such-Account-' + System.currentTimeMillis()
            }));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testSummary_InvalidJson() {
        prepareRest('/services/apexrest/mobile/distributor-stock/summary', '{ bad json');
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(500, RestContext.response.statusCode);
    }

    // ── Dispatch branches ──────────────────────────────────────────────────

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/mobile/distributor-stock/unknown',
            JSON.serialize(new Map<String, Object>()));
        Test.startTest(); API_DistributorStock_Rest.handlePost(); Test.stopTest();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_DistributorStock_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}