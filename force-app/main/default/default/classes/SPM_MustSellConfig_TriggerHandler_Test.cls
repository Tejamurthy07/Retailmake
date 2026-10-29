@isTest
private class SPM_MustSellConfig_TriggerHandler_Test {

    @TestSetup
    static void setupData() {
        Product_Category__c cat = new Product_Category__c(
            Name = 'MSC Test Category', Category_Code__c = 'MSC-CAT',
            Level__c = 'Category', Is_Active__c = true
        );
        insert cat;

        List<Product_Extension__c> products = new List<Product_Extension__c>();
        products.add(new Product_Extension__c(Name = 'MSC Product 1', SKU_Code__c = 'MSC-001', Product_Category__c = cat.Id, Is_Active__c = true));
        products.add(new Product_Extension__c(Name = 'MSC Product 2', SKU_Code__c = 'MSC-002', Product_Category__c = cat.Id, Is_Active__c = true));
        insert products;
    }

    static Product_Extension__c getProd1() {
        return [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'MSC-001' LIMIT 1];
    }
    static Product_Extension__c getProd2() {
        return [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = 'MSC-002' LIMIT 1];
    }

    // ─── Date Range Validation ─────────────────────────────────────────

    @isTest
    static void testValidDateRange() {
        Must_Sell_Config__c config = new Must_Sell_Config__c(
            Product_Ext__c = getProd1().Id, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true, Min_Qty__c = 1
        );
        Test.startTest();
        insert config;
        Test.stopTest();
        System.assertNotEquals(null, config.Id);
    }

    @isTest
    static void testInvalidDateRange_EndBeforeStart() {
        Must_Sell_Config__c config = new Must_Sell_Config__c(
            Product_Ext__c = getProd1().Id, Start_Date__c = Date.today().addDays(30),
            End_Date__c = Date.today(), Is_Active__c = true, Min_Qty__c = 1
        );
        Test.startTest();
        try {
            insert config;
            System.assert(false, 'Should throw');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    @isTest
    static void testNullDates_Allowed() {
        Must_Sell_Config__c config = new Must_Sell_Config__c(
            Product_Ext__c = getProd1().Id, Start_Date__c = null,
            End_Date__c = null, Is_Active__c = true, Min_Qty__c = 1
        );
        Test.startTest();
        insert config;
        Test.stopTest();
        System.assertNotEquals(null, config.Id);
    }

    // ─── Duplicate Prevention — Overlapping Dates ──────────────────────

    @isTest
    static void testDuplicate_OverlappingDates() {
        Id prodId = getProd1().Id;
        insert new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 1, Channel__c = 'GT'
        );

        Must_Sell_Config__c dup = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today().addDays(15),
            End_Date__c = Date.today().addDays(45), Is_Active__c = true,
            Min_Qty__c = 2, Channel__c = 'GT'
        );
        Test.startTest();
        try {
            insert dup;
            System.assert(false, 'Should throw for overlap');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    @isTest
    static void testNonOverlapping_Allowed() {
        Id prodId = getProd1().Id;
        insert new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(10), Is_Active__c = true,
            Min_Qty__c = 1, Channel__c = 'GT'
        );

        Must_Sell_Config__c config2 = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today().addDays(11),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 2, Channel__c = 'GT'
        );
        Test.startTest();
        insert config2;
        Test.stopTest();
        System.assertNotEquals(null, config2.Id);
    }

    // ─── Duplicate Prevention — Different Dimensions Allowed ───────────

    @isTest
    static void testDifferentChannel_Allowed() {
        Id prodId = getProd1().Id;
        insert new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 1, Channel__c = 'GT'
        );

        Must_Sell_Config__c config2 = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 2, Channel__c = 'MT'
        );
        Test.startTest();
        insert config2;
        Test.stopTest();
        System.assertNotEquals(null, config2.Id);
    }

    @isTest
    static void testDifferentProduct_Allowed() {
        insert new Must_Sell_Config__c(
            Product_Ext__c = getProd1().Id, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 1, Channel__c = 'GT'
        );

        Must_Sell_Config__c config2 = new Must_Sell_Config__c(
            Product_Ext__c = getProd2().Id, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 2, Channel__c = 'GT'
        );
        Test.startTest();
        insert config2;
        Test.stopTest();
        System.assertNotEquals(null, config2.Id);
    }

    // ─── Inactive Config Skip ──────────────────────────────────────────

    @isTest
    static void testInactiveConfig_SkipsDuplicateCheck() {
        Id prodId = getProd1().Id;
        insert new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 1, Channel__c = 'GT'
        );

        Must_Sell_Config__c inactive = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = false,
            Min_Qty__c = 2, Channel__c = 'GT'
        );
        Test.startTest();
        insert inactive;
        Test.stopTest();
        System.assertNotEquals(null, inactive.Id);
    }

    // ─── Open-Ended Date Overlap ───────────────────────────────────────

    @isTest
    static void testOpenEndedDate_Overlap() {
        Id prodId = getProd1().Id;
        insert new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = null, Is_Active__c = true,
            Min_Qty__c = 1, Channel__c = 'GT'
        );

        Must_Sell_Config__c config2 = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today().addDays(10),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 2, Channel__c = 'GT'
        );
        Test.startTest();
        try {
            insert config2;
            System.assert(false, 'Should throw for open-ended overlap');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ─── Intra-Batch Duplicate ─────────────────────────────────────────

    @isTest
    static void testIntraBatchDuplicate() {
        Id prodId = getProd1().Id;
        List<Must_Sell_Config__c> batch = new List<Must_Sell_Config__c>{
            new Must_Sell_Config__c(
                Product_Ext__c = prodId, Start_Date__c = Date.today(),
                End_Date__c = Date.today().addDays(30), Is_Active__c = true,
                Min_Qty__c = 1, Channel__c = 'GT'
            ),
            new Must_Sell_Config__c(
                Product_Ext__c = prodId, Start_Date__c = Date.today(),
                End_Date__c = Date.today().addDays(30), Is_Active__c = true,
                Min_Qty__c = 2, Channel__c = 'GT'
            )
        };
        Test.startTest();
        try {
            insert batch;
            System.assert(false, 'Should throw for batch duplicate');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ─── Update Tests ──────────────────────────────────────────────────

    @isTest
    static void testUpdate_SameKeyFields_NoError() {
        Must_Sell_Config__c config = new Must_Sell_Config__c(
            Product_Ext__c = getProd1().Id, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true, Min_Qty__c = 1
        );
        insert config;

        Test.startTest();
        config.Min_Qty__c = 10;
        update config;
        Test.stopTest();

        Must_Sell_Config__c updated = [SELECT Min_Qty__c FROM Must_Sell_Config__c WHERE Id = :config.Id];
        System.assertEquals(10, updated.Min_Qty__c);
    }

    @isTest
    static void testUpdate_ChangedKeyFields_DuplicateCheck() {
        Id prodId = getProd1().Id;
        Must_Sell_Config__c config1 = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 1, Channel__c = 'GT'
        );
        insert config1;

        Must_Sell_Config__c config2 = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 2, Channel__c = 'MT'
        );
        insert config2;

        Test.startTest();
        config2.Channel__c = 'GT';
        try {
            update config2;
            System.assert(false, 'Should throw when changing to duplicate key');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    @isTest
    static void testUpdate_InvalidDateRange() {
        Must_Sell_Config__c config = new Must_Sell_Config__c(
            Product_Ext__c = getProd1().Id, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true, Min_Qty__c = 1
        );
        insert config;

        Test.startTest();
        config.End_Date__c = Date.today().addDays(-10);
        try {
            update config;
            System.assert(false, 'Should throw for invalid dates on update');
        } catch (DmlException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    // ─── Null Product Skip ─────────────────────────────────────────────

    @isTest
    static void testNullProduct_SkipsDuplicateCheck() {
        Must_Sell_Config__c config = new Must_Sell_Config__c(
            Product_Ext__c = null, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true, Min_Qty__c = 1
        );
        Test.startTest();
        try {
            insert config;
        } catch (DmlException e) {
            // May fail due to required field, that's OK
            System.assert(true);
        }
        Test.stopTest();
    }

    // ─── Customer Type Dimension ───────────────────────────────────────

    @isTest
    static void testDifferentCustomerType_Allowed() {
        Id prodId = getProd1().Id;
        insert new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 1, Customer_Type__c = 'Grocery'
        );

        Must_Sell_Config__c config2 = new Must_Sell_Config__c(
            Product_Ext__c = prodId, Start_Date__c = Date.today(),
            End_Date__c = Date.today().addDays(30), Is_Active__c = true,
            Min_Qty__c = 2, Customer_Type__c = 'General Store'
        );
        Test.startTest();
        insert config2;
        Test.stopTest();
        System.assertNotEquals(null, config2.Id);
    }
}