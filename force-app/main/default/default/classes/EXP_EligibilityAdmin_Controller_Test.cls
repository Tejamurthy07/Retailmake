@IsTest
private class EXP_EligibilityAdmin_Controller_Test {

    @TestSetup
    static void setupData() {
        // Create expense eligibility rules
        Expense_Eligibility__c rule1 = new Expense_Eligibility__c(
            Band__c = 'Band 1',
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per Day',
            Rate_Amount__c = 500,
            Max_Per_Day__c = 500,
            Max_Per_Month__c = 15000,
            Receipt_Required__c = false,
            Receipt_Threshold__c = null,
            Is_Active__c = true,
            Sort_Order__c = 1,
            Description__c = 'Band 1 Daily Allowance',
            Travel_Type__c = 'HQ',
            Mandatory_Remarks__c = false,
            Daily_KM_Limit__c = 100
        );

        Expense_Eligibility__c rule2 = new Expense_Eligibility__c(
            Band__c = 'Band 2',
            Expense_Type__c = 'Travelling Allowance',
            Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per KM',
            Rate_Amount__c = 8,
            Max_Per_Day__c = 1000,
            Max_Per_Month__c = 25000,
            Receipt_Required__c = true,
            Receipt_Threshold__c = 500,
            Is_Active__c = true,
            Sort_Order__c = 2,
            Description__c = 'Band 2 Travel',
            Travel_Type__c = 'EX-HQ',
            Mandatory_Remarks__c = true,
            Daily_KM_Limit__c = 200
        );

        insert new List<Expense_Eligibility__c>{ rule1, rule2 };

        // Create rate slabs for rule2
        List<Expense_Rate_Slab__c> slabs = new List<Expense_Rate_Slab__c>();
        slabs.add(new Expense_Rate_Slab__c(
            Expense_Eligibility__c = rule2.Id,
            Travel_Mode__c = 'Two Wheeler',
            Rate_Type__c = 'Per KM',
            Rate_Amount__c = 5,
            Max_Amount__c = 500,
            Distance_From__c = 0,
            Distance_To__c = 50,
            Sort_Order__c = 1
        ));
        slabs.add(new Expense_Rate_Slab__c(
            Expense_Eligibility__c = rule2.Id,
            Travel_Mode__c = 'Four Wheeler',
            Rate_Type__c = 'Per KM',
            Rate_Amount__c = 12,
            Max_Amount__c = 1500,
            Distance_From__c = 0,
            Distance_To__c = 100,
            Sort_Order__c = 2
        ));
        insert slabs;

        // Create city tiers
        City_Tier__c tier1 = new City_Tier__c(
            Name = 'Mumbai',
            Tier__c = 'Tier 1',
            State__c = 'Maharashtra',
            Is_Active__c = true
        );
        City_Tier__c tier2 = new City_Tier__c(
            Name = 'Pune',
            Tier__c = 'Tier 2',
            State__c = 'Maharashtra',
            Is_Active__c = true
        );
        insert new List<City_Tier__c>{ tier1, tier2 };
    }

    // ── getAdminData ────────────────────────────────────────────────

    @IsTest
    static void testGetAdminData() {
        Test.startTest();
        Map<String, Object> data = EXP_EligibilityAdmin_Controller.getAdminData();
        Test.stopTest();

        System.assert(data.containsKey('rules'), 'Should contain rules');
        System.assert(data.containsKey('cityTiers'), 'Should contain cityTiers');

        List<Expense_Eligibility__c> rules = (List<Expense_Eligibility__c>) data.get('rules');
        System.assert(rules.size() >= 2, 'Should return at least 2 rules');

        List<City_Tier__c> tiers = (List<City_Tier__c>) data.get('cityTiers');
        System.assert(tiers.size() >= 2, 'Should return at least 2 city tiers');
    }

    // ── refreshAdminData ────────────────────────────────────────────

    @IsTest
    static void testRefreshAdminData() {
        Test.startTest();
        Map<String, Object> data = EXP_EligibilityAdmin_Controller.refreshAdminData();
        Test.stopTest();

        System.assert(data.containsKey('rules'), 'Refresh should return rules');
        System.assert(data.containsKey('cityTiers'), 'Refresh should return cityTiers');
    }

    // ── saveEligibilityRule (insert) ────────────────────────────────

    @IsTest
    static void testSaveEligibilityRule_New() {
        Expense_Eligibility__c newRule = new Expense_Eligibility__c(
            Band__c = 'Band 3',
            Expense_Type__c = 'Lodging',
            Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per Day',
            Rate_Amount__c = 2000,
            Max_Per_Day__c = 2000,
            Max_Per_Month__c = 30000,
            Receipt_Required__c = true,
            Is_Active__c = true,
            Sort_Order__c = 3
        );

        Test.startTest();
        Expense_Eligibility__c result = EXP_EligibilityAdmin_Controller.saveEligibilityRule(newRule);
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Should have an Id after save');
        System.assertEquals('Band 3', result.Band__c, 'Band should match');
    }

    // ── saveEligibilityRule (update) ────────────────────────────────

    @IsTest
    static void testSaveEligibilityRule_Update() {
        Expense_Eligibility__c rule = [SELECT Id, Rate_Amount__c FROM Expense_Eligibility__c
                                        WHERE Band__c = 'Band 1' LIMIT 1];
        rule.Rate_Amount__c = 600;

        Test.startTest();
        Expense_Eligibility__c result = EXP_EligibilityAdmin_Controller.saveEligibilityRule(rule);
        Test.stopTest();

        System.assertEquals(600, result.Rate_Amount__c, 'Rate should be updated');
    }

    // ── saveRateSlabs ───────────────────────────────────────────────

    @IsTest
    static void testSaveRateSlabs_UpsertAndDelete() {
        Expense_Eligibility__c rule = [SELECT Id FROM Expense_Eligibility__c WHERE Band__c = 'Band 2' LIMIT 1];
        List<Expense_Rate_Slab__c> existingSlabs = [
            SELECT Id FROM Expense_Rate_Slab__c WHERE Expense_Eligibility__c = :rule.Id
        ];

        // Get one slab to delete
        List<Id> toDelete = new List<Id>();
        if (!existingSlabs.isEmpty()) {
            toDelete.add(existingSlabs[0].Id);
        }

        // Create a new slab
        List<Expense_Rate_Slab__c> slabs = new List<Expense_Rate_Slab__c>();
        slabs.add(new Expense_Rate_Slab__c(
            Expense_Eligibility__c = rule.Id,
            Travel_Mode__c = 'Bus',
            Rate_Type__c = 'Per KM',
            Rate_Amount__c = 200,
            Max_Amount__c = 200,
            Distance_From__c = 0,
            Distance_To__c = 200,
            Sort_Order__c = 3
        ));

        Test.startTest();
        List<Expense_Rate_Slab__c> results = EXP_EligibilityAdmin_Controller.saveRateSlabs(
            rule.Id, slabs, toDelete
        );
        Test.stopTest();

        System.assertNotEquals(null, results, 'Should return updated slabs');
    }

    @IsTest
    static void testSaveRateSlabs_NewSlabWithoutParent() {
        Expense_Eligibility__c rule = [SELECT Id FROM Expense_Eligibility__c WHERE Band__c = 'Band 1' LIMIT 1];

        // Slab with no Expense_Eligibility__c set (should be auto-assigned)
        List<Expense_Rate_Slab__c> slabs = new List<Expense_Rate_Slab__c>();
        slabs.add(new Expense_Rate_Slab__c(
            Travel_Mode__c = 'Train',
            Rate_Type__c = 'Per KM',
            Rate_Amount__c = 300,
            Max_Amount__c = 300,
            Sort_Order__c = 1
        ));

        Test.startTest();
        List<Expense_Rate_Slab__c> results = EXP_EligibilityAdmin_Controller.saveRateSlabs(
            rule.Id, slabs, null
        );
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return at least 1 slab');
    }

    // ── deleteEligibilityRule ───────────────────────────────────────

    @IsTest
    static void testDeleteEligibilityRule() {
        Expense_Eligibility__c rule = [SELECT Id FROM Expense_Eligibility__c WHERE Band__c = 'Band 1' LIMIT 1];

        Test.startTest();
        EXP_EligibilityAdmin_Controller.deleteEligibilityRule(rule.Id);
        Test.stopTest();

        List<Expense_Eligibility__c> remaining = [SELECT Id FROM Expense_Eligibility__c WHERE Id = :rule.Id];
        System.assertEquals(0, remaining.size(), 'Rule should be deleted');
    }

    // ── cloneEligibilityRule ────────────────────────────────────────

    @IsTest
    static void testCloneEligibilityRule() {
        Expense_Eligibility__c source = [SELECT Id FROM Expense_Eligibility__c WHERE Band__c = 'Band 2' LIMIT 1];

        Test.startTest();
        Expense_Eligibility__c cloned = EXP_EligibilityAdmin_Controller.cloneEligibilityRule(
            source.Id, 'Band 4', 'EX-HQ'
        );
        Test.stopTest();

        System.assertNotEquals(null, cloned.Id, 'Cloned rule should have an Id');
        System.assertEquals('Band 4', cloned.Band__c, 'Clone should have new band');
        System.assertEquals(true, cloned.Is_Active__c, 'Clone should be active');

        // Verify child slabs were cloned
        List<Expense_Rate_Slab__c> clonedSlabs = [
            SELECT Id FROM Expense_Rate_Slab__c WHERE Expense_Eligibility__c = :cloned.Id
        ];
        System.assert(clonedSlabs.size() >= 2, 'Should clone at least 2 rate slabs');
    }

    @IsTest
    static void testCloneEligibilityRule_DefaultBandAndDuty() {
        Expense_Eligibility__c source = [SELECT Id, Band__c, Travel_Type__c FROM Expense_Eligibility__c
                                          WHERE Band__c = 'Band 1' LIMIT 1];

        Test.startTest();
        Expense_Eligibility__c cloned = EXP_EligibilityAdmin_Controller.cloneEligibilityRule(
            source.Id, null, null
        );
        Test.stopTest();

        System.assertEquals(source.Band__c, cloned.Band__c, 'Band should default to source band');
    }

    // ── saveCityTier ────────────────────────────────────────────────

    @IsTest
    static void testSaveCityTier_New() {
        City_Tier__c newTier = new City_Tier__c(
            Name = 'Nagpur',
            Tier__c = 'Tier 2',
            State__c = 'Maharashtra',
            Is_Active__c = true
        );

        Test.startTest();
        City_Tier__c result = EXP_EligibilityAdmin_Controller.saveCityTier(newTier);
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Should have an Id after save');
        System.assertEquals('Nagpur', result.Name, 'Name should match');
    }

    @IsTest
    static void testSaveCityTier_Update() {
        City_Tier__c tier = [SELECT Id, Tier__c FROM City_Tier__c WHERE Name = 'Pune' LIMIT 1];
        tier.Tier__c = 'Tier 1';

        Test.startTest();
        City_Tier__c result = EXP_EligibilityAdmin_Controller.saveCityTier(tier);
        Test.stopTest();

        System.assertEquals('Tier 1', result.Tier__c, 'Tier should be updated');
    }

    // ── deleteCityTier ──────────────────────────────────────────────

    @IsTest
    static void testDeleteCityTier() {
        City_Tier__c tier = [SELECT Id FROM City_Tier__c WHERE Name = 'Pune' LIMIT 1];

        Test.startTest();
        EXP_EligibilityAdmin_Controller.deleteCityTier(tier.Id);
        Test.stopTest();

        List<City_Tier__c> remaining = [SELECT Id FROM City_Tier__c WHERE Id = :tier.Id];
        System.assertEquals(0, remaining.size(), 'City tier should be deleted');
    }
}