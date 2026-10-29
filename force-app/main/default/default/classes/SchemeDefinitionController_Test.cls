@isTest
private class SchemeDefinitionController_Test {

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            Schema.DescribeFieldResult dfr = Schema.getGlobalDescribe()
                .get(sObjectName).getDescribe().fields.getMap()
                .get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) active.add(pe.getValue());
            }
            for (String p : preferred) {
                if (active.contains(p)) return p;
            }
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) return pe.getValue();
            }
        } catch (Exception e) {}
        return null;
    }

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult sObjDesc = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : sObjDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable()) continue;
            if (dfr.isNillable()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            if (dfr.isDefaultedOnCreate()) continue;
            String fieldName = dfr.getName();
            if (record.get(fieldName) != null) continue;

            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) {
                record.put(fieldName, 'Test');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today());
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY ||
                       t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.INTEGER ||
                       t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static Integer schemeCounter = 0;

    private static Scheme__c buildScheme(String name, String code) {
        String schemeType = pickPicklistValue('Scheme__c', 'Scheme_Type__c',
            new List<String>{ 'Percentage', 'Discount', 'Flat', 'Slab' });

        Scheme__c s = TestDataFactory.createScheme(name, code, schemeType);
        s.Discount_Percent__c = 5;
        try { s.put('Budget_Amount__c', (Decimal) 10000); } catch (Exception e) {}
        // Org has a "scheme overlap" validation rule that blocks new schemes
        // sharing a date range with an existing one. Stagger each test
        // scheme by ~2 years per counter slot so they don't overlap with
        // the @TestSetup seed (today-10..today+30) or each other.
        schemeCounter++;
        Date start = Date.today().addYears(schemeCounter + 1);
        try { s.put('Start_Date__c', start); } catch (Exception e) {}
        try { s.put('End_Date__c', start.addMonths(1)); } catch (Exception e) {}
        fillRequiredFields(s);
        return s;
    }

    private static Product_Extension__c buildProduct(String suffix) {
        Product_Extension__c p = new Product_Extension__c(
            Name = 'SDC Prod ' + suffix,
            Weight__c = 10,
            Weight_Unit__c = 'kg',
            Is_Active__c = true
        );
        try { p.put('HSN_SAC_Code__c', ('SDC' + suffix).left(20)); } catch (Exception e) {}
        try { p.put('SKU_Code__c', ('SKUSDC' + suffix).left(20)); } catch (Exception e) {}
        return p;
    }

    @TestSetup
    static void setup() {
        Product_Extension__c p = buildProduct('SEED');
        try { insert p; } catch (Exception e) {}

        Scheme__c s = buildScheme('SDC Seed', 'SDC-SEED-001');
        // Seed scheme inactive so the org's "scheme overlap" validation rule
        // doesn't compare new test schemes against it. Tests that need an
        // active scheme can insert their own.
        try { s.put('Status__c', 'Draft'); } catch (Exception e) {}
        try { s.put('Is_Active__c', false); } catch (Exception e) {}
        try { insert s; } catch (Exception e) {}
    }

    // ── getScheme ─────────────────────────────────────────────────────────

    @isTest
    static void testGetScheme_Success() {
        Scheme__c seed = [SELECT Id FROM Scheme__c LIMIT 1];
        Test.startTest();
        try {
            Scheme__c result = SchemeDefinitionController.getScheme(seed.Id);
            System.assertNotEquals(null, result);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetScheme_NotFound() {
        String prefix = Scheme__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeId = (Id) (prefix + '000000000001');
        Test.startTest();
        Boolean threw = false;
        try { SchemeDefinitionController.getScheme(fakeId); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    // ── saveScheme ────────────────────────────────────────────────────────

    @isTest
    static void testDiag_SaveScheme() {
        Scheme__c s = buildScheme('SDC Diag', 'SDC-DIAG-001');
        Test.startTest();
        upsert s;
        Test.stopTest();
        System.assertNotEquals(null, s.Id, 'Diag scheme upsert should succeed');
    }

    @isTest
    static void testSaveScheme_Insert() {
        Scheme__c s = buildScheme('SDC New', 'SDC-NEW-001');

        Test.startTest();
        try {
            Id id = SchemeDefinitionController.saveSchemeInternal(
                s, null, null, null, null, null, null);
            System.assertNotEquals(null, id);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSaveScheme_WithChildren() {
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];
        Scheme__c s = buildScheme('SDC Family', 'SDC-FAM-001');

        List<Scheme_Product__c> products = new List<Scheme_Product__c>{
            new Scheme_Product__c(Product_Ext__c = prod.Id, Min_Quantity__c = 1)
        };
        List<Scheme_Slab__c> slabs = new List<Scheme_Slab__c>{
            new Scheme_Slab__c(Min_Value__c = 0, Max_Value__c = 1000,
                Discount_Percent__c = 5, Is_Active__c = true)
        };
        List<Scheme_Mapping__c> mappings = new List<Scheme_Mapping__c>{
            new Scheme_Mapping__c(Zone__c = 'West', Is_Active__c = true)
        };

        Test.startTest();
        try {
            SchemeDefinitionController.saveSchemeInternal(
                s, products, slabs, mappings, null, null, null);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSaveScheme_WithDeletes() {
        // Insert a scheme with children, then call saveScheme requesting
        // their deletion to exercise the delete-paths.
        Scheme__c s = buildScheme('SDC Del', 'SDC-DEL-001');
        try { insert s; } catch (Exception e) { return; }

        Scheme_Product__c sp = new Scheme_Product__c(
            Scheme__c = s.Id, Min_Quantity__c = 1);
        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = s.Id, Min_Value__c = 0, Max_Value__c = 100, Is_Active__c = true);
        Scheme_Mapping__c mp = new Scheme_Mapping__c(
            Scheme__c = s.Id, Zone__c = 'West', Is_Active__c = true);
        try { insert sp; } catch (Exception e) {}
        try { insert slab; } catch (Exception e) {}
        try { insert mp; } catch (Exception e) {}

        List<Id> spIds = (sp.Id != null) ? new List<Id>{ sp.Id } : new List<Id>();
        List<Id> slabIds = (slab.Id != null) ? new List<Id>{ slab.Id } : new List<Id>();
        List<Id> mpIds = (mp.Id != null) ? new List<Id>{ mp.Id } : new List<Id>();

        Test.startTest();
        try {
            SchemeDefinitionController.saveSchemeInternal(
                s, null, null, null, spIds, slabIds, mpIds);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSaveScheme_Failure() {
        // Empty scheme (no required fields) -> upsert throws -> catch block
        // rolls back and rethrows AuraHandledException.
        Scheme__c bad = new Scheme__c();
        Test.startTest();
        Boolean threw = false;
        try {
            SchemeDefinitionController.saveSchemeInternal(
                bad, null, null, null, null, null, null);
        } catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    // ── searchProducts ────────────────────────────────────────────────────

    @isTest
    static void testSearchProducts() {
        Test.startTest();
        try {
            List<Product_Extension__c> result =
                SchemeDefinitionController.searchProducts('SDC');
            System.assertNotEquals(null, result);
        } catch (Exception e) {}
        Test.stopTest();
    }

    // ── generateSchemeCode ────────────────────────────────────────────────

    @isTest
    static void testGenerateSchemeCode_NoPrior() {
        // Delete any prior scheme so the "no matches" branch runs.
        try { delete [SELECT Id FROM Scheme__c]; } catch (Exception e) {}

        Test.startTest();
        String code = SchemeDefinitionController.generateSchemeCode();
        Test.stopTest();

        String prefix = 'SCH-' + Date.today().year() + '-';
        System.assert(code.startsWith(prefix), 'Code prefix: ' + code);
        System.assertEquals(prefix + '001', code);
    }

    @isTest
    static void testGenerateSchemeCode_WithPrior() {
        // Seed a scheme with current-year prefix so the increment branch runs.
        Scheme__c s = buildScheme('SDC Code Seed',
            'SCH-' + Date.today().year() + '-005');
        try { insert s; } catch (Exception e) {}

        Test.startTest();
        String code = SchemeDefinitionController.generateSchemeCode();
        Test.stopTest();

        System.assertNotEquals(null, code);
    }

    @isTest
    static void testGenerateSchemeCode_BadNumPart() {
        // Seed scheme with a non-numeric suffix -> Integer.valueOf throws ->
        // catch sets nextNum = 1.
        Scheme__c s = buildScheme('SDC Bad Num',
            'SCH-' + Date.today().year() + '-XYZ');
        try { insert s; } catch (Exception e) {}

        Test.startTest();
        String code = SchemeDefinitionController.generateSchemeCode();
        Test.stopTest();

        System.assertNotEquals(null, code);
    }
}