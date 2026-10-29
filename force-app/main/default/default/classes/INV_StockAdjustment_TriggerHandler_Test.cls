/**
 * @description Test class for INV_StockAdjustment_TriggerHandler.
 *              Tests system quantity snapshot and stock adjustment on approval.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_StockAdjustment_TriggerHandler_Test {

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

        Product_Extension__c product = new Product_Extension__c(Name = 'Adjust Product', SKU_Code__c = 'AP001', Is_Active__c = true);
        insert product;

        Warehouse_Stock__c stock = new Warehouse_Stock__c(
            Warehouse__c = warehouse.Id,
            Product_Ext__c = product.Id,
            Qty_On_Hand__c = 80,
            Qty_Reserved__c = 0,
            Qty_Damaged__c = 0
        );
        insert stock;
    }

    @isTest
    static void testSystemQtySnapshot() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'AP001'];

        Test.startTest();
        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Adjustment_Type__c = 'Physical_Count',
            Adjustment_Qty__c = 5,
            Reason__c = 'Physical count variance',
            Status__c = 'Draft',
            Adjustment_Date__c = Date.today()
        );
        insert adj;
        Test.stopTest();

        adj = [SELECT System_Qty__c FROM Stock_Adjustment__c WHERE Id = :adj.Id];
        System.assertEquals(80, adj.System_Qty__c, 'System qty should snapshot at 80');
    }

    @isTest
    static void testPositiveAdjustmentOnApproval() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'AP001'];

        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Adjustment_Type__c = 'Correction_Add',
            Adjustment_Qty__c = 20,
            Reason__c = 'Found missing inventory',
            Status__c = 'Draft',
            Adjustment_Date__c = Date.today()
        );
        insert adj;

        Test.startTest();
        adj.Status__c = 'Approved';
        update adj;
        Test.stopTest();

        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(100, stock.Qty_On_Hand__c, 'Stock should be 100 after +20 adjustment');
    }

    @isTest
    static void testNegativeAdjustmentOnApproval() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'AP001'];

        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Adjustment_Type__c = 'Damage',
            Adjustment_Qty__c = -15,
            Reason__c = 'Damaged goods found',
            Status__c = 'Draft',
            Adjustment_Date__c = Date.today()
        );
        insert adj;

        Test.startTest();
        adj.Status__c = 'Approved';
        update adj;
        Test.stopTest();

        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(65, stock.Qty_On_Hand__c, 'Stock should be 65 after -15 adjustment');
    }

    @isTest
    static void testRejectedAdjustmentNoStockChange() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'AP001'];

        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Adjustment_Type__c = 'Correction_Add',
            Adjustment_Qty__c = 50,
            Reason__c = 'Should not apply',
            Status__c = 'Draft',
            Adjustment_Date__c = Date.today()
        );
        insert adj;

        Test.startTest();
        adj.Status__c = 'Rejected';
        update adj;
        Test.stopTest();

        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(80, stock.Qty_On_Hand__c, 'Stock should remain 80 when rejected');
    }
}