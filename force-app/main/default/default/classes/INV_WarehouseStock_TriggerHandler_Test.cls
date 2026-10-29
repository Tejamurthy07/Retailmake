/**
 * @description Test class for INV_WarehouseStock_TriggerHandler.
 *              Tests unique constraint enforcement and default value setting.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_WarehouseStock_TriggerHandler_Test {

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

        Product_Extension__c product = new Product_Extension__c(Name = 'Test Product', SKU_Code__c = 'TP001', Is_Active__c = true);
        insert product;
    }

    @isTest
    static void testCreateStockWithDefaults() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Test.startTest();
        Warehouse_Stock__c stock = new Warehouse_Stock__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id
        );
        insert stock;
        Test.stopTest();

        stock = [SELECT Qty_On_Hand__c, Qty_Reserved__c, Qty_Damaged__c FROM Warehouse_Stock__c WHERE Id = :stock.Id];
        System.assertEquals(0, stock.Qty_On_Hand__c, 'Default on hand should be 0');
        System.assertEquals(0, stock.Qty_Reserved__c, 'Default reserved should be 0');
        System.assertEquals(0, stock.Qty_Damaged__c, 'Default damaged should be 0');
    }

    @isTest
    static void testDuplicateWarehouseProductBatchFails() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Warehouse_Stock__c stock1 = new Warehouse_Stock__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Batch_Number__c = 'BATCH001',
            Qty_On_Hand__c = 50
        );
        insert stock1;

        Test.startTest();
        Warehouse_Stock__c stock2 = new Warehouse_Stock__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Batch_Number__c = 'BATCH001',
            Qty_On_Hand__c = 25
        );
        try {
            insert stock2;
            System.assert(false, 'Should have thrown duplicate error');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('already exists') || e.getMessage().contains('duplicate'),
                'Error should mention duplicate: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testDifferentBatchesAllowed() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Warehouse_Stock__c stock1 = new Warehouse_Stock__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Batch_Number__c = 'BATCH001',
            Qty_On_Hand__c = 50
        );
        insert stock1;

        Test.startTest();
        Warehouse_Stock__c stock2 = new Warehouse_Stock__c(
            Warehouse__c = wh.Id,
            Product_Ext__c = product.Id,
            Batch_Number__c = 'BATCH002',
            Qty_On_Hand__c = 25
        );
        insert stock2;
        Test.stopTest();

        List<Warehouse_Stock__c> stocks = [
            SELECT Id FROM Warehouse_Stock__c WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :product.Id
        ];
        System.assertEquals(2, stocks.size(), 'Should allow different batches');
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage: the in-batch duplicate branch, the update path
    //  (never tested), the blank-batch key, and the Product__c blind spot
    //  that StockOperationsHubController bypasses this handler to avoid.
    // ══════════════════════════════════════════════════════════════════

    private static Warehouse_Stock__c stockRow(Id whId, Id productExtId, String batch, Decimal qty) {
        return new Warehouse_Stock__c(
            Warehouse__c = whId,
            Product_Ext__c = productExtId,
            Batch_Number__c = batch,
            Qty_On_Hand__c = qty
        );
    }

    @isTest
    static void duplicatesInsideOneInsert_areBothRejected() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Test.startTest();
        // Both rows arrive in ONE DML — nothing exists in the database yet, so
        // only the in-batch check can catch this.
        List<Database.SaveResult> results = Database.insert(new List<Warehouse_Stock__c>{
            stockRow(wh.Id, product.Id, 'SAME', 10),
            stockRow(wh.Id, product.Id, 'SAME', 20)
        }, false);
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess(), 'The first clashing row is refused');
        System.assertEquals(false, results[1].isSuccess(), 'And so is the second');
        System.assert(results[0].getErrors()[0].getMessage().contains('in this batch'),
            'Named as an in-batch clash, not a database one: '
            + results[0].getErrors()[0].getMessage());
        System.assertEquals(0, [SELECT COUNT() FROM Warehouse_Stock__c],
            'Neither row lands — a bulk load with a doubled key must not half-succeed silently');
    }

    @isTest
    static void sameProductAndBatch_inAnotherWarehouse_isAllowed() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];
        Warehouse__c other = new Warehouse__c(
            Name = 'Other Warehouse', Warehouse_Code__c = 'TW002',
            State__c = 'Maharashtra', Warehouse_Type__c = 'Central', Is_Active__c = true);
        insert other;
        insert stockRow(wh.Id, product.Id, 'BATCH001', 50);

        Test.startTest();
        insert stockRow(other.Id, product.Id, 'BATCH001', 25);
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Warehouse_Stock__c],
            'The same batch legitimately sits in two warehouses — the key is per warehouse');
    }

    @isTest
    static void blankAndNamedBatches_areDistinctKeys() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];
        insert stockRow(wh.Id, product.Id, null, 50);

        Test.startTest();
        // A batched row alongside the batchless one is fine…
        insert stockRow(wh.Id, product.Id, 'BATCH001', 25);
        // …but a second batchless row for the same product is a duplicate.
        Database.SaveResult secondBlank = Database.insert(
            stockRow(wh.Id, product.Id, null, 10), false);
        Test.stopTest();

        System.assertEquals(false, secondBlank.isSuccess(),
            'Blank batch is itself a key value — two unbatched rows for one product would '
            + 'split the on-hand figure across duplicates');
        System.assertEquals(2, [SELECT COUNT() FROM Warehouse_Stock__c],
            'The batchless and the batched row coexist');
    }

    @isTest
    static void update_ontoAnExistingKey_isBlocked() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];
        insert stockRow(wh.Id, product.Id, 'BATCH001', 50);
        Warehouse_Stock__c movable = stockRow(wh.Id, product.Id, 'BATCH002', 25);
        insert movable;

        Test.startTest();
        movable.Batch_Number__c = 'BATCH001';
        Database.SaveResult sr = Database.update(movable, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'Renaming a batch onto a key that already exists is the same duplicate through '
            + 'the side door — beforeUpdate must catch what beforeInsert would have');
        System.assert(sr.getErrors()[0].getMessage().contains('already exists'),
            'With the existing-record message: ' + sr.getErrors()[0].getMessage());
    }

    @isTest
    static void update_ofARecordsOwnFields_doesNotClashWithItself() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c LIMIT 1];
        Warehouse_Stock__c stock = stockRow(wh.Id, product.Id, 'BATCH001', 50);
        insert stock;

        Test.startTest();
        stock.Qty_On_Hand__c = 75;
        update stock;
        Test.stopTest();

        System.assertEquals(75, [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c WHERE Id = :stock.Id
        ].Qty_On_Hand__c,
            'An ordinary quantity edit keeps its own key — the self-exclusion is what makes '
            + 'every routine stock movement possible at all');
    }

    /**
     * KNOWN DEFECT — the uniqueness key is built from Product_Ext__c only, but
     * Warehouse_Stock__c carries TWO product lookups and the Stock Operations
     * Hub writes Product__c (Product2), leaving Product_Ext__c null. Two rows
     * for genuinely different Product2 products then both key to
     * "warehouse|null|batch" and are rejected as duplicates of each other.
     *
     * This is exactly why StockOperationsHubController wraps its upserts in
     * TriggerHandler.bypass('INV_WarehouseStock_TriggerHandler') — the guard
     * cannot tell hub-managed rows apart. The fix is to key on whichever
     * product lookup is populated (or to converge on one lookup). When that
     * lands, this test should be rewritten to assert BOTH rows insert.
     */
    @isTest
    static void KNOWN_DEFECT_distinctProduct2Rows_collideAsDuplicates() {
        Warehouse__c wh = [SELECT Id FROM Warehouse__c LIMIT 1];
        insert new List<Product2>{
            new Product2(Name = 'P2 Alpha', ProductCode = 'P2-A', IsActive = true),
            new Product2(Name = 'P2 Beta', ProductCode = 'P2-B', IsActive = true)
        };
        List<Product2> p2s = [SELECT Id FROM Product2 ORDER BY ProductCode];

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(new List<Warehouse_Stock__c>{
            new Warehouse_Stock__c(Warehouse__c = wh.Id, Product__c = p2s[0].Id, Qty_On_Hand__c = 10),
            new Warehouse_Stock__c(Warehouse__c = wh.Id, Product__c = p2s[1].Id, Qty_On_Hand__c = 20)
        }, false);
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess(),
            'Two DIFFERENT products are rejected as duplicates, because the key reads the '
            + 'null Product_Ext__c on both rows');
        System.assertEquals(false, results[1].isSuccess(), 'Both of them');
        System.assert(results[0].getErrors()[0].getMessage().contains('in this batch'),
            'Keyed identically despite being distinct stock: '
            + results[0].getErrors()[0].getMessage());
    }
}