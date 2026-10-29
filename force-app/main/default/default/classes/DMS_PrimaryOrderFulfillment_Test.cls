/**
 * @description Tests for the canonical primary-fulfilment path on Primary_Order__c
 *              (DMS_PrimaryOrderFulfillment_Service): approval -> primary Invoice +
 *              GST split + scheme accrual + warehouse deduction + distributor credit
 *              recalculation + order Dispatched. Complements DMS_PrimaryFulfillment_Test,
 *              which covers the deprecated Indent__c path.
 */
@isTest
private class DMS_PrimaryOrderFulfillment_Test {

    private static void enableCore() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_PRIMARY_FULFILLMENT, true);
    }

    private static Warehouse__c createWarehouse(String state) {
        Warehouse__c wh = new Warehouse__c(
            Name = 'Test Source WH',
            Warehouse_Code__c = 'WHPO1', // alphanumeric only (3-20) per Warehouse Code validation rule
            State__c = state,
            Is_Active__c = true
        );
        insert wh;
        return wh;
    }

    private static List<Product_Extension__c> productsWithGst(Integer count, Decimal gst) {
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(count);
        for (Product_Extension__c p : products) { p.GST_Rate__c = gst; }
        update products;
        return products;
    }

    private static void seedWarehouseStock(Id warehouseId, List<Product_Extension__c> products) {
        // Null batch so it matches the fulfilment deduction (which passes a null
        // batch); adjustDeduct keys on Warehouse+Product+Batch exactly.
        List<Warehouse_Stock__c> stock = new List<Warehouse_Stock__c>();
        for (Product_Extension__c p : products) {
            stock.add(new Warehouse_Stock__c(
                Warehouse__c = warehouseId, Product_Ext__c = p.Id, Qty_On_Hand__c = 1000
            ));
        }
        insert stock;
    }

    private static Primary_Order__c createSubmittedOrder(
        Id accountId, Id warehouseId, List<Product_Extension__c> products
    ) {
        Primary_Order__c po = new Primary_Order__c(
            Account__c = accountId,
            Warehouse__c = warehouseId,
            Order_Date__c = Date.today(),
            Status__c = 'Submitted'
        );
        insert po;
        List<Primary_Order_Line__c> lines = new List<Primary_Order_Line__c>();
        for (Integer i = 0; i < products.size(); i++) {
            lines.add(new Primary_Order_Line__c(
                Primary_Order__c = po.Id,
                Product_Ext__c = products[i].Id,
                Quantity__c = (i + 1) * 10,
                Base_Quantity__c = (i + 1) * 10,
                Unit_Price__c = 100
            ));
        }
        insert lines;
        return po;
    }

    @isTest
    static void approval_buildsPrimaryInvoice_withGstSplit_accrual_creditRecalc() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PO', 'Distributor');
        dist.BillingState = 'Maharashtra';
        update dist;
        List<Product_Extension__c> products = productsWithGst(1, 18);
        Warehouse__c wh = createWarehouse('Maharashtra'); // intra-state
        seedWarehouseStock(wh.Id, products);

        // Active 5% scheme with no channel/region restriction => applies to any distributor.
        Scheme__c scheme = new Scheme__c(
            Name = 'Primary 5pct', Scheme_Code__c = 'SCH-PO-' + String.valueOf(Datetime.now().getTime()),
            Status__c = 'Active', Start_Date__c = Date.today().addDays(-1),
            End_Date__c = Date.today().addDays(30), Discount_Percent__c = 5,
            Budget_Amount__c = 1000000 // Scheme validation rule requires Budget Amount > 0
        );
        insert scheme;

        Primary_Order__c po = createSubmittedOrder(dist.Id, wh.Id, products);

        enableCore();
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SCHEME_CLAIM, true);
        Test.startTest();
        update new Primary_Order__c(Id = po.Id, Status__c = 'Approved');
        Test.stopTest();

        Primary_Order__c after = [SELECT Status__c, Invoice__c FROM Primary_Order__c WHERE Id = :po.Id];
        System.assertEquals('Dispatched', after.Status__c, 'Order advanced to Dispatched');
        System.assertNotEquals(null, after.Invoice__c, 'Primary invoice linked');

        Invoice__c inv = [
            SELECT Order_Type__c, Account__c, Warehouse__c, Subtotal__c, Tax_Amount__c, Total_Amount__c
            FROM Invoice__c WHERE Id = :after.Invoice__c
        ];
        System.assertEquals('Primary', inv.Order_Type__c, 'Invoice is primary');
        System.assertEquals(dist.Id, inv.Account__c, 'Billed to distributor');
        System.assertEquals(1000, inv.Subtotal__c, 'Taxable base = 10*100');
        System.assert(inv.Tax_Amount__c > 0, 'GST applied at header');
        System.assertEquals(inv.Subtotal__c + inv.Tax_Amount__c, inv.Total_Amount__c, 'Total = base + tax');

        // GST split: intra-state => CGST + SGST, no IGST, on every line.
        List<Invoice_Line__c> ils = [
            SELECT CGST__c, SGST__c, IGST__c, Tax_Amount__c, Line_Amount__c
            FROM Invoice_Line__c WHERE Invoice__c = :inv.Id
        ];
        System.assertEquals(1, ils.size(), 'One invoice line per order line');
        for (Invoice_Line__c il : ils) {
            System.assert(il.CGST__c > 0 && il.SGST__c > 0, 'Intra-state CGST+SGST applied');
            System.assertEquals(0, il.IGST__c, 'No IGST intra-state');
            System.assert(il.Tax_Amount__c > 0, 'Line tax computed');
        }

        // Scheme accrual: 5% of the 1000 invoice base = 50 (filter to our scheme,
        // as the org may hold other active schemes that also accrue on this invoice).
        List<Scheme_Accrual__c> accruals = [
            SELECT Accrued_Amount__c, Status__c FROM Scheme_Accrual__c
            WHERE Invoice__c = :inv.Id AND Scheme__c = :scheme.Id
        ];
        System.assertEquals(1, accruals.size(), 'Accrual created on primary invoice for our scheme');
        System.assertEquals(50, accruals[0].Accrued_Amount__c, '5% of 1000');
        System.assertEquals('Open', accruals[0].Status__c, 'Accrual Open');

        // (Warehouse stock deduction is INV_WarehouseStock_Service behaviour, covered
        // by INV_WarehouseStock_Service_Test; this suite focuses on the primary-path
        // additions: GST split, scheme accrual and distributor credit recalculation.)

        // Distributor credit/outstanding refreshed from the new open invoice.
        Account distAfter = [SELECT Outstanding_Balance__c FROM Account WHERE Id = :dist.Id];
        System.assertEquals(inv.Total_Amount__c, distAfter.Outstanding_Balance__c,
            'Outstanding refreshed to the primary invoice total');
    }

    @isTest
    static void interState_appliesIgst() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PO IS', 'Distributor');
        dist.BillingState = 'Karnataka';
        update dist;
        List<Product_Extension__c> products = productsWithGst(1, 18);
        Warehouse__c wh = createWarehouse('Maharashtra'); // origin != destination
        seedWarehouseStock(wh.Id, products);
        Primary_Order__c po = createSubmittedOrder(dist.Id, wh.Id, products);

        enableCore();
        Test.startTest();
        update new Primary_Order__c(Id = po.Id, Status__c = 'Approved');
        Test.stopTest();

        Id invId = [SELECT Invoice__c FROM Primary_Order__c WHERE Id = :po.Id].Invoice__c;
        Invoice_Line__c il = [
            SELECT CGST__c, SGST__c, IGST__c FROM Invoice_Line__c WHERE Invoice__c = :invId LIMIT 1
        ];
        System.assert(il.IGST__c > 0, 'Inter-state IGST applied');
        System.assertEquals(0, il.CGST__c, 'No CGST inter-state');
        System.assertEquals(0, il.SGST__c, 'No SGST inter-state');
    }

    @isTest
    static void fulfilment_deductsWarehouseStockOnce_evenAfterInvoiceDispatched() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PO Once', 'Distributor');
        List<Product_Extension__c> products = productsWithGst(1, 18);
        Warehouse__c wh = createWarehouse('Maharashtra');
        seedWarehouseStock(wh.Id, products);                                  // 1000 on hand
        Primary_Order__c po = createSubmittedOrder(dist.Id, wh.Id, products); // orders 10

        enableCore();
        Test.startTest();
        update new Primary_Order__c(Id = po.Id, Status__c = 'Approved');

        Warehouse_Stock__c afterFulfil = [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :products[0].Id LIMIT 1
        ];
        System.assertEquals(990, afterFulfil.Qty_On_Hand__c, 'Fulfilment deducted the 10 ordered units once');

        // Walk the invoice through its lifecycle. OMS_Invoice_TriggerHandler must NOT
        // reserve on Confirmed or deduct again on Dispatched for a primary invoice —
        // that second write was the latent double-deduct.
        Id invId = [SELECT Invoice__c FROM Primary_Order__c WHERE Id = :po.Id].Invoice__c;
        update new Invoice__c(Id = invId, Status__c = 'Confirmed');
        update new Invoice__c(Id = invId, Status__c = 'Dispatched');
        Test.stopTest();

        Warehouse_Stock__c afterDispatch = [
            SELECT Qty_On_Hand__c, Qty_Reserved__c FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :products[0].Id LIMIT 1
        ];
        System.assertEquals(990, afterDispatch.Qty_On_Hand__c,
            'Still 990 — the invoice lifecycle must not deduct the same movement a second time');
        Decimal reserved = afterDispatch.Qty_Reserved__c == null ? 0 : afterDispatch.Qty_Reserved__c;
        System.assertEquals(0, reserved, 'Confirmed must not leak a reservation on a primary invoice');
    }

    /**
     * Primary dispatch used to pass `batch = null` straight to the deduction, so the warehouse
     * had no FEFO at all — and because Warehouse_Stock.Expiry_Date__c was never populated, the
     * expiry filters were dead code. It now resolves the ordered quantity to specific batches,
     * earliest expiry first.
     */
    @isTest
    static void fulfilment_allocatesWarehouseStockFefo_earliestExpiryFirst() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist FEFO', 'Distributor');
        List<Product_Extension__c> products = productsWithGst(1, 18);
        Warehouse__c wh = createWarehouse('Maharashtra');

        // Seed the LATER-expiring batch first, so insertion order can't explain the result.
        insert new List<Warehouse_Stock__c>{
            new Warehouse_Stock__c(Warehouse__c = wh.Id, Product_Ext__c = products[0].Id,
                Batch_Number__c = 'LATE', Expiry_Date__c = Date.today().addDays(90),
                Qty_On_Hand__c = 100),
            new Warehouse_Stock__c(Warehouse__c = wh.Id, Product_Ext__c = products[0].Id,
                Batch_Number__c = 'SOON', Expiry_Date__c = Date.today().addDays(5),
                Qty_On_Hand__c = 6)
        };

        Primary_Order__c po = createSubmittedOrder(dist.Id, wh.Id, products); // orders 10

        enableCore();
        Test.startTest();
        update new Primary_Order__c(Id = po.Id, Status__c = 'Approved');
        Test.stopTest();

        Map<String, Decimal> onHandByBatch = new Map<String, Decimal>();
        for (Warehouse_Stock__c ws : [
            SELECT Batch_Number__c, Qty_On_Hand__c FROM Warehouse_Stock__c
            WHERE Warehouse__c = :wh.Id AND Product_Ext__c = :products[0].Id
        ]) {
            onHandByBatch.put(ws.Batch_Number__c, ws.Qty_On_Hand__c);
        }
        // 10 units ordered: drain the 6 in the sooner-expiring batch, then 4 from the later one.
        System.assertEquals(0, onHandByBatch.get('SOON'),
            'Earliest-expiring batch is consumed first (FEFO)');
        System.assertEquals(96, onHandByBatch.get('LATE'),
            'Only the 4-unit remainder comes from the later-expiring batch');
    }

    @isTest
    static void fulfilment_blocksWhenWarehouseStockInsufficient() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PO Short', 'Distributor');
        List<Product_Extension__c> products = productsWithGst(1, 18);
        Warehouse__c wh = createWarehouse('Maharashtra');
        // Only 5 on hand; the order asks for 10.
        insert new Warehouse_Stock__c(
            Warehouse__c = wh.Id, Product_Ext__c = products[0].Id, Qty_On_Hand__c = 5
        );
        Primary_Order__c po = createSubmittedOrder(dist.Id, wh.Id, products);

        enableCore();
        Boolean blocked = false;
        Test.startTest();
        try {
            update new Primary_Order__c(Id = po.Id, Status__c = 'Approved');
        } catch (Exception e) {
            blocked = true;
            System.assert(e.getMessage().contains('Insufficient warehouse stock'),
                'Shortfall surfaced to the approver: ' + e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(true, blocked, 'Over-dispatch is blocked, not silently floored at zero');
        Warehouse_Stock__c stock = [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c WHERE Warehouse__c = :wh.Id LIMIT 1
        ];
        System.assertEquals(5, stock.Qty_On_Hand__c, 'Stock untouched when fulfilment is blocked');
    }

    @isTest
    static void approval_withTogglesOff_doesNothing() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PO Off', 'Distributor');
        List<Product_Extension__c> products = productsWithGst(1, 18);
        Warehouse__c wh = createWarehouse('Maharashtra');
        seedWarehouseStock(wh.Id, products);
        Primary_Order__c po = createSubmittedOrder(dist.Id, wh.Id, products);

        // Explicitly disable in the cache: Feature_Toggle__mdt is visible in tests,
        // and this org enables all DMS toggles, so relying on the mdt default is not safe.
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_PRIMARY_FULFILLMENT, false);
        Test.startTest();
        update new Primary_Order__c(Id = po.Id, Status__c = 'Approved');
        Test.stopTest();

        Primary_Order__c after = [SELECT Status__c, Invoice__c FROM Primary_Order__c WHERE Id = :po.Id];
        System.assertEquals('Approved', after.Status__c, 'Status unchanged when DMS disabled');
        System.assertEquals(null, after.Invoice__c, 'No invoice when DMS disabled');
    }
}