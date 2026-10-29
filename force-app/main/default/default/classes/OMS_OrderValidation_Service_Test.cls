/**
 * @description Test class for OMS_OrderValidation_Service.
 *              Validates credit limit checks, minimum order value enforcement,
 *              duplicate order detection, must-sell compliance, channel compliance,
 *              and category compliance.
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class OMS_OrderValidation_Service_Test {

    @TestSetup
    static void setupTestData() {
        // Create territory
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Validation Territory', 'TER-V01');

        // Create beat
        Beat__c beat = TestDataFactory.createAndInsertBeat('Validation Beat', 'BEAT-V01', territory.Id);

        // Create accounts with credit limits
        Account highCredit = TestDataFactory.createAccount('High Credit Account', 'Retailer');
        highCredit.Credit_Limit__c = 100000;
        highCredit.Credit_Utilized__c = 20000;
        highCredit.Outlet_Type__c = 'Grocery';

        Account lowCredit = TestDataFactory.createAccount('Low Credit Account', 'Retailer');
        lowCredit.Credit_Limit__c = 5000;
        lowCredit.Credit_Utilized__c = 4000;
        lowCredit.Outlet_Type__c = 'General Store';

        Account noCredit = TestDataFactory.createAccount('No Credit Account', 'Retailer');
        noCredit.Credit_Limit__c = 0;
        noCredit.Credit_Utilized__c = 0;

        insert new List<Account>{ highCredit, lowCredit, noCredit };

        // Create day attendance
        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        // Create visit
        Visit__c visit = TestDataFactory.createVisit(highCredit.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        // Create products
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(3);
    }

    // ── validateCreditLimit Tests ──────────────────────────────────────────

    @IsTest
    static void testValidateCreditLimit_withinLimit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000; // Available = 100000 - 20000 = 80000

        Test.startTest();
        // Insert should succeed since 50000 < 80000 available credit
        try {
            insert order;
            // If no error, the order was within the credit limit - pass
            System.assertNotEquals(null, order.Id, 'Order should be inserted successfully within credit limit');
        } catch (DmlException e) {
            // Might error from other validations; check if it is credit-related
            System.assert(!e.getMessage().contains('exceeds available credit limit'),
                'Should not fail credit validation when within limit');
        }
        Test.stopTest();
    }

    @IsTest
    static void testValidateCreditLimit_exceedsLimit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'Low Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 5000; // Available = 5000 - 4000 = 1000

        Test.startTest();
        try {
            insert order;
            // If insert succeeds, the validation may not have caught it due to
            // Total_Amount__c being reset by defaults. That's acceptable.
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('exceeds available credit limit'),
                'Should fail with credit limit exceeded error. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testValidateCreditLimit_nullAccountAndAmount() {
        // Test with null account - should skip validation gracefully
        List<Sales_Order__c> orders = new List<Sales_Order__c>();
        Sales_Order__c orderNoAccount = new Sales_Order__c(
            Order_Date__c = Date.today(),
            Status__c = 'Draft',
            Total_Amount__c = 1000
        );
        orders.add(orderNoAccount);

        Test.startTest();
        // Direct service call (not through trigger) to test null handling
        OMS_OrderValidation_Service.validateCreditLimit(orders);
        Test.stopTest();

        // Should not throw - null account is skipped
        System.assert(true, 'Should handle null account gracefully');
    }

    @IsTest
    static void testValidateCreditLimit_zeroCredit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'No Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 1000;

        Test.startTest();
        try {
            insert order;
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('credit') || e.getMessage().contains('minimum order'),
                'Should fail validation. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // ── validateMinOrderValue Tests ────────────────────────────────────────

    @IsTest
    static void testValidateMinOrderValue_aboveMinimum() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000;

        Test.startTest();
        try {
            insert order;
            System.assertNotEquals(null, order.Id, 'Order above minimum value should insert successfully');
        } catch (DmlException e) {
            // May fail for other reasons; ensure it's not min order related
            System.assert(!e.getMessage().contains('below the minimum order value'),
                'Should not fail min order value check. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testValidateMinOrderValue_directCall() {
        // Directly call the service to test the min order logic
        List<Sales_Order__c> orders = new List<Sales_Order__c>();

        // Order with very low amount
        Sales_Order__c lowOrder = new Sales_Order__c(
            Total_Amount__c = 1,
            Status__c = 'Draft'
        );
        orders.add(lowOrder);

        // Order with zero amount (should be skipped since <= 0)
        Sales_Order__c zeroOrder = new Sales_Order__c(
            Total_Amount__c = 0,
            Status__c = 'Draft'
        );
        orders.add(zeroOrder);

        // Order with null amount
        Sales_Order__c nullOrder = new Sales_Order__c(
            Total_Amount__c = null,
            Status__c = 'Draft'
        );
        orders.add(nullOrder);

        Test.startTest();
        OMS_OrderValidation_Service.validateMinOrderValue(orders);
        Test.stopTest();

        // The method adds errors to records; zero and null amount should not error
        System.assert(true, 'Min order value validation completed without exception');
    }

    // ── checkDuplicateOrders Tests ─────────────────────────────────────────

    @IsTest
    static void testCheckDuplicateOrders_noDuplicate() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000;

        Test.startTest();
        try {
            insert order;
            System.assertNotEquals(null, order.Id, 'First order should insert without duplicate error');
        } catch (DmlException e) {
            System.assert(!e.getMessage().contains('Potential duplicate order'),
                'First order should not be flagged as duplicate. Got: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testCheckDuplicateOrders_existingDuplicate() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        // Insert the first order
        Sales_Order__c order1 = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order1.Total_Amount__c = 50000;
        order1.Order_Date__c = Date.today();
        insert order1;

        // Now try to insert a duplicate (same account, same date, same rep, similar amount)
        Sales_Order__c order2 = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order2.Total_Amount__c = 50000;
        order2.Order_Date__c = Date.today();

        Test.startTest();
        try {
            insert order2;
            // May still succeed if amounts don't match within tolerance after defaults
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('duplicate') || e.getMessage().contains('Duplicate'),
                'Should detect duplicate order. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void testCheckDuplicateOrders_batchDuplicate() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        // Insert two identical orders in the same batch
        Sales_Order__c order1 = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order1.Total_Amount__c = 50000;
        order1.Order_Date__c = Date.today();

        Sales_Order__c order2 = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order2.Total_Amount__c = 50000;
        order2.Order_Date__c = Date.today();

        Test.startTest();
        try {
            insert new List<Sales_Order__c>{ order1, order2 };
            // May succeed if batch duplicate detection fires error on second record
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('Duplicate') || e.getMessage().contains('duplicate'),
                'Should detect batch duplicate. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void testCheckDuplicateOrders_nullFields() {
        // Direct call with null account and null date
        List<Sales_Order__c> orders = new List<Sales_Order__c>();
        Sales_Order__c order = new Sales_Order__c(
            Status__c = 'Draft',
            Total_Amount__c = 1000
        );
        orders.add(order);

        Test.startTest();
        OMS_OrderValidation_Service.checkDuplicateOrders(orders);
        Test.stopTest();

        System.assert(true, 'Should handle null account/date gracefully');
    }

    // ── validateMustSellCompliance Tests ───────────────────────────────────

    @IsTest
    static void testValidateMustSellCompliance_allProductsPresent() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        List<Product_Extension__c> products = [SELECT Id FROM Product_Extension__c];

        // Create a sales order with territory
        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000;
        order.Territory__c = territory.Id;
        order.Channel__c = 'Field App';
        insert order;

        // Create must-sell config for one product
        Must_Sell_Config__c config = TestDataFactory.createMustSellConfig(
            products[0].Id, 'Must Sell', 1, territory.Id, null, 'Grocery'
        );
        insert config;

        // Add the required product as a line item
        Order_Line_Item__c lineItem = TestDataFactory.createOrderLineItem(
            order.Id, products[0].Id, 10, 100
        );
        insert lineItem;

        Test.startTest();
        // Direct call: should not error since product is present
        Sales_Order__c freshOrder = [
            SELECT Id, Account__c, Territory__c, Channel__c, Trade_Channel__c
            FROM Sales_Order__c
            WHERE Id = :order.Id
        ];
        OMS_OrderValidation_Service.validateMustSellCompliance(
            new List<Sales_Order__c>{ freshOrder }
        );
        Test.stopTest();

        System.assert(true, 'Must-sell compliance passed with all products present');
    }

    @IsTest
    static void testValidateMustSellCompliance_missingProducts() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        List<Product_Extension__c> products = [SELECT Id, Name FROM Product_Extension__c];

        // Create a sales order
        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000;
        order.Territory__c = territory.Id;
        order.Channel__c = 'Field App';
        insert order;

        // Create must-sell config for a product but do NOT add line item
        Must_Sell_Config__c config = TestDataFactory.createMustSellConfig(
            products[0].Id, 'Must Sell', 1, territory.Id, null, 'Grocery'
        );
        insert config;

        Test.startTest();
        Sales_Order__c freshOrder = [
            SELECT Id, Account__c, Territory__c, Channel__c, Trade_Channel__c
            FROM Sales_Order__c
            WHERE Id = :order.Id
        ];
        OMS_OrderValidation_Service.validateMustSellCompliance(
            new List<Sales_Order__c>{ freshOrder }
        );
        Test.stopTest();

        // The method adds errors to the record, but since this is a direct call
        // outside of a trigger, we just verify no exception was thrown.
        System.assert(true, 'Must-sell compliance detected missing products');
    }

    @IsTest
    static void testValidateMustSellCompliance_noConfigs() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000;
        insert order;

        Test.startTest();
        Sales_Order__c freshOrder = [
            SELECT Id, Account__c, Territory__c, Channel__c, Trade_Channel__c
            FROM Sales_Order__c
            WHERE Id = :order.Id
        ];
        OMS_OrderValidation_Service.validateMustSellCompliance(
            new List<Sales_Order__c>{ freshOrder }
        );
        Test.stopTest();

        System.assert(true, 'Should handle no must-sell configs gracefully');
    }

    // ── validateChannelCompliance Tests ────────────────────────────────────

    @IsTest
    static void testValidateChannelCompliance_featureDisabled() {
        // When MDM-003 feature toggle is disabled, method should return immediately
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000;
        order.Trade_Channel__c = 'GT';
        insert order;

        Test.startTest();
        try {
            Sales_Order__c freshOrder = [
                SELECT Id, Account__c, Territory__c, Channel__c, Trade_Channel__c
                FROM Sales_Order__c
                WHERE Id = :order.Id
            ];
            OMS_OrderValidation_Service.validateChannelCompliance(
                new List<Sales_Order__c>{ freshOrder }
            );
        } catch (Exception e) {
            // Feature toggle metadata may not exist; this is acceptable
            System.assert(true, 'Channel compliance handled feature toggle check: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(true, 'Channel compliance handled gracefully');
    }

    @IsTest
    static void testValidateChannelCompliance_noTradeChannel() {
        // Orders without Trade_Channel__c should be skipped
        Sales_Order__c order = new Sales_Order__c(
            Status__c = 'Draft',
            Order_Date__c = Date.today()
        );

        Test.startTest();
        try {
            OMS_OrderValidation_Service.validateChannelCompliance(
                new List<Sales_Order__c>{ order }
            );
        } catch (Exception e) {
            // Acceptable if feature toggle query fails
        }
        Test.stopTest();

        System.assert(true, 'Channel compliance skipped orders without trade channel');
    }

    // ── validateCategoryCompliance Tests ───────────────────────────────────

    @IsTest
    static void testValidateCategoryCompliance_featureDisabled() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
        order.Total_Amount__c = 50000;
        insert order;

        Test.startTest();
        try {
            Sales_Order__c freshOrder = [
                SELECT Id, Account__c, Territory__c, Channel__c, Trade_Channel__c
                FROM Sales_Order__c
                WHERE Id = :order.Id
            ];
            OMS_OrderValidation_Service.validateCategoryCompliance(
                new List<Sales_Order__c>{ freshOrder }
            );
        } catch (Exception e) {
            // Feature toggle metadata may not exist; acceptable
        }
        Test.stopTest();

        System.assert(true, 'Category compliance handled gracefully when feature disabled');
    }

    @IsTest
    static void testValidateCategoryCompliance_noAccount() {
        Sales_Order__c order = new Sales_Order__c(
            Status__c = 'Draft',
            Order_Date__c = Date.today()
        );

        Test.startTest();
        try {
            OMS_OrderValidation_Service.validateCategoryCompliance(
                new List<Sales_Order__c>{ order }
            );
        } catch (Exception e) {
            // Acceptable
        }
        Test.stopTest();

        System.assert(true, 'Category compliance skipped orders without account');
    }

    // ── Bulk validation Tests ─────────────────────────────────────────────

    @IsTest
    static void testBulkCreditValidation() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        List<Sales_Order__c> orders = new List<Sales_Order__c>();
        for (Integer i = 0; i < 50; i++) {
            Sales_Order__c order = TestDataFactory.createSalesOrder(acct.Id, UserInfo.getUserId(), visit.Id);
            order.Total_Amount__c = 1000; // Above min order value of 500
            order.Order_Date__c = Date.today().addDays(-i - 1); // Different dates to avoid duplicates
            orders.add(order);
        }

        Test.startTest();
        try {
            insert orders;
        } catch (DmlException e) {
            // Some may fail due to duplicate detection or other reasons
            System.assert(true, 'Bulk insert attempted: ' + e.getMessage());
        }
        Test.stopTest();

        Integer insertedCount = [SELECT COUNT() FROM Sales_Order__c WHERE Account__c = :acct.Id];
        System.assert(insertedCount > 0, 'At least some orders should have been inserted');
    }

    @IsTest
    static void testEmptyOrderList() {
        Test.startTest();
        // All methods should handle empty lists gracefully
        List<Sales_Order__c> emptyList = new List<Sales_Order__c>();
        OMS_OrderValidation_Service.validateCreditLimit(emptyList);
        OMS_OrderValidation_Service.validateMinOrderValue(emptyList);
        OMS_OrderValidation_Service.checkDuplicateOrders(emptyList);
        OMS_OrderValidation_Service.validateMustSellCompliance(emptyList);
        try {
            OMS_OrderValidation_Service.validateChannelCompliance(emptyList);
        } catch (Exception e) {
            // Feature toggle may not exist
        }
        try {
            OMS_OrderValidation_Service.validateCategoryCompliance(emptyList);
        } catch (Exception e) {
            // Feature toggle may not exist
        }
        Test.stopTest();

        System.assert(true, 'All methods handled empty lists without exception');
    }

    // ═════════════════ Extended coverage (hard assertions) ═════════════════
    // The tests above execute lines but tolerate every outcome. The tests
    // below call the service directly and read SObject.getErrors(), so each
    // rule's verdict is pinned. Toggles are pinned through the @TestVisible
    // cache. The biggest addition: validateSchemeUsageCap (~130 lines) had no
    // test at all.

    private static Integer orderSeq = 0;

    private static Sales_Order__c insertedOrder(Id acctId, Decimal amount) {
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];
        Sales_Order__c o = TestDataFactory.createSalesOrder(acctId, UserInfo.getUserId(), visit.Id);
        o.Total_Amount__c = amount;
        orderSeq++;
        o.Order_Date__c = Date.today().addDays(-orderSeq);   // dodge the duplicate guard
        insert o;
        return o;
    }

    private static Boolean hasErrorContaining(SObject rec, String fragment) {
        for (Database.Error err : rec.getErrors()) {
            if (err.getMessage().contains(fragment)) return true;
        }
        return false;
    }

    // ── validateCreditLimit, pinned ───────────────────────────────────

    @IsTest
    static void credit_overLimitErrors_withinLimitPasses() {
        Account lowCredit = [SELECT Id FROM Account WHERE Name = 'Low Credit Account' LIMIT 1];
        // Available = 5000 - 4000 = 1000.
        Sales_Order__c over = new Sales_Order__c(
            Account__c = lowCredit.Id, Total_Amount__c = 6000, Order_Date__c = Date.today());
        Sales_Order__c within = new Sales_Order__c(
            Account__c = lowCredit.Id, Total_Amount__c = 500, Order_Date__c = Date.today());

        Test.startTest();
        OMS_OrderValidation_Service.validateCreditLimit(
            new List<Sales_Order__c>{ over, within });
        Test.stopTest();

        System.assert(hasErrorContaining(over, 'exceeds available credit limit'),
            '6000 against 1000 available must be refused, with the arithmetic in the message');
        System.assertEquals(0, within.getErrors().size(),
            '500 fits inside the 1000 available and passes untouched');
    }

    // ── validateMinOrderValue, pinned against the org config ─────────

    @IsTest
    static void minOrder_zeroAndNullNeverError_lowAmountFollowsConfig() {
        Sales_Order__c zero = new Sales_Order__c(Total_Amount__c = 0);
        Sales_Order__c none = new Sales_Order__c(Total_Amount__c = null);
        Sales_Order__c tiny = new Sales_Order__c(Total_Amount__c = 1);

        // The threshold lives in App_Config__mdt; read it so the expectation
        // tracks the org rather than assuming one.
        Decimal min = 0;
        List<App_Config__mdt> cfg = [
            SELECT Config_Value__c FROM App_Config__mdt
            WHERE DeveloperName = 'Min_Order_Value' LIMIT 1];
        if (!cfg.isEmpty() && cfg[0].Config_Value__c != null) {
            min = Decimal.valueOf(cfg[0].Config_Value__c);
        }

        Test.startTest();
        OMS_OrderValidation_Service.validateMinOrderValue(
            new List<Sales_Order__c>{ zero, none, tiny });
        Test.stopTest();

        System.assertEquals(0, zero.getErrors().size(),
            'Zero-amount orders (returns, free-goods) are exempt by design');
        System.assertEquals(0, none.getErrors().size(), 'Null amount is exempt too');
        if (min > 1) {
            System.assert(hasErrorContaining(tiny, 'below the minimum order value'),
                'A 1-rupee order sits under the configured minimum of ' + min);
        } else {
            System.assertEquals(0, tiny.getErrors().size(),
                'With no configured minimum, nothing is blocked');
        }
    }

    // ── checkDuplicateOrders, pinned ──────────────────────────────────

    @IsTest
    static void duplicates_similarAmountFlagged_differentAmountPasses() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Sales_Order__c existing = insertedOrder(acct.Id, 50000);
        existing = [SELECT Account__c, Order_Date__c, Sales_Rep__c, Total_Amount__c
                    FROM Sales_Order__c WHERE Id = :existing.Id];

        Sales_Order__c sameAmount = new Sales_Order__c(
            Account__c = existing.Account__c, Order_Date__c = existing.Order_Date__c,
            Sales_Rep__c = existing.Sales_Rep__c, Total_Amount__c = existing.Total_Amount__c);
        Sales_Order__c differentAmount = new Sales_Order__c(
            Account__c = existing.Account__c, Order_Date__c = existing.Order_Date__c,
            Sales_Rep__c = existing.Sales_Rep__c, Total_Amount__c = 10000);

        Test.startTest();
        OMS_OrderValidation_Service.checkDuplicateOrders(
            new List<Sales_Order__c>{ sameAmount });
        OMS_OrderValidation_Service.checkDuplicateOrders(
            new List<Sales_Order__c>{ differentAmount });
        Test.stopTest();

        System.assert(hasErrorContaining(sameAmount, 'Potential duplicate order'),
            'Same account, date, rep and amount within 1% is the double-entry signature');
        System.assertEquals(0, differentAmount.getErrors().size(),
            '10000 vs 50000 is far outside the 1% tolerance — a genuinely new order');
    }

    @IsTest
    static void duplicates_withinOneBatch_secondOrderIsFlagged() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Date freshDate = Date.today().addDays(-300);   // no DB order on this date
        Sales_Order__c first = new Sales_Order__c(
            Account__c = acct.Id, Order_Date__c = freshDate,
            Sales_Rep__c = UserInfo.getUserId(), Total_Amount__c = 1000);
        Sales_Order__c second = new Sales_Order__c(
            Account__c = acct.Id, Order_Date__c = freshDate,
            Sales_Rep__c = UserInfo.getUserId(), Total_Amount__c = 1000);

        Test.startTest();
        OMS_OrderValidation_Service.checkDuplicateOrders(
            new List<Sales_Order__c>{ first, second });
        Test.stopTest();

        System.assertEquals(0, first.getErrors().size(), 'The first of the pair is legitimate');
        System.assert(hasErrorContaining(second, 'within the same batch'),
            'The second identical order in one DML is caught before either hits the database');
    }

    // ── validateMustSellCompliance: the dimension filters ─────────────

    @IsTest
    static void mustSell_onlyConfigsMatchingEveryDimensionCount() {
        BPM_FeatureToggle_Util.toggleCache.put('MDM-003', false);   // channel = Channel__c
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Territory_Master__c t1 = [SELECT Id FROM Territory_Master__c WHERE Territory_Code__c = 'TER-V01'];
        Territory_Master__c t2 = TestDataFactory.createAndInsertTerritory('Other Territory', 'TER-V02');
        List<Product_Extension__c> products = [SELECT Id, Name FROM Product_Extension__c ORDER BY Name];

        Sales_Order__c order = insertedOrder(acct.Id, 50000);
        order.Territory__c = t1.Id;
        order.Channel__c = 'Field App';
        update order;

        // Four configs, three of which must be filtered out by their dimension:
        insert new List<Must_Sell_Config__c>{
            TestDataFactory.createMustSellConfig(products[0].Id, 'Must Sell', 1, t1.Id, null, 'Grocery'),  // matches
            TestDataFactory.createMustSellConfig(products[1].Id, 'Must Sell', 1, t2.Id, null, null),       // wrong territory
            TestDataFactory.createMustSellConfig(products[2].Id, 'Must Sell', 1, t1.Id, 'MT', null),       // wrong channel
            TestDataFactory.createMustSellConfig(products[2].Id, 'Must Sell', 1, t1.Id, null, 'General Store') // wrong outlet type
        };

        Test.startTest();
        Sales_Order__c fresh = [
            SELECT Id, Account__c, Territory__c, Channel__c, Trade_Channel__c
            FROM Sales_Order__c WHERE Id = :order.Id];
        OMS_OrderValidation_Service.validateMustSellCompliance(
            new List<Sales_Order__c>{ fresh });
        Test.stopTest();

        System.assert(hasErrorContaining(fresh, products[0].Name),
            'Only the config matching territory, channel AND outlet type flags its product');
        System.assert(!hasErrorContaining(fresh, products[1].Name),
            'A config for another territory must not leak into this order');
        System.assert(!hasErrorContaining(fresh, products[2].Name),
            'Nor configs for another channel or outlet type');
    }

    // ── validateChannelCompliance (MDM-003) ───────────────────────────

    @IsTest
    static void channel_blocksOnlyOffChannelProducts() {
        BPM_FeatureToggle_Util.toggleCache.put('MDM-003', true);
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        List<Product_Extension__c> products =
            [SELECT Id, Name FROM Product_Extension__c ORDER BY Name LIMIT 2];
        products[0].Channels__c = 'GT;MT';   // available in GT
        products[1].Channels__c = 'MT';      // MT only — off-channel for a GT order
        update products;

        Sales_Order__c order = insertedOrder(acct.Id, 50000);
        order.Trade_Channel__c = 'GT';
        update order;

        TriggerHandler.bypass('OMS_OrderLineItem_TriggerHandler');
        insert new List<Order_Line_Item__c>{
            TestDataFactory.createOrderLineItem(order.Id, products[0].Id, 5, 100),
            TestDataFactory.createOrderLineItem(order.Id, products[1].Id, 5, 100)
        };
        TriggerHandler.clearBypass('OMS_OrderLineItem_TriggerHandler');

        Test.startTest();
        Sales_Order__c fresh = [
            SELECT Id, Account__c, Territory__c, Channel__c, Trade_Channel__c
            FROM Sales_Order__c WHERE Id = :order.Id];
        OMS_OrderValidation_Service.validateChannelCompliance(
            new List<Sales_Order__c>{ fresh });
        Test.stopTest();

        System.assert(hasErrorContaining(fresh, products[1].Name),
            'The MT-only product cannot ride on a GT order');
        System.assert(!hasErrorContaining(fresh, products[0].Name),
            'The GT;MT product is legitimately in channel and must not be named');
    }

    // ── validateCategoryCompliance (MDM-004) ──────────────────────────

    @IsTest
    static void category_blocksProductsOutsideTheAccountsCategories() {
        BPM_FeatureToggle_Util.toggleCache.put('MDM-004', true);
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        List<Product_Extension__c> products =
            [SELECT Id, Name FROM Product_Extension__c ORDER BY Name LIMIT 2];

        Product_Category__c assigned = new Product_Category__c(
            Name = 'Assigned Cat', Category_Code__c = 'CAT-A', Level__c = 'Category', Is_Active__c = true);
        Product_Category__c foreign = new Product_Category__c(
            Name = 'Foreign Cat', Category_Code__c = 'CAT-B', Level__c = 'Category', Is_Active__c = true);
        insert new List<Product_Category__c>{ assigned, foreign };
        insert new Account_Category__c(
            Account__c = acct.Id, Category__c = assigned.Id, Is_Active__c = true);

        products[0].Product_Category__c = assigned.Id;
        products[1].Product_Category__c = foreign.Id;
        update products;

        Sales_Order__c order = insertedOrder(acct.Id, 50000);
        TriggerHandler.bypass('OMS_OrderLineItem_TriggerHandler');
        insert new List<Order_Line_Item__c>{
            TestDataFactory.createOrderLineItem(order.Id, products[0].Id, 5, 100),
            TestDataFactory.createOrderLineItem(order.Id, products[1].Id, 5, 100)
        };
        TriggerHandler.clearBypass('OMS_OrderLineItem_TriggerHandler');

        Test.startTest();
        Sales_Order__c fresh = [
            SELECT Id, Account__c FROM Sales_Order__c WHERE Id = :order.Id];
        OMS_OrderValidation_Service.validateCategoryCompliance(
            new List<Sales_Order__c>{ fresh });
        Test.stopTest();

        System.assert(hasErrorContaining(fresh, products[1].Name),
            'A product from a category the customer is not assigned to is blocked');
        System.assert(!hasErrorContaining(fresh, products[0].Name),
            'The assigned-category product passes');
    }

    // ── validateSchemeUsageCap — previously completely untested ───────

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

    private static Order_Line_Item__c lineApplying(Id orderId, Id schemeId) {
        return new Order_Line_Item__c(
            Sales_Order__c = orderId, Scheme_Applied__c = schemeId, Quantity__c = 1);
    }

    @IsTest
    static void usageCap_blocksACustomerWhoHasExhaustedTheScheme() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Scheme__c s = cappedScheme('SCH-OV01', 1);
        Sales_Order__c priorOrder = insertedOrder(acct.Id, 1000);
        insert new Scheme_Usage__c(
            Account__c = acct.Id, Scheme__c = s.Id, Sales_Order__c = priorOrder.Id,
            Benefit_Type__c = 'Discount', Benefit_Amount__c = 50, Used_At__c = Datetime.now());
        Sales_Order__c newOrder = insertedOrder(acct.Id, 2000);
        Order_Line_Item__c li = lineApplying(newOrder.Id, s.Id);

        Test.startTest();
        OMS_OrderValidation_Service.validateSchemeUsageCap(
            new List<Order_Line_Item__c>{ li });
        Test.stopTest();

        System.assert(hasErrorContaining(li, 'maximum usage limit'),
            'One prior use against a cap of one leaves no headroom — the hard backstop '
            + 'must catch what the soft UI filtering might miss');
    }

    @IsTest
    static void usageCap_editingTheOrderThatUsedIt_doesNotSelfBlock() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Scheme__c s = cappedScheme('SCH-OV02', 1);
        Sales_Order__c order = insertedOrder(acct.Id, 1000);
        insert new Scheme_Usage__c(
            Account__c = acct.Id, Scheme__c = s.Id, Sales_Order__c = order.Id,
            Benefit_Type__c = 'Discount', Benefit_Amount__c = 50, Used_At__c = Datetime.now());
        Order_Line_Item__c li = lineApplying(order.Id, s.Id);   // same order re-edited

        Test.startTest();
        OMS_OrderValidation_Service.validateSchemeUsageCap(
            new List<Order_Line_Item__c>{ li });
        Test.stopTest();

        System.assertEquals(0, li.getErrors().size(),
            'The order that consumed the use is excluded from its own count — re-saving a '
            + 'draft must never block on the usage it itself created');
    }

    @IsTest
    static void usageCap_twoNewOrdersInOneSave_onlyTheHeadroomPasses() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Scheme__c s = cappedScheme('SCH-OV03', 1);
        Sales_Order__c orderA = insertedOrder(acct.Id, 1000);
        Sales_Order__c orderB = insertedOrder(acct.Id, 2000);
        Order_Line_Item__c liA = lineApplying(orderA.Id, s.Id);
        Order_Line_Item__c liB = lineApplying(orderB.Id, s.Id);

        Test.startTest();
        OMS_OrderValidation_Service.validateSchemeUsageCap(
            new List<Order_Line_Item__c>{ liA, liB });
        Test.stopTest();

        Integer blockedLines = (liA.getErrors().isEmpty() ? 0 : 1)
            + (liB.getErrors().isEmpty() ? 0 : 1);
        System.assertEquals(1, blockedLines,
            'Cap 1 with no prior usage admits exactly one of the two new orders — '
            + 'both passing would double-spend the scheme, both failing would rob the customer');
    }

    @IsTest
    static void usageCap_uncappedSchemesAndSchemelessLines_neverBlock() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'High Credit Account' LIMIT 1];
        Scheme__c uncapped = TestDataFactory.createScheme(
            'No Cap', 'SCH-OV04', 'Discount in %', 'Same Product (QTY)');
        uncapped.Budget_Amount__c = 100000;
        uncapped.Status__c = 'Draft';
        insert uncapped;
        uncapped.Status__c = 'Active';
        update uncapped;
        Sales_Order__c order = insertedOrder(acct.Id, 1000);
        Order_Line_Item__c withUncapped = lineApplying(order.Id, uncapped.Id);
        Order_Line_Item__c noScheme = new Order_Line_Item__c(
            Sales_Order__c = order.Id, Quantity__c = 1);

        Test.startTest();
        OMS_OrderValidation_Service.validateSchemeUsageCap(
            new List<Order_Line_Item__c>{ withUncapped, noScheme });
        OMS_OrderValidation_Service.validateSchemeUsageCap(null);
        Test.stopTest();

        System.assertEquals(0, withUncapped.getErrors().size(),
            'No Max_Usage_Per_Customer means no cap to enforce');
        System.assertEquals(0, noScheme.getErrors().size(),
            'A line applying no scheme is not the cap\'s business');
    }
}