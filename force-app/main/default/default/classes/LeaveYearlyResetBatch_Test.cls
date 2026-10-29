@isTest
private class LeaveYearlyResetBatch_Test {

    @TestSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('LYR Territory', 'LYR-T-001');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Leave',
            Last_Name__c = 'Tester',
            Employee_Code__c = 'EMP-LYR-001',
            Email__c = 'lyr@example.com',
            Phone__c = '9876543210',
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Band__c = 'Band 1',
            Territory__c = territory.Id,
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Date_of_Joining__c = Date.today().addYears(-2)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;
    }

    private static void seedPolicy(String leaveType, String designation,
                                    Decimal entitlement, Decimal monthlyAccrual,
                                    Decimal maxCarry, String effectiveYear) {
        Leave_Policy__c policy = new Leave_Policy__c();
        try { policy.put('Leave_Type__c', leaveType); } catch (Exception e) {}
        if (designation != null) {
            try { policy.put('Designation__c', designation); } catch (Exception e) {}
        }
        try { policy.put('Annual_Entitlement__c', entitlement); } catch (Exception e) {}
        try { policy.put('Monthly_Accrual__c', monthlyAccrual); } catch (Exception e) {}
        try { policy.put('Max_Carry_Forward__c', maxCarry); } catch (Exception e) {}
        try { policy.put('Is_Active__c', true); } catch (Exception e) {}
        try { policy.put('Effective_Year__c', effectiveYear); } catch (Exception e) {}
        try { insert policy; } catch (Exception e) {}
    }

    @isTest
    static void testBatch_NoPolicies() {
        // No policies inserted -> execute() takes the early-return path.
        Test.startTest();
        Database.executeBatch(new LeaveYearlyResetBatch('2026'), 200);
        Test.stopTest();
    }

    @isTest
    static void testBatch_HappyPath() {
        // Policy with monthly accrual (initialAccrued = 0) and one without
        // (initialAccrued = entitlement).
        seedPolicy('Casual Leave', 'Sales Representative', 12, 1, 5, '2026');
        seedPolicy('Sick Leave', null, 10, 0, 0, null);

        Test.startTest();
        Database.executeBatch(new LeaveYearlyResetBatch('2026'), 200);
        Test.stopTest();
    }

    @isTest
    static void testBatch_WithCarryForwardAndExisting() {
        // Seed policy
        seedPolicy('Earned Leave', 'Sales Representative', 15, 0, 10, '2026');

        Employee__c emp = [SELECT Id FROM Employee__c LIMIT 1];

        // Previous-year balance to exercise the carryForward branch.
        try {
            Leave_Balance__c prev = new Leave_Balance__c();
            prev.put('Employee__c', emp.Id);
            prev.put('Leave_Type__c', 'Earned Leave');
            prev.put('Year__c', '2025');
            prev.put('Entitled__c', 15);
            prev.put('Accrued__c', 15);
            prev.put('Used__c', 8);
            prev.put('Pending__c', 0);
            try { prev.put('Available__c', 7); } catch (Exception e) {}
            insert prev;
        } catch (Exception e) {}

        // Current-year balance already exists for a different leave type -
        // exercises the existing-skip branch.
        try {
            Leave_Balance__c curr = new Leave_Balance__c();
            curr.put('Employee__c', emp.Id);
            curr.put('Leave_Type__c', 'Earned Leave');
            curr.put('Year__c', '2026');
            curr.put('Entitled__c', 15);
            curr.put('Used__c', 0);
            curr.put('Pending__c', 0);
            insert curr;
        } catch (Exception e) {}

        Test.startTest();
        Database.executeBatch(new LeaveYearlyResetBatch('2026'), 200);
        Test.stopTest();
    }

    @isTest
    static void testBatch_DesignationMismatch() {
        // Policy for a different designation -> skip path.
        seedPolicy('Optional Leave', 'Area Sales Manager', 5, 0, 0, '2026');

        Test.startTest();
        Database.executeBatch(new LeaveYearlyResetBatch('2026'), 200);
        Test.stopTest();
    }
}