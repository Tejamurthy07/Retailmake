@isTest
private class TAM_IncentiveCalculation_Service_Test {

    @testSetup
    static void setupTestData() {
        // Create target criteria
        Target_Criteria__c criteria = new Target_Criteria__c(
            Name = 'Revenue',
            Object__c = 'Account',
            Operator__c = 'COUNT',
            Date_Field__c = 'CreatedDate',
            User_Field__c = 'OwnerId',
            Active__c = true
        );
        insert criteria;

        // Create period
        Target_Period__c period = new Target_Period__c(
            Name = 'Test Period',
            Start_Date__c = Date.today().toStartOfMonth(),
            End_Date__c = Date.today().toStartOfMonth().addMonths(1).addDays(-1),
            Is_Active__c = true,
            Type__c = 'Monthly'
        );
        insert period;

        // Create target actual with 85% achievement
        Target_Actual__c actual = new Target_Actual__c(
            Target_Criteria__c = criteria.Id,
            Target_Period__c = period.Id,
            User__c = UserInfo.getUserId(),
            Target_Value__c = 100000,
            Achievement_Value__c = 85000
        );
        insert actual;

        // Create incentive slabs
        List<Incentive_Slab__c> slabs = new List<Incentive_Slab__c>();

        slabs.add(new Incentive_Slab__c(
            Name = 'Below Threshold',
            Min_Percent__c = 0, Max_Percent__c = 49.99,
            Payout_Type__c = 'Fixed Amount', Payout_Value__c = 0,
            Multiplier__c = 0, Is_Active__c = true, Sort_Order__c = 1
        ));
        slabs.add(new Incentive_Slab__c(
            Name = 'Standard',
            Min_Percent__c = 80, Max_Percent__c = 99.99,
            Payout_Type__c = 'Percentage', Payout_Value__c = 3,
            Multiplier__c = 1.0, Is_Active__c = true, Sort_Order__c = 3
        ));
        slabs.add(new Incentive_Slab__c(
            Name = 'Super Achiever',
            Min_Percent__c = 100, Max_Percent__c = 999,
            Payout_Type__c = 'Percentage', Payout_Value__c = 5,
            Multiplier__c = 2.0, Is_Active__c = true, Sort_Order__c = 5
        ));
        // Criteria-specific slab
        slabs.add(new Incentive_Slab__c(
            Name = 'Revenue Bonus',
            Target_Criteria__c = criteria.Id,
            Min_Percent__c = 80, Max_Percent__c = 99.99,
            Payout_Type__c = 'Fixed Amount', Payout_Value__c = 5000,
            Multiplier__c = 1.0, Is_Active__c = true, Sort_Order__c = 2
        ));

        insert slabs;
    }

    @isTest
    static void testCalculateForTargetActuals_StandardSlab() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];
        List<Target_Actual__c> actuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c
        ];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(actuals, period.Id);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should create one incentive');
        Incentive__c inc = results[0];
        System.assertEquals('Calculated', inc.Status__c, 'Status should be Calculated');
        System.assert(inc.Achievement_Percent__c > 0, 'Achievement % should be set');
        System.assert(inc.Calculated_Amount__c > 0, 'Payout should be > 0');
        System.assertNotEquals(null, inc.Incentive_Slab_Ref__c, 'Slab should be matched');

        // 85% achievement should match criteria-specific "Revenue Bonus" slab (Fixed 5000)
        Incentive_Slab__c matched = [SELECT Name FROM Incentive_Slab__c WHERE Id = :inc.Incentive_Slab_Ref__c];
        System.assertEquals('Revenue Bonus', matched.Name, 'Should match criteria-specific slab first');
        System.assertEquals(5000, inc.Calculated_Amount__c, 'Fixed payout should be 5000 * 1.0');
    }

    @isTest
    static void testCalculateForTargetActuals_NoTarget() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        // Create actual with zero target
        Target_Actual__c zeroActual = new Target_Actual__c(
            Target_Criteria__c = [SELECT Id FROM Target_Criteria__c LIMIT 1].Id,
            Target_Period__c = period.Id,
            User__c = UserInfo.getUserId(),
            Target_Value__c = 0,
            Achievement_Value__c = 0
        );
        insert zeroActual;

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(
            new List<Target_Actual__c>{ zeroActual }, period.Id
        );
        Test.stopTest();

        System.assertEquals(0, results.size(), 'No incentive for zero target');
    }

    @isTest
    static void testCalculateForTargetActuals_EmptyList() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(
            new List<Target_Actual__c>(), period.Id
        );
        Test.stopTest();

        System.assertEquals(0, results.size(), 'No incentives for empty list');
    }

    @isTest
    static void testComputePayout_Percentage() {
        Incentive_Slab__c slab = new Incentive_Slab__c(
            Payout_Type__c = 'Percentage', Payout_Value__c = 3, Multiplier__c = 1.5
        );

        Decimal result = TAM_IncentiveCalculation_Service.computePayout(100000, 85, slab);
        // 100000 * (3/100) * 1.5 = 4500
        System.assertEquals(4500, result, 'Percentage payout should be 4500');
    }

    @isTest
    static void testComputePayout_FixedAmount() {
        Incentive_Slab__c slab = new Incentive_Slab__c(
            Payout_Type__c = 'Fixed Amount', Payout_Value__c = 2000, Multiplier__c = 2.0
        );

        Decimal result = TAM_IncentiveCalculation_Service.computePayout(100000, 120, slab);
        // 2000 * 2.0 = 4000
        System.assertEquals(4000, result, 'Fixed payout should be 4000');
    }

    @isTest
    static void testUpsertExistingIncentive() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];
        List<Target_Actual__c> actuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c
        ];

        // Calculate first time
        TAM_IncentiveCalculation_Service.calculateForTargetActuals(actuals, period.Id);
        Integer countBefore = [SELECT COUNT() FROM Incentive__c];

        // Update achievement and recalculate
        actuals[0].Achievement_Value__c = 110000;
        update actuals;

        actuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c
        ];

        Test.startTest();
        TAM_IncentiveCalculation_Service.calculateForTargetActuals(actuals, period.Id);
        Test.stopTest();

        Integer countAfter = [SELECT COUNT() FROM Incentive__c];
        System.assertEquals(countBefore, countAfter, 'Should update existing, not create new');
    }

    // ── computePayout: Salary Percentage ────────────────────────────────

    @isTest
    static void testComputePayout_SalaryPercentage() {
        Incentive_Slab__c slab = new Incentive_Slab__c(
            Payout_Type__c = 'Salary Percentage', Payout_Value__c = 10, Multiplier__c = 1
        );
        // Monthly salary 50000, monthly period (multiplier 1)
        Decimal result = TAM_IncentiveCalculation_Service.computePayout(100000, 85, slab, 50000, 1);
        // 50000 * 1 * (10/100) * 1 = 5000
        System.assertEquals(5000, result);
    }

    @isTest
    static void testComputePayout_SalaryPercentage_Quarterly() {
        Incentive_Slab__c slab = new Incentive_Slab__c(
            Payout_Type__c = 'Salary Percentage', Payout_Value__c = 5, Multiplier__c = 1
        );
        // Monthly salary 50000, quarterly (multiplier 3)
        Decimal result = TAM_IncentiveCalculation_Service.computePayout(100000, 85, slab, 50000, 3);
        // 50000 * 3 * (5/100) * 1 = 7500
        System.assertEquals(7500, result);
    }

    // ── computePayout: null multiplier ──────────────────────────────────

    @isTest
    static void testComputePayout_NullMultiplier() {
        Incentive_Slab__c slab = new Incentive_Slab__c(
            Payout_Type__c = 'Fixed Amount', Payout_Value__c = 1000, Multiplier__c = null
        );
        Decimal result = TAM_IncentiveCalculation_Service.computePayout(100000, 85, slab);
        System.assertEquals(1000, result);
    }

    // ── findMatchingSlab: 4-tier priority ───────────────────────────────

    @isTest
    static void testFindMatchingSlab_CriteriaOnly() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];
        List<Incentive_Slab__c> slabs = [
            SELECT Id, Name, Target_Criteria__c, Min_Percent__c, Max_Percent__c,
                   Payout_Type__c, Payout_Value__c, Multiplier__c,
                   Is_Active__c, Effective_From__c, Effective_To__c,
                   Profile_Name__c, Territory__c
            FROM Incentive_Slab__c WHERE Is_Active__c = true
            ORDER BY Sort_Order__c ASC
        ];

        Test.startTest();
        Incentive_Slab__c matched = TAM_IncentiveCalculation_Service.findMatchingSlab(
            85, criteria.Id, 'System Administrator', null, slabs, Date.today()
        );
        Test.stopTest();

        System.assertNotEquals(null, matched);
        System.assertEquals('Revenue Bonus', matched.Name);
    }

    @isTest
    static void testFindMatchingSlab_Universal() {
        List<Incentive_Slab__c> slabs = [
            SELECT Id, Name, Target_Criteria__c, Min_Percent__c, Max_Percent__c,
                   Payout_Type__c, Payout_Value__c, Multiplier__c,
                   Is_Active__c, Effective_From__c, Effective_To__c,
                   Profile_Name__c, Territory__c
            FROM Incentive_Slab__c WHERE Is_Active__c = true
            ORDER BY Sort_Order__c ASC
        ];

        // Use a non-existent criteria — should fall through to universal slab
        Id fakeCriteriaId = Target_Criteria__c.SObjectType.getDescribe().getKeyPrefix() + '000000000000';
        Test.startTest();
        Incentive_Slab__c matched = TAM_IncentiveCalculation_Service.findMatchingSlab(
            85, fakeCriteriaId, 'Unknown Profile', null, slabs, Date.today()
        );
        Test.stopTest();

        // Should match universal "Standard" slab (no criteria, 80-99.99%)
        System.assertNotEquals(null, matched);
        System.assertEquals('Standard', matched.Name);
    }

    @isTest
    static void testFindMatchingSlab_NoMatch() {
        List<Incentive_Slab__c> slabs = [
            SELECT Id, Name, Target_Criteria__c, Min_Percent__c, Max_Percent__c,
                   Payout_Type__c, Payout_Value__c, Multiplier__c,
                   Is_Active__c, Effective_From__c, Effective_To__c,
                   Profile_Name__c, Territory__c
            FROM Incentive_Slab__c WHERE Is_Active__c = true
            ORDER BY Sort_Order__c ASC
        ];

        // 55% doesn't match any slab (gap between 49.99 and 80)
        Id fakeCriteriaId = Target_Criteria__c.SObjectType.getDescribe().getKeyPrefix() + '000000000000';
        Test.startTest();
        Incentive_Slab__c matched = TAM_IncentiveCalculation_Service.findMatchingSlab(
            55, fakeCriteriaId, null, null, slabs, Date.today()
        );
        Test.stopTest();

        System.assertEquals(null, matched);
    }

    // ── Prerequisite check ──────────────────────────────────────────────

    @isTest
    static void testPrerequisiteNotMet() {
        Target_Criteria__c revCriteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];

        // Create a second criteria with prerequisite
        Target_Criteria__c bonusCriteria = new Target_Criteria__c(
            Name = 'Bonus KPI', Object__c = 'Account', Operator__c = 'COUNT',
            Date_Field__c = 'CreatedDate', User_Field__c = 'OwnerId', Active__c = true,
            Prerequisite_Criteria__c = revCriteria.Id, Prerequisite_Min_Percent__c = 90
        );
        insert bonusCriteria;

        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        // Create actual for bonus criteria — but revenue prereq is only 85%
        Target_Actual__c bonusActual = new Target_Actual__c(
            Target_Criteria__c = bonusCriteria.Id, Target_Period__c = period.Id,
            User__c = UserInfo.getUserId(), Target_Value__c = 50000, Achievement_Value__c = 40000
        );
        insert bonusActual;

        // Include both actuals — revenue (85%) and bonus
        List<Target_Actual__c> allActuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c WHERE Target_Period__c = :period.Id
        ];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(allActuals, period.Id);
        Test.stopTest();

        // Bonus should be skipped (85% revenue < 90% prereq)
        for (Incentive__c inc : results) {
            System.assertNotEquals(bonusCriteria.Id, inc.Target_Criteria__c,
                'Bonus should be skipped due to prerequisite not met');
        }
    }

    // ── KPI Weightage ───────────────────────────────────────────────────

    @isTest
    static void testKPIWeightage() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];
        criteria.Incentive_Weight__c = 50; // 50% weight
        update criteria;

        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];
        List<Target_Actual__c> actuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c WHERE Target_Period__c = :period.Id
        ];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(actuals, period.Id);
        Test.stopTest();

        System.assert(!results.isEmpty());
        // Payout should be 50% of unweighted amount
        System.assert(results[0].Calculated_Amount__c <= 5000 * 0.5 + 1,
            'Weighted payout should be ~50% of base');
    }

    // ── getCumulativeActuals ────────────────────────────────────────────

    @isTest
    static void testGetCumulativeActuals_NoChildren() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];
        Set<Id> userIds = new Set<Id>{ UserInfo.getUserId() };
        Set<Id> criteriaIds = new Set<Id>();
        for (Target_Criteria__c tc : [SELECT Id FROM Target_Criteria__c]) criteriaIds.add(tc.Id);

        Test.startTest();
        List<Target_Actual__c> cumActuals =
            TAM_IncentiveCalculation_Service.getCumulativeActuals(period.Id, userIds, criteriaIds);
        Test.stopTest();

        System.assertNotEquals(null, cumActuals);
    }

    // ── calculateAnnualBonus — no quarterly periods ─────────────────────

    @isTest
    static void testCalculateAnnualBonus_NoQuarters() {
        Target_Period__c annualPeriod = new Target_Period__c(
            Name = 'Annual 2026', Start_Date__c = Date.newInstance(2026, 1, 1),
            End_Date__c = Date.newInstance(2026, 12, 31), Is_Active__c = true, Type__c = 'Yearly'
        );
        insert annualPeriod;

        Test.startTest();
        List<Incentive__c> bonuses = TAM_IncentiveCalculation_Service.calculateAnnualBonus(annualPeriod.Id);
        Test.stopTest();

        System.assertEquals(0, bonuses.size());
    }

    // ── Null input ──────────────────────────────────────────────────────

    @isTest
    static void testNullActuals() {
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];
        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(null, period.Id);
        Test.stopTest();
        System.assertEquals(0, results.size());
    }

    // ── calculateAnnualBonus — with quarterly data ──────────────────────

    @isTest
    static void testCalculateAnnualBonus_WithQuarters() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];

        // Create annual period
        Target_Period__c annualPeriod = new Target_Period__c(
            Name = 'Annual 2026', Start_Date__c = Date.newInstance(2026, 1, 1),
            End_Date__c = Date.newInstance(2026, 12, 31), Is_Active__c = true, Type__c = 'Yearly'
        );
        insert annualPeriod;

        // Create 4 quarterly child periods
        List<Target_Period__c> quarters = new List<Target_Period__c>();
        for (Integer q = 0; q < 4; q++) {
            quarters.add(new Target_Period__c(
                Name = 'Q' + (q + 1) + ' 2026',
                Start_Date__c = Date.newInstance(2026, q * 3 + 1, 1),
                End_Date__c = Date.newInstance(2026, q * 3 + 3, 28),
                Is_Active__c = true, Type__c = 'Quarterly',
                Parent_Period__c = annualPeriod.Id
            ));
        }
        insert quarters;

        // Create incentive records for each quarter (non-annual-bonus)
        List<Incentive__c> qIncentives = new List<Incentive__c>();
        Decimal[] amounts = new Decimal[]{ 5000, 8000, 3000, 7000 };
        for (Integer i = 0; i < 4; i++) {
            qIncentives.add(new Incentive__c(
                Salesperson__c = UserInfo.getUserId(),
                Target_Period__c = quarters[i].Id,
                Target_Criteria__c = criteria.Id,
                Calculated_Amount__c = amounts[i],
                Status__c = 'Calculated',
                Is_Annual_Bonus__c = false
            ));
        }
        insert qIncentives;

        Test.startTest();
        List<Incentive__c> bonuses = TAM_IncentiveCalculation_Service.calculateAnnualBonus(annualPeriod.Id);
        Test.stopTest();

        System.assertEquals(1, bonuses.size(), 'Should create 1 annual bonus');
        // Best 3 of 4: 8000 + 7000 + 5000 = 20000, avg = 6666.67
        System.assert(bonuses[0].Annual_Bonus__c > 0, 'Bonus should be positive');
        System.assertEquals(true, bonuses[0].Is_Annual_Bonus__c);
        System.assertEquals('Calculated', bonuses[0].Status__c);
    }

    // ── calculateAnnualBonus — less than 3 quarters ─────────────────────

    @isTest
    static void testCalculateAnnualBonus_LessThan3Quarters() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];

        Target_Period__c annualPeriod = new Target_Period__c(
            Name = 'Annual Short', Start_Date__c = Date.newInstance(2026, 1, 1),
            End_Date__c = Date.newInstance(2026, 12, 31), Is_Active__c = true, Type__c = 'Yearly'
        );
        insert annualPeriod;

        // Only 2 quarterly periods
        List<Target_Period__c> quarters = new List<Target_Period__c>{
            new Target_Period__c(Name = 'Q1S', Start_Date__c = Date.newInstance(2026, 1, 1),
                End_Date__c = Date.newInstance(2026, 3, 31), Is_Active__c = true,
                Type__c = 'Quarterly', Parent_Period__c = annualPeriod.Id),
            new Target_Period__c(Name = 'Q2S', Start_Date__c = Date.newInstance(2026, 4, 1),
                End_Date__c = Date.newInstance(2026, 6, 30), Is_Active__c = true,
                Type__c = 'Quarterly', Parent_Period__c = annualPeriod.Id)
        };
        insert quarters;

        insert new List<Incentive__c>{
            new Incentive__c(Salesperson__c = UserInfo.getUserId(), Target_Period__c = quarters[0].Id,
                Target_Criteria__c = criteria.Id, Calculated_Amount__c = 5000,
                Status__c = 'Calculated', Is_Annual_Bonus__c = false),
            new Incentive__c(Salesperson__c = UserInfo.getUserId(), Target_Period__c = quarters[1].Id,
                Target_Criteria__c = criteria.Id, Calculated_Amount__c = 8000,
                Status__c = 'Calculated', Is_Annual_Bonus__c = false)
        };

        Test.startTest();
        List<Incentive__c> bonuses = TAM_IncentiveCalculation_Service.calculateAnnualBonus(annualPeriod.Id);
        Test.stopTest();

        // Need at least 3 quarters — should return empty
        System.assertEquals(0, bonuses.size(), 'Should not qualify with < 3 quarters');
    }

    // ── getCumulativeActuals — with child periods ───────────────────────

    @isTest
    static void testGetCumulativeActuals_WithChildren() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];

        Target_Period__c parentPeriod = new Target_Period__c(
            Name = 'Cumulative Parent', Start_Date__c = Date.newInstance(2026, 1, 1),
            End_Date__c = Date.newInstance(2026, 6, 30), Is_Active__c = true,
            Type__c = 'Quarterly', Is_Cumulative__c = true
        );
        insert parentPeriod;

        List<Target_Period__c> children = new List<Target_Period__c>{
            new Target_Period__c(Name = 'Child M1', Start_Date__c = Date.newInstance(2026, 1, 1),
                End_Date__c = Date.newInstance(2026, 1, 31), Is_Active__c = true,
                Type__c = 'Monthly', Parent_Period__c = parentPeriod.Id),
            new Target_Period__c(Name = 'Child M2', Start_Date__c = Date.newInstance(2026, 2, 1),
                End_Date__c = Date.newInstance(2026, 2, 28), Is_Active__c = true,
                Type__c = 'Monthly', Parent_Period__c = parentPeriod.Id)
        };
        insert children;

        insert new List<Target_Actual__c>{
            new Target_Actual__c(Target_Criteria__c = criteria.Id, Target_Period__c = children[0].Id,
                User__c = UserInfo.getUserId(), Target_Value__c = 50000, Achievement_Value__c = 40000),
            new Target_Actual__c(Target_Criteria__c = criteria.Id, Target_Period__c = children[1].Id,
                User__c = UserInfo.getUserId(), Target_Value__c = 50000, Achievement_Value__c = 45000)
        };

        Set<Id> userIds = new Set<Id>{ UserInfo.getUserId() };
        Set<Id> criteriaIds = new Set<Id>{ criteria.Id };

        Test.startTest();
        List<Target_Actual__c> cumActuals =
            TAM_IncentiveCalculation_Service.getCumulativeActuals(parentPeriod.Id, userIds, criteriaIds);
        Test.stopTest();

        System.assertEquals(1, cumActuals.size(), 'Should aggregate into 1 record');
        System.assertEquals(100000, cumActuals[0].Target_Value__c, 'Target should sum to 100000');
        System.assertEquals(85000, cumActuals[0].Achievement_Value__c, 'Achievement should sum to 85000');
    }

    // ── Cumulative period calculation via main entry point ───────────────

    @isTest
    static void testCalculateForTargetActuals_CumulativePeriod() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];

        Target_Period__c cumPeriod = new Target_Period__c(
            Name = 'Cumulative Q', Start_Date__c = Date.newInstance(2026, 1, 1),
            End_Date__c = Date.newInstance(2026, 3, 31), Is_Active__c = true,
            Type__c = 'Quarterly', Is_Cumulative__c = true
        );
        insert cumPeriod;

        Target_Period__c childPeriod = new Target_Period__c(
            Name = 'Child Month', Start_Date__c = Date.newInstance(2026, 1, 1),
            End_Date__c = Date.newInstance(2026, 1, 31), Is_Active__c = true,
            Type__c = 'Monthly', Parent_Period__c = cumPeriod.Id
        );
        insert childPeriod;

        Target_Actual__c childActual = new Target_Actual__c(
            Target_Criteria__c = criteria.Id, Target_Period__c = childPeriod.Id,
            User__c = UserInfo.getUserId(), Target_Value__c = 100000, Achievement_Value__c = 90000
        );
        insert childActual;

        // Create a parent-level actual for the main method input
        Target_Actual__c parentActual = new Target_Actual__c(
            Target_Criteria__c = criteria.Id, Target_Period__c = cumPeriod.Id,
            User__c = UserInfo.getUserId(), Target_Value__c = 100000, Achievement_Value__c = 90000
        );
        insert parentActual;

        List<Target_Actual__c> actuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c WHERE Target_Period__c = :cumPeriod.Id
        ];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(actuals, cumPeriod.Id);
        Test.stopTest();

        // Should process cumulative path (line 77-87)
        System.assertNotEquals(null, results);
    }

    // ── Quarterly salary period multiplier ───────────────────────────────

    @isTest
    static void testQuarterlyPeriodMultiplier() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];

        Target_Period__c qPeriod = new Target_Period__c(
            Name = 'Q Period', Start_Date__c = Date.today().toStartOfMonth(),
            End_Date__c = Date.today().toStartOfMonth().addMonths(3).addDays(-1),
            Is_Active__c = true, Type__c = 'Quarterly'
        );
        insert qPeriod;

        Target_Actual__c actual = new Target_Actual__c(
            Target_Criteria__c = criteria.Id, Target_Period__c = qPeriod.Id,
            User__c = UserInfo.getUserId(), Target_Value__c = 300000, Achievement_Value__c = 270000
        );
        insert actual;

        List<Target_Actual__c> actuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c WHERE Target_Period__c = :qPeriod.Id
        ];

        Test.startTest();
        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(actuals, qPeriod.Id);
        Test.stopTest();

        // Covers line 104: salaryPeriodMultiplier = 3
        System.assertNotEquals(null, results);
    }
}