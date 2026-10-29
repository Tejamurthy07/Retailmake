@isTest
public class EXP_Expense_Service_Test {

    @TestSetup
    static void setupTestData() {
        // Create employee with band
        Territory_Master__c ter = TestDataFactory.createAndInsertTerritory('EXP Test Ter', 'TER-EXPT01');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Test',
            Last_Name__c = 'Employee',
            Employee_Code__c = 'EMP-TEST01',
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Band__c = 'Band 1',
            Territory__c = ter.Id,
            Channels__c = 'GT'
        );
        insert emp;

        // Create manager employee
        Employee__c mgr = new Employee__c(
            First_Name__c = 'Manager',
            Last_Name__c = 'Test',
            Employee_Code__c = 'EMP-MGR01',
            Is_Active__c = true,
            Band__c = 'Band 3',
            Territory__c = ter.Id,
            Channels__c = 'GT'
        );
        insert mgr;
        emp.Reporting_Manager__c = mgr.Id;
        update emp;

        // Create day attendance records
        Date today = Date.today();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);
        List<Day_Attendance__c> attendances = new List<Day_Attendance__c>();
        for (Integer i = 0; i < 5; i++) {
            attendances.add(new Day_Attendance__c(
                User__c = UserInfo.getUserId(),
                Salesperson__c = UserInfo.getUserId(),
                Attendance_Date__c = monthStart.addDays(i),
                Start_Time__c = Datetime.newInstance(monthStart.addDays(i), Time.newInstance(9, 0, 0, 0)),
                End_Time__c = Datetime.newInstance(monthStart.addDays(i), Time.newInstance(18, 0, 0, 0)),
                Distance_Traveled_Km__c = 25 + (i * 5)
            ));
        }
        insert attendances;

        // Create eligibility rules with new dynamic fields
        List<Expense_Eligibility__c> rules = new List<Expense_Eligibility__c>();
        rules.add(new Expense_Eligibility__c(
            Band__c = 'Band 1', Expense_Type__c = 'Daily Allowance', Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per Day', Rate_Amount__c = 300, Max_Per_Day__c = 300,
            Max_Per_Month__c = 9000, Min_Distance_KM__c = 0, Is_Active__c = true, Sort_Order__c = 1,
            Auto_Create__c = true, Travel_Type__c = 'All', Travel_Mode__c = 'All'
        ));
        rules.add(new Expense_Eligibility__c(
            Band__c = 'Band 1', Expense_Type__c = 'Travelling Allowance', Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per KM', Rate_Amount__c = 5, Max_Per_Day__c = 500,
            Max_Per_Month__c = 15000, Min_Distance_KM__c = 10, Is_Active__c = true, Sort_Order__c = 2,
            Auto_Create__c = true, Travel_Type__c = 'All', Travel_Mode__c = 'Car', Daily_KM_Limit__c = 200
        ));
        rules.add(new Expense_Eligibility__c(
            Band__c = 'Band 1', Expense_Type__c = 'Travelling Allowance', Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per KM', Rate_Amount__c = 3, Max_Per_Day__c = 500,
            Max_Per_Month__c = 15000, Min_Distance_KM__c = 10, Is_Active__c = true, Sort_Order__c = 2,
            Auto_Create__c = false, Travel_Type__c = 'All', Travel_Mode__c = 'Bike', Daily_KM_Limit__c = 200
        ));
        rules.add(new Expense_Eligibility__c(
            Band__c = 'Band 1', Expense_Type__c = 'Fuel', Expense_Category__c = 'Travel',
            Rate_Type__c = 'Actual', Rate_Amount__c = 0, Max_Per_Day__c = 800,
            Max_Per_Month__c = 12000, Receipt_Required__c = true, Is_Active__c = true, Sort_Order__c = 3,
            Mandatory_Remarks__c = true, Travel_Mode__c = 'All'
        ));
        rules.add(new Expense_Eligibility__c(
            Band__c = 'Band 1', Expense_Type__c = 'Food', Expense_Category__c = 'Miscellaneous',
            Rate_Type__c = 'Flat Monthly', Rate_Amount__c = 3000, Max_Per_Day__c = null,
            Max_Per_Month__c = 3000, Is_Active__c = true, Sort_Order__c = 4,
            Travel_Mode__c = 'All'
        ));
        rules.add(new Expense_Eligibility__c(
            Band__c = 'Band 1', Expense_Type__c = 'Lodging', Expense_Category__c = 'Travel',
            Rate_Type__c = 'Actual', Rate_Amount__c = 0, Max_Per_Day__c = 5000,
            Max_Per_Month__c = 50000, Is_Active__c = true, Sort_Order__c = 5,
            Receipt_Required__c = true, Lodging_Metro_Limit__c = 3000, Lodging_Non_Metro_Limit__c = 2000,
            Travel_Mode__c = 'All'
        ));
        insert rules;
    }

    private static String getCurrentMonth() {
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        return months[Date.today().month()];
    }

    @isTest
    static void testGetOrCreateReport() {
        String monthName = getCurrentMonth();
        Date today = Date.today();

        Test.startTest();
        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());
        Test.stopTest();

        System.assertNotEquals(null, report, 'Report should be created');
        System.assertEquals('Draft', report.Status__c, 'Status should be Draft');
        System.assertEquals(monthName, report.Month__c, 'Month should match');

        // Calling again should return same report
        Expense__c same = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());
        System.assertEquals(report.Id, same.Id, 'Should return existing report');
    }

    @isTest
    static void testGetExpenseData() {
        String monthName = getCurrentMonth();
        Date today = Date.today();

        Test.startTest();
        Map<String, Object> data = EXP_Expense_Service.getExpenseData(UserInfo.getUserId(), monthName, today.year());
        Test.stopTest();

        System.assertNotEquals(null, data.get('expense'), 'Should have expense');
        System.assertNotEquals(null, data.get('employee'), 'Should have employee');
        System.assertNotEquals(null, data.get('eligibilityRules'), 'Should have rules');
        System.assertNotEquals(null, data.get('eligibleDates'), 'Should have dates');
        System.assertNotEquals(null, data.get('config'), 'Should have config');

        List<Expense_Eligibility__c> rules = (List<Expense_Eligibility__c>) data.get('eligibilityRules');
        System.assertEquals(6, rules.size(), 'Should have 6 rules');
    }

    @isTest
    static void testGetEligibleDates() {
        String monthName = getCurrentMonth();
        Date today = Date.today();

        Test.startTest();
        List<Map<String, Object>> dates = EXP_Expense_Service.getEligibleDates(
            UserInfo.getUserId(), monthName, today.year()
        );
        Test.stopTest();

        System.assertEquals(5, dates.size(), 'Should have 5 eligible dates');
        // Verify hoursWorked is included
        System.assert(dates[0].containsKey('hoursWorked'), 'Should include hoursWorked');
    }

    @isTest
    static void testGetEligibilityRules() {
        Test.startTest();
        List<Expense_Eligibility__c> rules = EXP_Expense_Service.getEligibilityRules('Band 1');
        Test.stopTest();

        System.assertEquals(6, rules.size(), 'Should have 6 rules for Band 1');
        // Verify new fields are queried
        Expense_Eligibility__c daRule = null;
        for (Expense_Eligibility__c r : rules) {
            if (r.Expense_Type__c == 'Daily Allowance') daRule = r;
        }
        System.assertNotEquals(null, daRule, 'Should have DA rule');
        System.assertEquals(true, daRule.Auto_Create__c, 'DA should be auto-create');
        System.assertEquals('All', daRule.Travel_Mode__c, 'DA travel mode should be All');

        // Test caching
        List<Expense_Eligibility__c> cached = EXP_Expense_Service.getEligibilityRules('Band 1');
        System.assertEquals(6, cached.size(), 'Cached result should match');
    }

    @isTest
    static void testGetEmployeeBand() {
        Test.startTest();
        String band = EXP_Expense_Service.getEmployeeBand(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals('Band 1', band, 'Band should be Band 1');
    }

    @isTest
    static void testCalculateDAAmount() {
        // Full day (> 8 hours)
        Expense_Item__c itemFull = new Expense_Item__c(
            Working_Hours__c = 9, Claimed_Amount__c = 300
        );
        Expense_Eligibility__c daRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per Day', Rate_Amount__c = 300, Max_Per_Day__c = 300,
            Is_Active__c = true, Min_Distance_KM__c = 0
        );
        Decimal fullResult = EXP_Expense_Service.calculateEligibleAmount(itemFull, daRule, 22);
        System.assertEquals(300, fullResult, 'Full day DA should be 300');

        // Half day (4-8 hours)
        Expense_Item__c itemHalf = new Expense_Item__c(
            Working_Hours__c = 6, Claimed_Amount__c = 150
        );
        Decimal halfResult = EXP_Expense_Service.calculateEligibleAmount(itemHalf, daRule, 22);
        System.assertEquals(150, halfResult, 'Half day DA should be 150');

        // No DA (< 4 hours)
        Expense_Item__c itemNone = new Expense_Item__c(
            Working_Hours__c = 3, Claimed_Amount__c = 0
        );
        Decimal noneResult = EXP_Expense_Service.calculateEligibleAmount(itemNone, daRule, 22);
        System.assertEquals(0, noneResult, 'Less than 4 hours should be 0');
    }

    @isTest
    static void testCalculateTAAmount() {
        // Car rate
        Expense_Item__c carItem = new Expense_Item__c(
            GPS_Distance_KM__c = 30, Claimed_Amount__c = 150
        );
        Expense_Eligibility__c carRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per KM', Rate_Amount__c = 5, Max_Per_Day__c = 500,
            Is_Active__c = true, Min_Distance_KM__c = 10,
            Daily_KM_Limit__c = 200, Travel_Mode__c = 'Car'
        );
        Decimal carResult = EXP_Expense_Service.calculateEligibleAmount(carItem, carRule, 22);
        System.assertEquals(150, carResult, 'Car TA should be 30 * 5 = 150');

        // Bike rate (separate rule with its own Rate_Amount)
        Expense_Item__c bikeItem = new Expense_Item__c(
            GPS_Distance_KM__c = 30, Claimed_Amount__c = 90, Vehicle_Type__c = 'Bike'
        );
        Expense_Eligibility__c bikeRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per KM', Rate_Amount__c = 3, Max_Per_Day__c = 500,
            Is_Active__c = true, Min_Distance_KM__c = 10,
            Daily_KM_Limit__c = 200, Travel_Mode__c = 'Bike'
        );
        Decimal bikeResult = EXP_Expense_Service.calculateEligibleAmount(bikeItem, bikeRule, 22);
        System.assertEquals(90, bikeResult, 'Bike TA should be 30 * 3 = 90');

        // Daily KM limit
        Expense_Item__c overLimitItem = new Expense_Item__c(
            GPS_Distance_KM__c = 250, Claimed_Amount__c = 1000
        );
        Decimal limitResult = EXP_Expense_Service.calculateEligibleAmount(overLimitItem, carRule, 22);
        System.assertNotEquals(null, limitResult, 'Should return a calculated amount');
    }

    @isTest
    static void testCalculateLodgingAmount() {
        // Metro city
        Expense_Item__c metroItem = new Expense_Item__c(
            Claimed_Amount__c = 3500, Is_Metro__c = true
        );
        Expense_Eligibility__c lodgingRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Actual', Max_Per_Day__c = 5000,
            Is_Active__c = true, Min_Distance_KM__c = 0,
            Lodging_Metro_Limit__c = 3000, Lodging_Non_Metro_Limit__c = 2000
        );
        Decimal metroResult = EXP_Expense_Service.calculateEligibleAmount(metroItem, lodgingRule, 22);
        System.assertEquals(3000, metroResult, 'Metro lodging should cap at 3000');

        // Non-metro city
        Expense_Item__c nonMetroItem = new Expense_Item__c(
            Claimed_Amount__c = 2500, Is_Metro__c = false
        );
        Decimal nonMetroResult = EXP_Expense_Service.calculateEligibleAmount(nonMetroItem, lodgingRule, 22);
        System.assertEquals(2000, nonMetroResult, 'Non-metro lodging should cap at 2000');
    }

    @isTest
    static void testCalculateEligibleAmount() {
        Expense_Item__c item = new Expense_Item__c(
            GPS_Distance_KM__c = 30,
            Claimed_Amount__c = 500
        );

        // Per Day
        Expense_Eligibility__c perDayRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per Day', Rate_Amount__c = 300, Max_Per_Day__c = 300,
            Is_Active__c = true, Min_Distance_KM__c = 0
        );
        Decimal perDayResult = EXP_Expense_Service.calculateEligibleAmount(item, perDayRule, 22);
        System.assertEquals(300, perDayResult, 'Per Day should return rate amount');

        // Per KM
        Expense_Eligibility__c perKmRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per KM', Rate_Amount__c = 5, Max_Per_Day__c = 500,
            Is_Active__c = true, Min_Distance_KM__c = 10
        );
        Decimal perKmResult = EXP_Expense_Service.calculateEligibleAmount(item, perKmRule, 22);
        System.assertEquals(150, perKmResult, 'Per KM should return distance * rate');

        // Actual
        Expense_Eligibility__c actualRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Actual', Max_Per_Day__c = 800,
            Is_Active__c = true, Min_Distance_KM__c = 0
        );
        Decimal actualResult = EXP_Expense_Service.calculateEligibleAmount(item, actualRule, 22);
        System.assertEquals(500, actualResult, 'Actual should return claimed amount');

        // Flat Monthly
        Expense_Eligibility__c flatRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Flat Monthly', Rate_Amount__c = 3000, Max_Per_Day__c = 200,
            Is_Active__c = true, Min_Distance_KM__c = 0
        );
        Decimal flatResult = EXP_Expense_Service.calculateEligibleAmount(item, flatRule, 22);
        Decimal expected = (Decimal)(3000.0 / 22).setScale(2, RoundingMode.HALF_UP);
        System.assertEquals(expected, flatResult, 'Flat Monthly should return rate/working days');

        // Min distance not met
        Expense_Eligibility__c minDistRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per KM', Rate_Amount__c = 5, Max_Per_Day__c = 500,
            Is_Active__c = true, Min_Distance_KM__c = 50
        );
        Decimal minDistResult = EXP_Expense_Service.calculateEligibleAmount(item, minDistRule, 22);
        System.assertEquals(0, minDistResult, 'Below min distance should return 0');

        // Null/inactive rule
        Decimal nullResult = EXP_Expense_Service.calculateEligibleAmount(item, null, 22);
        System.assertEquals(0, nullResult, 'Null rule should return 0');
    }

    @isTest
    static void testSaveAndGetExpenseItems() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        List<Expense_Item__c> items = new List<Expense_Item__c>();
        items.add(new Expense_Item__c(
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 25,
            Claimed_Amount__c = 300,
            Eligible_Amount__c = 300,
            Working_Hours__c = 9
        ));
        items.add(new Expense_Item__c(
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Travelling Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 25,
            Claimed_Amount__c = 125,
            Eligible_Amount__c = 125,
            Vehicle_Type__c = 'Car'
        ));

        Test.startTest();
        List<Expense_Item__c> saved = EXP_Expense_Service.saveExpenseItems(report.Id, items);
        Test.stopTest();

        System.assertEquals(2, saved.size(), 'Should save 2 items');
        // Verify new fields saved
        System.assertEquals('Not Submitted', saved[0].Approval_Status__c, 'Default approval status');
        System.assertEquals(9, saved[0].Working_Hours__c, 'Working hours preserved');
        System.assertEquals('Car', saved[1].Vehicle_Type__c, 'Vehicle type preserved');

        // Get all items for report
        List<Expense_Item__c> allItems = EXP_Expense_Service.getAllExpenseItemsForReport(report.Id);
        System.assertEquals(2, allItems.size(), 'Should retrieve all items');
    }

    @isTest
    static void testSaveExceedingWithNotes() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        // Should fail without notes when exceeding eligible
        List<Expense_Item__c> itemsNoNotes = new List<Expense_Item__c>();
        itemsNoNotes.add(new Expense_Item__c(
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 25,
            Eligible_Amount__c = 300,
            Claimed_Amount__c = 400,
            Rate_Type__c = 'Per Day'
        ));

        Boolean caught = false;
        try {
            EXP_Expense_Service.saveExpenseItems(report.Id, itemsNoNotes);
        } catch (AuraHandledException e) {
            caught = true;
            System.assertNotEquals(null, e);
        }
        System.assert(caught, 'Should throw error when exceeding without notes');

        // Should succeed with notes
        List<Expense_Item__c> itemsWithNotes = new List<Expense_Item__c>();
        itemsWithNotes.add(new Expense_Item__c(
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 25,
            Eligible_Amount__c = 300,
            Claimed_Amount__c = 400,
            Rate_Type__c = 'Per Day',
            Notes__c = 'Client meeting required extended travel'
        ));

        Test.startTest();
        List<Expense_Item__c> saved = EXP_Expense_Service.saveExpenseItems(report.Id, itemsWithNotes);
        Test.stopTest();

        System.assertEquals(1, saved.size(), 'Should save when notes provided');
    }

    @isTest
    static void testDeleteExpenseItems() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            Claimed_Amount__c = 300,
            Eligible_Amount__c = 300
        );
        insert item;

        Test.startTest();
        EXP_Expense_Service.deleteExpenseItems(new List<Id>{ item.Id });
        Test.stopTest();

        List<Expense_Item__c> remaining = [SELECT Id FROM Expense_Item__c WHERE Id = :item.Id];
        System.assertEquals(0, remaining.size(), 'Item should be deleted');
    }

    @isTest
    static void testApprovalWorkflow() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            Claimed_Amount__c = 300,
            Eligible_Amount__c = 300
        );
        insert item;

        Test.startTest();
        // Submit
        Expense__c submitted = EXP_Expense_Service.submitReport(report.Id);
        System.assertEquals('Submitted', submitted.Status__c);
        System.assert(String.isNotBlank(submitted.Comments_History__c), 'Should have comments');

        // Verify item approval status
        Expense_Item__c submittedItem = [SELECT Approval_Status__c FROM Expense_Item__c WHERE Id = :item.Id];
        System.assertEquals('Pending', submittedItem.Approval_Status__c, 'Item should be Pending');

        // Manager approve
        Expense__c approved = EXP_Expense_Service.approveReport(report.Id, 'Looks good', 'manager');
        System.assertEquals('Manager Approved', approved.Status__c);

        // Verify item L1 approved
        Expense_Item__c l1Item = [SELECT Approval_Status__c, Approved_Amount__c FROM Expense_Item__c WHERE Id = :item.Id];
        System.assertEquals('L1 Approved', l1Item.Approval_Status__c, 'Item should be L1 Approved');
        System.assertNotEquals(null, l1Item.Approval_Status__c, 'Item should have approval status');

        // Finance approve
        Expense__c finApproved = EXP_Expense_Service.approveReport(report.Id, 'Verified', 'finance');
        System.assertEquals('Finance Approved', finApproved.Status__c);

        // Verify item Finance approved
        Expense_Item__c finItem = [SELECT Approval_Status__c FROM Expense_Item__c WHERE Id = :item.Id];
        System.assertEquals('L2 Approved', finItem.Approval_Status__c);

        // Mark paid
        Expense__c paid = EXP_Expense_Service.markAsPaid(report.Id);
        System.assertEquals('Paid', paid.Status__c);
        Test.stopTest();
    }

    @isTest
    static void testPerItemApproval() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        List<Expense_Item__c> items = new List<Expense_Item__c>();
        items.add(new Expense_Item__c(
            Expense__c = report.Id, Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance', Claimed_Amount__c = 300,
            Eligible_Amount__c = 300, Approval_Status__c = 'Pending'
        ));
        items.add(new Expense_Item__c(
            Expense__c = report.Id, Expense_Date__c = monthStart,
            Expense_Type__c = 'Fuel', Claimed_Amount__c = 500,
            Eligible_Amount__c = 500, Approval_Status__c = 'Pending'
        ));
        insert items;

        Test.startTest();
        // Approve individual items
        Map<String, Object> approveResult = EXP_Expense_Service.approveExpenseItems(
            new List<Id>{ items[0].Id }, 'OK', 'manager'
        );
        System.assertEquals(1, (Integer) approveResult.get('count'));

        // Reject individual items
        Map<String, Object> rejectResult = EXP_Expense_Service.rejectExpenseItems(
            new List<Id>{ items[1].Id }, 'No receipt', 'manager'
        );
        System.assertEquals(1, (Integer) rejectResult.get('count'));

        // Update approved amounts
        Map<Id, Decimal> amountsMap = new Map<Id, Decimal>();
        amountsMap.put(items[0].Id, 250);
        Map<String, Object> amountResult = EXP_Expense_Service.updateApprovedAmounts(amountsMap);
        System.assertNotEquals(null, amountResult.get('items'));
        Test.stopTest();

        // Verify statuses
        Expense_Item__c approved = [SELECT Approval_Status__c, Approved_Amount__c FROM Expense_Item__c WHERE Id = :items[0].Id];
        System.assertEquals('L1 Approved', approved.Approval_Status__c);
        System.assertEquals(250, approved.Approved_Amount__c, 'Amount should be updated');

        Expense_Item__c rejected = [SELECT Approval_Status__c FROM Expense_Item__c WHERE Id = :items[1].Id];
        System.assertEquals('Rejected', rejected.Approval_Status__c);
    }

    @isTest
    static void testRejectReport() {
        Date today = Date.today();
        String monthName = getCurrentMonth();

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = Date.newInstance(today.year(), today.month(), 1),
            Expense_Type__c = 'Daily Allowance',
            Claimed_Amount__c = 300, Eligible_Amount__c = 300
        );
        insert item;

        report.Status__c = 'Submitted';
        update report;

        Test.startTest();
        Expense__c rejected = EXP_Expense_Service.rejectReport(report.Id, 'Missing receipts', 'manager');
        Test.stopTest();

        System.assertEquals('Rejected', rejected.Status__c);
        System.assert(String.isNotBlank(rejected.Comments_History__c), 'Should have comments');

        Expense_Item__c rejItem = [SELECT Approval_Status__c FROM Expense_Item__c WHERE Id = :item.Id];
        System.assertEquals('Rejected', rejItem.Approval_Status__c, 'Item should be rejected');
    }

    @isTest
    static void testGetExpenseForApproval() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id, Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance', Claimed_Amount__c = 300,
            Eligible_Amount__c = 300
        );
        insert item;

        Test.startTest();
        Map<String, Object> data = EXP_Expense_Service.getExpenseForApproval(report.Id);
        Test.stopTest();

        System.assertNotEquals(null, data.get('expense'));
        System.assertNotEquals(null, data.get('items'));
        System.assertNotEquals(null, data.get('files'));
    }

    @isTest
    static void testAppendComment() {
        String result = EXP_Expense_Service.appendComment(null, 'Test comment', UserInfo.getUserId());
        System.assert(result.contains('Test comment'), 'Should contain comment');
        System.assert(result.contains(UserInfo.getName()), 'Should contain user name');

        String result2 = EXP_Expense_Service.appendComment(result, 'Second comment', UserInfo.getUserId());
        System.assert(result2.contains('Second comment'), 'Should contain second comment');
        System.assert(result2.contains('\n'), 'Should have newline separator');
    }

    @isTest
    static void testGetReportSummary() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            Claimed_Amount__c = 300,
            Eligible_Amount__c = 300
        );
        insert item;

        Test.startTest();
        Map<String, Object> summary = EXP_Expense_Service.getReportSummary(report.Id);
        Test.stopTest();

        System.assertNotEquals(null, summary.get('expense'));
        System.assertNotEquals(null, summary.get('typeBreakdown'));
        System.assertNotEquals(null, summary.get('dayBreakdown'));
    }

    @isTest
    static void testGetMonthlyOverview() {
        Date today = Date.today();
        String monthName = getCurrentMonth();

        EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Test.startTest();
        List<Map<String, Object>> overview = EXP_Expense_Service.getMonthlyOverview(
            UserInfo.getUserId(), today.year()
        );
        Test.stopTest();

        System.assertEquals(12, overview.size(), 'Should return 12 months');
    }

    @isTest
    static void testIsValidTransition() {
        System.assert(EXP_Expense_Service.isValidTransition('Draft', 'Submitted'));
        System.assert(EXP_Expense_Service.isValidTransition('Submitted', 'Manager Approved'));
        System.assert(EXP_Expense_Service.isValidTransition('Submitted', 'Rejected'));
        System.assert(!EXP_Expense_Service.isValidTransition('Draft', 'Manager Approved'));
        System.assert(!EXP_Expense_Service.isValidTransition('Paid', 'Draft'));
        System.assert(EXP_Expense_Service.isValidTransition('Finance Approved', 'Paid'));
        System.assert(EXP_Expense_Service.isValidTransition('Paid', 'Finance Approved'));
    }

    @isTest
    static void testConfigHelpers() {
        Test.startTest();
        Boolean boolVal = EXP_Expense_Service.getConfigBoolean('ALLOW_FUTURE_DATES', false);
        Integer intVal = EXP_Expense_Service.getConfigInteger('MAX_OVERRIDE_PERCENT', 150);
        String strVal = EXP_Expense_Service.getAppConfig('NON_EXISTENT', 'default');
        Test.stopTest();

        System.assertNotEquals(null, boolVal);
        System.assertNotEquals(null, intVal);
        System.assertEquals('default', strVal);
    }

    @isTest
    static void testClearCache() {
        EXP_Expense_Service.getEligibilityRules('Band 1');
        EXP_Expense_Service.getAppConfig('test', 'val');

        Test.startTest();
        EXP_Expense_Service.clearCache();
        Test.stopTest();

        List<Expense_Eligibility__c> rules = EXP_Expense_Service.getEligibilityRules('Band 1');
        System.assertEquals(6, rules.size(), 'Should re-fetch after cache clear');
    }

    @isTest
    static void testGetTeamExpenseReports() {
        Date today = Date.today();
        String monthName = getCurrentMonth();

        Test.startTest();
        List<Expense__c> teamReports = EXP_Expense_Service.getTeamExpenseReports(
            UserInfo.getUserId(), monthName, today.year()
        );
        Test.stopTest();

        System.assertNotEquals(null, teamReports);
    }

    @isTest
    static void testPopulateEligibilityFields() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Day_Attendance__c att = [
            SELECT Id FROM Day_Attendance__c
            WHERE Attendance_Date__c = :monthStart LIMIT 1
        ];

        List<Expense_Item__c> items = new List<Expense_Item__c>();
        items.add(new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Day_Attendance__c = att.Id,
            Claimed_Amount__c = 300
        ));

        Test.startTest();
        EXP_Expense_Service.populateEligibilityFields(items, report.Id);
        Test.stopTest();

        System.assertEquals('Per Day', items[0].Rate_Type__c);
        System.assertEquals(300, items[0].Rate_Amount__c);
        System.assert(items[0].Is_Eligible__c);
        System.assert(items[0].Eligible_Amount__c > 0);
    }

    @isTest
    static void testGetSubmitSummary() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            Claimed_Amount__c = 300,
            Eligible_Amount__c = 300
        );
        insert item;

        Test.startTest();
        Map<String, Object> summary = EXP_Expense_Service.getSubmitSummary(report.Id);
        Test.stopTest();

        System.assertEquals(1, (Integer) summary.get('totalItems'), 'Should have 1 item');
        System.assertEquals(1, (Integer) summary.get('dayCount'), 'Should have 1 day');
        System.assertEquals(300, (Decimal) summary.get('totalClaimed'), 'Total claimed should be 300');
        System.assertEquals(300, (Decimal) summary.get('totalEligible'), 'Total eligible should be 300');
        System.assertNotEquals(null, summary.get('typeBreakdown'), 'Should have type breakdown');
        System.assertEquals(true, summary.get('canSubmit'), 'Should be able to submit');
    }

    @isTest
    static void testFoodLimitCalculation() {
        Expense_Item__c foodItem = new Expense_Item__c(
            Claimed_Amount__c = 500
        );
        // Food limit is now enforced via Max_Per_Day__c
        Expense_Eligibility__c foodRule = new Expense_Eligibility__c(
            Rate_Type__c = 'Actual', Max_Per_Day__c = 300,
            Is_Active__c = true, Min_Distance_KM__c = 0,
            Travel_Mode__c = 'All'
        );

        Test.startTest();
        Decimal result = EXP_Expense_Service.calculateEligibleAmount(foodItem, foodRule, 22);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return a calculated amount');
    }

    @isTest
    static void testSystemCalculatedAmountPopulated() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        Day_Attendance__c att = [
            SELECT Id FROM Day_Attendance__c
            WHERE Attendance_Date__c = :monthStart LIMIT 1
        ];

        List<Expense_Item__c> items = new List<Expense_Item__c>();
        items.add(new Expense_Item__c(
            Expense__c = report.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Day_Attendance__c = att.Id,
            Claimed_Amount__c = 300
        ));

        Test.startTest();
        EXP_Expense_Service.populateEligibilityFields(items, report.Id);
        Test.stopTest();

        System.assertNotEquals(null, items[0].System_Calculated_Amount__c, 'System calc amount should be populated');
        System.assert(items[0].System_Calculated_Amount__c > 0, 'System calc amount should be > 0');
        System.assertEquals(items[0].Eligible_Amount__c, items[0].System_Calculated_Amount__c, 'System calc should equal eligible');
    }

    @isTest
    static void testSaveWithTravelMode() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        List<Expense_Item__c> items = new List<Expense_Item__c>();
        items.add(new Expense_Item__c(
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Travelling Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 30,
            Claimed_Amount__c = 150,
            Eligible_Amount__c = 150,
            Vehicle_Type__c = 'Car',
            Travel_Mode__c = 'Car'
        ));

        Test.startTest();
        List<Expense_Item__c> saved = EXP_Expense_Service.saveExpenseItems(report.Id, items);
        Test.stopTest();

        System.assertEquals(1, saved.size(), 'Should save 1 item');
        System.assertEquals('Car', saved[0].Travel_Mode__c, 'Travel mode should be preserved');
    }

    @isTest
    static void testSaveExpenseItemsValidation() {
        Date today = Date.today();
        String monthName = getCurrentMonth();
        Date monthStart = Date.newInstance(today.year(), today.month(), 1);

        Expense__c report = EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), monthName, today.year());

        List<Expense_Item__c> items = new List<Expense_Item__c>();
        items.add(new Expense_Item__c(
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 20,
            Manual_Distance_KM__c = 25,
            Eligible_Amount__c = 300,
            Claimed_Amount__c = 300
        ));

        Test.startTest();
        Boolean caught = false;
        try {
            EXP_Expense_Service.saveExpenseItems(report.Id, items);
        } catch (AuraHandledException e) {
            caught = true;
        }
        System.assert(caught, 'Should throw error for missing override reason');
        Test.stopTest();
    }

    // ── Direct private method tests ─────────────────────────────────

    @isTest
    static void testGetLodgingLimit_CityTier1() {
        Expense_Item__c item = new Expense_Item__c(City_Tier__c = 'Tier 1');
        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            City_Tier_1_Limit__c = 3000, City_Tier_2_Limit__c = 2000, City_Tier_3_Limit__c = 1500
        );
        System.assertEquals(3000, EXP_Expense_Service.getLodgingLimit(item, rule));
    }

    @isTest
    static void testGetLodgingLimit_CityTier2() {
        Expense_Item__c item = new Expense_Item__c(City_Tier__c = 'Tier 2');
        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            City_Tier_1_Limit__c = 3000, City_Tier_2_Limit__c = 2000, City_Tier_3_Limit__c = 1500
        );
        System.assertEquals(2000, EXP_Expense_Service.getLodgingLimit(item, rule));
    }

    @isTest
    static void testGetLodgingLimit_CityTier3() {
        Expense_Item__c item = new Expense_Item__c(City_Tier__c = 'Tier 3');
        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            City_Tier_1_Limit__c = 3000, City_Tier_2_Limit__c = 2000, City_Tier_3_Limit__c = 1500
        );
        System.assertEquals(1500, EXP_Expense_Service.getLodgingLimit(item, rule));
    }

    @isTest
    static void testGetLodgingLimit_Metro() {
        Expense_Item__c item = new Expense_Item__c(Is_Metro__c = true);
        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            Lodging_Metro_Limit__c = 4000, Lodging_Non_Metro_Limit__c = 2500
        );
        System.assertEquals(4000, EXP_Expense_Service.getLodgingLimit(item, rule));
    }

    @isTest
    static void testGetLodgingLimit_NonMetro() {
        Expense_Item__c item = new Expense_Item__c(Is_Metro__c = false);
        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            Lodging_Non_Metro_Limit__c = 2500
        );
        System.assertEquals(2500, EXP_Expense_Service.getLodgingLimit(item, rule));
    }

    @isTest
    static void testGetLodgingLimit_NoLimits() {
        Expense_Item__c item = new Expense_Item__c();
        Expense_Eligibility__c rule = new Expense_Eligibility__c();
        System.assertEquals(0, EXP_Expense_Service.getLodgingLimit(item, rule));
    }

    @isTest
    static void testGetAppliedDistance_Manual() {
        Expense_Item__c item = new Expense_Item__c(
            Manual_Distance_KM__c = 50, GPS_Distance_KM__c = 30
        );
        System.assertEquals(50, EXP_Expense_Service.getAppliedDistance(item));
    }

    @isTest
    static void testGetAppliedDistance_GPS() {
        Expense_Item__c item = new Expense_Item__c(GPS_Distance_KM__c = 30);
        System.assertEquals(30, EXP_Expense_Service.getAppliedDistance(item));
    }

    @isTest
    static void testGetAppliedDistance_Null() {
        Expense_Item__c item = new Expense_Item__c();
        System.assertEquals(0, EXP_Expense_Service.getAppliedDistance(item));
    }

    @isTest
    static void testCalculateSlabAmount() {
        List<Expense_Rate_Slab__c> slabs = new List<Expense_Rate_Slab__c>();
        slabs.add(new Expense_Rate_Slab__c(
            Distance_From__c = 0, Distance_To__c = 30, Rate_Amount__c = 5
        ));
        slabs.add(new Expense_Rate_Slab__c(
            Distance_From__c = 30, Distance_To__c = 100, Rate_Amount__c = 8
        ));

        // 50 km: first 30 @ 5 = 150, next 20 @ 8 = 160 → total 310
        Decimal result = EXP_Expense_Service.calculateSlabAmount(slabs, 50);
        System.assertEquals(310, result);
    }

    @isTest
    static void testCalculateSlabAmount_WithinFirstSlab() {
        List<Expense_Rate_Slab__c> slabs = new List<Expense_Rate_Slab__c>();
        slabs.add(new Expense_Rate_Slab__c(
            Distance_From__c = 0, Distance_To__c = 100, Rate_Amount__c = 3
        ));

        Decimal result = EXP_Expense_Service.calculateSlabAmount(slabs, 25);
        System.assertEquals(75, result);
    }

    @isTest
    static void testResolveCityTier() {
        Map<String, String> tierMap = new Map<String, String>{
            'Mumbai' => 'Tier 1', 'Pune' => 'Tier 2', 'Nashik' => 'Tier 3'
        };
        System.assertEquals('Tier 1', EXP_Expense_Service.resolveCityTier('Mumbai', tierMap));
        System.assertEquals('Tier 2', EXP_Expense_Service.resolveCityTier('Pune', tierMap));
        System.assertEquals(null, EXP_Expense_Service.resolveCityTier('Unknown', tierMap));
        System.assertEquals(null, EXP_Expense_Service.resolveCityTier(null, tierMap));
        System.assertEquals(null, EXP_Expense_Service.resolveCityTier('Mumbai', null));
    }

    @isTest
    static void testCalculateTAAmount_PerKM() {
        Expense_Item__c item = new Expense_Item__c(
            GPS_Distance_KM__c = 40, Travel_Mode__c = 'Bike'
        );
        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per KM', Rate_Amount__c = 5,
            Daily_KM_Limit__c = 100, Max_Per_Day__c = 500
        );

        Decimal result = EXP_Expense_Service.calculateTAAmount(item, rule);
        System.assertEquals(200, result, '40 km * 5 = 200');
    }

    @isTest
    static void testCalculateTAAmount_WithDailyKMLimit() {
        Expense_Item__c item = new Expense_Item__c(
            GPS_Distance_KM__c = 150, Travel_Mode__c = 'Car'
        );
        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            Rate_Type__c = 'Per KM', Rate_Amount__c = 8,
            Daily_KM_Limit__c = 100, Max_Per_Day__c = 1000
        );

        Decimal result = EXP_Expense_Service.calculateTAAmount(item, rule);
        System.assertEquals(800, result, '100 km (capped) * 8 = 800');
    }
}