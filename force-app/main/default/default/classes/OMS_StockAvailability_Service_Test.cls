@isTest
private class OMS_StockAvailability_Service_Test {

    @isTest
    static void testStockAvailable() {
        Account acc = TestDataFactory.createAndInsertAccount('Test Retailer', 'Retailer');
        acc.Credit_Limit__c = 1000000;
        acc.Credit_Utilized__c = 0;
        update acc;

        Product_Extension__c prod = TestDataFactory.createProduct('Test Product', 'TP-001');
        insert prod;

        Sales_Order__c order = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        order.Status__c = 'Draft';
        insert order;

        Order_Line_Item__c li = TestDataFactory.createOrderLineItem(order.Id, prod.Id, 10, 100);
        insert li;

        Test.startTest();
        Map<Id, List<String>> results = OMS_StockAvailability_Service.validateStockAvailability(
            new Set<Id>{ order.Id }
        );
        Test.stopTest();

        // Without warehouse set, stock check should still return results
        System.assertNotEquals(null, results);
        System.assert(results.containsKey(order.Id));
    }

    /**
     * The reservation guard: two orders that would EACH pass an isolated check must not both
     * pass when together they exceed supply. Warehouse holds 10; order A (already Submitted)
     * committed 8, so a new order for 5 leaves it 3 short of the 2 uncommitted units.
     */
    @isTest
    static void reservationGuard_setsAsideOtherOpenOrders() {
        Account retailer = TestDataFactory.createAndInsertAccount('Res Retailer', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('Res Product', 'RES-1');
        insert prod;
        Warehouse__c wh = new Warehouse__c(
            Name = 'Res WH', Warehouse_Code__c = 'RESWH1', State__c = 'Maharashtra', Is_Active__c = true);
        insert wh;
        insert new Warehouse_Stock__c(
            Warehouse__c = wh.Id, Product_Ext__c = prod.Id, Qty_On_Hand__c = 10, Qty_Reserved__c = 0);

        Territory_Master__c terr = new Territory_Master__c(Name = 'Res Terr', Territory_Code__c = 'RES-TERR-1');
        insert terr;

        // Order A already committed (Submitted) for 8 units — seeded past the trigger guard.
        Sales_Order__c a = TestDataFactory.createSalesOrder(retailer.Id, UserInfo.getUserId(), null);
        a.Warehouse__c = wh.Id;
        a.Territory__c = terr.Id;   // VR: Territory is required before submitting
        a.Status__c = 'Draft';
        insert a;
        insert new Order_Line_Item__c(
            Sales_Order__c = a.Id, Product_Ext__c = prod.Id, Quantity__c = 8, Base_Quantity__c = 8, Unit_Price__c = 100);
        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        update new Sales_Order__c(Id = a.Id, Status__c = 'Submitted');
        TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');

        // Order B (submitting) wants 5, but only 2 are uncommitted.
        Sales_Order__c b = TestDataFactory.createSalesOrder(retailer.Id, UserInfo.getUserId(), null);
        b.Warehouse__c = wh.Id;
        b.Status__c = 'Draft';
        insert b;
        insert new Order_Line_Item__c(
            Sales_Order__c = b.Id, Product_Ext__c = prod.Id, Quantity__c = 5, Base_Quantity__c = 5, Unit_Price__c = 100);

        Test.startTest();
        Map<Id, List<String>> short5 = OMS_StockAvailability_Service.validateForReservation(new Set<Id>{ b.Id });
        Test.stopTest();

        System.assert(!short5.get(b.Id).isEmpty(),
            'Order for 5 is blocked: A already committed 8 of 10, leaving 2 uncommitted');
        System.assert(short5.get(b.Id)[0].contains('uncommitted warehouse stock 2'),
            'Shortage reports the 2 units actually free, naming the supply source: '
            + short5.get(b.Id)[0]);

        // A different order for exactly 2 fits.
        Sales_Order__c c = TestDataFactory.createSalesOrder(retailer.Id, UserInfo.getUserId(), null);
        c.Warehouse__c = wh.Id;
        c.Status__c = 'Draft';
        insert c;
        insert new Order_Line_Item__c(
            Sales_Order__c = c.Id, Product_Ext__c = prod.Id, Quantity__c = 2, Base_Quantity__c = 2, Unit_Price__c = 100);
        Map<Id, List<String>> short2 = OMS_StockAvailability_Service.validateForReservation(new Set<Id>{ c.Id });
        System.assert(short2.get(c.Id).isEmpty(), 'An order for exactly the 2 uncommitted units fits');
    }

    @isTest
    static void testEmptyOrderIds() {
        Test.startTest();
        Map<Id, List<String>> results = OMS_StockAvailability_Service.validateStockAvailability(
            new Set<Id>()
        );
        Test.stopTest();

        System.assert(results.isEmpty());
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage.
    //
    //  The DISTRIBUTOR branch of validateForReservation had no test at all —
    //  and it is the reason the method exists: before it, two reps could each
    //  book the same units from one distributor, both orders approved, and the
    //  second invoice failed at FEFO after the retailer was promised the goods.
    //  Also covered here: validateStockAvailability's real shortage path (the
    //  test above has no warehouse, so it early-returns), the expired-batch
    //  exclusion, and the consuming allocation between two orders in one call.
    //
    //  Fixture notes: order line inserts bypass OMS_OrderLineItem_TriggerHandler
    //  so Base_Quantity__c stays exactly as written (and the pricing chain's
    //  per-DML query cost stays out of the way); order dates are varied per
    //  order because Sales_Order__c carries a duplicate guard on
    //  account + date + rep.
    // ══════════════════════════════════════════════════════════════════

    private static Integer orderSeq = 0;

    private static Sales_Order__c orderFor(Id accountId, Id warehouseId, Id distributorId, Id territoryId) {
        orderSeq++;
        Sales_Order__c o = TestDataFactory.createSalesOrder(accountId, UserInfo.getUserId(), null);
        o.Order_Date__c = Date.today().addDays(-orderSeq);
        o.Status__c = 'Draft';
        if (warehouseId != null) o.Warehouse__c = warehouseId;
        if (distributorId != null) o.Sold_From_Distributor__c = distributorId;
        if (territoryId != null) o.Territory__c = territoryId;
        insert o;
        return o;
    }

    private static void lineFor(Id orderId, Id productId, Decimal qty) {
        TriggerHandler.bypass('OMS_OrderLineItem_TriggerHandler');
        try {
            insert new Order_Line_Item__c(
                Sales_Order__c = orderId, Product_Ext__c = productId,
                Quantity__c = qty, Base_Quantity__c = qty, Unit_Price__c = 100);
        } finally {
            TriggerHandler.clearBypass('OMS_OrderLineItem_TriggerHandler');
        }
    }

    private static void markSubmitted(Id orderId) {
        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        try {
            update new Sales_Order__c(Id = orderId, Status__c = 'Submitted');
        } finally {
            TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
        }
    }

    // ── validateStockAvailability: the real path ──────────────────────

    @isTest
    static void availability_reportsTheShortageAgainstNetOfReserved() {
        Account retailer = TestDataFactory.createAndInsertAccount('AV Retailer', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('AV Product', 'AV-1');
        insert prod;
        Warehouse__c wh = new Warehouse__c(
            Name = 'AV WH', Warehouse_Code__c = 'AVWH1', State__c = 'Maharashtra', Is_Active__c = true);
        insert wh;
        // 10 on hand, 4 reserved → 6 available.
        insert new Warehouse_Stock__c(
            Warehouse__c = wh.Id, Product_Ext__c = prod.Id,
            Qty_On_Hand__c = 10, Qty_Reserved__c = 4);

        Sales_Order__c o = orderFor(retailer.Id, wh.Id, null, null);
        lineFor(o.Id, prod.Id, 10);

        Test.startTest();
        Map<Id, List<String>> shortages =
            OMS_StockAvailability_Service.validateStockAvailability(new Set<Id>{ o.Id });
        Test.stopTest();

        System.assertEquals(1, shortages.get(o.Id).size(), 'One product is short');
        System.assert(shortages.get(o.Id)[0].contains('required 10'),
            'The demand is named: ' + shortages.get(o.Id)[0]);
        System.assert(shortages.get(o.Id)[0].contains('available 6'),
            'Against the NET position — reserved units are not sellable: '
            + shortages.get(o.Id)[0]);
    }

    @isTest
    static void availability_excludesExpiredBatchesFromSupply() {
        Account retailer = TestDataFactory.createAndInsertAccount('AV Exp Retailer', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('AV Exp Product', 'AVX-1');
        insert prod;
        Warehouse__c wh = new Warehouse__c(
            Name = 'AVX WH', Warehouse_Code__c = 'AVXWH1', State__c = 'Maharashtra', Is_Active__c = true);
        insert wh;
        // 100 units expired, 5 units live — only the 5 are supply.
        insert new List<Warehouse_Stock__c>{
            new Warehouse_Stock__c(Warehouse__c = wh.Id, Product_Ext__c = prod.Id,
                Batch_Number__c = 'OLD', Qty_On_Hand__c = 100, Qty_Reserved__c = 0,
                Expiry_Date__c = Date.today().addDays(-1)),
            new Warehouse_Stock__c(Warehouse__c = wh.Id, Product_Ext__c = prod.Id,
                Batch_Number__c = 'LIVE', Qty_On_Hand__c = 5, Qty_Reserved__c = 0,
                Expiry_Date__c = Date.today().addDays(90))
        };

        Sales_Order__c o = orderFor(retailer.Id, wh.Id, null, null);
        lineFor(o.Id, prod.Id, 6);

        Test.startTest();
        Map<Id, List<String>> shortages =
            OMS_StockAvailability_Service.validateStockAvailability(new Set<Id>{ o.Id });
        Test.stopTest();

        System.assertEquals(1, shortages.get(o.Id).size(),
            'Six wanted, five sellable — the hundred expired units are not supply');
        System.assert(shortages.get(o.Id)[0].contains('available 5'),
            'Only the live batch counts: ' + shortages.get(o.Id)[0]);
    }

    @isTest
    static void availability_passesWhenSupplyCoversDemand() {
        Account retailer = TestDataFactory.createAndInsertAccount('AV OK Retailer', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('AV OK Product', 'AVOK-1');
        insert prod;
        Warehouse__c wh = new Warehouse__c(
            Name = 'AVOK WH', Warehouse_Code__c = 'AVOKWH1', State__c = 'Maharashtra', Is_Active__c = true);
        insert wh;
        insert new Warehouse_Stock__c(
            Warehouse__c = wh.Id, Product_Ext__c = prod.Id, Qty_On_Hand__c = 50, Qty_Reserved__c = 0);

        Sales_Order__c o = orderFor(retailer.Id, wh.Id, null, null);
        lineFor(o.Id, prod.Id, 20);

        Test.startTest();
        Map<Id, List<String>> shortages =
            OMS_StockAvailability_Service.validateStockAvailability(new Set<Id>{ o.Id });
        Test.stopTest();

        System.assertEquals(0, shortages.get(o.Id).size(), 'Twenty of fifty fits cleanly');
    }

    // ── validateForReservation: the distributor branch ────────────────

    @isTest
    static void reservation_distributorSupply_setsAsideOtherUnbilledOrders() {
        Account distributor = TestDataFactory.createAndInsertAccount('RD Distributor', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('RD Retailer', 'Retailer');
        Territory_Master__c terr = new Territory_Master__c(Name = 'RD Terr', Territory_Code__c = 'RDT1');
        insert terr;
        Product_Extension__c prod = TestDataFactory.createProduct('RD Product', 'RD-1');
        insert prod;
        // Distributor book position: 10 (Closing derived from Opening by the trigger).
        insert new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = prod.Id,
            Opening_Stock__c = 10, Stock_Date__c = Date.today(), Is_Current__c = true);

        // Another rep's order already Submitted (unbilled) for 8 of the 10.
        Sales_Order__c committed = orderFor(retailer.Id, null, distributor.Id, terr.Id);
        lineFor(committed.Id, prod.Id, 8);
        markSubmitted(committed.Id);

        // This rep now submits for 5 — only 2 are uncommitted.
        Sales_Order__c submitting = orderFor(retailer.Id, null, distributor.Id, null);
        lineFor(submitting.Id, prod.Id, 5);

        Test.startTest();
        Map<Id, List<String>> shortages =
            OMS_StockAvailability_Service.validateForReservation(new Set<Id>{ submitting.Id });
        Test.stopTest();

        System.assertEquals(1, shortages.get(submitting.Id).size(),
            'This is the double-booking the guard exists for: both orders would pass an '
            + 'isolated check, but together they oversell the distributor');
        System.assert(shortages.get(submitting.Id)[0].contains('uncommitted distributor stock 2'),
            'Naming the supply source and the 2 units genuinely free: '
            + shortages.get(submitting.Id)[0]);
    }

    @isTest
    static void reservation_billedOrders_releaseTheirDistributorClaim() {
        Account distributor = TestDataFactory.createAndInsertAccount('RB Distributor', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('RB Retailer', 'Retailer');
        Territory_Master__c terr = new Territory_Master__c(Name = 'RB Terr', Territory_Code__c = 'RBT1');
        insert terr;
        Product_Extension__c prod = TestDataFactory.createProduct('RB Product', 'RB-1');
        insert prod;
        insert new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = prod.Id,
            Opening_Stock__c = 10, Stock_Date__c = Date.today(), Is_Current__c = true);

        // A Submitted order for 8 — but already BILLED, so its goods have
        // physically left the distributor's stock. Counting it again would
        // reserve the same units twice.
        Sales_Order__c billed = orderFor(retailer.Id, null, distributor.Id, terr.Id);
        lineFor(billed.Id, prod.Id, 8);
        Invoice__c inv = new Invoice__c(
            Account__c = retailer.Id, Invoice_Number__c = 'RB-INV-1',
            Invoice_Date__c = Date.today(), Status__c = 'Draft',
            Total_Amount__c = 800, Balance_Due__c = 800);
        insert inv;
        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        try {
            update new Sales_Order__c(Id = billed.Id, Status__c = 'Submitted', Invoice__c = inv.Id);
        } finally {
            TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
        }

        Sales_Order__c submitting = orderFor(retailer.Id, null, distributor.Id, null);
        lineFor(submitting.Id, prod.Id, 5);

        Test.startTest();
        Map<Id, List<String>> shortages =
            OMS_StockAvailability_Service.validateForReservation(new Set<Id>{ submitting.Id });
        Test.stopTest();

        System.assertEquals(0, shortages.get(submitting.Id).size(),
            'The billed order no longer holds a claim — its stock movement is already in the '
            + 'book position, so 5 of 10 fits');
    }

    @isTest
    static void reservation_cancelledOrders_releaseAutomatically() {
        Account distributor = TestDataFactory.createAndInsertAccount('RC Distributor', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('RC Retailer', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('RC Product', 'RC-1');
        insert prod;
        insert new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = prod.Id,
            Opening_Stock__c = 10, Stock_Date__c = Date.today(), Is_Current__c = true);

        // An order for all 10 that was cancelled — Cancelled is not an open
        // status, so nothing needs to "release" it explicitly.
        Sales_Order__c cancelled = orderFor(retailer.Id, null, distributor.Id, null);
        lineFor(cancelled.Id, prod.Id, 10);
        TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler');
        try {
            update new Sales_Order__c(Id = cancelled.Id, Status__c = 'Cancelled');
        } finally {
            TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler');
        }

        Sales_Order__c submitting = orderFor(retailer.Id, null, distributor.Id, null);
        lineFor(submitting.Id, prod.Id, 10);

        Test.startTest();
        Map<Id, List<String>> shortages =
            OMS_StockAvailability_Service.validateForReservation(new Set<Id>{ submitting.Id });
        Test.stopTest();

        System.assertEquals(0, shortages.get(submitting.Id).size(),
            'A cancelled order holds no claim, so the full 10 are free again');
    }

    @isTest
    static void reservation_twoSubmittingOrders_cannotBothClaimTheSameUnits() {
        Account distributor = TestDataFactory.createAndInsertAccount('R2 Distributor', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('R2 Retailer', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('R2 Product', 'R2-1');
        insert prod;
        insert new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = prod.Id,
            Opening_Stock__c = 10, Stock_Date__c = Date.today(), Is_Current__c = true);

        // Both submitted in ONE call, 6 each against 10.
        Sales_Order__c first = orderFor(retailer.Id, null, distributor.Id, null);
        lineFor(first.Id, prod.Id, 6);
        Sales_Order__c second = orderFor(retailer.Id, null, distributor.Id, null);
        lineFor(second.Id, prod.Id, 6);

        Test.startTest();
        Map<Id, List<String>> shortages = OMS_StockAvailability_Service.validateForReservation(
            new Set<Id>{ first.Id, second.Id });
        Test.stopTest();

        Integer blocked = 0;
        for (Id orderId : shortages.keySet()) {
            if (!shortages.get(orderId).isEmpty()) blocked++;
        }
        System.assertEquals(1, blocked,
            'The allocation consumes as it goes — one order fits, the other is short. Both '
            + 'passing would be exactly the oversell this method was written to stop');
    }

    @isTest
    static void reservation_mixedSupply_judgesEachOrderAgainstItsOwnSource() {
        Account distributor = TestDataFactory.createAndInsertAccount('RM Distributor', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('RM Retailer', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('RM Product', 'RM-1');
        insert prod;
        Warehouse__c wh = new Warehouse__c(
            Name = 'RM WH', Warehouse_Code__c = 'RMWH1', State__c = 'Maharashtra', Is_Active__c = true);
        insert wh;
        // Warehouse holds 3; distributor holds 20.
        insert new Warehouse_Stock__c(
            Warehouse__c = wh.Id, Product_Ext__c = prod.Id, Qty_On_Hand__c = 3, Qty_Reserved__c = 0);
        insert new Distributor_Stock__c(
            Account__c = distributor.Id, Product_Ext__c = prod.Id,
            Opening_Stock__c = 20, Stock_Date__c = Date.today(), Is_Current__c = true);

        Sales_Order__c fromWarehouse = orderFor(retailer.Id, wh.Id, null, null);
        lineFor(fromWarehouse.Id, prod.Id, 5);
        Sales_Order__c fromDistributor = orderFor(retailer.Id, null, distributor.Id, null);
        lineFor(fromDistributor.Id, prod.Id, 5);

        Test.startTest();
        Map<Id, List<String>> shortages = OMS_StockAvailability_Service.validateForReservation(
            new Set<Id>{ fromWarehouse.Id, fromDistributor.Id });
        Test.stopTest();

        System.assertEquals(1, shortages.get(fromWarehouse.Id).size(),
            'Five against three warehouse units is short');
        System.assert(shortages.get(fromWarehouse.Id)[0].contains('warehouse'),
            'And says which source: ' + shortages.get(fromWarehouse.Id)[0]);
        System.assertEquals(0, shortages.get(fromDistributor.Id).size(),
            'While the distributor order fits against ITS supply — the twenty distributor '
            + 'units must never be lent to a warehouse order, or vice versa');
    }

    @isTest
    static void reservation_withNullOrEmptyInput_returnsEmpty() {
        Test.startTest();
        Map<Id, List<String>> fromNull =
            OMS_StockAvailability_Service.validateForReservation(null);
        Map<Id, List<String>> fromEmpty =
            OMS_StockAvailability_Service.validateForReservation(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, fromNull.size(), 'Null input is a no-op');
        System.assertEquals(0, fromEmpty.size(), 'Empty input likewise');
    }
}