/**
 * @description Tests for DMS_DistributorInventory_Service — the read layer over
 * Distributor_Stock__c that the replenishment engine and FEFO billing rely on.
 *
 * The behaviour worth pinning down is the aggregation itself: a distributor
 * holds one Distributor_Stock__c snapshot per batch, so "how much of product X
 * does distributor Y have" is a sum across rows, not a lookup. Getting that
 * wrong under-reports stock and triggers replenishment for goods already on the
 * shelf. The filters matter for the same reason — a superseded snapshot
 * (Is_Current__c = false) counted alongside the live one doubles the number.
 */
@isTest
private class DMS_DistributorInventory_Service_Test {

    @testSetup
    static void setupTestData() {
        List<Account> distributors = new List<Account>{
            TestDataFactory.createAccount('INV Distributor A', 'Distributor'),
            TestDataFactory.createAccount('INV Distributor B', 'Distributor')
        };
        insert distributors;

        insert new List<Product_Extension__c>{
            TestDataFactory.createProduct('INV Product 1', 'INV-P1'),
            TestDataFactory.createProduct('INV Product 2', 'INV-P2')
        };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> accountsByName() {
        Map<String, Id> byName = new Map<String, Id>();
        for (Account a : [SELECT Id, Name FROM Account WHERE Name LIKE 'INV Distributor%']) {
            byName.put(a.Name, a.Id);
        }
        return byName;
    }

    private static Map<String, Id> productsByCode() {
        Map<String, Id> byCode = new Map<String, Id>();
        for (Product_Extension__c p : [
            SELECT Id, SKU_Code__c FROM Product_Extension__c WHERE SKU_Code__c LIKE 'INV-P%'
        ]) {
            byCode.put(p.SKU_Code__c, p.Id);
        }
        return byCode;
    }

    /**
     * Closing_Stock__c cannot be set directly: INV_DistributorStock_TriggerHandler
     * recomputes it on before insert as Opening + Received - Sold - Damaged, so an
     * assigned value is overwritten with 0. The quantity therefore goes in through
     * Opening_Stock__c and the trigger derives the closing balance from it.
     */
    private static Distributor_Stock__c snapshot(
            Id accountId, Id productId, String batchNo, Decimal qty, Date expiry, Boolean isCurrent) {
        return new Distributor_Stock__c(
            Account__c = accountId,
            Product_Ext__c = productId,
            Batch_No__c = batchNo,
            Opening_Stock__c = qty,
            Received_Qty__c = 0,
            Sold_Qty__c = 0,
            Damaged_Qty__c = 0,
            Expiry_Date__c = expiry,
            Is_Current__c = isCurrent,
            Stock_Date__c = Date.today()
        );
    }

    // ── getCurrentOnHand ──────────────────────────────────────────────

    @isTest
    static void onHand_withNoAccounts_returnsEmptyMap() {
        Test.startTest();
        Map<String, Decimal> fromNull = DMS_DistributorInventory_Service.getCurrentOnHand(null, null);
        Map<String, Decimal> fromEmpty =
            DMS_DistributorInventory_Service.getCurrentOnHand(new Set<Id>(), null);
        Test.stopTest();

        System.assertEquals(0, fromNull.size(), 'A null account set queries nothing');
        System.assertEquals(0, fromEmpty.size(), 'An empty account set queries nothing');
    }

    @isTest
    static void onHand_sumsEveryBatchOfTheSameProduct() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');
        insert new List<Distributor_Stock__c>{
            snapshot(acc, prod, 'B-001', 40, Date.today().addDays(200), true),
            snapshot(acc, prod, 'B-002', 35, Date.today().addDays(300), true),
            snapshot(acc, prod, 'B-003', 25, Date.today().addDays(400), true)
        };

        Test.startTest();
        Map<String, Decimal> onHand = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ acc }, null);
        Test.stopTest();

        String key = DMS_DistributorInventory_Service.key(acc, prod);
        System.assertEquals(1, onHand.size(), 'Three batches of one product collapse to one entry');
        System.assertEquals(100, onHand.get(key),
            'On-hand is the sum across batches — reading a single row would under-report it');
    }

    @isTest
    static void onHand_ignoresSupersededSnapshots() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');
        insert new List<Distributor_Stock__c>{
            snapshot(acc, prod, 'B-001', 60, Date.today().addDays(200), true),
            snapshot(acc, prod, 'B-001', 999, Date.today().addDays(200), false)
        };

        Test.startTest();
        Map<String, Decimal> onHand = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ acc }, null);
        Test.stopTest();

        System.assertEquals(60,
            onHand.get(DMS_DistributorInventory_Service.key(acc, prod)),
            'Yesterday snapshot must not be added to today — that would double the stock');
    }

    @isTest
    static void onHand_keepsDistributorsAndProductsSeparate() {
        Map<String, Id> accs = accountsByName();
        Map<String, Id> prods = productsByCode();
        Id accA = accs.get('INV Distributor A');
        Id accB = accs.get('INV Distributor B');
        Id p1 = prods.get('INV-P1');
        Id p2 = prods.get('INV-P2');

        insert new List<Distributor_Stock__c>{
            snapshot(accA, p1, 'B-1', 10, null, true),
            snapshot(accA, p2, 'B-2', 20, null, true),
            snapshot(accB, p1, 'B-3', 30, null, true)
        };

        Test.startTest();
        Map<String, Decimal> onHand = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ accA, accB }, null);
        Test.stopTest();

        System.assertEquals(3, onHand.size(), 'Three distinct distributor+product pairs');
        System.assertEquals(10, onHand.get(DMS_DistributorInventory_Service.key(accA, p1)),
            'Distributor A product 1');
        System.assertEquals(20, onHand.get(DMS_DistributorInventory_Service.key(accA, p2)),
            'Distributor A product 2');
        System.assertEquals(30, onHand.get(DMS_DistributorInventory_Service.key(accB, p1)),
            'Distributor B holds its own stock of the same product');
    }

    @isTest
    static void onHand_appliesTheProductFilterWhenGiven() {
        Id acc = accountsByName().get('INV Distributor A');
        Map<String, Id> prods = productsByCode();
        Id p1 = prods.get('INV-P1');
        Id p2 = prods.get('INV-P2');

        insert new List<Distributor_Stock__c>{
            snapshot(acc, p1, 'B-1', 15, null, true),
            snapshot(acc, p2, 'B-2', 25, null, true)
        };

        Test.startTest();
        Map<String, Decimal> filtered = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ acc }, new Set<Id>{ p1 });
        Map<String, Decimal> unfiltered = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ acc }, new Set<Id>());
        Test.stopTest();

        System.assertEquals(1, filtered.size(), 'Only the requested product comes back');
        System.assertEquals(15, filtered.get(DMS_DistributorInventory_Service.key(acc, p1)),
            'And with its own quantity');
        System.assertEquals(2, unfiltered.size(),
            'An empty product set means "all products", not "no products"');
    }

    @isTest
    static void onHand_treatsAnEmptyBatchAsZero() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');
        insert new List<Distributor_Stock__c>{
            snapshot(acc, prod, 'B-1', null, null, true),
            snapshot(acc, prod, 'B-2', 12, null, true)
        };

        Test.startTest();
        Map<String, Decimal> onHand = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ acc }, null);
        Test.stopTest();

        System.assertEquals(12, onHand.get(DMS_DistributorInventory_Service.key(acc, prod)),
            'A batch with no quantities contributes nothing rather than breaking the sum');
    }

    @isTest
    static void onHand_omitsRowsWithNoProduct() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');
        insert new List<Distributor_Stock__c>{
            snapshot(acc, null, 'B-ORPHAN', 500, null, true),
            snapshot(acc, prod, 'B-1', 10, null, true)
        };

        Test.startTest();
        Map<String, Decimal> onHand = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ acc }, null);
        Test.stopTest();

        System.assertEquals(1, onHand.size(),
            'A snapshot with no product cannot be keyed and is left out');
        System.assertEquals(10, onHand.get(DMS_DistributorInventory_Service.key(acc, prod)),
            'The real row is unaffected');
    }

    @isTest
    static void onHand_withStockOnlyAtOtherDistributorsReturnsNothing() {
        Map<String, Id> accs = accountsByName();
        insert snapshot(accs.get('INV Distributor B'), productsByCode().get('INV-P1'),
            'B-1', 50, null, true);

        Test.startTest();
        Map<String, Decimal> onHand = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ accs.get('INV Distributor A') }, null);
        Test.stopTest();

        System.assertEquals(0, onHand.size(), 'One distributor cannot see another stock');
    }

    // ── getNearExpiry ─────────────────────────────────────────────────

    @isTest
    static void nearExpiry_returnsOnlyStockInsideTheWindow() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');
        insert new List<Distributor_Stock__c>{
            snapshot(acc, prod, 'SOON', 10, Date.today().addDays(15), true),
            snapshot(acc, prod, 'EDGE', 10, Date.today().addDays(30), true),
            snapshot(acc, prod, 'LATER', 10, Date.today().addDays(90), true)
        };

        Test.startTest();
        List<Distributor_Stock__c> nearExpiry = DMS_DistributorInventory_Service.getNearExpiry(30);
        Test.stopTest();

        System.assertEquals(2, nearExpiry.size(), 'Only the two inside the 30-day window');
        System.assertEquals('SOON', nearExpiry[0].Batch_No__c,
            'FEFO order — the batch expiring first is listed first so it is sold first');
        System.assertEquals('EDGE', nearExpiry[1].Batch_No__c,
            'The window boundary is inclusive');
    }

    /**
     * The service filters Expiry_Date__c <= cutoff, which reads as though it
     * surfaces stock that has already expired. It cannot: the Expiry_Date_Future
     * validation rule forbids a current row with a past expiry date, and once a
     * row is marked non-current the Is_Current__c = true filter drops it. So
     * expired stock is invisible to getNearExpiry by construction — it has to be
     * caught before the date passes.
     */
    @isTest
    static void nearExpiry_cannotHoldCurrentStockWithAPastExpiryDate() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');

        Test.startTest();
        Boolean blocked = false;
        try {
            insert snapshot(acc, prod, 'EXPIRED', 10, Date.today().addDays(-5), true);
        } catch (DmlException e) {
            blocked = true;
            System.assert(e.getMessage().contains('past expiry date'),
                'Expected the expiry validation rule, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(blocked,
            'Current stock cannot be back-dated, so getNearExpiry never sees expired rows');
    }

    @isTest
    static void nearExpiry_skipsEmptyAndUndatedBatches() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');
        // A negative balance is not represented here: Quantities_Non_Negative and
        // Sold_Qty_Not_Exceed_Available together make Closing_Stock__c < 0
        // unreachable through DML, so the service's `> 0` filter only ever has to
        // exclude zero.
        insert new List<Distributor_Stock__c>{
            snapshot(acc, prod, 'SOLD OUT', 0, Date.today().addDays(5), true),
            snapshot(acc, prod, 'NO DATE', 10, null, true),
            snapshot(acc, prod, 'SUPERSEDED', 10, Date.today().addDays(5), false),
            snapshot(acc, prod, 'REAL', 10, Date.today().addDays(5), true)
        };

        Test.startTest();
        List<Distributor_Stock__c> nearExpiry = DMS_DistributorInventory_Service.getNearExpiry(30);
        Test.stopTest();

        System.assertEquals(1, nearExpiry.size(),
            'Only a current, dated batch that still holds stock is actionable');
        System.assertEquals('REAL', nearExpiry[0].Batch_No__c, 'And it is the right one');
    }

    @isTest
    static void nearExpiry_withNullWindowUsesToday() {
        Id acc = accountsByName().get('INV Distributor A');
        Id prod = productsByCode().get('INV-P1');
        insert new List<Distributor_Stock__c>{
            snapshot(acc, prod, 'TODAY', 10, Date.today(), true),
            snapshot(acc, prod, 'TOMORROW', 10, Date.today().addDays(1), true)
        };

        Test.startTest();
        List<Distributor_Stock__c> nearExpiry = DMS_DistributorInventory_Service.getNearExpiry(null);
        Test.stopTest();

        System.assertEquals(1, nearExpiry.size(),
            'A null window falls back to today, so only stock expiring today qualifies');
        System.assertEquals('TODAY', nearExpiry[0].Batch_No__c, 'Expiring today is inclusive');
    }

    @isTest
    static void nearExpiry_withNothingNearExpiryReturnsEmpty() {
        Id acc = accountsByName().get('INV Distributor A');
        insert snapshot(acc, productsByCode().get('INV-P1'), 'FRESH', 10,
            Date.today().addDays(365), true);

        Test.startTest();
        List<Distributor_Stock__c> nearExpiry = DMS_DistributorInventory_Service.getNearExpiry(30);
        Test.stopTest();

        System.assertEquals(0, nearExpiry.size(), 'Healthy stock produces no alert');
    }

    // ── key ───────────────────────────────────────────────────────────

    @isTest
    static void key_isStableAndDistinguishesItsParts() {
        Map<String, Id> accs = accountsByName();
        Map<String, Id> prods = productsByCode();
        Id accA = accs.get('INV Distributor A');
        Id accB = accs.get('INV Distributor B');
        Id p1 = prods.get('INV-P1');

        Test.startTest();
        String first = DMS_DistributorInventory_Service.key(accA, p1);
        String again = DMS_DistributorInventory_Service.key(accA, p1);
        String other = DMS_DistributorInventory_Service.key(accB, p1);
        String nullKey = DMS_DistributorInventory_Service.key(null, null);
        Test.stopTest();

        System.assertEquals(first, again, 'The same pair always produces the same key');
        System.assertNotEquals(first, other, 'A different distributor is a different key');
        System.assertEquals(accA + '|' + p1, first, 'Callers can rebuild the key themselves');
        System.assertEquals('null|null', nullKey, 'Null ids do not throw — they key to a literal');
    }
}