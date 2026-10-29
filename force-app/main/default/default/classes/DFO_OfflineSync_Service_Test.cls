@isTest
private class DFO_OfflineSync_Service_Test {

    @testSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Sync Territory', 'TER-SYNC01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Sync Beat', 'BEAT-SYNC01', territory.Id);

        Account acct = TestDataFactory.createAccount('Sync Outlet', 'Retailer');
        insert acct;

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        // Create offline visits
        List<Visit__c> visits = new List<Visit__c>();
        for (Integer i = 0; i < 3; i++) {
            Visit__c v = TestDataFactory.createVisit(acct.Id, UserInfo.getUserId(), da.Id, beat.Id);
            v.Offline_Created__c = true;
            v.Is_Synced__c = false;
            visits.add(v);
        }
        insert visits;

        // Create offline orders on different dates to avoid duplicate validation
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];
        List<Sales_Order__c> orders = new List<Sales_Order__c>();
        for (Integer i = 0; i < 2; i++) {
            Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
            order.Offline_Created__c = true;
            order.Is_Synced__c = false;
            order.Order_Date__c = Date.today().addDays(-i);
            orders.add(order);
        }
        insert orders;
    }

    @isTest
    static void testSyncVisitsWithData() {
        Test.startTest();
        DFO_OfflineSync_Service.SyncResult result = DFO_OfflineSync_Service.syncVisits(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(3, result.totalProcessed, 'Should process 3 offline visits');
        System.assertEquals(3, result.successCount, 'All 3 should sync successfully');
        System.assertEquals(0, result.errorCount);
    }

    @isTest
    static void testSyncOrdersWithData() {
        Test.startTest();
        DFO_OfflineSync_Service.SyncResult result = DFO_OfflineSync_Service.syncOrders(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(2, result.totalProcessed, 'Should process 2 offline orders');
        System.assertEquals(2, result.successCount, 'All 2 should sync successfully');
        System.assertEquals(0, result.errorCount);
    }

    @isTest
    static void testSyncAllWithData() {
        Test.startTest();
        DFO_OfflineSync_Service.SyncResult result = DFO_OfflineSync_Service.syncAll(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(5, result.totalProcessed, 'Should process 3 visits + 2 orders');
        System.assertEquals(5, result.successCount);
        System.assertEquals(0, result.errorCount);
        System.assertEquals(0, result.errors.size());
    }

    @isTest
    static void testSyncVisitsEmpty() {
        // Delete all offline visits
        delete [SELECT Id FROM Visit__c WHERE Offline_Created__c = true];

        Test.startTest();
        DFO_OfflineSync_Service.SyncResult result = DFO_OfflineSync_Service.syncVisits(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(0, result.totalProcessed);
    }

    @isTest
    static void testSyncOrdersEmpty() {
        delete [SELECT Id FROM Sales_Order__c WHERE Offline_Created__c = true];

        Test.startTest();
        DFO_OfflineSync_Service.SyncResult result = DFO_OfflineSync_Service.syncOrders(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(0, result.totalProcessed);
    }

    @isTest
    static void testSyncVisitsAlreadySynced() {
        // Mark all as already synced
        List<Visit__c> visits = [SELECT Id, Is_Synced__c FROM Visit__c WHERE Offline_Created__c = true];
        for (Visit__c v : visits) {
            v.Is_Synced__c = true;
        }
        update visits;

        Test.startTest();
        DFO_OfflineSync_Service.SyncResult result = DFO_OfflineSync_Service.syncVisits(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(0, result.totalProcessed, 'Already synced visits should not be processed');
    }
}