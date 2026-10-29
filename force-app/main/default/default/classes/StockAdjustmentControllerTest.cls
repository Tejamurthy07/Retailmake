/**
 * @description Tests for StockAdjustmentController — the Stock Adjustment
 * Manager LWC's CRUD, lookup pickers and approval submission.
 *
 * The behaviour worth protecting is the server-side recompute in saveDraft.
 * Adjustment_Qty__c is what the approval writes back to inventory, and the LWC
 * computes it client-side before posting. If the server trusted that value, a
 * tampered or stale form could move stock by an arbitrary amount while showing
 * a plausible System/Actual pair. One test posts a deliberately wrong figure
 * and asserts it is overwritten.
 *
 * Fixture constraints, all enforced by validation rules on Stock_Adjustment__c:
 *   - Reason_Required rejects a blank Reason__c on every save, so no fixture
 *     can omit it;
 *   - Qty_Not_Zero rejects Adjustment_Qty__c = 0, and a null reads as zero in
 *     a formula, so every saved row needs a non-zero adjustment;
 *   - DMS_Location_Reference_Required demands a matching Warehouse or Account
 *     once Location_Type__c is set.
 */
@isTest
private class StockAdjustmentControllerTest {

    @testSetup
    static void setupTestData() {
        // Warehouse_Code_Format requires ^[A-Za-z0-9]{3,20}$ — no separators.
        insert new List<Warehouse__c>{
            new Warehouse__c(Name = 'ADJ Main Store', Warehouse_Code__c = 'ADJMAIN',
                City__c = 'Mumbai', State__c = 'Maharashtra', Is_Active__c = true),
            new Warehouse__c(Name = 'ADJ Overflow', Warehouse_Code__c = 'ADJOVER',
                City__c = 'Pune', State__c = 'Maharashtra', Is_Active__c = true),
            new Warehouse__c(Name = 'ADJ Closed', Warehouse_Code__c = 'ADJOLD',
                City__c = 'Nagpur', State__c = 'Maharashtra', Is_Active__c = false)
        };

        insert new List<Product2>{
            new Product2(Name = 'ADJ Alpha', ProductCode = 'ADJ-ALPHA', IsActive = true),
            new Product2(Name = 'ADJ Beta', ProductCode = 'ADJ-BETA', IsActive = true),
            new Product2(Name = 'ADJ Retired', ProductCode = 'ADJ-OLD', IsActive = false)
        };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> cachedWarehouses;
    private static Map<String, Id> cachedProducts;

    private static Map<String, Id> warehouses() {
        if (cachedWarehouses == null) {
            cachedWarehouses = new Map<String, Id>();
            for (Warehouse__c w : [
                SELECT Id, Warehouse_Code__c FROM Warehouse__c WHERE Warehouse_Code__c LIKE 'ADJ%'
            ]) {
                cachedWarehouses.put(w.Warehouse_Code__c, w.Id);
            }
        }
        return cachedWarehouses;
    }

    private static Map<String, Id> products() {
        if (cachedProducts == null) {
            cachedProducts = new Map<String, Id>();
            for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode LIKE 'ADJ-%']) {
                cachedProducts.put(p.ProductCode, p.Id);
            }
        }
        return cachedProducts;
    }

    private static Id mainStore() { return warehouses().get('ADJMAIN'); }
    private static Id overflow() { return warehouses().get('ADJOVER'); }
    private static Id alpha()    { return products().get('ADJ-ALPHA'); }
    private static Id beta()     { return products().get('ADJ-BETA'); }

    /** A saveable adjustment: reason present, quantities that differ. */
    private static Stock_Adjustment__c draft(Decimal systemQty, Decimal actualQty) {
        return new Stock_Adjustment__c(
            Warehouse__c = mainStore(),
            Product__c = alpha(),
            Batch_Number__c = 'B-ADJ-1',
            System_Qty__c = systemQty,
            Actual_Qty__c = actualQty,
            Adjustment_Type__c = 'Physical_Count',
            Reason__c = 'Cycle count variance',
            Status__c = 'Draft'
        );
    }

    private static Stock_Adjustment__c insertDraft(Decimal systemQty, Decimal actualQty) {
        Stock_Adjustment__c adj = draft(systemQty, actualQty);
        adj.Adjustment_Qty__c = actualQty - systemQty;
        insert adj;
        return adj;
    }

    private static Warehouse_Stock__c stock(
            Id warehouseId, Id productId, String batch, Decimal onHand, Decimal reserved) {
        return new Warehouse_Stock__c(
            Warehouse__c = warehouseId,
            Product__c = productId,
            Batch_Number__c = batch,
            Qty_On_Hand__c = onHand,
            Qty_Reserved__c = reserved,
            Qty_Damaged__c = 0,
            Min_Stock_Level__c = 10,
            Max_Stock_Level__c = 1000
        );
    }

    private static Set<Object> valuesOf(List<Map<String, String>> rows, String key) {
        Set<Object> out = new Set<Object>();
        for (Map<String, String> r : rows) out.add(r.get(key));
        return out;
    }

    // ── getAllAdjustments ─────────────────────────────────────────────

    @isTest
    static void allAdjustments_withNone_returnsEmpty() {
        Test.startTest();
        List<Stock_Adjustment__c> rows = StockAdjustmentController.getAllAdjustments();
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'An empty list renders an empty grid');
    }

    @isTest
    static void allAdjustments_returnsNewestFirstWithRelatedNames() {
        Stock_Adjustment__c older = insertDraft(100, 90);
        Stock_Adjustment__c newer = insertDraft(50, 60);
        // Records created in one transaction share a CreatedDate, so age one
        // explicitly to make the ordering assertion meaningful.
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-3));

        Test.startTest();
        List<Stock_Adjustment__c> rows = StockAdjustmentController.getAllAdjustments();
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Both adjustments listed');
        System.assertEquals(newer.Id, rows[0].Id, 'Newest first — the grid leads with recent work');
        System.assertEquals('ADJ Main Store', rows[0].Warehouse__r.Name,
            'The warehouse name is resolved so the grid shows a place, not an id');
        System.assertEquals('ADJ Alpha', rows[0].Product__r.Name, 'Same for the product');
        System.assertEquals('ADJMAIN', rows[0].Warehouse__r.Warehouse_Code__c, 'And its code');
    }

    // ── saveDraft ─────────────────────────────────────────────────────

    @isTest
    static void saveDraft_withNothingToSave_isRejected() {
        Test.startTest();
        Boolean threw = false;
        try {
            StockAdjustmentController.saveDraft(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A null payload has nothing to save');
    }

    @isTest
    static void saveDraft_recomputesTheAdjustmentQuantityServerSide() {
        Stock_Adjustment__c adj = draft(100, 80);
        // The client posts a figure that does not match its own System/Actual —
        // stale form state, or a tampered request.
        adj.Adjustment_Qty__c = 999;

        Test.startTest();
        Stock_Adjustment__c saved = StockAdjustmentController.saveDraft(adj);
        Test.stopTest();

        System.assertEquals(-20, saved.Adjustment_Qty__c,
            'The server recomputes Actual - System and discards what the client sent — this '
            + 'figure is what the approval writes back to inventory, so trusting the browser '
            + 'would let a stale form move stock by an arbitrary amount');
    }

    @isTest
    static void saveDraft_computesAPositiveAdjustmentWhenStockIsFound() {
        Test.startTest();
        Stock_Adjustment__c saved = StockAdjustmentController.saveDraft(draft(40, 55));
        Test.stopTest();

        System.assertEquals(15, saved.Adjustment_Qty__c,
            'Counting more than the system thought is a positive adjustment');
    }

    @isTest
    static void saveDraft_fillsInTheDefaults() {
        Stock_Adjustment__c adj = draft(100, 80);
        adj.Adjustment_Date__c = null;
        adj.Adjusted_By__c = null;
        adj.Status__c = null;

        Test.startTest();
        Stock_Adjustment__c saved = StockAdjustmentController.saveDraft(adj);
        Test.stopTest();

        System.assertEquals(Date.today(), saved.Adjustment_Date__c,
            'An undated adjustment is dated today rather than saved blank');
        System.assertEquals(UserInfo.getUserId(), saved.Adjusted_By__c,
            'And attributed to whoever counted');
        System.assertEquals('Draft', saved.Status__c,
            'New adjustments start in Draft so they can be corrected before approval');
    }

    @isTest
    static void saveDraft_keepsValuesTheCallerSupplied() {
        Stock_Adjustment__c adj = draft(100, 80);
        adj.Adjustment_Date__c = Date.today().addDays(-5);

        Test.startTest();
        Stock_Adjustment__c saved = StockAdjustmentController.saveDraft(adj);
        Test.stopTest();

        System.assertEquals(Date.today().addDays(-5), saved.Adjustment_Date__c,
            'A back-dated count keeps its own date — the default only fills a gap');
    }

    @isTest
    static void saveDraft_updatesAnExistingAdjustmentInPlace() {
        Stock_Adjustment__c adj = insertDraft(100, 80);

        Test.startTest();
        adj.Actual_Qty__c = 95;
        adj.Reason__c = 'Recounted after recheck';
        Stock_Adjustment__c saved = StockAdjustmentController.saveDraft(adj);
        Test.stopTest();

        System.assertEquals(adj.Id, saved.Id, 'The same record was updated');
        System.assertEquals(-5, saved.Adjustment_Qty__c,
            'And the adjustment is recomputed from the corrected count, not left stale');
        System.assertEquals(1, [SELECT COUNT() FROM Stock_Adjustment__c],
            'Re-saving does not create a second row');
    }

    // ── deleteAdjustment ──────────────────────────────────────────────

    @isTest
    static void deleteAdjustment_withNoId_isANoOp() {
        insertDraft(100, 80);

        Test.startTest();
        StockAdjustmentController.deleteAdjustment(null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Stock_Adjustment__c],
            'A null id is ignored, never read as "delete something"');
    }

    @isTest
    static void deleteAdjustment_removesADraft() {
        Stock_Adjustment__c adj = insertDraft(100, 80);

        Test.startTest();
        StockAdjustmentController.deleteAdjustment(adj.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Stock_Adjustment__c],
            'An unsubmitted count can be discarded');
    }

    @isTest
    static void deleteAdjustment_refusesAnythingPastDraft() {
        Stock_Adjustment__c adj = insertDraft(100, 80);
        adj.Status__c = 'Submitted';
        update adj;

        Test.startTest();
        Boolean threw = false;
        try {
            StockAdjustmentController.deleteAdjustment(adj.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'Once submitted the adjustment is part of an approval trail and cannot be erased');
        System.assertEquals(1, [SELECT COUNT() FROM Stock_Adjustment__c], 'It survives');
    }

    // ── submitForApproval ─────────────────────────────────────────────

    @isTest
    static void submit_withNoId_isRejected() {
        Test.startTest();
        Boolean threw = false;
        try {
            StockAdjustmentController.submitForApproval(null, 'go');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Nothing to submit without an adjustment');
    }

    @isTest
    static void submit_refusesAnythingNotInDraft() {
        Stock_Adjustment__c adj = insertDraft(100, 80);
        adj.Status__c = 'Approved';
        update adj;

        Test.startTest();
        Boolean threw = false;
        try {
            StockAdjustmentController.submitForApproval(adj.Id, 'again');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'Resubmitting an approved adjustment would raise a second approval for stock '
            + 'already written back');
    }

    @isTest
    static void submit_requiresTheFieldsTheApprovalWillActOn() {
        // Each of these saves cleanly but cannot be acted on downstream.
        // Adjustment_Qty is set directly so Qty_Not_Zero is satisfied without
        // needing both System and Actual.
        //
        // A missing WAREHOUSE is not testable here: Location_Type__c defaults to
        // 'Warehouse' and DMS_Location_Reference_Required then demands one, so a
        // warehouse-type adjustment with a blank Warehouse__c cannot be saved at
        // all. See submit_cannotSubmitADistributorAdjustment for the case where
        // that guard does bite.
        Stock_Adjustment__c noProduct = draft(100, 80);
        noProduct.Product__c = null;
        Stock_Adjustment__c noType = draft(100, 80);
        noType.Adjustment_Type__c = null;
        Stock_Adjustment__c noActual = draft(100, null);
        noActual.Adjustment_Qty__c = -20;
        insert new List<Stock_Adjustment__c>{ noProduct, noType, noActual };

        Test.startTest();
        Integer rejected = 0;
        for (Id adjId : new List<Id>{ noProduct.Id, noType.Id, noActual.Id }) {
            try {
                StockAdjustmentController.submitForApproval(adjId, 'go');
            } catch (AuraHandledException e) {
                rejected++;
            }
        }
        Test.stopTest();

        System.assertEquals(3, rejected,
            'An adjustment missing its product, type or counted quantity cannot be approved '
            + 'into a stock movement, so it is stopped at submission');
        System.assertEquals(0, [SELECT COUNT() FROM Approval_Request__c],
            'And no approval is raised for any of them');
    }

    /**
     * KNOWN GAP — Stock_Adjustment__c supports two location types. A Distributor
     * adjustment legitimately carries an Account__c and NO Warehouse__c, and
     * DMS_Location_Reference_Required is written to allow exactly that.
     *
     * submitForApproval, however, requires Warehouse__c unconditionally. So a
     * distributor stock adjustment can be created and saved through this
     * controller but can never be submitted — it is stuck in Draft with an error
     * that names a field the record is not supposed to have.
     *
     * Pinned here so the limitation is visible. If distributor adjustments are
     * meant to route for approval, that check needs to become "a warehouse OR an
     * account, matching Location_Type__c", and this test should be rewritten.
     */
    @isTest
    static void submit_cannotSubmitADistributorAdjustment() {
        Account distributor = TestDataFactory.createAccount('ADJ Distributor', 'Distributor');
        insert distributor;

        Stock_Adjustment__c adj = draft(100, 80);
        adj.Location_Type__c = 'Distributor';
        adj.Account__c = distributor.Id;
        adj.Warehouse__c = null;   // valid for a distributor-side adjustment
        adj.Adjustment_Qty__c = -20;
        insert adj;

        Test.startTest();
        Boolean threw = false;
        try {
            StockAdjustmentController.submitForApproval(adj.Id, 'Distributor count');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'A distributor adjustment saves happily but is refused at submission, because the '
            + 'controller asks for a warehouse the record is not meant to carry');
        System.assertEquals('Draft', [
            SELECT Status__c FROM Stock_Adjustment__c WHERE Id = :adj.Id
        ].Status__c, 'Leaving it stranded in Draft');
    }

    @isTest
    static void submit_routesACompleteDraftThroughTheApprovalEngine() {
        insert new Approval_Rule__c(
            Object_Process__c = 'Stock_Adjustment__c',
            Approval_Level__c = 1,
            Approver_Type__c = 'User',
            User__c = UserInfo.getUserId(),
            Auto_Approve__c = false,
            Is_Active__c = true
        );
        Stock_Adjustment__c adj = insertDraft(100, 80);

        Test.startTest();
        Id requestId = StockAdjustmentController.submitForApproval(adj.Id, 'Please review the count');
        Test.stopTest();

        System.assertNotEquals(null, requestId, 'An approval request comes back');
        Approval_Request__c req = [
            SELECT Object_Type__c, Record_Id__c, Status__c, Comments__c
            FROM Approval_Request__c WHERE Id = :requestId
        ];
        System.assertEquals('Stock_Adjustment__c', req.Object_Type__c,
            'Routed through the generic engine so it lands in My Approvals with everything else');
        System.assertEquals(String.valueOf(adj.Id), req.Record_Id__c, 'Against this adjustment');
        System.assertEquals('Pending', req.Status__c, 'Awaiting the approver');
        System.assertEquals('Please review the count', req.Comments__c, 'With the note attached');
    }

    // ── getStockInfo ──────────────────────────────────────────────────

    @isTest
    static void stockInfo_withoutBothKeys_returnsTheEmptyShape() {
        Test.startTest();
        Map<String, Object> noWarehouse = StockAdjustmentController.getStockInfo(null, alpha(), null);
        Map<String, Object> noProduct = StockAdjustmentController.getStockInfo(mainStore(), null, null);
        Test.stopTest();

        System.assertEquals(false, noWarehouse.get('exists'), 'Nothing to look up');
        System.assertEquals(0, noWarehouse.get('qtyOnHand'),
            'The form still gets a zero to pre-fill with, rather than a null it must guard');
        System.assertEquals(false, noProduct.get('exists'), 'Same without a product');
        System.assertEquals(0, noProduct.get('qtyAvailable'), 'And the same zeroed shape');
    }

    @isTest
    static void stockInfo_whenTheWarehouseHasNeverStockedTheProduct() {
        Test.startTest();
        Map<String, Object> info = StockAdjustmentController.getStockInfo(mainStore(), alpha(), null);
        Test.stopTest();

        System.assertEquals(false, info.get('exists'),
            'A first-ever count for a product reports no existing stock rather than failing');
        System.assertEquals(0, info.get('qtyOnHand'), 'So the system quantity pre-fills as zero');
    }

    @isTest
    static void stockInfo_returnsTheLiveQuantities() {
        insert stock(mainStore(), alpha(), 'B-ADJ-1', 120, 20);

        Test.startTest();
        Map<String, Object> info = StockAdjustmentController.getStockInfo(mainStore(), alpha(), null);
        Test.stopTest();

        System.assertEquals(true, info.get('exists'), 'The stock row was found');
        System.assertEquals(120, info.get('qtyOnHand'),
            'On-hand is what a physical count is compared against');
        System.assertEquals(100, info.get('qtyAvailable'), 'Available is on-hand less reserved');
        System.assertEquals(20, info.get('qtyReserved'), 'Reserved surfaced');
        System.assertEquals(0, info.get('qtyDamaged'), 'And damaged');
        System.assertNotEquals(null, info.get('stockId'), 'With the row id for the writeback');
    }

    @isTest
    static void stockInfo_narrowsToTheRequestedBatch() {
        insert new List<Warehouse_Stock__c>{
            stock(mainStore(), alpha(), 'B-OLD', 30, 0),
            stock(mainStore(), alpha(), 'B-NEW', 75, 0)
        };

        Test.startTest();
        Map<String, Object> newBatch = StockAdjustmentController.getStockInfo(
            mainStore(), alpha(), 'B-NEW');
        Map<String, Object> missingBatch = StockAdjustmentController.getStockInfo(
            mainStore(), alpha(), 'B-NOPE');
        Test.stopTest();

        System.assertEquals(75, newBatch.get('qtyOnHand'),
            'Counting a specific batch must compare against that batch, not whichever row '
            + 'the query happened to return first');
        System.assertEquals(false, missingBatch.get('exists'),
            'A batch the warehouse does not hold reports as absent');
    }

    // ── getPicklistOptions ────────────────────────────────────────────

    @isTest
    static void picklistOptions_returnTheAdjustmentTypes() {
        Test.startTest();
        Map<String, List<Map<String, String>>> options =
            StockAdjustmentController.getPicklistOptions();
        Test.stopTest();

        System.assert(options.containsKey('Adjustment_Type__c'), 'The type picker is driven from here');
        Set<Object> values = valuesOf(options.get('Adjustment_Type__c'), 'value');
        System.assert(!values.isEmpty(), 'And it is populated');
        System.assert(values.contains('Physical_Count'), 'Including the everyday cycle-count type');
        for (Map<String, String> o : options.get('Adjustment_Type__c')) {
            System.assert(String.isNotBlank(o.get('label')), 'Every option needs a display label');
        }
    }

    // ── searchWarehouses ──────────────────────────────────────────────

    @isTest
    static void searchWarehouses_withNoTerm_listsEveryActiveWarehouse() {
        Test.startTest();
        List<Map<String, String>> rows = StockAdjustmentController.searchWarehouses(null);
        Test.stopTest();

        Set<Object> labels = valuesOf(rows, 'label');
        System.assert(labels.contains('ADJ Main Store'), 'An empty term opens the full list');
        System.assert(labels.contains('ADJ Overflow'), 'Both active ones');
        System.assert(!labels.contains('ADJ Closed'),
            'A decommissioned warehouse is never adjustable');
    }

    @isTest
    static void searchWarehouses_matchesNameOrCode() {
        Test.startTest();
        List<Map<String, String>> byName = StockAdjustmentController.searchWarehouses('Overflow');
        List<Map<String, String>> byCode = StockAdjustmentController.searchWarehouses('ADJMAIN');
        List<Map<String, String>> noMatch = StockAdjustmentController.searchWarehouses('Zzzzz');
        Test.stopTest();

        System.assertEquals(1, byName.size(), 'Name is searchable');
        System.assertEquals('ADJ Overflow', byName[0].get('label'), 'And it is the right one');
        System.assertEquals(1, byCode.size(),
            'So is the code — staff often know the warehouse by its code alone');
        System.assertEquals(0, noMatch.size(), 'A miss returns nothing');
    }

    @isTest
    static void searchWarehouses_showsCodeAndCityInTheSubtitle() {
        Test.startTest();
        List<Map<String, String>> rows = StockAdjustmentController.searchWarehouses('Main Store');
        Test.stopTest();

        System.assertEquals('ADJMAIN · Mumbai', rows[0].get('subtitle'),
            'Code and city disambiguate similarly named warehouses');
    }

    // ── searchProducts ────────────────────────────────────────────────

    @isTest
    static void searchProducts_withNoWarehouse_searchesTheWholeCatalogue() {
        Test.startTest();
        List<Map<String, String>> rows = StockAdjustmentController.searchProducts('ADJ', null);
        Test.stopTest();

        Set<Object> labels = valuesOf(rows, 'label');
        System.assert(labels.contains('ADJ Alpha'), 'Active products are offered');
        System.assert(labels.contains('ADJ Beta'), 'All of them');
        System.assert(!labels.contains('ADJ Retired'),
            'A discontinued product cannot be adjusted');
    }

    @isTest
    static void searchProducts_withAStockedWarehouse_narrowsToWhatIsHeldThere() {
        insert stock(mainStore(), alpha(), 'B-ADJ-1', 50, 0);

        Test.startTest();
        List<Map<String, String>> rows = StockAdjustmentController.searchProducts('ADJ', mainStore());
        Test.stopTest();

        System.assertEquals(1, rows.size(),
            'Once a warehouse is chosen the picker shows only what it actually stocks, so a '
            + 'counter is not offered products that were never there');
        System.assertEquals('ADJ Alpha', rows[0].get('label'), 'The stocked one');
    }

    @isTest
    static void searchProducts_withAnEmptyWarehouse_fallsBackToTheWholeCatalogue() {
        // overflow() holds no stock rows at all.
        Test.startTest();
        List<Map<String, String>> rows = StockAdjustmentController.searchProducts('ADJ', overflow());
        Test.stopTest();

        Set<Object> labels = valuesOf(rows, 'label');
        System.assert(labels.contains('ADJ Alpha'), 'A brand-new warehouse still offers products');
        System.assert(labels.contains('ADJ Beta'),
            'Falling back to the full catalogue is deliberate — otherwise the first stock '
            + 'adjustment at a new warehouse could never be logged');
    }

    @isTest
    static void searchProducts_matchesOnProductCode() {
        Test.startTest();
        List<Map<String, String>> rows = StockAdjustmentController.searchProducts('ADJ-BETA', null);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'The code is searchable');
        System.assertEquals('ADJ Beta', rows[0].get('label'), 'And resolves to its product');
        System.assertEquals('ADJ-BETA', rows[0].get('subtitle'), 'With the code as the subtitle');
    }
}