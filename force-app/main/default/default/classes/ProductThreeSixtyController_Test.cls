/**
 * @description Test class for ProductThreeSixtyController.
 *              Validates getProductDetails, getProductKPIs, getBatches,
 *              getWarehouseStock, getDistributorStock, getPricing,
 *              getRecentOrderLines, getActiveSchemes, getRecentReturns,
 *              and getStockTransactions.
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class ProductThreeSixtyController_Test {

    @TestSetup
    static void setupTestData() {
        // Product
        Product_Extension__c prod = TestDataFactory.createProduct('P360 Product', 'P360-001');
        prod.MRP__c = 150;
        prod.Unit_Price__c = 120;
        prod.GST_Rate__c = 18;
        prod.Is_Returnable__c = true;
        prod.Min_Order_Qty__c = 1;
        insert prod;

        // Account
        Account acc = TestDataFactory.createAndInsertAccount('P360 Outlet', 'Retailer');

        // Warehouse
        Warehouse__c wh = new Warehouse__c(
            Name = 'P360 Warehouse',
            Warehouse_Code__c = 'WHP360',
            Is_Active__c = true
        );
        insert wh;

        // Warehouse Stock
        Warehouse_Stock__c ws = new Warehouse_Stock__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = prod.Id,
            Qty_On_Hand__c = 500,
            Qty_Reserved__c = 50
        );
        insert ws;

        // Distributor Stock
        Distributor_Stock__c ds = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = prod.Id,
            Opening_Stock__c = 100,
            Received_Qty__c = 50,
            Sold_Qty__c = 30,
            Closing_Stock__c = 120,
            Stock_Date__c = Date.today(),
            Is_Current__c = true
        );
        insert ds;

        // Batch Master
        Batch_Master__c batch = new Batch_Master__c(
            Product_Ext__c = prod.Id,
            Batch_Number__c = 'BATCH-001',
            Manufacturing_Date__c = Date.today().addMonths(-6),
            Expiry_Date__c = Date.today().addMonths(6),
            Quantity_Manufactured__c = 10000,
            Status__c = 'Active'
        );
        insert batch;

        // Price List
        Price_List__c pl = new Price_List__c(
            Product_Ext__c = prod.Id,
            Unit_Price__c = 120,
            Effective_From__c = Date.today().addDays(-30),
            Effective_To__c = Date.today().addDays(30),
            Is_Active__c = true
        );
        insert pl;

        // Sales Order + Line Items
        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        // Keep Status as 'Draft' (factory default) to avoid downstream flows.
        insert so;

        Order_Line_Item__c oli = TestDataFactory.createOrderLineItem(so.Id, prod.Id, 10, 120);
        insert oli;

        // Scheme tied to product
        Scheme__c scheme = TestDataFactory.createScheme('P360 Scheme', 'SCH-P360', 'Discount in %', 'Invoice Val Based');
        scheme.Status__c = 'Active';
        scheme.Start_Date__c = Date.today().addDays(-1);
        scheme.End_Date__c = Date.today().addDays(30);
        scheme.Product_Ext__c = prod.Id;
        scheme.Budget_Amount__c = 10000;
        insert scheme;

        // Stock Transaction
        Stock_Transaction__c st = new Stock_Transaction__c(
            Product_Ext__c = prod.Id,
            Warehouse__c = wh.Id,
            Transaction_Type__c = 'Inbound_GRN',
            Quantity__c = 500,
            Transaction_Date__c = Date.today()
        );
        insert st;
    }

    // ── Helper accessors ────────────────────────────────────────────────────

    private static Product_Extension__c getProduct() {
        return [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'P360-001' LIMIT 1];
    }

    // ── getProductDetails: valid product ────────────────────────────────────

    @IsTest
    static void testGetProductDetailsValid() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        Product_Extension__c detail = ProductThreeSixtyController.getProductDetails(prod.Id);
        Test.stopTest();

        System.assertEquals('P360 Product', detail.Name, 'Product name should match');
        System.assertEquals('P360-001', detail.SKU_Code__c, 'SKU code should match');
        System.assertEquals(150, detail.MRP__c, 'MRP should match');
        System.assertEquals(true, detail.Is_Active__c, 'Product should be active');
    }

    // ── getProductDetails: invalid ID throws ────────────────────────────────

    @IsTest
    static void testGetProductDetailsInvalid() {
        Id fakeId = Product_Extension__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';

        Test.startTest();
        Boolean caught = false;
        try {
            ProductThreeSixtyController.getProductDetails(fakeId);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Expected AuraHandledException for invalid product id');
    }

    // ── getProductKPIs: returns comprehensive KPIs ──────────────────────────

    @IsTest
    static void testGetProductKPIs() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        Map<String, Object> kpis = ProductThreeSixtyController.getProductKPIs(prod.Id);
        Test.stopTest();

        System.assert(kpis.containsKey('mtdOrderQty'), 'Should have mtdOrderQty');
        System.assert(kpis.containsKey('mtdOrderValue'), 'Should have mtdOrderValue');
        System.assert(kpis.containsKey('mtdOrderLines'), 'Should have mtdOrderLines');
        System.assert(kpis.containsKey('totalStockOnHand'), 'Should have totalStockOnHand');
        System.assert(kpis.containsKey('totalStockAvailable'), 'Should have totalStockAvailable');
        System.assert(kpis.containsKey('totalDistributorStock'), 'Should have totalDistributorStock');
        System.assert(kpis.containsKey('activeBatches'), 'Should have activeBatches');
        System.assert(kpis.containsKey('threeMonthOrderQty'), 'Should have threeMonthOrderQty');
        System.assert(kpis.containsKey('mtdReturnQty'), 'Should have mtdReturnQty');

        // Validate stock values
        System.assertEquals(500, (Decimal) kpis.get('totalStockOnHand'), 'Stock on hand should be 500');
        System.assertEquals(450, (Decimal) kpis.get('totalStockAvailable'), 'Available stock should be 450');
        System.assertEquals(120, (Decimal) kpis.get('totalDistributorStock'), 'Distributor stock should be 120');
        System.assertEquals(1, (Integer) kpis.get('activeBatches'), 'Should have 1 active batch');
    }

    // ── getBatches: returns batch records ───────────────────────────────────

    @IsTest
    static void testGetBatches() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Batch_Master__c> batches = ProductThreeSixtyController.getBatches(prod.Id);
        Test.stopTest();

        System.assertEquals(1, batches.size(), 'Should return 1 batch');
        System.assertEquals('BATCH-001', batches[0].Batch_Number__c, 'Batch number should match');
        System.assertEquals('Active', batches[0].Status__c, 'Batch should be active');
    }

    // ── getWarehouseStock: returns warehouse stock records ──────────────────

    @IsTest
    static void testGetWarehouseStock() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Warehouse_Stock__c> stocks = ProductThreeSixtyController.getWarehouseStock(prod.Id);
        Test.stopTest();

        System.assertEquals(1, stocks.size(), 'Should return 1 warehouse stock record');
        System.assertEquals(500, stocks[0].Qty_On_Hand__c, 'On hand qty should be 500');
    }

    // ── getDistributorStock: returns distributor stock records ──────────────

    @IsTest
    static void testGetDistributorStock() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Distributor_Stock__c> stocks = ProductThreeSixtyController.getDistributorStock(prod.Id);
        Test.stopTest();

        System.assertEquals(1, stocks.size(), 'Should return 1 distributor stock record');
        System.assertEquals(120, stocks[0].Closing_Stock__c, 'Closing stock should be 120');
        System.assertEquals(true, stocks[0].Is_Current__c, 'Record should be current');
    }

    // ── getPricing: returns price list records ──────────────────────────────

    @IsTest
    static void testGetPricing() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Price_List__c> pricing = ProductThreeSixtyController.getPricing(prod.Id);
        Test.stopTest();

        System.assert(!pricing.isEmpty(), 'Should return at least 1 price list');
        System.assertEquals(120, pricing[0].Unit_Price__c, 'Unit price should be 120');
    }

    // ── getRecentOrderLines: returns order line items ───────────────────────

    @IsTest
    static void testGetRecentOrderLines() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Order_Line_Item__c> lines = ProductThreeSixtyController.getRecentOrderLines(prod.Id, 10);
        Test.stopTest();

        System.assertEquals(1, lines.size(), 'Should return 1 order line item');
        System.assertEquals(10, lines[0].Quantity__c, 'Quantity should be 10');
    }

    // ── getRecentOrderLines: null limit defaults to 20 ──────────────────────

    @IsTest
    static void testGetRecentOrderLinesDefaultLimit() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Order_Line_Item__c> lines = ProductThreeSixtyController.getRecentOrderLines(prod.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, lines, 'Result should not be null');
    }

    // ── getRecentOrderLines: limit capped at 100 ────────────────────────────

    @IsTest
    static void testGetRecentOrderLinesMaxLimit() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Order_Line_Item__c> lines = ProductThreeSixtyController.getRecentOrderLines(prod.Id, 500);
        Test.stopTest();

        System.assert(lines.size() <= 100, 'Should not exceed 100 records');
    }

    // ── getActiveSchemes: returns active schemes for product ────────────────

    @IsTest
    static void testGetActiveSchemes() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Scheme__c> schemes = ProductThreeSixtyController.getActiveSchemes(prod.Id);
        Test.stopTest();

        System.assertEquals(1, schemes.size(), 'Should return 1 active scheme');
        System.assertEquals('SCH-P360', schemes[0].Scheme_Code__c, 'Scheme code should match');
    }

    // ── getRecentReturns: returns return line records ───────────────────────

    @IsTest
    static void testGetRecentReturns() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Return_Line__c> returns = ProductThreeSixtyController.getRecentReturns(prod.Id);
        Test.stopTest();

        // No return lines created in test setup, so expect empty
        System.assertNotEquals(null, returns, 'Result should not be null');
    }

    // ── getStockTransactions: returns transaction records ───────────────────

    @IsTest
    static void testGetStockTransactions() {
        Product_Extension__c prod = getProduct();

        Test.startTest();
        List<Stock_Transaction__c> txns = ProductThreeSixtyController.getStockTransactions(prod.Id);
        Test.stopTest();

        System.assert(!txns.isEmpty(), 'Should return at least 1 stock transaction');
        System.assertEquals('Inbound_GRN', txns[0].Transaction_Type__c, 'Transaction type should be Inbound_GRN');
    }

    // ── getProductKPIs: product with no related data returns zeros ──────────

    @IsTest
    static void testGetProductKPIsNoRelatedData() {
        Product_Extension__c emptyProd = TestDataFactory.createProduct('Empty Product', 'EMPTY-001');
        insert emptyProd;

        Test.startTest();
        Map<String, Object> kpis = ProductThreeSixtyController.getProductKPIs(emptyProd.Id);
        Test.stopTest();

        System.assertEquals(0, (Decimal) kpis.get('mtdOrderQty'), 'MTD order qty should be 0');
        System.assertEquals(0, (Decimal) kpis.get('totalStockOnHand'), 'Stock on hand should be 0');
        System.assertEquals(0, (Decimal) kpis.get('totalDistributorStock'), 'Distributor stock should be 0');
        System.assertEquals(0, (Integer) kpis.get('activeBatches'), 'Active batches should be 0');
        System.assertEquals(0, (Decimal) kpis.get('mtdReturnQty'), 'MTD return qty should be 0');
    }
}