/**
 * @description Test class for INV_DistributorStock_TriggerHandler.
 *              Tests closing stock calculation, current flag management,
 *              and validation rules.
 */
@isTest
private class INV_DistributorStock_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        // Create test Account. Use the factory: the org's default Account record type is
        // Retailer, so a bare `new Account(...)` trips Outlet_Type_Required_For_Retailer.
        Account testAccount = TestDataFactory.createAndInsertAccount('Test Distributor', 'Distributor');

        // Create test Product
        Product_Extension__c testProduct = new Product_Extension__c(
            Name = 'Test FMCG Product',
            SKU_Code__c = 'TST-001',
            Is_Active__c = true
        );
        insert testProduct;
    }

    @isTest
    static void testClosingStockCalculation() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Test.startTest();
        Distributor_Stock__c stock = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = prod.Id,
            Stock_Date__c = Date.today(),
            Opening_Stock__c = 100,
            Received_Qty__c = 50,
            Sold_Qty__c = 30,
            Damaged_Qty__c = 5,
            Is_Current__c = true
        );
        insert stock;
        Test.stopTest();

        stock = [SELECT Closing_Stock__c FROM Distributor_Stock__c WHERE Id = :stock.Id];
        // Closing = 100 + 50 - 30 - 5 = 115
        System.assertEquals(115, stock.Closing_Stock__c, 'Closing stock should be calculated as Opening + Received - Sold - Damaged');
    }

    @isTest
    static void testClosingStockRecalculationOnUpdate() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Distributor_Stock__c stock = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = prod.Id,
            Stock_Date__c = Date.today(),
            Opening_Stock__c = 100,
            Received_Qty__c = 50,
            Sold_Qty__c = 30,
            Damaged_Qty__c = 5,
            Is_Current__c = true
        );
        insert stock;

        Test.startTest();
        stock.Sold_Qty__c = 60;
        update stock;
        Test.stopTest();

        stock = [SELECT Closing_Stock__c FROM Distributor_Stock__c WHERE Id = :stock.Id];
        // Closing = 100 + 50 - 60 - 5 = 85
        System.assertEquals(85, stock.Closing_Stock__c, 'Closing stock should recalculate on update');
    }

    @isTest
    static void testUnmarkPreviousCurrentEntries() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        // Create first current entry
        Distributor_Stock__c stock1 = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = prod.Id,
            Stock_Date__c = Date.today().addDays(-1),
            Opening_Stock__c = 50,
            Is_Current__c = true
        );
        insert stock1;

        Test.startTest();
        // Create second current entry for same Account+Product
        Distributor_Stock__c stock2 = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = prod.Id,
            Stock_Date__c = Date.today(),
            Opening_Stock__c = 60,
            Is_Current__c = true
        );
        insert stock2;
        Test.stopTest();

        stock1 = [SELECT Is_Current__c FROM Distributor_Stock__c WHERE Id = :stock1.Id];
        stock2 = [SELECT Is_Current__c FROM Distributor_Stock__c WHERE Id = :stock2.Id];

        System.assertEquals(false, stock1.Is_Current__c, 'Previous current entry should be unmarked');
        System.assertEquals(true, stock2.Is_Current__c, 'New entry should remain current');
    }

    @isTest
    static void testClosingStockWithNullQuantities() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Test.startTest();
        Distributor_Stock__c stock = new Distributor_Stock__c(
            Account__c = acc.Id,
            Product_Ext__c = prod.Id,
            Stock_Date__c = Date.today(),
            Opening_Stock__c = 100
            // All other qty fields left null/default
        );
        insert stock;
        Test.stopTest();

        stock = [SELECT Closing_Stock__c FROM Distributor_Stock__c WHERE Id = :stock.Id];
        System.assertEquals(100, stock.Closing_Stock__c, 'Closing stock should handle null quantities gracefully');
    }

    @isTest
    static void testBulkInsert() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        List<Distributor_Stock__c> stockList = new List<Distributor_Stock__c>();
        for (Integer i = 0; i < 200; i++) {
            stockList.add(new Distributor_Stock__c(
                Account__c = acc.Id,
                Product_Ext__c = prod.Id,
                Stock_Date__c = Date.today().addDays(-i),
                Opening_Stock__c = 100 + i,
                Received_Qty__c = 50,
                Sold_Qty__c = 20,
                Damaged_Qty__c = 2,
                Is_Current__c = (i == 0)
            ));
        }

        Test.startTest();
        insert stockList;
        Test.stopTest();

        List<Distributor_Stock__c> results = [
            SELECT Closing_Stock__c FROM Distributor_Stock__c
            WHERE Account__c = :acc.Id ORDER BY Stock_Date__c DESC
        ];
        System.assertEquals(200, results.size(), 'All 200 records should be inserted');
    }
}