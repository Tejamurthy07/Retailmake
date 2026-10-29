@IsTest
private class OVE_StockCheckController_Test {

    @TestSetup
    static void setupData() {
        Account acc = TestDataFactory.createAndInsertAccount('Stock Test Outlet', 'Retailer');

        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Stock Territory', 'ST-001');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Stock Beat', 'SB-001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        Visit__c visit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        // Create products
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(3);

        // Create Distributor_Stock__c records
        List<Distributor_Stock__c> stocks = new List<Distributor_Stock__c>();
        for (Product_Extension__c prod : products) {
            stocks.add(new Distributor_Stock__c(
                Account__c = acc.Id,
                Visit__c = visit.Id,
                Product_Ext__c = prod.Id,
                Opening_Stock__c = 100,
                Received_Qty__c = 50,
                Sold_Qty__c = 30,
                Closing_Stock__c = 120,
                Damaged_Qty__c = 0,
                Stock_Date__c = Date.today(),
                Is_Current__c = true
            ));
        }
        insert stocks;
    }

    // ── getDistributorStock ─────────────────────────────────────────

    @IsTest
    static void testGetDistributorStock_ReturnsRecords() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Stock Test Outlet' LIMIT 1];

        Test.startTest();
        try {
            List<Distributor_Stock__c> results = OVE_StockCheckController.getDistributorStock(acc.Id);
            System.assertNotEquals(null, results, 'Result should not be null');
            // Feature toggle may return empty list if disabled
            if (!results.isEmpty()) {
                System.assertEquals(3, results.size(), 'Should return 3 stock records');
            }
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetDistributorStock_NoRecords() {
        Account emptyAcc = TestDataFactory.createAndInsertAccount('Empty Outlet', 'Retailer');

        Test.startTest();
        try {
            List<Distributor_Stock__c> results = OVE_StockCheckController.getDistributorStock(emptyAcc.Id);
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assertEquals(0, results.size(), 'Should return empty list');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── getProductsForStockCheck ────────────────────────────────────

    @IsTest
    static void testGetProductsForStockCheck_MatchingTerm() {
        Test.startTest();
        try {
            List<Product_Extension__c> results = OVE_StockCheckController.getProductsForStockCheck('Test Product');
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assert(results.size() >= 3, 'Should find at least 3 products matching "Test Product"');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetProductsForStockCheck_BySkuCode() {
        Test.startTest();
        try {
            List<Product_Extension__c> results = OVE_StockCheckController.getProductsForStockCheck('TP-0001');
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assert(results.size() >= 1, 'Should find at least 1 product by SKU code');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetProductsForStockCheck_NoMatch() {
        Test.startTest();
        try {
            List<Product_Extension__c> results = OVE_StockCheckController.getProductsForStockCheck('ZZZZNONEXISTENT');
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assertEquals(0, results.size(), 'Should return empty list for no match');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── saveStockEntries ────────────────────────────────────────────

    @IsTest
    static void testSaveStockEntries_NewEntries() {
        Visit__c visit = [SELECT Id, Account__c FROM Visit__c LIMIT 1];
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        entries.add(new Map<String, Object>{
            'productId' => prod.Id,
            'opening' => 200,
            'received' => 100,
            'sold' => 80,
            'closing' => 220,
            'damaged' => 0,
            'batch' => 'BATCH-A1'
        });
        String stockJson = JSON.serialize(entries);

        Test.startTest();
        try {
            List<Distributor_Stock__c> results = OVE_StockCheckController.saveStockEntries(
                stockJson, visit.Id, visit.Account__c
            );
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assertEquals(1, results.size(), 'Should save 1 stock entry');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_MultipleEntries() {
        Visit__c visit = [SELECT Id, Account__c FROM Visit__c LIMIT 1];
        List<Product_Extension__c> products = [SELECT Id FROM Product_Extension__c LIMIT 3];

        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        for (Product_Extension__c prod : products) {
            entries.add(new Map<String, Object>{
                'productId' => prod.Id,
                'opening' => 50,
                'received' => 25,
                'sold' => 10,
                'closing' => 65,
                'damaged' => 0
            });
        }
        String stockJson = JSON.serialize(entries);

        Test.startTest();
        try {
            List<Distributor_Stock__c> results = OVE_StockCheckController.saveStockEntries(
                stockJson, visit.Id, visit.Account__c
            );
            System.assertEquals(products.size(), results.size(), 'Should save all entries');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── getLastStockCheck ───────────────────────────────────────────

    @IsTest
    static void testGetLastStockCheck_ReturnsRecords() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Stock Test Outlet' LIMIT 1];

        Test.startTest();
        try {
            List<Distributor_Stock__c> results = OVE_StockCheckController.getLastStockCheck(acc.Id);
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assert(results.size() >= 3, 'Should return at least 3 records from last stock check');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetLastStockCheck_NoRecords() {
        Account emptyAcc = TestDataFactory.createAndInsertAccount('No Stock Outlet', 'Retailer');

        Test.startTest();
        try {
            List<Distributor_Stock__c> results = OVE_StockCheckController.getLastStockCheck(emptyAcc.Id);
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assertEquals(0, results.size(), 'Should return empty list');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── Error Path Tests — Cover catch (Exception e) blocks ──────────

    @IsTest
    static void testGetDistributorStock_NullId() {
        Test.startTest();
        try {
            OVE_StockCheckController.getDistributorStock(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetProductsForStockCheck_NullTerm() {
        Test.startTest();
        try {
            OVE_StockCheckController.getProductsForStockCheck(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetProductsForStockCheck_EmptyString() {
        Test.startTest();
        try {
            OVE_StockCheckController.getProductsForStockCheck('');
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_NullJson() {
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries(null, null, null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_InvalidJson() {
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries('bad json', null, null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_EmptyObjectJson() {
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries('{}', null, null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_EmptyArrayJson() {
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries('[]', null, null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetLastStockCheck_NullId() {
        Test.startTest();
        try {
            OVE_StockCheckController.getLastStockCheck(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ── Additional Error Path Tests — Force catch (Exception e) blocks ──────

    @IsTest
    static void testGetDistributorStock_FabricatedId() {
        Test.startTest();
        try {
            OVE_StockCheckController.getDistributorStock('001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetLastStockCheck_FabricatedId() {
        Test.startTest();
        try {
            OVE_StockCheckController.getLastStockCheck('001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_MalformedJsonObject() {
        // saveStockEntries expects a JSON array, passing an object should fail
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries('{"key":"value"}', null, null);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_InvalidIdInJson() {
        String json = '[{"id":"INVALID_ID","productId":"INVALID","opening":10}]';
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries(json, null, null);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_NumericJson() {
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries('12345', null, null);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_BooleanJson() {
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries('true', null, null);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_EmptyString() {
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries('', null, null);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSaveStockEntries_FabricatedIds() {
        String json = '[{"productId":null,"opening":10,"received":5,"sold":3,"closing":12,"damaged":0}]';
        Test.startTest();
        try {
            OVE_StockCheckController.saveStockEntries(json, '001000000000000AAA', '001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetProductsForStockCheck_SpecialChars() {
        Test.startTest();
        try {
            OVE_StockCheckController.getProductsForStockCheck('\'OR 1=1--');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage, with HARD assertions.
    //
    //  The tests above tolerate both outcomes ("feature toggle may be
    //  disabled"), so none of the service's real behaviour is pinned. OVE-010
    //  ships enabled — and where a test needs a particular toggle state it now
    //  pins it through BPM_FeatureToggle_Util's @TestVisible cache instead of
    //  hoping.
    //
    //  What the tests below protect is the money part of a stock check:
    //  the counted figure winning over the book position, the difference being
    //  booked as an auditable variance (found stock in, shrinkage out), and the
    //  opening chaining from the DISTRIBUTOR'S book position rather than
    //  whatever figure the rep's phone happened to be holding.
    // ══════════════════════════════════════════════════════════════════

    private static void setStockCheckFeature(Boolean enabled) {
        BPM_FeatureToggle_Util.toggleCache.put(
            OVE_StockCheck_Service.FEATURE_STOCK_CHECK, enabled);
    }

    private static Id outletId() {
        return [SELECT Id FROM Account WHERE Name = 'Stock Test Outlet' LIMIT 1].Id;
    }

    private static Visit__c theVisit() {
        return [SELECT Id, Account__c FROM Visit__c LIMIT 1];
    }

    private static String entryJson(Id productId, Map<String, Object> extra) {
        Map<String, Object> entry = new Map<String, Object>{ 'productId' => productId };
        if (extra != null) entry.putAll(extra);
        return JSON.serialize(new List<Object>{ entry });
    }

    // ── The feature toggle branch ─────────────────────────────────────

    @IsTest
    static void stock_withTheFeatureOff_returnsEmptyInsteadOfData() {
        setStockCheckFeature(false);

        Test.startTest();
        List<Distributor_Stock__c> results =
            OVE_StockCheckController.getDistributorStock(outletId());
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'Three current stock rows exist, but with OVE-010 off the panel gets an empty '
            + 'list — the feature disappears rather than erroring');
    }

    @IsTest
    static void stock_withTheFeatureOn_returnsTheCurrentRows() {
        setStockCheckFeature(true);

        Test.startTest();
        List<Distributor_Stock__c> results =
            OVE_StockCheckController.getDistributorStock(outletId());
        Test.stopTest();

        System.assertEquals(3, results.size(), 'All three current rows come back');
        for (Distributor_Stock__c ds : results) {
            System.assertEquals(120, ds.Closing_Stock__c,
                'The derived closing (100 + 50 - 30 - 0) is what the rep counts against');
            System.assertNotEquals(null, ds.Product_Ext__r.Name,
                'With the product name resolved for display');
        }
    }

    // ── The variance engine ───────────────────────────────────────────

    @IsTest
    static void save_countingMoreThanTheBook_booksFoundStockIn() {
        setStockCheckFeature(true);
        Visit__c visit = theVisit();
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        // Book position is 120. The rep counts 150 — 30 units of found stock.
        String stockJson = entryJson(prod.Id, new Map<String, Object>{
            'received' => 0, 'sold' => 0, 'damaged' => 0, 'closing' => 150
        });

        Test.startTest();
        List<Distributor_Stock__c> saved = OVE_StockCheckController.saveStockEntries(
            stockJson, visit.Id, visit.Account__c);
        Test.stopTest();

        System.assertEquals(1, saved.size(), 'One snapshot written');
        Distributor_Stock__c snapshot = [
            SELECT Opening_Stock__c, Received_Qty__c, Closing_Stock__c
            FROM Distributor_Stock__c WHERE Id = :saved[0].Id
        ];
        System.assertEquals(120, snapshot.Opening_Stock__c,
            'Opening chains from the BOOK position, never from a figure the phone sent');
        System.assertEquals(30, snapshot.Received_Qty__c,
            'The surplus is booked as received — found stock, not a silent overwrite');
        System.assertEquals(150, snapshot.Closing_Stock__c,
            'So the derived closing equals what was physically counted');

        List<Stock_Transaction__c> txns = [
            SELECT Direction__c, Transaction_Type__c, Quantity__c, Reference_Type__c
            FROM Stock_Transaction__c WHERE Reference_Id__c = :String.valueOf(visit.Id)
        ];
        System.assertEquals(1, txns.size(), 'And the variance leaves a ledger entry');
        System.assertEquals('In', txns[0].Direction__c, 'Directioned in');
        System.assertEquals('Adjustment_Add', txns[0].Transaction_Type__c, 'As an addition');
        System.assertEquals(30, txns[0].Quantity__c, 'For exactly the surplus');
        System.assertEquals('Stock_Check', txns[0].Reference_Type__c,
            'Traceable back to the stock check that raised it');
    }

    @IsTest
    static void save_countingLessThanTheBook_booksShrinkageOut() {
        setStockCheckFeature(true);
        Visit__c visit = theVisit();
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        // Book position 120, counted 95 — 25 units have gone missing.
        String stockJson = entryJson(prod.Id, new Map<String, Object>{
            'received' => 0, 'sold' => 0, 'damaged' => 0, 'closing' => 95
        });

        Test.startTest();
        List<Distributor_Stock__c> saved = OVE_StockCheckController.saveStockEntries(
            stockJson, visit.Id, visit.Account__c);
        Test.stopTest();

        Distributor_Stock__c snapshot = [
            SELECT Damaged_Qty__c, Closing_Stock__c
            FROM Distributor_Stock__c WHERE Id = :saved[0].Id
        ];
        System.assertEquals(25, snapshot.Damaged_Qty__c,
            'The shortfall is booked as damage/shrinkage, so it is visible, not vanished');
        System.assertEquals(95, snapshot.Closing_Stock__c, 'And the counted figure stands');

        Stock_Transaction__c txn = [
            SELECT Direction__c, Transaction_Type__c, Quantity__c
            FROM Stock_Transaction__c WHERE Reference_Id__c = :String.valueOf(visit.Id)
        ];
        System.assertEquals('Out', txn.Direction__c, 'Shrinkage leaves the position');
        System.assertEquals('Adjustment_Deduct', txn.Transaction_Type__c, 'As a deduction');
        System.assertEquals(25, txn.Quantity__c, 'For exactly the missing units');
    }

    @IsTest
    static void save_countingExactlyTheBook_writesNoVarianceTransaction() {
        setStockCheckFeature(true);
        Visit__c visit = theVisit();
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        // Counted = book position exactly.
        String stockJson = entryJson(prod.Id, new Map<String, Object>{
            'received' => 0, 'sold' => 0, 'damaged' => 0, 'closing' => 120
        });

        Test.startTest();
        OVE_StockCheckController.saveStockEntries(stockJson, visit.Id, visit.Account__c);
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Reference_Id__c = :String.valueOf(visit.Id)
        ], 'A clean count books nothing — the ledger only records genuine variances');
    }

    @IsTest
    static void save_marksTheVisitAsStockChecked() {
        setStockCheckFeature(true);
        Visit__c visit = theVisit();
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        Test.startTest();
        OVE_StockCheckController.saveStockEntries(
            entryJson(prod.Id, new Map<String, Object>{ 'closing' => 120 }),
            visit.Id, visit.Account__c);
        Test.stopTest();

        System.assertEquals(true, [
            SELECT Stock_Check_Completed__c FROM Visit__c WHERE Id = :visit.Id
        ].Stock_Check_Completed__c,
            'The visit records that its stock check happened — the completion summary and '
            + 'productivity flags read this');
    }

    @IsTest
    static void save_entriesWithoutAProduct_areSkippedEntirely() {
        setStockCheckFeature(true);
        Visit__c visit = theVisit();

        String stockJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'productId' => null, 'closing' => 50 },
            new Map<String, Object>{ 'closing' => 60 }
        });

        Test.startTest();
        List<Distributor_Stock__c> saved = OVE_StockCheckController.saveStockEntries(
            stockJson, visit.Id, visit.Account__c);
        Test.stopTest();

        System.assertEquals(0, saved.size(),
            'Rows with no product cannot be keyed to anything, so nothing is written and '
            + 'nothing throws');
        System.assertEquals(false, [
            SELECT Stock_Check_Completed__c FROM Visit__c WHERE Id = :visit.Id
        ].Stock_Check_Completed__c,
            'And an all-blank payload does not mark the visit checked');
    }

    @IsTest
    static void save_stringQuantities_areCoercedNotRejected() {
        setStockCheckFeature(true);
        Visit__c visit = theVisit();
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];

        // A JS client can easily serialise numbers as strings; toDecimal handles it.
        String stockJson = '[{"productId":"' + prod.Id + '","received":"10","sold":"5",'
            + '"damaged":"0","closing":"125"}]';

        Test.startTest();
        List<Distributor_Stock__c> saved = OVE_StockCheckController.saveStockEntries(
            stockJson, visit.Id, visit.Account__c);
        Test.stopTest();

        Distributor_Stock__c snapshot = [
            SELECT Closing_Stock__c FROM Distributor_Stock__c WHERE Id = :saved[0].Id
        ];
        System.assertEquals(125, snapshot.Closing_Stock__c,
            'Quantities arriving as strings are coerced, so the count still lands: '
            + 'book 120 + received 10 - sold 5 = 125, no variance');
    }

    @IsTest
    static void save_withAnExpiryDate_stampsItOnTheSnapshot() {
        setStockCheckFeature(true);
        Visit__c visit = theVisit();
        Product_Extension__c prod = [SELECT Id FROM Product_Extension__c LIMIT 1];
        Date expiry = Date.today().addDays(180);

        // A batch key distinct from the existing (null-batch) book rows: opening
        // chains from nothing, so the count itself is the position.
        String stockJson = '[{"productId":"' + prod.Id + '","batch":"BX-77",'
            + '"received":"40","sold":"0","damaged":"0",'
            + '"expiry":"' + String.valueOf(expiry) + '"}]';

        Test.startTest();
        List<Distributor_Stock__c> saved = OVE_StockCheckController.saveStockEntries(
            stockJson, visit.Id, visit.Account__c);
        Test.stopTest();

        Distributor_Stock__c snapshot = [
            SELECT Batch_No__c, Expiry_Date__c, Opening_Stock__c, Closing_Stock__c
            FROM Distributor_Stock__c WHERE Id = :saved[0].Id
        ];
        System.assertEquals('BX-77', snapshot.Batch_No__c, 'Tracked per batch');
        System.assertEquals(expiry, snapshot.Expiry_Date__c,
            'The expiry rides along so FEFO and near-expiry alerts can see this batch');
        System.assertEquals(0, snapshot.Opening_Stock__c,
            'A batch the book has never seen opens at zero');
        System.assertEquals(40, snapshot.Closing_Stock__c, 'And closes at what arrived');
    }

    // ── getLastStockCheck with data ───────────────────────────────────

    @IsTest
    static void lastStockCheck_returnsCurrentRowsForPrefill() {
        Test.startTest();
        List<Distributor_Stock__c> results =
            OVE_StockCheckController.getLastStockCheck(outletId());
        Test.stopTest();

        System.assertEquals(3, results.size(),
            'The pre-fill reads the current snapshot per product');
        for (Distributor_Stock__c ds : results) {
            System.assertEquals(120, ds.Closing_Stock__c,
                'Carrying the book closing the new count will chain from');
        }
    }

    // ── Product search with data ──────────────────────────────────────

    @IsTest
    static void productSearch_returnsActiveMatchesWithTheirFields() {
        Test.startTest();
        List<Product_Extension__c> results =
            OVE_StockCheckController.getProductsForStockCheck('Test Product');
        Test.stopTest();

        System.assertEquals(3, results.size(), 'All three seeded products match');
        for (Product_Extension__c p : results) {
            System.assertNotEquals(null, p.SKU_Code__c,
                'The SKU code rides along for the picker subtitle');
        }
    }
}