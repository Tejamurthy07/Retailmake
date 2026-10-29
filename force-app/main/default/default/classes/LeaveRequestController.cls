/**
 * @description Controller for the Leave Request LWC component.
 *              Manages leave request lifecycle: creation, approval, rejection,
 *              cancellation, balance tracking, and team leave visibility
 *              for FMCG field sales workforce management.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class LeaveRequestController {

    // Default balance fallback (used only when no Leave_Balance__c records exist)
    private static final Map<String, Decimal> DEFAULT_BALANCE = new Map<String, Decimal>{
        'CL' => 12,
        'SL' => 7,
        'EL' => 15,
        'CO' => 0
    };

    // ── Check if User is a Manager or Admin ──────────────────────────────────

    /**
     * @description Checks whether the given user is a manager (has direct reports)
     *              or a System Administrator. Both roles can access leave approvals.
     * @param userId The User Id to check.
     * @return True if the user has at least one direct report or is an Admin.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean checkIsManager(Id userId) {
        // Admins can always access leave approvals
        if (checkIsAdmin(userId)) {
            return true;
        }

        List<Employee__c> managerEmployees = [
            SELECT Id
            FROM Employee__c
            WHERE User__c = :userId
            LIMIT 1
        ];

        if (managerEmployees.isEmpty()) {
            return false;
        }

        Id managerEmployeeId = managerEmployees[0].Id;

        Integer directReportCount = [
            SELECT COUNT()
            FROM Employee__c
            WHERE Reporting_Manager__c = :managerEmployeeId
            AND Is_Active__c = true
        ];

        return directReportCount > 0;
    }

    // ── Check if User is an Admin ─────────────────────────────────────────

    /**
     * @description Checks whether the given user has the System Administrator profile.
     * @param userId The User Id to check.
     * @return True if the user is a System Administrator.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean checkIsAdmin(Id userId) {
        // Primary: custom permission (works in managed packages and subscriber orgs)
        if (FeatureManagement.checkPermission('Leave_Admin_Access')) {
            return true;
        }
        // Fallback: system admins by profile license (not name — portable across orgs)
        List<User> users = [
            SELECT Profile.PermissionsModifyAllData
            FROM User
            WHERE Id = :userId
            LIMIT 1
        ];
        return !users.isEmpty() && users[0].Profile.PermissionsModifyAllData == true;
    }

    // ── Get Reporting Manager User Id ───────────────────────────────────────

    /**
     * @description Retrieves the User Id of the reporting manager for a given
     *              employee (User Id). Traverses Employee__c -> Reporting_Manager__c -> User__c.
     * @param userId The User Id of the employee.
     * @return The User Id of the reporting manager, or null if not found.
     */
    @AuraEnabled
    public static Id getReportingManagerUserId(Id userId) {
        List<Employee__c> employees = [
            SELECT Reporting_Manager__c, Reporting_Manager__r.User__c
            FROM Employee__c
            WHERE User__c = :userId
            LIMIT 1
        ];

        if (employees.isEmpty() || employees[0].Reporting_Manager__c == null) {
            return null;
        }

        return employees[0].Reporting_Manager__r.User__c;
    }

    // ── Get Pending Approvals for Manager ───────────────────────────────────

    /**
     * @description Retrieves pending leave requests for approval. For managers,
     *              returns only requests assigned to them. For admins, returns
     *              all pending/submitted requests across the organization.
     * @param managerId The User Id of the manager/approver.
     * @return List of Leave_Request__c records pending approval.
     */
    @AuraEnabled
    public static List<Leave_Request__c> getPendingApprovalsForManager(Id managerId) {
        if (checkIsAdmin(managerId)) {
            return [
                SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                       Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                       Number_of_Days__c, Reason__c, Status__c,
                       Approved_By__c, Approved_By__r.Name, Approval_Date__c, Comments__c,
                       CreatedDate
                FROM Leave_Request__c
                WHERE Status__c IN ('Pending', 'Submitted')
                ORDER BY CreatedDate DESC
            ];
        }
        return [
            SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                   Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                   Number_of_Days__c, Reason__c, Status__c,
                   Approved_By__c, Approved_By__r.Name, Approval_Date__c, Comments__c,
                   CreatedDate
            FROM Leave_Request__c
            WHERE Approved_By__c = :managerId
            AND Status__c IN ('Pending', 'Submitted')
            ORDER BY CreatedDate DESC
        ];
    }

    // ── Get Approval History for Manager ────────────────────────────────────

    /**
     * @description Retrieves recently decided leave requests (Approved/Rejected).
     *              For managers, returns only their decisions. For admins, returns
     *              all recent decisions across the organization.
     * @param managerId The User Id of the manager/approver.
     * @return List of recently decided Leave_Request__c records.
     */
    @AuraEnabled
    public static List<Leave_Request__c> getApprovalHistoryForManager(Id managerId) {
        if (checkIsAdmin(managerId)) {
            return [
                SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                       Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                       Number_of_Days__c, Reason__c, Status__c,
                       Approved_By__c, Approved_By__r.Name, Approval_Date__c, Comments__c
                FROM Leave_Request__c
                WHERE Status__c IN ('Approved', 'Rejected')
                ORDER BY Approval_Date__c DESC
                LIMIT 50
            ];
        }
        return [
            SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                   Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                   Number_of_Days__c, Reason__c, Status__c,
                   Approved_By__c, Approved_By__r.Name, Approval_Date__c, Comments__c
            FROM Leave_Request__c
            WHERE Approved_By__c = :managerId
            AND Status__c IN ('Approved', 'Rejected')
            ORDER BY Approval_Date__c DESC
            LIMIT 50
        ];
    }

    // ── Get Leave Requests ────────────────────────────────────────────────────

    /**
     * @description Retrieves leave requests for a specific user, optionally filtered
     *              by status and year. Includes the Employee relationship name.
     * @param userId The User Id whose leave requests to retrieve.
     * @param status Optional status filter (e.g. 'Pending', 'Approved'). Pass null to skip.
     * @param year   Optional year filter. Pass null or 0 to skip.
     * @return List of Leave_Request__c records ordered by Start_Date__c DESC.
     */
    @AuraEnabled
    public static List<Leave_Request__c> getLeaveRequests(Id userId, String status, Integer year) {
        String query = 'SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c, ' +
            'Start_Date__c, Start_Session__c, End_Date__c, End_Session__c, Number_of_Days__c, Reason__c, Status__c, ' +
            'Approved_By__c, Approved_By__r.Name, Approval_Date__c, Comments__c ' +
            'FROM Leave_Request__c WHERE Employee__c = :userId';

        if (String.isNotBlank(status)) {
            query += ' AND Status__c = :status';
        }
        if (year != null && year > 0) {
            query += ' AND CALENDAR_YEAR(Start_Date__c) = :year';
        }

        query += ' ORDER BY Start_Date__c DESC';

        return Database.query(query);
    }

    // ── Get Team Leave Requests ───────────────────────────────────────────────

    /**
     * @description Retrieves leave requests for all direct reports of a manager.
     *              Looks up the manager's Employee__c record, finds direct reports
     *              via Reporting_Manager__c, then queries their leave requests.
     * @param managerId The User Id of the manager.
     * @param status    Optional status filter. Pass null to skip.
     * @return List of Leave_Request__c records for the manager's team.
     */
    @AuraEnabled
    public static List<Leave_Request__c> getTeamLeaveRequests(Id managerId, String status) {
        // Find the manager's Employee__c record
        List<Employee__c> managerEmployees = [
            SELECT Id
            FROM Employee__c
            WHERE User__c = :managerId
            LIMIT 1
        ];

        if (managerEmployees.isEmpty()) {
            return new List<Leave_Request__c>();
        }

        Id managerEmployeeId = managerEmployees[0].Id;

        // Find direct reports via the self-referencing Reporting_Manager__c lookup
        List<Employee__c> directReports = [
            SELECT User__c
            FROM Employee__c
            WHERE Reporting_Manager__c = :managerEmployeeId
            AND Is_Active__c = true
        ];

        if (directReports.isEmpty()) {
            return new List<Leave_Request__c>();
        }

        Set<Id> reportUserIds = new Set<Id>();
        for (Employee__c emp : directReports) {
            reportUserIds.add(emp.User__c);
        }

        String query = 'SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c, ' +
            'Start_Date__c, Start_Session__c, End_Date__c, End_Session__c, Number_of_Days__c, Reason__c, Status__c, ' +
            'Approved_By__c, Approved_By__r.Name, Approval_Date__c, Comments__c ' +
            'FROM Leave_Request__c WHERE Employee__c IN :reportUserIds';

        if (String.isNotBlank(status)) {
            query += ' AND Status__c = :status';
        }

        query += ' ORDER BY Start_Date__c DESC';

        return Database.query(query);
    }

    // ── Save Leave Request ────────────────────────────────────────────────────

    /**
     * @description Inserts or updates a Leave_Request__c record. Auto-calculates
     *              Number_of_Days__c from Start_Date__c/End_Date__c counting only
     *              business days (Mon-Fri), adjusted by Start_Session__c and
     *              End_Session__c for half-day precision. Validates leave balance
     *              before saving. New records automatically populate Approved_By__c
     *              with the reporting manager and set Status to 'Submitted'.
     * @param leaveRequest The Leave_Request__c record to save.
     * @return The saved Leave_Request__c record.
     */
    @AuraEnabled
    public static Leave_Request__c saveLeaveRequest(Leave_Request__c leaveRequest) {
        Savepoint sp = Database.setSavepoint();
        try {
            // Validate required dates
            if (leaveRequest.Start_Date__c == null || leaveRequest.End_Date__c == null) {
                throw new AuraHandledException('Start Date and End Date are required.');
            }
            if (leaveRequest.End_Date__c < leaveRequest.Start_Date__c) {
                throw new AuraHandledException('End Date cannot be before Start Date.');
            }

            // Validate session combination for same date
            String startSession = leaveRequest.Start_Session__c != null ? leaveRequest.Start_Session__c : 'Session 1';
            String endSession = leaveRequest.End_Session__c != null ? leaveRequest.End_Session__c : 'Session 2';

            if (leaveRequest.Start_Date__c == leaveRequest.End_Date__c &&
                startSession == 'Session 2' && endSession == 'Session 1') {
                throw new AuraHandledException(
                    'Invalid session selection. To Session cannot be Session 1 when From Session is Session 2 on the same date.'
                );
            }

            // Calculate business days with session adjustments
            Decimal numberOfDays = calculateBusinessDays(leaveRequest.Start_Date__c, leaveRequest.End_Date__c);

            // Adjust for sessions: Session 2 start = subtract 0.5, Session 1 end = subtract 0.5
            if (startSession == 'Session 2') {
                numberOfDays -= 0.5;
            }
            if (endSession == 'Session 1') {
                numberOfDays -= 0.5;
            }

            leaveRequest.Number_of_Days__c = numberOfDays;

            if (numberOfDays <= 0) {
                throw new AuraHandledException(
                    'The selected date range does not contain any business days.'
                );
            }

            Boolean isNew = leaveRequest.Id == null;
            if (isNew) {
                // Auto-populate Approved_By__c with reporting manager
                Id reportingManagerUserId = getReportingManagerUserId(leaveRequest.Employee__c);
                if (reportingManagerUserId != null) {
                    leaveRequest.Approved_By__c = reportingManagerUserId;
                }

                // Set status to Submitted (sent for approval)
                leaveRequest.Status__c = 'Submitted';
            }

            // Validate leave balance using Leave_Balance__c
            String fiscalYear = LeaveBalanceService.getCurrentFiscalYear();
            // Employee__c on Leave_Request__c is a Lookup(User), need Employee__c record Id
            Id employeeId = LeaveBalanceService.getEmployeeId(leaveRequest.Employee__c);
            if (employeeId == null) {
                throw new AuraHandledException('No employee record linked to your user. Please contact HR.');
            }
            LeaveBalanceService.validateBalance(employeeId, leaveRequest.Leave_Type__c, numberOfDays, fiscalYear);

            upsert leaveRequest;

            // Add to pending balance
            if (isNew) {
                LeaveBalanceService.addPending(employeeId, leaveRequest.Leave_Type__c, numberOfDays, fiscalYear);
            }

            return [
                SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                       Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                       Number_of_Days__c, Reason__c,
                       Status__c, Approved_By__c, Approved_By__r.Name,
                       Approval_Date__c, Comments__c
                FROM Leave_Request__c
                WHERE Id = :leaveRequest.Id
                LIMIT 1
            ];
        } catch (AuraHandledException ahe) {
            Database.rollback(sp);
            throw ahe;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Approve Leave Request ─────────────────────────────────────────────────

    /**
     * @description Approves a leave request by setting Status to 'Approved',
     *              recording the approver and approval timestamp, and deducting
     *              the corresponding leave balance from the employee's record.
     * @param leaveRequestId The Id of the Leave_Request__c to approve.
     * @param comments       Optional approval comments.
     * @return The updated Leave_Request__c record.
     */
    @AuraEnabled
    public static Leave_Request__c approveLeaveRequest(Id leaveRequestId, String comments) {
        Savepoint sp = Database.setSavepoint();
        try {
            Leave_Request__c request = [
                SELECT Id, Employee__c, Leave_Type__c, Number_of_Days__c, Status__c,
                       Approved_By__c, Comments__c
                FROM Leave_Request__c
                WHERE Id = :leaveRequestId
                LIMIT 1
            ];

            if (request.Status__c == 'Approved') {
                throw new AuraHandledException('This leave request has already been approved.');
            }
            if (request.Status__c == 'Cancelled') {
                throw new AuraHandledException('Cannot approve a cancelled leave request.');
            }

            request.Status__c = 'Approved';
            request.Approved_By__c = UserInfo.getUserId();
            request.Approval_Date__c = Datetime.now();
            if (String.isNotBlank(comments)) {
                request.Comments__c = comments;
            }
            update request;

            // Deduct leave balance using Leave_Balance__c
            String fiscalYear = LeaveBalanceService.getCurrentFiscalYear();
            Id empId = LeaveBalanceService.getEmployeeId(request.Employee__c);
            if (empId != null) {
                LeaveBalanceService.deductBalance(empId, request.Leave_Type__c, request.Number_of_Days__c, fiscalYear);
            }

            return [
                SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                       Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                       Number_of_Days__c, Reason__c,
                       Status__c, Approved_By__c, Approved_By__r.Name,
                       Approval_Date__c, Comments__c
                FROM Leave_Request__c
                WHERE Id = :leaveRequestId
                LIMIT 1
            ];
        } catch (AuraHandledException ahe) {
            Database.rollback(sp);
            throw ahe;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Reject Leave Request ──────────────────────────────────────────────────

    /**
     * @description Rejects a leave request by setting Status to 'Rejected'
     *              and recording the rejection comments.
     * @param leaveRequestId The Id of the Leave_Request__c to reject.
     * @param comments       Rejection reason/comments.
     * @return The updated Leave_Request__c record.
     */
    @AuraEnabled
    public static Leave_Request__c rejectLeaveRequest(Id leaveRequestId, String comments) {
        try {
            Leave_Request__c request = [
                SELECT Id, Status__c, Approved_By__c
                FROM Leave_Request__c
                WHERE Id = :leaveRequestId
                LIMIT 1
            ];

            if (request.Status__c == 'Rejected') {
                throw new AuraHandledException('This leave request has already been rejected.');
            }
            if (request.Status__c == 'Cancelled') {
                throw new AuraHandledException('Cannot reject a cancelled leave request.');
            }

            request.Status__c = 'Rejected';
            request.Approved_By__c = UserInfo.getUserId();
            request.Approval_Date__c = Datetime.now();
            if (String.isNotBlank(comments)) {
                request.Comments__c = comments;
            }
            update request;

            // Remove from pending balance
            String fiscalYear = LeaveBalanceService.getCurrentFiscalYear();
            Id empIdReject = LeaveBalanceService.getEmployeeId(request.Employee__c);
            if (empIdReject != null) {
                LeaveBalanceService.removePending(empIdReject, request.Leave_Type__c, request.Number_of_Days__c, fiscalYear);
            }

            return [
                SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                       Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                       Number_of_Days__c, Reason__c,
                       Status__c, Approved_By__c, Approved_By__r.Name,
                       Approval_Date__c, Comments__c
                FROM Leave_Request__c
                WHERE Id = :leaveRequestId
                LIMIT 1
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Cancel Leave Request ──────────────────────────────────────────────────

    /**
     * @description Cancels a leave request. If the request was previously Approved,
     *              restores the deducted leave balance back to the employee's record.
     * @param leaveRequestId The Id of the Leave_Request__c to cancel.
     * @return The updated Leave_Request__c record.
     */
    @AuraEnabled
    public static Leave_Request__c cancelLeaveRequest(Id leaveRequestId) {
        Savepoint sp = Database.setSavepoint();
        try {
            Leave_Request__c request = [
                SELECT Id, Employee__c, Leave_Type__c, Number_of_Days__c, Status__c
                FROM Leave_Request__c
                WHERE Id = :leaveRequestId
                LIMIT 1
            ];

            if (request.Status__c == 'Cancelled') {
                throw new AuraHandledException('This leave request has already been cancelled.');
            }

            Boolean wasApproved = request.Status__c == 'Approved';

            request.Status__c = 'Cancelled';
            update request;

            // Restore leave balance if the request was previously approved
            String fiscalYear = LeaveBalanceService.getCurrentFiscalYear();
            Id empIdCancel = LeaveBalanceService.getEmployeeId(request.Employee__c);
            if (empIdCancel != null) {
                if (wasApproved) {
                    LeaveBalanceService.restoreBalance(empIdCancel, request.Leave_Type__c, request.Number_of_Days__c, fiscalYear);
                } else {
                    LeaveBalanceService.removePending(empIdCancel, request.Leave_Type__c, request.Number_of_Days__c, fiscalYear);
                }
            }

            return [
                SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                       Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                       Number_of_Days__c, Reason__c,
                       Status__c, Approved_By__c, Approved_By__r.Name,
                       Approval_Date__c, Comments__c
                FROM Leave_Request__c
                WHERE Id = :leaveRequestId
                LIMIT 1
            ];
        } catch (AuraHandledException ahe) {
            Database.rollback(sp);
            throw ahe;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Get Leave Balance ─────────────────────────────────────────────────────

    /**
     * @description Retrieves the leave balance for a user from the Employee__c record.
     *              Returns a map with keys CL, SL, EL, CO and their respective balances.
     * @param userId The User Id to look up leave balances for.
     * @return Map with leave type abbreviation keys and Decimal balance values.
     */
    @AuraEnabled
    public static Map<String, Object> getLeaveBalance(Id userId) {
        String fiscalYear = LeaveBalanceService.getCurrentFiscalYear();
        List<Leave_Balance__c> balances = LeaveBalanceService.getBalancesForUser(userId, fiscalYear);

        Map<String, Object> result = new Map<String, Object>();
        List<Map<String, Object>> balanceList = new List<Map<String, Object>>();

        // Short type mapping for backward compatibility
        Map<String, String> shortTypeMap = new Map<String, String>{
            'Casual Leave' => 'CL', 'Sick Leave' => 'SL',
            'Earned Leave' => 'EL', 'Compensatory Off' => 'CO',
            'Maternity Leave' => 'ML', 'Paternity Leave' => 'PL',
            'Loss of Pay' => 'LOP'
        };

        Map<String, Decimal> simpleBalance = new Map<String, Decimal>();

        for (Leave_Balance__c lb : balances) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('leaveType', lb.Leave_Type__c);
            row.put('entitled', lb.Entitled__c);
            row.put('accrued', lb.Accrued__c);
            row.put('carryForward', lb.Carry_Forward__c);
            row.put('used', lb.Used__c);
            row.put('pending', lb.Pending__c);
            Decimal available = LeaveBalanceService.calcAvailable(lb);
            row.put('available', available);
            balanceList.add(row);

            String shortType = shortTypeMap.get(lb.Leave_Type__c);
            if (shortType != null) {
                simpleBalance.put(shortType, available);
            }
        }

        // If no balances found, return defaults
        if (balances.isEmpty()) {
            simpleBalance.put('CL', DEFAULT_BALANCE.get('CL'));
            simpleBalance.put('SL', DEFAULT_BALANCE.get('SL'));
            simpleBalance.put('EL', DEFAULT_BALANCE.get('EL'));
            simpleBalance.put('CO', DEFAULT_BALANCE.get('CO'));
        }

        result.put('balances', balanceList);
        result.put('simple', simpleBalance);
        result.put('year', fiscalYear);

        return result;
    }

    // ── Get Leaves Summary ────────────────────────────────────────────────────

    /**
     * @description Returns aggregated leave counts grouped by leave type and status
     *              for a specific user and year. Useful for dashboard widgets.
     * @param userId The User Id whose leave summary to retrieve.
     * @param year   The calendar year to summarise.
     * @return Map with composite keys (e.g. 'Casual Leave_Approved') and count values.
     */
    @AuraEnabled
    public static Map<String, Integer> getLeavesSummary(Id userId, Integer year) {
        Map<String, Integer> summary = new Map<String, Integer>();

        List<AggregateResult> results = [
            SELECT Leave_Type__c leaveType, Status__c status, COUNT(Id) cnt
            FROM Leave_Request__c
            WHERE Employee__c = :userId
            AND CALENDAR_YEAR(Start_Date__c) = :year
            GROUP BY Leave_Type__c, Status__c
        ];

        for (AggregateResult ar : results) {
            String leaveType = (String) ar.get('leaveType');
            String status = (String) ar.get('status');
            Integer cnt = (Integer) ar.get('cnt');
            summary.put(leaveType + '_' + status, cnt);
        }

        return summary;
    }

    // ── Get Upcoming Leaves ───────────────────────────────────────────────────

    /**
     * @description Retrieves future approved or pending leave requests for a user,
     *              ordered by start date ascending.
     * @param userId     The User Id whose upcoming leaves to retrieve.
     * @param limitCount Maximum number of records to return.
     * @return List of upcoming Leave_Request__c records.
     */
    @AuraEnabled
    public static List<Leave_Request__c> getUpcomingLeaves(Id userId, Integer limitCount) {
        if (limitCount == null || limitCount <= 0) {
            limitCount = 10;
        }

        return [
            SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                   Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                   Number_of_Days__c, Reason__c,
                   Status__c, Comments__c
            FROM Leave_Request__c
            WHERE Employee__c = :userId
            AND Start_Date__c >= :Date.today()
            AND Status__c IN ('Approved', 'Pending', 'Submitted')
            ORDER BY Start_Date__c ASC
            LIMIT :limitCount
        ];
    }

    // ── Get Team Leaves on Date ───────────────────────────────────────────────

    /**
     * @description Retrieves all team members who are on approved leave for a specific
     *              date. Useful for journey plan integration to show team availability.
     * @param targetDate The date to check for leaves.
     * @param managerId  The User Id of the manager.
     * @return List of Leave_Request__c records for team members on leave that date.
     */
    @AuraEnabled
    public static List<Leave_Request__c> getTeamLeavesOnDate(Date targetDate, Id managerId) {
        // Find the manager's Employee__c record
        List<Employee__c> managerEmployees = [
            SELECT Id
            FROM Employee__c
            WHERE User__c = :managerId
            LIMIT 1
        ];

        if (managerEmployees.isEmpty()) {
            return new List<Leave_Request__c>();
        }

        Id managerEmployeeId = managerEmployees[0].Id;

        // Find direct reports
        List<Employee__c> directReports = [
            SELECT User__c
            FROM Employee__c
            WHERE Reporting_Manager__c = :managerEmployeeId
            AND Is_Active__c = true
        ];

        if (directReports.isEmpty()) {
            return new List<Leave_Request__c>();
        }

        Set<Id> reportUserIds = new Set<Id>();
        for (Employee__c emp : directReports) {
            reportUserIds.add(emp.User__c);
        }

        return [
            SELECT Id, Name, Employee__c, Employee__r.Name, Leave_Type__c,
                   Start_Date__c, Start_Session__c, End_Date__c, End_Session__c,
                   Number_of_Days__c, Status__c
            FROM Leave_Request__c
            WHERE Employee__c IN :reportUserIds
            AND Start_Date__c <= :targetDate
            AND End_Date__c >= :targetDate
            AND Status__c = 'Approved'
            ORDER BY Employee__r.Name ASC
        ];
    }

    // ── Private Helper: Calculate Business Days ───────────────────────────────

    private static Decimal calculateBusinessDays(Date startDate, Date endDate) {
        Integer businessDays = 0;
        Date current = startDate;

        while (current <= endDate) {
            DateTime dt = DateTime.newInstance(current, Time.newInstance(0, 0, 0, 0));
            String dayOfWeek = dt.format('EEEE');
            if (dayOfWeek != 'Saturday' && dayOfWeek != 'Sunday') {
                businessDays++;
            }
            current = current.addDays(1);
        }

        return Decimal.valueOf(businessDays);
    }

    // Old private helpers removed — now delegated to LeaveBalanceService:
    // validateLeaveBalance → LeaveBalanceService.validateBalance()
    // deductLeaveBalance → LeaveBalanceService.deductBalance()
    // restoreLeaveBalance → LeaveBalanceService.restoreBalance()
}