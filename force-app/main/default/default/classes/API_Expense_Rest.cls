/**
 * @description REST API for Expense operations (Mobile App).
 *              Covers:
 *                - Add Expense
 *                - My Expense (list grouped by month/date)
 *                - Expense Detail
 *
 * @author  Praveen Kumar
 * @date    2026
 */
@RestResource(urlMapping='/mobile/expense/*')
global with sharing class API_Expense_Rest {

    private static final List<String> DAY_LABELS = new List<String>{
        '', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
    };

    private static final List<String> MONTH_NAMES = new List<String>{
        '', 'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
    };

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/add')) {
                doAddExpense(req);
            } else if (path.endsWith('/list')) {
                doExpenseList(req);
            } else if (path.endsWith('/detail')) {
                doExpenseDetail(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 8. Add Expense ─────────────────────────────────────────────────────

    private static void doAddExpense(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        String expenseType = (String) body.get('expenseType');
        String expenseDateStr = (String) body.get('expansedate');
        if (String.isBlank(expenseDateStr)) {
            expenseDateStr = (String) body.get('expenseDate');
        }
        String description = (String) body.get('description');
        Object amountObj = body.get('amount');

        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }

        // Resolve employee
        List<Employee__c> employees = [
            SELECT Id, User__c FROM Employee__c
            WHERE User__c = :userId OR Name = :userId
            LIMIT 1
        ];
        if (employees.isEmpty()) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }
        Employee__c emp = employees[0];

        // Parse expense date
        Date expenseDate;
        try {
            expenseDate = String.isNotBlank(expenseDateStr) ? Date.valueOf(expenseDateStr) : Date.today();
        } catch (Exception e) {
            expenseDate = Date.today();
        }

        // Parse amount
        Decimal amount = 0;
        if (amountObj instanceof Decimal) {
            amount = (Decimal) amountObj;
        } else if (amountObj instanceof String) {
            try {
                amount = Decimal.valueOf((String) amountObj);
            } catch (Exception e) {
                API_ResponseWrapper.sendError('Invalid amount value.');
                return;
            }
        }

        // Find or create monthly Expense report
        Integer expMonth = expenseDate.month();
        Integer expYear = expenseDate.year();
        String monthName = MONTH_NAMES[expMonth];

        List<Expense__c> reports = [
            SELECT Id FROM Expense__c
            WHERE Employee__c = :emp.Id
              AND Month__c = :monthName
              AND Period_Start__c <= :expenseDate
              AND Period_End__c >= :expenseDate
            LIMIT 1
        ];

        Id reportId;
        if (reports.isEmpty()) {
            Expense__c newReport = new Expense__c();
            newReport.Employee__c = emp.Id;
            newReport.Month__c = monthName;
            newReport.Status__c = 'Draft';
            newReport.Period_Start__c = Date.newInstance(expYear, expMonth, 1);
            newReport.Period_End__c = Date.newInstance(expYear, expMonth, Date.daysInMonth(expYear, expMonth));
            insert newReport;
            reportId = newReport.Id;
        } else {
            reportId = reports[0].Id;
        }

        // Create expense item
        Expense_Item__c item = new Expense_Item__c();
        item.Expense__c = reportId;
        item.Expense_Type__c = expenseType;
        item.Expense_Date__c = expenseDate;
        item.Claimed_Amount__c = amount;
        item.Notes__c = description;
        item.Approval_Status__c = 'Pending';

        insert item;

        API_ResponseWrapper.sendSuccess('Expense Item Created Successfully', new Map<String, Object>{'expenseItemId' => item.Id});
    }

    // ── 9. My Expense ──────────────────────────────────────────────────────

    private static void doExpenseList(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }

        Id sfUserId = resolveUserId(userId);
        if (sfUserId == null) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        // Query all expense items for this user, ordered by date desc
        List<Expense_Item__c> items = [
            SELECT Id, Name, Expense_Date__c, Claimed_Amount__c, Notes__c,
                   Expense_Type__c, Approval_Status__c
            FROM Expense_Item__c
            WHERE Expense__r.Employee__r.User__c = :sfUserId
            ORDER BY Expense_Date__c DESC
            LIMIT 500
        ];

        // Group by month, then by date
        Decimal grandTotal = 0;
        Map<String, List<Expense_Item__c>> monthGroups = new Map<String, List<Expense_Item__c>>();
        Map<String, Decimal> monthTotals = new Map<String, Decimal>();
        List<String> monthOrder = new List<String>();

        for (Expense_Item__c item : items) {
            if (item.Expense_Date__c == null) continue;

            String monthKey = String.valueOf(item.Expense_Date__c.year()) + '-' +
                              String.valueOf(item.Expense_Date__c.month()).leftPad(2, '0');

            if (!monthGroups.containsKey(monthKey)) {
                monthGroups.put(monthKey, new List<Expense_Item__c>());
                monthTotals.put(monthKey, 0);
                monthOrder.add(monthKey);
            }
            monthGroups.get(monthKey).add(item);

            Decimal amt = item.Claimed_Amount__c != null ? item.Claimed_Amount__c : 0;
            monthTotals.put(monthKey, monthTotals.get(monthKey) + amt);
            grandTotal += amt;
        }

        // Build response
        List<Map<String, Object>> monthDataList = new List<Map<String, Object>>();
        for (String monthKey : monthOrder) {
            List<Expense_Item__c> monthItems = monthGroups.get(monthKey);

            Map<String, Object> monthEntry = new Map<String, Object>();
            monthEntry.put('month', monthKey);

            // Parse for label
            List<String> parts = monthKey.split('-');
            Integer yr = Integer.valueOf(parts[0]);
            Integer mo = Integer.valueOf(parts[1]);
            monthEntry.put('monthLabel', MONTH_NAMES[mo] + ' ' + yr);
            monthEntry.put('totalExpenses', monthTotals.get(monthKey));
            monthEntry.put('totalRecords', monthItems.size());

            // Group by date within month
            Map<Date, List<Expense_Item__c>> dateGroups = new Map<Date, List<Expense_Item__c>>();
            List<Date> dateOrder = new List<Date>();
            for (Expense_Item__c item : monthItems) {
                Date d = item.Expense_Date__c;
                if (!dateGroups.containsKey(d)) {
                    dateGroups.put(d, new List<Expense_Item__c>());
                    dateOrder.add(d);
                }
                dateGroups.get(d).add(item);
            }

            List<Map<String, Object>> dateDataList = new List<Map<String, Object>>();
            for (Date d : dateOrder) {
                List<Expense_Item__c> dateItems = dateGroups.get(d);

                Decimal dailyTotal = 0;
                List<Map<String, Object>> expenseList = new List<Map<String, Object>>();

                for (Expense_Item__c item : dateItems) {
                    Decimal amt = item.Claimed_Amount__c != null ? item.Claimed_Amount__c : 0;
                    dailyTotal += amt;

                    Map<String, Object> expMap = new Map<String, Object>();
                    expMap.put('expenseId', item.Id);
                    expMap.put('expenseDate', String.valueOf(item.Expense_Date__c));
                    expMap.put('amount', amt);
                    expMap.put('description', item.Notes__c);
                    expMap.put('expenseType', item.Expense_Type__c);
                    expMap.put('status', item.Approval_Status__c);
                    expenseList.add(expMap);
                }

                Map<String, Object> dateEntry = new Map<String, Object>();
                dateEntry.put('date', String.valueOf(d));
                dateEntry.put('dayLabel', getDayLabel(d));
                dateEntry.put('dailyTotalAmount', dailyTotal);
                dateEntry.put('expenses', expenseList);
                dateDataList.add(dateEntry);
            }

            monthEntry.put('dates', dateDataList);
            monthDataList.add(monthEntry);
        }

        // Build top-level response
        Map<String, Object> responseData = new Map<String, Object>();
        responseData.put('status', 'success');
        responseData.put('message', 'Expense data fetched successfully');
        responseData.put('totalExpenses', grandTotal);
        responseData.put('data', monthDataList);

        API_ResponseWrapper.sendResponse(200, JSON.serialize(responseData));
    }

    // ── 10. Expense Detail ─────────────────────────────────────────────────

    private static void doExpenseDetail(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        String expenseId = (String) body.get('expenseId');

        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }
        if (String.isBlank(expenseId)) {
            API_ResponseWrapper.sendError('expenseId is required.');
            return;
        }

        Id sfUserId = resolveUserId(userId);
        if (sfUserId == null) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        List<Expense_Item__c> items = [
            SELECT Id, Name, Claimed_Amount__c, Approved_Amount__c,
                   Expense_Type__c, Approval_Status__c, Expense_Date__c,
                   Notes__c, Expense_Category__c, Has_Receipt__c,
                   Receipt_URL__c, Approver_Comments__c,
                   Expense__r.Employee__r.First_Name__c,
                   Expense__r.Employee__r.Last_Name__c,
                   Expense__r.Employee__r.Id,
                   CreatedDate, LastModifiedDate
            FROM Expense_Item__c
            WHERE Id = :expenseId
              AND Expense__r.Employee__r.User__c = :sfUserId
            LIMIT 1
        ];

        if (items.isEmpty()) {
            API_ResponseWrapper.sendError('Expense not found.');
            return;
        }

        Expense_Item__c item = items[0];

        Map<String, Object> data = new Map<String, Object>();
        data.put('expenseId', item.Id);
        data.put('expenseNumber', item.Name);
        data.put('amount', item.Claimed_Amount__c);
        data.put('currency', 'INR');
        data.put('expenseType', item.Expense_Type__c);
        data.put('status', item.Approval_Status__c);
        data.put('expenseDate', item.Expense_Date__c != null ? String.valueOf(item.Expense_Date__c) : '');

        // Display date format
        if (item.Expense_Date__c != null) {
            DateTime dt = DateTime.newInstance(item.Expense_Date__c, Time.newInstance(0, 0, 0, 0));
            data.put('displayDate', dt.format('MMM dd, yyyy'));
        } else {
            data.put('displayDate', '');
        }

        data.put('description', item.Notes__c);

        String salesperson = '';
        if (item.Expense__r != null && item.Expense__r.Employee__r != null) {
            salesperson = ((item.Expense__r.Employee__r.First_Name__c != null
                            ? item.Expense__r.Employee__r.First_Name__c : '') + ' ' +
                           (item.Expense__r.Employee__r.Last_Name__c != null
                            ? item.Expense__r.Employee__r.Last_Name__c : '')).trim();
        }
        data.put('salesperson', salesperson);
        data.put('salespersonId', item.Expense__r != null && item.Expense__r.Employee__r != null
                 ? item.Expense__r.Employee__r.Id : null);
        data.put('category', item.Expense_Category__c);
        data.put('source', 'user');
        data.put('hasReceipt', item.Has_Receipt__c);
        data.put('receiptUrl', item.Receipt_URL__c);
        data.put('approvedBy', null);
        data.put('approvedDate', null);
        data.put('rejectionReason', item.Approver_Comments__c);
        data.put('createdDateTime', item.CreatedDate != null ? item.CreatedDate.format('yyyy-MM-dd\'T\'HH:mm:ss') : null);
        data.put('lastModifiedDateTime', item.LastModifiedDate != null ? item.LastModifiedDate.format('yyyy-MM-dd\'T\'HH:mm:ss') : null);

        // Build top-level response matching API doc format
        Map<String, Object> response = new Map<String, Object>();
        response.put('status', 'success');
        response.put('message', 'Expense details fetched successfully');
        response.put('data', data);

        API_ResponseWrapper.sendResponse(200, JSON.serialize(response));
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private static Id resolveUserId(String userId) {
        List<Employee__c> employees = [
            SELECT Id, User__c FROM Employee__c
            WHERE User__c = :userId OR Name = :userId
            LIMIT 1
        ];
        return employees.isEmpty() ? null : employees[0].User__c;
    }

    private static String getDayLabel(Date d) {
        DateTime dt = DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0));
        return dt.format('EEE');
    }
}