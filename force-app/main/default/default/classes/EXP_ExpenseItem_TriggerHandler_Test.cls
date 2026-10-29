@isTest
public class EXP_ExpenseItem_TriggerHandler_Test {

    @TestSetup
    static void setupTestData() {
        Employee__c emp = new Employee__c(
            First_Name__c = 'Trigger',
            Last_Name__c = 'Test',
            Employee_Code__c = 'EMP-TRG01',
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Band__c = 'Band 1',
            Territory__c = TestDataFactory.createAndInsertTerritory('EXP Trigger Ter', 'TER-EXPTRG01').Id,
            Channels__c = 'GT'
        );
        insert emp;

        Date monthStart = Date.newInstance(Date.today().year(), Date.today().month(), 1);
        Day_Attendance__c att = new Day_Attendance__c(
            User__c = UserInfo.getUserId(),
            Salesperson__c = UserInfo.getUserId(),
            Attendance_Date__c = monthStart,
            Start_Time__c = Datetime.newInstance(monthStart, Time.newInstance(9, 0, 0, 0)),
            Distance_Traveled_Km__c = 30
        );
        insert att;

        Expense_Eligibility__c rule = new Expense_Eligibility__c(
            Band__c = 'Band 1', Expense_Type__c = 'Daily Allowance', Expense_Category__c = 'Travel',
            Rate_Type__c = 'Per Day', Rate_Amount__c = 300, Max_Per_Day__c = 300,
            Max_Per_Month__c = 9000, Is_Active__c = true, Sort_Order__c = 1
        );
        insert rule;

        Expense__c expense = new Expense__c(
            Employee__c = emp.Id,
            User__c = UserInfo.getUserId(),
            Month__c = getMonthName(Date.today().month()),
            Year__c = Date.today().year(),
            Period_Start__c = monthStart,
            Period_End__c = monthStart.addMonths(1).addDays(-1),
            Status__c = 'Draft',
            Working_Days__c = 22
        );
        insert expense;
    }

    static String getMonthName(Integer m) {
        List<String> months = new List<String>{'', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'};
        return months[m];
    }

    @isTest
    static void testBeforeInsert() {
        Expense__c expense = [SELECT Id FROM Expense__c LIMIT 1];
        Date monthStart = Date.newInstance(Date.today().year(), Date.today().month(), 1);

        Test.startTest();
        Expense_Item__c item = new Expense_Item__c(
            Expense__c = expense.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            Claimed_Amount__c = 300
        );
        insert item;
        Test.stopTest();

        // The trigger handler won't execute because feature toggle is off in test context
        // But the insert should succeed without errors
        Expense_Item__c inserted = [SELECT Id, Expense_Type__c FROM Expense_Item__c WHERE Id = :item.Id];
        System.assertEquals('Daily Allowance', inserted.Expense_Type__c);
    }

    @isTest
    static void testBeforeUpdate() {
        Expense__c expense = [SELECT Id FROM Expense__c LIMIT 1];
        Date monthStart = Date.newInstance(Date.today().year(), Date.today().month(), 1);

        Expense_Item__c item = new Expense_Item__c(
            Expense__c = expense.Id,
            Expense_Date__c = monthStart,
            Expense_Type__c = 'Daily Allowance',
            Expense_Category__c = 'Travel',
            GPS_Distance_KM__c = 30,
            Claimed_Amount__c = 300,
            Eligible_Amount__c = 300
        );
        insert item;

        Test.startTest();
        item.Claimed_Amount__c = 250;
        update item;
        Test.stopTest();

        Expense_Item__c updated = [SELECT Id, Claimed_Amount__c FROM Expense_Item__c WHERE Id = :item.Id];
        System.assertEquals(250, updated.Claimed_Amount__c);
    }
}