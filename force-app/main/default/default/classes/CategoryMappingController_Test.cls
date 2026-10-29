/**
 * @description Test class for CategoryMappingController.
 *              Validates all @AuraEnabled CRUD operations for Account and Employee
 *              category mappings, dashboard stats, lookup searches, and category tree.
 * @author  SFA Development Team
 * @date    2026
 */
@isTest
private class CategoryMappingController_Test {

    @TestSetup
    static void setupTestData() {
        // Territory
        Territory_Master__c territory = new Territory_Master__c(
            Name = 'CMC Test Territory',
            Territory_Code__c = 'TER-CMC01',
            State__c = 'Delhi',
            City__c = 'Delhi',
            Is_Active__c = true
        );
        insert territory;

        // Category hierarchy
        Product_Category__c l1 = new Product_Category__c(
            Name = 'Home Care',
            Category_Code__c = 'CMC-HC',
            Level__c = 'Category',
            Sort_Order__c = 1,
            Is_Active__c = true
        );
        insert l1;

        Product_Category__c l2a = new Product_Category__c(
            Name = 'Detergents',
            Category_Code__c = 'CMC-HC-DET',
            Level__c = 'Sub-Category',
            Parent_Category__c = l1.Id,
            Sort_Order__c = 1,
            Is_Active__c = true
        );
        Product_Category__c l2b = new Product_Category__c(
            Name = 'Cleaning Agents',
            Category_Code__c = 'CMC-HC-CLN',
            Level__c = 'Sub-Category',
            Parent_Category__c = l1.Id,
            Sort_Order__c = 2,
            Is_Active__c = true
        );
        insert new List<Product_Category__c>{ l2a, l2b };

        // Products under sub-categories
        List<Product_Extension__c> products = new List<Product_Extension__c>();
        products.add(new Product_Extension__c(
            Name = 'Detergent Powder 1kg',
            SKU_Code__c = 'CMC-P001',
            Product_Category__c = l2a.Id,
            Is_Active__c = true
        ));
        products.add(new Product_Extension__c(
            Name = 'Floor Cleaner 500ml',
            SKU_Code__c = 'CMC-P002',
            Product_Category__c = l2b.Id,
            Is_Active__c = true
        ));
        insert products;

        // Accounts
        Account acc1 = new Account(
            Name = 'CMC Test Store Alpha',
            Type = 'Retailer',
            Channel__c = 'GT', Outlet_Type__c = 'Grocery',
            Territory__c = territory.Id,
            Is_Active__c = true,
            BillingCity = 'Delhi',
            BillingState = 'Delhi',
            BillingCountry = 'India'
        );
        Account acc2 = new Account(
            Name = 'CMC Test Store Beta',
            Type = 'Retailer',
            Channel__c = 'GT', Outlet_Type__c = 'Grocery',
            Territory__c = territory.Id,
            Is_Active__c = true,
            BillingCity = 'Mumbai',
            BillingState = 'Maharashtra',
            BillingCountry = 'India'
        );
        insert new List<Account>{ acc1, acc2 };

        // Employees
        Employee__c emp1 = new Employee__c(
            First_Name__c = 'CMC',
            Last_Name__c = 'TestEmpAlpha',
            Employee_Code__c = 'EMP-CMC01',
            Is_Active__c = true,
            Territory__c = territory.Id,
            Channels__c = 'GT',
            User__c = UserInfo.getUserId()
        );
        Employee__c emp2 = new Employee__c(
            First_Name__c = 'CMC',
            Last_Name__c = 'TestEmpBeta',
            Employee_Code__c = 'EMP-CMC02',
            Is_Active__c = true,
            Territory__c = territory.Id,
            Channels__c = 'GT'
        );
        insert new List<Employee__c>{ emp1, emp2 };

        // Account Category mappings
        Account_Category__c acMap = new Account_Category__c(
            Account__c = acc1.Id,
            Category__c = l1.Id,
            Is_Active__c = true,
            Effective_From__c = Date.today().addDays(-10)
        );
        insert acMap;

        // Employee Category mappings
        Employee_Category__c ecMap = new Employee_Category__c(
            Employee__c = emp1.Id,
            Category__c = l1.Id,
            Is_Active__c = true,
            Responsibility_Type__c = 'Primary',
            Effective_From__c = Date.today().addDays(-10)
        );
        insert ecMap;
    }

    // ─── getCategoryMappingStats ───────────────────────────────────────

    @isTest
    static void testGetCategoryMappingStats() {
        Test.startTest();
        Map<String, Object> stats = CategoryMappingController.getCategoryMappingStats();
        Test.stopTest();

        System.assertNotEquals(null, stats, 'Stats should not be null');
        System.assert(stats.containsKey('totalAccounts'), 'Should contain totalAccounts');
        System.assert(stats.containsKey('accountsWithCategories'), 'Should contain accountsWithCategories');
        System.assert(stats.containsKey('totalEmployees'), 'Should contain totalEmployees');
        System.assert(stats.containsKey('employeesWithCategories'), 'Should contain employeesWithCategories');
        System.assert(stats.containsKey('totalCategories'), 'Should contain totalCategories');
        System.assert(stats.containsKey('activeAccountMappings'), 'Should contain activeAccountMappings');
        System.assert(stats.containsKey('activeEmployeeMappings'), 'Should contain activeEmployeeMappings');

        // Verify counts are reasonable
        Integer totalCategories = (Integer) stats.get('totalCategories');
        System.assert(totalCategories >= 3, 'Should have at least 3 categories');

        Integer activeAcctMappings = (Integer) stats.get('activeAccountMappings');
        System.assert(activeAcctMappings >= 1, 'Should have at least 1 active account mapping');

        Integer activeEmpMappings = (Integer) stats.get('activeEmployeeMappings');
        System.assert(activeEmpMappings >= 1, 'Should have at least 1 active employee mapping');
    }

    // ─── getAccountCategories ──────────────────────────────────────────

    @isTest
    static void testGetAccountCategories() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'CMC Test Store Alpha'];

        Test.startTest();
        List<Account_Category__c> mappings = CategoryMappingController.getAccountCategories(acc.Id);
        Test.stopTest();

        System.assertEquals(1, mappings.size(), 'Should return 1 mapping for Alpha store');
        System.assertNotEquals(null, mappings[0].Category__c, 'Category should be populated');
    }

    @isTest
    static void testGetAccountCategories_NoMappings() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'CMC Test Store Beta'];

        Test.startTest();
        List<Account_Category__c> mappings = CategoryMappingController.getAccountCategories(acc.Id);
        Test.stopTest();

        System.assertEquals(0, mappings.size(), 'Beta store should have no mappings');
    }

    // ─── getCategoryAccounts ───────────────────────────────────────────

    @isTest
    static void testGetCategoryAccounts() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC'];

        Test.startTest();
        List<Account_Category__c> mappings = CategoryMappingController.getCategoryAccounts(cat.Id);
        Test.stopTest();

        System.assertEquals(1, mappings.size(), 'Should return 1 account for Home Care category');
    }

    // ─── saveAccountCategory ───────────────────────────────────────────

    @isTest
    static void testSaveAccountCategory_Insert() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'CMC Test Store Beta'];
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-DET'];

        Account_Category__c newMapping = new Account_Category__c(
            Account__c = acc.Id,
            Category__c = cat.Id,
            Is_Active__c = true,
            Effective_From__c = Date.today()
        );

        Test.startTest();
        Account_Category__c result = CategoryMappingController.saveAccountCategoryInternal(newMapping);
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Should return an inserted record');
        System.assertEquals(acc.Id, result.Account__c, 'Account should match');
        System.assertEquals(cat.Id, result.Category__c, 'Category should match');
    }

    @isTest
    static void testSaveAccountCategory_Update() {
        Account_Category__c existing = [
            SELECT Id, Notes__c FROM Account_Category__c LIMIT 1
        ];
        existing.Notes__c = 'Updated via test';

        Test.startTest();
        Account_Category__c result = CategoryMappingController.saveAccountCategoryInternal(existing);
        Test.stopTest();

        System.assertEquals('Updated via test', result.Notes__c, 'Notes should be updated');
    }

    // ─── deleteAccountCategory ─────────────────────────────────────────

    @isTest
    static void testDeleteAccountCategory() {
        Account_Category__c existing = [SELECT Id FROM Account_Category__c LIMIT 1];
        Id mappingId = existing.Id;

        Test.startTest();
        CategoryMappingController.deleteAccountCategory(mappingId);
        Test.stopTest();

        List<Account_Category__c> remaining = [
            SELECT Id FROM Account_Category__c WHERE Id = :mappingId
        ];
        System.assertEquals(0, remaining.size(), 'Mapping should be deleted');
    }

    // ─── bulkAssignAccountCategories ───────────────────────────────────

    @isTest
    static void testBulkAssignAccountCategories() {
        Account acc1 = [SELECT Id FROM Account WHERE Name = 'CMC Test Store Alpha'];
        Account acc2 = [SELECT Id FROM Account WHERE Name = 'CMC Test Store Beta'];
        Product_Category__c cat1 = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-DET'];
        Product_Category__c cat2 = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-CLN'];

        List<Id> accountIds = new List<Id>{ acc1.Id, acc2.Id };
        List<Id> categoryIds = new List<Id>{ cat1.Id, cat2.Id };

        Test.startTest();
        List<Account_Category__c> results = CategoryMappingController.bulkAssignAccountCategories(
            accountIds, categoryIds, Date.today(), Date.today().addDays(90)
        );
        Test.stopTest();

        // 2 accounts x 2 categories = 4 mappings
        System.assertEquals(4, results.size(), 'Should create 4 mappings (2 accounts x 2 categories)');
        for (Account_Category__c ac : results) {
            System.assertEquals(true, ac.Is_Active__c, 'All mappings should be active');
        }
    }

    // ─── getEmployeeCategories ─────────────────────────────────────────

    @isTest
    static void testGetEmployeeCategories() {
        Employee__c emp = [SELECT Id FROM Employee__c WHERE Employee_Code__c = 'EMP-CMC01'];

        Test.startTest();
        List<Employee_Category__c> mappings = CategoryMappingController.getEmployeeCategories(emp.Id);
        Test.stopTest();

        System.assertEquals(1, mappings.size(), 'Should return 1 mapping for EMP-CMC01');
        System.assertNotEquals(null, mappings[0].Category__c, 'Category should be populated');
    }

    @isTest
    static void testGetEmployeeCategories_NoMappings() {
        Employee__c emp = [SELECT Id FROM Employee__c WHERE Employee_Code__c = 'EMP-CMC02'];

        Test.startTest();
        List<Employee_Category__c> mappings = CategoryMappingController.getEmployeeCategories(emp.Id);
        Test.stopTest();

        System.assertEquals(0, mappings.size(), 'EMP-CMC02 should have no mappings');
    }

    // ─── getCategoryEmployees ──────────────────────────────────────────

    @isTest
    static void testGetCategoryEmployees() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC'];

        Test.startTest();
        List<Employee_Category__c> mappings = CategoryMappingController.getCategoryEmployees(cat.Id);
        Test.stopTest();

        System.assertEquals(1, mappings.size(), 'Should return 1 employee for Home Care category');
    }

    // ─── saveEmployeeCategory ──────────────────────────────────────────

    @isTest
    static void testSaveEmployeeCategory_Insert() {
        Employee__c emp = [SELECT Id FROM Employee__c WHERE Employee_Code__c = 'EMP-CMC02'];
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-DET'];

        Employee_Category__c newMapping = new Employee_Category__c(
            Employee__c = emp.Id,
            Category__c = cat.Id,
            Is_Active__c = true,
            Responsibility_Type__c = 'Primary',
            Effective_From__c = Date.today()
        );

        Test.startTest();
        Employee_Category__c result = CategoryMappingController.saveEmployeeCategoryInternal(newMapping);
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Should return an inserted record');
        System.assertEquals(emp.Id, result.Employee__c, 'Employee should match');
        System.assertEquals(cat.Id, result.Category__c, 'Category should match');
    }

    @isTest
    static void testSaveEmployeeCategory_Update() {
        Employee_Category__c existing = [
            SELECT Id, Notes__c FROM Employee_Category__c LIMIT 1
        ];
        existing.Notes__c = 'Updated via test';

        Test.startTest();
        Employee_Category__c result = CategoryMappingController.saveEmployeeCategoryInternal(existing);
        Test.stopTest();

        System.assertEquals('Updated via test', result.Notes__c, 'Notes should be updated');
    }

    // ─── deleteEmployeeCategory ────────────────────────────────────────

    @isTest
    static void testDeleteEmployeeCategory() {
        Employee_Category__c existing = [SELECT Id FROM Employee_Category__c LIMIT 1];
        Id mappingId = existing.Id;

        Test.startTest();
        CategoryMappingController.deleteEmployeeCategory(mappingId);
        Test.stopTest();

        List<Employee_Category__c> remaining = [
            SELECT Id FROM Employee_Category__c WHERE Id = :mappingId
        ];
        System.assertEquals(0, remaining.size(), 'Mapping should be deleted');
    }

    // ─── bulkAssignEmployeeCategories ──────────────────────────────────

    @isTest
    static void testBulkAssignEmployeeCategories() {
        Employee__c emp1 = [SELECT Id FROM Employee__c WHERE Employee_Code__c = 'EMP-CMC01'];
        Employee__c emp2 = [SELECT Id FROM Employee__c WHERE Employee_Code__c = 'EMP-CMC02'];
        Product_Category__c cat1 = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-DET'];
        Product_Category__c cat2 = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-CLN'];

        List<Id> employeeIds = new List<Id>{ emp1.Id, emp2.Id };
        List<Id> categoryIds = new List<Id>{ cat1.Id, cat2.Id };

        Test.startTest();
        List<Employee_Category__c> results = CategoryMappingController.bulkAssignEmployeeCategories(
            employeeIds, categoryIds, 'Secondary', Date.today(), Date.today().addDays(90)
        );
        Test.stopTest();

        // 2 employees x 2 categories = 4 mappings
        System.assertEquals(4, results.size(), 'Should create 4 mappings (2 employees x 2 categories)');
        for (Employee_Category__c ec : results) {
            System.assertEquals('Secondary', ec.Responsibility_Type__c, 'All should be Secondary responsibility');
            System.assertEquals(true, ec.Is_Active__c, 'All mappings should be active');
        }
    }

    @isTest
    static void testBulkAssignEmployeeCategories_DefaultResponsibility() {
        Employee__c emp = [SELECT Id FROM Employee__c WHERE Employee_Code__c = 'EMP-CMC02'];
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-CLN'];

        Test.startTest();
        List<Employee_Category__c> results = CategoryMappingController.bulkAssignEmployeeCategories(
            new List<Id>{ emp.Id }, new List<Id>{ cat.Id }, null, Date.today(), null
        );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should create 1 mapping');
        Employee_Category__c created = [
            SELECT Responsibility_Type__c FROM Employee_Category__c WHERE Id = :results[0].Id
        ];
        System.assertEquals('Primary', created.Responsibility_Type__c,
            'Null responsibility type should default to Primary');
    }

    // ─── getCategoryProducts ───────────────────────────────────────────

    @isTest
    static void testGetCategoryProducts_WithoutSubCategories() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC-DET'];

        Test.startTest();
        List<Product_Extension__c> products = CategoryMappingController.getCategoryProducts(cat.Id, false);
        Test.stopTest();

        System.assertEquals(1, products.size(), 'Should return 1 product in Detergents sub-category');
        System.assertEquals('Detergent Powder 1kg', products[0].Name, 'Should be the detergent product');
    }

    @isTest
    static void testGetCategoryProducts_WithSubCategories() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC'];

        Test.startTest();
        List<Product_Extension__c> products = CategoryMappingController.getCategoryProducts(cat.Id, true);
        Test.stopTest();

        // L1 has no direct products, but L2a and L2b each have one
        System.assertEquals(2, products.size(), 'Should return 2 products from sub-categories');
    }

    @isTest
    static void testGetCategoryProducts_NoProducts() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'CMC-HC'];

        Test.startTest();
        // Without sub-categories, L1 category has no direct products
        List<Product_Extension__c> products = CategoryMappingController.getCategoryProducts(cat.Id, false);
        Test.stopTest();

        System.assertEquals(0, products.size(), 'L1 category with no direct products should return empty');
    }

    // ─── searchAccountsForLookup ───────────────────────────────────────

    @isTest
    static void testSearchAccountsForLookup() {
        Test.startTest();
        List<Account> results = CategoryMappingController.searchAccountsForLookup('CMC Test');
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should find 2 matching accounts');
    }

    @isTest
    static void testSearchAccountsForLookup_NoMatch() {
        Test.startTest();
        List<Account> results = CategoryMappingController.searchAccountsForLookup('ZZZNONEXISTENT');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should find no matching accounts');
    }

    @isTest
    static void testSearchAccountsForLookup_PartialMatch() {
        Test.startTest();
        List<Account> results = CategoryMappingController.searchAccountsForLookup('Alpha');
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should find 1 matching account');
        System.assertEquals('CMC Test Store Alpha', results[0].Name, 'Should match Alpha store');
    }

    // ─── searchEmployeesForLookup ──────────────────────────────────────

    @isTest
    static void testSearchEmployeesForLookup_ByLastName() {
        Test.startTest();
        List<Employee__c> results = CategoryMappingController.searchEmployeesForLookup('TestEmp');
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should find 2 matching employees');
    }

    @isTest
    static void testSearchEmployeesForLookup_ByCode() {
        Test.startTest();
        List<Employee__c> results = CategoryMappingController.searchEmployeesForLookup('EMP-CMC01');
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should find 1 matching employee by code');
    }

    @isTest
    static void testSearchEmployeesForLookup_ByFirstName() {
        Test.startTest();
        List<Employee__c> results = CategoryMappingController.searchEmployeesForLookup('CMC');
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should find 2 matching employees by first name');
    }

    @isTest
    static void testSearchEmployeesForLookup_NoMatch() {
        Test.startTest();
        List<Employee__c> results = CategoryMappingController.searchEmployeesForLookup('ZZZNONEXISTENT');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should find no matching employees');
    }

    // ─── getCategoryTree ───────────────────────────────────────────────

    @isTest
    static void testGetCategoryTree() {
        Test.startTest();
        List<Product_Category__c> tree = CategoryMappingController.getCategoryTree();
        Test.stopTest();

        System.assert(tree.size() >= 3, 'Should return at least 3 categories (L1 + 2 L2)');

        // Verify structure
        Boolean hasParent = false;
        Boolean hasChild = false;
        for (Product_Category__c cat : tree) {
            if (cat.Parent_Category__c == null) {
                hasParent = true;
            } else {
                hasChild = true;
            }
            System.assertEquals(true, cat.Is_Active__c, 'All returned categories should be active');
        }
        System.assert(hasParent, 'Tree should contain root categories');
        System.assert(hasChild, 'Tree should contain child categories');
    }
}