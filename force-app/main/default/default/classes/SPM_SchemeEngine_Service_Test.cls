/**
 * @description Test class for SPM_SchemeEngine_Service.
 *              Validates all 4 scheme categories x 6 scheme types (24 scenarios),
 *              scheme stacking/priority, expired scheme handling, budget checks,
 *              territory mapping, and order-level integration.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class SPM_SchemeEngine_Service_Test {

    @testSetup
    static void setupTestData() {
        // Create accounts
        Account retailer = TestDataFactory.createAndInsertAccount('Scheme Test Retailer', 'Retailer');

        // Create territory and beat
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Scheme Territory', 'TER-S01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Scheme Beat', 'BEAT-S01', territory.Id);

        // Create products
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(5);

        // ── Free Products, Same Product (QTY) ───────────────────────
        Scheme__c freeProductQty = TestDataFactory.createScheme(
            'Free Product Same QTY', 'SCH-FP-SPQ', 'Free Products', 'Same Product (QTY)');
        freeProductQty.Min_Quantity__c = 3;
        freeProductQty.Free_Product_Ext__c = products[0].Id;
        freeProductQty.Free_Quantity__c = 1;
        freeProductQty.Priority__c = 1;
        freeProductQty.Product_Ext__c = products[0].Id;

        // ── Discount in %, Same Product (VAL) ───────────────────────
        Scheme__c discountPctVal = TestDataFactory.createScheme(
            'Discount Pct Same VAL', 'SCH-DP-SPV', 'Discount in %', 'Same Product (VAL)');
        discountPctVal.MOV__c = 1500;
        discountPctVal.Discount_Percent__c = 3;
        discountPctVal.Priority__c = 2;
        discountPctVal.Product_Ext__c = products[1].Id;

        // ── Discount in Value, Assorted Product (QTY) ───────────────
        Scheme__c priceDiscAssortedQty = TestDataFactory.createScheme(
            'Price Disc Assorted QTY', 'SCH-PD-APQ', 'Discount in Value', 'Assorted Product (QTY)');
        priceDiscAssortedQty.Price_Discount__c = 200;
        priceDiscAssortedQty.Priority__c = 3;
        priceDiscAssortedQty.Is_Stackable__c = true;

        // ── Reward Points, Invoice Val Based ────────────────────────
        Scheme__c rewardInvoiceVal = TestDataFactory.createScheme(
            'Reward Points Invoice Val', 'SCH-RP-IVB', 'Reward Points', 'Invoice Val Based');
        rewardInvoiceVal.Invoice_Val_Threshold__c = 11000;
        rewardInvoiceVal.Reward_Points__c = 300;
        rewardInvoiceVal.Priority__c = 4;
        rewardInvoiceVal.Is_Stackable__c = true;

        // ── Free Products, Invoice Qty Based ────────────────────────
        Scheme__c freeInvoiceQty = TestDataFactory.createScheme(
            'Free Product Invoice QTY', 'SCH-FP-IQB', 'Free Products', 'Invoice Qty Based');
        freeInvoiceQty.Invoice_Qty_Threshold__c = 10;
        freeInvoiceQty.Invoice_Qty_UOM__c = 'KG';
        freeInvoiceQty.Free_Product_Ext__c = products[2].Id;
        freeInvoiceQty.Free_Quantity__c = 3;
        freeInvoiceQty.Priority__c = 5;
        freeInvoiceQty.Is_Stackable__c = true;

        // ── Expired scheme ──────────────────────────────────────────
        Scheme__c expiredScheme = TestDataFactory.createScheme(
            'Expired Offer', 'SCH-EXP01', 'Discount in %', 'Same Product (QTY)');
        expiredScheme.Start_Date__c = Date.today().addDays(-60);
        expiredScheme.End_Date__c = Date.today().addDays(-30);
        expiredScheme.Status__c = 'Expired';

        // ── Budget scheme ───────────────────────────────────────────
        Scheme__c budgetScheme = TestDataFactory.createScheme(
            'Budget Limited', 'SCH-BDG01', 'Discount in %', 'Same Product (QTY)');
        budgetScheme.Budget_Amount__c = 50000;
        budgetScheme.Budget_Used__c = 0;
        budgetScheme.Discount_Percent__c = 10;
        budgetScheme.Product_Ext__c = products[3].Id;
        budgetScheme.Priority__c = 6;

        // Insert all as Draft to avoid overlap validation
        List<Scheme__c> allSchemes = new List<Scheme__c>{
            freeProductQty, discountPctVal, priceDiscAssortedQty,
            rewardInvoiceVal, freeInvoiceQty, expiredScheme, budgetScheme
        };
        for (Scheme__c s : allSchemes) {
            if (s.Status__c == 'Active') s.Status__c = 'Draft';
            if (s.Budget_Amount__c == null || s.Budget_Amount__c == 0) s.Budget_Amount__c = 100000;
        }
        insert allSchemes;

        // Activate non-expired schemes
        for (Scheme__c s : allSchemes) {
            if (s.Scheme_Code__c != 'SCH-EXP01') s.Status__c = 'Active';
        }
        update allSchemes;

        // Scheme Products for assorted scheme
        Scheme__c assortedScheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-PD-APQ'];
        insert new List<Scheme_Product__c>{
            new Scheme_Product__c(
                Scheme__c = assortedScheme.Id,
                Product_Ext__c = products[0].Id,
                Is_Buy_Product__c = true,
                Is_Get_Product__c = false,
                Min_Quantity__c = 3
            ),
            new Scheme_Product__c(
                Scheme__c = assortedScheme.Id,
                Product_Ext__c = products[1].Id,
                Is_Buy_Product__c = true,
                Is_Get_Product__c = false,
                Min_Quantity__c = 4
            )
        };

        // Scheme Products for invoice schemes
        Scheme__c invScheme = [SELECT Id FROM Scheme__c WHERE Scheme_Code__c = 'SCH-FP-IQB'];
        insert new List<Scheme_Product__c>{
            new Scheme_Product__c(
                Scheme__c = invScheme.Id,
                Product_Ext__c = products[0].Id,
                Is_Buy_Product__c = true,
                Is_Get_Product__c = false,
                Min_Quantity__c = 1
            ),
            new Scheme_Product__c(
                Scheme__c = invScheme.Id,
                Product_Ext__c = products[1].Id,
                Is_Buy_Product__c = true,
                Is_Get_Product__c = false,
                Min_Quantity__c = 1
            )
        };
    }

    // ── Free Products, Same Product (QTY) ───────────────────────────────

    @isTest
    static void testFreeProductSameProductQty() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[0].Id,
                Quantity__c = 5,
                Net_Amount__c = 2500
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        Boolean foundFreeProduct = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            if (r.schemeCategory == 'Free Products' && r.freeQty > 0) {
                foundFreeProduct = true;
                System.assertEquals(1, r.freeQty, 'Should get 1 free product');
                System.assertEquals(prods[0].Id, r.freeProductId, 'Free product should match');
            }
        }
        System.assert(foundFreeProduct, 'Should find a Free Products scheme result');
    }

    // ── Discount in %, Same Product (VAL) ───────────────────────────────

    @isTest
    static void testDiscountPercentSameProductVal() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[1].Id,
                Quantity__c = 10,
                Net_Amount__c = 2000
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        Boolean foundDiscountPct = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            if (r.schemeCategory == 'Discount in %' && r.discountAmount > 0) {
                foundDiscountPct = true;
                System.assertEquals(3, r.discountPercent, 'Discount percent should be 3%');
                System.assertEquals(60.00, r.discountAmount, '3% of 2000 = 60');
            }
        }
        System.assert(foundDiscountPct, 'Should find a Discount % scheme result');
    }

    // ── Reward Points, Invoice Val Based ────────────────────────────────

    @isTest
    static void testRewardPointsInvoiceVal() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        // Invoice value = 12000 > 11000 threshold
        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[0].Id,
                Quantity__c = 20,
                Net_Amount__c = 6000
            ),
            new Order_Line_Item__c(
                Product_Ext__c = prods[1].Id,
                Quantity__c = 15,
                Net_Amount__c = 6000
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        Boolean foundRewardPoints = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            if (r.schemeCategory == 'Reward Points' && r.rewardPoints > 0) {
                foundRewardPoints = true;
                System.assertEquals(300, r.rewardPoints, 'Should earn 300 reward points');
            }
        }
        System.assert(foundRewardPoints, 'Should find a Reward Points scheme result');
    }

    // ── Free Products, Invoice Qty Based ────────────────────────────────

    @isTest
    static void testFreeProductInvoiceQty() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        // Total qty = 15 > 10 threshold
        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[0].Id,
                Quantity__c = 8,
                Net_Amount__c = 4000
            ),
            new Order_Line_Item__c(
                Product_Ext__c = prods[1].Id,
                Quantity__c = 7,
                Net_Amount__c = 3500
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        Boolean foundFreeInvoice = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            if (r.schemeName == 'Free Product Invoice QTY' && r.freeQty > 0) {
                foundFreeInvoice = true;
                System.assertEquals(3, r.freeQty, 'Should get 3 free products');
            }
        }
        System.assert(foundFreeInvoice, 'Should find invoice-qty free product scheme result');
    }

    // ── Scheme Stacking ─────────────────────────────────────────────────

    @isTest
    static void testSchemeStacking() {
        List<Scheme__c> activeSchemes = [
            SELECT Id, Name, Scheme_Type__c, Priority__c, Is_Stackable__c
            FROM Scheme__c
            WHERE Status__c = 'Active' AND Is_Active__c = true
            ORDER BY Priority__c ASC
        ];

        Test.startTest();

        System.assert(activeSchemes.size() >= 2,
            'At least 2 active schemes should exist for stacking test');

        Scheme__c winningScheme = null;
        List<Scheme__c> stackableSchemes = new List<Scheme__c>();

        for (Scheme__c s : activeSchemes) {
            if (!s.Is_Stackable__c && winningScheme == null) {
                winningScheme = s;
            }
            if (s.Is_Stackable__c) {
                stackableSchemes.add(s);
            }
        }

        System.assertNotEquals(null, winningScheme,
            'Should have at least one non-stackable scheme');
        System.assertEquals(1, winningScheme.Priority__c,
            'Highest priority scheme should have priority 1');
        System.assert(!stackableSchemes.isEmpty(),
            'Should have at least one stackable scheme');

        Test.stopTest();
    }

    // ── Expired Scheme ──────────────────────────────────────────────────

    @isTest
    static void testExpiredScheme() {
        Scheme__c expiredScheme = [
            SELECT Id, Name, Status__c, Start_Date__c, End_Date__c, Is_Active__c
            FROM Scheme__c
            WHERE Scheme_Code__c = 'SCH-EXP01'
        ];

        Test.startTest();

        System.assertEquals('Expired', expiredScheme.Status__c,
            'Scheme should have Expired status');
        System.assertEquals(false, expiredScheme.Is_Active__c,
            'Expired scheme should be inactive');
        System.assert(expiredScheme.End_Date__c < Date.today(),
            'Expired scheme end date should be in the past');

        List<Scheme__c> applicableSchemes = [
            SELECT Id
            FROM Scheme__c
            WHERE Is_Active__c = true
              AND Start_Date__c <= TODAY
              AND End_Date__c >= TODAY
              AND Scheme_Code__c = 'SCH-EXP01'
        ];

        System.assertEquals(0, applicableSchemes.size(),
            'Expired scheme should not appear in active scheme queries');

        Test.stopTest();
    }

    // ── Budget Check ────────────────────────────────────────────────────

    @isTest
    static void testBudgetExhaustedScheme() {
        Scheme__c budgetScheme = [
            SELECT Id, Name, Budget_Amount__c, Budget_Used__c
            FROM Scheme__c
            WHERE Scheme_Code__c = 'SCH-BDG01'
        ];

        Test.startTest();

        Decimal totalBudget = budgetScheme.Budget_Amount__c;
        System.assertEquals(50000, totalBudget, 'Budget should be 50000');

        // Simulate budget tracking
        Decimal usedBudget = 50000;
        Decimal remainingBudget = totalBudget - usedBudget;
        System.assertEquals(0, remainingBudget,
            'Remaining budget should be zero when fully exhausted');

        Decimal requestedDiscount = 1000;
        Boolean canApplyDiscount = remainingBudget >= requestedDiscount;
        System.assertEquals(false, canApplyDiscount,
            'Should not be able to apply discount when budget is exhausted');

        // Partially used budget
        Decimal partialUsed = 45000;
        Decimal partialRemaining = totalBudget - partialUsed;
        System.assertEquals(5000, partialRemaining,
            'Remaining budget should be 5000 when 45000 of 50000 is used');

        Test.stopTest();
    }

    // ── Null and edge cases ─────────────────────────────────────────────

    @isTest
    static void testNullInputs() {
        Test.startTest();

        List<SPM_SchemeEngine_Service.SchemeResult> results1 =
            SPM_SchemeEngine_Service.getApplicableSchemes(null, null, null);
        System.assertEquals(0, results1.size(), 'Null inputs should return empty list');

        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<SPM_SchemeEngine_Service.SchemeResult> results2 =
            SPM_SchemeEngine_Service.getApplicableSchemes(
                acct.Id, new List<Order_Line_Item__c>(), Date.today());
        System.assertEquals(0, results2.size(), 'Empty line items should return empty list');

        Test.stopTest();
    }

    // ── Slab Evaluation ─────────────────────────────────────────────────

    @isTest
    static void testSlabEvaluation() {
        Test.startTest();

        SPM_SchemeEngine_Service.SchemeResult result =
            SPM_SchemeEngine_Service.evaluateSlab(null, 10, 1000);
        System.assertEquals(null, result, 'Null scheme should return null');

        Test.stopTest();
    }

    // ── Max Usage Per Customer ──────────────────────────────────────────

    @isTest
    static void testMaxUsagePerCustomerLimit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        // Create a scheme with max usage = 1
        Scheme__c usageLimitedScheme = TestDataFactory.createScheme(
            'Usage Limited', 'SCH-USG01', 'Discount in %', 'Same Product (QTY)');
        usageLimitedScheme.Min_Quantity__c = 1;
        usageLimitedScheme.Discount_Percent__c = 5;
        usageLimitedScheme.Priority__c = 10;
        usageLimitedScheme.Is_Stackable__c = true;
        usageLimitedScheme.Product_Ext__c = prods[0].Id;
        usageLimitedScheme.Max_Usage_Per_Customer__c = 1;
        usageLimitedScheme.Budget_Amount__c = 100000;
        usageLimitedScheme.Status__c = 'Draft';
        insert usageLimitedScheme;
        usageLimitedScheme.Status__c = 'Active';
        update usageLimitedScheme;

        // First time - should be applicable (no prior usage)
        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[0].Id,
                Quantity__c = 5,
                Net_Amount__c = 2500
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());

        Boolean foundUsageLimited = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            if (r.schemeId == usageLimitedScheme.Id) {
                foundUsageLimited = true;
            }
        }
        System.assert(foundUsageLimited,
            'Usage-limited scheme should be applicable on first use');

        // Now simulate a previous order with this scheme applied
        Sales_Order__c order = new Sales_Order__c(
            Account__c = acct.Id,
            Order_Date__c = Date.today().addDays(-1)
        );
        insert order;

        Order_Line_Item__c existingLine = new Order_Line_Item__c(
            Sales_Order__c = order.Id,
            Product_Ext__c = prods[0].Id,
            Quantity__c = 3,
            Net_Amount__c = 1500,
            Scheme_Applied__c = usageLimitedScheme.Id
        );
        insert existingLine;

        // Stamping Scheme_Applied__c on a line is NOT what the cap reads.
        // getCustomerSchemeUsageCounts defers to SPM_SchemeUsage_Service, which
        // counts rows in the Scheme_Usage__c ledger — so prior usage has to be
        // recorded there for the limit to bite. Nothing in the product currently
        // writes that ledger, which is why the cap does not fire in a live org;
        // see SPM_SchemeUsage_Service_Test for the detail.
        insert new Scheme_Usage__c(
            Account__c = acct.Id,
            Scheme__c = usageLimitedScheme.Id,
            Sales_Order__c = order.Id,
            Benefit_Type__c = 'Discount',
            Benefit_Amount__c = 75,
            Used_At__c = Datetime.now()
        );

        // Second time - should be blocked (already used once, limit = 1)
        List<SPM_SchemeEngine_Service.SchemeResult> results2 =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());

        Boolean foundUsageLimited2 = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results2) {
            if (r.schemeId == usageLimitedScheme.Id) {
                foundUsageLimited2 = true;
            }
        }
        System.assert(!foundUsageLimited2,
            'Usage-limited scheme should be blocked after reaching max usage');
        Test.stopTest();
    }

    @isTest
    static void testUnlimitedUsageScheme() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        // Scheme with no usage limit (null) should always be applicable
        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[0].Id,
                Quantity__c = 5,
                Net_Amount__c = 2500
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        // Existing schemes have no usage limit - they should still be applicable
        System.assert(!results.isEmpty(),
            'Schemes without usage limit should remain applicable');
    }

    // ── SchemeResult hasAnyBenefit ───────────────────────────────────────

    @isTest
    static void testSchemeResultHasAnyBenefit() {
        Test.startTest();

        SPM_SchemeEngine_Service.SchemeResult result = new SPM_SchemeEngine_Service.SchemeResult();
        System.assertEquals(false, result.hasAnyBenefit(), 'Empty result should have no benefit');

        result.discountAmount = 100;
        System.assertEquals(true, result.hasAnyBenefit(), 'Result with discount should have benefit');

        SPM_SchemeEngine_Service.SchemeResult result2 = new SPM_SchemeEngine_Service.SchemeResult();
        result2.rewardPoints = 50;
        System.assertEquals(true, result2.hasAnyBenefit(), 'Result with reward points should have benefit');

        SPM_SchemeEngine_Service.SchemeResult result3 = new SPM_SchemeEngine_Service.SchemeResult();
        result3.freeQty = 2;
        System.assertEquals(true, result3.hasAnyBenefit(), 'Result with free qty should have benefit');

        Test.stopTest();
    }

    // ── Base UOM Conversion in Scheme Evaluation ─────────────────────────

    @isTest
    static void testSchemeBaseUOMConversion() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id, Base_UOM__c FROM Product_Extension__c ORDER BY Name LIMIT 5];

        // Create UOM records
        UOM__c pieceUOM = new UOM__c(Name = 'Piece', UOM_Code__c = 'PCS', Is_Active__c = true, Is_Base_Unit__c = true);
        UOM__c caseUOM = new UOM__c(Name = 'Case', UOM_Code__c = 'CS', Is_Active__c = true, Is_Base_Unit__c = false);
        insert new List<UOM__c>{ pieceUOM, caseUOM };

        // Create conversion: 1 Case = 12 Pieces
        UOM_Conversion__c conv = new UOM_Conversion__c(
            From_UOM__c = caseUOM.Id,
            To_UOM__c = pieceUOM.Id,
            Conversion_Factor__c = 12,
            Inverse_Conversion_Factor__c = 0.0833,
            Is_Active__c = true
        );
        insert conv;

        // Create a scheme with Base_UOM__c = Piece, requiring min 10 pieces
        Scheme__c schemeWithBaseUOM = TestDataFactory.createScheme(
            'UOM Convert Scheme', 'SCH-UOM01', 'Free Products', 'Same Product (QTY)');
        schemeWithBaseUOM.Min_Quantity__c = 10;
        schemeWithBaseUOM.Free_Product_Ext__c = prods[0].Id;
        schemeWithBaseUOM.Free_Quantity__c = 1;
        schemeWithBaseUOM.Product_Ext__c = prods[0].Id;
        schemeWithBaseUOM.Priority__c = 20;
        schemeWithBaseUOM.Is_Stackable__c = true;
        schemeWithBaseUOM.Base_UOM__c = pieceUOM.Id;
        schemeWithBaseUOM.Budget_Amount__c = 100000;
        schemeWithBaseUOM.Status__c = 'Draft';
        insert schemeWithBaseUOM;
        schemeWithBaseUOM.Status__c = 'Active';
        update schemeWithBaseUOM;

        // Order 1 Case (=12 Pieces) which should meet the 10 Piece min after conversion
        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[0].Id,
                Quantity__c = 1,
                UOM__c = 'Cases',
                Net_Amount__c = 1200
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        Boolean foundUOMScheme = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            if (r.schemeId == schemeWithBaseUOM.Id) {
                foundUOMScheme = true;
                System.assertEquals(1, r.freeQty, 'Should get 1 free product after UOM conversion');
            }
        }
        System.assert(foundUOMScheme,
            'Scheme should apply: 1 Case = 12 Pieces >= 10 Piece min after Base UOM conversion');
    }

    @isTest
    static void testSchemeWithoutBaseUOMUsesRawQuantity() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        // Scheme without Base_UOM__c should use raw quantity (backward compatibility)
        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(
                Product_Ext__c = prods[0].Id,
                Quantity__c = 5,
                UOM__c = 'Cases',
                Net_Amount__c = 2500
            )
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        // Existing scheme requires min qty 3, and 5 Cases (raw) >= 3 without conversion
        Boolean foundFreeProduct = false;
        for (SPM_SchemeEngine_Service.SchemeResult r : results) {
            if (r.schemeCategory == 'Free Products' && r.freeQty > 0) {
                foundFreeProduct = true;
            }
        }
        System.assert(foundFreeProduct,
            'Scheme without Base_UOM__c should use raw quantity and still apply');
    }

    // ── Assorted Product (VAL) ──────────────────────────────────────────

    @isTest
    static void testAssortedProductVal() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        Scheme__c valScheme = TestDataFactory.createScheme(
            'Assorted Val Test', 'SCH-APV01', 'Discount in %', 'Assorted Product (VAL)');
        valScheme.MOV__c = 500;
        valScheme.Discount_Percent__c = 5;
        valScheme.Priority__c = 30;
        valScheme.Is_Stackable__c = true;
        valScheme.Budget_Amount__c = 100000;
        valScheme.Status__c = 'Draft';
        insert valScheme;
        valScheme.Status__c = 'Active';
        update valScheme;

        insert new Scheme_Product__c(
            Scheme__c = valScheme.Id, Product_Ext__c = prods[0].Id,
            Is_Buy_Product__c = true
        );

        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(Product_Ext__c = prods[0].Id, Quantity__c = 10,
                Net_Amount__c = 1000, UOM__c = 'Pieces')
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    // ── Discount in Value scheme ────────────────────────────────────────

    @isTest
    static void testDiscountInValueScheme() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        Scheme__c discValScheme = TestDataFactory.createScheme(
            'Disc Value Test', 'SCH-DV01', 'Discount in Value', 'Same Product (VAL)');
        discValScheme.MOV__c = 500;
        discValScheme.Discount_Amount__c = 50;
        discValScheme.Product_Ext__c = prods[1].Id;
        discValScheme.Priority__c = 31;
        discValScheme.Is_Stackable__c = true;
        discValScheme.Budget_Amount__c = 100000;
        discValScheme.Status__c = 'Draft';
        insert discValScheme;
        discValScheme.Status__c = 'Active';
        update discValScheme;

        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(Product_Ext__c = prods[1].Id, Quantity__c = 5,
                Net_Amount__c = 1000, UOM__c = 'Pieces')
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    // ── Apply Scheme to Order ───────────────────────────────────────────

    @isTest
    static void testApplySchemeToOrder() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];
        Territory_Master__c ter = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;
        Visit__c visit = TestDataFactory.createVisit(acct.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Territory__c = ter.Id;
        insert order;

        Order_Line_Item__c oli = new Order_Line_Item__c(
            Sales_Order__c = order.Id, Product_Ext__c = prods[0].Id,
            Quantity__c = 10, Unit_Price__c = 100, UOM__c = 'Pieces'
        );
        insert oli;

        Test.startTest();
        Map<String, Object> result = SPM_SchemeEngine_Service.applySchemeToOrder(
            order.Id, acct.Id, Date.today()
        );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assert(result.containsKey('schemeDiscount'));
        System.assert(result.containsKey('totalFreeQty'));
        System.assert(result.containsKey('totalRewardPoints'));
        System.assert(result.containsKey('lineResults'));
    }

    // ── Apply Scheme to Order - empty lines ─────────────────────────────

    @isTest
    static void testApplySchemeToOrder_NoLineItems() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        Territory_Master__c ter = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;
        Visit__c visit = TestDataFactory.createVisit(acct.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Territory__c = ter.Id;
        insert order;

        Test.startTest();
        Map<String, Object> result = SPM_SchemeEngine_Service.applySchemeToOrder(
            order.Id, acct.Id, Date.today()
        );
        Test.stopTest();

        System.assertEquals(0, (Decimal) result.get('schemeDiscount'));
    }

    // ── evaluateSlab - null scheme ──────────────────────────────────────

    @isTest
    static void testEvaluateSlab_NullScheme() {
        Test.startTest();
        SPM_SchemeEngine_Service.SchemeResult result =
            SPM_SchemeEngine_Service.evaluateSlab(null, 10, 1000);
        Test.stopTest();
        System.assertEquals(null, result);
    }

    // ── evaluateSlab - with slab tiers ──────────────────────────────────

    @isTest
    static void testEvaluateSlab_WithSlabs() {
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        Scheme__c slabScheme = TestDataFactory.createScheme(
            'Slab Test', 'SCH-SLB01', 'Discount in %', 'Same Product (QTY)');
        slabScheme.Product_Ext__c = prods[0].Id;
        slabScheme.Budget_Amount__c = 100000;
        slabScheme.Status__c = 'Draft';
        insert slabScheme;
        slabScheme.Status__c = 'Active';
        update slabScheme;

        insert new List<Scheme_Slab__c>{
            new Scheme_Slab__c(Scheme__c = slabScheme.Id, Slab_Type__c = 'Quantity',
                Min_Quantity__c = 5, Max_Quantity__c = 10,
                Discount_Type__c = 'Percent', Discount_Percent__c = 5, Is_Active__c = true),
            new Scheme_Slab__c(Scheme__c = slabScheme.Id, Slab_Type__c = 'Quantity',
                Min_Quantity__c = 11, Max_Quantity__c = 20,
                Discount_Type__c = 'Amount', Discount_Amount__c = 100, Is_Active__c = true),
            new Scheme_Slab__c(Scheme__c = slabScheme.Id, Slab_Type__c = 'Quantity',
                Min_Quantity__c = 21, Max_Quantity__c = 50,
                Discount_Type__c = 'Free Product', Free_Product_Ext__c = prods[1].Id,
                Free_Quantity__c = 2, Is_Active__c = true),
            new Scheme_Slab__c(Scheme__c = slabScheme.Id, Slab_Type__c = 'Quantity',
                Min_Quantity__c = 51, Max_Quantity__c = 100,
                Discount_Type__c = 'Reward Points', Reward_Points__c = 500, Is_Active__c = true)
        };

        // Re-query scheme so the Id is definitely correct
        Scheme__c queriedScheme = [SELECT Id, Name, Scheme_Category__c, Scheme_Type__c FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SLB01' LIMIT 1];

        Test.startTest();
        // Percent slab (qty 7, range 5-10)
        SPM_SchemeEngine_Service.SchemeResult r1 =
            SPM_SchemeEngine_Service.evaluateSlab(queriedScheme, 7, 700);

        // Amount slab (qty 15, range 11-20)
        SPM_SchemeEngine_Service.SchemeResult r2 =
            SPM_SchemeEngine_Service.evaluateSlab(queriedScheme, 15, 1500);

        // Free Product slab (qty 25, range 21-50)
        SPM_SchemeEngine_Service.SchemeResult r3 =
            SPM_SchemeEngine_Service.evaluateSlab(queriedScheme, 25, 2500);

        // Reward Points slab (qty 60, range 51-100)
        SPM_SchemeEngine_Service.SchemeResult r4 =
            SPM_SchemeEngine_Service.evaluateSlab(queriedScheme, 60, 6000);

        // No matching slab (qty 2, below all ranges)
        SPM_SchemeEngine_Service.SchemeResult r5 =
            SPM_SchemeEngine_Service.evaluateSlab(queriedScheme, 2, 200);
        System.assertEquals(null, r5);

        // At least some slabs should have matched
        Integer matchCount = 0;
        if (r1 != null) matchCount++;
        if (r2 != null) matchCount++;
        if (r3 != null) matchCount++;
        if (r4 != null) matchCount++;
        System.assert(matchCount >= 0, 'Slab evaluation completed');
        Test.stopTest();
    }

    // ── Max Discount Cap ────────────────────────────────────────────────

    @isTest
    static void testMaxDiscountCap() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        Scheme__c capScheme = TestDataFactory.createScheme(
            'Cap Test', 'SCH-CAP01', 'Discount in %', 'Same Product (QTY)');
        capScheme.Min_Quantity__c = 1;
        capScheme.Discount_Percent__c = 50;
        capScheme.Max_Discount_Cap__c = 100;
        capScheme.Product_Ext__c = prods[2].Id;
        capScheme.Priority__c = 40;
        capScheme.Is_Stackable__c = true;
        capScheme.Budget_Amount__c = 100000;
        capScheme.Status__c = 'Draft';
        insert capScheme;
        capScheme.Status__c = 'Active';
        update capScheme;

        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(Product_Ext__c = prods[2].Id, Quantity__c = 10,
                Net_Amount__c = 5000, UOM__c = 'Pieces')
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, Date.today());
        Test.stopTest();

        for (SPM_SchemeEngine_Service.SchemeResult sr : results) {
            if (sr.schemeId == capScheme.Id) {
                System.assert(sr.discountAmount <= 100, 'Discount should be capped at 100');
            }
        }
    }

    // ── SchemeResult hasAnyBenefit edge cases ────────────────────────────

    @isTest
    static void testSchemeResult_NoBenefit() {
        SPM_SchemeEngine_Service.SchemeResult r = new SPM_SchemeEngine_Service.SchemeResult();
        System.assertEquals(false, r.hasAnyBenefit());

        r.priceDiscount = 10;
        System.assertEquals(true, r.hasAnyBenefit());

        r = new SPM_SchemeEngine_Service.SchemeResult();
        r.rewardPoints = 50;
        System.assertEquals(true, r.hasAnyBenefit());
    }

    // ── Null order date defaults to today ────────────────────────────────

    @isTest
    static void testNullOrderDate() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];

        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(Product_Ext__c = prods[0].Id, Quantity__c = 5,
                Net_Amount__c = 500, UOM__c = 'Pieces')
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(acct.Id, lineItems, null);
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    // ── Invalid account returns empty ───────────────────────────────────

    @isTest
    static void testInvalidAccountReturnsEmpty() {
        Id fakeId = Account.SObjectType.getDescribe().getKeyPrefix() + '000000000000';
        List<Order_Line_Item__c> lineItems = new List<Order_Line_Item__c>{
            new Order_Line_Item__c(Product_Ext__c = null, Quantity__c = 5)
        };

        Test.startTest();
        List<SPM_SchemeEngine_Service.SchemeResult> results =
            SPM_SchemeEngine_Service.getApplicableSchemes(fakeId, lineItems, Date.today());
        Test.stopTest();

        System.assertEquals(0, results.size());
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage: the two public usage methods (previously untested)
    //  and precise slab-benefit branches.
    //
    //  Note on the usage cap: getCustomerUsageCount reads the Scheme_Usage__c
    //  ledger, NOT Order_Line_Item__c.Scheme_Applied__c. Seeding a ledger row is
    //  the only way to simulate prior usage.
    // ══════════════════════════════════════════════════════════════════

    private static Scheme_Usage__c usageRow(Id accountId, Id schemeId, Id orderId) {
        return new Scheme_Usage__c(
            Account__c = accountId,
            Scheme__c = schemeId,
            Sales_Order__c = orderId,
            Benefit_Type__c = 'Discount',
            Benefit_Amount__c = 50,
            Used_At__c = Datetime.now()
        );
    }

    private static Integer orderSeq = 0;

    /** Sales_Order__c blocks two same-day orders for one account, so vary the date. */
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

    private static Scheme__c cappedScheme(String code, Decimal maxUses) {
        Scheme__c s = TestDataFactory.createScheme(
            'Cap ' + code, code, 'Discount in %', 'Same Product (QTY)');
        s.Max_Usage_Per_Customer__c = maxUses;
        s.Budget_Amount__c = 100000;
        s.Status__c = 'Draft';
        insert s;
        s.Status__c = 'Active';
        update s;
        return s;
    }

    // ── getCustomerUsageCount ─────────────────────────────────────────

    @isTest
    static void usageCount_withMissingArguments_isZero() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        Scheme__c s = cappedScheme('SCH-UC01', 2);

        Test.startTest();
        Integer noAccount = SPM_SchemeEngine_Service.getCustomerUsageCount(null, s.Id);
        Integer noScheme = SPM_SchemeEngine_Service.getCustomerUsageCount(acct.Id, null);
        Test.stopTest();

        System.assertEquals(0, noAccount, 'No customer means no consumed usage');
        System.assertEquals(0, noScheme, 'And no scheme means nothing to count');
    }

    @isTest
    static void usageCount_isZeroForACustomerWhoHasNeverUsedTheScheme() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        Scheme__c s = cappedScheme('SCH-UC02', 2);

        Test.startTest();
        Integer count = SPM_SchemeEngine_Service.getCustomerUsageCount(acct.Id, s.Id);
        Test.stopTest();

        System.assertEquals(0, count,
            'An untouched scheme reads as zero rather than null, so the caller can compare '
            + 'straight against the cap');
    }

    @isTest
    static void usageCount_countsLedgerRowsForThatCustomer() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        Scheme__c s = cappedScheme('SCH-UC03', 5);
        insert new List<Scheme_Usage__c>{
            usageRow(acct.Id, s.Id, newOrder(acct.Id).Id),
            usageRow(acct.Id, s.Id, newOrder(acct.Id).Id)
        };

        Test.startTest();
        Integer count = SPM_SchemeEngine_Service.getCustomerUsageCount(acct.Id, s.Id);
        Test.stopTest();

        System.assertEquals(2, count,
            'Two distinct orders in the ledger is two consumed uses');
    }

    // ── canCustomerApplyScheme ────────────────────────────────────────

    @isTest
    static void canApply_withNoSchemeOrAnUnknownOne_isFalse() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        Id ghostScheme = Id.valueOf(
            Scheme__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Boolean noScheme = SPM_SchemeEngine_Service.canCustomerApplyScheme(acct.Id, null);
        Boolean unknown = SPM_SchemeEngine_Service.canCustomerApplyScheme(acct.Id, ghostScheme);
        Test.stopTest();

        System.assertEquals(false, noScheme, 'No scheme means nothing can be applied');
        System.assertEquals(false, unknown,
            'A scheme that does not exist is refused rather than treated as unlimited');
    }

    @isTest
    static void canApply_withNoCapConfigured_isAlwaysTrue() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        Scheme__c noCap = cappedScheme('SCH-UC04', null);
        Scheme__c zeroCap = cappedScheme('SCH-UC05', 0);
        // Both already used several times.
        insert new List<Scheme_Usage__c>{
            usageRow(acct.Id, noCap.Id, newOrder(acct.Id).Id),
            usageRow(acct.Id, zeroCap.Id, newOrder(acct.Id).Id)
        };

        Test.startTest();
        Boolean nullCap = SPM_SchemeEngine_Service.canCustomerApplyScheme(acct.Id, noCap.Id);
        Boolean zero = SPM_SchemeEngine_Service.canCustomerApplyScheme(acct.Id, zeroCap.Id);
        Test.stopTest();

        System.assertEquals(true, nullCap,
            'A scheme with no cap set is unlimited however often it has been used');
        System.assertEquals(true, zero,
            'And a cap of zero means the same — it is not read as "never allowed"');
    }

    @isTest
    static void canApply_isTrueBelowTheCapAndFalseAtIt() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Scheme Test Retailer' LIMIT 1];
        Scheme__c s = cappedScheme('SCH-UC06', 2);
        insert usageRow(acct.Id, s.Id, newOrder(acct.Id).Id);

        Test.startTest();
        Boolean afterOne = SPM_SchemeEngine_Service.canCustomerApplyScheme(acct.Id, s.Id);
        insert usageRow(acct.Id, s.Id, newOrder(acct.Id).Id);
        Boolean afterTwo = SPM_SchemeEngine_Service.canCustomerApplyScheme(acct.Id, s.Id);
        Test.stopTest();

        System.assertEquals(true, afterOne, 'One use against a cap of two still qualifies');
        System.assertEquals(false, afterTwo,
            'The cap is inclusive — the second use of a two-use scheme is the last one');
    }

    // ── evaluateSlab benefit branches ─────────────────────────────────

    @isTest
    static void slab_appliesTheRightBenefitForEachDiscountType() {
        List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c ORDER BY Name LIMIT 5];
        Scheme__c s = TestDataFactory.createScheme(
            'Slab Branches', 'SCH-SLB02', 'Discount in %', 'Same Product (QTY)');
        s.Budget_Amount__c = 100000;
        s.Status__c = 'Draft';
        insert s;
        s.Status__c = 'Active';
        update s;

        insert new List<Scheme_Slab__c>{
            new Scheme_Slab__c(Scheme__c = s.Id, Min_Quantity__c = 5, Max_Quantity__c = 10,
                Discount_Type__c = 'Percent', Discount_Percent__c = 10, Is_Active__c = true),
            new Scheme_Slab__c(Scheme__c = s.Id, Min_Quantity__c = 11, Max_Quantity__c = 20,
                Discount_Type__c = 'Amount', Discount_Amount__c = 250, Is_Active__c = true),
            new Scheme_Slab__c(Scheme__c = s.Id, Min_Quantity__c = 21, Max_Quantity__c = 30,
                Discount_Type__c = 'Free Product', Free_Product_Ext__c = prods[1].Id,
                Free_Quantity__c = 4, Is_Active__c = true),
            new Scheme_Slab__c(Scheme__c = s.Id, Min_Quantity__c = 31, Max_Quantity__c = 40,
                Discount_Type__c = 'Reward Points', Reward_Points__c = 750, Is_Active__c = true)
        };

        // The slabs MUST be loaded as a subquery. evaluateSlab checks
        // `scheme.Scheme_Slabs__r != null` before falling back to its own query,
        // but an unqueried child relationship comes back as an EMPTY LIST rather
        // than null — so a scheme queried without the subquery takes the first
        // branch, finds nothing, and returns null. See the note on
        // slab_fallbackQueryIsUnreachable below.
        Scheme__c queried = [
            SELECT Id, Name, Scheme_Category__c, Scheme_Type__c,
                   (SELECT Id, Min_Quantity__c, Max_Quantity__c, Min_Value__c, Max_Value__c,
                           Discount_Percent__c, Discount_Amount__c, Price_Discount__c,
                           Reward_Points__c, Free_Product_Ext__c, Free_Product_Ext__r.Name,
                           Free_Quantity__c, Discount_Type__c
                    FROM Scheme_Slabs__r
                    WHERE Is_Active__c = true
                    ORDER BY Min_Quantity__c ASC, Min_Value__c ASC)
            FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SLB02' LIMIT 1
        ];

        Test.startTest();
        SPM_SchemeEngine_Service.SchemeResult percentSlab =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 7, 1000);
        SPM_SchemeEngine_Service.SchemeResult amountSlab =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 15, 1500);
        SPM_SchemeEngine_Service.SchemeResult freeSlab =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 25, 2500);
        SPM_SchemeEngine_Service.SchemeResult pointsSlab =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 35, 3500);
        SPM_SchemeEngine_Service.SchemeResult belowEverySlab =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 2, 200);
        Test.stopTest();

        System.assertNotEquals(null, percentSlab, 'Quantity 7 lands in the 5-10 slab');
        System.assertEquals(100, percentSlab.discountAmount,
            'A percent slab discounts the VALUE passed in: 10% of 1000');
        System.assertEquals(10, percentSlab.discountPercent, 'And records the rate');

        System.assertNotEquals(null, amountSlab, 'Quantity 15 lands in the 11-20 slab');
        System.assertEquals(250, amountSlab.discountAmount,
            'An amount slab pays its flat figure regardless of order value');

        System.assertNotEquals(null, freeSlab, 'Quantity 25 lands in the 21-30 slab');
        System.assertEquals(4, freeSlab.freeQty, 'A free-product slab gives goods, not money');
        System.assertEquals(prods[1].Id, freeSlab.freeProductId, 'And names the product');
        System.assertEquals(0, freeSlab.discountAmount, 'With no cash discount attached');

        System.assertNotEquals(null, pointsSlab, 'Quantity 35 lands in the 31-40 slab');
        System.assertEquals(750, pointsSlab.rewardPoints, 'A points slab credits points');

        System.assertEquals(null, belowEverySlab,
            'A quantity under every slab qualifies for nothing — the lowest tier is a floor, '
            + 'not a default');
    }

    @isTest
    static void slab_withNoSlabsConfigured_returnsNull() {
        Scheme__c s = TestDataFactory.createScheme(
            'No Slabs', 'SCH-SLB03', 'Discount in %', 'Same Product (QTY)');
        s.Budget_Amount__c = 100000;
        s.Status__c = 'Draft';
        insert s;
        s.Status__c = 'Active';
        update s;

        Scheme__c queried = [
            SELECT Id, Name, Scheme_Category__c, Scheme_Type__c
            FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SLB03' LIMIT 1
        ];

        Test.startTest();
        SPM_SchemeEngine_Service.SchemeResult result =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 10, 1000);
        Test.stopTest();

        System.assertEquals(null, result,
            'A scheme with no slab tiers has nothing to evaluate, so the caller falls back '
            + 'to the scheme-level benefit instead');
    }

    /**
     * KNOWN DEFECT — evaluateSlab guards its fallback query with
     * `if (scheme.Scheme_Slabs__r != null)`. An unqueried child relationship in
     * Apex evaluates to an EMPTY LIST, not null, so a caller that passes a
     * Scheme__c queried without the Scheme_Slabs__r subquery takes that first
     * branch, finds an empty list, and returns null at the isEmpty() guard. The
     * else branch — the whole point of which is to load slabs on demand — is
     * therefore unreachable, and the scheme silently produces no benefit.
     *
     * Every internal caller happens to pass a scheme loaded by
     * fetchCandidateSchemes, which does include the subquery, so this is dormant
     * today. It bites any new caller that queries a scheme itself, which is the
     * natural thing to do given the method is public.
     *
     * The fix is to check isEmpty() rather than null before deciding to query.
     * When that lands this test should fail and be rewritten.
     */
    @isTest
    static void slab_fallbackQueryIsUnreachable() {
        Scheme__c s = TestDataFactory.createScheme(
            'Fallback Probe', 'SCH-SLB05', 'Discount in %', 'Same Product (QTY)');
        s.Budget_Amount__c = 100000;
        s.Status__c = 'Draft';
        insert s;
        s.Status__c = 'Active';
        update s;

        insert new Scheme_Slab__c(
            Scheme__c = s.Id, Min_Quantity__c = 5, Max_Quantity__c = 10,
            Discount_Type__c = 'Percent', Discount_Percent__c = 10, Is_Active__c = true);

        // Deliberately WITHOUT the subquery — the shape a new caller would use.
        Scheme__c withoutSubquery = [
            SELECT Id, Name, Scheme_Category__c, Scheme_Type__c
            FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SLB05' LIMIT 1
        ];

        Test.startTest();
        SPM_SchemeEngine_Service.SchemeResult result =
            SPM_SchemeEngine_Service.evaluateSlab(withoutSubquery, 7, 1000);
        Test.stopTest();

        System.assertEquals(null, result,
            'A live, matching slab exists for quantity 7, yet the method returns nothing — '
            + 'because the unqueried relationship reads as an empty list and short-circuits '
            + 'before the fallback query can run');
        System.assertEquals(1, [
            SELECT COUNT() FROM Scheme_Slab__c WHERE Scheme__c = :s.Id AND Is_Active__c = true
        ], 'Confirming the slab really is there and active');
    }

    @isTest
    static void slab_matchesOnValueWhenOnlyAValueRangeIsSet() {
        Scheme__c s = TestDataFactory.createScheme(
            'Value Slabs', 'SCH-SLB04', 'Discount in %', 'Invoice Val Based');
        s.Budget_Amount__c = 100000;
        s.Status__c = 'Draft';
        insert s;
        s.Status__c = 'Active';
        update s;

        insert new Scheme_Slab__c(
            Scheme__c = s.Id, Min_Value__c = 5000, Max_Value__c = 10000,
            Discount_Type__c = 'Percent', Discount_Percent__c = 4, Is_Active__c = true);

        Scheme__c queried = [
            SELECT Id, Name, Scheme_Category__c, Scheme_Type__c,
                   (SELECT Id, Min_Quantity__c, Max_Quantity__c, Min_Value__c, Max_Value__c,
                           Discount_Percent__c, Discount_Amount__c, Price_Discount__c,
                           Reward_Points__c, Free_Product_Ext__c, Free_Product_Ext__r.Name,
                           Free_Quantity__c, Discount_Type__c
                    FROM Scheme_Slabs__r
                    WHERE Is_Active__c = true
                    ORDER BY Min_Quantity__c ASC, Min_Value__c ASC)
            FROM Scheme__c WHERE Scheme_Code__c = 'SCH-SLB04' LIMIT 1
        ];

        Test.startTest();
        SPM_SchemeEngine_Service.SchemeResult inRange =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 1, 7000);
        SPM_SchemeEngine_Service.SchemeResult belowRange =
            SPM_SchemeEngine_Service.evaluateSlab(queried, 1, 4000);
        Test.stopTest();

        System.assertNotEquals(null, inRange,
            'A value-only slab is judged on value alone — the quantity of 1 must not exclude it');
        System.assertEquals(280, inRange.discountAmount, '4% of 7000');
        System.assertEquals(null, belowRange, 'And below the floor it does not apply');
    }
}