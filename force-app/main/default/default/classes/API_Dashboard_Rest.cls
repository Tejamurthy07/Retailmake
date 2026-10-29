/**
 * @description REST API for KPI Dashboard / Home Screen (Mobile App).
 *              Covers:
 *                - Home Screen KPI Dashboard (target summary, day summary,
 *                  leaderboard, productivity, expense timeline, today's visits)
 *
 * @author  Praveen Kumar
 * @date    2026
 */
@RestResource(urlMapping='/mobile/dashboard/*')
global with sharing class API_Dashboard_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/kpi')) {
                doKpiDashboard(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 3. Home Screen (KPI Dashboard) ─────────────────────────────────────

    private static void doKpiDashboard(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }

        // Resolve employee → Salesforce User Id
        List<Employee__c> employees = [
            SELECT Id, User__c FROM Employee__c
            WHERE User__c = :userId OR Name = :userId
            LIMIT 1
        ];
        if (employees.isEmpty()) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }
        Id sfUserId = employees[0].User__c;

        Map<String, Object> data = new Map<String, Object>();

        // ── Target Summary ──
        data.put('targetSummary', buildTargetSummary(sfUserId));

        // ── Day Summary ──
        data.put('daySummary', buildDaySummary(sfUserId));

        // ── Leaderboard ──
        data.put('leaderboard', buildLeaderboard());

        // ── Productivity ──
        data.put('productivity', buildProductivity(sfUserId));

        // ── Expense Timeline ──
        String expRange = (String) body.get('expenseSummaryRange');
        data.put('expenseTimeline', buildExpenseTimeline(sfUserId, expRange));

        // ── Today's Visits ──
        data.put('todayVisits', buildTodayVisits(sfUserId));

        API_ResponseWrapper.sendSuccess('KPI Dashboard data fetched successfully', data);
    }

    // ── Target Summary ─────────────────────────────────────────────────────

    private static Map<String, Object> buildTargetSummary(Id sfUserId) {
        Map<String, Object> summary = new Map<String, Object>();

        Date today = Date.today();
        Integer currentMonth = today.month();
        Integer currentYear = today.year();
        String monthStr = getMonthName(currentMonth);
        String yearStr = String.valueOf(currentYear);

        // Query targets for this user/month/year
        List<Target__c> targets = [
            SELECT Id, Target_Value__c, Achievement_Value__c, Achievement_Percent__c
            FROM Target__c
            WHERE Salesperson__c = :sfUserId
              AND Month__c = :monthStr
              AND Year__c = :yearStr
            LIMIT 10
        ];

        Decimal totalTarget = 0;
        Decimal totalAchieved = 0;
        for (Target__c t : targets) {
            totalTarget += (t.Target_Value__c != null ? t.Target_Value__c : 0);
            totalAchieved += (t.Achievement_Value__c != null ? t.Achievement_Value__c : 0);
        }

        Decimal pct = totalTarget > 0 ? ((totalAchieved / totalTarget) * 100).setScale(0) : 0;

        summary.put('percentageTargetCompleted', pct);
        summary.put('thisMonthTarget', totalTarget);
        summary.put('targetAchieved', totalAchieved);
        summary.put('remainingTarget', totalTarget - totalAchieved);
        summary.put('totalDays', Date.daysInMonth(currentYear, currentMonth));
        summary.put('completedDays', today.day());

        return summary;
    }

    // ── Day Summary ────────────────────────────────────────────────────────

    private static Map<String, Object> buildDaySummary(Id sfUserId) {
        Map<String, Object> summary = new Map<String, Object>();
        Date today = Date.today();

        // Query today's attendance
        List<Day_Attendance__c> attendances = [
            SELECT Id, Total_Visits__c, Productive_Calls__c,
                   Distance_Traveled_Km__c, Total_Order_Value__c, Total_Orders__c
            FROM Day_Attendance__c
            WHERE Salesperson__c = :sfUserId
              AND Attendance_Date__c = :today
            LIMIT 1
        ];

        if (!attendances.isEmpty()) {
            Day_Attendance__c da = attendances[0];
            Integer totalVisits = da.Total_Visits__c != null ? da.Total_Visits__c.intValue() : 0;

            // Count completed visits
            Integer completedVisits = [
                SELECT COUNT()
                FROM Visit__c
                WHERE Salesperson__c = :sfUserId
                  AND Visit_Date__c = :today
                  AND Visit_Status__c = 'Completed'
            ];

            summary.put('totalVisits', totalVisits);
            summary.put('completedVisits', completedVisits);
            summary.put('productiveCalls', da.Productive_Calls__c != null ? da.Productive_Calls__c.intValue() : 0);
            summary.put('travelKm', da.Distance_Traveled_Km__c != null ? da.Distance_Traveled_Km__c : 0);

            // Today's expense
            Decimal todayExpense = 0;
            for (AggregateResult ar : [
                SELECT SUM(Claimed_Amount__c) total
                FROM Expense_Item__c
                WHERE Expense__r.Employee__r.User__c = :sfUserId
                  AND Expense_Date__c = :today
            ]) {
                todayExpense = ar.get('total') != null ? (Decimal) ar.get('total') : 0;
            }
            summary.put('totalExpense', todayExpense);
            summary.put('ordersAmount', da.Total_Order_Value__c != null ? da.Total_Order_Value__c : 0);
            summary.put('ordersCount', da.Total_Orders__c != null ? da.Total_Orders__c.intValue() : 0);
        } else {
            summary.put('totalVisits', 0);
            summary.put('completedVisits', 0);
            summary.put('productiveCalls', 0);
            summary.put('travelKm', 0);
            summary.put('totalExpense', 0);
            summary.put('ordersAmount', 0);
            summary.put('ordersCount', 0);
        }

        return summary;
    }

    // ── Leaderboard ────────────────────────────────────────────────────────

    private static List<Map<String, Object>> buildLeaderboard() {
        List<Map<String, Object>> board = new List<Map<String, Object>>();

        // Static leaderboard values (requested by user)
        board.add(new Map<String, Object>{
            'id' => 'a2C000001ABC123',
            'rank' => 1,
            'name' => 'Amal Perera',
            'region' => 'Western',
            'achieved' => 520000,
            'target' => 400000,
            'rankChange' => 2,
            'month' => '2026-04'
        });

        board.add(new Map<String, Object>{
            'id' => 'a2C000001ABC456',
            'rank' => 2,
            'name' => 'Kamal Silva',
            'region' => 'Central',
            'achieved' => 465000,
            'target' => 400000,
            'rankChange' => 0,
            'month' => '2026-04'
        });

        // Previous dynamic leaderboard logic retained as comment for future reference
        /*
        Date today = Date.today();
        String monthStr = getMonthName(today.month());
        String yearStr = String.valueOf(today.year());

        List<Target__c> leaders = [
            SELECT Id, Salesperson__c, Salesperson__r.Name, Achievement_Percent__c
            FROM Target__c
            WHERE Month__c = :monthStr
              AND Year__c = :yearStr
              AND Achievement_Percent__c != NULL
            ORDER BY Achievement_Percent__c DESC
            LIMIT 10
        ];

        Integer rank = 1;
        for (Target__c t : leaders) {
            Map<String, Object> entry = new Map<String, Object>();
            entry.put('rank', rank++);
            entry.put('name', t.Salesperson__r.Name);
            entry.put('achievementPercentage', t.Achievement_Percent__c);
            board.add(entry);
        }
        */

        return board;
    }

    // ── Productivity ───────────────────────────────────────────────────────

    private static Map<String, Object> buildProductivity(Id sfUserId) {
        Map<String, Object> prod = new Map<String, Object>();
        Date today = Date.today();
        Date monthStart = today.toStartOfMonth();

        // Aggregate visits this month
        Integer totalPlanned = 0;
        Integer totalCompleted = 0;
        Integer totalMissed = 0;
        Integer geoVerified = 0;
        Decimal totalDurationMin = 0;
        Integer visitCount = 0;

        for (Visit__c v : [
            SELECT Id, Visit_Status__c, Is_Geo_Fenced__c, Duration_Minutes__c, Is_Planned__c
            FROM Visit__c
            WHERE Salesperson__c = :sfUserId
              AND Visit_Date__c >= :monthStart
              AND Visit_Date__c <= :today
        ]) {
            if (v.Is_Planned__c == true) {
                totalPlanned++;
            }
            if (v.Visit_Status__c == 'Completed') {
                totalCompleted++;
                if (v.Duration_Minutes__c != null) {
                    totalDurationMin += v.Duration_Minutes__c;
                    visitCount++;
                }
            }
            if (v.Visit_Status__c == 'Missed') {
                totalMissed++;
            }
            if (v.Is_Geo_Fenced__c == true) {
                geoVerified++;
            }
        }

        Integer totalVisits = totalPlanned > 0 ? totalPlanned : (totalCompleted + totalMissed);
        Decimal completionPct = totalVisits > 0 ? ((Decimal) totalCompleted / totalVisits * 100).setScale(0) : 0;
        Decimal avgDuration = visitCount > 0 ? (totalDurationMin / visitCount).setScale(1) : null;

        Integer allVisitsCount = totalCompleted + totalMissed;
        Decimal geoVerifiedPct = allVisitsCount > 0 ? ((Decimal) geoVerified / allVisitsCount * 100).setScale(0) : 0;

        prod.put('tls', totalCompleted);
        prod.put('lppc', totalPlanned > 0 ? totalCompleted : 0);
        prod.put('missedVisits', totalMissed);
        prod.put('visitCompletionPercentage', completionPct);
        prod.put('avgVisitDuration', avgDuration);
        prod.put('geoVerifiedCheckInsPercentage', geoVerifiedPct);

        return prod;
    }

    // ── Expense Timeline ───────────────────────────────────────────────────

    private static Map<String, Object> buildExpenseTimeline(Id sfUserId, String durationParam) {
        Map<String, Object> timeline = new Map<String, Object>();

        Integer months = 6; // Default 6 months
        if (String.isNotBlank(durationParam)) {
            try {
                months = Integer.valueOf(durationParam.replaceAll('[^0-9]', ''));
            } catch (Exception e) {
                months = 6;
            }
        }

        timeline.put('duration', months + 'M');

        Date today = Date.today();
        Date startDate = today.addMonths(-months + 1).toStartOfMonth();

        // Query expense items grouped by month
        List<AggregateResult> results = [
            SELECT CALENDAR_MONTH(Expense_Date__c) mon,
                   CALENDAR_YEAR(Expense_Date__c) yr,
                   SUM(Claimed_Amount__c) total
            FROM Expense_Item__c
            WHERE Expense__r.Employee__r.User__c = :sfUserId
              AND Expense_Date__c >= :startDate
              AND Expense_Date__c <= :today
            GROUP BY CALENDAR_MONTH(Expense_Date__c), CALENDAR_YEAR(Expense_Date__c)
            ORDER BY CALENDAR_YEAR(Expense_Date__c), CALENDAR_MONTH(Expense_Date__c)
        ];

        // Build monthly map
        Map<String, Decimal> monthlyMap = new Map<String, Decimal>();
        for (AggregateResult ar : results) {
            Integer mon = (Integer) ar.get('mon');
            Decimal total = ar.get('total') != null ? (Decimal) ar.get('total') : 0;
            String key = String.valueOf(mon);
            monthlyMap.put(key, total);
        }

        List<Map<String, Object>> monthlyData = new List<Map<String, Object>>();
        Decimal grandTotal = 0;

        for (Integer i = 0; i < months; i++) {
            Date d = today.addMonths(-months + 1 + i).toStartOfMonth();
            String monthKey = String.valueOf(d.month());
            Decimal amount = monthlyMap.containsKey(monthKey) ? monthlyMap.get(monthKey) : 0;
            grandTotal += amount;

            Map<String, Object> entry = new Map<String, Object>();
            entry.put('month', getShortMonthName(d.month()));
            entry.put('amount', amount);
            monthlyData.add(entry);
        }

        timeline.put('totalExpense', grandTotal);
        timeline.put('avgExpensePerMonth', months > 0 ? (grandTotal / months).setScale(0) : 0);
        timeline.put('monthlyData', monthlyData);

        return timeline;
    }

    // ── Today's Visits ─────────────────────────────────────────────────────

    private static List<Map<String, Object>> buildTodayVisits(Id sfUserId) {
        List<Map<String, Object>> visits = new List<Map<String, Object>>();
        Date today = Date.today();

        for (Visit__c v : [
            SELECT Id, Name, Account__r.Name, Visit_Status__c,
                   Check_In_Latitude__c, Check_In_Longitude__c
            FROM Visit__c
            WHERE Salesperson__c = :sfUserId
              AND Visit_Date__c = :today
            ORDER BY CreatedDate
        ]) {
            Map<String, Object> visit = new Map<String, Object>();
            visit.put('visitId', v.Name);
            visit.put('accountName', v.Account__r != null ? v.Account__r.Name : '');
            visit.put('status', v.Visit_Status__c);
            visit.put('latitude', v.Check_In_Latitude__c);
            visit.put('longitude', v.Check_In_Longitude__c);
            visits.add(visit);
        }

        return visits;
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private static final List<String> MONTH_NAMES = new List<String>{
        '', 'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
    };

    private static final List<String> SHORT_MONTHS = new List<String>{
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    };

    private static String getMonthName(Integer m) {
        return (m >= 1 && m <= 12) ? MONTH_NAMES[m] : '';
    }

    private static String getShortMonthName(Integer m) {
        return (m >= 1 && m <= 12) ? SHORT_MONTHS[m] : '';
    }
}