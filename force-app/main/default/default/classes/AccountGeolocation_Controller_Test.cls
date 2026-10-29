@IsTest
private class AccountGeolocation_Controller_Test {

    @TestSetup
    static void setupData() {
        Account accWithGeo = TestDataFactory.createAccountWithGeoData('Outlet With Geo', 'Retailer', 19.0760, 72.8777);
        accWithGeo.Is_Active__c = true;
        insert accWithGeo;

        Territory_Master__c ter = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Account accWithBilling = new Account(
            Name = 'Outlet With Billing Only',
            Type = 'Retailer',
            Channel__c = 'GT',
            Outlet_Type__c = 'Grocery',
            Territory__c = ter.Id,
            BillingStreet = '456 Test Lane',
            BillingCity = 'Delhi',
            BillingState = 'Delhi',
            BillingPostalCode = '110001',
            BillingCountry = 'India',
            BillingLatitude = 28.6139,
            BillingLongitude = 77.2090,
            Is_Active__c = true
        );
        insert accWithBilling;

        Account accNoGeo = TestDataFactory.createAndInsertAccount('Outlet No Geo', 'Retailer');
        accNoGeo.Is_Active__c = true;
        update accNoGeo;
    }

    // ── saveAccountLocation ──────────────────────────────────────────

    @IsTest
    static void testSaveAccountLocation_Success() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet No Geo' LIMIT 1];

        Test.startTest();
        Account result = AccountGeolocation_Controller.saveAccountLocation(
            acc.Id, 19.0760, 72.8777, 10.0, 200
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Returned account should not be null');
        System.assertEquals(19.0760, result.Outlet_Latitude__c, 'Latitude should be saved');
        System.assertEquals(72.8777, result.Outlet_Longitude__c, 'Longitude should be saved');
        System.assertEquals(200, result.Geofence_Radius__c, 'Geofence radius should be saved');
    }

    @IsTest
    static void testSaveAccountLocation_DefaultRadius() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet No Geo' LIMIT 1];

        Test.startTest();
        Account result = AccountGeolocation_Controller.saveAccountLocation(
            acc.Id, 19.0760, 72.8777, 10.0, null
        );
        Test.stopTest();

        System.assertEquals(100, result.Geofence_Radius__c, 'Default radius should be 100');
    }

    @IsTest
    static void testSaveAccountLocation_NullAccountId() {
        try {
            AccountGeolocation_Controller.saveAccountLocation(null, 19.0760, 72.8777, 10.0, 200);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Account Id is required') ||
                          e.getMessage().contains('Script-thrown exception'),
                          'Should throw account id required error');
        }
    }

    @IsTest
    static void testSaveAccountLocation_NullLatLng() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet No Geo' LIMIT 1];

        try {
            AccountGeolocation_Controller.saveAccountLocation(acc.Id, null, 72.8777, 10.0, 200);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Latitude and longitude are required') ||
                          e.getMessage().contains('Script-thrown exception'),
                          'Should throw lat/lng required error');
        }
    }

    @IsTest
    static void testSaveAccountLocation_OutOfRangeLatitude() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet No Geo' LIMIT 1];

        try {
            AccountGeolocation_Controller.saveAccountLocation(acc.Id, 95.0, 72.8777, 10.0, 200);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('out of range') ||
                          e.getMessage().contains('Script-thrown exception'),
                          'Should throw out-of-range error');
        }
    }

    @IsTest
    static void testSaveAccountLocation_OutOfRangeLongitude() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet No Geo' LIMIT 1];

        try {
            AccountGeolocation_Controller.saveAccountLocation(acc.Id, 19.0760, 200.0, 10.0, 200);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('out of range') ||
                          e.getMessage().contains('Script-thrown exception'),
                          'Should throw out-of-range error');
        }
    }

    // ── getAccountLocation ───────────────────────────────────────────

    @IsTest
    static void testGetAccountLocation_Success() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Geo' LIMIT 1];

        Test.startTest();
        Account result = AccountGeolocation_Controller.getAccountLocation(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return account');
        System.assertEquals(19.0760, result.Outlet_Latitude__c, 'Latitude should match');
        System.assertEquals(72.8777, result.Outlet_Longitude__c, 'Longitude should match');
    }

    @IsTest
    static void testGetAccountLocation_NullId() {
        Test.startTest();
        Account result = AccountGeolocation_Controller.getAccountLocation(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Null Id should return null');
    }

    // ── getGeolocationStats ──────────────────────────────────────────

    @IsTest
    static void testGetGeolocationStats_NoTerritory() {
        Test.startTest();
        Map<String, Integer> stats = AccountGeolocation_Controller.getGeolocationStats(null);
        Test.stopTest();

        System.assert(stats.containsKey('total'), 'Should contain total');
        System.assert(stats.containsKey('withLocation'), 'Should contain withLocation');
        System.assert(stats.containsKey('withBilling'), 'Should contain withBilling');
        System.assert(stats.containsKey('missing'), 'Should contain missing');
        System.assert(stats.get('total') >= 3, 'Should have at least 3 accounts');
    }

    @IsTest
    static void testGetGeolocationStats_WithTerritory() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Test Territory', 'TT-001');

        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Geo' LIMIT 1];
        acc.Territory__c = territory.Id;
        update acc;

        Test.startTest();
        Map<String, Integer> stats = AccountGeolocation_Controller.getGeolocationStats(territory.Id);
        Test.stopTest();

        System.assert(stats.containsKey('total'), 'Should contain total');
        System.assert(stats.get('total') >= 1, 'Should have at least 1 account in territory');
    }

    // ── bulkCopyFromBillingAddress ───────────────────────────────────

    @IsTest
    static void testBulkCopyFromBillingAddress_NoTerritory() {
        Test.startTest();
        Integer count = AccountGeolocation_Controller.bulkCopyFromBillingAddress(null, 150);
        Test.stopTest();

        System.assert(count >= 1, 'Should have copied at least 1 account');

        Account updated = [SELECT Outlet_Latitude__c, Outlet_Longitude__c, Geofence_Radius__c
                           FROM Account WHERE Name = 'Outlet With Billing Only' LIMIT 1];
        System.assertEquals(28.6139, updated.Outlet_Latitude__c, 'Latitude should be copied from billing');
        System.assertEquals(77.2090, updated.Outlet_Longitude__c, 'Longitude should be copied from billing');
    }

    @IsTest
    static void testBulkCopyFromBillingAddress_WithTerritory() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Test Territory', 'TT-002');

        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Billing Only' LIMIT 1];
        acc.Territory__c = territory.Id;
        update acc;

        Test.startTest();
        Integer count = AccountGeolocation_Controller.bulkCopyFromBillingAddress(territory.Id, null);
        Test.stopTest();

        System.assert(count >= 1, 'Should have copied at least 1 account in territory');
    }

    @IsTest
    static void testBulkCopyFromBillingAddress_NoneToUpdate() {
        // All accounts with billing already have outlet geo set, so 0
        // First set outlet geo on the billing-only account
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Billing Only' LIMIT 1];
        acc.Outlet_Latitude__c = 28.6139;
        acc.Outlet_Longitude__c = 77.2090;
        update acc;

        Test.startTest();
        Integer count = AccountGeolocation_Controller.bulkCopyFromBillingAddress(null, 100);
        Test.stopTest();

        System.assertEquals(0, count, 'Should return 0 when no accounts need updating');
    }

    // ── clearAccountLocation ─────────────────────────────────────────

    @IsTest
    static void testClearAccountLocation_Success() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Geo' LIMIT 1];

        Test.startTest();
        AccountGeolocation_Controller.clearAccountLocation(acc.Id);
        Test.stopTest();

        Account updated = [SELECT Outlet_Latitude__c, Outlet_Longitude__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(null, updated.Outlet_Latitude__c, 'Latitude should be cleared');
        System.assertEquals(null, updated.Outlet_Longitude__c, 'Longitude should be cleared');
    }

    @IsTest
    static void testClearAccountLocation_NullId() {
        Test.startTest();
        AccountGeolocation_Controller.clearAccountLocation(null);
        Test.stopTest();
        // Should not throw - just returns
    }

    // ── checkGeofence ────────────────────────────────────────────────

    @IsTest
    static void testCheckGeofence_WithinFence() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Geo' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = AccountGeolocation_Controller.checkGeofence(
            acc.Id, 19.0761, 72.8778
        );
        Test.stopTest();

        System.assertEquals(true, result.get('hasFence'), 'Should have fence');
        System.assertEquals(true, result.get('withinFence'), 'Should be within fence for nearby coords');
        System.assertNotEquals(null, result.get('distanceMeters'), 'Distance should be calculated');
    }

    @IsTest
    static void testCheckGeofence_OutsideFence() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Geo' LIMIT 1];

        Test.startTest();
        // Use coordinates far away (Delhi vs Mumbai)
        Map<String, Object> result = AccountGeolocation_Controller.checkGeofence(
            acc.Id, 28.6139, 77.2090
        );
        Test.stopTest();

        System.assertEquals(true, result.get('hasFence'), 'Should have fence');
        System.assertEquals(false, result.get('withinFence'), 'Should be outside fence for distant coords');
    }

    @IsTest
    static void testCheckGeofence_NoGeoConfigured() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet No Geo' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = AccountGeolocation_Controller.checkGeofence(
            acc.Id, 19.0760, 72.8777
        );
        Test.stopTest();

        System.assertEquals(false, result.get('hasFence'), 'Should not have fence');
        System.assertEquals(true, result.get('withinFence'), 'Default should be within fence');
    }

    @IsTest
    static void testCheckGeofence_NullParams() {
        Test.startTest();
        Map<String, Object> result = AccountGeolocation_Controller.checkGeofence(null, null, null);
        Test.stopTest();

        System.assertEquals(false, result.get('hasFence'), 'Should not have fence');
        System.assertEquals('Missing account or location.', result.get('message'), 'Should have missing message');
    }

    @IsTest
    static void testCheckGeofence_NullLatLng() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Outlet With Geo' LIMIT 1];

        Test.startTest();
        Map<String, Object> result = AccountGeolocation_Controller.checkGeofence(acc.Id, null, null);
        Test.stopTest();

        System.assertEquals('Missing account or location.', result.get('message'));
    }
}