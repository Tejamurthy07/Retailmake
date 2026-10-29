/**
 * @description Test class for INV_WarehouseStock_Service.
 *              Tests all stock operations: check availability, reserve, release,
 *              deduct, add stock, and adjust deduct with audit trail verification.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_WarehouseStock_Service_Test {

    @TestSetup
    static void setupTestData() {
        // Create warehouse
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Test Warehouse',
            Warehouse_Code__c = 'TW001',
            State__c = 'Maharashtra',
            Warehouse_Type__c = 'Central',
            Is_Active__c = true
        );
        insert warehouse;

        // Create products
        Product_Extension__c product1 = new Product_Extension__c(Name = 'Test Product 1', SKU_Code__c = 'TP001', Is_Active__c = true);
        Product_Extension__c product2 = new Product_Extension__c(Name = 'Test Product 2', SKU_Code__c = 'TP002', Is_Active__c = true);
        insert new List<Product_Extension__c>{ product1, product2 };

        // Create initial stock records
        Warehouse_Stock__c stock1 = new Warehouse_Stock__c(
            Warehouse__c = warehouse.Id,
            Product_Ext__c = product1.Id,
            Qty_On_Hand__c = 100,
            Qty_Reserved__c = 0,
            Qty_Damaged__c = 0,
            Min_Stock_Level__c = 10,
            Max_Stock_Level__c = 500
        );
        Warehouse_Stock__c stock2 = new Warehouse_Stock__c(
            Warehouse__c = warehouse.Id,
            Product_Ext__c = product2.Id,
            Qty_On_Hand__c = 50,
            Qty_Reserved__c = 0,
            Qty_Damaged__c = 0,
            Min_Stock_Level__c = 5,
            Max_Stock_Level__c = 200
        );
        insert new List<Warehouse_Stock__c>{ stock1, stock2 };
    }

    @isTest
    static void testCheckAvailability() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        List<Product_Extension__c> products = [SELECT Id FROM Product_Extension__c ORDER BY SKU_Code__c];

        Test.startTest();
        Map<Id, Decimal> availability = INV_WarehouseStock_Service.checkAvailability(
            wh.Id, new List<Id>{ products[0].Id, products[1].Id }
        );
        Test.stopTest();

        System.assertEquals(100, availability.get(products[0].Id), 'Product 1 should have 100 available');
        System.assertEquals(50, availability.get(products[1].Id), 'Product 2 should have 50 available');
    }

    @isTest
    static void testReserveStock() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP001'];

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 20));

        Test.startTest();
        INV_WarehouseStock_Service.reserveStock(wh.Id, items, 'TEST_REF_001');
        Test.stopTest();

        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c, Qty_Reserved__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(100, stock.Qty_On_Hand__c, 'On hand should remain 100');
        System.assertEquals(20, stock.Qty_Reserved__c, 'Reserved should be 20');

        // Verify transaction log
        List<Stock_Transaction__c> txns = [
            SELECT Transaction_Type__c, Quantity__c, Direction__c
            FROM Stock_Transaction__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(1, txns.size(), 'Should have 1 transaction');
        System.assertEquals('Reservation', txns[0].Transaction_Type__c);
        System.assertEquals('Out', txns[0].Direction__c);
    }

    @isTest
    static void testReleaseReservation() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP001'];

        // First reserve stock
        Warehouse_Stock__c stock = [
            SELECT Id FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        stock.Qty_Reserved__c = 30;
        update stock;

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 30));

        Test.startTest();
        INV_WarehouseStock_Service.releaseReservation(wh.Id, items, 'TEST_REF_002');
        Test.stopTest();

        stock = [
            SELECT Qty_On_Hand__c, Qty_Reserved__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(100, stock.Qty_On_Hand__c, 'On hand should remain 100');
        System.assertEquals(0, stock.Qty_Reserved__c, 'Reserved should be 0 after release');
    }

    @isTest
    static void testDeductStock() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP001'];

        // Set up reservation first
        Warehouse_Stock__c stock = [
            SELECT Id FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        stock.Qty_Reserved__c = 25;
        update stock;

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 25));

        Test.startTest();
        INV_WarehouseStock_Service.deductStock(wh.Id, items, 'TEST_REF_003', 'Invoice');
        Test.stopTest();

        stock = [
            SELECT Qty_On_Hand__c, Qty_Reserved__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(75, stock.Qty_On_Hand__c, 'On hand should be 75 after deduction');
        System.assertEquals(0, stock.Qty_Reserved__c, 'Reserved should be 0 after deduction');

        // Verify transaction
        Stock_Transaction__c txn = [
            SELECT Transaction_Type__c, Direction__c, Running_Balance__c
            FROM Stock_Transaction__c
            WHERE Reference_Id__c = 'TEST_REF_003' LIMIT 1
        ];
        System.assertEquals('Outbound_Dispatch', txn.Transaction_Type__c);
        System.assertEquals('Out', txn.Direction__c);
    }

    @isTest
    static void testAddStock() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP002'];

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 30));

        Test.startTest();
        INV_WarehouseStock_Service.addStock(wh.Id, items, 'TEST_REF_004', 'GRN');
        Test.stopTest();

        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(80, stock.Qty_On_Hand__c, 'On hand should be 80 after addition');

        Stock_Transaction__c txn = [
            SELECT Transaction_Type__c, Direction__c
            FROM Stock_Transaction__c
            WHERE Reference_Id__c = 'TEST_REF_004' LIMIT 1
        ];
        System.assertEquals('Inbound_GRN', txn.Transaction_Type__c);
        System.assertEquals('In', txn.Direction__c);
    }

    @isTest
    static void testAddStockReturnOrder() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP001'];

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 10));

        Test.startTest();
        INV_WarehouseStock_Service.addStock(wh.Id, items, 'TEST_REF_005', 'Return_Order');
        Test.stopTest();

        Stock_Transaction__c txn = [
            SELECT Transaction_Type__c
            FROM Stock_Transaction__c
            WHERE Reference_Id__c = 'TEST_REF_005' LIMIT 1
        ];
        System.assertEquals('Return_Inbound', txn.Transaction_Type__c);
    }

    @isTest
    static void testAddStockTransfer() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP001'];

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 15));

        Test.startTest();
        INV_WarehouseStock_Service.addStock(wh.Id, items, 'TEST_REF_006', 'Stock_Transfer');
        Test.stopTest();

        Stock_Transaction__c txn = [
            SELECT Transaction_Type__c
            FROM Stock_Transaction__c
            WHERE Reference_Id__c = 'TEST_REF_006' LIMIT 1
        ];
        System.assertEquals('Transfer_In', txn.Transaction_Type__c);
    }

    @isTest
    static void testAdjustDeduct() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP001'];

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 10));

        Test.startTest();
        INV_WarehouseStock_Service.adjustDeduct(wh.Id, items, 'TEST_REF_007');
        Test.stopTest();

        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(90, stock.Qty_On_Hand__c, 'On hand should be 90 after deduction');

        Stock_Transaction__c txn = [
            SELECT Transaction_Type__c
            FROM Stock_Transaction__c
            WHERE Reference_Id__c = 'TEST_REF_007' LIMIT 1
        ];
        System.assertEquals('Adjustment_Deduct', txn.Transaction_Type__c);
    }

    @isTest
    static void testAddStockCreatesNewRecord() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];

        // Create a new product not in stock
        Product_Extension__c newProduct = new Product_Extension__c(Name = 'New Product', SKU_Code__c = 'NP001', Is_Active__c = true);
        insert newProduct;

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(newProduct.Id, 'BATCH001', 50));

        Test.startTest();
        INV_WarehouseStock_Service.addStock(wh.Id, items, 'TEST_REF_008', 'GRN');
        Test.stopTest();

        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c, Batch_Number__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :newProduct.Id
        ];
        System.assertEquals(50, stock.Qty_On_Hand__c, 'New stock record should have 50 on hand');
        System.assertEquals('BATCH001', stock.Batch_Number__c, 'Batch should match');
    }

    @isTest
    static void testStockLineItemConstructors() {
        INV_WarehouseStock_Service.StockLineItem item1 = new INV_WarehouseStock_Service.StockLineItem();
        System.assertEquals(null, item1.productId);

        Id fakeId = '01t000000000001AAA';
        INV_WarehouseStock_Service.StockLineItem item2 = new INV_WarehouseStock_Service.StockLineItem(fakeId, 'B001', 10);
        System.assertEquals(fakeId, item2.productId);
        System.assertEquals('B001', item2.batchNumber);
        System.assertEquals(10, item2.quantity);
    }

    @isTest
    static void testDeductStockTransferType() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TP001'];

        List<INV_WarehouseStock_Service.StockLineItem> items = new List<INV_WarehouseStock_Service.StockLineItem>();
        items.add(new INV_WarehouseStock_Service.StockLineItem(product.Id, null, 10));

        Test.startTest();
        INV_WarehouseStock_Service.deductStock(wh.Id, items, 'TEST_REF_009', 'Stock_Transfer');
        Test.stopTest();

        Stock_Transaction__c txn = [
            SELECT Transaction_Type__c
            FROM Stock_Transaction__c
            WHERE Reference_Id__c = 'TEST_REF_009' LIMIT 1
        ];
        System.assertEquals('Transfer_Out', txn.Transaction_Type__c);
    }
}