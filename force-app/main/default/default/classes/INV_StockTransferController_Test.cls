/**
 * @description Test class for INV_StockTransferController.
 *              Tests transfer CRUD operations, submit, and receive flows.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class INV_StockTransferController_Test {

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
            Name = 'Destination Warehouse',
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
    static void testCreateTransfer() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];

        String lineItemsJson = '[{"productId":"' + product.Id + '","batchNumber":null,"requestedQty":50}]';

        Test.startTest();
        Id transferId = INV_StockTransferController.createTransfer(
            sourceWh.Id, destWh.Id, Date.today(), 'Test transfer', lineItemsJson
        );
        Test.stopTest();

        System.assertNotEquals(null, transferId, 'Transfer ID should not be null');

        Stock_Transfer__c transfer = [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transferId];
        System.assertEquals('Draft', transfer.Status__c, 'Transfer should be in Draft');

        List<Stock_Transfer_Line__c> lines = [
            SELECT Requested_Qty__c FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId
        ];
        System.assertEquals(1, lines.size(), 'Should have 1 line item');
        System.assertEquals(50, lines[0].Requested_Qty__c, 'Requested qty should be 50');
    }

    @isTest
    static void testGetTransfers() {
        // Create a transfer
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Draft',
            Requested_By__c = UserInfo.getUserId()
        );
        insert transfer;

        Test.startTest();
        List<Stock_Transfer__c> transfers = INV_StockTransferController.getTransfers(sourceWh.Id, 'all');
        Test.stopTest();

        System.assertEquals(1, transfers.size(), 'Should find 1 transfer');
    }

    @isTest
    static void testGetTransferDetail() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert transfer;

        Stock_Transfer_Line__c line = new Stock_Transfer_Line__c(
            Stock_Transfer__c = transfer.Id,
            Product_Ext__c = product.Id,
            Requested_Qty__c = 30
        );
        insert line;

        Test.startTest();
        INV_StockTransferController.TransferDetail detail =
            INV_StockTransferController.getTransferDetail(transfer.Id);
        Test.stopTest();

        System.assertNotEquals(null, detail.transfer, 'Transfer should not be null');
        System.assertEquals(1, detail.lineItems.size(), 'Should have 1 line item');
    }

    @isTest
    static void testSubmitTransfer() {
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
        INV_StockTransferController.submitTransfer(transfer.Id);
        Test.stopTest();

        transfer = [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('Submitted', transfer.Status__c, 'Should be Submitted');
    }

    @isTest
    static void testSubmitNonDraftFails() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Submitted'
        );
        insert transfer;

        Test.startTest();
        Boolean threw = false;
        try {
            INV_StockTransferController.submitTransfer(transfer.Id);
        } catch (AuraHandledException e) {
            // AHE messages built via the constructor read 'Script-thrown exception'
            // in test context, so the type and the unchanged status are the
            // assertable signals — the wording is not.
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A non-draft transfer must be refused');
        System.assertEquals('Submitted',
            [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transfer.Id].Status__c,
            'And its status is untouched');
    }

    @isTest
    static void testGetAvailableProducts() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];

        Test.startTest();
        List<Warehouse_Stock__c> products =
            INV_StockTransferController.getAvailableProducts(sourceWh.Id, null);
        Test.stopTest();

        System.assertEquals(1, products.size(), 'Should find 1 available product');
    }

    @isTest
    static void testGetAvailableProductsWithSearch() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];

        Test.startTest();
        List<Warehouse_Stock__c> products =
            INV_StockTransferController.getAvailableProducts(sourceWh.Id, 'Transfer');
        Test.stopTest();

        System.assertEquals(1, products.size(), 'Should find 1 product matching search');
    }

    @isTest
    static void testReceiveTransfer() {
        Warehouse__c sourceWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'SRC01'];
        Warehouse__c destWh = [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = 'DST01'];
        Product_Extension__c product = [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];

        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWh.Id,
            Destination_Warehouse__c = destWh.Id,
            Transfer_Date__c = Date.today(),
            Status__c = 'Approved'
        );
        insert transfer;

        Stock_Transfer_Line__c line = new Stock_Transfer_Line__c(
            Stock_Transfer__c = transfer.Id,
            Product_Ext__c = product.Id,
            Requested_Qty__c = 40,
            Approved_Qty__c = 40
        );
        insert line;

        String receivedJson = '[{"lineItemId":"' + line.Id + '","receivedQty":38}]';

        Test.startTest();
        INV_StockTransferController.receiveTransfer(transfer.Id, receivedJson);
        Test.stopTest();

        transfer = [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transfer.Id];
        System.assertEquals('Received', transfer.Status__c, 'Should be Received');

        line = [SELECT Received_Qty__c FROM Stock_Transfer_Line__c WHERE Id = :line.Id];
        System.assertEquals(38, line.Received_Qty__c, 'Received qty should be 38');
    }

    // ═════════════ Extended coverage: approval, stock movement, filters ═════════════
    // The tests above never call approveTransfer — the only method that makes a
    // transfer move stock — and never assert a single warehouse quantity. The
    // tests below follow the units.

    private static Id warehouseId(String code) {
        return [SELECT Id FROM Warehouse__c WHERE Warehouse_Code__c = :code].Id;
    }

    @isTest
    static void fullLifecycle_movesTheUnitsWarehouseToWarehouse() {
        Id src = warehouseId('SRC01');
        Id dst = warehouseId('DST01');
        Product_Extension__c product =
            [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];

        Test.startTest();
        Id transferId = INV_StockTransferController.createTransfer(
            src, dst, Date.today(), 'lifecycle',
            '[{"productId":"' + product.Id + '","batchNumber":null,"requestedQty":50}]');

        Stock_Transfer_Line__c line = [
            SELECT Id, Available_Stock__c FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c = :transferId];
        System.assertEquals(200, line.Available_Stock__c,
            'Creation snapshots what the source could see at request time');

        INV_StockTransferController.submitTransfer(transferId);
        INV_StockTransferController.approveTransfer(transferId);

        line = [SELECT Approved_Qty__c FROM Stock_Transfer_Line__c WHERE Id = :line.Id];
        System.assertEquals(50, line.Approved_Qty__c,
            'Approval grants the full requested quantity — the deduction keys off this field');
        Warehouse_Stock__c sourceStock = [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c
            WHERE Warehouse__c = :src AND Product_Ext__c = :product.Id];
        System.assertEquals(150, sourceStock.Qty_On_Hand__c,
            'Approval is the moment the units leave the source: 200 - 50');

        INV_StockTransferController.receiveTransfer(transferId,
            '[{"lineItemId":"' + line.Id + '","receivedQty":45}]');
        Test.stopTest();

        Stock_Transfer__c done = [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transferId];
        System.assertEquals('Received', done.Status__c,
            'From Approved the controller steps through In_Transit, so the guarded '
            + 'transition map is satisfied');
        List<Warehouse_Stock__c> destStock = [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c
            WHERE Warehouse__c = :dst AND Product_Ext__c = :product.Id];
        System.assertEquals(1, destStock.size(), 'Receipt creates the destination stock row');
        System.assertEquals(45, destStock[0].Qty_On_Hand__c,
            'The destination gets what actually arrived, not what was approved');
        line = [SELECT Short_Qty__c FROM Stock_Transfer_Line__c WHERE Id = :line.Id];
        System.assertEquals(5, line.Short_Qty__c,
            'The 5 units lost in transit are not silently dropped — the shortfall '
            + 'formula reports approved minus received');
    }

    @isTest
    static void approve_refusesAnythingButSubmitted() {
        Stock_Transfer__c draft = new Stock_Transfer__c(
            Source_Warehouse__c = warehouseId('SRC01'),
            Destination_Warehouse__c = warehouseId('DST01'),
            Transfer_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert draft;

        Test.startTest();
        Boolean threw = false;
        try {
            INV_StockTransferController.approveTransfer(draft.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A draft cannot jump straight to Approved');
        System.assertEquals('Draft',
            [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :draft.Id].Status__c,
            'And nothing moved');
    }

    @isTest
    static void receive_refusesADraftTransfer() {
        Stock_Transfer__c draft = new Stock_Transfer__c(
            Source_Warehouse__c = warehouseId('SRC01'),
            Destination_Warehouse__c = warehouseId('DST01'),
            Transfer_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert draft;

        Test.startTest();
        Boolean threw = false;
        try {
            INV_StockTransferController.receiveTransfer(draft.Id, '[]');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'Receiving stock that was never approved would conjure inventory at the '
            + 'destination that no source ever gave up');
    }

    @isTest
    static void receive_fromInTransit_touchesOnlyTheNamedLines() {
        Product_Extension__c product =
            [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];
        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = warehouseId('SRC01'),
            Destination_Warehouse__c = warehouseId('DST01'),
            Transfer_Date__c = Date.today(),
            Status__c = 'In_Transit'
        );
        insert transfer;
        Stock_Transfer_Line__c named = new Stock_Transfer_Line__c(
            Stock_Transfer__c = transfer.Id, Product_Ext__c = product.Id,
            Requested_Qty__c = 10, Approved_Qty__c = 10);
        Stock_Transfer_Line__c untouched = new Stock_Transfer_Line__c(
            Stock_Transfer__c = transfer.Id, Product_Ext__c = product.Id,
            Requested_Qty__c = 20, Approved_Qty__c = 20);
        insert new List<Stock_Transfer_Line__c>{ named, untouched };

        Test.startTest();
        INV_StockTransferController.receiveTransfer(transfer.Id,
            '[{"lineItemId":"' + named.Id + '","receivedQty":10}]');
        Test.stopTest();

        System.assertEquals('Received',
            [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transfer.Id].Status__c,
            'In_Transit goes straight to Received, no intermediate hop needed');
        System.assertEquals(10,
            [SELECT Received_Qty__c FROM Stock_Transfer_Line__c WHERE Id = :named.Id].Received_Qty__c,
            'The named line records its receipt');
        System.assertEquals(null,
            [SELECT Received_Qty__c FROM Stock_Transfer_Line__c WHERE Id = :untouched.Id].Received_Qty__c,
            'A line absent from the payload keeps its null — partial receipts must not '
            + 'invent zeros for lines still on the truck');
    }

    @isTest
    static void create_skipsUnusableLinesAndSnapshotsZeroForUnstockedProducts() {
        Id src = warehouseId('SRC01');
        Id dst = warehouseId('DST01');
        Product_Extension__c stocked =
            [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'TRP01'];
        Product_Extension__c unstocked = new Product_Extension__c(
            Name = 'Never Stocked', SKU_Code__c = 'TRP02', Is_Active__c = true);
        insert unstocked;

        String lineJson = '['
            + '{"productId":null,"requestedQty":5},'
            + '{"productId":"' + stocked.Id + '","requestedQty":0},'
            + '{"productId":"' + stocked.Id + '","requestedQty":-3},'
            + '{"productId":"' + unstocked.Id + '","requestedQty":10}'
            + ']';

        Test.startTest();
        Id transferId = INV_StockTransferController.createTransfer(src, dst, null, null, lineJson);
        Test.stopTest();

        System.assertEquals(Date.today(),
            [SELECT Transfer_Date__c FROM Stock_Transfer__c WHERE Id = :transferId].Transfer_Date__c,
            'A null transfer date defaults to today');
        List<Stock_Transfer_Line__c> lines = [
            SELECT Product_Ext__c, Requested_Qty__c, Available_Stock__c
            FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId];
        System.assertEquals(1, lines.size(),
            'Null-product, zero-qty and negative-qty entries are all dropped — only the '
            + 'one usable line survives');
        System.assertEquals(unstocked.Id, lines[0].Product_Ext__c, 'And it is the right one');
        System.assertEquals(0, lines[0].Available_Stock__c,
            'A product with no stock row at the source snapshots as 0, not null — the '
            + 'approver sees they would be approving against nothing');
    }

    @isTest
    static void create_withEmptyLineArray_stillCreatesTheDraftHeader() {
        Test.startTest();
        Id transferId = INV_StockTransferController.createTransfer(
            warehouseId('SRC01'), warehouseId('DST01'), Date.today(), 'header only', '[]');
        Test.stopTest();

        System.assertEquals('Draft',
            [SELECT Status__c FROM Stock_Transfer__c WHERE Id = :transferId].Status__c,
            'An empty cart still saves as a draft to finish later');
        System.assertEquals(0,
            [SELECT COUNT() FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId],
            'With no lines');
    }

    @isTest
    static void getTransfers_filtersByStatusAndMatchesEitherEnd() {
        Id src = warehouseId('SRC01');
        Id dst = warehouseId('DST01');
        insert new List<Stock_Transfer__c>{
            new Stock_Transfer__c(Source_Warehouse__c = src, Destination_Warehouse__c = dst,
                Transfer_Date__c = Date.today(), Status__c = 'Draft'),
            new Stock_Transfer__c(Source_Warehouse__c = src, Destination_Warehouse__c = dst,
                Transfer_Date__c = Date.today(), Status__c = 'Submitted')
        };

        Test.startTest();
        List<Stock_Transfer__c> draftsAtSource =
            INV_StockTransferController.getTransfers(src, 'Draft');
        List<Stock_Transfer__c> allAtDestination =
            INV_StockTransferController.getTransfers(dst, 'all');
        List<Stock_Transfer__c> submittedAnywhere =
            INV_StockTransferController.getTransfers(null, 'Submitted');
        Test.stopTest();

        System.assertEquals(1, draftsAtSource.size(), 'Status filter narrows to the draft');
        System.assertEquals('Draft', draftsAtSource[0].Status__c, 'And it is the draft');
        System.assertEquals(2, allAtDestination.size(),
            'The warehouse matches as destination too — a receiving warehouse sees its '
            + 'inbound transfers, and "all" skips the status filter');
        System.assertEquals(1, submittedAnywhere.size(),
            'No warehouse plus a status works as a pure status view');
    }

    @isTest
    static void getAvailableProducts_hidesExhaustedStockAndMissedSearches() {
        Id src = warehouseId('SRC01');
        Product_Extension__c exhausted = new Product_Extension__c(
            Name = 'Exhausted Product', SKU_Code__c = 'TRP03', Is_Active__c = true);
        insert exhausted;
        insert new Warehouse_Stock__c(
            Warehouse__c = src, Product_Ext__c = exhausted.Id,
            Qty_On_Hand__c = 0, Qty_Reserved__c = 0, Qty_Damaged__c = 0);

        Test.startTest();
        List<Warehouse_Stock__c> pickable =
            INV_StockTransferController.getAvailableProducts(src, null);
        List<Warehouse_Stock__c> bySku =
            INV_StockTransferController.getAvailableProducts(src, 'TRP01');
        List<Warehouse_Stock__c> noMatch =
            INV_StockTransferController.getAvailableProducts(src, 'zzz-nothing');
        Test.stopTest();

        System.assertEquals(1, pickable.size(),
            'Zero-available stock never reaches the picker — offering it would create '
            + 'transfers that can only come up short');
        System.assertEquals('TRP01', pickable[0].Product_Ext__r.SKU_Code__c,
            'Only the stocked product shows');
        System.assertEquals(1, bySku.size(), 'The search term also matches on SKU code');
        System.assertEquals(0, noMatch.size(), 'A miss is an empty list, not an error');
    }
}