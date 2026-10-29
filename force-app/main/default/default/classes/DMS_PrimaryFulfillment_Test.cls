/**
 * @description Phase 1 tests for the DMS primary fulfillment loop:
 *              Indent approval -> primary Invoice + warehouse deduction -> GRN
 *              receipt -> Distributor_Stock posting -> Indent Received.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_PrimaryFulfillment_Test {

    private static void enableDmsToggles() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_PRIMARY_FULFILLMENT, true);
        // This suite exercises the deprecated Indent__c path, which is now opt-in.
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_LEGACY_INDENT_FULFILLMENT, true);
    }

    private static Warehouse__c createWarehouse() {
        Warehouse__c wh = new Warehouse__c(
            Name = 'Test Source WH',
            Warehouse_Code__c = 'WHDMS1', // alphanumeric only (3-20) per the Warehouse Code rule
            Is_Active__c = true
        );
        insert wh;
        return wh;
    }

    private static void seedWarehouseStock(Id warehouseId, List<Product_Extension__c> products) {
        List<Warehouse_Stock__c> stock = new List<Warehouse_Stock__c>();
        for (Product_Extension__c p : products) {
            stock.add(new Warehouse_Stock__c(
                Warehouse__c = warehouseId,
                Product_Ext__c = p.Id,
                Qty_On_Hand__c = 1000
            ));
        }
        insert stock;
    }

    private static Indent__c createApprovableIndent(
        Id accountId, Id warehouseId, List<Product_Extension__c> products
    ) {
        Indent__c indent = new Indent__c(
            Account__c = accountId,
            Source_Warehouse__c = warehouseId,
            Indent_Date__c = Date.today(),
            Requested_Delivery_Date__c = Date.today().addDays(5),
            Status__c = 'Submitted'
        );
        insert indent;

        List<Indent_Line__c> lines = new List<Indent_Line__c>();
        for (Integer i = 0; i < products.size(); i++) {
            lines.add(new Indent_Line__c(
                Indent__c = indent.Id,
                Product_Ext__c = products[i].Id,
                Requested_Qty__c = (i + 1) * 10,
                Approved_Qty__c = (i + 1) * 10,
                Unit_Price__c = 100
            ));
        }
        insert lines;
        return indent;
    }

    @isTest
    static void approval_createsPrimaryInvoice_andDeductsWarehouse() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist A', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(2);
        Warehouse__c wh = createWarehouse();
        seedWarehouseStock(wh.Id, products);
        Indent__c indent = createApprovableIndent(dist.Id, wh.Id, products);

        enableDmsToggles();
        Test.startTest();
        update new Indent__c(Id = indent.Id, Status__c = 'Approved');
        Test.stopTest();

        Indent__c after = [SELECT Status__c, Invoice__c FROM Indent__c WHERE Id = :indent.Id];
        System.assertEquals('Dispatched', after.Status__c, 'Indent advanced to Dispatched');
        System.assertNotEquals(null, after.Invoice__c, 'Primary invoice linked to indent');

        Invoice__c inv = [
            SELECT Order_Type__c, Account__c, Warehouse__c FROM Invoice__c WHERE Id = :after.Invoice__c
        ];
        System.assertEquals('Primary', inv.Order_Type__c, 'Invoice is primary');
        System.assertEquals(dist.Id, inv.Account__c, 'Invoice billed to distributor');
        System.assertEquals(wh.Id, inv.Warehouse__c, 'Invoice sourced from warehouse');

        System.assertEquals(2, [SELECT COUNT() FROM Invoice_Line__c WHERE Invoice__c = :inv.Id],
            'One invoice line per indent line');

        // Product 0 had qty 10; on-hand was 1000 -> 990.
        Warehouse_Stock__c ws = [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :products[0].Id LIMIT 1
        ];
        System.assertEquals(990, ws.Qty_On_Hand__c, 'Warehouse stock deducted for dispatched qty');
    }

    @isTest
    static void grnReceipt_postsDistributorStock_andReceivesIndent() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist B', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Warehouse__c wh = createWarehouse();
        seedWarehouseStock(wh.Id, products);
        Indent__c indent = createApprovableIndent(dist.Id, wh.Id, products);

        enableDmsToggles();
        update new Indent__c(Id = indent.Id, Status__c = 'Approved');

        Id invoiceId = [SELECT Invoice__c FROM Indent__c WHERE Id = :indent.Id].Invoice__c;

        // Distributor receives the dispatch via GRN.
        GRN__c grn = new GRN__c(
            Account__c = dist.Id,
            Invoice__c = invoiceId,
            GRN_Date__c = Date.today(),
            Status__c = 'Pending'
        );
        insert grn;
        insert new GRN_Line__c(
            GRN__c = grn.Id,
            Product_Ext__c = products[0].Id,
            Received_Qty__c = 10,
            Damaged_Qty__c = 0,
            Batch_No__c = 'B-001'
        );

        Test.startTest();
        update new GRN__c(Id = grn.Id, Status__c = 'Received');
        Test.stopTest();

        Distributor_Stock__c ds = [
            SELECT Received_Qty__c, Closing_Stock__c, Is_Current__c, Batch_No__c
            FROM Distributor_Stock__c
            WHERE Account__c = :dist.Id AND Product_Ext__c = :products[0].Id LIMIT 1
        ];
        System.assertEquals(10, ds.Received_Qty__c, 'Received qty posted to distributor stock');
        System.assertEquals(10, ds.Closing_Stock__c, 'Closing stock computed');
        System.assertEquals(true, ds.Is_Current__c, 'New snapshot is current');

        System.assertEquals(1, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Account__c = :dist.Id AND Direction__c = 'In' AND Reference_Type__c = 'GRN'
        ], 'Distributor stock-in transaction written');

        Indent__c after = [SELECT Status__c FROM Indent__c WHERE Id = :indent.Id];
        System.assertEquals('Received', after.Status__c, 'Indent advanced to Received');
    }

    /**
     * Two GRN lines on the SAME product+batch used to produce two snapshots that each opened
     * from the same pre-transaction closing, and both stayed Is_Current__c = true — so the
     * on-hand read (which sums current rows) counted the opening balance twice. With a prior
     * balance of 20 and a receipt of 10 + 6, on-hand read 56 instead of 36.
     */
    @isTest
    static void grnReceipt_sameProductBatchTwice_doesNotDoubleCountOpening() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist Dup', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Warehouse__c wh = createWarehouse();
        seedWarehouseStock(wh.Id, products);
        Indent__c indent = createApprovableIndent(dist.Id, wh.Id, products);

        enableDmsToggles();
        update new Indent__c(Id = indent.Id, Status__c = 'Approved');
        Id invoiceId = [SELECT Invoice__c FROM Indent__c WHERE Id = :indent.Id].Invoice__c;

        // Prior distributor position for this product+batch: 20 on hand.
        insert new Distributor_Stock__c(
            Account__c = dist.Id, Product_Ext__c = products[0].Id, Batch_No__c = 'B-001',
            Opening_Stock__c = 0, Received_Qty__c = 20, Sold_Qty__c = 0, Damaged_Qty__c = 0,
            Stock_Date__c = Date.today(), Is_Current__c = true
        );

        // One GRN carrying the same product+batch across TWO lines.
        GRN__c grn = new GRN__c(
            Account__c = dist.Id, Invoice__c = invoiceId,
            GRN_Date__c = Date.today(), Status__c = 'Pending'
        );
        insert grn;
        insert new List<GRN_Line__c>{
            new GRN_Line__c(GRN__c = grn.Id, Product_Ext__c = products[0].Id,
                Received_Qty__c = 10, Damaged_Qty__c = 0, Batch_No__c = 'B-001'),
            new GRN_Line__c(GRN__c = grn.Id, Product_Ext__c = products[0].Id,
                Received_Qty__c = 6, Damaged_Qty__c = 0, Batch_No__c = 'B-001')
        };

        Test.startTest();
        update new GRN__c(Id = grn.Id, Status__c = 'Received');
        Test.stopTest();

        List<Distributor_Stock__c> current = [
            SELECT Opening_Stock__c, Received_Qty__c, Closing_Stock__c
            FROM Distributor_Stock__c
            WHERE Account__c = :dist.Id AND Product_Ext__c = :products[0].Id
              AND Batch_No__c = 'B-001' AND Is_Current__c = true
        ];
        System.assertEquals(1, current.size(),
            'Exactly one current snapshot per Account+Product+Batch — two would double-count on hand');
        System.assertEquals(20, current[0].Opening_Stock__c, 'Opens from the real prior position');
        System.assertEquals(16, current[0].Received_Qty__c, 'Both lines summed into one snapshot (10 + 6)');
        System.assertEquals(36, current[0].Closing_Stock__c, '20 + 16 — not 20 counted twice');

        // Line-level audit detail is still preserved: one ledger entry per GRN line.
        System.assertEquals(2, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Account__c = :dist.Id AND Reference_Type__c = 'GRN' AND Reference_Id__c = :grn.Id
        ], 'One stock transaction per GRN line');
    }

    /**
     * Batch numbers are free text across the whole model, so a batch had no referential
     * integrity and every document re-typed its own expiry date. Stock now resolves the batch
     * to its Batch_Master and takes the expiry from there — the batch's own definition.
     */
    @isTest
    static void grnReceipt_resolvesBatchMaster_andTakesItsExpiry() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist BM', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Warehouse__c wh = createWarehouse();
        seedWarehouseStock(wh.Id, products);
        Indent__c indent = createApprovableIndent(dist.Id, wh.Id, products);

        // The batch's own definition: expires in 60 days.
        Batch_Master__c bm = new Batch_Master__c(
            Batch_Number__c = 'BM-RESOLVE-1',
            Product_Ext__c = products[0].Id,
            Manufacturing_Date__c = Date.today().addDays(-10),
            Expiry_Date__c = Date.today().addDays(60),
            Quantity_Manufactured__c = 1000
        );
        insert bm;

        enableDmsToggles();
        update new Indent__c(Id = indent.Id, Status__c = 'Approved');
        Id invoiceId = [SELECT Invoice__c FROM Indent__c WHERE Id = :indent.Id].Invoice__c;

        GRN__c grn = new GRN__c(Account__c = dist.Id, Invoice__c = invoiceId,
            GRN_Date__c = Date.today(), Status__c = 'Pending');
        insert grn;
        // The GRN line re-types a DIFFERENT expiry — the master must win.
        insert new GRN_Line__c(
            GRN__c = grn.Id, Product_Ext__c = products[0].Id,
            Received_Qty__c = 10, Damaged_Qty__c = 0,
            Batch_No__c = 'BM-RESOLVE-1', Expiry_Date__c = Date.today().addDays(5)
        );

        Test.startTest();
        update new GRN__c(Id = grn.Id, Status__c = 'Received');
        Test.stopTest();

        Distributor_Stock__c ds = [
            SELECT Batch_Master__c, Expiry_Date__c FROM Distributor_Stock__c
            WHERE Account__c = :dist.Id AND Product_Ext__c = :products[0].Id
              AND Is_Current__c = true LIMIT 1
        ];
        System.assertEquals(bm.Id, ds.Batch_Master__c,
            'Free-text batch resolved to its Batch_Master — batches now have referential integrity');
        System.assertEquals(Date.today().addDays(60), ds.Expiry_Date__c,
            'Expiry comes from the batch master, not the date re-typed on the GRN line');
    }

    @isTest
    static void approval_withTogglesOff_doesNothing() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist C', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Warehouse__c wh = createWarehouse();
        seedWarehouseStock(wh.Id, products);
        Indent__c indent = createApprovableIndent(dist.Id, wh.Id, products);

        // Toggles intentionally left disabled.
        Test.startTest();
        update new Indent__c(Id = indent.Id, Status__c = 'Approved');
        Test.stopTest();

        Indent__c after = [SELECT Status__c, Invoice__c FROM Indent__c WHERE Id = :indent.Id];
        System.assertEquals('Approved', after.Status__c, 'Status unchanged when DMS disabled');
        System.assertEquals(null, after.Invoice__c, 'No invoice generated when DMS disabled');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c WHERE Account__c = :dist.Id],
            'No primary invoice created when DMS disabled');
    }
}