/**
 * @description Tests the company-wide stock overview: warehouse on-hand, distributor on-hand,
 *              in-transit transfers, near-expiry alerts and the movement ledger.
 */
@isTest
private class INV_StockManagementController_Test {

    @isTest
    static void overview_rollsUpTheWholeChain() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SM', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);

        Warehouse__c wh = new Warehouse__c(
            Name = 'SM Warehouse', Warehouse_Code__c = 'SMWH1',
            State__c = 'Maharashtra', Is_Active__c = true
        );
        insert wh;

        // Warehouse holds 100, one batch expiring soon (drives the near-expiry alert).
        insert new Warehouse_Stock__c(
            Warehouse__c = wh.Id, Product_Ext__c = products[0].Id,
            Batch_Number__c = 'SM-B1', Expiry_Date__c = Date.today().addDays(5),
            Qty_On_Hand__c = 100, Qty_Reserved__c = 0
        );

        // Distributor holds 40.
        insert new Distributor_Stock__c(
            Account__c = dist.Id, Product_Ext__c = products[0].Id, Batch_No__c = 'SM-B1',
            Opening_Stock__c = 0, Received_Qty__c = 40, Sold_Qty__c = 0, Damaged_Qty__c = 0,
            Stock_Date__c = Date.today(), Is_Current__c = true
        );

        Test.startTest();
        INV_StockManagementController.Overview o = INV_StockManagementController.getOverview();
        Test.stopTest();

        System.assert(o.warehouseUnits >= 100, 'Warehouse on-hand rolled up');
        System.assert(o.distributorUnits >= 40, 'Distributor on-hand rolled up');
        System.assert(!o.warehouses.isEmpty(), 'Warehouse breakdown returned');
        System.assert(!o.distributors.isEmpty(), 'Distributor breakdown returned');
        System.assert(o.nearExpiryCount >= 1, 'Batch expiring inside the near-expiry window is flagged');
        System.assertNotEquals(null, o.movements, 'Movement ledger returned');
        System.assertNotEquals(null, o.inTransit, 'In-transit list returned');
    }
}