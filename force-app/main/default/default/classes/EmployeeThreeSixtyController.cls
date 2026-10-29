/**
 * @description Controller for the Employee 360-degree View LWC component.
 *              Provides a comprehensive view of an employee including profile details,
 *              attendance KPIs, leave history, beat assignments, performance trends,
 *              recent activity, and direct reports for manager hierarchy.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class EmployeeThreeSixtyController {

    // ── Get Employee Details ──────────────────────────────────────────────────

    /**
     * @description Retrieves full Employee__c record including territory, reporting
     *              manager hierarchy, and all profile fields.
     * @param employeeId The Employee__c record Id.
     * @return The Employee__c record with all relevant fields.
     */
    @AuraEnabled(cacheable=true)
    public static Employee__c getEmployeeDetails(Id employeeId) {
        List<Employee__c> employees = [
            SELECT Id, Name, First_Name__c, Last_Name__c, Employee_Code__c,
                   Department__c, Designation__c, Phone__c, Email__c,
                   Zone__c, Region__c,
                   Territory__c, Territory__r.Name,
                   Reporting_Manager__c,
                   Reporting_Manager__r.First_Name__c,
                   Reporting_Manager__r.Last_Name__c,
                   Reporting_Manager__r.Designation__c,
                   User__c, Date_of_Joining__c, Is_Active__c,
                   Profile_Photo_URL__c, Address__c,
                                      Week_Off_Days__c
            FROM Employee__c
            WHERE Id = :employeeId
            LIMIT 1
        ];
        if (employees.isEmpty()) {
            throw new AuraHandledException('Employee not found.');
        }
        return employees[0];
    }

    // ── Get Employee KPIs ─────────────────────────────────────────────────────

    /**
     * @description Calculates comprehensive MTD KPIs for an employee including
     *              attendance percentage, order metrics, collection totals, visit
     *              counts, beat coverage, leave balances, and average hours worked.
     * @param employeeId The Employee__c record Id.
     * @return Map of KPI metric names to their computed values.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getEmployeeKPIs(Id employeeId) {
        Map<String, Object> kpis = new Map<String, Object>();

        // ── Fetch employee to get User__c link and leave balances ────
        List<Employee__c> employees = [
            SELECT Id, User__c, Week_Off_Days__c,
                   CL_Balance__c, SL_Balance__c, EL_Balance__c, CO_Balance__c
            FROM Employee__c
            WHERE Id = :employeeId
            LIMIT 1
        ];
        if (employees.isEmpty()) {
            throw new AuraHandledException('Employee not found.');
        }
        Employee__c emp = employees[0];
        Id userId = emp.User__c;

        Date today = Date.today();
        Date mtdStart = today.toStartOfMonth();

        // ── MTD Attendance Count ────────────────────────────────────
        Integer attendanceCount = [
            SELECT COUNT()
            FROM Day_Attendance__c
            WHERE User__c = :userId
            AND Attendance_Date__c >= :mtdStart
            AND Attendance_Date__c <= :today
            AND Status__c IN ('Present', 'Started', 'Completed', 'Ended', 'Auto-Closed', 'In Progress', 'Half Day')
        ];
        kpis.put('mtdAttendanceCount', attendanceCount);

        // ── MTD Total Working Days (non week-off days elapsed so far) ─
        // Respect employee-level Week_Off_Days__c (e.g. "Sunday" or "Saturday;Sunday")
        Set<String> weekOffDays = new Set<String>();
        String weekOffStr = emp.Week_Off_Days__c != null ? emp.Week_Off_Days__c : 'Sunday';
        for (String d : weekOffStr.split(';')) {
            weekOffDays.add(d.trim().toLowerCase());
        }
        Integer totalWorkingDays = 0;
        Date cursor = mtdStart;
        while (cursor <= today) {
            Datetime dt = Datetime.newInstance(cursor, Time.newInstance(0, 0, 0, 0));
            String dayOfWeek = dt.format('EEEE').toLowerCase();
            if (!weekOffDays.contains(dayOfWeek)) {
                totalWorkingDays++;
            }
            cursor = cursor.addDays(1);
        }
        kpis.put('mtdTotalWorkingDays', totalWorkingDays);

        // ── Attendance Percentage ───────────────────────────────────
        Decimal attendancePct = totalWorkingDays > 0
            ? (Decimal.valueOf(attendanceCount) / Decimal.valueOf(totalWorkingDays) * 100)
                .setScale(1, RoundingMode.HALF_UP)
            : 0;
        kpis.put('attendancePercentage', attendancePct);

        // ── MTD Order Metrics (from Day_Attendance__c aggregates) ───
        AggregateResult[] orderAgg = [
            SELECT SUM(Total_Orders__c) orderCount,
                   SUM(Total_Order_Value__c) orderValue
            FROM Day_Attendance__c
            WHERE User__c = :userId
            AND Attendance_Date__c >= :mtdStart
            AND Attendance_Date__c <= :today
        ];
        Integer mtdOrderCount = 0;
        Decimal mtdOrderValue = 0;
        if (!orderAgg.isEmpty()) {
            Decimal oc = (Decimal)orderAgg[0].get('orderCount');
            mtdOrderCount = oc != null ? oc.intValue() : 0;
            Decimal ov = (Decimal)orderAgg[0].get('orderValue');
            mtdOrderValue = ov != null ? ov : 0;
        }
        kpis.put('mtdOrderCount', mtdOrderCount);
        kpis.put('mtdOrderValue', mtdOrderValue);

        // ── MTD Collection Total ────────────────────────────────────
        AggregateResult[] collAgg = [
            SELECT SUM(Total_Collection__c) collectionTotal
            FROM Day_Attendance__c
            WHERE User__c = :userId
            AND Attendance_Date__c >= :mtdStart
            AND Attendance_Date__c <= :today
        ];
        Decimal mtdCollection = 0;
        if (!collAgg.isEmpty()) {
            Decimal cv = (Decimal)collAgg[0].get('collectionTotal');
            mtdCollection = cv != null ? cv : 0;
        }
        kpis.put('mtdCollectionTotal', mtdCollection);

        // ── MTD Visit Count and Productive Calls ────────────────────
        AggregateResult[] visitAgg = [
            SELECT SUM(Total_Visits__c) visitCount,
                   SUM(Productive_Calls__c) productiveCalls
            FROM Day_Attendance__c
            WHERE User__c = :userId
            AND Attendance_Date__c >= :mtdStart
            AND Attendance_Date__c <= :today
        ];
        Integer mtdVisitCount = 0;
        Integer mtdProductiveCalls = 0;
        if (!visitAgg.isEmpty()) {
            Decimal vc = (Decimal)visitAgg[0].get('visitCount');
            mtdVisitCount = vc != null ? vc.intValue() : 0;
            Decimal pc = (Decimal)visitAgg[0].get('productiveCalls');
            mtdProductiveCalls = pc != null ? pc.intValue() : 0;
        }
        kpis.put('mtdVisitCount', mtdVisitCount);
        kpis.put('mtdProductiveCalls', mtdProductiveCalls);

        // ── Total Beats Assigned ────────────────────────────────────
        // Check by Assigned_User__c first, then OwnerId, then Territory
        Integer totalBeats = [
            SELECT COUNT()
            FROM Beat__c
            WHERE Assigned_User__c = :userId
        ];
        if (totalBeats == 0) {
            totalBeats = [
                SELECT COUNT()
                FROM Beat__c
                WHERE OwnerId = :userId
            ];
        }
        if (totalBeats == 0 && emp.Territory__c != null) {
            Id kpiTerritoryId = emp.Territory__c;
            totalBeats = [
                SELECT COUNT()
                FROM Beat__c
                WHERE Territory__c = :kpiTerritoryId
            ];
        }
        kpis.put('totalBeatsAssigned', totalBeats);

        // ── Total Outlets Covered ───────────────────────────────────
        AggregateResult[] outletAgg = [
            SELECT SUM(Total_Outlets__c) totalOutlets
            FROM Beat__c
            WHERE Assigned_User__c = :userId
        ];
        Integer totalOutlets = 0;
        if (!outletAgg.isEmpty()) {
            Decimal ol = (Decimal)outletAgg[0].get('totalOutlets');
            totalOutlets = ol != null ? ol.intValue() : 0;
        }
        if (totalOutlets == 0) {
            outletAgg = [
                SELECT SUM(Total_Outlets__c) totalOutlets
                FROM Beat__c
                WHERE OwnerId = :userId
            ];
            if (!outletAgg.isEmpty()) {
                Decimal ol = (Decimal)outletAgg[0].get('totalOutlets');
                totalOutlets = ol != null ? ol.intValue() : 0;
            }
        }
        if (totalOutlets == 0 && emp.Territory__c != null) {
            Id kpiTerritoryId = emp.Territory__c;
            outletAgg = [
                SELECT SUM(Total_Outlets__c) totalOutlets
                FROM Beat__c
                WHERE Territory__c = :kpiTerritoryId
            ];
            if (!outletAgg.isEmpty()) {
                Decimal ol = (Decimal)outletAgg[0].get('totalOutlets');
                totalOutlets = ol != null ? ol.intValue() : 0;
            }
        }
        kpis.put('totalOutletsCovered', totalOutlets);

        // ── Leave Balance (from Leave_Balance__c) ─────────────────
        String fiscalYear = LeaveBalanceService.getCurrentFiscalYear();
        Id empId = LeaveBalanceService.getEmployeeId(userId);
        Decimal clBal = 0, slBal = 0, elBal = 0, coBal = 0;
        Decimal clEnt = 12, slEnt = 7, elEnt = 15, coEnt = 0;

        if (empId != null) {
            for (Leave_Balance__c lb : LeaveBalanceService.getBalancesForEmployee(empId, fiscalYear)) {
                Decimal avail = LeaveBalanceService.calcAvailable(lb);
                Decimal entitled = lb.Entitled__c != null ? lb.Entitled__c : 0;
                if (lb.Leave_Type__c == 'Casual Leave') { clBal = avail; clEnt = entitled; }
                else if (lb.Leave_Type__c == 'Sick Leave') { slBal = avail; slEnt = entitled; }
                else if (lb.Leave_Type__c == 'Earned Leave') { elBal = avail; elEnt = entitled; }
                else if (lb.Leave_Type__c == 'Compensatory Off') { coBal = avail; coEnt = entitled; }
            }
        }

        kpis.put('clBalance', clBal);
        kpis.put('slBalance', slBal);
        kpis.put('elBalance', elBal);
        kpis.put('coBalance', coBal);
        kpis.put('clEntitled', clEnt);
        kpis.put('slEntitled', slEnt);
        kpis.put('elEntitled', elEnt);
        kpis.put('coEntitled', coEnt);
        kpis.put('totalLeaveBalance', clBal + slBal + elBal + coBal);

        // ── Average Hours Worked (MTD) ──────────────────────────────
        AggregateResult[] hoursAgg = [
            SELECT AVG(Hours_Worked__c) avgHours
            FROM Day_Attendance__c
            WHERE User__c = :userId
            AND Attendance_Date__c >= :mtdStart
            AND Attendance_Date__c <= :today
            AND Hours_Worked__c != null
        ];
        Decimal avgHours = 0;
        if (!hoursAgg.isEmpty()) {
            Decimal ah = (Decimal)hoursAgg[0].get('avgHours');
            avgHours = ah != null ? ah.setScale(1, RoundingMode.HALF_UP) : 0;
        }
        kpis.put('avgHoursWorked', avgHours);

        return kpis;
    }

    // ── Get Attendance History ─────────────────────────────────────────────────

    /**
     * @description Retrieves Day_Attendance__c records for a given month and year,
     *              providing a complete attendance calendar view.
     * @param employeeId The Employee__c record Id.
     * @param year       The four-digit year.
     * @param month      The month number (1-12).
     * @return List of Day_Attendance__c records for the specified month.
     */
    @AuraEnabled(cacheable=true)
    public static List<Day_Attendance__c> getAttendanceHistory(Id employeeId, Integer year, Integer month) {
        Id userId = getEmployeeUserId(employeeId);

        Date monthStart = Date.newInstance(year, month, 1);
        Date monthEnd = Date.newInstance(year, month, Date.daysInMonth(year, month));

        return [
            SELECT Id, Name, Attendance_Date__c, Status__c,
                   Day_Start_Time__c, Day_End_Time__c, Hours_Worked__c,
                   Total_Visits__c, Productive_Calls__c,
                   Total_Orders__c, Total_Order_Value__c, Total_Collection__c,
                   Distance_Traveled_Km__c,
                   Start_Location_Lat__c, Start_Location_Long__c,
                   End_Location_Lat__c, End_Location_Long__c
            FROM Day_Attendance__c
            WHERE User__c = :userId
            AND Attendance_Date__c >= :monthStart
            AND Attendance_Date__c <= :monthEnd
            ORDER BY Attendance_Date__c ASC
        ];
    }

    // ── Get Leave History ──────────────────────────────────────────────────────

    /**
     * @description Retrieves Leave_Request__c records for a given year, showing
     *              all leave applications and their approval status.
     * @param employeeId The Employee__c record Id.
     * @param year       The four-digit year.
     * @return List of Leave_Request__c records for the specified year.
     */
    @AuraEnabled(cacheable=true)
    public static List<Leave_Request__c> getLeaveHistory(Id employeeId, Integer year) {
        Id userId = getEmployeeUserId(employeeId);

        Date yearStart = Date.newInstance(year, 1, 1);
        Date yearEnd = Date.newInstance(year, 12, 31);

        return [
            SELECT Id, Name, Leave_Type__c, Start_Date__c, End_Date__c,
                   Number_of_Days__c, Status__c, Reason__c, Comments__c,
                   Approved_By__c, Approved_By__r.Name, Approval_Date__c,
                   CreatedDate
            FROM Leave_Request__c
            WHERE Employee__c = :userId
            AND Start_Date__c >= :yearStart
            AND Start_Date__c <= :yearEnd
            ORDER BY Start_Date__c DESC
        ];
    }

    // ── Get Assigned Beats ────────────────────────────────────────────────────

    /**
     * @description Retrieves active Beat__c records assigned to the employee,
     *              including territory information and outlet counts.
     * @param employeeId The Employee__c record Id.
     * @return List of Beat__c records assigned to the employee.
     */
    @AuraEnabled(cacheable=true)
    public static List<Beat__c> getAssignedBeats(Id employeeId) {
        List<Employee__c> emps = [
            SELECT User__c, Territory__c
            FROM Employee__c
            WHERE Id = :employeeId
            LIMIT 1
        ];
        if (emps.isEmpty()) {
            throw new AuraHandledException('Employee not found.');
        }

        Employee__c emp = emps[0];
        List<Beat__c> beats = new List<Beat__c>();

        // First try beats directly assigned to the user (by Assigned_User__c)
        if (emp.User__c != null) {
            Id userId = emp.User__c;
            beats = [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                       Total_Outlets__c, Pincode_Cluster__c, Description__c,
                       Territory__c, Territory__r.Name,
                       Is_Active__c, Sequence__c
                FROM Beat__c
                WHERE Assigned_User__c = :userId
                ORDER BY Sequence__c NULLS LAST, Name
            ];

            // Second fallback: try beats owned by the user
            if (beats.isEmpty()) {
                beats = [
                    SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                           Total_Outlets__c, Pincode_Cluster__c, Description__c,
                           Territory__c, Territory__r.Name,
                           Is_Active__c, Sequence__c
                    FROM Beat__c
                    WHERE OwnerId = :userId
                    ORDER BY Sequence__c NULLS LAST, Name
                ];
            }
        }

        // Third fallback: show all beats in the employee's territory
        if (beats.isEmpty() && emp.Territory__c != null) {
            Id territoryId = emp.Territory__c;
            beats = [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Frequency__c,
                       Total_Outlets__c, Pincode_Cluster__c, Description__c,
                       Territory__c, Territory__r.Name,
                       Is_Active__c, Sequence__c
                FROM Beat__c
                WHERE Territory__c = :territoryId
                ORDER BY Sequence__c NULLS LAST, Name
            ];
        }

        return beats;
    }

    // ── Get Performance Trend ─────────────────────────────────────────────────

    /**
     * @description Retrieves monthly aggregated performance data for the last N months,
     *              providing trend analysis of orders, collections, and visits.
     * @param employeeId The Employee__c record Id.
     * @param months     Number of months to look back (default 6, max 24).
     * @return List of Maps containing monthly performance metrics.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getPerformanceTrend(Id employeeId, Integer months) {
        Id userId = getEmployeeUserId(employeeId);

        Integer lookback = (months != null && months > 0) ? months : 6;
        if (lookback > 24) {
            lookback = 24;
        }

        Date today = Date.today();
        Date startDate = today.addMonths(-lookback).toStartOfMonth();

        // Aggregate Day_Attendance__c by calendar month
        AggregateResult[] monthlyAgg = [
            SELECT CALENDAR_YEAR(Attendance_Date__c) yr,
                   CALENDAR_MONTH(Attendance_Date__c) mo,
                   SUM(Total_Orders__c) orderCount,
                   SUM(Total_Order_Value__c) orderValue,
                   SUM(Total_Collection__c) collectionTotal,
                   SUM(Total_Visits__c) visitCount,
                   SUM(Productive_Calls__c) productiveCalls
            FROM Day_Attendance__c
            WHERE User__c = :userId
            AND Attendance_Date__c >= :startDate
            AND Attendance_Date__c <= :today
            GROUP BY CALENDAR_YEAR(Attendance_Date__c), CALENDAR_MONTH(Attendance_Date__c)
            ORDER BY CALENDAR_YEAR(Attendance_Date__c) ASC, CALENDAR_MONTH(Attendance_Date__c) ASC
        ];

        List<Map<String, Object>> trend = new List<Map<String, Object>>();
        List<String> monthNames = new List<String>{
            '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        };

        for (AggregateResult ar : monthlyAgg) {
            Map<String, Object> row = new Map<String, Object>();
            Integer yr = (Integer)ar.get('yr');
            Integer mo = (Integer)ar.get('mo');
            row.put('month', monthNames[mo] + ' ' + yr);
            row.put('year', yr);
            row.put('monthNumber', mo);

            Decimal oc = (Decimal)ar.get('orderCount');
            row.put('orderCount', oc != null ? oc.intValue() : 0);

            Decimal ov = (Decimal)ar.get('orderValue');
            row.put('orderValue', ov != null ? ov : 0);

            Decimal ct = (Decimal)ar.get('collectionTotal');
            row.put('collectionTotal', ct != null ? ct : 0);

            Decimal vc = (Decimal)ar.get('visitCount');
            row.put('visitCount', vc != null ? vc.intValue() : 0);

            Decimal pc = (Decimal)ar.get('productiveCalls');
            row.put('productiveCalls', pc != null ? pc.intValue() : 0);

            trend.add(row);
        }

        return trend;
    }

    // ── Get Recent Activity ───────────────────────────────────────────────────

    /**
     * @description Retrieves recent Day_Attendance__c records showing the daily
     *              activity summary for an employee.
     * @param employeeId The Employee__c record Id.
     * @param limitCount Maximum number of records to return (default 15, max 100).
     * @return List of Day_Attendance__c records ordered by most recent first.
     */
    @AuraEnabled(cacheable=true)
    public static List<Day_Attendance__c> getRecentActivity(Id employeeId, Integer limitCount) {
        Id userId = getEmployeeUserId(employeeId);

        Integer queryLimit = (limitCount != null && limitCount > 0) ? limitCount : 15;
        if (queryLimit > 100) {
            queryLimit = 100;
        }

        return [
            SELECT Id, Name, Attendance_Date__c, Status__c,
                   Day_Start_Time__c, Day_End_Time__c, Hours_Worked__c,
                   Total_Visits__c, Productive_Calls__c,
                   Total_Orders__c, Total_Order_Value__c, Total_Collection__c,
                   Distance_Traveled_Km__c
            FROM Day_Attendance__c
            WHERE User__c = :userId
            ORDER BY Attendance_Date__c DESC
            LIMIT :queryLimit
        ];
    }

    // ── Get Direct Reports ────────────────────────────────────────────────────

    /**
     * @description Retrieves Employee__c records that report to the given employee,
     *              including their basic MTD KPIs for a manager's team overview.
     * @param employeeId The Employee__c record Id (manager).
     * @return List of Maps containing each direct report's profile and summary KPIs.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getDirectReports(Id employeeId) {
        List<Employee__c> directReports = [
            SELECT Id, Name, First_Name__c, Last_Name__c, Employee_Code__c,
                   Department__c, Designation__c, Phone__c, Email__c,
                   Profile_Photo_URL__c, User__c, Is_Active__c,
                   Territory__c, Territory__r.Name
            FROM Employee__c
            WHERE Reporting_Manager__c = :employeeId
            AND Is_Active__c = true
            ORDER BY First_Name__c, Last_Name__c
        ];

        if (directReports.isEmpty()) {
            return new List<Map<String, Object>>();
        }

        // Collect User Ids for bulk KPI lookup
        Set<Id> userIds = new Set<Id>();
        for (Employee__c dr : directReports) {
            if (dr.User__c != null) {
                userIds.add(dr.User__c);
            }
        }

        // Get MTD attendance counts per user
        Date today = Date.today();
        Date mtdStart = today.toStartOfMonth();

        Map<Id, Integer> attendanceByUser = new Map<Id, Integer>();
        Map<Id, Decimal> orderValueByUser = new Map<Id, Decimal>();
        Map<Id, Decimal> collectionByUser = new Map<Id, Decimal>();
        Map<Id, Integer> visitsByUser = new Map<Id, Integer>();

        if (!userIds.isEmpty()) {
            // Attendance count per user
            AggregateResult[] attAgg = [
                SELECT User__c uid, COUNT(Id) attCount
                FROM Day_Attendance__c
                WHERE User__c IN :userIds
                AND Attendance_Date__c >= :mtdStart
                AND Attendance_Date__c <= :today
                AND Status__c IN ('Present', 'Started', 'Completed', 'Ended', 'Auto-Closed', 'In Progress', 'Half Day')
                GROUP BY User__c
            ];
            for (AggregateResult ar : attAgg) {
                attendanceByUser.put((Id)ar.get('uid'), (Integer)ar.get('attCount'));
            }

            // Order value and collection per user
            AggregateResult[] perfAgg = [
                SELECT User__c uid,
                       SUM(Total_Order_Value__c) orderVal,
                       SUM(Total_Collection__c) collVal,
                       SUM(Total_Visits__c) visitCnt
                FROM Day_Attendance__c
                WHERE User__c IN :userIds
                AND Attendance_Date__c >= :mtdStart
                AND Attendance_Date__c <= :today
                GROUP BY User__c
            ];
            for (AggregateResult ar : perfAgg) {
                Id uid = (Id)ar.get('uid');
                Decimal ov = (Decimal)ar.get('orderVal');
                orderValueByUser.put(uid, ov != null ? ov : 0);
                Decimal cv = (Decimal)ar.get('collVal');
                collectionByUser.put(uid, cv != null ? cv : 0);
                Decimal vc = (Decimal)ar.get('visitCnt');
                visitsByUser.put(uid, vc != null ? vc.intValue() : 0);
            }
        }

        // Build result with employee details and KPIs
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (Employee__c dr : directReports) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('employeeId', dr.Id);
            row.put('name', dr.First_Name__c + ' ' + dr.Last_Name__c);
            row.put('firstName', dr.First_Name__c);
            row.put('lastName', dr.Last_Name__c);
            row.put('employeeCode', dr.Employee_Code__c);
            row.put('designation', dr.Designation__c);
            row.put('department', dr.Department__c);
            row.put('phone', dr.Phone__c);
            row.put('email', dr.Email__c);
            row.put('profilePhotoUrl', dr.Profile_Photo_URL__c);
            row.put('territoryName', dr.Territory__r != null ? dr.Territory__r.Name : null);
            row.put('isActive', dr.Is_Active__c);

            Id uid = dr.User__c;
            row.put('mtdAttendanceDays', attendanceByUser.containsKey(uid)
                ? attendanceByUser.get(uid) : 0);
            row.put('mtdOrderValue', orderValueByUser.containsKey(uid)
                ? orderValueByUser.get(uid) : 0);
            row.put('mtdCollectionTotal', collectionByUser.containsKey(uid)
                ? collectionByUser.get(uid) : 0);
            row.put('mtdVisitCount', visitsByUser.containsKey(uid)
                ? visitsByUser.get(uid) : 0);

            results.add(row);
        }

        return results;
    }

    // ── Get Current User's Employee Id ────────────────────────────────────────

    /**
     * @description Resolves the Employee__c record Id for the current logged-in user.
     *              Used when the component is placed on a Tab without an explicit employeeId.
     * @return The Employee__c record Id for the current user.
     */
    @AuraEnabled(cacheable=true)
    public static Id getMyEmployeeId() {
        Id currentUserId = UserInfo.getUserId();
        List<Employee__c> employees = [
            SELECT Id FROM Employee__c
            WHERE User__c = :currentUserId
            AND Is_Active__c = true
            LIMIT 1
        ];
        if (employees.isEmpty()) {
            throw new AuraHandledException('No Employee record found for the current user.');
        }
        return employees[0].Id;
    }

    // ── Get Holidays for Month ─────────────────────────────────────────────

    /**
     * @description Retrieves active Holiday__c records for a given month/year,
     *              optionally filtered by the employee's territory.
     * @param employeeId The Employee__c record Id (used for territory filtering).
     * @param year       The four-digit year.
     * @param month      The month (1-12).
     * @return List of Holiday__c records for the month.
     */
    @AuraEnabled(cacheable=true)
    public static List<Holiday__c> getHolidaysForMonth(Id employeeId, Integer year, Integer month) {
        Date startDate = Date.newInstance(year, month, 1);
        Date endDate = startDate.addMonths(1).addDays(-1);

        // Get employee's territory for filtering regional holidays
        Id territoryId = null;
        if (employeeId != null) {
            List<Employee__c> emps = [
                SELECT Territory__c FROM Employee__c WHERE Id = :employeeId LIMIT 1
            ];
            if (!emps.isEmpty()) {
                territoryId = emps[0].Territory__c;
            }
        }

        // Return holidays that are either not territory-specific or match the employee's territory
        if (territoryId != null) {
            return [
                SELECT Id, Name, Holiday_Date__c, Type__c, Description__c
                FROM Holiday__c
                WHERE Holiday_Date__c >= :startDate
                AND Holiday_Date__c <= :endDate
                AND Is_Active__c = true
                AND (Territory__c = null OR Territory__c = :territoryId)
                ORDER BY Holiday_Date__c ASC
            ];
        } else {
            return [
                SELECT Id, Name, Holiday_Date__c, Type__c, Description__c
                FROM Holiday__c
                WHERE Holiday_Date__c >= :startDate
                AND Holiday_Date__c <= :endDate
                AND Is_Active__c = true
                AND Territory__c = null
                ORDER BY Holiday_Date__c ASC
            ];
        }
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    /**
     * @description Resolves the User__c Id from an Employee__c record.
     *              Used by multiple methods to bridge Employee to User-based queries.
     * @param employeeId The Employee__c record Id.
     * @return The associated User Id.
     */
    private static Id getEmployeeUserId(Id employeeId) {
        List<Employee__c> employees = [
            SELECT User__c
            FROM Employee__c
            WHERE Id = :employeeId
            LIMIT 1
        ];
        if (employees.isEmpty()) {
            throw new AuraHandledException('Employee not found.');
        }
        if (employees[0].User__c == null) {
            throw new AuraHandledException('Employee does not have a linked User record.');
        }
        return employees[0].User__c;
    }
}