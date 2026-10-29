/**
 * @description Test class for OutletThreeSixtyController.
 *              Tests all 360-degree view methods including outlet details, KPIs,
 *              orders, collections, visits, schemes, stock, credit, and timeline.
 *
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class OutletThreeSixtyController_Test {

    @TestSetup
    static void setupTestData() {
        // Create Territory
        Territory_Master__c territory = new Territory_Master__c(
            Name = 'Test Territory',
            Territory_Code__c = 'TER-TEST-001',
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        insert territory;

        // Create Beat
        Beat__c beat = new Beat__c(
            Name = 'Test Beat',
            Beat_Code__c = 'BT-TEST-001',
            Territory__c = territory.Id,
            Frequency__c = 'Weekly',
            Is_Active__c = true,
            Day_of_Week__c = 'Monday'
        );
        insert beat;

        // Create Account
        Account acc = new Account(
            Name = 'Test Outlet 360',
            Outlet_Type__c = 'Grocery',
            Outlet_Class__c = 'A',
            Channel__c = 'GT',
            GSTIN__c = '27AABCU9603R1ZM',
            PAN__c = 'AABCU9603R',
            Credit_Limit__c = 100000,
            Credit_Utilized__c = 25000,
            Outstanding_Balance__c = 25000,
            Beat__c = beat.Id,
            Territory__c = territory.Id,
            Is_Active__c = true,
            BillingStreet = '123 Test Street',
            BillingCity = 'Mumbai',
            BillingState = 'Maharashtra',
            BillingPostalCode = '400001',
            BillingLatitude = 19.076,
            BillingLongitude = 72.877,
            Phone = '9876543210',
            Owner_Name__c = 'Test Owner'
        );
        insert acc;

        // Create Sales Orders
        Sales_Order__c order1 = new Sales_Order__c(
            Account__c = acc.Id,
            Order_Date__c = Date.today(),
            Status__c = 'Submitted',
            Total_Net_Amount__c = 15000,
            Total_Items__c = 5,
            Channel__c = 'Field App',
            Territory__c = territory.Id
        );
        Sales_Order__c order2 = new Sales_Order__c(
            Account__c = acc.Id,
            Order_Date__c = Date.today().addDays(-5),
            Status__c = 'Delivered',
            Total_Net_Amount__c = 20000,
            Total_Items__c = 8,
            Channel__c = 'Field App',
            Territory__c = territory.Id
        );
        insert new List<Sales_Order__c>{ order1, order2 };

        // Create Visit
        Visit__c visit = new Visit__c(
            Account__c = acc.Id,
            Visit_Date__c = Date.today(),
            Check_In_Time__c = DateTime.now().addHours(-2),
            Check_Out_Time__c = DateTime.now().addHours(-1),
            Duration_Minutes__c = 60,
            Visit_Status__c = 'Completed',
            Is_Productive__c = true,
            Is_Planned__c = true,
            Order_Value__c = 15000,
            Beat__c = beat.Id
        );
        insert visit;

        // Create Collection
        Collection__c col = new Collection__c(
            Account__c = acc.Id,
            Collection_Date__c = Date.today(),
            Amount__c = 10000,
            Payment_Mode__c = 'Cash',
            Status__c = 'Collected',
            Receipt_Number__c = 'RCP-001'
        );
        insert col;

        // Create Invoice
        Invoice__c inv = new Invoice__c(
            Account__c = acc.Id,
            Sales_Order__c = order1.Id,
            Invoice_Date__c = Date.today(),
            Due_Date__c = Date.today().addDays(30),
            Total_Amount__c = 15000,
            Balance_Due__c = 5000,
            Status__c = 'Confirmed'
        );
        insert inv;

        // Create Distributor Stock
        Distributor_Stock__c stock = new Distributor_Stock__c(
            Account__c = acc.Id,
            Stock_Date__c = Date.today(),
            Opening_Stock__c = 100,
            Received_Qty__c = 50,
            Sold_Qty__c = 30,
            Damaged_Qty__c = 2,
            Closing_Stock__c = 118,
            Batch_No__c = 'BATCH-001',
            Expiry_Date__c = Date.today().addMonths(6),
            Is_Current__c = true
        );
        insert stock;

        // Create Scheme
        Scheme__c scheme = new Scheme__c(
            Name = 'Test Scheme',
            Scheme_Code__c = 'SCH-TEST-001',
            Scheme_Type__c = 'Same Product (QTY)',
            Scheme_Category__c = 'Discount in %',
            Description__c = '10% off on all products',
            Start_Date__c = Date.today().addDays(-10),
            End_Date__c = Date.today().addDays(20),
            Status__c = 'Draft',
            Applicable_Channel__c = 'GT',
            Budget_Amount__c = 50000,
            Budget_Used__c = 10000,
            Max_Discount_Cap__c = 5000
        );
        insert scheme;
        scheme.Status__c = 'Active';
        update scheme;
    }

    // ── Get Outlet Details ───────────────────────────────────────────────

    @IsTest
    static void testGetOutletDetails_Success() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        Account result = OutletThreeSixtyController.getOutletDetails(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Outlet 360', result.Name);
        System.assertEquals('A', result.Outlet_Class__c);
        System.assertEquals('GT', result.Channel__c);
        System.assertEquals('27AABCU9603R1ZM', result.GSTIN__c);
        System.assertEquals('AABCU9603R', result.PAN__c);
        System.assertEquals('Test Owner', result.Owner_Name__c);
        System.assertEquals(100000, result.Credit_Limit__c);
        System.assertNotEquals(null, result.Beat__r, 'Beat relationship should be populated');
        System.assertNotEquals(null, result.Territory__r, 'Territory relationship should be populated');
    }

    @IsTest
    static void testGetOutletDetails_NotFound() {
        // Use a fabricated Account Id that won't exist
        Id fakeId = Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001';

        Test.startTest();
        try {
            OutletThreeSixtyController.getOutletDetails(fakeId);
            System.assert(false, 'Should have thrown AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Should have an error message');
        }
        Test.stopTest();
    }

    // ── Get Outlet KPIs ──────────────────────────────────────────────────

    @IsTest
    static void testGetOutletKPIs() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        Map<String, Object> kpis = OutletThreeSixtyController.getOutletKPIs(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, kpis, 'KPIs should not be null');
        System.assert(kpis.containsKey('mtdOrderCount'), 'Should contain mtdOrderCount');
        System.assert(kpis.containsKey('mtdOrderValue'), 'Should contain mtdOrderValue');
        System.assert(kpis.containsKey('mtdVisitCount'), 'Should contain mtdVisitCount');
        System.assert(kpis.containsKey('mtdCollection'), 'Should contain mtdCollection');
        System.assert(kpis.containsKey('outstandingBalance'), 'Should contain outstandingBalance');
        System.assert(kpis.containsKey('overdueAmount'), 'Should contain overdueAmount');
        System.assert(kpis.containsKey('creditLimit'), 'Should contain creditLimit');
        System.assert(kpis.containsKey('creditUtilized'), 'Should contain creditUtilized');
        System.assert(kpis.containsKey('creditAvailable'), 'Should contain creditAvailable');
        System.assert(kpis.containsKey('creditUtilizationPct'), 'Should contain creditUtilizationPct');
        System.assert(kpis.containsKey('avgOrderValue'), 'Should contain avgOrderValue');
        System.assert(kpis.containsKey('lastOrderDate'), 'Should contain lastOrderDate');
        System.assert(kpis.containsKey('lastVisitDate'), 'Should contain lastVisitDate');

        // Verify MTD order values
        Integer orderCount = (Integer)kpis.get('mtdOrderCount');
        System.assert(orderCount >= 1, 'Should have at least 1 MTD order');

        Decimal mtdOrderValue = (Decimal)kpis.get('mtdOrderValue');
        System.assert(mtdOrderValue > 0, 'MTD order value should be positive');

        // Verify credit
        Decimal creditLimit = (Decimal)kpis.get('creditLimit');
        System.assertEquals(100000, creditLimit, 'Credit limit should be 100000');
    }

    // ── Get Recent Orders ────────────────────────────────────────────────

    @IsTest
    static void testGetRecentOrders() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<Sales_Order__c> orders = OutletThreeSixtyController.getRecentOrders(acc.Id, 10);
        Test.stopTest();

        System.assertEquals(2, orders.size(), 'Should return 2 orders');
        // Orders should be sorted by date DESC
        System.assert(orders[0].Order_Date__c >= orders[1].Order_Date__c, 'Orders should be sorted by date DESC');
    }

    @IsTest
    static void testGetRecentOrders_DefaultLimit() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<Sales_Order__c> orders = OutletThreeSixtyController.getRecentOrders(acc.Id, null);
        Test.stopTest();

        System.assert(orders.size() <= 10, 'Default limit should be 10');
    }

    @IsTest
    static void testGetRecentOrders_MaxLimitCapped() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<Sales_Order__c> orders = OutletThreeSixtyController.getRecentOrders(acc.Id, 500);
        Test.stopTest();

        // Should not throw, limit is internally capped at 100
        System.assertNotEquals(null, orders);
    }

    // ── Get Collection History ───────────────────────────────────────────

    @IsTest
    static void testGetCollectionHistory() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<Collection__c> collections = OutletThreeSixtyController.getCollectionHistory(acc.Id, 20);
        Test.stopTest();

        System.assertEquals(1, collections.size(), 'Should return 1 collection');
        System.assertEquals(10000, collections[0].Amount__c, 'Collection amount should be 10000');
        System.assertEquals('Cash', collections[0].Payment_Mode__c, 'Payment mode should be Cash');
    }

    // ── Get Visit History ────────────────────────────────────────────────

    @IsTest
    static void testGetVisitHistory() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<Visit__c> visits = OutletThreeSixtyController.getVisitHistory(acc.Id, 20);
        Test.stopTest();

        System.assertEquals(1, visits.size(), 'Should return 1 visit');
        System.assertEquals('Completed', visits[0].Visit_Status__c);
        System.assertEquals(true, visits[0].Is_Productive__c);
        System.assertEquals(60, visits[0].Duration_Minutes__c);
    }

    // ── Get Applicable Schemes ───────────────────────────────────────────

    @IsTest
    static void testGetApplicableSchemes() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<Scheme__c> schemes = OutletThreeSixtyController.getApplicableSchemes(acc.Id);
        Test.stopTest();

        System.assertEquals(1, schemes.size(), 'Should return 1 applicable scheme');
        System.assertEquals('Test Scheme', schemes[0].Name);
        System.assertEquals('Same Product (QTY)', schemes[0].Scheme_Type__c);
    }

    @IsTest
    static void testGetApplicableSchemes_InvalidAccount() {
        Id fakeId = Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001';

        Test.startTest();
        List<Scheme__c> schemes = OutletThreeSixtyController.getApplicableSchemes(fakeId);
        Test.stopTest();

        System.assertEquals(0, schemes.size(), 'Should return empty list for invalid account');
    }

    // ── Get Stock Levels ─────────────────────────────────────────────────

    @IsTest
    static void testGetStockLevels() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<Distributor_Stock__c> stock = OutletThreeSixtyController.getStockLevels(acc.Id);
        Test.stopTest();

        System.assertEquals(1, stock.size(), 'Should return 1 stock record');
        System.assertEquals(118, stock[0].Closing_Stock__c);
        System.assertEquals('BATCH-001', stock[0].Batch_No__c);
        System.assertEquals(true, stock[0].Is_Current__c);
    }

    // ── Get Credit Utilization ───────────────────────────────────────────

    @IsTest
    static void testGetCreditUtilization() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        Map<String, Decimal> credit = OutletThreeSixtyController.getCreditUtilization(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, credit, 'Credit map should not be null');
        System.assertEquals(100000, credit.get('creditLimit'));
        System.assertEquals(25000, credit.get('creditUtilized'));
        System.assertEquals(75000, credit.get('creditAvailable'));
        System.assertEquals(25.0, credit.get('utilizationPct'));
    }

    @IsTest
    static void testGetCreditUtilization_InvalidAccount() {
        Id fakeId = Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001';

        Test.startTest();
        Map<String, Decimal> credit = OutletThreeSixtyController.getCreditUtilization(fakeId);
        Test.stopTest();

        System.assertEquals(0, credit.get('creditLimit'));
        System.assertEquals(0, credit.get('creditUtilized'));
    }

    // ── Get Account Timeline ─────────────────────────────────────────────

    @IsTest
    static void testGetAccountTimeline() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<OutletThreeSixtyController.TimelineEntry> timeline =
            OutletThreeSixtyController.getAccountTimeline(acc.Id, 30);
        Test.stopTest();

        // Should have orders + visits + collections = at least 4 entries
        System.assert(timeline.size() >= 4, 'Timeline should have at least 4 entries (2 orders + 1 visit + 1 collection). Got: ' + timeline.size());

        // Verify sorted by date descending
        for (Integer i = 0; i < timeline.size() - 1; i++) {
            if (timeline[i].activityDate != null && timeline[i + 1].activityDate != null) {
                System.assert(timeline[i].activityDate >= timeline[i + 1].activityDate,
                    'Timeline should be sorted by date descending');
            }
        }

        // Verify entry types
        Set<String> types = new Set<String>();
        for (OutletThreeSixtyController.TimelineEntry entry : timeline) {
            types.add(entry.activityType);
            System.assertNotEquals(null, entry.recordId, 'Entry should have a recordId');
            System.assertNotEquals(null, entry.title, 'Entry should have a title');
        }
        System.assert(types.contains('Order'), 'Timeline should contain Order entries');
        System.assert(types.contains('Visit'), 'Timeline should contain Visit entries');
        System.assert(types.contains('Collection'), 'Timeline should contain Collection entries');
    }

    @IsTest
    static void testGetAccountTimeline_DefaultLimit() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Outlet 360' LIMIT 1];

        Test.startTest();
        List<OutletThreeSixtyController.TimelineEntry> timeline =
            OutletThreeSixtyController.getAccountTimeline(acc.Id, null);
        Test.stopTest();

        System.assert(timeline.size() <= 30, 'Default limit should be 30');
    }

    // ── TimelineEntry Comparable Test ────────────────────────────────────

    @IsTest
    static void testTimelineEntryComparable() {
        OutletThreeSixtyController.TimelineEntry entry1 = new OutletThreeSixtyController.TimelineEntry(
            null, 'Order', 'Test1', 'Desc1', Date.today(), 100, 'Submitted', 'standard:orders'
        );
        OutletThreeSixtyController.TimelineEntry entry2 = new OutletThreeSixtyController.TimelineEntry(
            null, 'Visit', 'Test2', 'Desc2', Date.today().addDays(-1), 200, 'Completed', 'standard:visit'
        );
        OutletThreeSixtyController.TimelineEntry entry3 = new OutletThreeSixtyController.TimelineEntry(
            null, 'Collection', 'Test3', 'Desc3', null, 300, 'Collected', 'standard:currency'
        );

        // entry1 is newer, should come first (return -1)
        System.assertEquals(-1, entry1.compareTo(entry2));
        // entry2 is older, should come after (return 1)
        System.assertEquals(1, entry2.compareTo(entry1));
        // null dates go last
        System.assertEquals(-1, entry1.compareTo(entry3));
        System.assertEquals(1, entry3.compareTo(entry1));
        // same date
        System.assertEquals(0, entry1.compareTo(entry1));
    }
}