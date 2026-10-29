public with sharing class MDM_CategoryMapping_Service {

    private static final String FEATURE_CODE = 'MDM-004';

    private static Map<Id, Set<Id>> categoryChildrenCache;

    public static Set<Id> getAccountCategoryIds(Id accountId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE) || accountId == null) {
            return new Set<Id>();
        }
        Date today = Date.today();
        Set<Id> categoryIds = new Set<Id>();
        for (Account_Category__c ac : [
            SELECT Category__c FROM Account_Category__c
            WHERE Account__c = :accountId
            AND Is_Active__c = true
            AND (Effective_From__c = null OR Effective_From__c <= :today)
            AND (Effective_To__c = null OR Effective_To__c >= :today)
        ]) {
            if (ac.Category__c != null) {
                categoryIds.add(ac.Category__c);
            }
        }
        return categoryIds;
    }

    public static Map<Id, Set<Id>> getAccountCategoryIdsMap(Set<Id> accountIds) {
        Map<Id, Set<Id>> result = new Map<Id, Set<Id>>();
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE) || accountIds == null || accountIds.isEmpty()) {
            return result;
        }
        for (Id accId : accountIds) {
            result.put(accId, new Set<Id>());
        }
        Date today = Date.today();
        for (Account_Category__c ac : [
            SELECT Account__c, Category__c FROM Account_Category__c
            WHERE Account__c IN :accountIds
            AND Is_Active__c = true
            AND (Effective_From__c = null OR Effective_From__c <= :today)
            AND (Effective_To__c = null OR Effective_To__c >= :today)
        ]) {
            if (ac.Category__c != null) {
                result.get(ac.Account__c).add(ac.Category__c);
            }
        }
        return result;
    }

    public static Set<Id> getEmployeeCategoryIds(Id employeeId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE) || employeeId == null) {
            return new Set<Id>();
        }
        Date today = Date.today();
        Set<Id> categoryIds = new Set<Id>();
        for (Employee_Category__c ec : [
            SELECT Category__c FROM Employee_Category__c
            WHERE Employee__c = :employeeId
            AND Is_Active__c = true
            AND (Effective_From__c = null OR Effective_From__c <= :today)
            AND (Effective_To__c = null OR Effective_To__c >= :today)
        ]) {
            if (ec.Category__c != null) {
                categoryIds.add(ec.Category__c);
            }
        }
        return categoryIds;
    }

    public static Set<Id> getCurrentUserCategoryIds() {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            return new Set<Id>();
        }
        List<Employee__c> emps = [
            SELECT Id FROM Employee__c WHERE User__c = :UserInfo.getUserId() AND Is_Active__c = true LIMIT 1
        ];
        if (emps.isEmpty()) {
            return new Set<Id>();
        }
        return getEmployeeCategoryIds(emps[0].Id);
    }

    public static Set<Id> expandCategoryHierarchy(Set<Id> categoryIds) {
        if (categoryIds == null || categoryIds.isEmpty()) {
            return categoryIds;
        }
        loadCategoryHierarchy();
        Set<Id> expanded = new Set<Id>(categoryIds);
        for (Id catId : categoryIds) {
            if (categoryChildrenCache.containsKey(catId)) {
                expanded.addAll(categoryChildrenCache.get(catId));
            }
        }
        return expanded;
    }

    public static Set<Id> getProductIdsForAccountCategories(Id accountId) {
        Set<Id> categoryIds = getAccountCategoryIds(accountId);
        if (categoryIds.isEmpty()) {
            return new Set<Id>();
        }
        Set<Id> expandedIds = expandCategoryHierarchy(categoryIds);
        Set<Id> productIds = new Set<Id>();
        for (Product_Extension__c pe : [
            SELECT Id FROM Product_Extension__c
            WHERE Product_Category__c IN :expandedIds AND Is_Active__c = true
        ]) {
            productIds.add(pe.Id);
        }
        return productIds;
    }

    public static Map<Id, Boolean> validateProductsForAccount(Id accountId, Set<Id> productIds) {
        Map<Id, Boolean> result = new Map<Id, Boolean>();
        if (productIds == null || productIds.isEmpty()) {
            return result;
        }
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            for (Id pId : productIds) {
                result.put(pId, true);
            }
            return result;
        }
        Set<Id> categoryIds = getAccountCategoryIds(accountId);
        if (categoryIds.isEmpty()) {
            for (Id pId : productIds) {
                result.put(pId, true);
            }
            return result;
        }
        Set<Id> expandedIds = expandCategoryHierarchy(categoryIds);
        for (Product_Extension__c pe : [
            SELECT Id, Product_Category__c FROM Product_Extension__c WHERE Id IN :productIds
        ]) {
            if (pe.Product_Category__c == null) {
                result.put(pe.Id, true);
            } else {
                result.put(pe.Id, expandedIds.contains(pe.Product_Category__c));
            }
        }
        for (Id pId : productIds) {
            if (!result.containsKey(pId)) {
                result.put(pId, false);
            }
        }
        return result;
    }

    public static Boolean isEmployeeAuthorizedForCategory(Id employeeId, Id categoryId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            return true;
        }
        Set<Id> empCatIds = getEmployeeCategoryIds(employeeId);
        if (empCatIds.isEmpty()) {
            return true;
        }
        Set<Id> expandedIds = expandCategoryHierarchy(empCatIds);
        return expandedIds.contains(categoryId);
    }

    public static Boolean canSellProduct(Id employeeId, Id accountId, Id productId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            return true;
        }
        List<Product_Extension__c> prods = [
            SELECT Id, Product_Category__c FROM Product_Extension__c WHERE Id = :productId LIMIT 1
        ];
        if (prods.isEmpty() || prods[0].Product_Category__c == null) {
            return true;
        }
        Id categoryId = prods[0].Product_Category__c;

        Set<Id> acctCatIds = getAccountCategoryIds(accountId);
        if (!acctCatIds.isEmpty()) {
            Set<Id> expandedAcct = expandCategoryHierarchy(acctCatIds);
            if (!expandedAcct.contains(categoryId)) {
                return false;
            }
        }

        Set<Id> empCatIds = getEmployeeCategoryIds(employeeId);
        if (!empCatIds.isEmpty()) {
            Set<Id> expandedEmp = expandCategoryHierarchy(empCatIds);
            if (!expandedEmp.contains(categoryId)) {
                return false;
            }
        }

        return true;
    }

    public static List<Id> filterAllowedProducts(Id employeeId, Id accountId, List<Id> productIds) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE) || productIds == null || productIds.isEmpty()) {
            return productIds;
        }
        Set<Id> productIdSet = new Set<Id>(productIds);
        Map<Id, Boolean> allowed = validateProductsForAccount(accountId, productIdSet);

        Set<Id> empCatIds = getEmployeeCategoryIds(employeeId);
        Set<Id> expandedEmp = empCatIds.isEmpty() ? new Set<Id>() : expandCategoryHierarchy(empCatIds);

        Map<Id, Id> productCatMap = new Map<Id, Id>();
        if (!empCatIds.isEmpty()) {
            for (Product_Extension__c pe : [
                SELECT Id, Product_Category__c FROM Product_Extension__c WHERE Id IN :productIdSet
            ]) {
                productCatMap.put(pe.Id, pe.Product_Category__c);
            }
        }

        List<Id> filtered = new List<Id>();
        for (Id pId : productIds) {
            Boolean acctAllowed = allowed.containsKey(pId) ? allowed.get(pId) : true;
            Boolean empAllowed = true;
            if (!empCatIds.isEmpty() && productCatMap.containsKey(pId) && productCatMap.get(pId) != null) {
                empAllowed = expandedEmp.contains(productCatMap.get(pId));
            }
            if (acctAllowed && empAllowed) {
                filtered.add(pId);
            }
        }
        return filtered;
    }

    private static void loadCategoryHierarchy() {
        if (categoryChildrenCache != null) {
            return;
        }
        categoryChildrenCache = new Map<Id, Set<Id>>();
        for (Product_Category__c cat : [
            SELECT Id, Parent_Category__c FROM Product_Category__c WHERE Parent_Category__c != null
        ]) {
            if (!categoryChildrenCache.containsKey(cat.Parent_Category__c)) {
                categoryChildrenCache.put(cat.Parent_Category__c, new Set<Id>());
            }
            categoryChildrenCache.get(cat.Parent_Category__c).add(cat.Id);
        }
    }

    @TestVisible
    private static void clearCache() {
        categoryChildrenCache = null;
    }
}