/**
 * VisitManagerController
 * Unified Apex controller for the standalone Visit Management component.
 * Orchestrates Day Attendance, Visit lifecycle, beat selection/switching,
 * and all visit activities within a single-screen experience.
 */
public without sharing class VisitManagerController {

    // ──────────────────────────────────────────────────
    // 1. INITIALIZATION — Full context load on mount
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Map<String, Object> getInitialContext() {
        Id userId = UserInfo.getUserId();
        Map<String, Object> ctx = new Map<String, Object>();

        // Current day attendance
        Day_Attendance__c dayAtt = DFO_DayAttendance_Service.getCurrentAttendance(userId);
        ctx.put('dayAttendance', dayAtt);
        ctx.put('isDayStarted', dayAtt != null);

        // Also fetch any attendance record for today (any status) so the UI
        // can show a summary card instead of the Start Day button when the
        // user has already ended their day.
        List<Day_Attendance__c> todayAttList = [
            SELECT Id, Name, Status__c, Day_Start_Time__c, Day_End_Time__c,
                   Start_Time__c, End_Time__c, Hours_Worked__c,
                   Total_Visits__c, Productive_Calls__c, Total_Orders__c,
                   Total_Order_Value__c, Total_Collection__c,
                   Distance_Traveled_Km__c, Beat__c, Beat__r.Name,
                   Duty_Type__c, Remarks__c, Is_Finalized__c, Auto_Closed__c
            FROM Day_Attendance__c
            WHERE User__c = :userId
              AND Attendance_Date__c = :Date.today()
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!todayAttList.isEmpty()) {
            ctx.put('todayAttendance', todayAttList[0]);
            ctx.put('hasTodayAttendance', true);
        } else {
            ctx.put('todayAttendance', null);
            ctx.put('hasTodayAttendance', false);
        }

        // Config
        ctx.put('config', getVisitConfig());

        // Always load today's beats for beat selection / switch
        ctx.put('todaysBeats', getTodaysBeats());

        if (dayAtt != null) {
            // Day stats
            ctx.put('dayStats', DFO_DayAttendance_Service.getDayStats(dayAtt.Id));

            // Active visit (in-progress)
            Visit__c activeVisit = getActiveVisit(userId);
            ctx.put('activeVisit', activeVisit);
            ctx.put('hasActiveVisit', activeVisit != null);

            if (activeVisit != null) {
                ctx.put('activeVisitSummary', getVisitSummaryData(activeVisit.Id));
                ctx.put('visitActivities', OVE_Visit_Service.getVisitActivities(activeVisit.Id));
            }

            // Planned + today's visits
            Date today = Date.today();
            ctx.put('todaysVisits', OVE_Visit_Service.getTodaysVisits(userId));
            ctx.put('plannedVisits', OVE_Visit_Service.getPlannedVisits(userId, today));

            // Beat info
            ctx.put('currentBeatId', dayAtt.Beat__c);
            ctx.put('currentBeat', dayAtt.Beat__r != null ? dayAtt.Beat__r.Name : '');
            try {
                ctx.put('beatSwitched', dayAtt.Beat_Switched__c == true);
                ctx.put('originalBeatId', dayAtt.Original_Beat__c);
            } catch (SObjectException e) {
                // Fields may not be queried in all code paths
                ctx.put('beatSwitched', false);
                ctx.put('originalBeatId', null);
            }
        }

        return ctx;
    }

    // ──────────────────────────────────────────────────
    // 2. GET TODAY'S BEATS from Journey Plan + other user beats
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static List<Map<String, Object>> getTodaysBeats() {
        Id userId = UserInfo.getUserId();
        Date today = Date.today();
        String dayOfWeek = getDayOfWeek(today);
        List<Map<String, Object>> beats = new List<Map<String, Object>>();

        // Get journey plan days for today (assigned beats)
        List<Journey_Plan_Day__c> jpDays = [
            SELECT Id, Beat__c, Beat__r.Name, Beat__r.Beat_Code__c,
                   Journey_Plan__c, Journey_Plan__r.Name
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c IN (
                SELECT Id FROM Journey_Plan__c
                WHERE Salesperson__c = :userId
                  AND Status__c IN ('Draft', 'Approved', 'Active')
                  AND Effective_From__c <= :today
                  AND Effective_To__c >= :today
            )
            // A dated plan day counts as "today's" only when its date IS today.
            // The weekday branch is for weekday-recurring plans (no specific date)
            // only — without the "Plan_Date = null" guard it matched every other
            // same-weekday entry too, so a beat scheduled for next Wednesday, or an
            // earlier Wednesday, showed up as assigned for this Wednesday.
            AND (Plan_Date__c = :today
                 OR (Plan_Date__c = null AND Day_of_Week__c = :dayOfWeek))
            AND Beat__c != null
        ];

        // Track assigned beat IDs (deduplicated)
        Set<Id> assignedBeatIds = new Set<Id>();
        Map<Id, Journey_Plan_Day__c> beatToJpDay = new Map<Id, Journey_Plan_Day__c>();
        for (Journey_Plan_Day__c jpd : jpDays) {
            if (!assignedBeatIds.contains(jpd.Beat__c)) {
                assignedBeatIds.add(jpd.Beat__c);
                beatToJpDay.put(jpd.Beat__c, jpd);
            }
        }

        // Get other unique beats from ALL journey plan days for this user
        // (not just today — gives option to switch to other beats)
        List<Journey_Plan_Day__c> allJpDays = [
            SELECT Id, Beat__c, Beat__r.Name, Beat__r.Beat_Code__c,
                   Journey_Plan__c, Journey_Plan__r.Name
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c IN (
                SELECT Id FROM Journey_Plan__c
                WHERE Salesperson__c = :userId
                  AND Status__c IN ('Draft', 'Approved', 'Active')
                  AND Effective_From__c <= :today
                  AND Effective_To__c >= :today
            )
            AND Beat__c != null
            AND Beat__c NOT IN :assignedBeatIds
        ];

        // Deduplicate other beats
        Set<Id> otherBeatIds = new Set<Id>();
        Map<Id, Journey_Plan_Day__c> otherBeatToJpDay = new Map<Id, Journey_Plan_Day__c>();
        for (Journey_Plan_Day__c jpd : allJpDays) {
            if (!otherBeatIds.contains(jpd.Beat__c)) {
                otherBeatIds.add(jpd.Beat__c);
                otherBeatToJpDay.put(jpd.Beat__c, jpd);
            }
        }

        // Get outlet counts for all beats
        Set<Id> allBeatIds = new Set<Id>();
        allBeatIds.addAll(assignedBeatIds);
        allBeatIds.addAll(otherBeatIds);

        Map<Id, Integer> beatOutletCounts = new Map<Id, Integer>();
        if (!allBeatIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Beat__c beatId, COUNT(Id) cnt
                FROM Beat_Outlet__c
                WHERE Beat__c IN :allBeatIds AND Is_Active__c = true
                GROUP BY Beat__c
            ]) {
                beatOutletCounts.put((Id)ar.get('beatId'), (Integer)ar.get('cnt'));
            }
        }

        // Build assigned beats (isAssigned = true)
        for (Id beatId : assignedBeatIds) {
            Journey_Plan_Day__c jpd = beatToJpDay.get(beatId);
            Map<String, Object> beat = new Map<String, Object>();
            beat.put('beatId', jpd.Beat__c);
            beat.put('beatName', jpd.Beat__r.Name);
            beat.put('beatCode', jpd.Beat__r.Beat_Code__c);
            beat.put('journeyPlanDayId', jpd.Id);
            beat.put('journeyPlanName', jpd.Journey_Plan__r.Name);
            beat.put('outletCount', beatOutletCounts.containsKey(jpd.Beat__c)
                ? beatOutletCounts.get(jpd.Beat__c) : 0);
            beat.put('isAssigned', true);
            beats.add(beat);
        }

        // Build other beats (isAssigned = false)
        for (Id beatId : otherBeatIds) {
            Journey_Plan_Day__c jpd = otherBeatToJpDay.get(beatId);
            Map<String, Object> beat = new Map<String, Object>();
            beat.put('beatId', jpd.Beat__c);
            beat.put('beatName', jpd.Beat__r.Name);
            beat.put('beatCode', jpd.Beat__r.Beat_Code__c);
            beat.put('journeyPlanDayId', jpd.Id);
            beat.put('journeyPlanName', jpd.Journey_Plan__r.Name);
            beat.put('outletCount', beatOutletCounts.containsKey(jpd.Beat__c)
                ? beatOutletCounts.get(jpd.Beat__c) : 0);
            beat.put('isAssigned', false);
            beats.add(beat);
        }

        return beats;
    }

    // ──────────────────────────────────────────────────
    // 3. DAY START
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Day_Attendance__c startDay(String dayJson) {
        return DayAttendanceController.startDay(dayJson);
    }

    // ──────────────────────────────────────────────────
    // 4. DAY END
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Day_Attendance__c endDay(String dayJson) {
        return DayAttendanceController.endDay(dayJson);
    }

    // ──────────────────────────────────────────────────
    // 4B. SELECT BEAT (after day start)
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Day_Attendance__c selectBeat(Id attendanceId, Id beatId, Id journeyPlanDayId) {
        if (beatId == null) {
            throw new AuraHandledException('Please select a beat.');
        }

        List<Day_Attendance__c> records = [
            SELECT Id, Beat__c, Original_Beat__c, Journey_Plan_Day__c,
                   Beat_Switched__c, Beat_Switch_Reason__c
            FROM Day_Attendance__c WHERE Id = :attendanceId LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('Day Attendance record not found.');
        }

        Day_Attendance__c da = records[0];
        da.Beat__c = beatId;
        da.Original_Beat__c = beatId;
        da.Beat_Switched__c = false;
        da.Beat_Switch_Reason__c = null;
        if (journeyPlanDayId != null) {
            da.Journey_Plan_Day__c = journeyPlanDayId;
        }
        update da;

        // Re-query to get relationship fields
        return [
            SELECT Id, Beat__c, Beat__r.Name, Original_Beat__c, Original_Beat__r.Name,
                   Beat_Switched__c, Beat_Switch_Reason__c, Journey_Plan_Day__c,
                   Journey_Plan_Day__r.Name, Journey_Plan_Day__r.Journey_Plan__c,
                   Journey_Plan_Day__r.Journey_Plan__r.Name
            FROM Day_Attendance__c WHERE Id = :attendanceId LIMIT 1
        ];
    }

    // ──────────────────────────────────────────────────
    // 5. SWITCH BEAT
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Day_Attendance__c switchBeat(Id attendanceId, Id newBeatId, String reason) {
        if (String.isBlank(reason)) {
            throw new AuraHandledException('Beat switch reason is mandatory.');
        }

        List<Day_Attendance__c> records = [
            SELECT Id, Beat__c, Original_Beat__c, Beat_Switched__c,
                   Journey_Plan_Day__c
            FROM Day_Attendance__c WHERE Id = :attendanceId LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('Day Attendance record not found.');
        }

        Day_Attendance__c da = records[0];

        // Store original beat only on first switch
        if (da.Beat_Switched__c != true) {
            da.Original_Beat__c = da.Beat__c;
        }
        da.Beat__c = newBeatId;
        da.Beat_Switched__c = true;
        da.Beat_Switch_Reason__c = reason;

        // Update Journey_Plan_Day__c if available for the new beat
        Id userId = UserInfo.getUserId();
        Date today = Date.today();
        String dayOfWeek = getDayOfWeek(today);
        List<Journey_Plan_Day__c> jpDays = [
            SELECT Id FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c IN (
                SELECT Id FROM Journey_Plan__c
                WHERE Salesperson__c = :userId
                  AND Status__c IN ('Draft', 'Approved', 'Active')
                  AND Effective_From__c <= :today
                  AND Effective_To__c >= :today
            )
            AND Beat__c = :newBeatId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!jpDays.isEmpty()) {
            da.Journey_Plan_Day__c = jpDays[0].Id;
        }

        update da;

        // Re-query to get relationship fields
        return [
            SELECT Id, Beat__c, Beat__r.Name, Original_Beat__c, Original_Beat__r.Name,
                   Beat_Switched__c, Beat_Switch_Reason__c,
                   Journey_Plan_Day__c, Journey_Plan_Day__r.Name,
                   Journey_Plan_Day__r.Journey_Plan__c, Journey_Plan_Day__r.Journey_Plan__r.Name
            FROM Day_Attendance__c WHERE Id = :attendanceId LIMIT 1
        ];
    }

    // ──────────────────────────────────────────────────
    // 6. VISIT CHECK-IN
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Visit__c checkInVisit(String visitJson) {
        return VisitCheckInController.createVisit(visitJson);
    }

    // ──────────────────────────────────────────────────
    // 7. VISIT CHECK-OUT
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Visit__c checkOutVisit(String visitJson) {
        return VisitCheckInController.completeVisit(visitJson);
    }

    // ──────────────────────────────────────────────────
    // 8. SKIP VISIT (existing or planned)
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Visit__c skipVisit(Id visitId, String skipReason) {
        return VisitCheckInController.skipVisit(visitId, skipReason);
    }

    @AuraEnabled
    public static Visit__c skipPlannedVisit(Id accountId, Id beatId, Id attendanceId, String skipReason) {
        if (accountId == null || String.isBlank(skipReason)) {
            throw new AuraHandledException('Account and skip reason are required.');
        }
        Id userId = UserInfo.getUserId();

        // Create a Visit record in Skipped status for this planned outlet
        Visit__c visit = new Visit__c();
        visit.Account__c = accountId;
        visit.Outlet__c = accountId;
        visit.Salesperson__c = userId;
        visit.Beat__c = beatId;
        visit.Day_Attendance__c = attendanceId;
        visit.Visit_Status__c = 'Skipped';
        visit.Visit_Date__c = Date.today();
        visit.Is_Planned__c = true;
        visit.Is_Ad_Hoc__c = false;
        visit.Deviation_Reason__c = skipReason;
        visit.Is_Productive__c = false;
        visit.Non_Productive_Reason__c = 'Visit Skipped';
        insert visit;

        return [
            SELECT Id, Name, Account__c, Account__r.Name, Visit_Status__c,
                   Beat__c, Beat__r.Name, Deviation_Reason__c, Is_Planned__c
            FROM Visit__c WHERE Id = :visit.Id LIMIT 1
        ];
    }

    // ──────────────────────────────────────────────────
    // 9. REFRESH DATA — Lightweight refresh endpoints
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Map<String, Object> refreshDayData() {
        Id userId = UserInfo.getUserId();
        Map<String, Object> data = new Map<String, Object>();

        Day_Attendance__c dayAtt = DFO_DayAttendance_Service.getCurrentAttendance(userId);
        if (dayAtt != null) {
            data.put('dayStats', DFO_DayAttendance_Service.getDayStats(dayAtt.Id));
            data.put('todaysVisits', OVE_Visit_Service.getTodaysVisits(userId));
            data.put('plannedVisits', OVE_Visit_Service.getPlannedVisits(userId, Date.today()));
            data.put('currentBeatId', dayAtt.Beat__c);
            data.put('currentBeat', dayAtt.Beat__r != null ? dayAtt.Beat__r.Name : '');

            Visit__c activeVisit = getActiveVisit(userId);
            data.put('activeVisit', activeVisit);
            data.put('hasActiveVisit', activeVisit != null);

            if (activeVisit != null) {
                data.put('activeVisitSummary', getVisitSummaryData(activeVisit.Id));
            }
        }

        return data;
    }

    @AuraEnabled
    public static Map<String, Object> refreshVisitSummary(Id visitId) {
        return getVisitSummaryData(visitId);
    }

    // ──────────────────────────────────────────────────
    // 10. OUTLET SEARCH (ad-hoc)
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static List<Account> searchOutlets(String searchTerm) {
        return VisitCheckInController.searchOutlets(searchTerm);
    }

    // ──────────────────────────────────────────────────
    // 11. EMPLOYEE SEARCH (companion)
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static List<Employee__c> searchEmployees(String searchTerm) {
        return DayAttendanceController.searchEmployees(searchTerm);
    }

    // ──────────────────────────────────────────────────
    // 12. VISIT ACTIVITIES & CONFIG
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static List<Map<String, Object>> getVisitActivities(Id visitId) {
        return OVE_Visit_Service.getVisitActivities(visitId);
    }

    /**
     * @description The activity keys enabled for the running user at the profile
     *              level (no outlet-type filter). Lets the UI hide summary tiles
     *              (Orders / Collection) when those activities are switched off.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getEnabledActivityKeys() {
        return new List<String>(VisitActivityConfig.visibleKeys(null));
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getVisitConfig() {
        Map<String, Object> config = new Map<String, Object>();
        try {
            config.put('selfieRequired', DFO_DayAttendance_Service.getConfigBoolean('SELFIE_REQUIRED', false));
            config.put('gpsTrackingEnabled', BPM_FeatureToggle_Util.isEnabled('DFO-002'));
            config.put('gpsTrackingInterval', DFO_DayAttendance_Service.getConfigInteger('GPS_TRACKING_INTERVAL', 300000));
            config.put('geofenceEnabled', BPM_FeatureToggle_Util.isEnabled('OVE-002'));
            config.put('adHocVisitsEnabled', BPM_FeatureToggle_Util.isEnabled('OVE-003'));
            config.put('photoRequiredCheckIn', DFO_DayAttendance_Service.getConfigBoolean('PHOTO_REQUIRED_CHECKIN', false));
            config.put('minVisitDuration', DFO_DayAttendance_Service.getConfigInteger('MIN_VISIT_DURATION_SEC', 60));
            config.put('maxVisitsPerDay', DFO_DayAttendance_Service.getConfigInteger('MAX_VISITS_PER_DAY', 50));
            config.put('statsRefreshInterval', DFO_DayAttendance_Service.getConfigInteger('STATS_REFRESH_INTERVAL', 60000));
            config.put('allowGeofenceOverride', DFO_DayAttendance_Service.getConfigBoolean('ALLOW_GEOFENCE_OVERRIDE', true));
        } catch (Exception e) {
            config.put('selfieRequired', false);
            config.put('gpsTrackingEnabled', false);
            config.put('gpsTrackingInterval', 300000);
            config.put('geofenceEnabled', false);
            config.put('adHocVisitsEnabled', true);
            config.put('photoRequiredCheckIn', false);
            config.put('minVisitDuration', 60);
            config.put('maxVisitsPerDay', 50);
            config.put('statsRefreshInterval', 60000);
            config.put('allowGeofenceOverride', true);
        }
        return config;
    }

    // ──────────────────────────────────────────────────
    // 14. OUTLET SUMMARY (for check-in screen)
    // ──────────────────────────────────────────────────
    @AuraEnabled
    public static Map<String, Object> getOutletSummary(Id accountId) {
        return OVE_Visit_Service.getOutletSummary(accountId);
    }

    /**
     * Credit availability per account for the day board — a color tier plus the
     * available amount, so each outlet can be color-coded by how much headroom
     * it has. Resolved for every outlet on the board in one call.
     */
    @AuraEnabled(cacheable=true)
    public static Map<Id, CreditInfo> getCreditStatusForAccounts(List<Id> accountIds) {
        Map<Id, CreditInfo> result = new Map<Id, CreditInfo>();
        if (accountIds == null || accountIds.isEmpty()) return result;
        for (Account a : [
            SELECT Id, Credit_Limit__c, Credit_Utilized__c, Outstanding_Balance__c,
                   Credit_Period_Days__c
            FROM Account WHERE Id IN :accountIds
        ]) {
            Decimal limitAmt = a.Credit_Limit__c != null ? a.Credit_Limit__c : 0;
            // Exposure = greater of the two divergent credit fields.
            Decimal utilized = Math.max(
                a.Credit_Utilized__c != null ? a.Credit_Utilized__c : 0,
                a.Outstanding_Balance__c != null ? a.Outstanding_Balance__c : 0
            );
            CreditInfo ci = new CreditInfo();
            ci.available = limitAmt - utilized;
            ci.creditDays = a.Credit_Period_Days__c;
            if (limitAmt <= 0) {
                ci.tier = 'none';
            } else if (ci.available <= 0) {
                ci.tier = 'over';
            } else {
                Decimal ratio = ci.available / limitAmt;
                ci.tier = ratio < 0.2 ? 'low' : (ratio < 0.5 ? 'moderate' : 'good');
            }
            result.put(a.Id, ci);
        }
        return result;
    }

    public class CreditInfo {
        @AuraEnabled public String tier;       // good | moderate | low | over | none
        @AuraEnabled public Decimal available; // limit - exposure (may be negative)
        @AuraEnabled public String creditDays; // Credit period in days, for the day-board badge
    }

    // ──────────────────────────────────────────────────
    // PRIVATE HELPERS
    // ──────────────────────────────────────────────────

    private static Visit__c getActiveVisit(Id userId) {
        List<Visit__c> activeVisits = [
            SELECT Id, Name, Account__c, Account__r.Name, Account__r.BillingStreet,
                   Account__r.BillingCity, Beat__c, Beat__r.Name,
                   Visit_Status__c, Visit_Sequence__c, Check_In_Time__c,
                   Check_In_Lat__c, Check_In_Long__c, Is_Ad_Hoc__c, Is_Planned__c,
                   Order_Value__c, Collection_Amount__c, Total_Orders_Count__c,
                   Day_Attendance__c, Notes__c, Duration_Minutes__c,
                   Salesperson__c
            FROM Visit__c
            WHERE Salesperson__c = :userId
              AND Visit_Status__c IN ('Checked In', 'In Progress')
              AND DAY_ONLY(Check_In_Time__c) = TODAY
            ORDER BY Check_In_Time__c DESC
            LIMIT 1
        ];
        return activeVisits.isEmpty() ? null : activeVisits[0];
    }

    private static Map<String, Object> getVisitSummaryData(Id visitId) {
        Map<String, Object> summary = new Map<String, Object>();

        List<Sales_Order__c> orders = [
            SELECT Id, Name, Total_Net_Amount__c, Status__c, Total_Items__c, CreatedDate
            FROM Sales_Order__c
            WHERE Visit__c = :visitId AND Status__c != 'Cancelled'
            ORDER BY CreatedDate DESC
        ];
        summary.put('orders', orders);
        summary.put('ordersCount', orders.size());

        Decimal totalOrderValue = 0;
        for (Sales_Order__c o : orders) {
            totalOrderValue += (o.Total_Net_Amount__c != null ? o.Total_Net_Amount__c : 0);
        }
        summary.put('totalOrderValue', totalOrderValue);

        List<Collection__c> collections = [
            SELECT Id, Name, Amount__c, Payment_Mode__c, Status__c, CreatedDate
            FROM Collection__c
            WHERE Visit__c = :visitId AND Status__c NOT IN ('Cancelled', 'Bounced')
            ORDER BY CreatedDate DESC
        ];
        summary.put('collections', collections);
        summary.put('collectionsCount', collections.size());

        Decimal totalCollection = 0;
        for (Collection__c c : collections) {
            totalCollection += (c.Amount__c != null ? c.Amount__c : 0);
        }
        summary.put('totalCollection', totalCollection);

        List<Return_Order__c> returns = [
            SELECT Id, Name, Total_Return_Amount__c, Status__c, Return_Reason__c, CreatedDate
            FROM Return_Order__c
            WHERE Visit__c = :visitId AND Status__c != 'Cancelled'
            ORDER BY CreatedDate DESC
        ];
        summary.put('returns', returns);
        summary.put('returnsCount', returns.size());

        // Store Score — average of the audit-survey scores captured on this visit.
        // Wrapped defensively: a running user without FLS on the score field must
        // not break the whole visit summary; the score simply won't show.
        Decimal storeScore = null;
        Integer scoredSurveys = 0;
        try {
            List<AggregateResult> scoreAgg = [
                SELECT AVG(Score_Percentage__c) avgScore, COUNT(Id) cnt
                FROM Survey_Response__c
                WHERE Visit__c = :visitId AND Score_Percentage__c != null
            ];
            if (!scoreAgg.isEmpty()) {
                Object cntObj = scoreAgg[0].get('cnt');
                Object avgObj = scoreAgg[0].get('avgScore');
                scoredSurveys = (cntObj != null) ? (Integer) cntObj : 0;
                if (avgObj != null) {
                    storeScore = ((Decimal) avgObj).setScale(0, System.RoundingMode.HALF_UP);
                }
            }
        } catch (Exception e) {
            storeScore = null;
            scoredSurveys = 0;
        }
        summary.put('storeScore', storeScore);
        summary.put('scoredSurveys', scoredSurveys);

        return summary;
    }

    private static String getDayOfWeek(Date d) {
        Date refDate = Date.newInstance(2000, 1, 1);
        Integer dayIndex = Math.mod(refDate.daysBetween(d), 7);
        if (dayIndex < 0) dayIndex += 7;
        List<String> dayNames = new List<String>{
            'Saturday', 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'
        };
        return dayNames[dayIndex];
    }
}