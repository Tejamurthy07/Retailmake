/**
 * @description Test class for BPM_BeatOutlet_TriggerHandler.
 *              Validates automatic Total_Outlets__c rollup on parent Beat__c.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class BPM_BeatOutlet_TriggerHandler_Test {

    @testSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('BO Test Territory', 'TER-BO01');
        Beat__c beat = TestDataFactory.createBeat('Outlet Beat', 'BEAT-OT01', territory.Id);
        beat.Day_of_Week__c = 'Monday';
        insert beat;

        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accounts.add(TestDataFactory.createAccount('Outlet ' + i, 'Retailer'));
        }
        insert accounts;
    }

    @isTest
    static void testOutletCountOnInsert() {
        Beat__c beat = [SELECT Id FROM Beat__c WHERE Beat_Code__c = 'BEAT-OT01' LIMIT 1];
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name LIMIT 5];

        Test.startTest();
        List<Beat_Outlet__c> outlets = new List<Beat_Outlet__c>();
        for (Account acct : accounts) {
            outlets.add(TestDataFactory.createBeatOutlet(beat.Id, acct.Id));
        }
        insert outlets;
        Test.stopTest();

        Beat__c updated = [SELECT Total_Outlets__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals(5, updated.Total_Outlets__c, 'Total_Outlets__c should be 5 after inserting 5 outlets');
    }

    @isTest
    static void testOutletCountOnDeactivate() {
        Beat__c beat = [SELECT Id FROM Beat__c WHERE Beat_Code__c = 'BEAT-OT01' LIMIT 1];
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name LIMIT 3];

        List<Beat_Outlet__c> outlets = new List<Beat_Outlet__c>();
        for (Account acct : accounts) {
            outlets.add(TestDataFactory.createBeatOutlet(beat.Id, acct.Id));
        }
        insert outlets;

        Test.startTest();
        outlets[0].Is_Active__c = false;
        update outlets[0];
        Test.stopTest();

        Beat__c updated = [SELECT Total_Outlets__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals(2, updated.Total_Outlets__c, 'Total_Outlets__c should be 2 after deactivating 1 outlet');
    }

    @isTest
    static void testOutletCountOnDelete() {
        Beat__c beat = [SELECT Id FROM Beat__c WHERE Beat_Code__c = 'BEAT-OT01' LIMIT 1];
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name LIMIT 3];

        List<Beat_Outlet__c> outlets = new List<Beat_Outlet__c>();
        for (Account acct : accounts) {
            outlets.add(TestDataFactory.createBeatOutlet(beat.Id, acct.Id));
        }
        insert outlets;

        Test.startTest();
        delete outlets[0];
        Test.stopTest();

        Beat__c updated = [SELECT Total_Outlets__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals(2, updated.Total_Outlets__c, 'Total_Outlets__c should be 2 after deleting 1 outlet');
    }
}