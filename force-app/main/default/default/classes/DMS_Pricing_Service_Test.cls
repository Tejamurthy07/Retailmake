/**
 * @description Tests for DMS_Pricing_Service: price-list resolution with min-qty
 *              tiers and master-price fallback.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_Pricing_Service_Test {

    @isTest
    static void resolvesTiersAndFallback() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist Price', 'Distributor');
        List<Product_Extension__c> ps = TestDataFactory.createAndInsertProducts(2);
        Id withList = ps[0].Id;
        Id noList = ps[1].Id;
        update new List<Product_Extension__c>{
            new Product_Extension__c(Id = withList, Unit_Price__c = 200),
            new Product_Extension__c(Id = noList, Unit_Price__c = 77)
        };

        Date f = Date.today().addDays(-1);
        Date t = Date.today().addDays(30);
        // MDM_PriceList_Handler rejects two entries that share product + customer +
        // category + territory + region + channel over overlapping dates, and its
        // composite key ignores Min_Qty__c — so a quantity tier looks like a
        // duplicate to it. Bypassing the handler is the only way to build the tiers
        // this service is designed to read. See tiersCannotBeCreatedThroughTheTrigger.
        TriggerHandler.bypass('MDM_PriceList_Handler');
        try {
            insert new List<Price_List__c>{
                new Price_List__c(Name = 'B-1', Product_Ext__c = withList, Price_Type__c = 'Retailer Price',
                    Unit_Price__c = 100, Min_Qty__c = 1, Effective_From__c = f, Effective_To__c = t,
                    Is_Active__c = true, Status__c = 'Approved'),
                new Price_List__c(Name = 'B-10', Product_Ext__c = withList, Price_Type__c = 'Retailer Price',
                    Unit_Price__c = 90, Min_Qty__c = 10, Effective_From__c = f, Effective_To__c = t,
                    Is_Active__c = true, Status__c = 'Approved')
            };
        } finally {
            TriggerHandler.clearBypass('MDM_PriceList_Handler');
        }

        Test.startTest();
        Map<Id, DMS_Pricing_Service.ProductPrice> r =
            DMS_Pricing_Service.resolve(new Set<Id>{ withList, noList }, dist.Id);
        Map<Id, Decimal> at5 = DMS_Pricing_Service.priceForLines(new Map<Id, Decimal>{ withList => 5 }, dist.Id);
        Map<Id, Decimal> at10 = DMS_Pricing_Service.priceForLines(new Map<Id, Decimal>{ withList => 10 }, dist.Id);
        Test.stopTest();

        DMS_Pricing_Service.ProductPrice pp = r.get(withList);
        System.assertEquals(true, pp.fromPriceList, 'Product has a price list');
        System.assertEquals(100, pp.listPrice, 'List price at qty 1 is 100');
        System.assert(pp.tiers.size() >= 2, 'Two qty tiers resolved');
        System.assertEquals(100, at5.get(withList), 'qty 5 -> 100');
        System.assertEquals(90, at10.get(withList), 'qty 10 -> bulk 90');

        DMS_Pricing_Service.ProductPrice ppNo = r.get(noList);
        System.assertEquals(false, ppNo.fromPriceList, 'No price list for second product');
        System.assertEquals(77, ppNo.listPrice, 'Falls back to product master price');
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage: guard clauses, the four dimension filters,
    //  priority selection, effective-date windows and qty edge cases.
    // ══════════════════════════════════════════════════════════════════

    private static final Date FROM_DATE = Date.today().addDays(-1);
    private static final Date TO_DATE   = Date.today().addDays(30);

    private static Product_Extension__c productAt(Decimal masterPrice) {
        Product_Extension__c p = TestDataFactory.createProduct(
            'PRC ' + masterPrice, 'PRC-' + String.valueOf(masterPrice));
        p.Unit_Price__c = masterPrice;
        insert p;
        return p;
    }

    private static Price_List__c entry(Id productId, Decimal unitPrice, Decimal minQty) {
        return new Price_List__c(
            Name = 'PL-' + unitPrice,
            Product_Ext__c = productId,
            Price_Type__c = 'Retailer Price',
            Unit_Price__c = unitPrice,
            Min_Qty__c = minQty,
            Effective_From__c = FROM_DATE,
            Effective_To__c = TO_DATE,
            Is_Active__c = true,
            Status__c = 'Approved'
        );
    }

    private static Decimal listPriceOf(Id productId, Id accountId) {
        return DMS_Pricing_Service.resolve(new Set<Id>{ productId }, accountId)
            .get(productId).listPrice;
    }

    // ── Guard clauses ─────────────────────────────────────────────────

    @isTest
    static void resolve_withNoProducts_returnsEmptyMap() {
        Test.startTest();
        Map<Id, DMS_Pricing_Service.ProductPrice> fromNull =
            DMS_Pricing_Service.resolve(null, null);
        Map<Id, DMS_Pricing_Service.ProductPrice> fromEmpty =
            DMS_Pricing_Service.resolve(new Set<Id>(), null);
        Test.stopTest();

        System.assertEquals(0, fromNull.size(), 'Nothing asked for, nothing queried');
        System.assertEquals(0, fromEmpty.size(), 'An empty catalogue request is not an error');
    }

    @isTest
    static void priceForLines_withNoQuantities_returnsEmptyMap() {
        Test.startTest();
        Map<Id, Decimal> fromNull = DMS_Pricing_Service.priceForLines(null, null);
        Map<Id, Decimal> fromEmpty =
            DMS_Pricing_Service.priceForLines(new Map<Id, Decimal>(), null);
        Test.stopTest();

        System.assertEquals(0, fromNull.size(), 'An order with no lines prices to nothing');
        System.assertEquals(0, fromEmpty.size(), 'Same for an empty map');
    }

    @isTest
    static void resolve_withUnknownProductId_returnsZeroBasePrice() {
        // A product id that is not in Product_Extension__c — a stale catalogue
        // reference must not throw, it must price to zero and flag no price list.
        Id ghost = Id.valueOf(
            Product_Extension__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Map<Id, DMS_Pricing_Service.ProductPrice> r =
            DMS_Pricing_Service.resolve(new Set<Id>{ ghost }, null);
        Test.stopTest();

        DMS_Pricing_Service.ProductPrice pp = r.get(ghost);
        System.assertNotEquals(null, pp, 'Every requested product gets an entry back');
        System.assertEquals(0, pp.basePrice, 'An unknown product has no master price');
        System.assertEquals(0, pp.listPrice, 'And therefore prices at zero');
        System.assertEquals(false, pp.fromPriceList, 'With no price-list entry behind it');
        System.assertEquals(1, pp.tiers.size(), 'A single default tier is still returned');
    }

    @isTest
    static void resolve_withUnknownAccountId_treatsContextAsEmpty() {
        Product_Extension__c prod = productAt(50);
        Id ghostAccount = Id.valueOf(
            Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Decimal price = listPriceOf(prod.Id, ghostAccount);
        Test.stopTest();

        System.assertEquals(50, price,
            'An account that no longer exists leaves no dimensions to match, so the '
            + 'master price stands rather than the call failing');
    }

    // ── Dimension filters ─────────────────────────────────────────────

    @isTest
    static void customerSpecificPriceAppliesOnlyToThatCustomer() {
        Account mine = TestDataFactory.createAndInsertAccount('PRC Mine', 'Distributor');
        Account theirs = TestDataFactory.createAndInsertAccount('PRC Theirs', 'Distributor');
        Product_Extension__c prod = productAt(200);

        Price_List__c pl = entry(prod.Id, 120, 1);
        pl.Customer__c = mine.Id;
        insert pl;

        Test.startTest();
        Decimal forMine = listPriceOf(prod.Id, mine.Id);
        Decimal forTheirs = listPriceOf(prod.Id, theirs.Id);
        Decimal forNobody = listPriceOf(prod.Id, null);
        Test.stopTest();

        System.assertEquals(120, forMine, 'The negotiated customer price applies');
        System.assertEquals(200, forTheirs,
            'Another distributor must never see a customer-specific rate');
        System.assertEquals(200, forNobody,
            'With no account context there is no customer to match, so it cannot apply');
    }

    @isTest
    static void territorySpecificPriceAppliesOnlyInThatTerritory() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Terr', 'Distributor');
        Account accWithTerritory = [SELECT Territory__c FROM Account WHERE Id = :acc.Id];
        Territory_Master__c other =
            TestDataFactory.createAndInsertTerritory('PRC Other Territory', 'TER-PRC9');
        Product_Extension__c prod = productAt(300);

        Price_List__c pl = entry(prod.Id, 250, 1);
        pl.Territory__c = other.Id;
        insert pl;

        Test.startTest();
        Decimal price = listPriceOf(prod.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, accWithTerritory.Territory__c,
            'The account sits in its own territory');
        System.assertEquals(300, price,
            'A rate scoped to a different territory does not reach this distributor');
    }

    @isTest
    static void channelSpecificPriceMatchesOnlyItsChannel() {
        // The factory puts every account on the GT channel.
        Account acc = TestDataFactory.createAndInsertAccount('PRC Chan', 'Distributor');
        Product_Extension__c gtProduct = productAt(400);
        Product_Extension__c mtProduct = productAt(500);

        Price_List__c gt = entry(gtProduct.Id, 350, 1);
        gt.Channel__c = 'GT';
        Price_List__c mt = entry(mtProduct.Id, 450, 1);
        mt.Channel__c = 'MT';
        insert new List<Price_List__c>{ gt, mt };

        Test.startTest();
        Decimal gtPrice = listPriceOf(gtProduct.Id, acc.Id);
        Decimal mtPrice = listPriceOf(mtProduct.Id, acc.Id);
        Decimal noContext = listPriceOf(gtProduct.Id, null);
        Test.stopTest();

        System.assertEquals(350, gtPrice, 'A GT rate reaches a GT distributor');
        System.assertEquals(500, mtPrice,
            'A modern-trade rate must not leak to a general-trade distributor');
        System.assertEquals(400, noContext,
            'With no account there is no channel to compare against');
    }

    @isTest
    static void categorySpecificPriceMatchesOnlyItsCategory() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Cat', 'Distributor');
        Product_Category__c category = new Product_Category__c(
            Name = 'PRC Category', Category_Code__c = 'PRC-CAT', Level__c = 'Category',
            Is_Active__c = true);
        insert category;

        Product_Extension__c inCategory = productAt(600);
        inCategory.Product_Category__c = category.Id;
        update inCategory;
        Product_Extension__c noCategory = productAt(700);

        Price_List__c forCategory = entry(inCategory.Id, 550, 1);
        forCategory.Category__c = category.Id;
        Price_List__c forCategoryButWrongProduct = entry(noCategory.Id, 650, 1);
        forCategoryButWrongProduct.Category__c = category.Id;
        insert new List<Price_List__c>{ forCategory, forCategoryButWrongProduct };

        Test.startTest();
        Decimal matched = listPriceOf(inCategory.Id, acc.Id);
        Decimal unmatched = listPriceOf(noCategory.Id, acc.Id);
        Test.stopTest();

        System.assertEquals(550, matched, 'The category rate applies to a product in it');
        System.assertEquals(700, unmatched,
            'A product with no category cannot match a category-scoped rate');
    }

    // ── Priority selection ────────────────────────────────────────────

    @isTest
    static void moreSpecificDimensionWinsOverTheBaseRate() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Prio', 'Distributor');
        Product_Extension__c prod = productAt(1000);

        // Two different dimension combinations, so the overlap guard does not
        // fire; MDM_PriceList_Handler assigns each its own Priority__c.
        Price_List__c base = entry(prod.Id, 900, 1);
        Price_List__c customer = entry(prod.Id, 800, 1);
        customer.Customer__c = acc.Id;
        insert new List<Price_List__c>{ base, customer };

        Test.startTest();
        Decimal price = listPriceOf(prod.Id, acc.Id);
        Test.stopTest();

        System.assertEquals(800, price,
            'A customer-specific rate outranks the base rate — the lowest Priority__c wins, '
            + 'not whichever row the query happened to return first');
    }

    // ── Effective-date window ─────────────────────────────────────────

    @isTest
    static void expiredAndFutureAndInactiveEntriesAreIgnored() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Dates', 'Distributor');
        Product_Extension__c expired = productAt(110);
        Product_Extension__c future = productAt(120);
        Product_Extension__c inactive = productAt(130);

        Price_List__c expiredEntry = entry(expired.Id, 10, 1);
        expiredEntry.Effective_From__c = Date.today().addDays(-60);
        expiredEntry.Effective_To__c = Date.today().addDays(-30);
        Price_List__c futureEntry = entry(future.Id, 20, 1);
        futureEntry.Effective_From__c = Date.today().addDays(30);
        futureEntry.Effective_To__c = Date.today().addDays(60);
        Price_List__c inactiveEntry = entry(inactive.Id, 30, 1);
        inactiveEntry.Is_Active__c = false;
        insert new List<Price_List__c>{ expiredEntry, futureEntry, inactiveEntry };

        Test.startTest();
        Map<Id, DMS_Pricing_Service.ProductPrice> r = DMS_Pricing_Service.resolve(
            new Set<Id>{ expired.Id, future.Id, inactive.Id }, acc.Id);
        Test.stopTest();

        System.assertEquals(110, r.get(expired.Id).listPrice, 'A lapsed rate no longer applies');
        System.assertEquals(120, r.get(future.Id).listPrice, 'A rate that starts later is not live yet');
        System.assertEquals(130, r.get(inactive.Id).listPrice, 'A switched-off rate is ignored');
        for (Id pid : r.keySet()) {
            System.assertEquals(false, r.get(pid).fromPriceList,
                'None of these products has an applicable price-list entry');
        }
    }

    @isTest
    static void openEndedEntryStillApplies() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Open', 'Distributor');
        Product_Extension__c prod = productAt(140);
        Price_List__c openEnded = entry(prod.Id, 99, 1);
        openEnded.Effective_To__c = null;
        insert openEnded;

        Test.startTest();
        Decimal price = listPriceOf(prod.Id, acc.Id);
        Test.stopTest();

        System.assertEquals(99, price,
            'A rate with no end date runs indefinitely rather than being treated as expired');
    }

    // ── Quantity handling ─────────────────────────────────────────────

    @isTest
    static void priceForLines_belowTheBreakAndWithNoQuantity() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Qty', 'Distributor');
        Product_Extension__c prod = productAt(160);

        TriggerHandler.bypass('MDM_PriceList_Handler');
        try {
            insert new List<Price_List__c>{
                entry(prod.Id, 150, 1),
                entry(prod.Id, 140, 25)
            };
        } finally {
            TriggerHandler.clearBypass('MDM_PriceList_Handler');
        }

        Test.startTest();
        Map<Id, Decimal> atOne = DMS_Pricing_Service.priceForLines(
            new Map<Id, Decimal>{ prod.Id => 1 }, acc.Id);
        Map<Id, Decimal> atTwentyFour = DMS_Pricing_Service.priceForLines(
            new Map<Id, Decimal>{ prod.Id => 24 }, acc.Id);
        Map<Id, Decimal> atTwentyFive = DMS_Pricing_Service.priceForLines(
            new Map<Id, Decimal>{ prod.Id => 25 }, acc.Id);
        Map<Id, Decimal> atNull = DMS_Pricing_Service.priceForLines(
            new Map<Id, Decimal>{ prod.Id => null }, acc.Id);
        Test.stopTest();

        System.assertEquals(150, atOne.get(prod.Id), 'Single unit pays the standard rate');
        System.assertEquals(150, atTwentyFour.get(prod.Id),
            'One short of the break still pays the standard rate');
        System.assertEquals(140, atTwentyFive.get(prod.Id), 'The break applies from 25 up');
        // A missing quantity becomes 0, and 0 clears no tier — not even the
        // opening one at minQty 1 — so the price stays at its seeded value, the
        // product master rate. Note that is the UNDISCOUNTED 160 rather than the
        // negotiated 150: a line that loses its quantity prices higher than any
        // real order would. Harmless while quantity is mandatory upstream, but it
        // is a fallback to master, not to the opening tier.
        System.assertEquals(160, atNull.get(prod.Id),
            'A missing quantity falls back to the product master price, not the price list');
    }

    @isTest
    static void identicallyPricedBreaksCollapseIntoOneTier() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Same', 'Distributor');
        Product_Extension__c prod = productAt(170);

        TriggerHandler.bypass('MDM_PriceList_Handler');
        try {
            insert new List<Price_List__c>{
                entry(prod.Id, 165, 1),
                entry(prod.Id, 165, 50)
            };
        } finally {
            TriggerHandler.clearBypass('MDM_PriceList_Handler');
        }

        Test.startTest();
        DMS_Pricing_Service.ProductPrice pp =
            DMS_Pricing_Service.resolve(new Set<Id>{ prod.Id }, acc.Id).get(prod.Id);
        Test.stopTest();

        System.assertEquals(1, pp.tiers.size(),
            'A break that does not change the price is not a break — showing "50+ for the same '
            + 'money" in the catalogue would be noise');
        System.assertEquals(165, pp.listPrice, 'And the single tier carries the rate');
    }

    @isTest
    static void productWithNoMasterPriceResolvesToZero() {
        Account acc = TestDataFactory.createAndInsertAccount('PRC Zero', 'Distributor');
        Product_Extension__c prod = TestDataFactory.createProduct('PRC No Price', 'PRC-NOPRICE');
        prod.Unit_Price__c = null;
        insert prod;

        Test.startTest();
        DMS_Pricing_Service.ProductPrice pp =
            DMS_Pricing_Service.resolve(new Set<Id>{ prod.Id }, acc.Id).get(prod.Id);
        Test.stopTest();

        System.assertEquals(0, pp.basePrice, 'An unpriced product is zero, not null');
        System.assertEquals(0, pp.listPrice, 'So it cannot blow up an order total');
        System.assertEquals(1, pp.tiers.size(), 'One default tier is still produced');
    }

    // ── Interaction with the price-list trigger ───────────────────────

    /**
     * This service is built entirely around Min_Qty__c breaks — PriceTier, the
     * breakpoint set, priceAtQty. But MDM_PriceList_Handler.validateDateRangeOverlap
     * rejects a second entry sharing product + customer + category + territory +
     * region + channel over overlapping dates, and buildCompositeKey does NOT
     * include Min_Qty__c. So a quantity tier is indistinguishable from a duplicate
     * and cannot be created through the UI or a normal insert at all.
     *
     * This test pins that contradiction so it is visible rather than folklore. If
     * the handler is fixed to include Min_Qty__c in the key, this test should fail
     * and be deleted — and the bypass calls elsewhere in this class removed.
     */
    @isTest
    static void tiersCannotBeCreatedThroughTheTrigger() {
        Product_Extension__c prod = productAt(180);

        Test.startTest();
        Boolean rejected = false;
        try {
            insert new List<Price_List__c>{
                entry(prod.Id, 175, 1),
                entry(prod.Id, 160, 10)
            };
        } catch (DmlException e) {
            rejected = true;
            System.assert(e.getMessage().contains('overlap'),
                'Expected the overlap guard, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(rejected,
            'Two quantity breaks on one product are rejected as overlapping duplicates, '
            + 'because the overlap key ignores Min_Qty__c');
    }
}