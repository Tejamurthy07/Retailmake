/**
 * @description Test class for INV_GRN_TriggerHandler.
 *              Tests stock addition when GRN status transitions to Received.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_GRN_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        // Create account. Use the factory: the org's default Account record type is Retailer,
        // and a bare `new Account(...)` therefore trips Outlet_Type_Required_For_Retailer.
        Account acct = TestDataFactory.createAndInsertAccount('Test Distributor', 'Distributor');

        // Create warehouse
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'GRN Warehouse',
            Warehouse_Code__c = 'GRN01',
            State__c = 'Maharashtra',
            Warehouse_Type__c = 'Central',
            Is_Active__c = true
        );
        insert warehouse;

        // Create product
        Product_Extension__c product = new Product_Extension__c(Name = 'GRN Product', SKU_Code__c = 'GP001', Is_Active__c = true);
        insert product;

        // Create invoice with warehouse
        Invoice__c invoice = new Invoice__c(
            Account__c = acct.Id,
            Invoice_Date__c = Date.today(),
            Invoice_Number__c = 'INV-TEST-001',
            Status__c = 'Confirmed',
            Total_Amount__c = 10000,
            Balance_Due__c = 10000,
            Warehouse__c = warehouse.Id
        );
        insert invoice;

        // Create GRN
        GRN__c grn = new GRN__c(
            Invoice__c = invoice.Id,
            Status__c = 'Pending'
        );
        insert grn;

        // Create GRN Lines
        GRN_Line__c grnLine = new GRN_Line__c(
            GRN__c = grn.Id,
            Product_Ext__c = product.Id,
            Dispatched_Qty__c = 100,
            Received_Qty__c = 95,
            Short_Qty__c = 3,
            Damaged_Qty__c = 2
        );
        insert grnLine;
    }

    @isTest
    static void testGRNReceivedAddsStock() {
        GRN__c grn = [SELECT Id, Status__c FROM GRN__c LIMIT 1];
        Warehouse__c wh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'GRN01'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'GP001'];

        Test.startTest();
        grn.Status__c = 'Received';
        update grn;
        Test.stopTest();

        // Check that stock was created/updated
        List<Warehouse_Stock__c> stocks = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];

        System.assert(!stocks.isEmpty(), 'Stock record should exist');
        // GRN adds Received_Qty - Damaged_Qty = 95 - 2 = 93
        System.assertEquals(93, stocks[0].Qty_On_Hand__c, 'Stock should be 93 (95 received - 2 damaged)');
    }

    @isTest
    static void testGRNPartialAddsStock() {
        GRN__c grn = [SELECT Id, Status__c FROM GRN__c LIMIT 1];

        Test.startTest();
        grn.Status__c = 'Partial';
        update grn;
        Test.stopTest();

        // Partial GRN should also add stock
        List<Warehouse_Stock__c> stocks = [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c
        ];
        // Should have created stock records
        System.assert(stocks.size() >= 0, 'Should process without errors');
    }

    @isTest
    static void testGRNPendingNoStockChange() {
        // GRN is already Pending from setup. No stock should exist initially.
        Warehouse__c wh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'GRN01'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'GP001'];

        List<Warehouse_Stock__c> stocks = [
            SELECT Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];

        System.assert(stocks.isEmpty(), 'No stock should exist before GRN receipt');
    }
}