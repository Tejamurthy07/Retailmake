@IsTest
private class TAM_IncentiveSlabManager_Controller_Test {

    @TestSetup
    static void setupData() {
        // Create Target Criteria
        Target_Criteria__c criteria = TestDataFactory.createTargetCriteria(
            'Sales Revenue', 'Sales_Order__c', 'SUM', 'Total_Net_Amount__c',
            'Order_Date__c', 'Salesperson__c'
        );
        insert criteria;

        // Create Territory
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory(
            'Slab Territory', 'SLT-001'
        );

        // Create Incentive Slabs
        List<Incentive_Slab__c> slabs = new List<Incentive_Slab__c>{
            new Incentive_Slab__c(
                Name = 'Bronze Slab',
                Target_Criteria__c = criteria.Id,
                Min_Percent__c = 70,
                Max_Percent__c = 85,
                Payout_Type__c = 'Percentage',
                Payout_Value__c = 3,
                Multiplier__c = 1.0,
                Is_Active__c = true,
                Sort_Order__c = 1,
                Description__c = 'Bronze tier incentive',
                Territory__c = territory.Id
            ),
            new Incentive_Slab__c(
                Name = 'Silver Slab',
                Target_Criteria__c = criteria.Id,
                Min_Percent__c = 85,
                Max_Percent__c = 100,
                Payout_Type__c = 'Percentage',
                Payout_Value__c = 5,
                Multiplier__c = 1.0,
                Is_Active__c = true,
                Sort_Order__c = 2,
                Description__c = 'Silver tier incentive',
                Territory__c = territory.Id
            ),
            new Incentive_Slab__c(
                Name = 'Gold Slab',
                Target_Criteria__c = criteria.Id,
                Min_Percent__c = 100,
                Max_Percent__c = 150,
                Payout_Type__c = 'Fixed Amount',
                Payout_Value__c = 10000,
                Multiplier__c = 1.5,
                Is_Active__c = true,
                Sort_Order__c = 3,
                Description__c = 'Gold tier incentive',
                Territory__c = territory.Id
            )
        };
        insert slabs;
    }

    // ── getDashboardData ────────────────────────────────────────────

    @IsTest
    static void testGetDashboardData_ReturnsCompleteData() {
        Test.startTest();
        Map<String, Object> result = TAM_IncentiveSlabManager_Controller.getDashboardData();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.containsKey('slabs'), 'Should contain slabs key');
        System.assert(result.containsKey('criteriaOptions'), 'Should contain criteriaOptions key');
        System.assert(result.containsKey('profileOptions'), 'Should contain profileOptions key');
        System.assert(result.containsKey('territoryOptions'), 'Should contain territoryOptions key');

        List<Incentive_Slab__c> slabs = (List<Incentive_Slab__c>) result.get('slabs');
        System.assert(slabs.size() >= 3, 'Should return at least 3 slabs');
    }

    @IsTest
    static void testGetDashboardData_CriteriaOptionsIncludeAll() {
        Map<String, Object> result = TAM_IncentiveSlabManager_Controller.getDashboardData();
        List<Map<String, String>> criteriaOpts = (List<Map<String, String>>) result.get('criteriaOptions');

        System.assert(criteriaOpts.size() >= 2, 'Should have All option plus at least 1 criteria');
        System.assertEquals('-- Universal (All Criteria) --', criteriaOpts[0].get('label'),
            'First option should be All');
    }

    @IsTest
    static void testGetDashboardData_TerritoryOptions() {
        Map<String, Object> result = TAM_IncentiveSlabManager_Controller.getDashboardData();
        List<Map<String, String>> territoryOpts = (List<Map<String, String>>) result.get('territoryOptions');

        System.assert(territoryOpts.size() >= 2, 'Should have All option plus at least 1 territory');
        System.assertEquals('-- Universal (All Territories) --', territoryOpts[0].get('label'),
            'First option should be All');
    }

    // ── getSlabDetail ───────────────────────────────────────────────

    @IsTest
    static void testGetSlabDetail_ReturnsRecord() {
        Incentive_Slab__c slab = [SELECT Id FROM Incentive_Slab__c WHERE Name = 'Bronze Slab' LIMIT 1];

        Test.startTest();
        Incentive_Slab__c result = TAM_IncentiveSlabManager_Controller.getSlabDetail(slab.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Slab detail should not be null');
        System.assertEquals(slab.Id, result.Id, 'Should return correct slab');
        System.assertEquals(70, result.Min_Percent__c, 'Min percent should be 70');
        System.assertEquals(85, result.Max_Percent__c, 'Max percent should be 85');
        System.assertEquals('Percentage', result.Payout_Type__c, 'Payout type should be Percentage');
    }

    // ── saveSlab ────────────────────────────────────────────────────

    @IsTest
    static void testSaveSlab_InsertNew() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];

        Incentive_Slab__c newSlab = new Incentive_Slab__c(
            Name = 'Platinum Slab',
            Target_Criteria__c = criteria.Id,
            Min_Percent__c = 150,
            Max_Percent__c = 200,
            Payout_Type__c = 'Fixed Amount',
            Payout_Value__c = 25000,
            Multiplier__c = 2.0,
            Is_Active__c = true,
            Sort_Order__c = 4,
            Description__c = 'Platinum tier incentive'
        );

        Test.startTest();
        Incentive_Slab__c result = TAM_IncentiveSlabManager_Controller.saveSlab(newSlab);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertNotEquals(null, result.Id, 'Should have an Id');
        System.assertEquals('Platinum Slab', result.Name, 'Name should match');
    }

    @IsTest
    static void testSaveSlab_UpdateExisting() {
        Incentive_Slab__c existing = [SELECT Id, Name, Payout_Value__c FROM Incentive_Slab__c
            WHERE Name = 'Silver Slab' LIMIT 1];
        existing.Payout_Value__c = 7;
        existing.Description__c = 'Updated Silver tier';

        Test.startTest();
        Incentive_Slab__c result = TAM_IncentiveSlabManager_Controller.saveSlab(existing);
        Test.stopTest();

        System.assertEquals(existing.Id, result.Id, 'Should update existing record');
        System.assertEquals(7, result.Payout_Value__c, 'Payout value should be updated');
    }

    // ── deleteSlab ──────────────────────────────────────────────────

    @IsTest
    static void testDeleteSlab_Success() {
        Incentive_Slab__c toDelete = [SELECT Id FROM Incentive_Slab__c WHERE Name = 'Bronze Slab' LIMIT 1];
        Integer countBefore = [SELECT COUNT() FROM Incentive_Slab__c];

        Test.startTest();
        TAM_IncentiveSlabManager_Controller.deleteSlab(toDelete.Id);
        Test.stopTest();

        Integer countAfter = [SELECT COUNT() FROM Incentive_Slab__c];
        System.assertEquals(countBefore - 1, countAfter, 'One slab should be deleted');
    }

    // ── toggleActive ────────────────────────────────────────────────

    @IsTest
    static void testToggleActive_Deactivate() {
        Incentive_Slab__c slab = [SELECT Id FROM Incentive_Slab__c WHERE Name = 'Silver Slab' LIMIT 1];

        Test.startTest();
        TAM_IncentiveSlabManager_Controller.toggleActive(slab.Id, false);
        Test.stopTest();

        Incentive_Slab__c updated = [SELECT Is_Active__c FROM Incentive_Slab__c WHERE Id = :slab.Id];
        System.assertEquals(false, updated.Is_Active__c, 'Slab should be deactivated');
    }

    @IsTest
    static void testToggleActive_Activate() {
        Incentive_Slab__c slab = [SELECT Id FROM Incentive_Slab__c WHERE Name = 'Silver Slab' LIMIT 1];
        slab.Is_Active__c = false;
        update slab;

        Test.startTest();
        TAM_IncentiveSlabManager_Controller.toggleActive(slab.Id, true);
        Test.stopTest();

        Incentive_Slab__c updated = [SELECT Is_Active__c FROM Incentive_Slab__c WHERE Id = :slab.Id];
        System.assertEquals(true, updated.Is_Active__c, 'Slab should be activated');
    }

    // ── cloneSlab ───────────────────────────────────────────────────

    @IsTest
    static void testCloneSlab_CreatesClone() {
        Incentive_Slab__c original = [SELECT Id, Name FROM Incentive_Slab__c WHERE Name = 'Gold Slab' LIMIT 1];
        Integer countBefore = [SELECT COUNT() FROM Incentive_Slab__c];

        Test.startTest();
        Incentive_Slab__c cloned = TAM_IncentiveSlabManager_Controller.cloneSlab(original.Id);
        Test.stopTest();

        Integer countAfter = [SELECT COUNT() FROM Incentive_Slab__c];
        System.assertEquals(countBefore + 1, countAfter, 'Should have one more slab');
        System.assertNotEquals(original.Id, cloned.Id, 'Clone should have a different Id');
        System.assertEquals('Gold Slab (Copy)', cloned.Name, 'Clone name should have (Copy) suffix');
        System.assertEquals(false, cloned.Is_Active__c, 'Clone should be inactive by default');
    }

    // ── bulkToggleActive ────────────────────────────────────────────

    @IsTest
    static void testBulkToggleActive_DeactivateMultiple() {
        List<Incentive_Slab__c> slabs = [SELECT Id FROM Incentive_Slab__c WHERE Is_Active__c = true LIMIT 3];
        List<Id> slabIds = new List<Id>();
        for (Incentive_Slab__c s : slabs) slabIds.add(s.Id);

        Test.startTest();
        TAM_IncentiveSlabManager_Controller.bulkToggleActive(slabIds, false);
        Test.stopTest();

        List<Incentive_Slab__c> updated = [SELECT Is_Active__c FROM Incentive_Slab__c WHERE Id IN :slabIds];
        for (Incentive_Slab__c s : updated) {
            System.assertEquals(false, s.Is_Active__c, 'All slabs should be deactivated');
        }
    }

    @IsTest
    static void testBulkToggleActive_EmptyList() {
        Test.startTest();
        TAM_IncentiveSlabManager_Controller.bulkToggleActive(new List<Id>(), true);
        Test.stopTest();
        // Should not throw for empty list
    }

    // ── bulkDelete ──────────────────────────────────────────────────

    @IsTest
    static void testBulkDelete_DeleteMultiple() {
        List<Incentive_Slab__c> slabs = [SELECT Id FROM Incentive_Slab__c LIMIT 2];
        List<Id> slabIds = new List<Id>();
        for (Incentive_Slab__c s : slabs) slabIds.add(s.Id);
        Integer countBefore = [SELECT COUNT() FROM Incentive_Slab__c];

        Test.startTest();
        TAM_IncentiveSlabManager_Controller.bulkDelete(slabIds);
        Test.stopTest();

        Integer countAfter = [SELECT COUNT() FROM Incentive_Slab__c];
        System.assertEquals(countBefore - 2, countAfter, 'Two slabs should be deleted');
    }

    @IsTest
    static void testBulkDelete_EmptyList() {
        Integer countBefore = [SELECT COUNT() FROM Incentive_Slab__c];

        Test.startTest();
        TAM_IncentiveSlabManager_Controller.bulkDelete(new List<Id>());
        Test.stopTest();

        Integer countAfter = [SELECT COUNT() FROM Incentive_Slab__c];
        System.assertEquals(countBefore, countAfter, 'No slabs should be deleted');
    }
}