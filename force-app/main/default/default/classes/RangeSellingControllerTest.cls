/**
 * @description Tests for RangeSellingController — the range-selling coverage
 * matrix (what share of billed outlets each brand / sub-brand / SKU reaches).
 *
 * The number that matters is the distinct-outlet count. An outlet that ordered
 * the same brand on three orders, or on three lines of one order, is still ONE
 * covered outlet — inflating it makes range coverage look better than it is,
 * which defeats the report's purpose. The core test builds exactly that shape
 * and asserts the count stays at the distinct figure.
 *
 * Fixture notes, learned the hard way elsewhere in this suite:
 *   - Sales_Order__c has a duplicate guard on account + date + rep, so every
 *     order gets its own Order_Date__c;
 *   - Order_Line_Item__c requires a product and a positive quantity.
 */
@isTest
private class RangeSellingControllerTest {

    @testSetup
    static void setupTestData() {
        insert new List<Account>{
            TestDataFactory.createAccount('RS Outlet One', 'Retailer'),
            TestDataFactory.createAccount('RS Outlet Two', 'Retailer'),
            TestDataFactory.createAccount('RS Outlet Three', 'Retailer')
        };

        Product_Extension__c colaCan = TestDataFactory.createProduct('RS Cola Can', 'RS-COLA-CAN');
        colaCan.Brand__c = 'Fizz';
        colaCan.Sub_Brand__c = 'Fizz Cola';
        Product_Extension__c colaBottle = TestDataFactory.createProduct('RS Cola Bottle', 'RS-COLA-BTL');
        colaBottle.Brand__c = 'Fizz';
        colaBottle.Sub_Brand__c = 'Fizz Cola';
        Product_Extension__c lemon = TestDataFactory.createProduct('RS Lemon', 'RS-LEMON');
        lemon.Brand__c = 'Fizz';
        lemon.Sub_Brand__c = 'Fizz Lemon';
        Product_Extension__c chips = TestDataFactory.createProduct('RS Chips', 'RS-CHIPS');
        chips.Brand__c = 'Crunch';
        chips.Sub_Brand__c = 'Crunch Salted';
        Product_Extension__c unbranded = TestDataFactory.createProduct('RS Unbranded', 'RS-PLAIN');
        // Brand__c / Sub_Brand__c deliberately left null.
        insert new List<Product_Extension__c>{ colaCan, colaBottle, lemon, chips, unbranded };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> cachedAccounts;
    private static Map<String, Id> cachedProducts;
    private static Integer orderSeq = 0;

    private static Map<String, Id> accounts() {
        if (cachedAccounts == null) {
            cachedAccounts = new Map<String, Id>();
            for (Account a : [SELECT Id, Name FROM Account WHERE Name LIKE 'RS Outlet%']) {
                cachedAccounts.put(a.Name, a.Id);
            }
        }
        return cachedAccounts;
    }

    private static Map<String, Id> products() {
        if (cachedProducts == null) {
            cachedProducts = new Map<String, Id>();
            for (Product_Extension__c p : [
                SELECT Id, SKU_Code__c FROM Product_Extension__c WHERE SKU_Code__c LIKE 'RS-%'
            ]) {
                cachedProducts.put(p.SKU_Code__c, p.Id);
            }
        }
        return cachedProducts;
    }

    private static Id outletOne()   { return accounts().get('RS Outlet One'); }
    private static Id outletTwo()   { return accounts().get('RS Outlet Two'); }
    private static Id outletThree() { return accounts().get('RS Outlet Three'); }

    /** An order for the outlet, date-spaced past the duplicate guard. */
    private static Sales_Order__c newOrder(Id accountId) {
        orderSeq++;
        Sales_Order__c o = new Sales_Order__c(
            Account__c = accountId,
            Order_Date__c = Date.today().addDays(-orderSeq),
            Status__c = 'Draft'
        );
        insert o;
        return o;
    }

    /**
     * One order for the outlet carrying the given SKUs, one line each.
     *
     * Lines are inserted in ONE DML with the order-line trigger handler
     * bypassed: its pricing chain (OMS_OrderPricing_Service) runs a stack of
     * queries per insert, and a test that builds several orders line-by-line
     * blows the 101-query limit inside fixture setup. The controller under
     * test only reads Product_Ext__r fields and the Sales_Order__r account,
     * both set right here — no derived pricing is involved.
     */
    private static void orderWith(Id accountId, List<String> skuCodes) {
        Sales_Order__c o = newOrder(accountId);
        List<Order_Line_Item__c> lines = new List<Order_Line_Item__c>();
        for (String sku : skuCodes) {
            lines.add(new Order_Line_Item__c(
                Sales_Order__c = o.Id,
                Product_Ext__c = products().get(sku),
                Quantity__c = 10,
                Unit_Price__c = 50
            ));
        }
        TriggerHandler.bypass('OMS_OrderLineItem_TriggerHandler');
        try {
            insert lines;
        } finally {
            TriggerHandler.clearBypass('OMS_OrderLineItem_TriggerHandler');
        }
    }

    private static Map<String, RangeSellingController.CoverageRow> byName(
            List<RangeSellingController.CoverageRow> rows) {
        Map<String, RangeSellingController.CoverageRow> m =
            new Map<String, RangeSellingController.CoverageRow>();
        for (RangeSellingController.CoverageRow r : rows) m.put(r.name, r);
        return m;
    }

    // ── Grouping guard ────────────────────────────────────────────────

    @isTest
    static void anUnknownGrouping_isRejected() {
        Test.startTest();
        Integer rejected = 0;
        try {
            RangeSellingController.getCoverage('Category');
        } catch (AuraHandledException e) { rejected++; }
        try {
            RangeSellingController.getCoverage(null);
        } catch (AuraHandledException e) { rejected++; }
        try {
            // The whitelist is also the injection guard — anything not on it,
            // including something query-shaped, must be refused outright.
            RangeSellingController.getCoverage('Name FROM Account--');
        } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(3, rejected,
            'Only the whitelisted groupings reach the dynamic SOQL; everything else throws');
    }

    // ── Empty org ─────────────────────────────────────────────────────

    @isTest
    static void withNoOrdersAtAll_returnsNoRows() {
        Test.startTest();
        List<RangeSellingController.CoverageRow> rows =
            RangeSellingController.getCoverage('Brand');
        Test.stopTest();

        System.assertEquals(0, rows.size(),
            'No billing yet means an empty matrix, not an error');
    }

    // ── Brand coverage ────────────────────────────────────────────────

    @isTest
    static void brandCoverage_countsDistinctOutletsNotOrdersOrLines() {
        // Outlet One buys Fizz on TWO orders, one of them with TWO Fizz lines —
        // four Fizz lines in total, but still one covered outlet.
        orderWith(outletOne(), new List<String>{ 'RS-COLA-CAN', 'RS-COLA-BTL' });
        orderWith(outletOne(), new List<String>{ 'RS-LEMON' });
        // Outlet Two buys Fizz once and Crunch once.
        orderWith(outletTwo(), new List<String>{ 'RS-COLA-CAN', 'RS-CHIPS' });
        // Outlet Three is billed, but only for Crunch.
        orderWith(outletThree(), new List<String>{ 'RS-CHIPS' });

        Test.startTest();
        Map<String, RangeSellingController.CoverageRow> rows =
            byName(RangeSellingController.getCoverage('Brand'));
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two brands were billed');

        RangeSellingController.CoverageRow fizz = rows.get('Fizz');
        System.assertEquals(2, fizz.covered,
            'Fizz reached two outlets — four line items across three orders must still '
            + 'count as two, or the coverage number is meaningless');
        System.assertEquals(3, fizz.total, 'Out of three billed outlets');
        System.assertEquals(67, fizz.pct, '2 of 3 rounds to 67%');

        RangeSellingController.CoverageRow crunch = rows.get('Crunch');
        System.assertEquals(2, crunch.covered, 'Crunch also reached two outlets');
        System.assertEquals(67, crunch.pct, 'Same share');
    }

    @isTest
    static void brandCoverage_ordersRowsByReachDescending() {
        orderWith(outletOne(), new List<String>{ 'RS-COLA-CAN' });
        orderWith(outletTwo(), new List<String>{ 'RS-COLA-CAN' });
        orderWith(outletThree(), new List<String>{ 'RS-COLA-CAN', 'RS-CHIPS' });

        Test.startTest();
        List<RangeSellingController.CoverageRow> rows =
            RangeSellingController.getCoverage('Brand');
        Test.stopTest();

        System.assertEquals('Fizz', rows[0].name,
            'The widest-reaching brand leads the matrix (3 outlets)');
        System.assertEquals('Crunch', rows[1].name, 'The narrower one follows (1 outlet)');
        System.assert(rows[0].covered >= rows[1].covered, 'Descending by reach');
    }

    @isTest
    static void unbrandedLines_areLeftOutOfBrandCoverage() {
        orderWith(outletOne(), new List<String>{ 'RS-PLAIN' });
        orderWith(outletTwo(), new List<String>{ 'RS-COLA-CAN' });

        Test.startTest();
        Map<String, RangeSellingController.CoverageRow> rows =
            byName(RangeSellingController.getCoverage('Brand'));
        Test.stopTest();

        System.assertEquals(1, rows.size(),
            'A product with no brand cannot appear as a brand row — null is filtered, '
            + 'not rendered as a blank bar');
        System.assertEquals(2, rows.get('Fizz').total,
            'But the outlet that bought it still counts among billed outlets, so the '
            + 'denominator is 2 and Fizz shows 1 of 2');
        System.assertEquals(50, rows.get('Fizz').pct, 'Half the billed base');
    }

    // ── Sub-brand and SKU groupings ───────────────────────────────────

    @isTest
    static void subBrandCoverage_separatesSubBrandsWithinABrand() {
        // Both products are brand Fizz, but different sub-brands.
        orderWith(outletOne(), new List<String>{ 'RS-COLA-CAN' });
        orderWith(outletTwo(), new List<String>{ 'RS-LEMON' });

        Test.startTest();
        Map<String, RangeSellingController.CoverageRow> rows =
            byName(RangeSellingController.getCoverage('Sub-Brand'));
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two sub-brands, two rows');
        System.assertEquals(1, rows.get('Fizz Cola').covered,
            'Sub-brand coverage splits what the Brand view merges — that split is the '
            + 'range-selling gap the rep is meant to close');
        System.assertEquals(1, rows.get('Fizz Lemon').covered, 'One outlet each');
    }

    @isTest
    static void skuCoverage_groupsByProductName() {
        orderWith(outletOne(), new List<String>{ 'RS-COLA-CAN', 'RS-CHIPS' });
        orderWith(outletTwo(), new List<String>{ 'RS-COLA-CAN' });

        Test.startTest();
        Map<String, RangeSellingController.CoverageRow> rows =
            byName(RangeSellingController.getCoverage('SKU'));
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two SKUs billed');
        System.assertEquals(2, rows.get('RS Cola Can').covered, 'The can reached both outlets');
        System.assertEquals(1, rows.get('RS Chips').covered, 'Chips reached one');
        System.assertEquals(100, rows.get('RS Cola Can').pct, '2 of 2 billed outlets');
    }

    // ── Denominator behaviour ─────────────────────────────────────────

    @isTest
    static void theDenominator_isBilledOutletsNotAllOutlets() {
        // Outlet Three exists but has never ordered — it must not dilute the
        // percentages. Coverage is share of the BILLED base.
        orderWith(outletOne(), new List<String>{ 'RS-COLA-CAN' });
        orderWith(outletTwo(), new List<String>{ 'RS-COLA-CAN' });

        Test.startTest();
        Map<String, RangeSellingController.CoverageRow> rows =
            byName(RangeSellingController.getCoverage('Brand'));
        Test.stopTest();

        System.assertEquals(2, rows.get('Fizz').total,
            'Three outlets exist but only two are billed — the never-billed one is a '
            + 'distribution problem, not a range-selling one');
        System.assertEquals(100, rows.get('Fizz').pct, 'So Fizz covers 100% of its base');
    }

    @isTest
    static void anOrderWithNoLines_stillCountsInTheDenominator() {
        // Outlet One is billed (has an order) but bought nothing groupable.
        newOrder(outletOne());
        orderWith(outletTwo(), new List<String>{ 'RS-COLA-CAN' });

        Test.startTest();
        Map<String, RangeSellingController.CoverageRow> rows =
            byName(RangeSellingController.getCoverage('Brand'));
        Test.stopTest();

        System.assertEquals(2, rows.get('Fizz').total,
            'The denominator comes from Sales_Order__c, so an outlet with an empty order '
            + 'is billed but uncovered');
        System.assertEquals(50, rows.get('Fizz').pct, '1 of 2');
    }

    @isTest
    static void percentages_roundToWholeNumbers() {
        // 1 of 3 = 33.33…% — the matrix shows whole percentages.
        orderWith(outletOne(), new List<String>{ 'RS-COLA-CAN' });
        orderWith(outletTwo(), new List<String>{ 'RS-CHIPS' });
        orderWith(outletThree(), new List<String>{ 'RS-CHIPS' });

        Test.startTest();
        Map<String, RangeSellingController.CoverageRow> rows =
            byName(RangeSellingController.getCoverage('Brand'));
        Test.stopTest();

        System.assertEquals(33, rows.get('Fizz').pct, '1 of 3 renders as 33, not 33.333');
        System.assertEquals(67, rows.get('Crunch').pct, 'And 2 of 3 rounds up to 67');
    }
}