/**
 * @description Service class for Daily Attendance (Day Field Operations) module.
 *              Encapsulates all business logic for day start/end lifecycle,
 *              GPS tracking, summary calculations, and team attendance queries.
 *              Designed to be called from both Controller and TriggerHandler layers.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class DFO_DayAttendance_Service {

    // ── Feature Codes ───────────────────────────────────────────────────────
    public static final String FEATURE_ATTENDANCE    = 'DFO-001';
    public static final String FEATURE_GPS_TRACKING  = 'DFO-002';
    public static final String FEATURE_AUTO_CLOSE    = 'DFO-003';
    public static final String FEATURE_MANAGER_DASH  = 'DFO-004';

    // ── Config Keys ─────────────────────────────────────────────────────────
    private static final String CFG_AUTO_DAY_END_TIME       = 'AUTO_DAY_END_TIME';
    private static final String CFG_MAX_GPS_ACCURACY        = 'MAX_GPS_ACCURACY_METERS';
    private static final String CFG_GPS_TRACKING_INTERVAL   = 'GPS_TRACKING_INTERVAL_SEC';
    private static final String CFG_SELFIE_REQUIRED         = 'SELFIE_REQUIRED';
    private static final String CFG_STATS_REFRESH_INTERVAL  = 'STATS_REFRESH_INTERVAL_SEC';

    // ── App Config Cache ────────────────────────────────────────────────────
    private static Map<String, String> configCache;

    // ── Inner DTO Classes ───────────────────────────────────────────────────

    /**
     * @description Request DTO for starting a day.
     */
    public class DayStartRequest {
        public Decimal startLatitude;
        public Decimal startLongitude;
        public Decimal startAccuracy;
        public String  selfieBase64;
        public Decimal batteryLevel;
        public String  networkStatus;
        public String  deviceInfo;
        public String  dutyType;
        public String  workType;
        public Decimal odometerStart;
        public Boolean withCompanion;
        public Id      companionId;
    }

    /**
     * @description Request DTO for ending a day.
     */
    public class DayEndRequest {
        public Id      attendanceId;
        public Decimal endLatitude;
        public Decimal endLongitude;
        public Decimal endAccuracy;
        public String  selfieBase64;
        public String  remarks;
        public Decimal odometerEnd;
    }

    // ── Day Lifecycle ───────────────────────────────────────────────────────

    /**
     * @description Starts a new day for the current user. Validates feature toggle,
     *              checks for duplicate attendance, verifies no active leave, and
     *              creates the Day_Attendance__c record with GPS log.
     * @param request The DayStartRequest DTO with location and device data.
     * @return The created Day_Attendance__c record.
     */
    public static Day_Attendance__c startDay(DayStartRequest request) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_ATTENDANCE)) {
            throw new AuraHandledException('Daily Attendance feature is currently disabled.');
        }

        Id currentUserId = UserInfo.getUserId();
        Date today = Date.today();

        // Check for duplicate attendance
        List<Day_Attendance__c> existing = [
            SELECT Id, Status__c FROM Day_Attendance__c
            WHERE User__c = :currentUserId
              AND Attendance_Date__c = :today
              AND Status__c NOT IN ('Auto-Closed')
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            throw new AuraHandledException('You have already started your day. Only one active attendance record is allowed per day.');
        }

        // Check for active leave
        List<Leave_Request__c> activeLeave = [
            SELECT Id FROM Leave_Request__c
            WHERE Employee__c = :currentUserId
              AND Status__c = 'Approved'
              AND Start_Date__c <= :today
              AND End_Date__c >= :today
            LIMIT 1
        ];

        // Determine today's beat from Journey Plan
        String dayOfWeek = getDayOfWeek(today);
        Id beatId = null;
        Id journeyPlanDayId = null;
        List<Journey_Plan_Day__c> jpDays = [
            SELECT Id, Beat__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c IN (
                SELECT Id FROM Journey_Plan__c
                WHERE Salesperson__c = :currentUserId
                  AND Status__c = 'Active'
                  AND Effective_From__c <= :today
                  AND Effective_To__c >= :today
            )
            AND Day_of_Week__c = :dayOfWeek
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!jpDays.isEmpty()) {
            beatId = jpDays[0].Beat__c;
            journeyPlanDayId = jpDays[0].Id;
        }

        // Check selfie requirement
        Boolean selfieRequired = getConfigBoolean(CFG_SELFIE_REQUIRED, false);
        if (selfieRequired && String.isBlank(request.selfieBase64)) {
            throw new AuraHandledException('A selfie photo is required to start your day. Please capture a selfie and try again.');
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // Create Day Attendance record
            Day_Attendance__c dayRecord = new Day_Attendance__c();
            dayRecord.User__c = currentUserId;
            dayRecord.Salesperson__c = currentUserId;
            dayRecord.Attendance_Date__c = today;
            dayRecord.Status__c = 'Started';
            dayRecord.Day_Start_Time__c = DateTime.now();
            dayRecord.Start_Time__c = DateTime.now();
            dayRecord.Start_Location_Lat__c = request.startLatitude;
            dayRecord.Start_Location_Long__c = request.startLongitude;
            dayRecord.Start_Accuracy__c = request.startAccuracy;
            dayRecord.Battery_Level__c = request.batteryLevel;
            dayRecord.Network_Status__c = request.networkStatus;
            dayRecord.Device_Info__c = String.isNotBlank(request.deviceInfo) && request.deviceInfo.length() > 255
                ? request.deviceInfo.left(255)
                : request.deviceInfo;
            dayRecord.Week_Day__c = dayOfWeek;
            dayRecord.Beat__c = beatId;
            dayRecord.Journey_Plan_Day__c = journeyPlanDayId;
            dayRecord.Is_Leave_Day__c = !activeLeave.isEmpty();
            dayRecord.Odometer_Start__c = request.odometerStart;
            dayRecord.With_Companion__c = request.withCompanion == true;
            dayRecord.Companion__c = request.withCompanion == true ? request.companionId : null;
            dayRecord.Duty_Type__c = String.isNotBlank(request.dutyType) ? request.dutyType : 'HQ';
            dayRecord.Work_Type__c = String.isNotBlank(request.workType) ? request.workType : null;

            // Initialize counters
            dayRecord.Total_Visits__c = 0;
            dayRecord.Productive_Calls__c = 0;
            dayRecord.Non_Productive_Visits__c = 0;
            dayRecord.Total_Orders__c = 0;
            dayRecord.Total_Order_Value__c = 0;
            dayRecord.Total_Collection__c = 0;
            dayRecord.Total_Distance__c = 0;
            dayRecord.Distance_Traveled_Km__c = 0;

            insert dayRecord;

            // Attach start selfie to day attendance record
            if (String.isNotBlank(request.selfieBase64)) {
                FileAttachment_Util.saveFileToParent(request.selfieBase64, 'DayStart_' + today.format(), dayRecord.Id);
            }

            // Log GPS for day start
            if (BPM_FeatureToggle_Util.isEnabled(FEATURE_GPS_TRACKING) &&
                request.startLatitude != null && request.startLongitude != null) {
                GPS_Log__c gpsLog = new GPS_Log__c();
                gpsLog.Day_Attendance__c = dayRecord.Id;
                gpsLog.Salesperson__c = currentUserId;
                gpsLog.Latitude__c = request.startLatitude;
                gpsLog.Longitude__c = request.startLongitude;
                gpsLog.Accuracy__c = request.startAccuracy;
                gpsLog.Captured_At__c = DateTime.now();
                gpsLog.Log_Type__c = 'Day_Start';
                gpsLog.Battery_Level__c = request.batteryLevel;
                gpsLog.Network_Status__c = request.networkStatus;
                gpsLog.Is_Offline_Captured__c = false;
                insert gpsLog;
            }

            // Re-query to include all relationship fields (avoids SObjectException
            // when callers access fields like Beat_Switched__c on the returned record)
            return getCurrentAttendance(currentUserId);
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Failed to start day: ' + e.getMessage());
        }
    }

    /**
     * @description Ends the current day for the user. Validates status transition,
     *              calculates day summary, logs end GPS, and finalizes the record.
     * @param request The DayEndRequest DTO with end location and remarks.
     * @return The updated Day_Attendance__c record.
     */
    public static Day_Attendance__c endDay(DayEndRequest request) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_ATTENDANCE)) {
            throw new AuraHandledException('Daily Attendance feature is currently disabled.');
        }

        List<Day_Attendance__c> records = [
            SELECT Id, Status__c, User__c, Day_Start_Time__c, Start_Location_Lat__c,
                   Start_Location_Long__c, Attendance_Date__c, Odometer_Start__c
            FROM Day_Attendance__c
            WHERE Id = :request.attendanceId
            LIMIT 1
        ];

        if (records.isEmpty()) {
            throw new AuraHandledException('Day attendance record not found.');
        }

        Day_Attendance__c dayRecord = records[0];

        // Validate status transition
        if (!isValidStatusTransition('Day_Attendance__c', dayRecord.Status__c, 'Ended')) {
            throw new AuraHandledException('Cannot end day from current status: ' + dayRecord.Status__c);
        }

        // Validate odometer reading — end must be greater than start
        if (request.odometerEnd != null && dayRecord.Odometer_Start__c != null
            && request.odometerEnd <= dayRecord.Odometer_Start__c) {
            throw new AuraHandledException(
                'End odometer reading (' + request.odometerEnd +
                ') must be greater than start reading (' + dayRecord.Odometer_Start__c + ').'
            );
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // Calculate hours worked
            DateTime endTime = DateTime.now();
            Long millisWorked = endTime.getTime() - dayRecord.Day_Start_Time__c.getTime();
            Decimal hoursWorked = Decimal.valueOf(millisWorked) / 3600000.0;

            // Calculate total distance from GPS breadcrumbs
            Decimal totalDistanceKm = calculateTotalDistance(dayRecord.Id);

            dayRecord.Status__c = 'Ended';
            dayRecord.Day_End_Time__c = endTime;
            dayRecord.End_Time__c = endTime;
            dayRecord.End_Location_Lat__c = request.endLatitude;
            dayRecord.End_Location_Long__c = request.endLongitude;
            dayRecord.End_Accuracy__c = request.endAccuracy;
            dayRecord.Hours_Worked__c = hoursWorked.setScale(2, RoundingMode.HALF_UP);
            dayRecord.Distance_Traveled_Km__c = totalDistanceKm;
            dayRecord.Total_Distance__c = totalDistanceKm;
            dayRecord.Remarks__c = request.remarks;
            dayRecord.Odometer_End__c = request.odometerEnd;
            dayRecord.Is_Finalized__c = true;

            // Recalculate summary from actual visit data
            recalculateDaySummaryFields(dayRecord);

            update dayRecord;

            // Attach end selfie to day attendance record
            if (String.isNotBlank(request.selfieBase64)) {
                FileAttachment_Util.saveFileToParent(request.selfieBase64, 'DayEnd_' + dayRecord.Attendance_Date__c.format(), dayRecord.Id);
            }

            // Log GPS for day end
            if (BPM_FeatureToggle_Util.isEnabled(FEATURE_GPS_TRACKING) &&
                request.endLatitude != null && request.endLongitude != null) {
                GPS_Log__c gpsLog = new GPS_Log__c();
                gpsLog.Day_Attendance__c = dayRecord.Id;
                gpsLog.Salesperson__c = dayRecord.User__c;
                gpsLog.Latitude__c = request.endLatitude;
                gpsLog.Longitude__c = request.endLongitude;
                gpsLog.Accuracy__c = request.endAccuracy;
                gpsLog.Captured_At__c = DateTime.now();
                gpsLog.Log_Type__c = 'Day_End';
                gpsLog.Is_Offline_Captured__c = false;
                insert gpsLog;
            }

            return dayRecord;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Failed to end day: ' + e.getMessage());
        }
    }

    // ── Summary Calculation ─────────────────────────────────────────────────

    /**
     * @description Recalculates all summary fields on Day_Attendance__c by
     *              aggregating visit, order, and collection data. Bulk-safe.
     * @param attendanceIds Set of Day_Attendance__c Ids to recalculate.
     * @return List of updated Day_Attendance__c records (not yet committed).
     */
    public static List<Day_Attendance__c> calculateDaySummary(Set<Id> attendanceIds) {
        if (attendanceIds == null || attendanceIds.isEmpty()) {
            return new List<Day_Attendance__c>();
        }

        // Aggregate visit data using separate queries (SOQL does not support CASE WHEN)
        Map<Id, Map<String, Object>> visitAggregates = new Map<Id, Map<String, Object>>();

        // Query 1: Total visits + order/collection aggregates
        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId,
                   COUNT(Id) totalVisits,
                   SUM(Order_Value__c) totalOrderValue,
                   SUM(Collection_Amount__c) totalCollection,
                   SUM(Total_Orders_Count__c) totalOrders
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
            GROUP BY Day_Attendance__c
        ]) {
            Map<String, Object> agg = new Map<String, Object>();
            agg.put('totalVisits', ar.get('totalVisits'));
            agg.put('totalOrderValue', ar.get('totalOrderValue'));
            agg.put('totalCollection', ar.get('totalCollection'));
            agg.put('totalOrders', ar.get('totalOrders'));
            visitAggregates.put((Id)ar.get('attId'), agg);
        }

        // Query 2: Productive visit count
        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId, COUNT(Id) cnt
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
              AND Is_Productive__c = true
              AND Visit_Status__c = 'Completed'
            GROUP BY Day_Attendance__c
        ]) {
            Id attId = (Id) ar.get('attId');
            if (!visitAggregates.containsKey(attId)) {
                visitAggregates.put(attId, new Map<String, Object>());
            }
            visitAggregates.get(attId).put('productiveCount', ar.get('cnt'));
        }

        // Query 3: Non-productive visit count
        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId, COUNT(Id) cnt
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
              AND Is_Productive__c = false
              AND Visit_Status__c = 'Completed'
            GROUP BY Day_Attendance__c
        ]) {
            Id attId = (Id) ar.get('attId');
            if (!visitAggregates.containsKey(attId)) {
                visitAggregates.put(attId, new Map<String, Object>());
            }
            visitAggregates.get(attId).put('nonProductiveCount', ar.get('cnt'));
        }

        List<Day_Attendance__c> updates = new List<Day_Attendance__c>();
        for (Id attId : attendanceIds) {
            Day_Attendance__c da = new Day_Attendance__c(Id = attId);
            Map<String, Object> agg = visitAggregates.containsKey(attId)
                ? visitAggregates.get(attId)
                : new Map<String, Object>();

            Integer totalVisits = agg.containsKey('totalVisits') ? (Integer)agg.get('totalVisits') : 0;
            Integer productive = agg.containsKey('productiveCount') ? safeInteger(agg.get('productiveCount')) : 0;
            Integer nonProductive = agg.containsKey('nonProductiveCount') ? safeInteger(agg.get('nonProductiveCount')) : 0;
            Decimal orderValue = agg.containsKey('totalOrderValue') && agg.get('totalOrderValue') != null ? (Decimal)agg.get('totalOrderValue') : 0;
            Decimal collectionAmt = agg.containsKey('totalCollection') && agg.get('totalCollection') != null ? (Decimal)agg.get('totalCollection') : 0;
            Integer totalOrders = agg.containsKey('totalOrders') ? safeInteger(agg.get('totalOrders')) : 0;

            da.Total_Visits__c = totalVisits;
            da.Productive_Calls__c = productive;
            da.Non_Productive_Visits__c = nonProductive;
            da.Total_Order_Value__c = orderValue;
            da.Total_Orders_Value__c = orderValue;
            da.Total_Collection__c = collectionAmt;
            da.Total_Collections__c = collectionAmt;
            da.Total_Orders__c = totalOrders;
            da.Orders_Taken__c = totalOrders;

            // Calculate productivity %
            if (totalVisits > 0) {
                da.Productivity_Percent__c = (Decimal.valueOf(productive) / Decimal.valueOf(totalVisits) * 100).setScale(2, RoundingMode.HALF_UP);
            } else {
                da.Productivity_Percent__c = 0;
            }

            updates.add(da);
        }

        return updates;
    }

    /**
     * @description Recalculates summary for a single attendance record.
     * @param attendanceId The Day_Attendance__c Id.
     */
    public static void recalculateSummary(Id attendanceId) {
        List<Day_Attendance__c> updates = calculateDaySummary(new Set<Id>{ attendanceId });
        if (!updates.isEmpty()) {
            TriggerHandler.bypass('DFO_DayAttendance_TriggerHandler');
            try {
                update updates;
            } finally {
                TriggerHandler.clearBypass('DFO_DayAttendance_TriggerHandler');
            }
        }
    }

    // ── GPS Operations ──────────────────────────────────────────────────────

    /**
     * @description Logs a single GPS breadcrumb point.
     * @param gpsLog The GPS_Log__c record to insert.
     * @return The inserted GPS_Log__c record.
     */
    public static GPS_Log__c logGPS(GPS_Log__c gpsLog) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_GPS_TRACKING)) {
            return gpsLog;
        }
        if (gpsLog.Captured_At__c == null) {
            gpsLog.Captured_At__c = DateTime.now();
        }
        if (gpsLog.Log_Type__c == null) {
            gpsLog.Log_Type__c = 'Breadcrumb';
        }
        insert gpsLog;
        return gpsLog;
    }

    /**
     * @description Bulk inserts GPS logs (for offline sync scenarios).
     * @param gpsLogs List of GPS_Log__c records to insert.
     * @return List of inserted GPS_Log__c records.
     */
    public static List<GPS_Log__c> logGPSBatch(List<GPS_Log__c> gpsLogs) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_GPS_TRACKING)) {
            return gpsLogs;
        }
        for (GPS_Log__c gps : gpsLogs) {
            if (gps.Captured_At__c == null) {
                gps.Captured_At__c = DateTime.now();
            }
            if (gps.Synced_At__c == null) {
                gps.Synced_At__c = DateTime.now();
            }
            if (gps.Log_Type__c == null) {
                gps.Log_Type__c = 'Breadcrumb';
            }
        }
        insert gpsLogs;
        return gpsLogs;
    }

    // ── Query Methods ───────────────────────────────────────────────────────

    /**
     * @description Gets the current day's attendance for a user (or running user if null).
     * @param userId Optional user Id. Defaults to current user.
     * @return The Day_Attendance__c record, or null if not started.
     */
    public static Day_Attendance__c getCurrentAttendance(Id userId) {
        Id targetUserId = userId != null ? userId : UserInfo.getUserId();
        Date today = Date.today();

        List<Day_Attendance__c> records = [
            SELECT Id, Name, User__c, Salesperson__c, Attendance_Date__c, Status__c,
                   Day_Start_Time__c, Day_End_Time__c, Start_Time__c, End_Time__c,
                   Start_Location_Lat__c, Start_Location_Long__c,
                   End_Location_Lat__c, End_Location_Long__c,
                   Battery_Level__c, Network_Status__c, Device_Info__c,
                   Hours_Worked__c, Distance_Traveled_Km__c, Total_Distance__c,
                   Total_Visits__c, Productive_Calls__c, Non_Productive_Visits__c,
                   Total_Orders__c, Orders_Taken__c, Total_Order_Value__c, Total_Orders_Value__c,
                   Total_Collection__c, Total_Collections__c,
                   Productivity_Percent__c, Beat__c, Beat__r.Name,
                   Beat_Switched__c, Original_Beat__c, Original_Beat__r.Name,
                   Beat_Switch_Reason__c,
                   Journey_Plan_Day__c, Journey_Plan_Day__r.Name,
                   Journey_Plan_Day__r.Journey_Plan__c, Journey_Plan_Day__r.Journey_Plan__r.Name,
                   Week_Day__c,
                   Is_Finalized__c, Auto_Closed__c, Is_Leave_Day__c, Remarks__c,
                   Odometer_Start__c, Odometer_End__c
            FROM Day_Attendance__c
            WHERE (User__c = :targetUserId OR Salesperson__c = :targetUserId)
              AND Attendance_Date__c = :today
              AND Status__c IN ('Started', 'In Progress')
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        return records.isEmpty() ? null : records[0];
    }

    /**
     * @description Gets day stats as a Map for the LWC component.
     * @param attendanceId The Day_Attendance__c Id.
     * @return Map of stat key-value pairs.
     */
    public static Map<String, Object> getDayStats(Id attendanceId) {
        Map<String, Object> stats = new Map<String, Object>();

        List<Day_Attendance__c> records = [
            SELECT Total_Visits__c, Productive_Calls__c, Non_Productive_Visits__c,
                   Total_Orders__c, Total_Order_Value__c, Total_Collection__c,
                   Distance_Traveled_Km__c, Productivity_Percent__c, Hours_Worked__c
            FROM Day_Attendance__c
            WHERE Id = :attendanceId
            LIMIT 1
        ];

        if (records.isEmpty()) {
            return stats;
        }

        Day_Attendance__c da = records[0];

        // Get planned visits count from today's journey plan
        Integer plannedVisits = 0;
        List<Visit__c> plannedRecords = [
            SELECT Id FROM Visit__c
            WHERE Day_Attendance__c = :attendanceId
              AND Is_Planned__c = true
        ];
        plannedVisits = plannedRecords.size();

        // Also count planned outlets from the beat
        if (plannedVisits == 0) {
            List<Day_Attendance__c> withBeat = [
                SELECT Beat__c FROM Day_Attendance__c WHERE Id = :attendanceId LIMIT 1
            ];
            if (!withBeat.isEmpty() && withBeat[0].Beat__c != null) {
                plannedVisits = [
                    SELECT COUNT() FROM Beat_Outlet__c
                    WHERE Beat__c = :withBeat[0].Beat__c AND Is_Active__c = true
                ];
            }
        }

        Integer completedVisits = [
            SELECT COUNT() FROM Visit__c
            WHERE Day_Attendance__c = :attendanceId
              AND Visit_Status__c = 'Completed'
        ];

        stats.put('Planned_Visits__c', plannedVisits);
        stats.put('Completed_Visits__c', completedVisits);
        stats.put('Productive_Calls__c', da.Productive_Calls__c != null ? da.Productive_Calls__c : 0);
        stats.put('Non_Productive_Calls__c', da.Non_Productive_Visits__c != null ? da.Non_Productive_Visits__c : 0);
        stats.put('Orders_Today__c', da.Total_Orders__c != null ? da.Total_Orders__c : 0);
        stats.put('Order_Value__c', da.Total_Order_Value__c != null ? da.Total_Order_Value__c : 0);
        stats.put('Collection_Total__c', da.Total_Collection__c != null ? da.Total_Collection__c : 0);
        stats.put('Distance_Covered__c', da.Distance_Traveled_Km__c != null ? da.Distance_Traveled_Km__c : 0);
        stats.put('Productivity_Percent__c', da.Productivity_Percent__c != null ? da.Productivity_Percent__c : 0);

        return stats;
    }

    /**
     * @description Gets team attendance for a manager on a given date.
     * @param managerId The manager's User Id.
     * @param attendanceDate The date to query.
     * @return List of Day_Attendance__c records for direct reports.
     */
    public static List<Day_Attendance__c> getTeamAttendance(Id managerId, Date attendanceDate) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_MANAGER_DASH)) {
            throw new AuraHandledException('Manager Dashboard feature is currently disabled.');
        }

        // Get direct report user IDs
        Set<Id> reportUserIds = getDirectReportUserIds(managerId);
        if (reportUserIds.isEmpty()) {
            return new List<Day_Attendance__c>();
        }

        return [
            SELECT Id, Name, User__c, Salesperson__c, Attendance_Date__c, Status__c,
                   Day_Start_Time__c, Day_End_Time__c, Hours_Worked__c,
                   Total_Visits__c, Productive_Calls__c, Non_Productive_Visits__c,
                   Total_Orders__c, Total_Order_Value__c, Total_Collection__c,
                   Distance_Traveled_Km__c, Productivity_Percent__c,
                   Beat__c, Beat__r.Name, Week_Day__c, Auto_Closed__c,
                   Start_Location_Lat__c, Start_Location_Long__c
            FROM Day_Attendance__c
            WHERE User__c IN :reportUserIds
              AND Attendance_Date__c = :attendanceDate
            ORDER BY Day_Start_Time__c ASC
        ];
    }

    /**
     * @description Gets team attendance summary for a date range.
     * @param managerId The manager's User Id.
     * @param fromDate Start of date range.
     * @param toDate End of date range.
     * @return List of aggregate results by user.
     */
    public static List<Map<String, Object>> getTeamAttendanceSummary(Id managerId, Date fromDate, Date toDate) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_MANAGER_DASH)) {
            throw new AuraHandledException('Manager Dashboard feature is currently disabled.');
        }

        Set<Id> reportUserIds = getDirectReportUserIds(managerId);
        if (reportUserIds.isEmpty()) {
            return new List<Map<String, Object>>();
        }

        List<Map<String, Object>> summary = new List<Map<String, Object>>();
        for (AggregateResult ar : [
            SELECT User__c userId,
                   COUNT(Id) daysWorked,
                   SUM(Hours_Worked__c) totalHours,
                   SUM(Total_Visits__c) totalVisits,
                   SUM(Productive_Calls__c) totalProductive,
                   SUM(Total_Order_Value__c) totalOrderValue,
                   SUM(Total_Collection__c) totalCollection,
                   SUM(Distance_Traveled_Km__c) totalDistance,
                   AVG(Productivity_Percent__c) avgProductivity
            FROM Day_Attendance__c
            WHERE User__c IN :reportUserIds
              AND Attendance_Date__c >= :fromDate
              AND Attendance_Date__c <= :toDate
              AND Status__c IN ('Ended', 'Auto-Closed')
            GROUP BY User__c
        ]) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('userId', ar.get('userId'));
            row.put('daysWorked', ar.get('daysWorked'));
            row.put('totalHours', ar.get('totalHours'));
            row.put('totalVisits', ar.get('totalVisits'));
            row.put('totalProductive', ar.get('totalProductive'));
            row.put('totalOrderValue', ar.get('totalOrderValue'));
            row.put('totalCollection', ar.get('totalCollection'));
            row.put('totalDistance', ar.get('totalDistance'));
            row.put('avgProductivity', ar.get('avgProductivity'));
            summary.add(row);
        }

        return summary;
    }

    // ── App Config ──────────────────────────────────────────────────────────

    /**
     * @description Gets a configuration value from App_Config__mdt.
     * @param configKey The Config_Key__c value.
     * @param defaultValue The default value if not found.
     * @return The configuration value.
     */
    public static String getAppConfig(String configKey, String defaultValue) {
        if (configCache == null) {
            configCache = new Map<String, String>();
            for (App_Config__mdt cfg : [
                SELECT Config_Key__c, Config_Value__c FROM App_Config__mdt
            ]) {
                configCache.put(cfg.Config_Key__c, cfg.Config_Value__c);
            }
        }
        return configCache.containsKey(configKey) ? configCache.get(configKey) : defaultValue;
    }

    /**
     * @description Gets a boolean config value.
     */
    public static Boolean getConfigBoolean(String configKey, Boolean defaultValue) {
        String val = getAppConfig(configKey, String.valueOf(defaultValue));
        return 'true'.equalsIgnoreCase(val);
    }

    /**
     * @description Gets an integer config value.
     */
    public static Integer getConfigInteger(String configKey, Integer defaultValue) {
        String val = getAppConfig(configKey, String.valueOf(defaultValue));
        try {
            return Integer.valueOf(val);
        } catch (Exception e) {
            return defaultValue;
        }
    }

    // ── Status Transition Validation ────────────────────────────────────────

    /**
     * @description Validates if a status transition is allowed per Status_Transition__mdt.
     * @param objectApiName The SObject API name.
     * @param fromStatus The current status.
     * @param toStatus The target status.
     * @return True if the transition is allowed.
     */
    public static Boolean isValidStatusTransition(String objectApiName, String fromStatus, String toStatus) {
        List<Status_Transition__mdt> transitions = [
            SELECT Id FROM Status_Transition__mdt
            WHERE Object_API_Name__c = :objectApiName
              AND From_Status__c = :fromStatus
              AND To_Status__c = :toStatus
              AND Is_Active__c = true
            LIMIT 1
        ];
        return !transitions.isEmpty();
    }

    // ── Private Helpers ─────────────────────────────────────────────────────

    /**
     * @description Total distance travelled, summed from the day's GPS breadcrumbs.
     *
     * The guard is about impossible travel WITHIN one day, not about any region
     * being "wrong" — the product runs in multiple countries, so Tanzanian and
     * Indian coordinates are both perfectly valid. The failure is a single day
     * carrying points from two of them: breadcrumbs captured minutes apart in
     * Bangalore and in Tanzania, which no one can drive between. That happens
     * when breadcrumbs from different sessions land on one day (offline sync
     * flushing a previous session, mock-location testing, or a stray bad fix),
     * and summing raw consecutive distances then adds the round trip and back —
     * a ~6 km day was reported as 9,536 km. The route map looked right because
     * it only plots the clean start/visit/end points, not every breadcrumb.
     *
     * Two guards keep the sum honest, both anchored to THIS day's own location
     * rather than any fixed region, so they adapt wherever the rep actually is:
     *   1. Drop points far from the day's own centre. The median lat/lng is the
     *      dominant cluster and is outlier-proof, so points beyond MAX_RADIUS of
     *      it — a different continent's session bleeding in — are discarded.
     *   2. Skip any remaining segment whose implied speed is impossible, so a
     *      lone teleport between otherwise-valid points can't inflate the total.
     */
    private static Decimal calculateTotalDistance(Id attendanceId) {
        List<GPS_Log__c> gpsLogs = [
            SELECT Latitude__c, Longitude__c, Captured_At__c
            FROM GPS_Log__c
            WHERE Day_Attendance__c = :attendanceId
              AND Latitude__c != null AND Longitude__c != null
            ORDER BY Captured_At__c ASC
        ];
        if (gpsLogs.size() < 2) {
            return 0;
        }

        // Drop the (0,0) null-island sentinel and collect coords for a median centre.
        List<GPS_Log__c> clean = new List<GPS_Log__c>();
        List<Decimal> lats = new List<Decimal>();
        List<Decimal> lngs = new List<Decimal>();
        for (GPS_Log__c g : gpsLogs) {
            if (g.Latitude__c == 0 && g.Longitude__c == 0) continue;
            clean.add(g);
            lats.add(g.Latitude__c);
            lngs.add(g.Longitude__c);
        }
        if (clean.size() < 2) {
            return 0;
        }
        lats.sort();
        lngs.sort();
        Double medLat = (Double) lats[lats.size() / 2];
        Double medLng = (Double) lngs[lngs.size() / 2];

        final Double MAX_RADIUS_METERS = 100000.0;         // 100 km from the day's centre
        final Double MAX_SPEED_MPS = 150.0 * 1000 / 3600;  // 150 km/h in m/s
        final Double MAX_SEGMENT_METERS = 5000.0;          // fallback when no time delta

        Decimal totalMeters = 0;
        GPS_Log__c lastGood = null;
        for (GPS_Log__c g : clean) {
            // Guard 1: reject points far from the day's centre.
            Double fromCentre = OVE_GeoValidation_Service.calculateDistance(
                medLat, medLng, (Double) g.Latitude__c, (Double) g.Longitude__c);
            if (fromCentre > MAX_RADIUS_METERS) continue;

            if (lastGood == null) { lastGood = g; continue; }

            Double meters = OVE_GeoValidation_Service.calculateDistance(
                (Double) lastGood.Latitude__c, (Double) lastGood.Longitude__c,
                (Double) g.Latitude__c, (Double) g.Longitude__c);

            // Guard 2: reject an impossible-speed jump between retained points.
            Boolean plausible;
            if (lastGood.Captured_At__c != null && g.Captured_At__c != null) {
                Long secs = (g.Captured_At__c.getTime() - lastGood.Captured_At__c.getTime()) / 1000;
                plausible = (secs > 0)
                    ? (meters / secs) <= MAX_SPEED_MPS
                    : meters <= MAX_SEGMENT_METERS;
            } else {
                plausible = meters <= MAX_SEGMENT_METERS;
            }

            if (plausible) {
                totalMeters += meters;
                lastGood = g;   // advance the anchor only on a good point
            }
        }

        return (totalMeters / 1000).setScale(2, RoundingMode.HALF_UP);
    }

    /**
     * @description Recomputes Distance_Traveled_Km__c / Total_Distance__c from
     *              GPS breadcrumbs for the given days, using the outlier-resistant
     *              calculation above. A repair entry point for records whose
     *              distance was inflated by bad breadcrumbs before that guard
     *              existed.
     * @return The number of records updated.
     */
    public static Integer recalculateDistances(Set<Id> attendanceIds) {
        if (attendanceIds == null || attendanceIds.isEmpty()) {
            return 0;
        }
        List<Day_Attendance__c> updates = new List<Day_Attendance__c>();
        for (Id aid : attendanceIds) {
            Decimal km = calculateTotalDistance(aid);
            updates.add(new Day_Attendance__c(
                Id = aid, Distance_Traveled_Km__c = km, Total_Distance__c = km));
        }
        if (!updates.isEmpty()) {
            update updates;
        }
        return updates.size();
    }

    /**
     * @description Recalculates summary fields from visit aggregates.
     */
    private static void recalculateDaySummaryFields(Day_Attendance__c dayRecord) {
        List<Day_Attendance__c> calcs = calculateDaySummary(new Set<Id>{ dayRecord.Id });
        if (!calcs.isEmpty()) {
            Day_Attendance__c calc = calcs[0];
            dayRecord.Total_Visits__c = calc.Total_Visits__c;
            dayRecord.Productive_Calls__c = calc.Productive_Calls__c;
            dayRecord.Non_Productive_Visits__c = calc.Non_Productive_Visits__c;
            dayRecord.Total_Orders__c = calc.Total_Orders__c;
            dayRecord.Orders_Taken__c = calc.Orders_Taken__c;
            dayRecord.Total_Order_Value__c = calc.Total_Order_Value__c;
            dayRecord.Total_Orders_Value__c = calc.Total_Orders_Value__c;
            dayRecord.Total_Collection__c = calc.Total_Collection__c;
            dayRecord.Total_Collections__c = calc.Total_Collections__c;
            dayRecord.Productivity_Percent__c = calc.Productivity_Percent__c;
        }
    }

    /**
     * @description Gets direct report user IDs for a manager.
     */
    private static Set<Id> getDirectReportUserIds(Id managerId) {
        Set<Id> userIds = new Set<Id>();
        for (Employee__c emp : [
            SELECT User__c
            FROM Employee__c
            WHERE Reporting_Manager__r.User__c = :managerId
              AND Is_Active__c = true
              AND User__c != null
        ]) {
            userIds.add(emp.User__c);
        }
        return userIds;
    }

    /**
     * @description Converts a Date to day-of-week string.
     */
    private static String getDayOfWeek(Date d) {
        DateTime dt = DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0));
        return dt.format('EEEE');
    }


    /**
     * @description Safely converts an Object to Integer (handles Decimal from aggregates).
     */
    private static Integer safeInteger(Object val) {
        if (val == null) return 0;
        if (val instanceof Integer) return (Integer)val;
        if (val instanceof Decimal) return ((Decimal)val).intValue();
        return 0;
    }

    /**
     * @description Clears the config cache. For testing.
     */
    @TestVisible
    private static void clearConfigCache() {
        configCache = null;
    }
}