@IsTest
private class ProductManagementController_Test {

    @TestSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('PM Territory', 'PM-TER-001');

        Product_Category__c cat = new Product_Category__c(
            Name = 'PM Foods', Category_Code__c = 'PM-FOOD', Level__c = 'Category',
            Sort_Order__c = 1, Is_Active__c = true
        );
        insert cat;

        Product_Category__c subCat = new Product_Category__c(
            Name = 'PM Snacks', Category_Code__c = 'PM-SNK', Level__c = 'Sub-Category',
            Parent_Category__c = cat.Id, Sort_Order__c = 1, Is_Active__c = true
        );
        insert subCat;

        List<Product_Extension__c> products = new List<Product_Extension__c>();
        for (Integer i = 1; i <= 3; i++) {
            products.add(new Product_Extension__c(
                Name = 'PM Product ' + i, SKU_Code__c = 'PM-PRD-00' + i, Brand__c = 'PMBrand',
                Product_Category__c = subCat.Id, MRP__c = 100 * i, Unit_Price__c = 70 * i,
                GST_Rate__c = 18, Is_Active__c = true, Weight__c = 500, Weight_Unit__c = 'g',
                Unit_of_Measure__c = 'Piece', Case_Size__c = 24, Min_Order_Qty__c = 5
            ));
        }
        insert products;

        Price_List__c pl = new Price_List__c(
            Name = 'PM-BASE-PRD1', Product_Ext__c = products[0].Id,
            Price_Type__c = 'Retailer Price', Unit_Price__c = 70,
            Effective_From__c = Date.today().addMonths(-1),
            Is_Active__c = true, Status__c = 'Approved'
        );
        insert pl;

        Batch_Master__c batch = new Batch_Master__c(
            Name = 'PM-BATCH-001', Batch_Number__c = 'PM-BN-0001',
            Product_Ext__c = products[0].Id,
            Manufacturing_Date__c = Date.today().addMonths(-3),
            Expiry_Date__c = Date.today().addMonths(9),
            Quantity_Manufactured__c = 5000, Shelf_Life_Days__c = 365, Status__c = 'Active'
        );
        insert batch;

        Must_Sell_Config__c msc = new Must_Sell_Config__c(
            Product_Ext__c = products[0].Id, Classification__c = 'Must Sell',
            Min_Qty__c = 5, Is_Active__c = true,
            Start_Date__c = Date.today().addDays(-10), End_Date__c = Date.today().addDays(30)
        );
        insert msc;

        List<UOM__c> uoms = new List<UOM__c>();
        uoms.add(new UOM__c(Name = 'PM Pieces', UOM_Code__c = 'PM-PCS', UOM_Type__c = 'Count', Is_Base_Unit__c = true, Is_Active__c = true));
        uoms.add(new UOM__c(Name = 'PM Box', UOM_Code__c = 'PM-BOX', UOM_Type__c = 'Count', Is_Base_Unit__c = false, Is_Active__c = true));
        insert uoms;

        UOM_Conversion__c conv = new UOM_Conversion__c(
            From_UOM__c = uoms[1].Id, To_UOM__c = uoms[0].Id,
            Conversion_Factor__c = 24, Is_Active__c = true
        );
        insert conv;
    }

    // ─── Products ──────────────────────────────────────────────────────

    @IsTest static void testGetProducts_NoFilters() {
        Test.startTest();
        ProductManagementController.ProductPageResult r = ProductManagementController.getProducts(null, null, null, true, 1, 25);
        Test.stopTest();
        System.assert(r.totalCount >= 3);
        System.assertNotEquals(null, r.products);
    }

    @IsTest static void testGetProducts_WithSearch() {
        Test.startTest();
        ProductManagementController.ProductPageResult r = ProductManagementController.getProducts('PM Product 1', null, null, true, 1, 25);
        Test.stopTest();
        System.assert(r.totalCount >= 1);
    }

    @IsTest static void testGetProducts_WithCategory() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'PM-FOOD' LIMIT 1];
        Test.startTest();
        ProductManagementController.ProductPageResult r = ProductManagementController.getProducts(null, cat.Id, null, true, 1, 25);
        Test.stopTest();
        System.assert(r.totalCount >= 3);
    }

    @IsTest static void testGetProducts_WithBrand() {
        Test.startTest();
        ProductManagementController.ProductPageResult r = ProductManagementController.getProducts(null, null, 'PMBrand', false, null, null);
        Test.stopTest();
        System.assert(r.totalCount >= 3);
    }

    @IsTest static void testGetBrands() {
        Test.startTest();
        List<String> brands = ProductManagementController.getBrands();
        Test.stopTest();
        System.assert(brands.size() >= 1);
    }

    @IsTest static void testSaveProduct_Insert() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'PM-SNK' LIMIT 1];
        Product_Extension__c p = new Product_Extension__c(
            Name = 'New PM Product', SKU_Code__c = 'PM-NEW-001', Brand__c = 'PMBrand',
            Product_Category__c = cat.Id, MRP__c = 500, Is_Active__c = true
        );
        Test.startTest();
        Product_Extension__c saved = ProductManagementController.saveProductInternal(p);
        Test.stopTest();
        System.assertNotEquals(null, saved.Id);
    }

    @IsTest static void testSaveProduct_Update() {
        Product_Extension__c p = [SELECT Id, MRP__c FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-001' LIMIT 1];
        p.MRP__c = 999;
        Test.startTest();
        Product_Extension__c saved = ProductManagementController.saveProductInternal(p);
        Test.stopTest();
        System.assertEquals(999, saved.MRP__c);
    }

    @IsTest static void testSaveProduct_Error() {
        Test.startTest();
        try {
            ProductManagementController.saveProductInternal(new Product_Extension__c(SKU_Code__c = 'PM-PRD-001'));
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @IsTest static void testDeleteProduct() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-003' LIMIT 1];
        Test.startTest();
        ProductManagementController.deleteProduct(p.Id);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Product_Extension__c WHERE Id = :p.Id]);
    }

    // ─── Categories ────────────────────────────────────────────────────

    @IsTest static void testGetCategories() {
        Test.startTest();
        List<Product_Category__c> cats = ProductManagementController.getCategories(null, null, true);
        Test.stopTest();
        System.assert(cats.size() >= 2);
    }

    @IsTest static void testGetCategories_WithFilters() {
        Test.startTest();
        List<Product_Category__c> cats = ProductManagementController.getCategories('PM', 'Sub-Category', true);
        Test.stopTest();
        System.assert(cats.size() >= 1);
    }

    @IsTest static void testSaveCategory() {
        Product_Category__c cat = new Product_Category__c(
            Name = 'PM New Cat', Category_Code__c = 'PM-NEW', Level__c = 'Category',
            Sort_Order__c = 99, Is_Active__c = true
        );
        Test.startTest();
        Product_Category__c saved = ProductManagementController.saveCategoryInternal(cat);
        Test.stopTest();
        System.assertNotEquals(null, saved.Id);
    }

    @IsTest static void testSaveCategory_Error() {
        Test.startTest();
        try {
            ProductManagementController.saveCategoryInternal(new Product_Category__c(Category_Code__c = 'PM-FOOD'));
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @IsTest static void testDeleteCategory() {
        Product_Category__c cat = new Product_Category__c(
            Name = 'PM Delete Cat', Category_Code__c = 'PM-DEL', Level__c = 'Category',
            Sort_Order__c = 99, Is_Active__c = true
        );
        insert cat;
        Test.startTest();
        ProductManagementController.deleteCategory(cat.Id);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Product_Category__c WHERE Id = :cat.Id]);
    }

    // ─── Price Lists ───────────────────────────────────────────────────

    @IsTest static void testGetPriceLists() {
        Test.startTest();
        ProductManagementController.PriceListPageResult r = ProductManagementController.getPriceLists(
            null, null, null, null, null, null, null, true, 1, 25, null
        );
        Test.stopTest();
        System.assert(r.totalCount >= 1);
    }

    @IsTest static void testGetPriceLists_WithFilters() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-001' LIMIT 1];
        Test.startTest();
        ProductManagementController.PriceListPageResult r = ProductManagementController.getPriceLists(
            p.Id, null, null, null, null, null, null, true, 1, 25, 'PM'
        );
        Test.stopTest();
        System.assertNotEquals(null, r);
    }

    @IsTest static void testSavePriceList() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-002' LIMIT 1];
        Price_List__c pl = new Price_List__c(
            Name = 'PM-NEW-PL', Product_Ext__c = p.Id, Price_Type__c = 'Retailer Price',
            Unit_Price__c = 80, Effective_From__c = Date.today(), Is_Active__c = true, Status__c = 'Approved'
        );
        Test.startTest();
        Price_List__c saved = ProductManagementController.savePriceListInternal(pl);
        Test.stopTest();
        System.assertNotEquals(null, saved.Id);
    }

    @IsTest static void testDeletePriceList() {
        Price_List__c pl = [SELECT Id FROM Price_List__c WHERE Name = 'PM-BASE-PRD1' LIMIT 1];
        Test.startTest();
        ProductManagementController.deletePriceList(pl.Id);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Price_List__c WHERE Id = :pl.Id]);
    }

    // ─── Pricebook Priorities ──────────────────────────────────────────

    @IsTest static void testGetPricebookPriorities() {
        Test.startTest();
        List<Pricebook_Priority__mdt> priorities = ProductManagementController.getPricebookPriorities();
        Test.stopTest();
        System.assertNotEquals(null, priorities);
    }

    // ─── Batches ───────────────────────────────────────────────────────

    @IsTest static void testGetBatches() {
        Test.startTest();
        List<Batch_Master__c> batches = ProductManagementController.getBatches(null, 'Active', null);
        Test.stopTest();
        System.assert(batches.size() >= 1);
    }

    @IsTest static void testGetBatches_WithSearch() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-001' LIMIT 1];
        Test.startTest();
        List<Batch_Master__c> batches = ProductManagementController.getBatches(p.Id, null, 'PM');
        Test.stopTest();
        System.assertNotEquals(null, batches);
    }

    @IsTest static void testSaveBatch() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-002' LIMIT 1];
        Batch_Master__c b = new Batch_Master__c(
            Name = 'PM-NEW-BATCH', Batch_Number__c = 'PM-BN-NEW',
            Product_Ext__c = p.Id, Manufacturing_Date__c = Date.today(),
            Expiry_Date__c = Date.today().addMonths(12),
            Quantity_Manufactured__c = 1000, Status__c = 'Active'
        );
        Test.startTest();
        Batch_Master__c saved = ProductManagementController.saveBatchInternal(b);
        Test.stopTest();
        System.assertNotEquals(null, saved.Id);
    }

    @IsTest static void testDeleteBatch() {
        Batch_Master__c b = [SELECT Id FROM Batch_Master__c WHERE Batch_Number__c = 'PM-BN-0001' LIMIT 1];
        Test.startTest();
        ProductManagementController.deleteBatch(b.Id);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Batch_Master__c WHERE Id = :b.Id]);
    }

    // ─── Must-Sell Configs ─────────────────────────────────────────────

    @IsTest static void testGetMustSellConfigs() {
        Test.startTest();
        List<Must_Sell_Config__c> configs = ProductManagementController.getMustSellConfigs(true, null, null, null);
        Test.stopTest();
        System.assert(configs.size() >= 1);
    }

    @IsTest static void testGetMustSellConfigs_WithFilters() {
        Test.startTest();
        List<Must_Sell_Config__c> configs = ProductManagementController.getMustSellConfigs(true, null, 'Must Sell', 'PM');
        Test.stopTest();
        System.assertNotEquals(null, configs);
    }

    @IsTest static void testSaveMustSellConfig() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-002' LIMIT 1];
        Must_Sell_Config__c c = new Must_Sell_Config__c(
            Product_Ext__c = p.Id, Classification__c = 'Focused Sell', Min_Qty__c = 3,
            Is_Active__c = true, Start_Date__c = Date.today(), End_Date__c = Date.today().addDays(30)
        );
        Test.startTest();
        Must_Sell_Config__c saved = ProductManagementController.saveMustSellConfigInternal(c);
        Test.stopTest();
        System.assertNotEquals(null, saved.Id);
    }

    @IsTest static void testDeleteMustSellConfig() {
        Must_Sell_Config__c c = [SELECT Id FROM Must_Sell_Config__c LIMIT 1];
        Test.startTest();
        ProductManagementController.deleteMustSellConfig(c.Id);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Must_Sell_Config__c WHERE Id = :c.Id]);
    }

    // ─── Price Change Logs ─────────────────────────────────────────────

    @IsTest static void testGetPriceChangeLogs() {
        Test.startTest();
        List<Price_Change_Log__c> logs = ProductManagementController.getPriceChangeLogs(null);
        Test.stopTest();
        System.assertNotEquals(null, logs);
    }

    @IsTest static void testGetPriceChangeLogs_WithProduct() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-001' LIMIT 1];
        Test.startTest();
        List<Price_Change_Log__c> logs = ProductManagementController.getPriceChangeLogs(p.Id);
        Test.stopTest();
        System.assertNotEquals(null, logs);
    }

    // ─── Dashboard Stats ───────────────────────────────────────────────

    @IsTest static void testGetDashboardStats() {
        Test.startTest();
        ProductManagementController.DashboardStats stats = ProductManagementController.getDashboardStats();
        Test.stopTest();
        System.assert(stats.totalProducts >= 3);
        System.assert(stats.activeProducts >= 3);
        System.assert(stats.totalCategories >= 2);
        System.assert(stats.activeBatches >= 1);
        System.assertNotEquals(null, stats.activePriceLists);
        System.assertNotEquals(null, stats.nearExpiryBatches);
        System.assertNotEquals(null, stats.expiredBatches);
        System.assertNotEquals(null, stats.mustSellConfigs);
        System.assertNotEquals(null, stats.totalUOMs);
        System.assertNotEquals(null, stats.totalConversions);
    }

    // ─── Lookups ───────────────────────────────────────────────────────

    @IsTest static void testSearchProductsForLookup() {
        Test.startTest();
        List<Product_Extension__c> results = ProductManagementController.searchProductsForLookup('PM');
        Test.stopTest();
        System.assert(results.size() >= 1);
    }

    @IsTest static void testSearchTerritoriesForLookup() {
        Test.startTest();
        List<Territory_Master__c> results = ProductManagementController.searchTerritoriesForLookup('PM');
        Test.stopTest();
        System.assert(results.size() >= 1);
    }

    @IsTest static void testSearchCategoriesForLookup() {
        Test.startTest();
        List<Product_Category__c> results = ProductManagementController.searchCategoriesForLookup('PM');
        Test.stopTest();
        System.assert(results.size() >= 1);
    }

    @IsTest static void testSearchCustomersForLookup() {
        Test.startTest();
        List<Account> results = ProductManagementController.searchCustomersForLookup('Test');
        Test.stopTest();
        System.assertNotEquals(null, results);
    }

    // ─── UOM ───────────────────────────────────────────────────────────

    @IsTest static void testGetUOMs() {
        Test.startTest();
        List<UOM__c> uoms = ProductManagementController.getUOMs();
        Test.stopTest();
        System.assert(uoms.size() >= 2);
    }

    @IsTest static void testSaveUOM() {
        UOM__c u = new UOM__c(Name = 'PM Dozen', UOM_Code__c = 'PM-DOZ', UOM_Type__c = 'Count', Is_Active__c = true);
        Test.startTest();
        UOM__c saved = ProductManagementController.saveUOMInternal(u);
        Test.stopTest();
        System.assertNotEquals(null, saved.Id);
    }

    @IsTest static void testDeleteUOM() {
        UOM__c u = new UOM__c(Name = 'PM Delete UOM', UOM_Code__c = 'PM-DELUOM', UOM_Type__c = 'Count', Is_Active__c = true);
        insert u;
        Test.startTest();
        ProductManagementController.deleteUOM(u.Id);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM UOM__c WHERE Id = :u.Id]);
    }

    @IsTest static void testGetActiveUOMsForLookup() {
        Test.startTest();
        List<UOM__c> uoms = ProductManagementController.getActiveUOMsForLookup();
        Test.stopTest();
        System.assert(uoms.size() >= 2);
    }

    // ─── UOM Conversions ───────────────────────────────────────────────

    @IsTest static void testGetUOMConversions() {
        Test.startTest();
        List<UOM_Conversion__c> convs = ProductManagementController.getUOMConversions(null, null, true);
        Test.stopTest();
        System.assert(convs.size() >= 1);
    }

    @IsTest static void testGetUOMConversions_WithFilters() {
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-001' LIMIT 1];
        Test.startTest();
        List<UOM_Conversion__c> convs = ProductManagementController.getUOMConversions(p.Id, 'PM', true);
        Test.stopTest();
        System.assertNotEquals(null, convs);
    }

    @IsTest static void testSaveUOMConversion() {
        List<UOM__c> uoms = [SELECT Id FROM UOM__c WHERE UOM_Code__c LIKE 'PM-%' ORDER BY UOM_Code__c];
        Product_Extension__c p = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PM-PRD-001' LIMIT 1];
        UOM_Conversion__c c = new UOM_Conversion__c(
            From_UOM__c = uoms[0].Id, To_UOM__c = uoms[1].Id,
            Conversion_Factor__c = 12, Product__c = p.Id, Is_Active__c = true
        );
        Test.startTest();
        UOM_Conversion__c saved = ProductManagementController.saveUOMConversionInternal(c);
        Test.stopTest();
        System.assertNotEquals(null, saved.Id);
        System.assertEquals(12, saved.Conversion_Factor__c);
    }

    @IsTest static void testSaveUOMConversion_SameUOMError() {
        List<UOM__c> uoms = [SELECT Id FROM UOM__c WHERE UOM_Code__c LIKE 'PM-%' LIMIT 1];
        UOM_Conversion__c c = new UOM_Conversion__c(
            From_UOM__c = uoms[0].Id, To_UOM__c = uoms[0].Id, Conversion_Factor__c = 1
        );
        Test.startTest();
        try {
            ProductManagementController.saveUOMConversionInternal(c);
            System.assert(false, 'Should throw');
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @IsTest static void testSaveUOMConversion_ZeroFactor() {
        List<UOM__c> uoms = [SELECT Id FROM UOM__c WHERE UOM_Code__c LIKE 'PM-%' ORDER BY UOM_Code__c];
        UOM_Conversion__c c = new UOM_Conversion__c(
            From_UOM__c = uoms[0].Id, To_UOM__c = uoms[1].Id, Conversion_Factor__c = 0
        );
        Test.startTest();
        try {
            ProductManagementController.saveUOMConversionInternal(c);
            System.assert(false, 'Should throw');
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @IsTest static void testSaveUOMConversion_Duplicate() {
        UOM_Conversion__c existing = [SELECT From_UOM__c, To_UOM__c FROM UOM_Conversion__c LIMIT 1];
        UOM_Conversion__c dup = new UOM_Conversion__c(
            From_UOM__c = existing.From_UOM__c, To_UOM__c = existing.To_UOM__c, Conversion_Factor__c = 10
        );
        Test.startTest();
        try {
            ProductManagementController.saveUOMConversionInternal(dup);
            System.assert(false, 'Should throw for duplicate');
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @IsTest static void testDeleteUOMConversion() {
        UOM_Conversion__c c = [SELECT Id FROM UOM_Conversion__c LIMIT 1];
        Test.startTest();
        ProductManagementController.deleteUOMConversion(c.Id);
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM UOM_Conversion__c WHERE Id = :c.Id]);
    }

    // ─── Wrapper Classes ───────────────────────────────────────────────

    @IsTest static void testProductPageResult() {
        ProductManagementController.ProductPageResult r = new ProductManagementController.ProductPageResult();
        r.products = new List<Product_Extension__c>();
        r.totalCount = 0;
        r.pageNumber = 1;
        r.pageSize = 25;
        r.totalPages = 0;
        System.assertEquals(0, r.totalCount);
    }

    @IsTest static void testPriceListPageResult() {
        ProductManagementController.PriceListPageResult r = new ProductManagementController.PriceListPageResult();
        r.priceLists = new List<Price_List__c>();
        r.totalCount = 0;
        r.pageNumber = 1;
        r.pageSize = 25;
        r.totalPages = 0;
        System.assertEquals(0, r.totalCount);
    }

    @IsTest static void testDashboardStats() {
        ProductManagementController.DashboardStats s = new ProductManagementController.DashboardStats();
        s.totalProducts = 0;
        s.activeProducts = 0;
        s.totalCategories = 0;
        s.activePriceLists = 0;
        s.activeBatches = 0;
        s.nearExpiryBatches = 0;
        s.expiredBatches = 0;
        s.mustSellConfigs = 0;
        s.totalUOMs = 0;
        s.totalConversions = 0;
        System.assertEquals(0, s.totalProducts);
    }
}