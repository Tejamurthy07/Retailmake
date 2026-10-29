/**
 * @description Test class for INV_StockTransfer_TriggerHandler.
 *              Tests status transition validation and stock deduction/addition on transfer lifecycle.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_StockTransfer_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        Warehouse__c sourceWh = new Warehouse__c(
            Name = 'Source Warehouse',
            Warehouse_Code__c = 'SRC01',
            State__c = 'Maharashtra',
            Warehouse_Type__c = 'Central',
            Is_Active__c = true
        );
        Warehouse__c destWh = new Warehouse__c(
            Name = 'Dest Warehouse',
            Warehouse_Code__c = 'DST01',
            State__c = 'Gujarat',
            Warehouse_Type__c = 'Regional',
            Is_Active__c = true
        );
        insert new List<Warehouse__c>{ sourceWh, destWh };

        Product_Extension__c product = new Product_Extension__c(Name = 'Transfer Product', SKU_Code__c = 'TRP01', Is_Active__c = true);
        insert product;

        Warehouse_Stock__c stock = new Warehouse_Stock__c(
            Warehouse__c = sourceWh.Id,
            Product_Ext__c = product.Id,
            Qty_On_Hand__c = 200,
            Qty_Reserved__c = 0,
            Qty_Damaged__c = 0
        );
        insert stock;
    }

    @isTest
    static void testValidStatusTransition() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert transfer;

        Test.startTest();
        transfer.Status__c = 'Submitted';
        update transfer;
        Test.stopTest();

        transfer = [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('Submitted', transfer.Status__c, 'Should transition to Submitted');
    }

    @isTest
    static void testInvalidStatusTransition() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert transfer;

        Test.startTest();
        transfer.Status__c = 'Received';
        try {
            update transfer;
            System.assert(false, 'Should have thrown validation error');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Invalid status transition'),
                'Error should mention invalid transition');
        }
        Test.stopTest();
    }

    @isTest
    static void testApprovedDeductsFromSource() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Submitted'
        );
        insert transfer;

        Stock_Transfer_Line__c line = new Stock_Transfer_Line__c(
            Stock_Transfer__c = transfer.Id,
            Product_Ext__c = product.Id,
            Requested_Qty__c = 50,
            Approved_Qty__c = 50
        );
        insert line;

        Test.startTest();
        transfer.Status__c = 'Approved';
        update transfer;
        Test.stopTest();

        Warehouse_Stock__c sourceStock = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :sourceWh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(150, sourceStock.Qty_On_Hand__c, 'Source should have 150 after deduction');
    }

    /**
     * Transit shortfall: the source is deducted for the APPROVED quantity and the destination
     * credited with the RECEIVED quantity, so units that left but never arrived are the
     * difference. Short_Qty__c is a formula (Approved - Received), so that loss IS captured and
     * reportable — this pins that behaviour.
     */
    @isTest
    static void testReceiptRecordsTransitShortfall() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Submitted'
        );
        insert transfer;

        Stock_Transfer_Line__c line = new Stock_Transfer_Line__c(
            Stock_Transfer__c = transfer.Id,
            Product_Ext__c = product.Id,
            Requested_Qty__c = 50,
            Approved_Qty__c = 50
        );
        insert line;

        transfer.Status__c = 'Approved';
        update transfer;            // source deducted 50
        transfer.Status__c = 'In_Transit';
        update transfer;

        Test.startTest();
        // Only 45 of the 50 dispatched units actually turn up.
        update new Stock_Transfer_Line__c(Id = line.Id, Received_Qty__c = 45);
        transfer.Status__c = 'Received';
        update transfer;            // destination credited 45
        Test.stopTest();

        Stock_Transfer_Line__c after = [
            SELECT Approved_Qty__c, Received_Qty__c, Short_Qty__c
            FROM Stock_Transfer_Line__c WHERE Id = :line.Id
        ];
        System.assertEquals(5, after.Short_Qty__c,
            'The 5 units that left the source and never arrived are recorded as a transit shortfall');
    }

    @isTest
    static void testCancelledTransfer() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert transfer;

        Test.startTest();
        transfer.Status__c = 'Cancelled';
        update transfer;
        Test.stopTest();

        transfer = [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('Cancelled', transfer.Status__c, 'Should be Cancelled');
    }
}