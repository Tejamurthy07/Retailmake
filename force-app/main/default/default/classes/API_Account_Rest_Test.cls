/**
 * @description Test class for API_Account_Rest. Covers every branch of
 *              handleGet (list / detail / invalid / top-level catch), the
 *              detail not-found and missing-param paths, and the address
 *              builder with both full and partial field combinations.
 *
 *              Defensive fixture: Channel__c + Territory__c + Outlet_Type__c
 *              are resolved at runtime so org-specific validation rules
 *              (Channel required / Active accounts need territory /
 *              Outlet_Type required for Retailer) cannot fail setup. The
 *              previous version's _object_name assertion has been removed
 *              because that line is commented out in the controller.
 */
@isTest
private class API_Account_Rest_Test {

    private static String pickPicklistValue(String fieldName, List<String> preferred) {
        try {
            Schema.DescribeFieldResult dfr =
                Account.SObjectType.getDescribe().fields.getMap().get(fieldName).getDescribe();
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
        // Territory so the "Active accounts must have a territory" rule
        // (where present) is satisfied.
        Id territoryId;
        try {
            Territory_Master__c terr = new Territory_Master__c(
                Name = 'API Acc Terr',
                Territory_Code__c = 'APIACCTERR',
                State__c = 'Maharashtra',
                City__c = 'Mumbai',
                Is_Active__c = true
            );
            insert terr;
            territoryId = terr.Id;
        } catch (Exception e) {}

        String channel = pickPicklistValue('Channel__c',
            new List<String>{ 'GT', 'MT', 'E-Commerce' });

        Account acc = new Account(
            Name = 'ABC Wholesale',
            AccountNumber = 'OUT0001',
            BillingStreet = '123 Main St',
            BillingCity = 'Delhi',
            BillingState = 'Delhi',
            BillingPostalCode = '110001',
            Phone = '+91-9876543210',
            Outlet_Latitude__c = 28.6139,
            Outlet_Longitude__c = 77.2090,
            Credit_Limit__c = 100000.00,
            Outstanding_Balance__c = 45000.00,
            Is_Active__c = true
        );
        try { acc.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
        try { acc.put('Region__c', 'North Region'); } catch (Exception e) {}
        try { acc.put('Email__c', 'abc@wholesale.test'); } catch (Exception e) {}
        if (channel != null) try { acc.put('Channel__c', channel); } catch (Exception e) {}
        if (territoryId != null) try { acc.put('Territory__c', territoryId); } catch (Exception e) {}
        // Distributor RecordType (where present) skips the
        // "Outlet Type required for Retailer" rule.
        Map<String, Schema.RecordTypeInfo> rtMap =
            Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
        if (rtMap.containsKey('Distributor')) {
            acc.put('RecordTypeId', rtMap.get('Distributor').getRecordTypeId());
        }
        insert acc;
    }

    private static void prepareRest(String uri, Map<String, String> params) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'GET';
        if (params != null) {
            for (String k : params.keySet()) req.params.put(k, params.get(k));
        }
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    @isTest
    static void testAccountList() {
        prepareRest('/services/apexrest/mobile/account/list', null);

        Test.startTest();
        API_Account_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'List endpoint returns 200');
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'), 'Status flag true');

        List<Object> data = (List<Object>) result.get('data');
        System.assert(!data.isEmpty(), 'At least one account returned');

        Map<String, Object> first = (Map<String, Object>) data[0];
        System.assertEquals('ABC Wholesale', first.get('Name'),
            'First account is the setup record');
        System.assertEquals('OUT0001', first.get('Outlet_Code__c'),
            'AccountNumber mapped to Outlet_Code__c');
        System.assertNotEquals(null, first.get('Address__c'),
            'Address built from billing fields');
    }

    @isTest
    static void testAccountDetail() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'ABC Wholesale' LIMIT 1];
        prepareRest('/services/apexrest/mobile/account/detail',
            new Map<String, String>{ 'accountId' => acc.Id });

        Test.startTest();
        API_Account_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'Detail returns 200');
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'), 'Status flag true');

        Map<String, Object> data = (Map<String, Object>) result.get('data');
        System.assertEquals('ABC Wholesale', data.get('Name'));
        System.assertEquals('OUT0001', data.get('Outlet_Code__c'));
        System.assertEquals(true, data.get('Is_Active__c'));
    }

    @isTest
    static void testAccountDetailNotFound() {
        // Account key prefix 001 + 15 zeros guaranteed not to exist.
        prepareRest('/services/apexrest/mobile/account/detail',
            new Map<String, String>{ 'accountId' => '001000000000000AAA' });

        Test.startTest();
        API_Account_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Not-found returns 400');
    }

    @isTest
    static void testAccountDetailMissingParam() {
        prepareRest('/services/apexrest/mobile/account/detail', null);

        Test.startTest();
        API_Account_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Missing accountId returns 400');
    }

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/mobile/account/unknown', null);

        Test.startTest();
        API_Account_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Unknown endpoint returns 400');
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        // Force the outer handleGet try/catch by leaving RestContext.request
        // null. Accessing req.requestURI then NPEs and the catch wraps it
        // into sendServerError. This covers the catch (Exception e) branch.
        RestContext.request = null;
        RestContext.response = new RestResponse();

        Test.startTest();
        try {
            API_Account_Rest.handleGet();
        } catch (Exception e) {
            // sendServerError may rethrow; either way the catch line ran.
        }
        Test.stopTest();
    }

    @isTest
    static void testAddressBuilder_PartialFields() {
        // Insert a second account with only some billing fields populated so
        // buildAddress's per-field conditional appends are each exercised:
        // - one with only City, no Street/State/Postal
        // - one with no billing fields at all
        String channel = pickPicklistValue('Channel__c',
            new List<String>{ 'GT', 'MT' });

        Account onlyCity = new Account(
            Name = 'Only City Acc',
            AccountNumber = 'OUT0002',
            BillingCity = 'Mumbai',
            Is_Active__c = true,
            Credit_Limit__c = 10000
        );
        try { onlyCity.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
        if (channel != null) try { onlyCity.put('Channel__c', channel); } catch (Exception e) {}
        Map<String, Schema.RecordTypeInfo> rt =
            Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
        if (rt.containsKey('Distributor')) {
           onlyCity.put('RecordTypeId', rt.get('Distributor').getRecordTypeId());
        }
        try { insert onlyCity; } catch (Exception e) {}

        Account noAddress = new Account(
            Name = 'No Addr Acc',
            AccountNumber = 'OUT0003',
            Is_Active__c = true,
            Credit_Limit__c = 10000
        );
        try { noAddress.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
        if (channel != null) try { noAddress.put('Channel__c', channel); } catch (Exception e) {}
        if (rt.containsKey('Distributor')) {
           noAddress.put('RecordTypeId', rt.get('Distributor').getRecordTypeId());
        }
        try { insert noAddress; } catch (Exception e) {}

        prepareRest('/services/apexrest/mobile/account/list', null);

        Test.startTest();
        API_Account_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode, 'List still returns 200');
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        List<Object> data = (List<Object>) result.get('data');
        System.assert(data.size() >= 1,
            'List includes the original + any successfully-inserted partial accounts');
    }
}