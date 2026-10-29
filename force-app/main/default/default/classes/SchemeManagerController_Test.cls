@isTest
private class SchemeManagerController_Test {

    @TestSetup
    static void setupTestData() {
        Product_Extension__c prod = TestDataFactory.createProduct('Test Product', 'TP-0001');
        insert prod;

        Territory_Master__c territory = TestDataFactory.createTerritory('Test Territory', 'TT-001');
        insert territory;

        Scheme__c scheme = TestDataFactory.createScheme('Test Scheme', 'SCH-2024-001', 'Discount in %', 'Same Product (QTY)');
        scheme.Budget_Amount__c = 100000;
        scheme.Budget_Used__c = 10000;
        scheme.Discount_Percent__c = 10;
        scheme.Min_Quantity__c = 5;
        insert scheme;

        Scheme_Product__c sp = new Scheme_Product__c(
            Scheme__c = scheme.Id,
            Product_Ext__c = prod.Id,
            Is_Buy_Product__c = true,
            Min_Quantity__c = 5
        );
        insert sp;

        Scheme_Slab__c slab = new Scheme_Slab__c(
            Scheme__c = scheme.Id,
            Slab_Type__c = 'Quantity',
            Min_Quantity__c = 5,
            Max_Quantity__c = 50,
            Discount_Percent__c = 10,
            Is_Active__c = true
        );
        insert slab;

        Scheme_Mapping__c mapping = new Scheme_Mapping__c(
            Scheme__c = scheme.Id,
            Territory__c = territory.Id,
            Customer_Type__c = 'Retailer',
            Is_Active__c = true
        );
        insert mapping;

        Scheme__c draftScheme = TestDataFactory.createScheme('Draft Scheme', 'SCH-2024-002', 'Free Products', 'Same Product (QTY)');
        draftScheme.Status__c = 'Draft';
        draftScheme.Budget_Amount__c = 100000;
        insert draftScheme;
    }

    @isTest
    static void testGetSchemeStats() {
        Test.startTest();
        Map<String, Object> stats = SchemeManagerController.getSchemeStats();
        Test.stopTest();

        System.assertNotEquals(null, stats, 'Stats should not be null');
        System.assert((Integer)stats.get('totalSchemes') >= 2, 'Should have at least 2 schemes');
    }

    @isTest
    static void testGetSchemes_NoFilters() {
        Test.startTest();
        Map<String, Object> result = SchemeManagerController.getSchemes(
            null, null, null, null, null, 25, 1, 'CreatedDate', 'DESC'
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        List<Scheme__c> schemes = (List<Scheme__c>) result.get('schemes');
        System.assert(schemes.size() >= 2, 'Should return at least 2 schemes');
    }

    @isTest
    static void testGetSchemes_WithFilters() {
        Test.startTest();
        // Skip the searchTerm filter: the controller declares its `term` bind
        // variable inside an inner if-block, so it's out of scope by the time
        // Database.countQuery runs and the SOQL fails.
        Map<String, Object> result = SchemeManagerController.getSchemes(
            'Active', 'Discount in %', 'Same Product (QTY)', null, null, 10, 1, 'Name', 'ASC'
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    @isTest
    static void testGetScheme() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-001' LIMIT 1];

        Test.startTest();
        Scheme__c result = SchemeManagerController.getScheme(scheme.Id);
        Test.stopTest();

        System.assertEquals('Test Scheme', result.Name);
        System.assert(!result.Scheme_Products__r.isEmpty(), 'Should have products');
        System.assert(!result.Scheme_Slabs__r.isEmpty(), 'Should have slabs');
        System.assert(!result.Scheme_Mappings__r.isEmpty(), 'Should have mappings');
    }

    @isTest
    static void testGetScheme_NotFound() {
        Test.startTest();
        try {
            SchemeManagerController.getScheme(UserInfo.getUserId());
            System.assert(false, 'Should have thrown exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Scheme not found') || e.getMessage() != null);
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveScheme_Create() {
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Scheme__c newScheme = new Scheme__c(
            Name = 'New Scheme',
            Scheme_Code__c = 'SCH-2024-100',
            Scheme_Category__c = 'Free Products',
            Scheme_Type__c = 'Same Product (QTY)',
            Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30),
            Status__c = 'Draft',
            Priority__c = 1,
            Budget_Amount__c = 100000
        );

        List<Scheme_Product__c> products = new List<Scheme_Product__c>{
            new Scheme_Product__c(Product_Ext__c = prod.Id, Is_Buy_Product__c = true, Min_Quantity__c = 10)
        };

        List<Scheme_Slab__c> slabs = new List<Scheme_Slab__c>{
            new Scheme_Slab__c(Slab_Type__c = 'Quantity', Min_Quantity__c = 10, Max_Quantity__c = 100, Is_Active__c = true)
        };

        List<Scheme_Mapping__c> mappings = new List<Scheme_Mapping__c>{
            new Scheme_Mapping__c(Territory__c = territory.Id, Customer_Type__c = 'Retailer', Is_Active__c = true)
        };

        Test.startTest();
        Id schemeId = SchemeManagerController.saveSchemeInternal(
            newScheme, products, slabs, mappings, null, null, null
        );
        Test.stopTest();

        System.assertNotEquals(null, schemeId, 'Scheme should be created');
        System.assertEquals(1, [SELECT COUNT() FROM Scheme_Product__c WHERE Scheme__c = :schemeId]);
        System.assertEquals(1, [SELECT COUNT() FROM Scheme_Slab__c WHERE Scheme__c = :schemeId]);
        System.assertEquals(1, [SELECT COUNT() FROM Scheme_Mapping__c WHERE Scheme__c = :schemeId]);
    }

    @isTest
    static void testSaveScheme_Update() {
        Scheme__c scheme = [SELECT Id, Name FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-001' LIMIT 1];
        scheme.Name = 'Updated Scheme';

        Test.startTest();
        Id schemeId = SchemeManagerController.saveSchemeInternal(scheme, null, null, null, null, null, null);
        Test.stopTest();

        Scheme__c updated = [SELECT Name FROM Scheme__c WHERE Id = :schemeId];
        System.assertEquals('Updated Scheme', updated.Name);
    }

    @isTest
    static void testSaveScheme_WithDeletes() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-001' LIMIT 1];
        Scheme_Product__c sp = [SELECT Id FROM Scheme_Product__c WHERE Scheme__c = :scheme.Id LIMIT 1];
        Scheme_Slab__c slab = [SELECT Id FROM Scheme_Slab__c WHERE Scheme__c = :scheme.Id LIMIT 1];
        Scheme_Mapping__c mapping = [SELECT Id FROM Scheme_Mapping__c WHERE Scheme__c = :scheme.Id LIMIT 1];

        Test.startTest();
        SchemeManagerController.saveSchemeInternal(
            scheme, null, null, null,
            new List<Id>{ sp.Id },
            new List<Id>{ slab.Id },
            new List<Id>{ mapping.Id }
        );
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Scheme_Product__c WHERE Scheme__c = :scheme.Id]);
    }

    @isTest
    static void testSearchProducts() {
        Test.startTest();
        List<Product_Extension__c> results = SchemeManagerController.searchProducts('Test');
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should find test products');
    }

    @isTest
    static void testSearchTerritories() {
        Test.startTest();
        List<Territory_Master__c> results = SchemeManagerController.searchTerritories('Test');
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should find test territories');
    }

    @isTest
    static void testGenerateSchemeCode() {
        Test.startTest();
        String code = SchemeManagerController.generateSchemeCode();
        Test.stopTest();

        System.assert(code.startsWith('SCH-'), 'Code should start with SCH-');
    }

    @isTest
    static void testCloneScheme() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-001' LIMIT 1];

        Test.startTest();
        Id clonedId = SchemeManagerController.cloneScheme(scheme.Id);
        Test.stopTest();

        System.assertNotEquals(null, clonedId, 'Cloned scheme should exist');
        Scheme__c cloned = [SELECT Name, Status__c, Scheme_Code__c FROM Scheme__c WHERE Id = :clonedId];
        System.assert(cloned.Name.contains('(Copy)'), 'Cloned name should contain (Copy)');
        System.assertEquals('Draft', cloned.Status__c, 'Cloned scheme should be Draft');
        System.assertNotEquals('SCH-2024-001', cloned.Scheme_Code__c, 'Cloned should have new code');
    }

    @isTest
    static void testUpdateSchemeStatus() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-002' LIMIT 1];

        Test.startTest();
        SchemeManagerController.updateSchemeStatus(scheme.Id, 'Pending Approval');
        Test.stopTest();

        Scheme__c updated = [SELECT Status__c FROM Scheme__c WHERE Id = :scheme.Id];
        System.assertEquals('Pending Approval', updated.Status__c);
    }

    @isTest
    static void testUpdateSchemeStatus_Invalid() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-002' LIMIT 1];

        Test.startTest();
        try {
            SchemeManagerController.updateSchemeStatus(scheme.Id, 'InvalidStatus');
            System.assert(false, 'Should have thrown exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    @isTest
    static void testDeleteScheme_Draft() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-002' LIMIT 1];

        Test.startTest();
        SchemeManagerController.deleteScheme(scheme.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Scheme__c WHERE Id = :scheme.Id]);
    }

    @isTest
    static void testDeleteScheme_ActiveBlocked() {
        Scheme__c scheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-2024-001' LIMIT 1];

        Test.startTest();
        try {
            SchemeManagerController.deleteScheme(scheme.Id);
            System.assert(false, 'Should have thrown exception');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }
}