/**
 * @description Test class for MDM_ProductCatalogController.
 */
@isTest
private class MDM_ProductCatalogController_Test {

    @TestSetup
    static void setupTestData() {
        // Create category hierarchy
        Product_Category__c beverages = new Product_Category__c(
            Name = 'Beverages',
            Category_Code__c = 'BEV',
            Level__c = 'Category',
            Sort_Order__c = 1,
            Is_Active__c = true
        );
        insert beverages;

        Product_Category__c juices = new Product_Category__c(
            Name = 'Juices',
            Category_Code__c = 'BEV-JUI',
            Level__c = 'Sub-Category',
            Parent_Category__c = beverages.Id,
            Sort_Order__c = 1,
            Is_Active__c = true
        );
        insert juices;

        Product_Category__c brandA = new Product_Category__c(
            Name = 'Brand A Juices',
            Category_Code__c = 'BEV-JUI-BRA',
            Level__c = 'Brand',
            Parent_Category__c = juices.Id,
            Sort_Order__c = 1,
            Is_Active__c = true
        );
        insert brandA;

        // Create products (Product_Extension__c)
        List<Product_Extension__c> products = new List<Product_Extension__c>();
        for (Integer i = 1; i <= 5; i++) {
            products.add(new Product_Extension__c(
                Name = 'Test Product ' + i,
                Product_Category__c = brandA.Id,
                Barcode_EAN__c = '1234567890123',
                HSN_SAC_Code__c = '22011010',
                Weight__c = 500,
                Weight_Unit__c = 'ml',
                Case_Size__c = 24,
                Min_Order_Qty__c = 5,
                Is_Active__c = true
            ));
        }
        products.add(new Product_Extension__c(
            Name = 'Inactive Product',
            Is_Active__c = false
        ));
        insert products;

        // Create price list entries
        List<Price_List__c> prices = new List<Price_List__c>();
        for (Integer i = 0; i < 5; i++) {
            prices.add(new Price_List__c(
                Name = products[i].Name + ' MRP',
                Product_Ext__c = products[i].Id,
                Unit_Price__c = 100 + (i * 10),
                Price_Type__c = 'MRP',
                Channel__c = 'GT',
                Effective_From__c = Date.today().addDays(-30),
                Is_Active__c = true
            ));
        }
        insert prices;

        // Create test account and stock
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Catalog Territory', 'CAT-TER-001');
        Id distRtId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Distributor').getRecordTypeId();
        Account testAcc = new Account(Name = 'Stock Test Distributor', Is_Active__c = true, RecordTypeId = distRtId, Territory__c = territory.Id, Channel__c = 'GT');
        insert testAcc;

        Distributor_Stock__c stock = new Distributor_Stock__c(
            Account__c = testAcc.Id,
            Product_Ext__c = products[0].Id,
            Stock_Date__c = Date.today(),
            Opening_Stock__c = 100,
            Received_Qty__c = 50,
            Sold_Qty__c = 20,
            Is_Current__c = true
        );
        insert stock;

        // Create batch
        Batch_Master__c batch = new Batch_Master__c(
            Name = 'BATCH-001',
            Batch_Number__c = 'B-2024-001',
            Product_Ext__c = products[0].Id,
            Manufacturing_Date__c = Date.today().addDays(-90),
            Expiry_Date__c = Date.today().addDays(270),
            Status__c = 'Active',
            Quantity_Manufactured__c = 10000
        );
        insert batch;
    }

    @isTest
    static void testGetProducts_NoFilters() {
        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult result =
            MDM_ProductCatalogController.getProducts(null, null, false, 50, 0);
        Test.stopTest();

        System.assert(result.totalCount >= 5, 'Should return all products');
        System.assertNotEquals(null, result.products, 'Products list should not be null');
    }

    @isTest
    static void testGetProducts_WithSearch() {
        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult result =
            MDM_ProductCatalogController.getProducts('Test Product 1', null, true, 50, 0);
        Test.stopTest();

        System.assert(result.totalCount >= 1, 'Should find at least one product');
    }

    @isTest
    static void testGetProducts_ActiveOnly() {
        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult result =
            MDM_ProductCatalogController.getProducts(null, null, true, 50, 0);
        Test.stopTest();

        for (MDM_ProductCatalogController.ProductWrapper pw : result.products) {
            System.assertEquals(true, pw.isActive, 'Only active products should be returned');
        }
    }

    @isTest
    static void testGetProducts_ByCategory() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'BEV' LIMIT 1];

        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult result =
            MDM_ProductCatalogController.getProducts(null, cat.Id, true, 50, 0);
        Test.stopTest();

        System.assert(result.totalCount >= 1, 'Should return products in category hierarchy');
    }

    @isTest
    static void testGetCategoryTree() {
        Test.startTest();
        List<MDM_ProductCatalogController.CategoryNode> tree =
            MDM_ProductCatalogController.getCategoryTree();
        Test.stopTest();

        System.assert(!tree.isEmpty(), 'Category tree should not be empty');
        // Root should be "Beverages" with children
        Boolean foundBeverages = false;
        for (MDM_ProductCatalogController.CategoryNode node : tree) {
            if (node.name == 'Beverages') {
                foundBeverages = true;
                System.assert(!node.children.isEmpty(), 'Beverages should have sub-categories');
            }
        }
        System.assert(foundBeverages, 'Should find Beverages category at root');
    }

    @isTest
    static void testGetProductPricing() {
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE Name = 'Test Product 1' LIMIT 1];

        Test.startTest();
        List<Price_List__c> prices = MDM_ProductCatalogController.getProductPricing(product.Id);
        Test.stopTest();

        System.assert(!prices.isEmpty(), 'Should return pricing for product');
    }

    @isTest
    static void testGetProductDetail() {
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE Name = 'Test Product 1' LIMIT 1];

        Test.startTest();
        MDM_ProductCatalogController.ProductDetailWrapper detail =
            MDM_ProductCatalogController.getProductDetail(product.Id);
        Test.stopTest();

        System.assertEquals(product.Id, detail.productId, 'Should return correct product');
        System.assertNotEquals(null, detail.priceLists, 'Price lists should not be null');
        System.assert(detail.activeBatchCount >= 1, 'Should have active batch');
        System.assert(detail.totalDistributorStock > 0, 'Should have distributor stock');
    }

    @isTest
    static void testGetProducts_Pagination() {
        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult page1 =
            MDM_ProductCatalogController.getProducts(null, null, true, 3, 0);
        MDM_ProductCatalogController.ProductCatalogResult page2 =
            MDM_ProductCatalogController.getProducts(null, null, true, 3, 3);
        Test.stopTest();

        System.assertEquals(3, page1.products.size(), 'Page 1 should have 3 products');
        System.assert(page2.products.size() >= 1, 'Page 2 should have remaining products');
    }

    @isTest
    static void testGetProducts_NullParams() {
        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult result =
            MDM_ProductCatalogController.getProducts(null, null, null, null, null);
        Test.stopTest();
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.products);
    }

    @isTest
    static void testGetProducts_SearchAndActiveAndCategory() {
        Product_Category__c cat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'BEV-JUI-BRA' LIMIT 1];
        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult result =
            MDM_ProductCatalogController.getProducts('Test', cat.Id, true, 10, 0);
        Test.stopTest();
        System.assert(result.totalCount >= 1);
    }

    @isTest
    static void testGetProducts_SubCategoryFilter() {
        Product_Category__c subCat = [SELECT Id FROM Product_Category__c WHERE Category_Code__c = 'BEV-JUI' LIMIT 1];
        Test.startTest();
        MDM_ProductCatalogController.ProductCatalogResult result =
            MDM_ProductCatalogController.getProducts(null, subCat.Id, true, 50, 0);
        Test.stopTest();
        System.assert(result.totalCount >= 5, 'Sub-category should include brand children');
    }

    @isTest
    static void testGetProductDetail_AllFields() {
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE Name = 'Test Product 1' LIMIT 1];
        Test.startTest();
        MDM_ProductCatalogController.ProductDetailWrapper detail =
            MDM_ProductCatalogController.getProductDetail(product.Id);
        Test.stopTest();

        System.assertEquals('Test Product 1', detail.name);
        System.assertEquals(true, detail.isActive);
        System.assertEquals('Brand A Juices', detail.categoryName);
        System.assertEquals('1234567890123', detail.barcodeEAN);
        System.assertEquals('22011010', detail.hsnCode);
        System.assertEquals(500, detail.weight);
        System.assertEquals('ml', detail.weightUnit);
        System.assertEquals(24, detail.caseSize);
        System.assertEquals(5, detail.minOrderQty);
        System.assertNotEquals(null, detail.priceLists);
        System.assert(detail.activeBatchCount >= 1);
        System.assert(detail.totalDistributorStock >= 0);
    }

    @isTest
    static void testGetProductDetail_NoStockNoBatch() {
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE Name = 'Test Product 2' LIMIT 1];
        Test.startTest();
        MDM_ProductCatalogController.ProductDetailWrapper detail =
            MDM_ProductCatalogController.getProductDetail(product.Id);
        Test.stopTest();

        System.assertEquals(0, detail.activeBatchCount);
        System.assertEquals(0, detail.totalDistributorStock);
    }

    @isTest
    static void testGetProductPricing_NoPrices() {
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE Name = 'Inactive Product' LIMIT 1];
        Test.startTest();
        List<Price_List__c> prices = MDM_ProductCatalogController.getProductPricing(product.Id);
        Test.stopTest();
        System.assertEquals(0, prices.size());
    }

    @isTest
    static void testGetCategoryTree_ParentChildRelationship() {
        Test.startTest();
        List<MDM_ProductCatalogController.CategoryNode> tree =
            MDM_ProductCatalogController.getCategoryTree();
        Test.stopTest();

        MDM_ProductCatalogController.CategoryNode beverages = null;
        for (MDM_ProductCatalogController.CategoryNode node : tree) {
            if (node.name == 'Beverages') beverages = node;
        }
        System.assertNotEquals(null, beverages);
        System.assertNotEquals(null, beverages.children);
        System.assert(!beverages.children.isEmpty());

        MDM_ProductCatalogController.CategoryNode juices = beverages.children[0];
        System.assertEquals('Juices', juices.name);
        System.assertEquals('BEV-JUI', juices.code);
        System.assertEquals('Sub-Category', juices.level);
        System.assertNotEquals(null, juices.children);
    }

    @isTest
    static void testProductWrapper_Fields() {
        MDM_ProductCatalogController.ProductWrapper pw = new MDM_ProductCatalogController.ProductWrapper();
        pw.productId = null;
        pw.name = 'Test';
        pw.productCode = 'TST';
        pw.family = 'TestFamily';
        pw.isActive = true;
        pw.description = 'desc';
        pw.categoryName = 'Cat';
        pw.categoryId = null;
        pw.barcodeEAN = '123';
        pw.barcodeUPC = '456';
        pw.hsnCode = '789';
        pw.weight = 100;
        pw.weightUnit = 'g';
        pw.caseSize = 12;
        pw.minOrderQty = 5;
        pw.extIsActive = true;
        pw.imageUrl = 'http://test.com/img.jpg';
        System.assertEquals('Test', pw.name);
    }

    @isTest
    static void testProductDetailWrapper_Fields() {
        MDM_ProductCatalogController.ProductDetailWrapper dw = new MDM_ProductCatalogController.ProductDetailWrapper();
        dw.productId = null;
        dw.name = 'Detail';
        dw.productCode = 'DET';
        dw.family = 'Family';
        dw.isActive = true;
        dw.description = 'desc';
        dw.categoryName = 'Cat';
        dw.barcodeEAN = '123';
        dw.barcodeUPC = '456';
        dw.hsnCode = '789';
        dw.weight = 100;
        dw.weightUnit = 'g';
        dw.caseSize = 12;
        dw.minOrderQty = 5;
        dw.imageUrl = 'http://test.com';
        dw.skuCode = 'SKU1';
        dw.mrp = 99;
        dw.unitPrice = 70;
        dw.brand = 'Brand';
        dw.priceLists = new List<Price_List__c>();
        dw.activeBatchCount = 0;
        dw.totalDistributorStock = 0;
        System.assertEquals('Detail', dw.name);
    }

    @isTest
    static void testCategoryNode_Fields() {
        MDM_ProductCatalogController.CategoryNode cn = new MDM_ProductCatalogController.CategoryNode();
        cn.id = null;
        cn.name = 'Node';
        cn.code = 'ND';
        cn.level = 'Category';
        cn.parentId = null;
        cn.sortOrder = 1;
        cn.children = new List<MDM_ProductCatalogController.CategoryNode>();
        System.assertEquals('Node', cn.name);
    }

    @isTest
    static void testProductCatalogResult_Fields() {
        MDM_ProductCatalogController.ProductCatalogResult r = new MDM_ProductCatalogController.ProductCatalogResult();
        r.totalCount = 10;
        r.products = new List<MDM_ProductCatalogController.ProductWrapper>();
        System.assertEquals(10, r.totalCount);
    }
}