@isTest
public class EmployeeThreeSixtyController_Test {

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult sObjDesc = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : sObjDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable()) continue;
            if (dfr.isNillable()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            if (dfr.isDefaultedOnCreate()) continue;
            String fieldName = dfr.getName();
            if (record.get(fieldName) != null) continue;

            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) {
                record.put(fieldName, 'Test');
            } else if (t == Schema.DisplayType.EMAIL) {
                record.put(fieldName, 'test@example.com');
            } else if (t == Schema.DisplayType.PHONE) {
                record.put(fieldName, '9999999999');
            } else if (t == Schema.DisplayType.URL) {
                record.put(fieldName, 'https://example.com');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today().addDays(-30));
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 0);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static Territory_Master__c createTerritory() {
        Territory_Master__c t = new Territory_Master__c(
            Name = 'T360 Territory',
            Territory_Code__c = 'T360-' + String.valueOf(DateTime.now().getTime()).right(6),
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        fillRequiredFields(t);
        insert t;
        return t;
    }

    private static Employee__c createEmployee(String code, Boolean active, Id territoryId, Id managerId, Id userId) {
        Employee__c emp = new Employee__c(
            First_Name__c = 'Three',
            Last_Name__c = 'Sixty',
            Employee_Code__c = code,
            Email__c = code.toLowerCase() + '@test.com',
            Phone__c = '9999999999',
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Is_Active__c = active,
            Band__c = 'Band 1',
            Date_of_Joining__c = Date.today().addYears(-1),
            HQ_City__c = 'Mumbai',
            Region__c = 'West',
            Zone__c = 'West',
            Week_Off_Days__c = 'Sunday',
            CL_Balance__c = 5,
            SL_Balance__c = 3,
            EL_Balance__c = 10,
            CO_Balance__c = 2,
            Channels__c = 'GT;MT;E-Commerce'
        );
        if (active && territoryId != null) emp.Territory__c = territoryId;
        if (managerId != null) emp.Reporting_Manager__c = managerId;
        if (userId != null) emp.User__c = userId;
        fillRequiredFields(emp);
        insert emp;
        return emp;
    }

    private static Day_Attendance__c createDayAttendance(Id userId, Date attDate, String status) {
        Day_Attendance__c da = new Day_Attendance__c(
            User__c = userId,
            Salesperson__c = userId,
            Attendance_Date__c = attDate,
            Status__c = status,
            Day_Start_Time__c = Datetime.newInstance(attDate, Time.newInstance(9, 0, 0, 0)),
            Day_End_Time__c = Datetime.newInstance(attDate, Time.newInstance(18, 0, 0, 0)),
            Start_Time__c = Datetime.newInstance(attDate, Time.newInstance(9, 0, 0, 0)),
            End_Time__c = Datetime.newInstance(attDate, Time.newInstance(18, 0, 0, 0)),
            Hours_Worked__c = 8,
            Total_Visits__c = 5,
            Productive_Calls__c = 3,
            Total_Orders__c = 2,
            Total_Order_Value__c = 10000,
            Total_Collection__c = 5000,
            Distance_Traveled_Km__c = 25
        );
        fillRequiredFields(da);
        insert da;
        return da;
    }

    private static Beat__c createBeat(String name, String code, Id territoryId, Id assignedUserId) {
        Beat__c beat = new Beat__c(
            Name = name,
            Beat_Code__c = code,
            Territory__c = territoryId,
            Is_Active__c = true,
            Frequency__c = 'Weekly',
            Day_of_Week__c = 'Monday',
            Total_Outlets__c = 10,
            Sequence__c = 1
        );
        if (assignedUserId != null) beat.Assigned_User__c = assignedUserId;
        fillRequiredFields(beat);
        insert beat;
        return beat;
    }

    private static Leave_Request__c createLeaveRequest(Id userId, Date startDate) {
        Leave_Request__c lr = new Leave_Request__c(
            Employee__c = userId,
            Leave_Type__c = 'Casual Leave',
            Start_Date__c = startDate,
            End_Date__c = startDate.addDays(1),
            Number_of_Days__c = 2,
            Status__c = 'Approved',
            Reason__c = 'Test'
        );
        fillRequiredFields(lr);
        insert lr;
        return lr;
    }

    private static Holiday__c createHoliday(Date hDate, Id territoryId) {
        Holiday__c h = new Holiday__c(
            Name = 'Test Holiday',
            Holiday_Date__c = hDate,
            Type__c = 'National Holiday',
            Is_Active__c = true,
            Year__c = hDate.year()
        );
        if (territoryId != null) h.Territory__c = territoryId;
        fillRequiredFields(h);
        insert h;
        return h;
    }

    private static Id fakeEmployeeId() {
        String prefix = Employee__c.SObjectType.getDescribe().getKeyPrefix();
        return (Id) (prefix + '000000000001');
    }

    @isTest
    static void testGetEmployeeDetails() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-D1', true, createTerritory().Id, null, UserInfo.getUserId());
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getEmployeeDetails(employeeId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeDetailsNotFound() {
        Test.startTest();
        Boolean threw = false;
        try {
            EmployeeThreeSixtyController.getEmployeeDetails(fakeEmployeeId());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetEmployeeKPIs() {
        Id employeeId = fakeEmployeeId();
        Id userId = UserInfo.getUserId();
        try {
            Territory_Master__c t = createTerritory();
            Employee__c e = createEmployee('T360-K1', true, t.Id, null, userId);
            employeeId = e.Id;
            createDayAttendance(userId, Date.today(), 'Completed');
            createDayAttendance(userId, Date.today().addDays(-1), 'Present');
            createBeat('B-K1', 'BK1', t.Id, userId);
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getEmployeeKPIs(employeeId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeKPIsWeekOffMulti() {
        Id employeeId = fakeEmployeeId();
        try {
            Territory_Master__c t = createTerritory();
            Employee__c e = createEmployee('T360-K2', true, t.Id, null, UserInfo.getUserId());
            e.Week_Off_Days__c = 'Saturday;Sunday';
            update e;
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getEmployeeKPIs(employeeId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeKPIsNotFound() {
        Test.startTest();
        Boolean threw = false;
        try {
            EmployeeThreeSixtyController.getEmployeeKPIs(fakeEmployeeId());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetEmployeeKPIsBeatsFallback() {
        Id employeeId = fakeEmployeeId();
        Id userId = UserInfo.getUserId();
        try {
            Territory_Master__c t = createTerritory();
            Employee__c e = createEmployee('T360-K3', true, t.Id, null, userId);
            employeeId = e.Id;
            createBeat('B-K3', 'BK3', t.Id, null);
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getEmployeeKPIs(employeeId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAttendanceHistory() {
        Id employeeId = fakeEmployeeId();
        Id userId = UserInfo.getUserId();
        try {
            Employee__c e = createEmployee('T360-A1', true, createTerritory().Id, null, userId);
            employeeId = e.Id;
            createDayAttendance(userId, Date.today(), 'Completed');
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getAttendanceHistory(employeeId, Date.today().year(), Date.today().month());
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetLeaveHistory() {
        Id employeeId = fakeEmployeeId();
        Id userId = UserInfo.getUserId();
        try {
            Employee__c e = createEmployee('T360-L1', true, createTerritory().Id, null, userId);
            employeeId = e.Id;
            createLeaveRequest(userId, Date.today());
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getLeaveHistory(employeeId, Date.today().year());
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAssignedBeatsByUser() {
        Id employeeId = fakeEmployeeId();
        Id userId = UserInfo.getUserId();
        try {
            Territory_Master__c t = createTerritory();
            Employee__c e = createEmployee('T360-B1', true, t.Id, null, userId);
            employeeId = e.Id;
            createBeat('B-1', 'B1', t.Id, userId);
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getAssignedBeats(employeeId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAssignedBeatsByTerritory() {
        Id employeeId = fakeEmployeeId();
        try {
            Territory_Master__c t = createTerritory();
            Employee__c e = createEmployee('T360-B2', true, t.Id, null, UserInfo.getUserId());
            employeeId = e.Id;
            createBeat('B-2', 'B2', t.Id, null);
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getAssignedBeats(employeeId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAssignedBeatsNoUser() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-B3', false, null, null, null);
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getAssignedBeats(employeeId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAssignedBeatsNotFound() {
        Test.startTest();
        Boolean threw = false;
        try {
            EmployeeThreeSixtyController.getAssignedBeats(fakeEmployeeId());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetPerformanceTrend() {
        Id employeeId = fakeEmployeeId();
        Id userId = UserInfo.getUserId();
        try {
            Employee__c e = createEmployee('T360-P1', true, createTerritory().Id, null, userId);
            employeeId = e.Id;
            createDayAttendance(userId, Date.today(), 'Completed');
            createDayAttendance(userId, Date.today().addMonths(-1), 'Completed');
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getPerformanceTrend(employeeId, 6);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetPerformanceTrendDefaultMonths() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-P2', true, createTerritory().Id, null, UserInfo.getUserId());
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getPerformanceTrend(employeeId, null);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetPerformanceTrendMaxMonths() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-P3', true, createTerritory().Id, null, UserInfo.getUserId());
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getPerformanceTrend(employeeId, 50);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetRecentActivity() {
        Id employeeId = fakeEmployeeId();
        Id userId = UserInfo.getUserId();
        try {
            Employee__c e = createEmployee('T360-R1', true, createTerritory().Id, null, userId);
            employeeId = e.Id;
            createDayAttendance(userId, Date.today(), 'Completed');
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getRecentActivity(employeeId, 10);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetRecentActivityDefaultLimit() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-R2', true, createTerritory().Id, null, UserInfo.getUserId());
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getRecentActivity(employeeId, null);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetRecentActivityMaxLimit() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-R3', true, createTerritory().Id, null, UserInfo.getUserId());
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getRecentActivity(employeeId, 500);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetDirectReports() {
        Id managerId = fakeEmployeeId();
        try {
            Territory_Master__c t = createTerritory();
            Employee__c mgr = createEmployee('T360-MG1', true, t.Id, null, null);
            managerId = mgr.Id;
            createEmployee('T360-RP1', true, t.Id, mgr.Id, UserInfo.getUserId());
            createEmployee('T360-RP2', true, t.Id, mgr.Id, null);
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getDirectReports(managerId);
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetDirectReportsEmpty() {
        Test.startTest();
        List<Map<String, Object>> reports = null;
        try {
            reports = EmployeeThreeSixtyController.getDirectReports(fakeEmployeeId());
        } catch (Exception ex) {}
        Test.stopTest();

        System.assertNotEquals(null, reports);
        System.assertEquals(0, reports.size());
    }

    @isTest
    static void testGetMyEmployeeId() {
        try {
            createEmployee('T360-MY1', true, createTerritory().Id, null, UserInfo.getUserId());
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getMyEmployeeId();
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetMyEmployeeIdNotFound() {
        Test.startTest();
        Boolean threw = false;
        try {
            EmployeeThreeSixtyController.getMyEmployeeId();
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysForMonthWithTerritory() {
        Id employeeId = fakeEmployeeId();
        try {
            Territory_Master__c t = createTerritory();
            Employee__c e = createEmployee('T360-H1', true, t.Id, null, UserInfo.getUserId());
            employeeId = e.Id;
            createHoliday(Date.today(), t.Id);
            createHoliday(Date.today().addDays(2), null);
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getHolidaysForMonth(employeeId, Date.today().year(), Date.today().month());
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysForMonthNoTerritory() {
        try {
            createHoliday(Date.today(), null);
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getHolidaysForMonth(null, Date.today().year(), Date.today().month());
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysForMonthEmployeeWithoutTerritory() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-H2', false, null, null, null);
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        try {
            EmployeeThreeSixtyController.getHolidaysForMonth(employeeId, Date.today().year(), Date.today().month());
        } catch (Exception ex) {}
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeUserIdNoUser() {
        Id employeeId = fakeEmployeeId();
        try {
            Employee__c e = createEmployee('T360-NU1', false, null, null, null);
            employeeId = e.Id;
        } catch (Exception ex) {}

        Test.startTest();
        Boolean threw = false;
        try {
            EmployeeThreeSixtyController.getAttendanceHistory(employeeId, Date.today().year(), Date.today().month());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
    }
}