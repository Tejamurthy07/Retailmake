/**
 * @description Tests for StockOperationsHubController — the Stock Operations Hub
 * LWC's read slices, transfer request creation, approval submission and receipt.
 *
 * The weight here is on confirmReceipt and its applyStockMovements helper,
 * because that is where the class stops being a thin wrapper and starts moving
 * real inventory. It deliberately bypasses INV_StockTransfer_TriggerHandler and
 * redoes both stock legs itself, which means:
 *
 *   - nothing else is checking the arithmetic;
 *   - the skip-if-already-logged guard is the only thing standing between a
 *     re-run and double-counted stock.
 *
 * So those get the most tests, including the idempotency path, the floor at
 * zero, and the case where the destination warehouse has never held the product.
 *
 * Note on fixtures: Qty_Available__c, Is_Low_Stock__c and Is_Zero_Stock__c are
 * all formulas, so stock states are set up by writing Qty_On_Hand__c,
 * Qty_Reserved__c and Min_Stock_Level__c rather than the derived fields.
 */
@isTest
private class StockOperationsHubControllerTest {

    @testSetup
    static void setupTestData() {
        // Warehouse_Code_Format requires ^[A-Za-z0-9]{3,20}$ — strictly
        // alphanumeric, so no hyphens or separators in these codes.
        List<Warehouse__c> warehouses = new List<Warehouse__c>{
            new Warehouse__c(Name = 'SOH Source', Warehouse_Code__c = 'SOHSRC',
                City__c = 'Mumbai', State__c = 'Maharashtra',
                Is_Active__c = true, Manager__c = UserInfo.getUserId()),
            new Warehouse__c(Name = 'SOH Destination', Warehouse_Code__c = 'SOHDEST',
                City__c = 'Pune', State__c = 'Maharashtra',
                Is_Active__c = true, Manager__c = UserInfo.getUserId()),
            new Warehouse__c(Name = 'SOH Retired', Warehouse_Code__c = 'SOHOLD',
                City__c = 'Nagpur', State__c = 'Maharashtra', Is_Active__c = false)
        };
        insert warehouses;

        insert new List<Product2>{
            new Product2(Name = 'SOH Alpha Widget', ProductCode = 'SOH-ALPHA', IsActive = true),
            new Product2(Name = 'SOH Beta Widget', ProductCode = 'SOH-BETA', IsActive = true),
            new Product2(Name = 'SOH Gamma Widget', ProductCode = 'SOH-GAMMA', IsActive = true)
        };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> cachedWarehouses;
    private static Map<String, Id> cachedProducts;

    private static Map<String, Id> warehouses() {
        if (cachedWarehouses == null) {
            cachedWarehouses = new Map<String, Id>();
            for (Warehouse__c w : [
                SELECT Id, Warehouse_Code__c FROM Warehouse__c WHERE Warehouse_Code__c LIKE 'SOH%'
            ]) {
                cachedWarehouses.put(w.Warehouse_Code__c, w.Id);
            }
        }
        return cachedWarehouses;
    }

    private static Map<String, Id> products() {
        if (cachedProducts == null) {
            cachedProducts = new Map<String, Id>();
            for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode LIKE 'SOH-%']) {
                cachedProducts.put(p.ProductCode, p.Id);
            }
        }
        return cachedProducts;
    }

    private static Id src()   { return warehouses().get('SOHSRC'); }
    private static Id dest()  { return warehouses().get('SOHDEST'); }
    private static Id alpha() { return products().get('SOH-ALPHA'); }
    private static Id beta()  { return products().get('SOH-BETA'); }
    private static Id gamma() { return products().get('SOH-GAMMA'); }

    private static Warehouse_Stock__c stock(
            Id warehouseId, Id productId, String batch, Decimal onHand, Decimal minLevel) {
        return new Warehouse_Stock__c(
            Warehouse__c = warehouseId,
            Product__c = productId,
            Batch_Number__c = batch,
            Qty_On_Hand__c = onHand,
            Qty_Reserved__c = 0,
            Qty_Damaged__c = 0,
            Min_Stock_Level__c = minLevel,
            Max_Stock_Level__c = 1000
        );
    }

    /** Healthy 100, zero-stock, and low-stock rows in the source warehouse. */
    private static void seedSourceStock() {
        insert new List<Warehouse_Stock__c>{
            stock(src(), alpha(), 'B-ALPHA', 100, 10),
            stock(src(), beta(),  'B-BETA',    0, 5),
            stock(src(), gamma(), 'B-GAMMA',   5, 10)
        };
    }

    private static Stock_Transfer__c transfer(String status) {
        Stock_Transfer__c t = new Stock_Transfer__c(
            Source_Warehouse__c = src(),
            Destination_Warehouse__c = dest(),
            Transfer_Date__c = Date.today(),
            Status__c = status,
            Requested_By__c = UserInfo.getUserId()
        );
        insert t;
        return t;
    }

    private static Stock_Transfer_Line__c line(
            Id transferId, Id productId, String batch, Decimal requested, Decimal approved) {
        return new Stock_Transfer_Line__c(
            Stock_Transfer__c = transferId,
            Product__c = productId,
            Batch_Number__c = batch,
            Requested_Qty__c = requested,
            Approved_Qty__c = approved
        );
    }

    private static Decimal onHandFor(Id warehouseId, Id productId, String batch) {
        List<Warehouse_Stock__c> rows = [
            SELECT Qty_On_Hand__c FROM Warehouse_Stock__c
            WHERE Warehouse__c = :warehouseId AND Product__c = :productId
              AND Batch_Number__c = :batch
        ];
        return rows.isEmpty() ? null : rows[0].Qty_On_Hand__c;
    }

    private static Map<String, Object> firstWhere(
            List<Map<String, Object>> rows, String key, Object value) {
        for (Map<String, Object> r : rows) {
            if (value.equals(r.get(key))) return r;
        }
        return null;
    }

    // ── getActiveWarehouses ───────────────────────────────────────────

    @isTest
    static void activeWarehouses_excludeRetiredOnes() {
        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getActiveWarehouses();
        Test.stopTest();

        Set<Object> labels = new Set<Object>();
        for (Map<String, Object> r : rows) labels.add(r.get('label'));
        System.assert(labels.contains('SOH Source'), 'An active warehouse is selectable');
        System.assert(labels.contains('SOH Destination'), 'Both active ones are');
        System.assert(!labels.contains('SOH Retired'),
            'A decommissioned warehouse must not be offered as a transfer endpoint');
    }

    @isTest
    static void activeWarehouses_carryCodeAndCityInTheSubtitle() {
        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getActiveWarehouses();
        Test.stopTest();

        Map<String, Object> source = firstWhere(rows, 'label', 'SOH Source');
        System.assertNotEquals(null, source, 'The source warehouse is listed');
        System.assertEquals(src(), source.get('value'), 'Keyed by id for the picker');
        System.assertEquals('SOHSRC · Mumbai', source.get('subtitle'),
            'Code and city disambiguate warehouses with similar names');
    }

    // ── getAvailability ───────────────────────────────────────────────

    @isTest
    static void availability_withNoWarehouse_returnsEmpty() {
        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getAvailability(null, null, null);
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'No warehouse chosen means nothing to show');
    }

    @isTest
    static void availability_returnsEveryRowForTheWarehouse() {
        seedSourceStock();

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getAvailability(src(), null, null);
        Test.stopTest();

        System.assertEquals(3, rows.size(), 'All three stock rows come back');
        Map<String, Object> alphaRow = firstWhere(rows, 'productCode', 'SOH-ALPHA');
        System.assertEquals(100, alphaRow.get('qtyOnHand'), 'On-hand surfaced');
        System.assertEquals(100, alphaRow.get('qtyAvailable'),
            'Available is on-hand less reserved, and nothing is reserved here');
        System.assertEquals('B-ALPHA', alphaRow.get('batchNumber'), 'Batch surfaced');
        System.assertEquals(false, alphaRow.get('isLow'), 'Well above its minimum');
        System.assertEquals(false, alphaRow.get('isZero'), 'And not empty');
    }

    @isTest
    static void availability_lowFilterShowsOnlyStockAtOrBelowItsMinimum() {
        seedSourceStock();

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getAvailability(src(), null, 'low');
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'Only the row running low');
        System.assertEquals('SOH-GAMMA', rows[0].get('productCode'),
            'Five on hand against a minimum of ten is the reorder signal');
        System.assertEquals(true, rows[0].get('isLow'), 'Flagged low');
    }

    @isTest
    static void availability_zeroFilterShowsOnlyEmptyStock() {
        seedSourceStock();

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getAvailability(src(), null, 'zero');
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'Only the empty row');
        System.assertEquals('SOH-BETA', rows[0].get('productCode'), 'The one at zero');
        System.assertEquals(true, rows[0].get('isZero'), 'Flagged empty');
        System.assertEquals(false, rows[0].get('isLow'),
            'Empty is not "low" — the formula excludes zero so the two filters do not overlap');
    }

    @isTest
    static void availability_searchMatchesNameCodeAndBatch() {
        seedSourceStock();

        Test.startTest();
        List<Map<String, Object>> byName = StockOperationsHubController.getAvailability(src(), 'Alpha', null);
        List<Map<String, Object>> byCode = StockOperationsHubController.getAvailability(src(), 'SOH-BETA', null);
        List<Map<String, Object>> byBatch = StockOperationsHubController.getAvailability(src(), 'B-GAMMA', null);
        List<Map<String, Object>> noMatch = StockOperationsHubController.getAvailability(src(), 'Zzzzz', null);
        Test.stopTest();

        System.assertEquals(1, byName.size(), 'Product name is searchable');
        System.assertEquals(1, byCode.size(), 'So is the product code');
        System.assertEquals(1, byBatch.size(),
            'And the batch number — warehouse staff often have only the batch on the carton');
        System.assertEquals(0, noMatch.size(), 'A miss returns nothing rather than everything');
    }

    @isTest
    static void availability_isScopedToOneWarehouse() {
        seedSourceStock();
        insert stock(dest(), alpha(), 'B-ALPHA', 999, 10);

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getAvailability(dest(), null, null);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'Only the destination warehouse rows');
        System.assertEquals(999, rows[0].get('qtyOnHand'), 'With its own quantity');
    }

    // ── searchSourceProducts ──────────────────────────────────────────

    @isTest
    static void searchSourceProducts_guardsAgainstUnusableInput() {
        seedSourceStock();

        Test.startTest();
        List<Map<String, Object>> noWarehouse =
            StockOperationsHubController.searchSourceProducts(null, 'Alpha');
        List<Map<String, Object>> blank =
            StockOperationsHubController.searchSourceProducts(src(), '');
        List<Map<String, Object>> tooShort =
            StockOperationsHubController.searchSourceProducts(src(), 'A');
        Test.stopTest();

        System.assertEquals(0, noWarehouse.size(), 'No source warehouse, nothing to search');
        System.assertEquals(0, blank.size(), 'A blank term is not a search');
        System.assertEquals(0, tooShort.size(),
            'One character would return the whole catalogue on every keystroke');
    }

    @isTest
    static void searchSourceProducts_returnsAvailabilityInTheSubtitle() {
        seedSourceStock();

        Test.startTest();
        List<Map<String, Object>> rows =
            StockOperationsHubController.searchSourceProducts(src(), 'Alpha');
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'The matching product');
        System.assertEquals(alpha(), rows[0].get('value'), 'Keyed by product id');
        System.assertEquals('SOH Alpha Widget', rows[0].get('label'), 'Named for the picker');
        System.assertEquals(100, rows[0].get('availableQty'), 'Available quantity exposed');
        System.assertEquals('B-ALPHA', rows[0].get('batchNumber'), 'And the batch');
        System.assert(String.valueOf(rows[0].get('subtitle')).contains('Available: 100'),
            'The requester sees what is actually on the shelf before asking for it: '
            + rows[0].get('subtitle'));
    }

    // ── getMyRequests ─────────────────────────────────────────────────

    @isTest
    static void myRequests_includeOnesIRaisedWithTheirLineCount() {
        Stock_Transfer__c t = transfer('Draft');
        insert new List<Stock_Transfer_Line__c>{
            line(t.Id, alpha(), 'B-ALPHA', 10, 10),
            line(t.Id, beta(), 'B-BETA', 5, 5)
        };

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getMyRequests();
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'My request is listed');
        System.assertEquals(t.Id, rows[0].get('id'), 'The right one');
        System.assertEquals('Draft', rows[0].get('status'), 'With its status');
        System.assertEquals(2, rows[0].get('lineCount'),
            'And its line count, so the list shows size without a second query');
        System.assertEquals(true, rows[0].get('isMine'),
            'Flagged as mine so the UI can offer submit/edit');
        System.assertEquals('SOH Source', rows[0].get('sourceWarehouse'), 'Source named');
        System.assertEquals('SOH Destination', rows[0].get('destinationWarehouse'), 'Destination named');
    }

    @isTest
    static void myRequests_showZeroLinesForAnEmptyRequest() {
        transfer('Draft');

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getMyRequests();
        Test.stopTest();

        System.assertEquals(0, rows[0].get('lineCount'),
            'A request with no lines reports zero rather than failing on a null subquery');
    }

    // ── createRequest ─────────────────────────────────────────────────

    @isTest
    static void createRequest_rejectsAMissingOrIdenticalEndpoint() {
        Test.startTest();
        Integer rejected = 0;
        try {
            StockOperationsHubController.createRequest(null, dest(), Date.today(), null, null);
        } catch (AuraHandledException e) { rejected++; }
        try {
            StockOperationsHubController.createRequest(src(), null, Date.today(), null, null);
        } catch (AuraHandledException e) { rejected++; }
        try {
            StockOperationsHubController.createRequest(src(), src(), Date.today(), null, null);
        } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(3, rejected,
            'A transfer needs two different endpoints — moving stock to itself is a no-op '
            + 'that would still deduct and re-add');
        System.assertEquals(0, [SELECT COUNT() FROM Stock_Transfer__c], 'Nothing created');
    }

    @isTest
    static void createRequest_startsAsDraftAndDefaultsTheDate() {
        Test.startTest();
        Id transferId = StockOperationsHubController.createRequest(
            src(), dest(), null, 'Urgent restock', null);
        Test.stopTest();

        Stock_Transfer__c saved = [
            SELECT Status__c, Transfer_Date__c, Notes__c, Requested_By__c,
                   Source_Warehouse__c, Destination_Warehouse__c
            FROM Stock_Transfer__c WHERE Id = :transferId
        ];
        System.assertEquals('Draft', saved.Status__c,
            'A new request starts in Draft so it can be edited before submission');
        System.assertEquals(Date.today(), saved.Transfer_Date__c,
            'A missing date defaults to today rather than saving blank');
        System.assertEquals('Urgent restock', saved.Notes__c, 'Notes carried');
        System.assertEquals(UserInfo.getUserId(), saved.Requested_By__c, 'Raised by the running user');
    }

    @isTest
    static void createRequest_buildsLinesAndSnapshotsAvailableStock() {
        seedSourceStock();
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{
                'productId' => alpha(), 'batchNumber' => 'B-ALPHA', 'requestedQty' => 25
            }
        });

        Test.startTest();
        Id transferId = StockOperationsHubController.createRequest(
            src(), dest(), Date.today(), null, linesJson);
        Test.stopTest();

        List<Stock_Transfer_Line__c> lines = [
            SELECT Product__c, Batch_Number__c, Requested_Qty__c, Approved_Qty__c, Available_Stock__c
            FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId
        ];
        System.assertEquals(1, lines.size(), 'One line created');
        System.assertEquals(alpha(), lines[0].Product__c, 'For the requested product');
        System.assertEquals(25, lines[0].Requested_Qty__c, 'At the requested quantity');
        System.assertEquals(25, lines[0].Approved_Qty__c,
            'Approved defaults to requested so the approval has something to deduct');
        System.assertEquals(100, lines[0].Available_Stock__c,
            'The source availability is snapshotted at request time — the approver needs the '
            + 'picture as it was, not as it becomes');
    }

    @isTest
    static void createRequest_snapshotsZeroWhenSourceHasNoStockRow() {
        // No Warehouse_Stock row for this product at the source at all.
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'productId' => alpha(), 'requestedQty' => 10 }
        });

        Test.startTest();
        Id transferId = StockOperationsHubController.createRequest(
            src(), dest(), Date.today(), null, linesJson);
        Test.stopTest();

        System.assertEquals(0, [
            SELECT Available_Stock__c FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c = :transferId
        ].Available_Stock__c,
            'A product the source has never stocked snapshots as zero, not null — the '
            + 'approver sees plainly that there is nothing to send');
    }

    @isTest
    static void createRequest_skipsLinesWithNoProductOrQuantity() {
        seedSourceStock();
        String linesJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'productId' => alpha(), 'requestedQty' => 10 },
            new Map<String, Object>{ 'productId' => null,    'requestedQty' => 10 },
            new Map<String, Object>{ 'productId' => beta(),  'requestedQty' => 0 },
            new Map<String, Object>{ 'productId' => gamma(), 'requestedQty' => null }
        });

        Test.startTest();
        Id transferId = StockOperationsHubController.createRequest(
            src(), dest(), Date.today(), null, linesJson);
        Test.stopTest();

        System.assertEquals(1, [
            SELECT COUNT() FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId
        ], 'Only the usable line survives — a zero-quantity row would move nothing but still '
         + 'clutter the approval');
    }

    @isTest
    static void createRequest_withNoLinesCreatesTheHeaderAlone() {
        Test.startTest();
        Id transferId = StockOperationsHubController.createRequest(
            src(), dest(), Date.today(), 'Lines to follow', '');
        Test.stopTest();

        System.assertNotEquals(null, transferId, 'The header saves');
        System.assertEquals(0, [
            SELECT COUNT() FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId
        ], 'A request can be drafted before its lines are known');
    }

    // ── submitRequest ─────────────────────────────────────────────────

    @isTest
    static void submitRequest_rejectsAnythingNotInDraft() {
        Stock_Transfer__c approved = transfer('Approved');

        Test.startTest();
        Boolean threw = false;
        try {
            StockOperationsHubController.submitRequest(approved.Id, 'please');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'Only a Draft can be submitted — resubmitting an approved transfer would raise a '
            + 'second approval for stock already committed');
    }

    @isTest
    static void submitRequest_routesADraftThroughTheApprovalEngine() {
        insert new Approval_Rule__c(
            Object_Process__c = 'Stock_Transfer__c',
            Approval_Level__c = 1,
            Approver_Type__c = 'User',
            User__c = UserInfo.getUserId(),
            Auto_Approve__c = false,
            Is_Active__c = true
        );
        Stock_Transfer__c draft = transfer('Draft');

        Test.startTest();
        Id requestId = StockOperationsHubController.submitRequest(draft.Id, 'Please approve');
        Test.stopTest();

        System.assertNotEquals(null, requestId, 'An approval request id comes back');
        Approval_Request__c req = [
            SELECT Object_Type__c, Record_Id__c, Status__c, Comments__c
            FROM Approval_Request__c WHERE Id = :requestId
        ];
        System.assertEquals('Stock_Transfer__c', req.Object_Type__c,
            'Routed through the generic engine, so it lands in My Approvals like everything else');
        System.assertEquals(String.valueOf(draft.Id), req.Record_Id__c, 'Against this transfer');
        System.assertEquals('Pending', req.Status__c, 'Awaiting the warehouse manager');
        System.assertEquals('Please approve', req.Comments__c, 'With the submitter comments');
    }

    // ── getPendingReceipts ────────────────────────────────────────────

    @isTest
    static void pendingReceipts_showOnlyApprovedAndInTransit() {
        transfer('Draft');
        Stock_Transfer__c approved = transfer('Approved');
        Stock_Transfer__c inTransit = transfer('In_Transit');
        transfer('Received');

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getPendingReceipts();
        Test.stopTest();

        Set<Object> ids = new Set<Object>();
        for (Map<String, Object> r : rows) ids.add(r.get('id'));
        System.assertEquals(2, rows.size(), 'Only the two receivable states');
        System.assert(ids.contains(approved.Id), 'Approved is receivable');
        System.assert(ids.contains(inTransit.Id), 'So is in-transit');
    }

    // ── getRequestLines ───────────────────────────────────────────────

    @isTest
    static void requestLines_withNoTransfer_returnsEmpty() {
        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getRequestLines(null);
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'Nothing selected, nothing to show');
    }

    @isTest
    static void requestLines_defaultReceivedFallsBackThroughApprovedThenRequested() {
        Stock_Transfer__c t = transfer('Approved');
        insert new List<Stock_Transfer_Line__c>{
            line(t.Id, alpha(), 'B-ALPHA', 20, 15),     // approved differs from requested
            line(t.Id, beta(),  'B-BETA',  30, null)    // never explicitly approved
        };

        Test.startTest();
        List<Map<String, Object>> rows = StockOperationsHubController.getRequestLines(t.Id);
        Test.stopTest();

        Map<String, Object> alphaRow = firstWhere(rows, 'productCode', 'SOH-ALPHA');
        Map<String, Object> betaRow = firstWhere(rows, 'productCode', 'SOH-BETA');
        System.assertEquals(15, alphaRow.get('defaultReceivedQty'),
            'The receive modal opens at the APPROVED quantity, not the requested one — '
            + 'defaulting to requested would quietly over-receive a trimmed approval');
        System.assertEquals(30, betaRow.get('defaultReceivedQty'),
            'With no approved quantity it falls back to requested');
        System.assertEquals(20, alphaRow.get('requestedQty'), 'Requested still shown for context');
    }

    // ── confirmReceipt ────────────────────────────────────────────────

    @isTest
    static void confirmReceipt_rejectsMissingIdOrWrongStatus() {
        Stock_Transfer__c draft = transfer('Draft');

        Test.startTest();
        Integer rejected = 0;
        try {
            StockOperationsHubController.confirmReceipt(null, '[]');
        } catch (AuraHandledException e) { rejected++; }
        try {
            StockOperationsHubController.confirmReceipt(draft.Id, '[]');
        } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(2, rejected,
            'Stock cannot be received against a draft — the approval has not happened yet');
        System.assertEquals('Draft', [
            SELECT Status__c FROM Stock_Transfer__c WHERE Id = :draft.Id
        ].Status__c, 'And the transfer is untouched');
    }

    @isTest
    static void confirmReceipt_movesStockBetweenWarehousesAndClosesTheTransfer() {
        seedSourceStock();
        insert stock(dest(), alpha(), 'B-ALPHA', 40, 10);
        Stock_Transfer__c t = transfer('Approved');
        Stock_Transfer_Line__c li = line(t.Id, alpha(), 'B-ALPHA', 30, 30);
        insert li;

        String receivedJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'lineItemId' => li.Id, 'receivedQty' => 30 }
        });

        Test.startTest();
        StockOperationsHubController.confirmReceipt(t.Id, receivedJson);
        Test.stopTest();

        System.assertEquals('Received', [
            SELECT Status__c FROM Stock_Transfer__c WHERE Id = :t.Id
        ].Status__c, 'The transfer closes');
        System.assertEquals(30, [
            SELECT Received_Qty__c FROM Stock_Transfer_Line__c WHERE Id = :li.Id
        ].Received_Qty__c, 'The received quantity is stamped on the line');
        System.assertEquals(70, onHandFor(src(), alpha(), 'B-ALPHA'),
            'Source drops by the approved quantity: 100 - 30');
        System.assertEquals(70, onHandFor(dest(), alpha(), 'B-ALPHA'),
            'Destination rises by the received quantity: 40 + 30');
    }

    @isTest
    static void confirmReceipt_logsBothLegsAsStockTransactions() {
        seedSourceStock();
        Stock_Transfer__c t = transfer('Approved');
        Stock_Transfer_Line__c li = line(t.Id, alpha(), 'B-ALPHA', 30, 30);
        insert li;

        Test.startTest();
        StockOperationsHubController.confirmReceipt(t.Id, JSON.serialize(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'lineItemId' => li.Id, 'receivedQty' => 30 }
            }));
        Test.stopTest();

        List<Stock_Transaction__c> txns = [
            SELECT Transaction_Type__c, Direction__c, Quantity__c, Warehouse__c, Reference_Type__c
            FROM Stock_Transaction__c WHERE Reference_Id__c = :String.valueOf(t.Id)
            ORDER BY Transaction_Type__c
        ];
        System.assertEquals(2, txns.size(), 'One audit row per leg');
        System.assertEquals('Transfer_In', txns[0].Transaction_Type__c, 'The inbound leg');
        System.assertEquals('In', txns[0].Direction__c, 'Directioned in');
        System.assertEquals(dest(), txns[0].Warehouse__c, 'At the destination');
        System.assertEquals('Transfer_Out', txns[1].Transaction_Type__c, 'The outbound leg');
        System.assertEquals('Out', txns[1].Direction__c, 'Directioned out');
        System.assertEquals(src(), txns[1].Warehouse__c, 'At the source');
        System.assertEquals('Stock_Transfer', txns[1].Reference_Type__c, 'Traceable to the transfer');
    }

    @isTest
    static void confirmReceipt_createsDestinationStockWhenItIsANewProductThere() {
        seedSourceStock();   // destination holds nothing at all
        Stock_Transfer__c t = transfer('Approved');
        Stock_Transfer_Line__c li = line(t.Id, alpha(), 'B-ALPHA', 25, 25);
        insert li;

        Test.startTest();
        StockOperationsHubController.confirmReceipt(t.Id, JSON.serialize(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'lineItemId' => li.Id, 'receivedQty' => 25 }
            }));
        Test.stopTest();

        System.assertEquals(25, onHandFor(dest(), alpha(), 'B-ALPHA'),
            'The first shipment of a product to a warehouse creates its stock row rather than '
            + 'silently dropping the receipt');
        System.assertEquals(75, onHandFor(src(), alpha(), 'B-ALPHA'), 'Source still deducted');
    }

    @isTest
    static void confirmReceipt_neverDrivesSourceStockNegative() {
        seedSourceStock();
        Stock_Transfer__c t = transfer('Approved');
        // Approved for more than the source actually holds (100).
        Stock_Transfer_Line__c li = line(t.Id, alpha(), 'B-ALPHA', 250, 250);
        insert li;

        Test.startTest();
        StockOperationsHubController.confirmReceipt(t.Id, JSON.serialize(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'lineItemId' => li.Id, 'receivedQty' => 250 }
            }));
        Test.stopTest();

        System.assertEquals(0, onHandFor(src(), alpha(), 'B-ALPHA'),
            'Deducting more than is held floors at zero — negative on-hand would fail the '
            + 'Quantities_Non_Negative rule and block the whole receipt');
    }

    @isTest
    static void confirmReceipt_runTwice_doesNotMoveStockAgain() {
        seedSourceStock();
        insert stock(dest(), alpha(), 'B-ALPHA', 40, 10);
        Stock_Transfer__c t = transfer('Approved');
        Stock_Transfer_Line__c li = line(t.Id, alpha(), 'B-ALPHA', 30, 30);
        insert li;
        String receivedJson = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'lineItemId' => li.Id, 'receivedQty' => 30 }
        });

        StockOperationsHubController.confirmReceipt(t.Id, receivedJson);

        Test.startTest();
        // A double-click, a retry, or the legacy trigger firing from another
        // context must not move the stock a second time.
        try {
            StockOperationsHubController.confirmReceipt(t.Id, receivedJson);
        } catch (AuraHandledException e) {
            // The status guard may reject the second call outright, which is
            // equally acceptable — what matters is the stock not moving twice.
        }
        Test.stopTest();

        System.assertEquals(70, onHandFor(src(), alpha(), 'B-ALPHA'),
            'Source deducted once only — the already-logged check is the only guard against '
            + 'double-counting inventory');
        System.assertEquals(70, onHandFor(dest(), alpha(), 'B-ALPHA'), 'Destination added once only');
        System.assertEquals(2, [
            SELECT COUNT() FROM Stock_Transaction__c WHERE Reference_Id__c = :String.valueOf(t.Id)
        ], 'And still just the two audit rows');
    }

    @isTest
    static void confirmReceipt_fromInTransitSkipsTheIntermediateStep() {
        seedSourceStock();
        Stock_Transfer__c t = transfer('In_Transit');
        Stock_Transfer_Line__c li = line(t.Id, alpha(), 'B-ALPHA', 20, 20);
        insert li;

        Test.startTest();
        StockOperationsHubController.confirmReceipt(t.Id, JSON.serialize(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'lineItemId' => li.Id, 'receivedQty' => 20 }
            }));
        Test.stopTest();

        System.assertEquals('Received', [
            SELECT Status__c FROM Stock_Transfer__c WHERE Id = :t.Id
        ].Status__c, 'A transfer already in transit goes straight to Received');
        System.assertEquals(80, onHandFor(src(), alpha(), 'B-ALPHA'), 'And still moves the stock');
    }

    @isTest
    static void confirmReceipt_usesTheEnteredQuantityWhenItIsShortOfApproved() {
        seedSourceStock();
        Stock_Transfer__c t = transfer('Approved');
        Stock_Transfer_Line__c li = line(t.Id, alpha(), 'B-ALPHA', 30, 30);
        insert li;

        Test.startTest();
        // Only 18 of the 30 actually arrived.
        StockOperationsHubController.confirmReceipt(t.Id, JSON.serialize(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'lineItemId' => li.Id, 'receivedQty' => 18 }
            }));
        Test.stopTest();

        System.assertEquals(70, onHandFor(src(), alpha(), 'B-ALPHA'),
            'Source is deducted by what was APPROVED and shipped: 100 - 30');
        System.assertEquals(18, onHandFor(dest(), alpha(), 'B-ALPHA'),
            'Destination gains only what actually arrived, leaving the 12-unit shortfall '
            + 'visible as the difference between the two legs');
    }

    @isTest
    static void confirmReceipt_withNoLines_movesNothing() {
        seedSourceStock();
        Stock_Transfer__c t = transfer('Approved');

        Test.startTest();
        StockOperationsHubController.confirmReceipt(t.Id, '[]');
        Test.stopTest();

        System.assertEquals('Received', [
            SELECT Status__c FROM Stock_Transfer__c WHERE Id = :t.Id
        ].Status__c, 'An empty transfer still closes');
        System.assertEquals(100, onHandFor(src(), alpha(), 'B-ALPHA'), 'With no stock moved');
        System.assertEquals(0, [
            SELECT COUNT() FROM Stock_Transaction__c WHERE Reference_Id__c = :String.valueOf(t.Id)
        ], 'And nothing logged');
    }
}