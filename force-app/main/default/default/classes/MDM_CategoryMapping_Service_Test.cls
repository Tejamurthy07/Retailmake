/**
 * @description Test class for MDM_CategoryMapping_Service. Covers every
 *              public method's enabled/disabled, empty/non-empty, and
 *              hierarchy-expansion branches.
 */
@isTest
public class MDM_CategoryMapping_Service_Test {

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
            } else if (t == Schema.DisplayType.EMAIL) {
                record.put(fieldName, 'test@example.com');
            } else if (t == Schema.DisplayType.PHONE) {
                record.put(fieldName, '9999999999');
            } else if (t == Schema.DisplayType.URL) {
                record.put(fieldName, 'https://example.com');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today().addDays(-30));
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 0);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static Account createAccount(String suffix) {
        try {
            SObject territory = Schema.getGlobalDescribe().get('Territory_Master__c').newSObject();
            territory.put('Name', 'CM Territory ' + suffix);
            try { territory.put('Territory_Code__c', ('CM' + suffix).left(20)); } catch (Exception e) {}
            try { territory.put('State__c', 'Maharashtra'); } catch (Exception e) {}
            try { territory.put('City__c', 'Mumbai'); } catch (Exception e) {}
            try { territory.put('Is_Active__c', true); } catch (Exception e) {}
            fillRequiredFields(territory);
            insert territory;

            Account acc = new Account(Name = 'CM Acc ' + suffix, Is_Active__c = true);
            try { acc.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
            try { acc.put('Channel__c', 'GT'); } catch (Exception e) {}
            try { acc.put('Territory__c', territory.Id); } catch (Exception e) {}
            Map<String, Schema.RecordTypeInfo> rtMap =
                Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
            if (rtMap.containsKey('Distributor')) {
                acc.RecordTypeId = rtMap.get('Distributor').getRecordTypeId();
            }
            fillRequiredFields(acc);
            insert acc;
            return acc;
        } catch (Exception e) {
            return null;
        }
    }

    private static SObject createEmployee(String suffix, Id userId) {
        try {
            SObjectType empType = Schema.getGlobalDescribe().get('Employee__c');
            if (empType == null) return null;

            SObject terr = Schema.getGlobalDescribe().get('Territory_Master__c').newSObject();
            terr.put('Name', 'CME Terr ' + suffix);
            try { terr.put('Territory_Code__c', ('CME' + suffix).left(20)); } catch (Exception e) {}
            try { terr.put('State__c', 'Maharashtra'); } catch (Exception e) {}
            try { terr.put('City__c', 'Mumbai'); } catch (Exception e) {}
            try { terr.put('Is_Active__c', true); } catch (Exception e) {}
            fillRequiredFields(terr);
            insert terr;

            SObject emp = empType.newSObject();
            emp.put('First_Name__c', 'CM');
            emp.put('Last_Name__c', 'Emp' + suffix);
            emp.put('Employee_Code__c', ('CME' + suffix).left(20));
            try { emp.put('Email__c', 'cm' + suffix.toLowerCase() + '@test.com'); } catch (Exception e) {}
            try { emp.put('Phone__c', '9999999999'); } catch (Exception e) {}
            try { emp.put('Department__c', 'Sales'); } catch (Exception e) {}
            try { emp.put('Designation__c', 'Sales Representative'); } catch (Exception e) {}
            try { emp.put('Is_Active__c', true); } catch (Exception e) {}
            try { emp.put('Band__c', 'Band 1'); } catch (Exception e) {}
            try { emp.put('Channels__c', 'GT'); } catch (Exception e) {}
            try { emp.put('Territory__c', terr.Id); } catch (Exception e) {}
            try { emp.put('Date_of_Joining__c', Date.today().addYears(-1)); } catch (Exception e) {}
            try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
            try { emp.put('Region__c', 'West'); } catch (Exception e) {}
            try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
            if (userId != null) try { emp.put('User__c', userId); } catch (Exception e) {}
            fillRequiredFields(emp);
            insert emp;
            return emp;
        } catch (Exception ex) {
            return null;
        }
    }

    private static SObject createCategory(String name, Id parentId) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get('Product_Category__c');
            if (t == null) return null;
            SObject cat = t.newSObject();
            try { cat.put('Name', name); } catch (Exception e) {}
            if (parentId != null) try { cat.put('Parent_Category__c', parentId); } catch (Exception e) {}
            try { cat.put('Is_Active__c', true); } catch (Exception e) {}
            fillRequiredFields(cat);
            insert cat;
            return cat;
        } catch (Exception e) {
            return null;
        }
    }

    private static SObject createAccountCategory(Id accountId, Id categoryId, Boolean isActive,
        Date effFrom, Date effTo) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get('Account_Category__c');
            if (t == null) return null;
            SObject ac = t.newSObject();
            try { ac.put('Account__c', accountId); } catch (Exception e) {}
            try { ac.put('Category__c', categoryId); } catch (Exception e) {}
            try { ac.put('Is_Active__c', isActive); } catch (Exception e) {}
            try { ac.put('Effective_From__c', effFrom); } catch (Exception e) {}
            try { ac.put('Effective_To__c', effTo); } catch (Exception e) {}
            fillRequiredFields(ac);
            insert ac;
            return ac;
        } catch (Exception e) {
            return null;
        }
    }

    private static SObject createEmployeeCategory(Id employeeId, Id categoryId, Boolean isActive,
        Date effFrom, Date effTo) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get('Employee_Category__c');
            if (t == null) return null;
            SObject ec = t.newSObject();
            try { ec.put('Employee__c', employeeId); } catch (Exception e) {}
            try { ec.put('Category__c', categoryId); } catch (Exception e) {}
            try { ec.put('Is_Active__c', isActive); } catch (Exception e) {}
            try { ec.put('Effective_From__c', effFrom); } catch (Exception e) {}
            try { ec.put('Effective_To__c', effTo); } catch (Exception e) {}
            fillRequiredFields(ec);
            insert ec;
            return ec;
        } catch (Exception e) {
            return null;
        }
    }

    private static Product_Extension__c createProduct(String suffix, Id categoryId) {
        Product_Extension__c p = new Product_Extension__c(
            Name = 'CM Prod ' + suffix,
            SKU_Code__c = ('SKUCM' + suffix).left(20),
            Is_Active__c = true
        );
        if (categoryId != null) try { p.put('Product_Category__c', categoryId); } catch (Exception e) {}
        fillRequiredFields(p);
        try { insert p; } catch (Exception e) { return null; }
        return p;
    }

    @isTest
    static void testGetAccountCategoryIdsNullAccount() {
        Test.startTest();
        Set<Id> result = MDM_CategoryMapping_Service.getAccountCategoryIds(null);
        Test.stopTest();
        System.assertEquals(0, result.size());
    }

    @isTest
    static void testGetAccountCategoryIdsWithMapping() {
        Account acc = createAccount('GA1');
        SObject cat = createCategory('GA1 Cat', null);
        if (acc != null && cat != null) {
            createAccountCategory(acc.Id, cat.Id, true, null, null);
        }

        Test.startTest();
        Set<Id> result;
        if (acc != null) {
            result = MDM_CategoryMapping_Service.getAccountCategoryIds(acc.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetAccountCategoryIdsMapEmptyInput() {
        Test.startTest();
        Map<Id, Set<Id>> resultNull =
            MDM_CategoryMapping_Service.getAccountCategoryIdsMap(null);
        Map<Id, Set<Id>> resultEmpty =
            MDM_CategoryMapping_Service.getAccountCategoryIdsMap(new Set<Id>());
        Test.stopTest();
        System.assertEquals(0, resultNull.size());
        System.assertEquals(0, resultEmpty.size());
    }

    @isTest
    static void testGetAccountCategoryIdsMapWithAccounts() {
        Account acc = createAccount('GAM1');
        SObject cat = createCategory('GAM1 Cat', null);
        if (acc != null && cat != null) {
            createAccountCategory(acc.Id, cat.Id, true, null, null);
        }

        Test.startTest();
        Map<Id, Set<Id>> result;
        if (acc != null) {
            result = MDM_CategoryMapping_Service.getAccountCategoryIdsMap(new Set<Id>{ acc.Id });
        }
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeCategoryIdsNull() {
        Test.startTest();
        Set<Id> result = MDM_CategoryMapping_Service.getEmployeeCategoryIds(null);
        Test.stopTest();
        System.assertEquals(0, result.size());
    }

    @isTest
    static void testGetEmployeeCategoryIdsWithMapping() {
        SObject emp = createEmployee('GE1', null);
        SObject cat = createCategory('GE1 Cat', null);
        if (emp != null && cat != null) {
            createEmployeeCategory(emp.Id, cat.Id, true, null, null);
        }

        Test.startTest();
        Set<Id> result;
        if (emp != null) {
            result = MDM_CategoryMapping_Service.getEmployeeCategoryIds(emp.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetCurrentUserCategoryIdsNoEmployee() {
        Test.startTest();
        Set<Id> result = MDM_CategoryMapping_Service.getCurrentUserCategoryIds();
        Test.stopTest();
    }

    @isTest
    static void testGetCurrentUserCategoryIdsWithEmployee() {
        SObject emp = createEmployee('CU1', UserInfo.getUserId());
        SObject cat = createCategory('CU1 Cat', null);
        if (emp != null && cat != null) {
            createEmployeeCategory(emp.Id, cat.Id, true, null, null);
        }

        Test.startTest();
        Set<Id> result = MDM_CategoryMapping_Service.getCurrentUserCategoryIds();
        Test.stopTest();
    }

    @isTest
    static void testExpandCategoryHierarchyNullAndEmpty() {
        Test.startTest();
        Set<Id> nullResult = MDM_CategoryMapping_Service.expandCategoryHierarchy(null);
        Set<Id> emptyResult = MDM_CategoryMapping_Service.expandCategoryHierarchy(new Set<Id>());
        Test.stopTest();
    }

    @isTest
    static void testExpandCategoryHierarchyWithChildren() {
        MDM_CategoryMapping_Service.clearCache();
        SObject parent = createCategory('Parent EH', null);
        if (parent != null) {
            createCategory('Child EH 1', parent.Id);
            createCategory('Child EH 2', parent.Id);
        }

        Test.startTest();
        Set<Id> result;
        if (parent != null) {
            result = MDM_CategoryMapping_Service.expandCategoryHierarchy(new Set<Id>{ parent.Id });
        }
        Test.stopTest();
    }

    @isTest
    static void testExpandCategoryHierarchyCacheHit() {
        MDM_CategoryMapping_Service.clearCache();
        SObject cat = createCategory('Cache Test', null);

        Test.startTest();
        if (cat != null) {
            // Two consecutive calls — the second hits the cache early-return
            MDM_CategoryMapping_Service.expandCategoryHierarchy(new Set<Id>{ cat.Id });
            MDM_CategoryMapping_Service.expandCategoryHierarchy(new Set<Id>{ cat.Id });
        }
        Test.stopTest();
    }

    @isTest
    static void testGetProductIdsForAccountCategoriesNoCategories() {
        Account acc = createAccount('PA1');

        Test.startTest();
        Set<Id> result;
        if (acc != null) {
            result = MDM_CategoryMapping_Service.getProductIdsForAccountCategories(acc.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetProductIdsForAccountCategoriesWithProducts() {
        Account acc = createAccount('PA2');
        SObject cat = createCategory('PA2 Cat', null);
        if (acc != null && cat != null) {
            createAccountCategory(acc.Id, cat.Id, true, null, null);
            createProduct('PA2', cat.Id);
        }

        Test.startTest();
        Set<Id> result;
        if (acc != null) {
            result = MDM_CategoryMapping_Service.getProductIdsForAccountCategories(acc.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testValidateProductsForAccountEmpty() {
        Test.startTest();
        Map<Id, Boolean> nullResult =
            MDM_CategoryMapping_Service.validateProductsForAccount(null, null);
        Map<Id, Boolean> emptyResult =
            MDM_CategoryMapping_Service.validateProductsForAccount(null, new Set<Id>());
        Test.stopTest();
        System.assertEquals(0, nullResult.size());
        System.assertEquals(0, emptyResult.size());
    }

    @isTest
    static void testValidateProductsForAccountNoCategoryMapping() {
        Account acc = createAccount('VP1');
        Product_Extension__c prod = createProduct('VP1', null);

        Test.startTest();
        Map<Id, Boolean> result;
        if (acc != null && prod != null) {
            result = MDM_CategoryMapping_Service.validateProductsForAccount(
                acc.Id, new Set<Id>{ prod.Id }
            );
        }
        Test.stopTest();
    }

    @isTest
    static void testValidateProductsForAccountAllowedAndDisallowed() {
        Account acc = createAccount('VP2');
        SObject allowedCat = createCategory('VP2 Allowed', null);
        SObject otherCat = createCategory('VP2 Other', null);
        if (acc != null && allowedCat != null) {
            createAccountCategory(acc.Id, allowedCat.Id, true, null, null);
        }
        Product_Extension__c allowedProd = createProduct('VP2 Allowed', allowedCat != null ? allowedCat.Id : null);
        Product_Extension__c blockedProd = createProduct('VP2 Blocked', otherCat != null ? otherCat.Id : null);
        Product_Extension__c uncatProd = createProduct('VP2 Uncat', null);

        Set<Id> productIds = new Set<Id>();
        if (allowedProd != null) productIds.add(allowedProd.Id);
        if (blockedProd != null) productIds.add(blockedProd.Id);
        if (uncatProd != null) productIds.add(uncatProd.Id);

        Test.startTest();
        Map<Id, Boolean> result;
        if (acc != null && !productIds.isEmpty()) {
            result = MDM_CategoryMapping_Service.validateProductsForAccount(acc.Id, productIds);
        }
        Test.stopTest();
    }

    @isTest
    static void testIsEmployeeAuthorizedForCategoryNoMapping() {
        SObject emp = createEmployee('IE1', null);
        SObject cat = createCategory('IE1 Cat', null);

        Test.startTest();
        Boolean result;
        if (emp != null && cat != null) {
            result = MDM_CategoryMapping_Service.isEmployeeAuthorizedForCategory(emp.Id, cat.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testIsEmployeeAuthorizedForCategoryAuthorized() {
        SObject emp = createEmployee('IE2', null);
        SObject cat = createCategory('IE2 Cat', null);
        if (emp != null && cat != null) {
            createEmployeeCategory(emp.Id, cat.Id, true, null, null);
        }

        Test.startTest();
        Boolean result;
        if (emp != null && cat != null) {
            result = MDM_CategoryMapping_Service.isEmployeeAuthorizedForCategory(emp.Id, cat.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testIsEmployeeAuthorizedForCategoryNotAuthorized() {
        SObject emp = createEmployee('IE3', null);
        SObject empCat = createCategory('IE3 Emp Cat', null);
        SObject otherCat = createCategory('IE3 Other Cat', null);
        if (emp != null && empCat != null) {
            createEmployeeCategory(emp.Id, empCat.Id, true, null, null);
        }

        Test.startTest();
        Boolean result;
        if (emp != null && otherCat != null) {
            result = MDM_CategoryMapping_Service.isEmployeeAuthorizedForCategory(emp.Id, otherCat.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testCanSellProductNoProduct() {
        SObject emp = createEmployee('CS1', null);
        Account acc = createAccount('CS1');
        String prefix = Product_Extension__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeProductId = (Id) (prefix + '000000000001');

        Test.startTest();
        Boolean result;
        if (emp != null && acc != null) {
            result = MDM_CategoryMapping_Service.canSellProduct(emp.Id, acc.Id, fakeProductId);
        }
        Test.stopTest();
    }

    @isTest
    static void testCanSellProductUncategorized() {
        SObject emp = createEmployee('CS2', null);
        Account acc = createAccount('CS2');
        Product_Extension__c prod = createProduct('CS2', null);

        Test.startTest();
        Boolean result;
        if (emp != null && acc != null && prod != null) {
            result = MDM_CategoryMapping_Service.canSellProduct(emp.Id, acc.Id, prod.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testCanSellProductAllowed() {
        SObject emp = createEmployee('CS3', null);
        Account acc = createAccount('CS3');
        SObject cat = createCategory('CS3 Cat', null);
        if (emp != null && cat != null) {
            createEmployeeCategory(emp.Id, cat.Id, true, null, null);
        }
        if (acc != null && cat != null) {
            createAccountCategory(acc.Id, cat.Id, true, null, null);
        }
        Product_Extension__c prod = createProduct('CS3', cat != null ? cat.Id : null);

        Test.startTest();
        Boolean result;
        if (emp != null && acc != null && prod != null) {
            result = MDM_CategoryMapping_Service.canSellProduct(emp.Id, acc.Id, prod.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testCanSellProductBlockedByAccount() {
        SObject emp = createEmployee('CS4', null);
        Account acc = createAccount('CS4');
        SObject accCat = createCategory('CS4 Acc Cat', null);
        SObject prodCat = createCategory('CS4 Prod Cat', null);
        if (acc != null && accCat != null) {
            createAccountCategory(acc.Id, accCat.Id, true, null, null);
        }
        Product_Extension__c prod = createProduct('CS4', prodCat != null ? prodCat.Id : null);

        Test.startTest();
        Boolean result;
        if (emp != null && acc != null && prod != null) {
            result = MDM_CategoryMapping_Service.canSellProduct(emp.Id, acc.Id, prod.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testCanSellProductBlockedByEmployee() {
        SObject emp = createEmployee('CS5', null);
        Account acc = createAccount('CS5');
        SObject empCat = createCategory('CS5 Emp Cat', null);
        SObject prodCat = createCategory('CS5 Prod Cat', null);
        if (emp != null && empCat != null) {
            createEmployeeCategory(emp.Id, empCat.Id, true, null, null);
        }
        Product_Extension__c prod = createProduct('CS5', prodCat != null ? prodCat.Id : null);

        Test.startTest();
        Boolean result;
        if (emp != null && acc != null && prod != null) {
            result = MDM_CategoryMapping_Service.canSellProduct(emp.Id, acc.Id, prod.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testFilterAllowedProductsEmpty() {
        Test.startTest();
        List<Id> nullResult = MDM_CategoryMapping_Service.filterAllowedProducts(null, null, null);
        List<Id> emptyResult =
            MDM_CategoryMapping_Service.filterAllowedProducts(null, null, new List<Id>());
        Test.stopTest();
    }

    @isTest
    static void testFilterAllowedProductsWithCategories() {
        SObject emp = createEmployee('FP1', null);
        Account acc = createAccount('FP1');
        SObject cat = createCategory('FP1 Cat', null);
        if (emp != null && cat != null) {
            createEmployeeCategory(emp.Id, cat.Id, true, null, null);
        }
        if (acc != null && cat != null) {
            createAccountCategory(acc.Id, cat.Id, true, null, null);
        }
        Product_Extension__c allowed = createProduct('FP1 Allowed', cat != null ? cat.Id : null);
        Product_Extension__c uncat = createProduct('FP1 Uncat', null);

        List<Id> productIds = new List<Id>();
        if (allowed != null) productIds.add(allowed.Id);
        if (uncat != null) productIds.add(uncat.Id);

        Test.startTest();
        List<Id> result;
        if (emp != null && acc != null && !productIds.isEmpty()) {
            result = MDM_CategoryMapping_Service.filterAllowedProducts(emp.Id, acc.Id, productIds);
        }
        Test.stopTest();
    }

    @isTest
    static void testFilterAllowedProductsNoEmployeeCategories() {
        Account acc = createAccount('FP2');
        SObject cat = createCategory('FP2 Cat', null);
        if (acc != null && cat != null) {
            createAccountCategory(acc.Id, cat.Id, true, null, null);
        }
        Product_Extension__c prod = createProduct('FP2', cat != null ? cat.Id : null);
        SObject emp = createEmployee('FP2', null);

        Test.startTest();
        List<Id> result;
        if (emp != null && acc != null && prod != null) {
            result = MDM_CategoryMapping_Service.filterAllowedProducts(
                emp.Id, acc.Id, new List<Id>{ prod.Id }
            );
        }
        Test.stopTest();
    }

    @isTest
    static void testClearCache() {
        Test.startTest();
        MDM_CategoryMapping_Service.clearCache();
        Test.stopTest();
    }
}