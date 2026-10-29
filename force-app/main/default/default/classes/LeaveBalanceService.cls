/**
 * @description Service class for managing leave balances.
 *              Handles yearly initialization, monthly accrual, carry forward,
 *              balance deduction/restoration, and policy matching.
 */
public with sharing class LeaveBalanceService {

    // ═══════════════════════════════════════════════════════════════
    // YEARLY RESET: Initialize balances for a new fiscal year
    // Creates Leave_Balance__c records for all active employees
    // based on matching Leave_Policy__c records
    // ═══════════════════════════════════════════════════════════════

    public static void initializeYearlyBalances(String year) {
        // Load active policies for this year (or universal)
        List<Leave_Policy__c> policies = [
            SELECT Id, Leave_Type__c, Designation__c, Annual_Entitlement__c,
                   Monthly_Accrual__c, Max_Carry_Forward__c
            FROM Leave_Policy__c
            WHERE Is_Active__c = true
            AND (Effective_Year__c = :year OR Effective_Year__c = null)
            ORDER BY Designation__c NULLS LAST
        ];

        if (policies.isEmpty()) return;

        // Load active employees
        List<Employee__c> employees = [
            SELECT Id, Designation__c FROM Employee__c WHERE Is_Active__c = true
        ];

        // Load previous year balances for carry forward
        String prevYear = String.valueOf(Integer.valueOf(year) - 1);
        Map<String, Leave_Balance__c> prevBalanceMap = new Map<String, Leave_Balance__c>();
        for (Leave_Balance__c lb : [
            SELECT Id, Employee__c, Leave_Type__c, Accrued__c, Carry_Forward__c, Used__c, Pending__c
            FROM Leave_Balance__c
            WHERE Year__c = :prevYear
        ]) {
            prevBalanceMap.put(lb.Employee__c + '-' + lb.Leave_Type__c, lb);
        }

        // Check existing balances for this year (avoid duplicates)
        Set<String> existingKeys = new Set<String>();
        for (Leave_Balance__c lb : [
            SELECT Employee__c, Leave_Type__c FROM Leave_Balance__c WHERE Year__c = :year
        ]) {
            existingKeys.add(lb.Employee__c + '-' + lb.Leave_Type__c);
        }

        List<Leave_Balance__c> newBalances = new List<Leave_Balance__c>();

        for (Employee__c emp : employees) {
            for (Leave_Policy__c policy : policies) {
                // Match policy: designation-specific first, then universal
                if (policy.Designation__c != null &&
                    !policy.Designation__c.equalsIgnoreCase(emp.Designation__c)) {
                    continue;
                }

                String key = emp.Id + '-' + policy.Leave_Type__c;

                // Skip if already exists for this year
                if (existingKeys.contains(key)) continue;

                // Check if a more specific policy already matched
                // (designation-specific beats universal)
                if (policy.Designation__c == null && existingKeys.contains(key)) continue;

                Decimal entitlement = policy.Annual_Entitlement__c != null ? policy.Annual_Entitlement__c : 0;
                Decimal monthlyAccrual = policy.Monthly_Accrual__c != null ? policy.Monthly_Accrual__c : 0;

                // Calculate carry forward from previous year
                Decimal carryForward = 0;
                Decimal maxCarry = policy.Max_Carry_Forward__c != null ? policy.Max_Carry_Forward__c : 0;

                if (maxCarry > 0) {
                    Leave_Balance__c prevBal = prevBalanceMap.get(key);
                    if (prevBal != null) {
                        Decimal unusedDays = calcAvailable(prevBal);
                        carryForward = Math.min(unusedDays, maxCarry);
                        if (carryForward < 0) carryForward = 0;
                    }
                }

                // For lump-sum types (no monthly accrual), credit full entitlement immediately
                Decimal initialAccrued = (monthlyAccrual == 0 || monthlyAccrual == null) ? entitlement : 0;

                Leave_Balance__c lb = new Leave_Balance__c(
                    Employee__c = emp.Id,
                    Leave_Type__c = policy.Leave_Type__c,
                    Year__c = year,
                    Entitled__c = entitlement,
                    Accrued__c = initialAccrued,
                    Carry_Forward__c = carryForward,
                    Used__c = 0,
                    Pending__c = 0,
                    Leave_Policy__c = policy.Id
                );

                newBalances.add(lb);
                existingKeys.add(key); // Prevent duplicate from universal policy
            }
        }

        if (!newBalances.isEmpty()) {
            insert newBalances;
        }

        System.debug('Initialized ' + newBalances.size() + ' leave balances for year ' + year);
    }

    // ═══════════════════════════════════════════════════════════════
    // MONTHLY ACCRUAL: Increment Accrued__c for accrual-based types
    // Run on 1st of every month
    // ═══════════════════════════════════════════════════════════════

    public static void runMonthlyAccrual(String year) {
        // Find balances that have monthly accrual policies
        List<Leave_Balance__c> balances = [
            SELECT Id, Accrued__c, Entitled__c, Leave_Policy__c,
                   Leave_Policy__r.Monthly_Accrual__c
            FROM Leave_Balance__c
            WHERE Year__c = :year
            AND Leave_Policy__r.Monthly_Accrual__c > 0
            AND Leave_Policy__r.Is_Active__c = true
        ];

        List<Leave_Balance__c> toUpdate = new List<Leave_Balance__c>();

        for (Leave_Balance__c lb : balances) {
            Decimal accrualRate = lb.Leave_Policy__r.Monthly_Accrual__c;
            Decimal currentAccrued = lb.Accrued__c != null ? lb.Accrued__c : 0;
            Decimal maxEntitled = lb.Entitled__c != null ? lb.Entitled__c : 0;

            // Don't accrue beyond annual entitlement
            Decimal newAccrued = Math.min(currentAccrued + accrualRate, maxEntitled);

            if (newAccrued != currentAccrued) {
                lb.Accrued__c = newAccrued;
                toUpdate.add(lb);
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        System.debug('Accrued leave for ' + toUpdate.size() + ' balances');
    }

    // ═══════════════════════════════════════════════════════════════
    // BALANCE OPERATIONS: Deduct, Restore, Add Pending
    // Called by LeaveRequestController on approval/cancellation
    // ═══════════════════════════════════════════════════════════════

    public static void deductBalance(Id employeeId, String leaveType, Decimal days, String year) {
        Leave_Balance__c lb = getBalance(employeeId, leaveType, year);
        if (lb == null) return;

        lb.Used__c = (lb.Used__c != null ? lb.Used__c : 0) + days;
        // Remove from pending since it's now approved
        lb.Pending__c = Math.max((lb.Pending__c != null ? lb.Pending__c : 0) - days, 0);
        update lb;
    }

    public static void restoreBalance(Id employeeId, String leaveType, Decimal days, String year) {
        Leave_Balance__c lb = getBalance(employeeId, leaveType, year);
        if (lb == null) return;

        lb.Used__c = Math.max((lb.Used__c != null ? lb.Used__c : 0) - days, 0);
        update lb;
    }

    public static void addPending(Id employeeId, String leaveType, Decimal days, String year) {
        Leave_Balance__c lb = getBalance(employeeId, leaveType, year);
        if (lb == null) return;

        lb.Pending__c = (lb.Pending__c != null ? lb.Pending__c : 0) + days;
        update lb;
    }

    public static void removePending(Id employeeId, String leaveType, Decimal days, String year) {
        Leave_Balance__c lb = getBalance(employeeId, leaveType, year);
        if (lb == null) return;

        lb.Pending__c = Math.max((lb.Pending__c != null ? lb.Pending__c : 0) - days, 0);
        update lb;
    }

    // ═══════════════════════════════════════════════════════════════
    // VALIDATE: Check if employee has sufficient balance
    // ═══════════════════════════════════════════════════════════════

    public static void validateBalance(Id employeeId, String leaveType, Decimal days, String year) {
        Leave_Balance__c lb = getBalance(employeeId, leaveType, year);

        if (lb == null) {
            throw new AuraHandledException(
                'No leave balance found for ' + leaveType + ' in year ' + year +
                '. Please contact HR to initialize your leave balances.'
            );
        }

        Decimal available = calcAvailable(lb);

        if (days > available) {
            throw new AuraHandledException(
                'Insufficient ' + leaveType + ' balance. Available: ' +
                String.valueOf(available) + ' days, Requested: ' +
                String.valueOf(days) + ' days.'
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // GET BALANCES: For UI display
    // ═══════════════════════════════════════════════════════════════

    public static List<Leave_Balance__c> getBalancesForUser(Id userId, String year) {
        // Get employee ID from user
        List<Employee__c> employees = [
            SELECT Id FROM Employee__c WHERE User__c = :userId AND Is_Active__c = true LIMIT 1
        ];

        if (employees.isEmpty()) return new List<Leave_Balance__c>();

        return [
            SELECT Id, Leave_Type__c, Year__c, Entitled__c, Accrued__c,
                   Carry_Forward__c, Used__c, Pending__c,
                   Leave_Policy__c, Leave_Policy__r.Name
            FROM Leave_Balance__c
            WHERE Employee__c = :employees[0].Id
            AND Year__c = :year
            ORDER BY Leave_Type__c
        ];
    }

    public static List<Leave_Balance__c> getBalancesForEmployee(Id employeeId, String year) {
        return [
            SELECT Id, Leave_Type__c, Year__c, Entitled__c, Accrued__c,
                   Carry_Forward__c, Used__c, Pending__c,
                   Leave_Policy__c, Leave_Policy__r.Name
            FROM Leave_Balance__c
            WHERE Employee__c = :employeeId
            AND Year__c = :year
            ORDER BY Leave_Type__c
        ];
    }

    // ═══════════════════════════════════════════════════════════════
    // HELPER: Get single balance record
    // ═══════════════════════════════════════════════════════════════

    private static Leave_Balance__c getBalance(Id employeeId, String leaveType, String year) {
        List<Leave_Balance__c> balances = [
            SELECT Id, Used__c, Pending__c, Accrued__c, Carry_Forward__c
            FROM Leave_Balance__c
            WHERE Employee__c = :employeeId
            AND Leave_Type__c = :leaveType
            AND Year__c = :year
            LIMIT 1
        ];

        return balances.isEmpty() ? null : balances[0];
    }

    // ═══════════════════════════════════════════════════════════════
    // HELPER: Get current fiscal year
    // ═══════════════════════════════════════════════════════════════

    public static String getCurrentFiscalYear() {
        Integer currentMonth = Date.today().month();
        Integer currentYear = Date.today().year();
        // Indian fiscal year: April to March
        return String.valueOf(currentMonth < 4 ? currentYear - 1 : currentYear);
    }

    // Get employee ID from user ID
    public static Id getEmployeeId(Id userId) {
        List<Employee__c> employees = [
            SELECT Id FROM Employee__c WHERE User__c = :userId AND Is_Active__c = true LIMIT 1
        ];
        return employees.isEmpty() ? null : employees[0].Id;
    }

    // Calculate available balance in code (doesn't depend on formula field)
    public static Decimal calcAvailable(Leave_Balance__c lb) {
        Decimal accrued = lb.Accrued__c != null ? lb.Accrued__c : 0;
        Decimal carry = lb.Carry_Forward__c != null ? lb.Carry_Forward__c : 0;
        Decimal used = lb.Used__c != null ? lb.Used__c : 0;
        Decimal pending = lb.Pending__c != null ? lb.Pending__c : 0;
        return accrued + carry - used - pending;
    }
}