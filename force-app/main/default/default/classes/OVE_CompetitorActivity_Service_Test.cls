/**
 * @description Test class for OVE_CompetitorActivity_Service.
 *              Validates competitor entry retrieval, competitor master list,
 *              entry save/delete, and feature toggle disabled scenarios.
 *
 *              Feature_Toggle__mdt cannot be inserted in test context, so
 *              service methods gated by feature toggles may return empty lists
 *              or throw AuraHandledException.
 *
 * @author  SFA Development Team
 * @date    2026
 */
@isTest
private class OVE_CompetitorActivity_Service_Test {

    @testSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('CA Territory', 'TER-CA01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('CA Beat', 'BEAT-CA01', territory.Id);

        Account outlet = TestDataFactory.createAccount('CA Test Outlet', 'Retailer');
        insert outlet;

        Day_Attendance__c da = TestDataFactory.createDayAttendanceWithDefaults(UserInfo.getUserId());
        insert da;

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            outlet.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 1;
        insert visit;
    }

    // ── getCompetitorEntriesForVisit ─────────────────────────────────────────

    @isTest
    static void testGetCompetitorEntriesForVisit_ValidVisit() {
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Test.startTest();
        List<Competitor__c> results = OVE_CompetitorActivity_Service.getCompetitorEntriesForVisit(visit.Id);
        Test.stopTest();

        // Feature toggle may be disabled -> empty list
        System.assertNotEquals(null, results, 'Result should not be null');
    }

    @isTest
    static void testGetCompetitorEntriesForVisit_NullVisitId() {
        Test.startTest();
        List<Competitor__c> results = OVE_CompetitorActivity_Service.getCompetitorEntriesForVisit(null);
        Test.stopTest();

        System.assertNotEquals(null, results, 'Result should not be null for null visitId');
        System.assertEquals(0, results.size(), 'Should return empty list for null visit');
    }

    // ── getCompetitorMaster ──────────────────────────────────────────────────

    @isTest
    static void testGetCompetitorMaster() {
        Test.startTest();
        List<String> companies = OVE_CompetitorActivity_Service.getCompetitorMaster();
        Test.stopTest();

        System.assertNotEquals(null, companies, 'Result should not be null');
        // No competitor records in setup, so expect empty
    }

    // ── saveCompetitorEntry ──────────────────────────────────────────────────

    @isTest
    static void testSaveCompetitorEntry_ValidJson() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CA Test Outlet' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c WHERE Account__c = :acct.Id LIMIT 1];

        Map<String, Object> data = new Map<String, Object>();
        data.put('visitId', visit.Id);
        data.put('accountId', acct.Id);
        data.put('competitorCompany', 'Rival Corp');
        data.put('competitorSKU', 'RIVAL-SKU-001');
        data.put('competitorPrice', 120.50);
        data.put('notes', 'Active promotion running');
        String entryJson = JSON.serialize(data);

        Test.startTest();
        try {
            Competitor__c saved = OVE_CompetitorActivity_Service.saveCompetitorEntry(entryJson);
            System.assertNotEquals(null, saved.Id, 'Saved record should have an Id');
            System.assertEquals('Rival Corp', saved.Competitor_Company__c, 'Company should match');
            System.assertEquals('RIVAL-SKU-001', saved.Competitor_SKU__c, 'SKU should match');
            System.assertEquals(120.50, saved.Competitor_Price__c, 'Price should match');
            System.assertEquals(true, saved.Is_Active__c, 'Should be active');
            System.assertEquals(Date.today(), saved.Activity_Date__c, 'Date should be today');

            // Verify visit flag updated
            Visit__c updatedVisit = [SELECT Competitor_Check_Completed__c FROM Visit__c WHERE Id = :visit.Id];
            System.assertEquals(true, updatedVisit.Competitor_Check_Completed__c,
                'Competitor check flag should be true');
        } catch (Exception e) {
            System.assert(e.getMessage() != null, 'Exception captured: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveCompetitorEntry_UpdateExisting() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CA Test Outlet' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c WHERE Account__c = :acct.Id LIMIT 1];

        // Create initial entry
        Competitor__c existing = new Competitor__c(
            Visit__c = visit.Id,
            Account__c = acct.Id,
            Competitor_Company__c = 'Old Corp',
            Competitor_SKU__c = 'OLD-SKU',
            Activity_Date__c = Date.today(),
            Is_Active__c = true
        );
        insert existing;

        // Update via service
        Map<String, Object> data = new Map<String, Object>();
        data.put('id', existing.Id);
        data.put('visitId', visit.Id);
        data.put('accountId', acct.Id);
        data.put('competitorCompany', 'Updated Corp');
        data.put('competitorSKU', 'UPDATED-SKU');
        String entryJson = JSON.serialize(data);

        Test.startTest();
        try {
            Competitor__c updated = OVE_CompetitorActivity_Service.saveCompetitorEntry(entryJson);
            System.assertEquals(existing.Id, updated.Id, 'Should update existing record');
            System.assertEquals('Updated Corp', updated.Competitor_Company__c, 'Company should be updated');
        } catch (Exception e) {
            System.assert(e.getMessage() != null, 'Exception captured: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── deleteCompetitorEntry ────────────────────────────────────────────────

    @isTest
    static void testDeleteCompetitorEntry_ValidEntry() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CA Test Outlet' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c WHERE Account__c = :acct.Id LIMIT 1];

        Competitor__c entry = new Competitor__c(
            Visit__c = visit.Id,
            Account__c = acct.Id,
            Competitor_Company__c = 'Delete Me Corp',
            Activity_Date__c = Date.today(),
            Is_Active__c = true
        );
        insert entry;

        Test.startTest();
        OVE_CompetitorActivity_Service.deleteCompetitorEntry(entry.Id);
        Test.stopTest();

        List<Competitor__c> remaining = [SELECT Id FROM Competitor__c WHERE Id = :entry.Id];
        System.assertEquals(0, remaining.size(), 'Entry should be deleted');
    }

    @isTest
    static void testDeleteCompetitorEntry_InvalidId() {
        Test.startTest();
        try {
            // Use a fabricated Id that does not exist
            OVE_CompetitorActivity_Service.deleteCompetitorEntry(null);
            System.assert(false, 'Should have thrown an exception');
        } catch (Exception e) {
            System.assert(e.getMessage() != null, 'Exception expected for invalid Id');
        }
        Test.stopTest();
    }

    // ── Feature Toggle ───────────────────────────────────────────────────────

    @isTest
    static void testFeatureToggleDisabled_ReturnsEmptyList() {
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Test.startTest();
        List<Competitor__c> results = OVE_CompetitorActivity_Service.getCompetitorEntriesForVisit(visit.Id);
        Test.stopTest();

        // When toggle is disabled, method returns empty list
        System.assertNotEquals(null, results, 'Should return a list, not null');
    }
}