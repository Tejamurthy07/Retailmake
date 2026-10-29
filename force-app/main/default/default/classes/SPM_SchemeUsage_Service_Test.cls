/**
 * @description Tests for SPM_SchemeUsage_Service — the per-customer scheme usage
 * ledger behind the Max_Uses_Per_Customer__c cap.
 *
 * The rule this ledger exists to enforce is "one order, one use". A single order
 * that touches the same scheme across several lines must count once, and
 * re-firing the writer must never add a second row — otherwise a customer burns
 * through their allowance without receiving anything extra. Those two
 * properties get the most tests.
 *
 * Fixture notes:
 *   - Sales_Order__c requires an Account and an Order Date, and requires a
 *     Territory for any status other than Draft or Cancelled, so orders here
 *     stay in Draft unless a test needs otherwise.
 *   - Scheme_Usage__c requires Account, Scheme, Sales Order, Benefit Type and
 *     Used At, so seeded rows always carry all five.
 */
@isTest
private class SPM_SchemeUsage_Service_Test {

    @testSetup
    static void setupTestData() {
        Territory_Master__c territory =
            TestDataFactory.createAndInsertTerritory('SU Territory', 'TER-SU01');

        insert new List<Account>{
            TestDataFactory.createAccount('SU Customer A', 'Retailer'),
            TestDataFactory.createAccount('SU Customer B', 'Retailer')
        };

        insert new List<Product_Extension__c>{
            TestDataFactory.createProduct('SU Product One', 'SU-P1'),
            TestDataFactory.createProduct('SU Product Two', 'SU-P2')
        };

        insert new List<Scheme__c>{
            scheme('SU Discount Scheme', 'SU-SCH-DISC', discountType(), 2),
            scheme('SU Free Goods Scheme', 'SU-SCH-FREE', freeGoodsType(), 1),
            scheme('SU Points Scheme', 'SU-SCH-PTS', pointsType(), null),
            scheme('SU Unlimited Scheme', 'SU-SCH-UNL', discountType(), 0)
        };
        // Territory is referenced by orders raised in the tests below.
        System.assertNotEquals(null, territory.Id, 'Territory seeded');
    }

    /**
     * Scheme_Type__c is a RESTRICTED picklist and the deployed value set has
     * drifted from the repo metadata, so hardcoding a literal here breaks the
     * whole class on a value that does not exist in this org. These helpers pick
     * the first value the org actually has, and fall back to leaving the field
     * blank — which mapBenefitType treats as a plain discount — rather than
     * failing setup.
     */
    private static Set<String> cachedSchemeTypes;

    private static Set<String> validSchemeTypes() {
        if (cachedSchemeTypes == null) {
            cachedSchemeTypes = new Set<String>();
            for (Schema.PicklistEntry e : Scheme__c.Scheme_Type__c.getDescribe().getPicklistValues()) {
                if (e.isActive()) cachedSchemeTypes.add(e.getValue());
            }
        }
        return cachedSchemeTypes;
    }

    private static String firstAvailable(List<String> preferred) {
        for (String p : preferred) {
            if (validSchemeTypes().contains(p)) return p;
        }
        return null;
    }

    /** A type that maps to the 'Free Product' benefit, or null if none exists. */
    private static String freeGoodsType() {
        return firstAvailable(new List<String>{ 'Buy X Get Y', 'Combo Offer' });
    }

    /** A type that maps to the 'Points' benefit, or null if none exists. */
    private static String pointsType() {
        return firstAvailable(new List<String>{ 'Reward Points' });
    }

    /** Any type that is NOT one of the special-cased ones, so it maps to 'Discount'. */
    private static String discountType() {
        return firstAvailable(new List<String>{
            'Flat Discount Percent', 'Amount Off', 'Same Product (VAL)',
            'Same Product (QTY)', 'Slab Based'
        });
    }

    private static Scheme__c scheme(String name, String code, String type, Decimal maxUses) {
        Scheme__c s = new Scheme__c(
            Name = name,
            Scheme_Code__c = code,
            Status__c = 'Active',
            Start_Date__c = Date.today().addDays(-1),
            End_Date__c = Date.today().addDays(30),
            Budget_Amount__c = 1000000,
            Max_Uses_Per_Customer__c = maxUses
        );
        // Left blank when the org has no suitable value — the field is optional.
        if (String.isNotBlank(type)) s.Scheme_Type__c = type;
        return s;
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> cachedAccounts;
    private static Map<String, Id> cachedSchemes;
    private static Map<String, Id> cachedProducts;

    private static Map<String, Id> accounts() {
        if (cachedAccounts == null) {
            cachedAccounts = new Map<String, Id>();
            for (Account a : [SELECT Id, Name FROM Account WHERE Name LIKE 'SU Customer%']) {
                cachedAccounts.put(a.Name, a.Id);
            }
        }
        return cachedAccounts;
    }

    private static Map<String, Id> schemes() {
        if (cachedSchemes == null) {
            cachedSchemes = new Map<String, Id>();
            for (Scheme__c s : [SELECT Id, Scheme_Code__c FROM Scheme__c WHERE Scheme_Code__c LIKE 'SU-SCH-%']) {
                cachedSchemes.put(s.Scheme_Code__c, s.Id);
            }
        }
        return cachedSchemes;
    }

    private static Map<String, Id> products() {
        if (cachedProducts == null) {
            cachedProducts = new Map<String, Id>();
            for (Product_Extension__c p : [
                SELECT Id, SKU_Code__c FROM Product_Extension__c WHERE SKU_Code__c LIKE 'SU-P%'
            ]) {
                cachedProducts.put(p.SKU_Code__c, p.Id);
            }
        }
        return cachedProducts;
    }

    private static Id custA()    { return accounts().get('SU Customer A'); }
    private static Id custB()    { return accounts().get('SU Customer B'); }
    private static Id discount() { return schemes().get('SU-SCH-DISC'); }
    private static Id freeGoods(){ return schemes().get('SU-SCH-FREE'); }
    private static Id points()   { return schemes().get('SU-SCH-PTS'); }
    private static Id unlimited(){ return schemes().get('SU-SCH-UNL'); }
    private static Id productOne() { return products().get('SU-P1'); }

    /**
     * Each order gets its own date. Sales_Order__c carries a duplicate guard
     * keyed on account + date + sales rep, so two same-day orders for one
     * customer are refused — and several tests here need exactly that pair to
     * prove a cap is counted per order.
     */
    private static Integer orderSeq = 0;

    private static Sales_Order__c order(Id accountId) {
        orderSeq++;
        Sales_Order__c o = new Sales_Order__c(
            Account__c = accountId,
            Order_Date__c = Date.today().addDays(-orderSeq),
            Status__c = 'Draft'
        );
        insert o;
        return o;
    }

    private static Order_Line_Item__c orderLine(
            Id orderId, Id productId, Id schemeId, Decimal schemeDiscount) {
        return new Order_Line_Item__c(
            Sales_Order__c = orderId,
            Product_Ext__c = productId,
            Quantity__c = 10,
            Unit_Price__c = 100,
            Scheme__c = schemeId,
            Scheme_Discount__c = schemeDiscount
        );
    }

    private static Scheme_Usage__c usage(Id accountId, Id schemeId, Id orderId) {
        return new Scheme_Usage__c(
            Account__c = accountId,
            Scheme__c = schemeId,
            Sales_Order__c = orderId,
            Benefit_Type__c = 'Discount',
            Benefit_Amount__c = 100,
            Used_At__c = Datetime.now()
        );
    }

    private static List<Scheme__c> schemeRecords(List<Id> ids) {
        return [
            SELECT Id, Max_Uses_Per_Customer__c FROM Scheme__c WHERE Id IN :ids
        ];
    }

    // ── recordDeliveredUsage ──────────────────────────────────────────

    @isTest
    static void deliveredUsage_withNoOrders_doesNothing() {
        Test.startTest();
        SPM_SchemeUsage_Service.recordDeliveredUsage(null);
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Scheme_Usage__c], 'Nothing to record');
    }

    @isTest
    static void deliveredUsage_withNoSchemeOnAnyLine_recordsNothing() {
        Sales_Order__c o = order(custA());
        insert orderLine(o.Id, productOne(), null, null);

        Test.startTest();
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ o.Id });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Scheme_Usage__c],
            'An order that used no scheme consumes nobody allowance');
    }

    @isTest
    static void deliveredUsage_countsOneUsePerOrderEvenAcrossManyLines() {
        Sales_Order__c o = order(custA());
        // The same scheme applied to three separate lines of one order.
        insert new List<Order_Line_Item__c>{
            orderLine(o.Id, productOne(), discount(), 30),
            orderLine(o.Id, productOne(), discount(), 45),
            orderLine(o.Id, productOne(), discount(), 25)
        };

        Test.startTest();
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ o.Id });
        Test.stopTest();

        List<Scheme_Usage__c> rows = [
            SELECT Account__c, Scheme__c, Sales_Order__c, Benefit_Amount__c, Benefit_Type__c
            FROM Scheme_Usage__c
        ];
        System.assertEquals(1, rows.size(),
            'One order is one use no matter how many lines carried the scheme — counting per '
            + 'line would burn a customer allowance three times for a single order');
        System.assertEquals(custA(), rows[0].Account__c, 'Attributed to the customer');
        System.assertEquals(discount(), rows[0].Scheme__c, 'For the scheme used');
        System.assertEquals(o.Id, rows[0].Sales_Order__c, 'And the order that used it');
        System.assertEquals(100, rows[0].Benefit_Amount__c,
            'The benefit is summed across the lines: 30 + 45 + 25');
    }

    @isTest
    static void deliveredUsage_recordsOneRowPerSchemeOnTheOrder() {
        Sales_Order__c o = order(custA());
        insert new List<Order_Line_Item__c>{
            orderLine(o.Id, productOne(), discount(), 50),
            orderLine(o.Id, productOne(), freeGoods(), 0)
        };

        Test.startTest();
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ o.Id });
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Scheme_Usage__c],
            'Two different schemes on one order are two separate uses');
    }

    @isTest
    static void deliveredUsage_isIdempotent() {
        Sales_Order__c o = order(custA());
        insert orderLine(o.Id, productOne(), discount(), 60);
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ o.Id });

        Test.startTest();
        // A trigger re-firing on a later status change must not double-count.
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ o.Id });
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ o.Id });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Scheme_Usage__c],
            'Re-running the writer leaves the ledger untouched — this is the only thing '
            + 'standing between a status flip-flop and a customer losing their allowance');
    }

    @isTest
    static void deliveredUsage_mapsTheBenefitTypeFromTheSchemeType() {
        Sales_Order__c o = order(custA());
        insert new List<Order_Line_Item__c>{
            orderLine(o.Id, productOne(), discount(), 10),
            orderLine(o.Id, productOne(), freeGoods(), 0),
            orderLine(o.Id, productOne(), points(), 0)
        };

        Test.startTest();
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ o.Id });
        Test.stopTest();

        Map<Id, String> typeByScheme = new Map<Id, String>();
        for (Scheme_Usage__c u : [SELECT Scheme__c, Benefit_Type__c FROM Scheme_Usage__c]) {
            typeByScheme.put(u.Scheme__c, u.Benefit_Type__c);
        }
        // Anything that is not free-goods or points falls through to Discount,
        // including a scheme with no type set at all.
        System.assertEquals('Discount', typeByScheme.get(discount()),
            'A discount-style scheme is recorded as a discount');

        // The other two only assert when this org actually has the value — see
        // the note on validSchemeTypes().
        if (freeGoodsType() != null) {
            System.assertEquals('Free Product', typeByScheme.get(freeGoods()),
                'A free-goods scheme is recorded as free product, not as a discount, because '
                + 'the two are reported and funded separately');
        }
        if (pointsType() != null) {
            System.assertEquals('Points', typeByScheme.get(points()),
                'A reward scheme is recorded as points');
        }
    }

    @isTest
    static void deliveredUsage_handlesSeveralOrdersInOneCall() {
        Sales_Order__c first = order(custA());
        Sales_Order__c second = order(custB());
        insert new List<Order_Line_Item__c>{
            orderLine(first.Id, productOne(), discount(), 20),
            orderLine(second.Id, productOne(), discount(), 40)
        };

        Test.startTest();
        SPM_SchemeUsage_Service.recordDeliveredUsage(new Set<Id>{ first.Id, second.Id });
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Scheme_Usage__c],
            'Each order gets its own row, attributed to its own customer');
        System.assertEquals(1, [
            SELECT COUNT() FROM Scheme_Usage__c WHERE Account__c = :custA()
        ], 'Customer A used it once');
        System.assertEquals(1, [
            SELECT COUNT() FROM Scheme_Usage__c WHERE Account__c = :custB()
        ], 'And so did customer B, independently');
    }

    // ── filterExhaustedSchemes ────────────────────────────────────────

    @isTest
    static void filter_withNothingToFilter_returnsEmpty() {
        List<Scheme__c> all = schemeRecords(new List<Id>{ discount() });

        Test.startTest();
        Set<Id> noAccount = SPM_SchemeUsage_Service.filterExhaustedSchemes(null, all);
        Set<Id> noSchemes = SPM_SchemeUsage_Service.filterExhaustedSchemes(custA(), null);
        Set<Id> emptyList = SPM_SchemeUsage_Service.filterExhaustedSchemes(
            custA(), new List<Scheme__c>());
        Test.stopTest();

        System.assertEquals(0, noAccount.size(), 'No customer, nothing to judge');
        System.assertEquals(0, noSchemes.size(), 'No schemes, nothing to return');
        System.assertEquals(0, emptyList.size(), 'Same for an empty list');
    }

    @isTest
    static void filter_treatsANullOrZeroCapAsUnlimited() {
        List<Scheme__c> candidates = schemeRecords(new List<Id>{ points(), unlimited() });
        // Both already used several times over.
        Sales_Order__c o1 = order(custA());
        Sales_Order__c o2 = order(custA());
        insert new List<Scheme_Usage__c>{
            usage(custA(), points(), o1.Id), usage(custA(), points(), o2.Id),
            usage(custA(), unlimited(), o1.Id), usage(custA(), unlimited(), o2.Id)
        };

        Test.startTest();
        Set<Id> allowed = SPM_SchemeUsage_Service.filterExhaustedSchemes(custA(), candidates);
        Test.stopTest();

        System.assert(allowed.contains(points()),
            'A scheme with no cap set is unlimited, however often it has been used');
        System.assert(allowed.contains(unlimited()),
            'And a cap of zero means the same — it is not read as "never allowed"');
    }

    @isTest
    static void filter_allowsASchemeStillUnderItsCap() {
        List<Scheme__c> candidates = schemeRecords(new List<Id>{ discount() });
        // Cap is 2; one use so far.
        insert usage(custA(), discount(), order(custA()).Id);

        Test.startTest();
        Set<Id> allowed = SPM_SchemeUsage_Service.filterExhaustedSchemes(custA(), candidates);
        Test.stopTest();

        System.assert(allowed.contains(discount()),
            'One use against a cap of two leaves the scheme available');
    }

    @isTest
    static void filter_dropsASchemeThatHasReachedItsCap() {
        List<Scheme__c> candidates = schemeRecords(new List<Id>{ discount(), freeGoods() });
        Sales_Order__c o1 = order(custA());
        Sales_Order__c o2 = order(custA());
        insert new List<Scheme_Usage__c>{
            usage(custA(), discount(), o1.Id),
            usage(custA(), discount(), o2.Id),   // cap of 2 now reached
            usage(custA(), freeGoods(), o1.Id)   // cap of 1 now reached
        };

        Test.startTest();
        Set<Id> allowed = SPM_SchemeUsage_Service.filterExhaustedSchemes(custA(), candidates);
        Test.stopTest();

        System.assertEquals(0, allowed.size(),
            'A customer at their limit stops being offered the scheme — the cap is inclusive, '
            + 'so the second use of a two-use scheme is the last one');
    }

    @isTest
    static void filter_countsUsageForThisCustomerOnly() {
        List<Scheme__c> candidates = schemeRecords(new List<Id>{ freeGoods() });
        // Customer B has exhausted the one-use scheme; customer A has not.
        insert usage(custB(), freeGoods(), order(custB()).Id);

        Test.startTest();
        Set<Id> allowedForA = SPM_SchemeUsage_Service.filterExhaustedSchemes(custA(), candidates);
        Set<Id> allowedForB = SPM_SchemeUsage_Service.filterExhaustedSchemes(custB(), candidates);
        Test.stopTest();

        System.assert(allowedForA.contains(freeGoods()),
            'One customer using up a scheme must not close it for everyone else');
        System.assertEquals(0, allowedForB.size(), 'While the customer who used it is done');
    }

    // ── getUsageCounts ────────────────────────────────────────────────

    @isTest
    static void usageCounts_withNothingToCount_returnsEmpty() {
        Test.startTest();
        Map<Id, Integer> noAccount = SPM_SchemeUsage_Service.getUsageCounts(
            null, new Set<Id>{ discount() });
        Map<Id, Integer> noSchemes = SPM_SchemeUsage_Service.getUsageCounts(custA(), null);
        Map<Id, Integer> emptySet = SPM_SchemeUsage_Service.getUsageCounts(
            custA(), new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, noAccount.size(), 'No customer, no counts');
        System.assertEquals(0, noSchemes.size(), 'No schemes, no counts');
        System.assertEquals(0, emptySet.size(), 'Same for an empty set');
    }

    @isTest
    static void usageCounts_countDistinctOrdersNotRows() {
        Sales_Order__c o1 = order(custA());
        Sales_Order__c o2 = order(custA());
        // Two ledger rows against the SAME order — belt-and-braces, since the
        // writers are idempotent, but the count must still read one use.
        insert new List<Scheme_Usage__c>{
            usage(custA(), discount(), o1.Id),
            usage(custA(), discount(), o1.Id),
            usage(custA(), discount(), o2.Id)
        };

        Test.startTest();
        Map<Id, Integer> counts = SPM_SchemeUsage_Service.getUsageCounts(
            custA(), new Set<Id>{ discount() });
        Test.stopTest();

        System.assertEquals(2, counts.get(discount()),
            'Two distinct orders is two uses — a duplicate ledger row must not cost the '
            + 'customer an extra use');
    }

    @isTest
    static void usageCounts_excludeTheOrderBeingSaved() {
        Sales_Order__c beingSaved = order(custA());
        Sales_Order__c earlier = order(custA());
        insert new List<Scheme_Usage__c>{
            usage(custA(), discount(), beingSaved.Id),
            usage(custA(), discount(), earlier.Id)
        };

        Test.startTest();
        Map<Id, Integer> withAll = SPM_SchemeUsage_Service.getUsageCounts(
            custA(), new Set<Id>{ discount() });
        Map<Id, Integer> excludingSelf = SPM_SchemeUsage_Service.getUsageCounts(
            custA(), new Set<Id>{ discount() }, new Set<Id>{ beingSaved.Id });
        Test.stopTest();

        System.assertEquals(2, withAll.get(discount()), 'Both orders count normally');
        System.assertEquals(1, excludingSelf.get(discount()),
            'The order being re-saved is excluded from its own cap check, otherwise editing '
            + 'an order would make it fail the limit it already satisfies');
    }

    @isTest
    static void usageCounts_areScopedToTheCustomer() {
        insert new List<Scheme_Usage__c>{
            usage(custA(), discount(), order(custA()).Id),
            usage(custB(), discount(), order(custB()).Id)
        };

        Test.startTest();
        Map<Id, Integer> forA = SPM_SchemeUsage_Service.getUsageCounts(
            custA(), new Set<Id>{ discount() });
        Test.stopTest();

        System.assertEquals(1, forA.get(discount()),
            'Only this customer usage counts against their own allowance');
    }

    @isTest
    static void usageCounts_omitSchemesNeverUsed() {
        insert usage(custA(), discount(), order(custA()).Id);

        Test.startTest();
        Map<Id, Integer> counts = SPM_SchemeUsage_Service.getUsageCounts(
            custA(), new Set<Id>{ discount(), freeGoods() });
        Test.stopTest();

        System.assertEquals(1, counts.get(discount()), 'The used scheme is counted');
        System.assertEquals(null, counts.get(freeGoods()),
            'An unused scheme has no entry — callers must read a missing key as zero');
    }

    // ── reverseOrderUsage ─────────────────────────────────────────────

    @isTest
    static void reverse_withNoOrders_doesNothing() {
        insert usage(custA(), discount(), order(custA()).Id);

        Test.startTest();
        SPM_SchemeUsage_Service.reverseOrderUsage(null);
        SPM_SchemeUsage_Service.reverseOrderUsage(new Set<Id>());
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Scheme_Usage__c],
            'An empty request leaves the ledger alone');
    }

    @isTest
    static void reverse_returnsTheUseToTheCustomer() {
        Sales_Order__c cancelled = order(custA());
        Sales_Order__c kept = order(custA());
        insert new List<Scheme_Usage__c>{
            usage(custA(), freeGoods(), cancelled.Id),
            usage(custA(), freeGoods(), kept.Id)
        };

        Test.startTest();
        SPM_SchemeUsage_Service.reverseOrderUsage(new Set<Id>{ cancelled.Id });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Scheme_Usage__c],
            'Only the cancelled order usage is released');
        System.assertEquals(kept.Id, [
            SELECT Sales_Order__c FROM Scheme_Usage__c
        ].Sales_Order__c, 'And the surviving order keeps its use');

        Set<Id> allowed = SPM_SchemeUsage_Service.filterExhaustedSchemes(
            custA(), schemeRecords(new List<Id>{ freeGoods() }));
        System.assertEquals(0, allowed.size(),
            'One use of the one-use scheme remains, so it is still exhausted — cancelling one '
            + 'of two orders gives back exactly one use, not all of them');
    }

    // ── recordOrderUsage ──────────────────────────────────────────────

    @isTest
    static void orderUsage_withNoOrders_doesNothing() {
        Test.startTest();
        SPM_SchemeUsage_Service.recordOrderUsage(null);
        SPM_SchemeUsage_Service.recordOrderUsage(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Scheme_Usage__c], 'Nothing to record');
    }

    @isTest
    static void orderUsage_withNoLines_recordsNothing() {
        Sales_Order__c empty = order(custA());

        Test.startTest();
        SPM_SchemeUsage_Service.recordOrderUsage(new Set<Id>{ empty.Id });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Scheme_Usage__c],
            'An order with no lines has nothing for the engine to evaluate');
    }

    @isTest
    static void orderUsage_leavesAnAlreadyRecordedPairAlone() {
        Sales_Order__c o = order(custA());
        insert orderLine(o.Id, productOne(), discount(), 25);
        // Pre-seed the ledger for this order, as the delivered writer would have.
        insert usage(custA(), discount(), o.Id);

        Test.startTest();
        SPM_SchemeUsage_Service.recordOrderUsage(new Set<Id>{ o.Id });
        Test.stopTest();

        System.assertEquals(1, [
            SELECT COUNT() FROM Scheme_Usage__c
            WHERE Sales_Order__c = :o.Id AND Scheme__c = :discount()
        ], 'The two writers share one ledger, so a pair already recorded is never doubled '
         + 'whichever path runs second');
    }
}