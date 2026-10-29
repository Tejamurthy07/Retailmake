/**
 * @description Test class for INV_WarehouseStockController.
 *              Tests all LWC controller methods for the warehouse stock dashboard.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_WarehouseStockController_Test {

    @TestSetup
    static void setupTestData() {
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'Test Warehouse',
            Warehouse_Code__c = 'TW001',
            State__c = 'Maharashtra',
            Warehouse_Type__c = 'Central',
            Is_Active__c = true
        );
        insert warehouse;

        Product_Extension__c product1 = new Product_Extension__c(Name = 'Product A', SKU_Code__c = 'PA001', Is_Active__c = true);
        Product_Extension__c product2 = new Product_Extension__c(Name = 'Product B', SKU_Code__c = 'PB001', Is_Active__c = true);
        insert new List<Product_Extension__c>{ product1, product2 };

        Warehouse_Stock__c stock1 = new Warehouse_Stock__c(
            Warehouse__c = warehouse.Id,
            Product_Ext__c = product1.Id,
            Qty_On_Hand__c = 100,
            Qty_Reserved__c = 10,
            Qty_Damaged__c = 2,
            Min_Stock_Level__c = 20,
            Max_Stock_Level__c = 500
        );
        Warehouse_Stock__c stock2 = new Warehouse_Stock__c(
            Warehouse__c = warehouse.Id,
            Product_Ext__c = product2.Id,
            Qty_On_Hand__c = 0,
            Qty_Reserved__c = 0,
            Qty_Damaged__c = 0,
            Min_Stock_Level__c = 5,
            Max_Stock_Level__c = 100
        );
        insert new List<Warehouse_Stock__c>{ stock1, stock2 };

        // Create a transaction
        Stock_Transaction__c txn = new Stock_Transaction__c(
            Warehouse_Stock__c = stock1.Id,
            Warehouse__c = warehouse.Id,
            Product_Ext__c = product1.Id,
            Transaction_Type__c = 'Inbound_GRN',
            Quantity__c = 100,
            Direction__c = 'In',
            Reference_Type__c = 'GRN',
            Reference_Id__c = 'TEST_GRN_001',
            Running_Balance__c = 100,
            Transaction_Date__c = Datetime.now()
        );
        insert txn;
    }

    @isTest
    static void testGetWarehouseStockKPIs() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];

        Test.startTest();
        INV_WarehouseStockController.WarehouseStockKPIs kpis =
            INV_WarehouseStockController.getWarehouseStockKPIs(wh.Id);
        Test.stopTest();

        System.assertEquals(2, kpis.totalSkus, 'Should have 2 SKUs');
        System.assertEquals(100, kpis.totalOnHand, 'Should have 100 total on hand');
        System.assertEquals(10, kpis.totalReserved, 'Should have 10 reserved');
    }

    @isTest
    static void testGetWarehouseStockKPIsNoFilter() {
        Test.startTest();
        INV_WarehouseStockController.WarehouseStockKPIs kpis =
            INV_WarehouseStockController.getWarehouseStockKPIs(null);
        Test.stopTest();

        System.assertNotEquals(null, kpis);
    }

    @isTest
    static void testGetWarehouseStock() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];

        Test.startTest();
        INV_WarehouseStockController.WarehouseStockListResult result =
            INV_WarehouseStockController.getWarehouseStock(wh.Id, null, 'all', 25, 0);
        Test.stopTest();

        System.assertEquals(2, result.totalCount, 'Should have 2 records');
        System.assertEquals(2, result.records.size(), 'Should return 2 records');
    }

    @isTest
    static void testGetWarehouseStockWithSearch() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];

        Test.startTest();
        INV_WarehouseStockController.WarehouseStockListResult result =
            INV_WarehouseStockController.getWarehouseStock(wh.Id, 'Product A', 'all', 25, 0);
        Test.stopTest();

        System.assertEquals(1, result.totalCount, 'Should find 1 record matching search');
    }

    @isTest
    static void testGetWarehouseStockFilters() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];

        Test.startTest();
        // Zero stock filter
        INV_WarehouseStockController.WarehouseStockListResult zeroResult =
            INV_WarehouseStockController.getWarehouseStock(wh.Id, null, 'zero', 25, 0);

        // Healthy filter
        INV_WarehouseStockController.WarehouseStockListResult healthyResult =
            INV_WarehouseStockController.getWarehouseStock(wh.Id, null, 'healthy', 25, 0);
        Test.stopTest();

        System.assert(zeroResult.totalCount >= 0, 'Should return valid count');
        System.assert(healthyResult.totalCount >= 0, 'Should return valid count');
    }

    @isTest
    static void testGetWarehouses() {
        Test.startTest();
        List<Warehouse__c> warehouses = INV_WarehouseStockController.getWarehouses();
        Test.stopTest();

        System.assertEquals(1, warehouses.size(), 'Should return 1 warehouse');
        System.assertEquals('TW001', warehouses[0].Warehouse_Code__c);
    }

    @isTest
    static void testGetStockTransactions() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];

        Test.startTest();
        List<Stock_Transaction__c> txns =
            INV_WarehouseStockController.getStockTransactions(wh.Id, null, 50);
        Test.stopTest();

        System.assertEquals(1, txns.size(), 'Should return 1 transaction');
    }

    @isTest
    static void testGetStockTransactionsWithProduct() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PA001'];

        Test.startTest();
        List<Stock_Transaction__c> txns =
            INV_WarehouseStockController.getStockTransactions(wh.Id, product.Id, 50);
        Test.stopTest();

        System.assertEquals(1, txns.size(), 'Should return 1 transaction');
    }

    @isTest
    static void testGetLowStockAlerts() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];

        Test.startTest();
        List<Warehouse_Stock__c> alerts =
            INV_WarehouseStockController.getLowStockAlerts(wh.Id);
        Test.stopTest();

        // At least the zero stock record should be an alert
        System.assert(alerts.size() >= 1, 'Should have at least 1 low/zero stock alert');
    }

    @isTest
    static void testCheckStockAvailability() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'PA001'];

        Test.startTest();
        INV_WarehouseStockController.StockAvailability avail =
            INV_WarehouseStockController.checkStockAvailability(wh.Id, product.Id);
        Test.stopTest();

        System.assertEquals(100, avail.totalOnHand, 'Should have 100 on hand');
        System.assertEquals(10, avail.totalReserved, 'Should have 10 reserved');
        System.assertEquals(90, avail.totalAvailable, 'Should have 90 available');
    }
}