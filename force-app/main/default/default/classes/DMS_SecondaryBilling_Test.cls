/**
 * @description Phase 3 tests for DMS secondary billing: FEFO batch allocation
 *              across distributor stock, stock-out + invoice creation, retailer
 *              credit enforcement, insufficient-stock handling, and gating.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_SecondaryBilling_Test {

    private static void enableToggles() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SECONDARY_BILLING, true);
    }

    private static void seedBatch(Id accountId, Id productId, String batch, Date expiry, Decimal qty) {
        insert new Distributor_Stock__c(
            Account__c = accountId,
            Product_Ext__c = productId,
            Batch_No__c = batch,
            Expiry_Date__c = expiry,
            Opening_Stock__c = qty,
            Stock_Date__c = Date.today(),
            Is_Current__c = true
        );
    }

    private static Decimal onHand(Id accountId, Id productId) {
        Map<String, Decimal> m = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ accountId }, new Set<Id>{ productId });
        String k = DMS_DistributorInventory_Service.key(accountId, productId);
        return m.containsKey(k) ? m.get(k) : 0;
    }

    @isTest
    static void fefoAcrossBatches_billsAndDeducts() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SB', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SB', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Id productId = products[0].Id;

        // Two current batches; earlier-expiry batch should be consumed first.
        seedBatch(dist.Id, productId, 'EARLY', Date.today().addDays(10), 30);
        seedBatch(dist.Id, productId, 'LATE',  Date.today().addDays(60), 50);

        enableToggles();
        Test.startTest();
        Id invoiceId = DMS_SecondaryBilling_Service.createSecondaryInvoice(
            dist.Id, retailer.Id,
            new List<DMS_SecondaryBilling_Service.LineRequest>{
                new DMS_SecondaryBilling_Service.LineRequest(productId, 60, 10)
            });
        Test.stopTest();

        Invoice__c inv = [
            SELECT Order_Type__c, Account__c, Sold_From_Distributor__c, Total_Amount__c
            FROM Invoice__c WHERE Id = :invoiceId
        ];
        System.assertEquals('Secondary', inv.Order_Type__c, 'Secondary invoice');
        System.assertEquals(retailer.Id, inv.Account__c, 'Billed to retailer');
        System.assertEquals(dist.Id, inv.Sold_From_Distributor__c, 'Sourced from distributor stock');
        System.assertEquals(600, inv.Total_Amount__c, 'Total = 60 * 10');

        // FEFO: 30 from EARLY + 30 from LATE -> two lines.
        List<Invoice_Line__c> ilines = [
            SELECT Batch_No__c, Quantity__c FROM Invoice_Line__c WHERE Invoice__c = :invoiceId ORDER BY Line_Number__c
        ];
        System.assertEquals(2, ilines.size(), 'One line per allocated batch');
        System.assertEquals('EARLY', ilines[0].Batch_No__c, 'Earliest-expiry batch consumed first');
        System.assertEquals(30, ilines[0].Quantity__c, 'Full EARLY batch consumed');
        System.assertEquals(30, ilines[1].Quantity__c, 'Remainder from LATE batch');

        // Remaining on-hand: EARLY 0 + LATE 20 = 20.
        System.assertEquals(20, onHand(dist.Id, productId), 'Distributor stock reduced to 20');

        System.assertEquals(2, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Account__c = :dist.Id AND Direction__c = 'Out'
              AND Transaction_Type__c = 'Outbound_Dispatch' AND Reference_Type__c = 'Invoice'
        ], 'Two stock-out transactions written');
    }

    @isTest
    static void duplicateProductLines_deductOnce() {
        // Same product on two request lines must draw the COMBINED quantity from
        // stock exactly once (regression for the per-line FEFO double-decrement).
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBdup', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBdup', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Id productId = products[0].Id;
        seedBatch(dist.Id, productId, 'B1', Date.today().addDays(30), 100);

        enableToggles();
        Test.startTest();
        Id invoiceId = DMS_SecondaryBilling_Service.createSecondaryInvoice(
            dist.Id, retailer.Id,
            new List<DMS_SecondaryBilling_Service.LineRequest>{
                new DMS_SecondaryBilling_Service.LineRequest(productId, 20, 10),
                new DMS_SecondaryBilling_Service.LineRequest(productId, 30, 10)
            });
        Test.stopTest();

        // Combined 50 units billed and deducted once: on-hand 100 -> 50.
        System.assertEquals(50, onHand(dist.Id, productId), 'Combined 50 deducted once (not 70+ via double-count)');
        Invoice__c inv = [SELECT Total_Amount__c FROM Invoice__c WHERE Id = :invoiceId];
        System.assertEquals(500, inv.Total_Amount__c, 'Total = (20+30) * 10');
    }

    @isTest
    static void insufficientStock_throws() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SB2', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SB2', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedBatch(dist.Id, products[0].Id, 'B1', Date.today().addDays(30), 20);

        enableToggles();
        Boolean thrown = false;
        Test.startTest();
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(
                dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.LineRequest>{
                    new DMS_SecondaryBilling_Service.LineRequest(products[0].Id, 50, 10)
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Insufficient'), 'Insufficient stock message');
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Should throw on insufficient stock');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c WHERE Sold_From_Distributor__c = :dist.Id],
            'No invoice created on failure');
    }

    @isTest
    static void creditLimitExceeded_throws() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SB3', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SB3', 'Retailer');
        retailer.Credit_Limit__c = 100;
        retailer.Outstanding_Balance__c = 0;
        update retailer;

        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedBatch(dist.Id, products[0].Id, 'B1', Date.today().addDays(30), 1000);

        enableToggles();
        Boolean thrown = false;
        Test.startTest();
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(
                dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.LineRequest>{
                    new DMS_SecondaryBilling_Service.LineRequest(products[0].Id, 60, 10) // 600 > 100
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Credit limit exceeded'), 'Credit message');
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Should throw on credit breach');
    }

    @isTest
    static void disabled_throws() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SB4', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SB4', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedBatch(dist.Id, products[0].Id, 'B1', Date.today().addDays(30), 100);

        // Explicitly disable in the cache (this org enables the DMS toggles as real
        // Feature_Toggle__mdt, which are visible in tests).
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SECONDARY_BILLING, false);
        Boolean thrown = false;
        Test.startTest();
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(
                dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.LineRequest>{
                    new DMS_SecondaryBilling_Service.LineRequest(products[0].Id, 10, 10)
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('not enabled'), 'Disabled message');
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Should throw when secondary billing disabled');
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage.
    //
    //  createInvoiceFromQuote — the sales-order-faithful path that carries
    //  pre-computed commercial terms — had no test at all, which is most of
    //  the gap. Also covered here: the argument guards on both entry points,
    //  the price-list fallback when a line omits its price, and the credit
    //  check's disabled and no-limit exits.
    // ══════════════════════════════════════════════════════════════════

    private static DMS_SecondaryBilling_Service.QuoteLine quoteLine(
            Id productId, Decimal qty, Decimal unitPrice) {
        DMS_SecondaryBilling_Service.QuoteLine q = new DMS_SecondaryBilling_Service.QuoteLine();
        q.productId = productId;
        q.qty = qty;
        q.unitPrice = unitPrice;
        q.gross = qty * unitPrice;
        q.discount = 0;
        q.schemeDiscount = 0;
        q.taxRate = 0;
        q.tax = 0;
        q.cgst = 0;
        q.sgst = 0;
        q.igst = 0;
        q.freeQty = 0;
        q.net = qty * unitPrice;
        return q;
    }

    private static Id firstProduct() {
        return TestDataFactory.createAndInsertProducts(1)[0].Id;
    }

    // ── createSecondaryInvoice: argument guards ───────────────────────

    @isTest
    static void createSecondaryInvoice_withMissingArguments_throws() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBargs', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBargs', 'Retailer');
        Id productId = firstProduct();
        List<DMS_SecondaryBilling_Service.LineRequest> oneLine =
            new List<DMS_SecondaryBilling_Service.LineRequest>{
                new DMS_SecondaryBilling_Service.LineRequest(productId, 5, 10)
            };
        enableToggles();

        Test.startTest();
        Integer rejected = 0;
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(null, retailer.Id, oneLine);
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(dist.Id, null, oneLine);
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(dist.Id, retailer.Id, null);
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.LineRequest>());
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(4, rejected,
            'Missing distributor, retailer or lines must all be refused before any stock moves');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c], 'Nothing was created');
    }

    @isTest
    static void createSecondaryInvoice_withOnlyUnusableLines_throws() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBnone', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBnone', 'Retailer');
        Id productId = firstProduct();
        enableToggles();

        Test.startTest();
        Boolean thrown = false;
        try {
            DMS_SecondaryBilling_Service.createSecondaryInvoice(dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.LineRequest>{
                    new DMS_SecondaryBilling_Service.LineRequest(null, 10, 10),
                    new DMS_SecondaryBilling_Service.LineRequest(productId, 0, 10),
                    new DMS_SecondaryBilling_Service.LineRequest(productId, null, 10)
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('No valid order lines'),
                'Expected the empty-lines message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(thrown,
            'A request of nothing but blank products and zero quantities has nothing to bill');
    }

    // ── createSecondaryInvoice: pricing fallback ──────────────────────

    @isTest
    static void lineWithNoPriceFallsBackToTheProductPrice() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBprice', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBprice', 'Retailer');
        Product_Extension__c prod = TestDataFactory.createProduct('SB Priced', 'SB-PRICED');
        prod.Unit_Price__c = 25;
        insert prod;
        seedBatch(dist.Id, prod.Id, 'B1', Date.today().addDays(30), 100);
        enableToggles();

        Test.startTest();
        Id invoiceId = DMS_SecondaryBilling_Service.createSecondaryInvoice(
            dist.Id, retailer.Id,
            new List<DMS_SecondaryBilling_Service.LineRequest>{
                new DMS_SecondaryBilling_Service.LineRequest(prod.Id, 4, null)
            });
        Test.stopTest();

        System.assertEquals(100, [
            SELECT Subtotal__c FROM Invoice__c WHERE Id = :invoiceId
        ].Subtotal__c, 'With no price on the line the product master rate of 25 is used: 4 x 25');
        System.assertEquals(25, [
            SELECT Unit_Price__c FROM Invoice_Line__c WHERE Invoice__c = :invoiceId
        ].Unit_Price__c, 'And the resolved price is what lands on the line');
    }

    // ── Credit check exits ────────────────────────────────────────────

    @isTest
    static void creditCheckIsSkippedWhenEnforcementIsOff() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBcredoff', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBcredoff', 'Retailer');
        retailer.Credit_Limit__c = 100;
        retailer.Outstanding_Balance__c = 0;
        update retailer;
        Id productId = firstProduct();
        seedBatch(dist.Id, productId, 'B1', Date.today().addDays(30), 1000);

        enableToggles();
        // Same 600-rupee sale that breaches the 100 limit in creditLimitExceeded_throws,
        // but with enforcement switched off it must go through.
        DMS_Config.overrides = new Map<String, String>{ DMS_Config.KEY_ENFORCE_CREDIT => 'false' };

        Test.startTest();
        Id invoiceId = DMS_SecondaryBilling_Service.createSecondaryInvoice(
            dist.Id, retailer.Id,
            new List<DMS_SecondaryBilling_Service.LineRequest>{
                new DMS_SecondaryBilling_Service.LineRequest(productId, 60, 10)
            });
        Test.stopTest();

        System.assertNotEquals(null, invoiceId,
            'With ENFORCE_CREDIT off the ceiling is advisory and the sale completes');
        System.assertEquals(600, [
            SELECT Total_Amount__c FROM Invoice__c WHERE Id = :invoiceId
        ].Total_Amount__c, 'Billed in full');
    }

    @isTest
    static void retailerWithNoCreditLimitIsNotBlocked() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBnolimit', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBnolimit', 'Retailer');
        retailer.Credit_Limit__c = 0;
        retailer.Outstanding_Balance__c = 5000;
        update retailer;
        Id productId = firstProduct();
        seedBatch(dist.Id, productId, 'B1', Date.today().addDays(30), 1000);
        enableToggles();

        Test.startTest();
        Id invoiceId = DMS_SecondaryBilling_Service.createSecondaryInvoice(
            dist.Id, retailer.Id,
            new List<DMS_SecondaryBilling_Service.LineRequest>{
                new DMS_SecondaryBilling_Service.LineRequest(productId, 10, 10)
            });
        Test.stopTest();

        System.assertNotEquals(null, invoiceId,
            'A blank or zero limit means no ceiling has been agreed, so nothing is enforced '
            + 'even with money outstanding');
    }

    // ── createInvoiceFromQuote ────────────────────────────────────────

    @isTest
    static void quote_gating_and_argumentGuards() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBQg', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBQg', 'Retailer');
        Id productId = firstProduct();
        List<DMS_SecondaryBilling_Service.QuoteLine> oneLine =
            new List<DMS_SecondaryBilling_Service.QuoteLine>{ quoteLine(productId, 5, 10) };

        Test.startTest();
        // Toggles off first.
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SECONDARY_BILLING, false);
        Boolean disabledThrew = false;
        try {
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(dist.Id, retailer.Id, oneLine);
        } catch (DMS_SecondaryBillingException e) {
            disabledThrew = e.getMessage().contains('not enabled');
        }

        enableToggles();
        Integer rejected = 0;
        try {
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(null, retailer.Id, oneLine);
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        try {
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(dist.Id, null, oneLine);
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        try {
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(dist.Id, retailer.Id, null);
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        try {
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.QuoteLine>());
        } catch (DMS_SecondaryBillingException e) { rejected++; }
        Test.stopTest();

        System.assert(disabledThrew, 'The quote path is gated by the same toggles');
        System.assertEquals(4, rejected, 'And guards its arguments the same way');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c], 'Nothing created');
    }

    @isTest
    static void quote_withOnlyUnusableLines_throws() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBQnone', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBQnone', 'Retailer');
        Id productId = firstProduct();
        enableToggles();

        Test.startTest();
        Boolean thrown = false;
        try {
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.QuoteLine>{
                    quoteLine(null, 5, 10),
                    quoteLine(productId, 0, 10)
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('No valid order lines'),
                'Expected the empty-lines message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(thrown, 'A quote with no billable line has nothing to invoice');
    }

    @isTest
    static void quote_carriesCommercialTermsAndMovesStock() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBQ', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBQ', 'Retailer');
        Id productId = firstProduct();
        seedBatch(dist.Id, productId, 'EARLY', Date.today().addDays(10), 8);
        seedBatch(dist.Id, productId, 'LATE', Date.today().addDays(90), 20);

        // A line whose terms were already worked out upstream: 10 units at 100,
        // 150 off (50 of it scheme), 18% tax on the discounted value.
        DMS_SecondaryBilling_Service.QuoteLine q = quoteLine(productId, 10, 100);
        q.discount = 150;
        q.schemeDiscount = 50;
        q.taxRate = 18;
        q.cgst = 76.5;
        q.sgst = 76.5;
        q.igst = 0;
        q.tax = 153;
        q.freeQty = 2;
        q.hsn = '1704';
        q.net = 1003; // 1000 gross - 150 discount + 153 tax
        enableToggles();

        Test.startTest();
        Id invoiceId = DMS_SecondaryBilling_Service.createInvoiceFromQuote(
            dist.Id, retailer.Id, new List<DMS_SecondaryBilling_Service.QuoteLine>{ q });
        Test.stopTest();

        Invoice__c inv = [
            SELECT Order_Type__c, Account__c, Sold_From_Distributor__c, Subtotal__c,
                   Discount_Amount__c, Tax_Amount__c, Net_Amount__c, Total_Amount__c,
                   Balance_Due__c, Total_Items__c, Status__c
            FROM Invoice__c WHERE Id = :invoiceId
        ];
        System.assertEquals('Secondary', inv.Order_Type__c, 'Still a secondary invoice');
        System.assertEquals(retailer.Id, inv.Account__c, 'Billed to the retailer');
        System.assertEquals(dist.Id, inv.Sold_From_Distributor__c, 'Out of distributor stock');
        System.assertEquals(1000, inv.Subtotal__c, 'Gross carried from the quote, not recomputed');
        System.assertEquals(150, inv.Discount_Amount__c, 'Discount carried');
        System.assertEquals(153, inv.Tax_Amount__c, 'Tax carried');
        System.assertEquals(1003, inv.Net_Amount__c, 'Net carried');
        System.assertEquals(1003, inv.Total_Amount__c, 'The quote net is what is billed');
        System.assertEquals(1003, inv.Balance_Due__c, 'And what is owed');
        System.assertEquals(1, inv.Total_Items__c, 'One source line');

        // One invoice line per SOURCE line, holding its terms — unlike the
        // LineRequest path, which writes one line per allocated batch.
        List<Invoice_Line__c> lines = [
            SELECT Quantity__c, Free_Quantity__c, Unit_Price__c, Discount_Amount__c,
                   Scheme_Discount__c, Tax_Rate__c, Tax_Amount__c, CGST__c, SGST__c, IGST__c,
                   Line_Amount__c, Net_Amount__c, HSN_SAC_Code__c
            FROM Invoice_Line__c WHERE Invoice__c = :invoiceId
        ];
        System.assertEquals(1, lines.size(),
            'The quote path keeps the source line shape even though stock came from two batches');
        System.assertEquals(10, lines[0].Quantity__c, 'Billed quantity');
        System.assertEquals(2, lines[0].Free_Quantity__c, 'Free units recorded separately');
        System.assertEquals(150, lines[0].Discount_Amount__c, 'Line discount');
        System.assertEquals(50, lines[0].Scheme_Discount__c, 'Scheme portion kept distinct');
        System.assertEquals(18, lines[0].Tax_Rate__c, 'Rate');
        System.assertEquals(76.5, lines[0].CGST__c, 'CGST half');
        System.assertEquals(76.5, lines[0].SGST__c, 'SGST half');
        System.assertEquals(0, lines[0].IGST__c, 'Intra-state, so no IGST');
        System.assertEquals('1704', lines[0].HSN_SAC_Code__c, 'HSN carried for the tax invoice');

        // Physical movement is still FEFO across batches: 8 from EARLY, 2 from LATE.
        System.assertEquals(18, onHand(dist.Id, productId), 'Ten units left the distributor');
        System.assertEquals(2, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Reference_Id__c = :invoiceId AND Direction__c = 'Out'
        ], 'One stock movement per batch touched');
    }

    @isTest
    static void quote_aggregatesDuplicateProductsBeforeAllocating() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBQdup', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBQdup', 'Retailer');
        Id productId = firstProduct();
        seedBatch(dist.Id, productId, 'B1', Date.today().addDays(30), 100);
        enableToggles();

        Test.startTest();
        Id invoiceId = DMS_SecondaryBilling_Service.createInvoiceFromQuote(
            dist.Id, retailer.Id,
            new List<DMS_SecondaryBilling_Service.QuoteLine>{
                quoteLine(productId, 20, 10),
                quoteLine(productId, 30, 10)
            });
        Test.stopTest();

        System.assertEquals(50, onHand(dist.Id, productId),
            'The same product on two quote lines draws its combined quantity once');
        System.assertEquals(2, [
            SELECT COUNT() FROM Invoice_Line__c WHERE Invoice__c = :invoiceId
        ], 'But both source lines survive on the invoice');
        System.assertEquals(500, [
            SELECT Subtotal__c FROM Invoice__c WHERE Id = :invoiceId
        ].Subtotal__c, 'Gross is the sum of both lines');
    }

    @isTest
    static void quote_insufficientStock_throwsAndCreatesNothing() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBQshort', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBQshort', 'Retailer');
        Id productId = firstProduct();
        seedBatch(dist.Id, productId, 'B1', Date.today().addDays(30), 5);
        enableToggles();

        Test.startTest();
        Boolean thrown = false;
        try {
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.QuoteLine>{ quoteLine(productId, 50, 10) });
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();

        System.assert(thrown, 'A quote cannot bill stock the distributor does not hold');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c], 'And no invoice is left behind');
        System.assertEquals(5, onHand(dist.Id, productId), 'Stock is untouched');
    }

    @isTest
    static void quote_breachingTheRetailerCreditLimit_throws() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist SBQcred', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer SBQcred', 'Retailer');
        retailer.Credit_Limit__c = 500;
        retailer.Outstanding_Balance__c = 400;
        update retailer;
        Id productId = firstProduct();
        seedBatch(dist.Id, productId, 'B1', Date.today().addDays(30), 1000);
        enableToggles();

        Test.startTest();
        Boolean thrown = false;
        try {
            // Net 1000 on top of 400 outstanding against a 500 ceiling.
            DMS_SecondaryBilling_Service.createInvoiceFromQuote(dist.Id, retailer.Id,
                new List<DMS_SecondaryBilling_Service.QuoteLine>{ quoteLine(productId, 100, 10) });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Credit limit exceeded'),
                'Expected the credit message, got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(thrown,
            'The quote path checks credit on the NET amount before any stock moves');
        System.assertEquals(1000, onHand(dist.Id, productId), 'Stock untouched');
    }
}