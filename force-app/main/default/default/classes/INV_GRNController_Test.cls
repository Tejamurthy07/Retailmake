/**
 * @description Test class for INV_GRNController.
 *              Covers all @AuraEnabled methods including list, detail, create,
 *              status update, line items, product search, and warehouse options.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_GRNController_Test {

    @TestSetup
    static void setupTestData() {
        // Account
        Account acct = TestDataFactory.createAndInsertAccount('GRN Test Distributor', 'Distributor');

        // Warehouse
        Warehouse__c warehouse = new Warehouse__c(
            Name = 'GRN Test Warehouse',
            Warehouse_Code__c = 'GRNTEST01',
            State__c = 'Maharashtra',
            Warehouse_Type__c = 'Central',
            Is_Active__c = true
        );
        insert warehouse;

        // Products
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(3);

        // Invoice linked to warehouse
        Invoice__c invoice = new Invoice__c(
            Account__c = acct.Id,
            Invoice_Date__c = Date.today(),
            Invoice_Number__c = 'INV-GRN-TEST-001',
            Status__c = 'Confirmed',
            Total_Amount__c = 50000,
            Balance_Due__c = 50000,
            Warehouse__c = warehouse.Id
        );
        insert invoice;

        // GRN
        GRN__c grn = new GRN__c(
            Invoice__c = invoice.Id,
            Account__c = acct.Id,
            GRN_Date__c = Date.today(),
            Status__c = 'Pending',
            Received_By__c = 'Test Receiver',
            Notes__c = 'Test GRN'
        );
        insert grn;

        // GRN Lines
        List<GRN_Line__c> lines = new List<GRN_Line__c>();
        for (Product_Extension__c prod : products) {
            lines.add(new GRN_Line__c(
                GRN__c = grn.Id,
                Product_Ext__c = prod.Id,
                Dispatched_Qty__c = 100,
                Received_Qty__c = 95,
                Short_Qty__c = 3,
                Damaged_Qty__c = 2,
                Batch_No__c = 'BATCH-001'
            ));
        }
        insert lines;
    }

    @isTest
    static void testGetGRNs_NoFilters() {
        Test.startTest();
        List<GRN__c> results = INV_GRNController.getGRNs(null, null, null, null);
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return at least one GRN');
    }

    @isTest
    static void testGetGRNs_WithStatusFilter() {
        Test.startTest();
        List<GRN__c> results = INV_GRNController.getGRNs('Pending', null, null, null);
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return Pending GRNs');
        for (GRN__c grn : results) {
            System.assertEquals('Pending', grn.Status__c, 'All returned GRNs should be Pending');
        }
    }

    @isTest
    static void testGetGRNs_WithAllFilters() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'GRNTEST01'];

        Test.startTest();
        List<GRN__c> results = INV_GRNController.getGRNs(
            'Pending',
            Date.today().addDays(-1),
            Date.today().addDays(1),
            wh.Id
        );
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should return GRNs matching all filters');
    }

    @isTest
    static void testGetGRNs_StatusAll() {
        Test.startTest();
        List<GRN__c> results = INV_GRNController.getGRNs('all', null, null, null);
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Status "all" should return GRNs');
    }

    @isTest
    static void testGetGRNById() {
        GRN__c grn = [SELECT Id FROM GRN__c LIMIT 1];

        Test.startTest();
        INV_GRNController.GRNDetail detail = INV_GRNController.getGRNById(grn.Id);
        Test.stopTest();

        System.assertNotEquals(null, detail.grn, 'GRN header should be returned');
        System.assert(!detail.lineItems.isEmpty(), 'GRN should have line items');
        System.assertEquals(3, detail.lineItems.size(), 'Should have 3 line items');
    }

    @isTest
    static void testCreateGRN() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Invoice__c inv = [SELECT Id FROM Invoice__c LIMIT 1];
        List<Product_Extension__c> products = [SELECT Id FROM Product_Extension__c LIMIT 2];

        INV_GRNController.GRNInput input = new INV_GRNController.GRNInput();
        input.invoiceId = inv.Id;
        input.accountId = acct.Id;
        input.grnDate = Date.today();
        input.receivedBy = 'Unit Test';
        input.notes = 'Created by test';
        input.lineItems = new List<INV_GRNController.GRNLineInput>();

        for (Product_Extension__c prod : products) {
            INV_GRNController.GRNLineInput line = new INV_GRNController.GRNLineInput();
            line.productId = prod.Id;
            line.batchNo = 'TEST-BATCH';
            line.dispatchedQty = 50;
            line.receivedQty = 48;
            line.shortQty = 2;
            line.damagedQty = 0;
            line.expiryDate = Date.today().addMonths(6);
            line.notes = 'Test line';
            input.lineItems.add(line);
        }

        String grnJson = JSON.serialize(input);

        Test.startTest();
        Id grnId = INV_GRNController.createGRN(grnJson);
        Test.stopTest();

        System.assertNotEquals(null, grnId, 'GRN Id should be returned');

        GRN__c created = [SELECT Status__c, Notes__c FROM GRN__c WHERE Id = :grnId];
        System.assertEquals('Pending', created.Status__c, 'New GRN should be Pending');

        List<GRN_Line__c> createdLines = [SELECT Id FROM GRN_Line__c WHERE GRN__c = :grnId];
        System.assertEquals(2, createdLines.size(), 'Should have 2 line items');
    }

    @isTest
    static void testCreateGRN_NoLineItems() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Invoice__c inv = [SELECT Id FROM Invoice__c LIMIT 1];

        INV_GRNController.GRNInput input = new INV_GRNController.GRNInput();
        input.invoiceId = inv.Id;
        input.accountId = acct.Id;
        input.notes = 'Header only';

        String grnJson = JSON.serialize(input);

        Test.startTest();
        Id grnId = INV_GRNController.createGRN(grnJson);
        Test.stopTest();

        System.assertNotEquals(null, grnId, 'GRN should be created even without lines');
    }

    @isTest
    static void testUpdateGRNStatus_PendingToReceived() {
        GRN__c grn = [SELECT Id, Status__c FROM GRN__c LIMIT 1];

        Test.startTest();
        INV_GRNController.updateGRNStatus(grn.Id, 'Received');
        Test.stopTest();

        GRN__c updated = [SELECT Status__c FROM GRN__c WHERE Id = :grn.Id];
        System.assertEquals('Received', updated.Status__c, 'Status should be Received');
    }

    @isTest
    static void testUpdateGRNStatus_PendingToPartial() {
        GRN__c grn = [SELECT Id FROM GRN__c LIMIT 1];

        Test.startTest();
        INV_GRNController.updateGRNStatus(grn.Id, 'Partial');
        Test.stopTest();

        GRN__c updated = [SELECT Status__c FROM GRN__c WHERE Id = :grn.Id];
        System.assertEquals('Partial', updated.Status__c, 'Status should be Partial');
    }

    @isTest
    static void testUpdateGRNStatus_InvalidTransition() {
        GRN__c grn = [SELECT Id, Status__c FROM GRN__c LIMIT 1];
        // First move to Received
        grn.Status__c = 'Received';
        update grn;

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            INV_GRNController.updateGRNStatus(grn.Id, 'Pending');
        } catch (AuraHandledException e) {
            // AHE messages built via the constructor read 'Script-thrown
            // exception' in test context — the wording is not assertable.
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw exception for invalid transition');
        System.assertEquals('Received',
            [SELECT Status__c FROM GRN__c WHERE Id = :grn.Id].Status__c,
            'A refused transition leaves the GRN exactly where it was');
    }

    @isTest
    static void testGetGRNLineItems() {
        GRN__c grn = [SELECT Id FROM GRN__c LIMIT 1];

        Test.startTest();
        List<GRN_Line__c> lines = INV_GRNController.getGRNLineItems(grn.Id);
        Test.stopTest();

        System.assertEquals(3, lines.size(), 'Should return 3 line items');
    }

    @isTest
    static void testSearchProducts() {
        Test.startTest();
        List<Product_Extension__c> results = INV_GRNController.searchProducts('Test Product');
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should find products matching search term');
    }

    @isTest
    static void testSearchProducts_BySKU() {
        Test.startTest();
        List<Product_Extension__c> results = INV_GRNController.searchProducts('TP-');
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Should find products by SKU prefix');
    }

    @isTest
    static void testSearchProducts_BlankTerm() {
        Test.startTest();
        List<Product_Extension__c> results = INV_GRNController.searchProducts('');
        Test.stopTest();

        System.assert(!results.isEmpty(), 'Blank search should return active products');
    }

    @isTest
    static void testGetWarehouseOptions() {
        Test.startTest();
        List<Warehouse__c> warehouses = INV_GRNController.getWarehouseOptions();
        Test.stopTest();

        System.assert(!warehouses.isEmpty(), 'Should return at least one active warehouse');
        System.assertEquals('GRN Test Warehouse', warehouses[0].Name, 'Should return the test warehouse');
    }
}