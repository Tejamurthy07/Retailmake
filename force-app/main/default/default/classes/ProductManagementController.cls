/**
 * @description Unified controller for the Product Management Hub LWC.
 *              Provides CRUD operations for Products, Categories, Price Lists,
 *              Batch Master, and Priority Sell Configuration in a single management console.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class ProductManagementController {

    // ─── Product Extension CRUD ────────────────────────────────────────

    @AuraEnabled
    public static ProductPageResult getProducts(String searchTerm, String categoryId, String brand, Boolean activeOnly, Integer pageNumber, Integer pageSize) {
        if (pageNumber == null || pageNumber < 1) pageNumber = 1;
        if (pageSize == null || pageSize < 1) pageSize = 25;

        String baseQuery = 'FROM Product_Extension__c WHERE Id != null';
        List<Object> bindVars = new List<Object>();

        if (activeOnly == true) {
            baseQuery += ' AND Is_Active__c = true';
        }
        if (String.isNotBlank(searchTerm)) {
            String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            baseQuery += ' AND (Name LIKE \'' + String.escapeSingleQuotes(searchKey) + '\' OR SKU_Code__c LIKE \'' + String.escapeSingleQuotes(searchKey) + '\')';
        }
        if (String.isNotBlank(categoryId)) {
            // If the selected category is a top-level 'Category' (has
            // sub-categories), include products linked to any of its
            // sub-categories too — otherwise picking 'Foods' returns
            // nothing because products are actually linked to the leaf
            // sub-categories like 'Foods / Biscuits'.
            Set<Id> categoryIds = new Set<Id>{ (Id) categoryId };
            for (Product_Category__c child : [
                SELECT Id FROM Product_Category__c
                WHERE Parent_Category__c = :categoryId
            ]) {
                categoryIds.add(child.Id);
            }
            List<String> quotedIds = new List<String>();
            for (Id cid : categoryIds) {
                quotedIds.add('\'' + String.escapeSingleQuotes((String) cid) + '\'');
            }
            baseQuery += ' AND Product_Category__c IN (' + String.join(quotedIds, ',') + ')';
        }
        if (String.isNotBlank(brand)) {
            baseQuery += ' AND Brand__c = \'' + String.escapeSingleQuotes(brand) + '\'';
        }

        Integer totalCount = Database.countQuery('SELECT COUNT() ' + baseQuery);

        String dataQuery = 'SELECT Id, Name, SKU_Code__c, Brand__c, MRP__c, Unit_Price__c, GST_Rate__c, ' +
                           'Is_Active__c, Unit_of_Measure__c, Base_UOM__c, Base_UOM__r.Name, Base_UOM__r.UOM_Code__c, ' +
                           'Case_Size__c, Min_Order_Qty__c, ' +
                           'Product_Category__c, Product_Category__r.Name, Product_Category__r.Id, HSN_SAC_Code__c, ' +
                           'Barcode_EAN__c, Barcode_UPC__c, Weight__c, Weight_Unit__c, ' +
                           'Is_Returnable__c, Shelf_Life_Days__c, Reorder_Level__c, Reorder_Quantity__c, ' +
                           'Product_Image_URL__c, Sub_Category__c, Channels__c ' +
                           baseQuery + ' ORDER BY Name ASC LIMIT :pageSize OFFSET :offset';

        Integer offset = (pageNumber - 1) * pageSize;
        List<Product_Extension__c> products = Database.query(dataQuery);

        ProductPageResult result = new ProductPageResult();
        result.products = products;
        result.totalCount = totalCount;
        result.pageNumber = pageNumber;
        result.pageSize = pageSize;
        result.totalPages = (Integer) Math.ceil((Decimal) totalCount / pageSize);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getBrands() {
        Set<String> brands = new Set<String>();
        for (AggregateResult ar : [
            SELECT Brand__c b FROM Product_Extension__c
            WHERE Brand__c != null
            GROUP BY Brand__c
            ORDER BY Brand__c ASC
            LIMIT 500
        ]) {
            String b = (String) ar.get('b');
            if (String.isNotBlank(b)) brands.add(b);
        }
        List<String> result = new List<String>(brands);
        result.sort();
        return result;
    }

    // ── Namespace-tolerant SObject building ─────────────────────────────
    // The LWC sends records as JSON with UNqualified field keys; in the
    // managed-package namespace those must be re-applied under the real field
    // API names or DML drops them (INVALID_FIELD_FOR_INSERT_UPDATE / blank save).
    private static SObject buildSObject(Schema.SObjectType t, Map<String, Object> m) {
        SObject rec = t.newSObject();
        if (m == null) return rec;
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();
        for (String key : m.keySet()) {
            if (key == 'sobjectType' || key == 'attributes' || m.get(key) == null) continue;
            Schema.SObjectField sf = resolveField(fmap, key);
            if (sf == null) continue;
            Schema.DescribeFieldResult dfr = sf.getDescribe();
            try { rec.put(dfr.getName(), coerceValue(dfr.getType(), m.get(key))); } catch (Exception e) {}
        }
        return rec;
    }
    private static Schema.SObjectField resolveField(Map<String, Schema.SObjectField> fmap, String name) {
        if (String.isBlank(name) || fmap == null) return null;
        Schema.SObjectField f = fmap.get(name);
        if (f != null) return f;
        String bare = unqualify(name);
        for (String key : fmap.keySet()) { if (unqualify(key).equalsIgnoreCase(bare)) return fmap.get(key); }
        return null;
    }
    private static String unqualify(String api) {
        if (String.isBlank(api)) return api;
        if (api.endsWithIgnoreCase('__c') && api.split('__').size() >= 3) return api.substringAfter('__');
        return api;
    }
    private static Object coerceValue(Schema.DisplayType t, Object val) {
        if (val == null) return null;
        String s = String.valueOf(val);
        if (String.isBlank(s)) return null;
        if (t == Schema.DisplayType.Boolean) return (val instanceof Boolean) ? val : Boolean.valueOf(s);
        if (t == Schema.DisplayType.Date) return Date.valueOf(s.substring(0, 10));
        if (t == Schema.DisplayType.DateTime) return Datetime.valueOf(s.replace('T', ' ').replace('Z', ''));
        if (t == Schema.DisplayType.Double || t == Schema.DisplayType.Currency || t == Schema.DisplayType.Percent) return Decimal.valueOf(s);
        if (t == Schema.DisplayType.Integer) return Integer.valueOf(s);
        if (t == Schema.DisplayType.Reference || t == Schema.DisplayType.Id) return (Id) s;
        return s;
    }

    @AuraEnabled
    public static Product_Extension__c saveProduct(String productJson) {
        return saveProductInternal((Product_Extension__c) buildSObject(
            Product_Extension__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(productJson)));
    }

    public static Product_Extension__c saveProductInternal(Product_Extension__c product) {
        try {
            Schema.DescribeSObjectResult d = Product_Extension__c.SObjectType.getDescribe();
            if (product.Id == null && !d.isCreateable()) {
                throw new AuraHandledException('You do not have permission to create products.');
            }
            if (product.Id != null && !d.isUpdateable()) {
                throw new AuraHandledException('You do not have permission to update products.');
            }
            upsert product;
            return [SELECT Id, Name, SKU_Code__c, Brand__c, MRP__c, Unit_Price__c, GST_Rate__c,
                           Is_Active__c, Unit_of_Measure__c, Base_UOM__c, Base_UOM__r.Name, Base_UOM__r.UOM_Code__c,
                           Case_Size__c, Min_Order_Qty__c,
                           Product_Category__c, Product_Category__r.Name, HSN_SAC_Code__c,
                           Barcode_EAN__c, Barcode_UPC__c, Weight__c, Weight_Unit__c,
                           Is_Returnable__c, Shelf_Life_Days__c, Reorder_Level__c, Reorder_Quantity__c,
                           Product_Image_URL__c, Sub_Category__c
                    FROM Product_Extension__c WHERE Id = :product.Id];
        } catch (DmlException e) {
            String msg = e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage();
            AuraHandledException ex = new AuraHandledException(msg);
            ex.setMessage(msg);
            throw ex;
        } catch (Exception e) {
            AuraHandledException ex = new AuraHandledException(e.getMessage());
            ex.setMessage(e.getMessage());
            throw ex;
        }
    }

    @AuraEnabled
    public static void deleteProduct(Id productId) {
        if (!Product_Extension__c.SObjectType.getDescribe().isDeletable()) {
            throw new AuraHandledException('You do not have permission to delete products.');
        }
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE Id = :productId LIMIT 1];
        delete p;
    }

    // ─── Product Category CRUD ─────────────────────────────────────────

    @AuraEnabled
    public static List<Product_Category__c> getCategories(String searchTerm, String level, Boolean activeOnly) {
        String query = 'SELECT Id, Name, Category_Code__c, Level__c, Is_Active__c, Sort_Order__c, ' +
                       'Parent_Category__c, Parent_Category__r.Name ' +
                       'FROM Product_Category__c WHERE Id != null';
        if (activeOnly == true) {
            query += ' AND Is_Active__c = true';
        }
        if (String.isNotBlank(level)) {
            query += ' AND Level__c = :level';
        }
        if (String.isNotBlank(searchTerm)) {
            String searchKey = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' AND (Name LIKE :searchKey OR Category_Code__c LIKE :searchKey)';
        }
        query += ' ORDER BY Sort_Order__c ASC, Name ASC LIMIT 500';
        return Database.query(query);
    }

    @AuraEnabled
    public static Product_Category__c saveCategory(String categoryJson) {
        return saveCategoryInternal((Product_Category__c) buildSObject(
            Product_Category__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(categoryJson)));
    }

    public static Product_Category__c saveCategoryInternal(Product_Category__c category) {
        try {
            Schema.DescribeSObjectResult d = Product_Category__c.SObjectType.getDescribe();
            if (category.Id == null && !d.isCreateable()) {
                throw new AuraHandledException('You do not have permission to create categories.');
            }
            if (category.Id != null && !d.isUpdateable()) {
                throw new AuraHandledException('You do not have permission to update categories.');
            }
            upsert category;
            return [SELECT Id, Name, Category_Code__c, Level__c, Is_Active__c, Sort_Order__c,
                           Parent_Category__c, Parent_Category__r.Name
                    FROM Product_Category__c WHERE Id = :category.Id];
        } catch (DmlException e) {
            // Surface the first validation / DML message cleanly so the LWC
            // toast shows the human-readable rule text instead of a raw
            // fetchResponse blob. Salesforce has a known quirk where
            // AuraHandledException's getMessage() returns "Script-thrown
            // exception" unless setMessage() is called.
            String msg = e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage();
            AuraHandledException ex = new AuraHandledException(msg);
            ex.setMessage(msg);
            throw ex;
        } catch (Exception e) {
            AuraHandledException ex = new AuraHandledException(e.getMessage());
            ex.setMessage(e.getMessage());
            throw ex;
        }
    }

    @AuraEnabled
    public static void deleteCategory(Id categoryId) {
        if (!Product_Category__c.SObjectType.getDescribe().isDeletable()) {
            throw new AuraHandledException('You do not have permission to delete categories.');
        }
        // Cascade delete category mappings that reference this category
        delete [SELECT Id FROM Account_Category__c WHERE Category__c = :categoryId];
        delete [SELECT Id FROM Employee_Category__c WHERE Category__c = :categoryId];
        Product_Category__c c = [SELECT Id FROM Product_Category__c WHERE Id = :categoryId LIMIT 1];
        delete c;
    }

    // ─── Price List CRUD ───────────────────────────────────────────────

    @AuraEnabled
    public static PriceListPageResult getPriceLists(String productId, String channel, String region, String categoryId, String territoryId, String customerId, String priorityFilter, Boolean activeOnly, Integer pageNumber, Integer pageSize, String searchTerm) {
        if (pageNumber == null || pageNumber < 1) pageNumber = 1;
        if (pageSize == null || pageSize < 1) pageSize = 25;

        String baseQuery = 'FROM Price_List__c WHERE Id != null';

        if (activeOnly == true) {
            baseQuery += ' AND Is_Active__c = true';
        }
        if (String.isNotBlank(productId)) {
            baseQuery += ' AND Product_Ext__c = \'' + String.escapeSingleQuotes(productId) + '\'';
        }
        if (String.isNotBlank(searchTerm)) {
            String searchKey = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            baseQuery += ' AND (Product_Ext__r.Name LIKE :searchKey OR Product_Ext__r.SKU_Code__c LIKE :searchKey OR Customer__r.Name LIKE :searchKey OR Name LIKE :searchKey)';
        }
        if (String.isNotBlank(channel)) {
            baseQuery += ' AND Channel__c = \'' + String.escapeSingleQuotes(channel) + '\'';
        }
        if (String.isNotBlank(region)) {
            String regionKey = '%' + String.escapeSingleQuotes(region) + '%';
            baseQuery += ' AND Region__c LIKE \'' + String.escapeSingleQuotes(regionKey) + '\'';
        }
        if (String.isNotBlank(categoryId)) {
            baseQuery += ' AND Category__c = \'' + String.escapeSingleQuotes(categoryId) + '\'';
        }
        if (String.isNotBlank(territoryId)) {
            baseQuery += ' AND Territory__c = \'' + String.escapeSingleQuotes(territoryId) + '\'';
        }
        if (String.isNotBlank(customerId)) {
            baseQuery += ' AND Customer__c = \'' + String.escapeSingleQuotes(customerId) + '\'';
        }
        if (String.isNotBlank(priorityFilter)) {
            baseQuery += ' AND Priority__c = ' + Integer.valueOf(priorityFilter);
        }

        Integer totalCount = Database.countQuery('SELECT COUNT() ' + baseQuery);

        Integer offset = (pageNumber - 1) * pageSize;
        String dataQuery = 'SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                           'Channel__c, Region__c, Unit_Price__c, Price_Type__c, ' +
                           'Customer__c, Customer__r.Name, Category__c, Category__r.Name, ' +
                           'Territory__c, Territory__r.Name, Priority__c, ' +
                           'Effective_From__c, Effective_To__c, Is_Active__c, Min_Qty__c ' +
                           baseQuery + ' ORDER BY Priority__c ASC, Product_Ext__r.Name ASC, Channel__c ASC LIMIT :pageSize OFFSET :offset';

        List<Price_List__c> priceLists = Database.query(dataQuery);

        PriceListPageResult result = new PriceListPageResult();
        result.priceLists = priceLists;
        result.totalCount = totalCount;
        result.pageNumber = pageNumber;
        result.pageSize = pageSize;
        result.totalPages = (Integer) Math.ceil((Decimal) totalCount / pageSize);
        return result;
    }

    @AuraEnabled
    public static Price_List__c savePriceList(String priceListJson) {
        return savePriceListInternal((Price_List__c) buildSObject(
            Price_List__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(priceListJson)));
    }

    public static Price_List__c savePriceListInternal(Price_List__c priceList) {
        upsert priceList;
        return [SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                       Channel__c, Region__c, Unit_Price__c, Price_Type__c,
                       Customer__c, Customer__r.Name, Category__c, Category__r.Name,
                       Territory__c, Territory__r.Name, Priority__c,
                       Effective_From__c, Effective_To__c, Is_Active__c, Min_Qty__c
                FROM Price_List__c WHERE Id = :priceList.Id];
    }

    @AuraEnabled
    public static void deletePriceList(Id priceListId) {
        Price_List__c pl = [SELECT Id FROM Price_List__c WHERE Id = :priceListId LIMIT 1];
        delete pl;
    }

    // ─── Pricebook Priority Configuration (Read-only) ───────────────────

    @AuraEnabled(cacheable=true)
    public static List<Pricebook_Priority__mdt> getPricebookPriorities() {
        return [SELECT Id, MasterLabel, DeveloperName, Priority_Order__c,
                       Has_Customer__c, Has_Category__c, Has_Territory__c, Has_Channel__c,
                       Is_Active__c
                FROM Pricebook_Priority__mdt
                WHERE Is_Active__c = true
                ORDER BY Priority_Order__c ASC];
    }

    // ─── Batch Master CRUD ─────────────────────────────────────────────

    @AuraEnabled
    public static List<Batch_Master__c> getBatches(String productId, String status, String searchTerm) {
        String query = 'SELECT Id, Name, Batch_Number__c, Product_Ext__c, Product_Ext__r.Name, ' +
                       'Product_Ext__r.SKU_Code__c, Manufacturing_Date__c, Expiry_Date__c, ' +
                       'Status__c, Quantity_Manufactured__c, Shelf_Life_Days__c, ' +
                       'Shelf_Life_Remaining_Pct__c, Is_Near_Expiry__c ' +
                       'FROM Batch_Master__c WHERE Id != null';

        if (String.isNotBlank(productId)) {
            query += ' AND Product_Ext__c = \'' + String.escapeSingleQuotes(productId) + '\'';
        }
        if (String.isNotBlank(status)) {
            query += ' AND Status__c = \'' + String.escapeSingleQuotes(status) + '\'';
        }
        if (String.isNotBlank(searchTerm)) {
            String searchKey = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' AND (Product_Ext__r.Name LIKE :searchKey OR Product_Ext__r.SKU_Code__c LIKE :searchKey OR Batch_Number__c LIKE :searchKey)';
        }
        query += ' ORDER BY Expiry_Date__c ASC LIMIT 200';

        return Database.query(query);
    }

    @AuraEnabled
    public static Batch_Master__c saveBatch(String batchJson) {
        return saveBatchInternal((Batch_Master__c) buildSObject(
            Batch_Master__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(batchJson)));
    }

    public static Batch_Master__c saveBatchInternal(Batch_Master__c batch) {
        upsert batch;
        return [SELECT Id, Name, Batch_Number__c, Product_Ext__c, Product_Ext__r.Name,
                       Product_Ext__r.SKU_Code__c, Manufacturing_Date__c, Expiry_Date__c,
                       Status__c, Quantity_Manufactured__c, Shelf_Life_Days__c,
                       Shelf_Life_Remaining_Pct__c, Is_Near_Expiry__c
                FROM Batch_Master__c WHERE Id = :batch.Id];
    }

    @AuraEnabled
    public static void deleteBatch(Id batchId) {
        Batch_Master__c b = [SELECT Id FROM Batch_Master__c WHERE Id = :batchId LIMIT 1];
        delete b;
    }

    // ─── Must-Sell Configuration CRUD ──────────────────────────────────

    @AuraEnabled
    public static List<Must_Sell_Config__c> getMustSellConfigs(Boolean activeOnly, String channel, String classification, String searchTerm) {
        String query = 'SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                       'Classification__c, Channel__c, Customer_Type__c, Territory__c, Territory__r.Name, ' +
                       'Start_Date__c, End_Date__c, Is_Active__c, Min_Qty__c ' +
                       'FROM Must_Sell_Config__c WHERE Id != null';

        if (activeOnly == true) {
            query += ' AND Is_Active__c = true';
        }
        if (String.isNotBlank(channel)) {
            query += ' AND Channel__c = :channel';
        }
        if (String.isNotBlank(classification)) {
            query += ' AND Classification__c = :classification';
        }
        if (String.isNotBlank(searchTerm)) {
            String searchKey = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' AND (Product_Ext__r.Name LIKE :searchKey OR Product_Ext__r.SKU_Code__c LIKE :searchKey)';
        }
        query += ' ORDER BY Product_Ext__r.Name ASC LIMIT 200';

        return Database.query(query);
    }

    @AuraEnabled
    public static Must_Sell_Config__c saveMustSellConfig(String configJson) {
        return saveMustSellConfigInternal((Must_Sell_Config__c) buildSObject(
            Must_Sell_Config__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(configJson)));
    }

    public static Must_Sell_Config__c saveMustSellConfigInternal(Must_Sell_Config__c config) {
        upsert config;
        return [SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                       Classification__c, Channel__c, Customer_Type__c, Territory__c, Territory__r.Name,
                       Start_Date__c, End_Date__c, Is_Active__c, Min_Qty__c
                FROM Must_Sell_Config__c WHERE Id = :config.Id];
    }

    @AuraEnabled
    public static void deleteMustSellConfig(Id configId) {
        Must_Sell_Config__c c = [SELECT Id FROM Must_Sell_Config__c WHERE Id = :configId LIMIT 1];
        delete c;
    }

    // ─── Price Change Log (Read-only) ──────────────────────────────────

    @AuraEnabled
    public static List<Price_Change_Log__c> getPriceChangeLogs(String productId) {
        String query = 'SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                       'Old_Price__c, New_Price__c, Change_Date__c, Change_Reason__c, Changed_By__c, ' +
                       'Channel__c, Region__c, Customer__c, Customer__r.Name, ' +
                       'Category__c, Category__r.Name, Territory__c, Territory__r.Name, ' +
                       'Priority__c, Price_List__c ' +
                       'FROM Price_Change_Log__c';
        if (String.isNotBlank(productId)) {
            query += ' WHERE Product_Ext__c = \'' + String.escapeSingleQuotes(productId) + '\'';
        }
        query += ' ORDER BY Change_Date__c DESC LIMIT 100';
        return Database.query(query);
    }

    // ─── Dashboard Stats ───────────────────────────────────────────────

    @AuraEnabled
    public static DashboardStats getDashboardStats() {
        DashboardStats stats = new DashboardStats();
        stats.totalProducts = [SELECT COUNT() FROM Product_Extension__c];
        stats.activeProducts = [SELECT COUNT() FROM Product_Extension__c WHERE Is_Active__c = true];
        stats.totalCategories = [SELECT COUNT() FROM Product_Category__c];
        stats.activePriceLists = [SELECT COUNT() FROM Price_List__c WHERE Is_Active__c = true];
        stats.activeBatches = [SELECT COUNT() FROM Batch_Master__c WHERE Status__c = 'Active'];
        stats.nearExpiryBatches = [SELECT COUNT() FROM Batch_Master__c WHERE Is_Near_Expiry__c = true AND Status__c = 'Active'];
        // Expired = expiry date already past. The Is_Near_Expiry__c formula
        // deliberately excludes these (it requires days-to-expiry >= 0), so
        // expired batches were invisible on the dashboard. Count them in
        // their own tile.
        stats.expiredBatches = [SELECT COUNT() FROM Batch_Master__c WHERE Expiry_Date__c < TODAY];
        stats.mustSellConfigs = [SELECT COUNT() FROM Must_Sell_Config__c WHERE Is_Active__c = true];
        stats.totalUOMs = [SELECT COUNT() FROM UOM__c WHERE Is_Active__c = true];
        stats.totalConversions = [SELECT COUNT() FROM UOM_Conversion__c WHERE Is_Active__c = true];
        return stats;
    }

    // ─── Product Lookup for related objects ─────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Product_Extension__c> searchProductsForLookup(String searchTerm) {
        String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [SELECT Id, Name, SKU_Code__c, Brand__c, MRP__c
                FROM Product_Extension__c
                WHERE Is_Active__c = true
                  AND (Name LIKE :searchKey OR SKU_Code__c LIKE :searchKey)
                ORDER BY Name ASC
                LIMIT 20];
    }

    // ─── Territory Lookup for Must-Sell config and Price Lists ──────────

    @AuraEnabled(cacheable=true)
    public static List<Territory_Master__c> searchTerritoriesForLookup(String searchTerm) {
        String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [SELECT Id, Name, Territory_Code__c
                FROM Territory_Master__c
                WHERE Is_Active__c = true
                  AND (Name LIKE :searchKey OR Territory_Code__c LIKE :searchKey)
                ORDER BY Name ASC
                LIMIT 20];
    }

    // ─── Category Lookup for Price Lists ────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Product_Category__c> searchCategoriesForLookup(String searchTerm) {
        String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [SELECT Id, Name, Category_Code__c, Level__c
                FROM Product_Category__c
                WHERE Is_Active__c = true
                  AND (Name LIKE :searchKey OR Category_Code__c LIKE :searchKey)
                ORDER BY Name ASC
                LIMIT 20];
    }

    // ─── Customer (Account) Lookup for Price Lists ──────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Account> searchCustomersForLookup(String searchTerm) {
        String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [SELECT Id, Name, AccountNumber
                FROM Account
                WHERE Name LIKE :searchKey
                ORDER BY Name ASC
                LIMIT 20];
    }

    // ─── UOM Master CRUD ─────────────────────────────────────────────────

    @AuraEnabled
    public static List<UOM__c> getUOMs() {
        return [
            SELECT Id, Name, UOM_Code__c, UOM_Type__c, Is_Base_Unit__c,
                   Is_Active__c, Description__c
            FROM UOM__c
            ORDER BY UOM_Type__c, Name
            LIMIT 200
        ];
    }

    @AuraEnabled
    public static UOM__c saveUOM(String uomJson) {
        return saveUOMInternal((UOM__c) buildSObject(
            UOM__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(uomJson)));
    }

    public static UOM__c saveUOMInternal(UOM__c uom) {
        upsert uom;
        return [
            SELECT Id, Name, UOM_Code__c, UOM_Type__c, Is_Base_Unit__c,
                   Is_Active__c, Description__c
            FROM UOM__c WHERE Id = :uom.Id
        ];
    }

    @AuraEnabled
    public static void deleteUOM(Id uomId) {
        delete [SELECT Id FROM UOM__c WHERE Id = :uomId LIMIT 1];
    }

    // ─── UOM Conversion CRUD ──────────────────────────────────────────────

    @AuraEnabled
    public static List<UOM_Conversion__c> getUOMConversions(String productId, String searchTerm, Boolean activeOnly) {
        String query = 'SELECT Id, Name, From_UOM__c, From_UOM__r.Name, From_UOM__r.UOM_Code__c, ' +
                       'To_UOM__c, To_UOM__r.Name, To_UOM__r.UOM_Code__c, ' +
                       'Conversion_Factor__c, Inverse_Conversion_Factor__c, ' +
                       'Product__c, Product__r.Name, Is_Active__c ' +
                       'FROM UOM_Conversion__c WHERE Id != null';

        if (String.isNotBlank(productId)) {
            query += ' AND (Product__c = \'' + String.escapeSingleQuotes(productId) + '\' OR Product__c = null)';
        }
        if (activeOnly == true) {
            query += ' AND Is_Active__c = true';
        }
        if (String.isNotBlank(searchTerm)) {
            String searchKey = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' AND (Product__r.Name LIKE :searchKey OR From_UOM__r.Name LIKE :searchKey OR To_UOM__r.Name LIKE :searchKey)';
        }
        query += ' ORDER BY Product__c NULLS LAST, From_UOM__r.Name, To_UOM__r.Name LIMIT 200';
        return Database.query(query);
    }

    @AuraEnabled
    public static UOM_Conversion__c saveUOMConversion(String conversionJson) {
        return saveUOMConversionInternal((UOM_Conversion__c) buildSObject(
            UOM_Conversion__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(conversionJson)));
    }

    public static UOM_Conversion__c saveUOMConversionInternal(UOM_Conversion__c conversion) {
        if (conversion.From_UOM__c == conversion.To_UOM__c) {
            throw new AuraHandledException('From UOM and To UOM must be different.');
        }
        if (conversion.Conversion_Factor__c == null || conversion.Conversion_Factor__c <= 0) {
            throw new AuraHandledException('Conversion factor must be a positive number.');
        }

        // Duplicate check: same From + To + Product must not already exist
        String dupQuery = 'SELECT Id FROM UOM_Conversion__c WHERE From_UOM__c = :fromId AND To_UOM__c = :toId';
        Id fromId = conversion.From_UOM__c;
        Id toId = conversion.To_UOM__c;
        Id prodId = conversion.Product__c;
        Id recId = conversion.Id;

        if (prodId != null) {
            dupQuery += ' AND Product__c = :prodId';
        } else {
            dupQuery += ' AND Product__c = null';
        }
        if (recId != null) {
            dupQuery += ' AND Id != :recId';
        }
        dupQuery += ' LIMIT 1';

        List<UOM_Conversion__c> existing = Database.query(dupQuery);
        if (!existing.isEmpty()) {
            throw new AuraHandledException('A conversion rule already exists for this From UOM, To UOM, and Product combination.');
        }

        conversion.Inverse_Conversion_Factor__c = (1 / conversion.Conversion_Factor__c).setScale(4, RoundingMode.HALF_UP);
        upsert conversion;
        return [
            SELECT Id, Name, From_UOM__c, From_UOM__r.Name, From_UOM__r.UOM_Code__c,
                   To_UOM__c, To_UOM__r.Name, To_UOM__r.UOM_Code__c,
                   Conversion_Factor__c, Inverse_Conversion_Factor__c,
                   Product__c, Product__r.Name, Is_Active__c
            FROM UOM_Conversion__c WHERE Id = :conversion.Id
        ];
    }

    @AuraEnabled
    public static void deleteUOMConversion(Id conversionId) {
        delete [SELECT Id FROM UOM_Conversion__c WHERE Id = :conversionId LIMIT 1];
    }

    // ─── UOM Lookup for dropdowns ──────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<UOM__c> getActiveUOMsForLookup() {
        return [
            SELECT Id, Name, UOM_Code__c, UOM_Type__c
            FROM UOM__c
            WHERE Is_Active__c = true
            ORDER BY UOM_Type__c, Name
        ];
    }

    // ─── Inner Classes ─────────────────────────────────────────────────

    public class ProductPageResult {
        @AuraEnabled public List<Product_Extension__c> products;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer totalPages;
    }

    public class PriceListPageResult {
        @AuraEnabled public List<Price_List__c> priceLists;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer pageNumber;
        @AuraEnabled public Integer pageSize;
        @AuraEnabled public Integer totalPages;
    }

    public class DashboardStats {
        @AuraEnabled public Integer totalProducts;
        @AuraEnabled public Integer activeProducts;
        @AuraEnabled public Integer totalCategories;
        @AuraEnabled public Integer activePriceLists;
        @AuraEnabled public Integer activeBatches;
        @AuraEnabled public Integer nearExpiryBatches;
        @AuraEnabled public Integer expiredBatches;
        @AuraEnabled public Integer mustSellConfigs;
        @AuraEnabled public Integer totalUOMs;
        @AuraEnabled public Integer totalConversions;
    }
}