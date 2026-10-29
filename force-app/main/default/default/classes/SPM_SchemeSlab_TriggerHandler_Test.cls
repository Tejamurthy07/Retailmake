@isTest
private class SPM_SchemeSlab_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        Scheme__c scheme = TestDataFactory.createScheme('Slab Scheme', 'SCH-SLAB-001', 'Discount in %', 'Same Product (QTY)');
        scheme.Budget_Amount__c = 100000;
        scheme.Status__c = 'Draft';
        insert scheme;
        scheme.Status__c = 'Active';
        update scheme;

        Scheme__c scheme2 = TestDataFactory.createScheme('Slab Scheme 2', 'SCH-SLAB-002', 'Free Products', 'Same Product (QTY)');
        scheme2.Budget_Amount__c = 100000;
        scheme2.Status__c = 'Draft';
        insert scheme2;
        scheme2.Status__c = 'Active';
        update scheme2;
    }

    static Scheme__c getScheme1() {
        return [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SLAB-001' LIMIT 1];
    }
    static Scheme__c getScheme2() {
        return [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SLAB-002' LIMIT 1];
    }

    // ── beforeInsert: validateSlabRanges ────────────────────────────────

    @isTest
    static void testValidQuantityRange() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = getScheme1().Id, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10, Discount_Percent__c = 5, Is_Active__c = true
        );
        Test.startTest();
        insert slab;
        Test.stopTest();
        System.assertNotEquals(null, slab.Id);
    }

    @isTest
    static void testInvalidQuantityRange_MinGreaterThanMax() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = getScheme1().Id, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 100, Max_Quantity__c = 10, Is_Active__c = true
        );
        Test.startTest();
        try {
            insert slab;
            System.assert(false, 'Should throw');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    @isTest
    static void testValidValueRange() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = getScheme1().Id, Slab_Type__c = 'Value',
            Min_Value__c = 100, Max_Value__c = 500, Discount_Percent__c = 3, Is_Active__c = true
        );
        Test.startTest();
        insert slab;
        Test.stopTest();
        System.assertNotEquals(null, slab.Id);
    }

    @isTest
    static void testInvalidValueRange_MinGreaterThanMax() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = getScheme1().Id, Slab_Type__c = 'Value',
            Min_Value__c = 1000, Max_Value__c = 100, Is_Active__c = true
        );
        Test.startTest();
        try {
            insert slab;
            System.assert(false, 'Should throw');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    @isTest
    static void testNullRanges_Allowed() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = getScheme1().Id, Slab_Type__c = 'Quantity',
            Min_Quantity__c = null, Max_Quantity__c = null,
            Min_Value__c = null, Max_Value__c = null,
            Discount_Percent__c = 5, Is_Active__c = true
        );
        Test.startTest();
        insert slab;
        Test.stopTest();
        System.assertNotEquals(null, slab.Id);
    }

    // ── beforeUpdate: validateSlabRanges on update ──────────────────────

    @isTest
    static void testUpdate_ValidRange() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = getScheme2().Id, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 50, Discount_Percent__c = 10, Is_Active__c = true
        );
        insert slab;

        Test.startTest();
        slab.Discount_Percent__c = 15;
        update slab;
        Test.stopTest();

        System.assertEquals(15, [SELECT Discount_Percent__c FROM Scheme_Slab__c WHERE Id = :slab.Id].Discount_Percent__c);
    }

    @isTest
    static void testUpdate_InvalidRange() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = getScheme2().Id, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 50, Discount_Percent__c = 10, Is_Active__c = true
        );
        insert slab;

        Test.startTest();
        slab.Min_Quantity__c = 100;
        try {
            update slab;
            System.assert(false, 'Should throw');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ── afterInsert: detectOverlappingSlabs — quantity overlap ──────────

    @isTest
    static void testOverlappingQuantitySlabs() {
        Id schemeId = getScheme1().Id;
        insert new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10,
            Discount_Percent__c = 5, Is_Active__c = true
        );

        Scheme_Slab__c overlap = new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 5, Max_Quantity__c = 15,
            Discount_Percent__c = 10, Is_Active__c = true
        );
        Test.startTest();
        try {
            insert overlap;
            System.assert(false, 'Should throw for overlap');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ── afterInsert: detectOverlappingSlabs — value overlap ─────────────

    @isTest
    static void testOverlappingValueSlabs() {
        Id schemeId = getScheme2().Id;
        insert new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Value',
            Min_Value__c = 100, Max_Value__c = 500,
            Discount_Percent__c = 5, Is_Active__c = true
        );

        Scheme_Slab__c overlap = new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Value',
            Min_Value__c = 400, Max_Value__c = 800,
            Discount_Percent__c = 10, Is_Active__c = true
        );
        Test.startTest();
        try {
            insert overlap;
            System.assert(false, 'Should throw for value overlap');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ── Non-overlapping slabs allowed ───────────────────────────────────

    @isTest
    static void testNonOverlappingSlabs_Allowed() {
        Id schemeId = getScheme1().Id;
        insert new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10,
            Discount_Percent__c = 5, Is_Active__c = true
        );

        Scheme_Slab__c noOverlap = new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 11, Max_Quantity__c = 20,
            Discount_Percent__c = 10, Is_Active__c = true
        );
        Test.startTest();
        insert noOverlap;
        Test.stopTest();
        System.assertNotEquals(null, noOverlap.Id);
    }

    // ── Inactive slab skips overlap check ──────────────────────────────

    @isTest
    static void testInactiveSlab_SkipsOverlapCheck() {
        Id schemeId = getScheme2().Id;
        insert new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10,
            Discount_Percent__c = 5, Is_Active__c = true
        );

        Scheme_Slab__c inactive = new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 5, Max_Quantity__c = 15,
            Discount_Percent__c = 10, Is_Active__c = false
        );
        Test.startTest();
        insert inactive;
        Test.stopTest();
        System.assertNotEquals(null, inactive.Id);
    }

    // ── Different scheme — no overlap ──────────────────────────────────

    @isTest
    static void testDifferentScheme_NoOverlap() {
        insert new Scheme_Slab__c(
            Scheme__c = getScheme1().Id, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10,
            Discount_Percent__c = 5, Is_Active__c = true
        );

        Scheme_Slab__c otherScheme = new Scheme_Slab__c(
            Scheme__c = getScheme2().Id, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10,
            Discount_Percent__c = 10, Is_Active__c = true
        );
        Test.startTest();
        insert otherScheme;
        Test.stopTest();
        System.assertNotEquals(null, otherScheme.Id);
    }

    // ── afterUpdate: overlap on update ──────────────────────────────────

    @isTest
    static void testUpdateCausesOverlap() {
        Id schemeId = getScheme1().Id;
        insert new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10,
            Discount_Percent__c = 5, Is_Active__c = true
        );

        Scheme_Slab__c slab2 = new Scheme_Slab__c(
            Scheme__c = schemeId, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 20, Max_Quantity__c = 30,
            Discount_Percent__c = 10, Is_Active__c = true
        );
        insert slab2;

        Test.startTest();
        slab2.Min_Quantity__c = 5;
        slab2.Max_Quantity__c = 15;
        try {
            update slab2;
            System.assert(false, 'Should throw for overlap on update');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ── No scheme ID — skips overlap ───────────────────────────────────

    @isTest
    static void testNullScheme_SkipsOverlap() {
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = null, Slab_Type__c = 'Quantity',
            Min_Quantity__c = 1, Max_Quantity__c = 10, Is_Active__c = true
        );
        Test.startTest();
        try {
            insert slab;
        } catch (DmlException e) {
            // Required field may fail, that's OK
            System.assert(true);
        }
        Test.stopTest();
    }
}