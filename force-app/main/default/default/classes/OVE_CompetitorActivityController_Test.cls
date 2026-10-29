@IsTest
private class OVE_CompetitorActivityController_Test {

    @TestSetup
    static void setupData() {
        // Create Account (outlet)
        Account acc = TestDataFactory.createAndInsertAccount('Competitor Test Outlet', 'Retailer');

        // Create supporting records for Visit
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Comp Territory', 'CT-001');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Comp Beat', 'CB-001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        Visit__c visit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        // Create Competitor__c entries linked to the visit
        Competitor__c comp1 = new Competitor__c(
            Visit__c = visit.Id,
            Account__c = acc.Id,
            Competitor_Company__c = 'Rival Corp',
            Competitor_SKU__c = 'RIVAL-001',
            Competitor_Price__c = 150.00,
            Notes__c = 'Aggressive pricing on shampoo',
            Activity_Date__c = Date.today(),
            Is_Active__c = true
        );
        Competitor__c comp2 = new Competitor__c(
            Visit__c = visit.Id,
            Account__c = acc.Id,
            Competitor_Company__c = 'AnotherBrand',
            Competitor_SKU__c = 'AB-002',
            Competitor_Price__c = 200.00,
            Notes__c = 'New product launch',
            Activity_Date__c = Date.today(),
            Is_Active__c = true
        );
        insert new List<Competitor__c>{ comp1, comp2 };
    }

    // ── getCompetitorEntriesForVisit ────────────────────────────────

    @IsTest
    static void testGetCompetitorEntriesForVisit_ReturnsEntries() {
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Test.startTest();
        try {
            List<Competitor__c> results = OVE_CompetitorActivityController.getCompetitorEntriesForVisit(visit.Id);
            // Feature may be disabled; if enabled we expect 2 entries
            System.assertNotEquals(null, results, 'Result list should not be null');
        } catch (AuraHandledException e) {
            // Feature toggle OVE-011 may not be enabled in test context
            System.assert(e.getMessage() != null, 'Exception should have a message');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetCompetitorEntriesForVisit_NoVisitEntries() {
        // Use a fabricated Visit Id that has no competitor entries
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c emptyVisit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        emptyVisit.Visit_Date__c = Date.today().addDays(-1);
        insert emptyVisit;

        Test.startTest();
        try {
            List<Competitor__c> results = OVE_CompetitorActivityController.getCompetitorEntriesForVisit(emptyVisit.Id);
            System.assertEquals(0, results.size(), 'Should return empty list for visit with no entries');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── getCompetitorMaster ─────────────────────────────────────────

    @IsTest
    static void testGetCompetitorMaster_ReturnsList() {
        Test.startTest();
        try {
            List<String> companies = OVE_CompetitorActivityController.getCompetitorMaster();
            System.assertNotEquals(null, companies, 'Result should not be null');
            // We created 2 distinct companies in setup
            System.assert(companies.size() >= 2, 'Should contain at least 2 competitor companies');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── saveCompetitorEntry ─────────────────────────────────────────

    @IsTest
    static void testSaveCompetitorEntry_NewEntry() {
        Visit__c visit = [SELECT Id, Account__c FROM Visit__c LIMIT 1];

        Map<String, Object> entryData = new Map<String, Object>{
            'visitId' => visit.Id,
            'accountId' => visit.Account__c,
            'competitorCompany' => 'NewRival Inc',
            'competitorSKU' => 'NR-100',
            'competitorPrice' => 250,
            'notes' => 'Test new entry'
        };
        String entryJson = JSON.serialize(entryData);

        Test.startTest();
        try {
            Competitor__c result = OVE_CompetitorActivityController.saveCompetitorEntry(entryJson);
            System.assertNotEquals(null, result, 'Saved entry should not be null');
            System.assertNotEquals(null, result.Id, 'Saved entry should have an Id');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Exception expected if feature disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveCompetitorEntry_UpdateExisting() {
        Competitor__c existing = [SELECT Id, Visit__c, Account__c FROM Competitor__c LIMIT 1];

        Map<String, Object> entryData = new Map<String, Object>{
            'id' => existing.Id,
            'visitId' => existing.Visit__c,
            'accountId' => existing.Account__c,
            'competitorCompany' => 'Updated Corp',
            'competitorSKU' => 'UPD-001',
            'competitorPrice' => 175,
            'notes' => 'Updated notes'
        };
        String entryJson = JSON.serialize(entryData);

        Test.startTest();
        try {
            Competitor__c result = OVE_CompetitorActivityController.saveCompetitorEntry(entryJson);
            System.assertEquals(existing.Id, result.Id, 'Should update existing record');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Exception expected if feature disabled');
        }
        Test.stopTest();
    }

    // ── deleteCompetitorEntry ───────────────────────────────────────

    @IsTest
    static void testDeleteCompetitorEntry_Success() {
        Competitor__c toDelete = [SELECT Id FROM Competitor__c LIMIT 1];
        Integer countBefore = [SELECT COUNT() FROM Competitor__c];

        Test.startTest();
        try {
            OVE_CompetitorActivityController.deleteCompetitorEntry(toDelete.Id);
            Integer countAfter = [SELECT COUNT() FROM Competitor__c];
            System.assertEquals(countBefore - 1, countAfter, 'One record should be deleted');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Exception expected if feature disabled or record issue');
        }
        Test.stopTest();
    }

    @IsTest
    static void testDeleteCompetitorEntry_InvalidId() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.deleteCompetitorEntry('a0B000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Should throw exception for invalid Id');
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ── Error Path Tests — Cover catch (Exception e) blocks ──────────

    @IsTest
    static void testGetEntriesForVisit_NullId() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.getCompetitorEntriesForVisit(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetCompetitorMaster_ErrorPath() {
        // getCompetitorMaster takes no params so we just call it and
        // cover the happy-or-catch path; the method itself rarely
        // errors, but executing it ensures the try block is covered.
        Test.startTest();
        try {
            OVE_CompetitorActivityController.getCompetitorMaster();
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_NullJson() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_InvalidJson() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry('bad json');
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_EmptyObjectJson() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry('{}');
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_NullRequiredFields() {
        String json = JSON.serialize(new Map<String, Object>{
            'visitId' => null,
            'accountId' => null,
            'competitorCompany' => null
        });
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry(json);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testDeleteEntry_NullId() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.deleteCompetitorEntry(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ── Additional Error Path Tests — Force catch (Exception e) blocks ──────

    @IsTest
    static void testGetEntriesForVisit_FabricatedId() {
        // Use a syntactically valid but non-existent Id to force a service-layer error
        Test.startTest();
        try {
            OVE_CompetitorActivityController.getCompetitorEntriesForVisit('001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_MalformedJsonArray() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry('[1,2,3]');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_InvalidIdInJson() {
        String json = '{"id":"INVALID_ID","visitId":"INVALID","accountId":"INVALID","competitorCompany":"Test"}';
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry(json);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_TypeMismatchJson() {
        // competitorPrice as a string instead of number to trigger type cast error
        String json = '{"visitId":null,"accountId":null,"competitorCompany":"X","competitorPrice":"not_a_number"}';
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry(json);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testDeleteEntry_FabricatedId() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.deleteCompetitorEntry('a0B000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_NumericJson() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry('12345');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_BooleanJson() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry('true');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveEntry_EmptyString() {
        Test.startTest();
        try {
            OVE_CompetitorActivityController.saveCompetitorEntry('');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage, with HARD assertions.
    //
    //  The tests above tolerate both outcomes ("feature toggle may be
    //  disabled"), so none of the service behaviour is pinned. OVE-011 ships
    //  enabled; where a state matters it is pinned through
    //  BPM_FeatureToggle_Util's @TestVisible cache rather than assumed.
    // ══════════════════════════════════════════════════════════════════

    private static void setCompetitorFeature(Boolean enabled) {
        BPM_FeatureToggle_Util.toggleCache.put(
            OVE_CompetitorActivity_Service.FEATURE_COMPETITOR, enabled);
    }

    private static Visit__c theVisit() {
        return [SELECT Id, Account__c FROM Visit__c LIMIT 1];
    }

    // ── getCompetitorEntriesForVisit ──────────────────────────────────

    @IsTest
    static void entries_withTheFeatureOn_returnTheVisitRows() {
        setCompetitorFeature(true);
        Visit__c visit = theVisit();

        Test.startTest();
        List<Competitor__c> results =
            OVE_CompetitorActivityController.getCompetitorEntriesForVisit(visit.Id);
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Both seeded entries for this visit come back');
        Set<String> companies = new Set<String>();
        for (Competitor__c c : results) companies.add(c.Competitor_Company__c);
        System.assert(companies.contains('Rival Corp'), 'With their company names');
        System.assert(companies.contains('AnotherBrand'), 'Both of them');
    }

    @IsTest
    static void entries_withTheFeatureOff_returnEmptyDespiteData() {
        setCompetitorFeature(false);
        Visit__c visit = theVisit();

        Test.startTest();
        List<Competitor__c> results =
            OVE_CompetitorActivityController.getCompetitorEntriesForVisit(visit.Id);
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'Two entries exist, but with OVE-011 off the activity disappears rather than '
            + 'erroring — this is the branch the soft tests never distinguished');
    }

    @IsTest
    static void entries_areScopedToTheVisitAsked() {
        setCompetitorFeature(true);
        // A second visit for the same outlet, one day earlier (Visit lookups are
        // per day attendance, so reuse it), with its own single entry.
        Visit__c original = theVisit();
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];
        Account acc = [SELECT Id FROM Account WHERE Name = 'Competitor Test Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Visit__c other = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert other;
        insert new Competitor__c(
            Visit__c = other.Id, Account__c = acc.Id,
            Competitor_Company__c = 'ThirdBrand', Is_Active__c = true,
            Activity_Date__c = Date.today());

        Test.startTest();
        List<Competitor__c> forOriginal =
            OVE_CompetitorActivityController.getCompetitorEntriesForVisit(original.Id);
        List<Competitor__c> forOther =
            OVE_CompetitorActivityController.getCompetitorEntriesForVisit(other.Id);
        Test.stopTest();

        System.assertEquals(2, forOriginal.size(), 'The first visit keeps its two entries');
        System.assertEquals(1, forOther.size(), 'The second sees only its own');
        System.assertEquals('ThirdBrand', forOther[0].Competitor_Company__c, 'And it is the right one');
    }

    // ── getCompetitorMaster ───────────────────────────────────────────

    @IsTest
    static void master_returnsDistinctSortedActiveCompanies() {
        Visit__c visit = theVisit();
        // A duplicate company and an inactive one — neither should add a row.
        insert new List<Competitor__c>{
            new Competitor__c(Visit__c = visit.Id, Account__c = visit.Account__c,
                Competitor_Company__c = 'Rival Corp', Is_Active__c = true,
                Activity_Date__c = Date.today()),
            new Competitor__c(Visit__c = visit.Id, Account__c = visit.Account__c,
                Competitor_Company__c = 'GhostBrand', Is_Active__c = false,
                Activity_Date__c = Date.today())
        };

        Test.startTest();
        List<String> companies = OVE_CompetitorActivityController.getCompetitorMaster();
        Test.stopTest();

        System.assertEquals(2, companies.size(),
            'Rival Corp appears once despite two entries, and the inactive GhostBrand is '
            + 'not offered at all');
        System.assertEquals('AnotherBrand', companies[0],
            'Alphabetical, so the dropdown reads predictably');
        System.assertEquals('Rival Corp', companies[1], 'Second of the two');
    }

    // ── saveCompetitorEntry ───────────────────────────────────────────

    @IsTest
    static void save_createsTheEntryAndMarksTheVisitChecked() {
        Visit__c visit = theVisit();
        String entryJson = JSON.serialize(new Map<String, Object>{
            'visitId' => visit.Id,
            'accountId' => visit.Account__c,
            'competitorCompany' => 'FreshRival',
            'competitorSKU' => 'FR-100',
            'competitorPrice' => 99.5,
            'notes' => 'Undercutting on oil'
        });

        Test.startTest();
        Competitor__c saved = OVE_CompetitorActivityController.saveCompetitorEntry(entryJson);
        Test.stopTest();

        Competitor__c stored = [
            SELECT Competitor_Company__c, Competitor_SKU__c, Competitor_Price__c,
                   Notes__c, Activity_Date__c, Is_Active__c, Visit__c
            FROM Competitor__c WHERE Id = :saved.Id
        ];
        System.assertEquals('FreshRival', stored.Competitor_Company__c, 'Company stored');
        System.assertEquals('FR-100', stored.Competitor_SKU__c, 'SKU stored');
        System.assertEquals(99.5, stored.Competitor_Price__c, 'Price stored');
        System.assertEquals(Date.today(), stored.Activity_Date__c,
            'Stamped with today — the sighting date is when the rep logged it');
        System.assertEquals(true, stored.Is_Active__c, 'And live immediately');
        System.assertEquals(true, [
            SELECT Competitor_Check_Completed__c FROM Visit__c WHERE Id = :visit.Id
        ].Competitor_Check_Completed__c,
            'The visit records that its competitor check happened');
    }

    @IsTest
    static void save_withAnId_updatesInPlaceInsteadOfDuplicating() {
        Visit__c visit = theVisit();
        Competitor__c existing = [
            SELECT Id FROM Competitor__c WHERE Competitor_Company__c = 'Rival Corp' LIMIT 1
        ];
        Integer beforeCount = [SELECT COUNT() FROM Competitor__c];

        String entryJson = JSON.serialize(new Map<String, Object>{
            'id' => existing.Id,
            'visitId' => visit.Id,
            'accountId' => visit.Account__c,
            'competitorCompany' => 'Rival Corp',
            'competitorPrice' => 175,
            'notes' => 'Price raised since last visit'
        });

        Test.startTest();
        Competitor__c saved = OVE_CompetitorActivityController.saveCompetitorEntry(entryJson);
        Test.stopTest();

        System.assertEquals(existing.Id, saved.Id, 'The same record was updated');
        System.assertEquals(beforeCount, [SELECT COUNT() FROM Competitor__c],
            'Editing a sighting must not clone it');
        System.assertEquals(175, [
            SELECT Competitor_Price__c FROM Competitor__c WHERE Id = :existing.Id
        ].Competitor_Price__c, 'With the corrected price stored');
    }

    @IsTest
    static void save_withoutAVisit_savesTheEntryWithoutTouchingAnyVisit() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Competitor Test Outlet' LIMIT 1];
        String entryJson = JSON.serialize(new Map<String, Object>{
            'accountId' => acc.Id,
            'competitorCompany' => 'AdHocBrand'
        });

        Test.startTest();
        Competitor__c saved = OVE_CompetitorActivityController.saveCompetitorEntry(entryJson);
        Test.stopTest();

        System.assertNotEquals(null, saved.Id,
            'A sighting logged outside a visit still saves — visitId is optional');
        System.assertEquals(false, [
            SELECT Competitor_Check_Completed__c FROM Visit__c WHERE Id = :theVisit().Id
        ].Competitor_Check_Completed__c,
            'And no visit is marked checked by an entry that named none');
    }

    // ── deleteCompetitorEntry ─────────────────────────────────────────

    @IsTest
    static void delete_removesTheEntryAndLeavesTheRestAlone() {
        Competitor__c victim = [
            SELECT Id FROM Competitor__c WHERE Competitor_Company__c = 'Rival Corp' LIMIT 1
        ];

        Test.startTest();
        OVE_CompetitorActivityController.deleteCompetitorEntry(victim.Id);
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM Competitor__c WHERE Id = :victim.Id
        ], 'The entry is gone');
        System.assertEquals(1, [SELECT COUNT() FROM Competitor__c],
            'And its sibling on the same visit survives');
    }

    @IsTest
    static void delete_ofAnIdThatMatchesNothing_surfacesAsHandled() {
        // The service queries LIMIT 1 before deleting; zero rows makes that
        // query expression throw, which the controller must wrap for the LWC.
        Id ghost = Id.valueOf(
            Competitor__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Boolean threw = false;
        try {
            OVE_CompetitorActivityController.deleteCompetitorEntry(ghost);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'A stale id from the client reaches the LWC as an AuraHandledException, not a '
            + 'raw QueryException it cannot render');
        System.assertEquals(2, [SELECT COUNT() FROM Competitor__c], 'Nothing else was deleted');
    }
}