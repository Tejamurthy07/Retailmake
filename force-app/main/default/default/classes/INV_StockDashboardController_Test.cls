/**
 * @description Test class for INV_StockDashboardController.
 */
@isTest
private class INV_StockDashboardController_Test {

    @TestSetup
    static void setupTestData() {
        // A bare Account trips the org's outlet-type and territory validation
        // rules — the factory builds one that satisfies both.
        Account distributor = TestDataFactory.createAndInsertAccount('Test Distributor', 'Distributor');

        List<Product_Extension__c> products = new List<Product_Extension__c>();
        for (Integer i = 1; i <= 5; i++) {
            products.add(new Product_Extension__c(Name = 'Stock Product ' + i, SKU_Code__c = 'SP-' + i, Is_Active__c = true));
        }
        insert products;

        List<Distributor_Stock__c> stocks = new List<Distributor_Stock__c>();
        // Healthy stock
        stocks.add(new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = products[0].Id,
            Stock_Date__c = Date.today(), Opening_Stock__c = 100, Received_Qty__c = 50,
            Sold_Qty__c = 20, Damaged_Qty__c = 5, Is_Current__c = true
        ));
        // Low stock
        stocks.add(new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = products[1].Id,
            Stock_Date__c = Date.today(), Opening_Stock__c = 10, Received_Qty__c = 0,
            Sold_Qty__c = 5, Damaged_Qty__c = 0, Is_Current__c = true
        ));
        // Zero stock
        stocks.add(new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = products[2].Id,
            Stock_Date__c = Date.today(), Opening_Stock__c = 10, Received_Qty__c = 0,
            Sold_Qty__c = 10, Damaged_Qty__c = 0, Is_Current__c = true
        ));
        // Historical (not current)
        stocks.add(new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = products[0].Id,
            Stock_Date__c = Date.today().addDays(-7), Opening_Stock__c = 80,
            Received_Qty__c = 40, Sold_Qty__c = 20, Damaged_Qty__c = 0, Is_Current__c = false
        ));
        insert stocks;

        // Near-expiry batch
        Batch_Master__c nearExpiry = new Batch_Master__c(
            Name = 'Near Expiry Batch', Batch_Number__c = 'NEB-001',
            Product_Ext__c = products[0].Id,
            Manufacturing_Date__c = Date.today().addDays(-350),
            Expiry_Date__c = Date.today().addDays(15),
            Status__c = 'Active', Quantity_Manufactured__c = 5000
        );
        // Active batch with good shelf life
        Batch_Master__c activeBatch = new Batch_Master__c(
            Name = 'Active Batch', Batch_Number__c = 'ACT-001',
            Product_Ext__c = products[1].Id,
            Manufacturing_Date__c = Date.today().addDays(-30),
            Expiry_Date__c = Date.today().addDays(335),
            Status__c = 'Active', Quantity_Manufactured__c = 10000
        );
        insert new List<Batch_Master__c>{ nearExpiry, activeBatch };
    }

    @isTest
    static void testGetStockKPIs_AllAccounts() {
        Test.startTest();
        INV_StockDashboardController.StockKPIs kpis =
            INV_StockDashboardController.getStockKPIs(null);
        Test.stopTest();

        System.assert(kpis.totalSkus >= 3, 'Should have at least 3 current SKUs');
        System.assert(kpis.totalClosingStock > 0, 'Should have total closing stock');
        System.assert(kpis.lowStockCount >= 1, 'Should have at least 1 low stock item');
        System.assert(kpis.zeroStockCount >= 1, 'Should have at least 1 zero stock item');
        System.assert(kpis.nearExpiryBatchCount >= 1, 'Should have near-expiry batches');
    }

    @isTest
    static void testGetStockKPIs_SpecificAccount() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Distributor' LIMIT 1];

        Test.startTest();
        INV_StockDashboardController.StockKPIs kpis =
            INV_StockDashboardController.getStockKPIs(acc.Id);
        Test.stopTest();

        System.assert(kpis.totalSkus >= 3, 'Should have SKUs for this account');
    }

    @isTest
    static void testGetCurrentStock_AllFilters() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Distributor' LIMIT 1];

        Test.startTest();
        // All stock
        INV_StockDashboardController.StockListResult allStock =
            INV_StockDashboardController.getCurrentStock(acc.Id, null, 'all', 25, 0);
        // Low stock
        INV_StockDashboardController.StockListResult lowStock =
            INV_StockDashboardController.getCurrentStock(acc.Id, null, 'low', 25, 0);
        // Zero stock
        INV_StockDashboardController.StockListResult zeroStock =
            INV_StockDashboardController.getCurrentStock(acc.Id, null, 'zero', 25, 0);
        // Healthy stock
        INV_StockDashboardController.StockListResult healthyStock =
            INV_StockDashboardController.getCurrentStock(acc.Id, null, 'healthy', 25, 0);
        Test.stopTest();

        System.assert(allStock.totalCount >= 3, 'Should return all current stock');
        System.assert(lowStock.totalCount >= 1, 'Should find low stock items');
        System.assert(zeroStock.totalCount >= 1, 'Should find zero stock items');
        System.assert(healthyStock.totalCount >= 1, 'Should find healthy stock items');
    }

    @isTest
    static void testGetCurrentStock_WithSearch() {
        Test.startTest();
        INV_StockDashboardController.StockListResult result =
            INV_StockDashboardController.getCurrentStock(null, 'Stock Product 1', 'all', 25, 0);
        Test.stopTest();

        System.assert(result.totalCount >= 1, 'Should find product by search');
    }

    @isTest
    static void testGetNearExpiryBatches() {
        Test.startTest();
        List<Batch_Master__c> batches =
            INV_StockDashboardController.getNearExpiryBatches(30, 25);
        Test.stopTest();

        System.assert(!batches.isEmpty(), 'Should find near-expiry batches within 30 days');
    }

    @isTest
    static void testGetStockMovementHistory() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Distributor' LIMIT 1];
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'SP-1' LIMIT 1];

        Test.startTest();
        List<Distributor_Stock__c> history =
            INV_StockDashboardController.getStockMovementHistory(acc.Id, prod.Id, 20);
        Test.stopTest();

        System.assert(history.size() >= 2, 'Should return current and historical entries');
    }

    @isTest
    static void testGetDistributorsWithStock() {
        Test.startTest();
        List<Account> distributors = INV_StockDashboardController.getDistributorsWithStock();
        Test.stopTest();

        System.assert(!distributors.isEmpty(), 'Should return distributors with stock');
    }
}