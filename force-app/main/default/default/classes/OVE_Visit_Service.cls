/**
 * @description Service class for Visit Management (Outlet Visit Execution) module.
 *              Encapsulates all business logic for visit check-in/check-out lifecycle,
 *              geo-fence validation, planned visit management, outlet 360 summary,
 *              and team visit queries.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class OVE_Visit_Service {

    // ── Feature Codes ───────────────────────────────────────────────────────
    public static final String FEATURE_VISIT_EXECUTION  = 'OVE-001';
    public static final String FEATURE_GEOFENCE         = 'OVE-002';
    public static final String FEATURE_AD_HOC_VISITS    = 'OVE-003';
    public static final String FEATURE_MUST_SELL        = 'SPM-002';

    // ── Config Keys ─────────────────────────────────────────────────────────
    private static final String CFG_MIN_VISIT_DURATION  = 'MIN_VISIT_DURATION_SEC';
    private static final String CFG_MAX_VISITS_PER_DAY  = 'MAX_VISITS_PER_DAY';
    private static final String CFG_ALLOW_GEO_OVERRIDE  = 'ALLOW_GEOFENCE_OVERRIDE';
    private static final String CFG_REQUIRE_PHOTO       = 'REQUIRE_PHOTO_CHECKIN';

    private static final Double DEFAULT_GEOFENCE_RADIUS = 500.0;

    // ── Inner DTO Classes ───────────────────────────────────────────────────

    /**
     * @description Request DTO for visit check-in.
     */
    public class CheckInRequest {
        public Id      accountId;
        public Id      beatId;
        public Id      dayAttendanceId;
        public Id      journeyPlanDayId;
        public Decimal latitude;
        public Decimal longitude;
        public Decimal accuracy;
        public String  photoBase64;
        public Decimal batteryLevel;
        public String  networkStatus;
        public Boolean isPlanned;
        public String  adHocReason;
        public String  geoOverrideReason;
        public Id      existingVisitId;
    }

    /**
     * @description Request DTO for visit check-out / completion.
     */
    public class CheckOutRequest {
        public Id      visitId;
        public Decimal latitude;
        public Decimal longitude;
        public Decimal accuracy;
        public String  photoBase64;
        public Boolean isProductive;
        public String  nonProductiveReason;
        public String  notes;
        public String  completedActivities;
    }

    /**
     * @description Result DTO for geo-fence validation.
     */
    public class GeoValidationResult {
        @AuraEnabled public Boolean isWithinRadius;
        @AuraEnabled public Double  distanceMeters;
        @AuraEnabled public Double  allowedRadius;
        @AuraEnabled public Boolean canOverride;
        @AuraEnabled public String  message;
    }

    // ── Visit Lifecycle ─────────────────────────────────────────────────────

    /**
     * @description Creates a new visit (check-in) at an outlet. Validates feature toggle,
     *              active attendance, geo-fence, and max visits limit.
     * @param request The CheckInRequest DTO.
     * @return The created Visit__c record.
     */
    public static Visit__c checkIn(CheckInRequest request) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_VISIT_EXECUTION)) {
            throw new AuraHandledException('Visit Execution feature is currently disabled.');
        }

        Id currentUserId = UserInfo.getUserId();
        Date today = Date.today();

        // Validate active day attendance
        if (request.dayAttendanceId == null) {
            Day_Attendance__c currentAttendance = DFO_DayAttendance_Service.getCurrentAttendance(currentUserId);
            if (currentAttendance == null) {
                throw new AuraHandledException('Please start your day before checking in to an outlet.');
            }
            request.dayAttendanceId = currentAttendance.Id;
        }

        // Check max visits per day limit
        Integer maxVisits = DFO_DayAttendance_Service.getConfigInteger(CFG_MAX_VISITS_PER_DAY, 30);
        Integer todaysVisitCount = [
            SELECT COUNT() FROM Visit__c
            WHERE Day_Attendance__c = :request.dayAttendanceId
        ];
        if (todaysVisitCount >= maxVisits) {
            throw new AuraHandledException('You have reached the maximum number of visits (' + maxVisits + ') for today.');
        }

        // Check no other visit is currently in progress
        List<Visit__c> activeVisits = [
            SELECT Id, Account__c, Account__r.Name FROM Visit__c
            WHERE Day_Attendance__c = :request.dayAttendanceId
              AND Visit_Status__c IN ('Checked In', 'In Progress')
            LIMIT 1
        ];
        if (!activeVisits.isEmpty()) {
            throw new AuraHandledException('You have an active visit at ' +
                activeVisits[0].Account__r.Name + '. Please complete it before checking in to another outlet.');
        }

        // Validate ad-hoc visit
        Boolean isAdHoc = request.isPlanned != null ? !request.isPlanned : true;
        if (isAdHoc && !BPM_FeatureToggle_Util.isEnabled(FEATURE_AD_HOC_VISITS)) {
            throw new AuraHandledException('Ad-hoc visits are not allowed. Only planned visits from your journey plan can be checked in.');
        }

        // Geo-fence validation
        GeoValidationResult geoResult = null;
        if (BPM_FeatureToggle_Util.isEnabled(FEATURE_GEOFENCE) &&
            request.latitude != null && request.longitude != null) {
            geoResult = validateGeoFence(request.latitude, request.longitude, request.accountId);
            if (!geoResult.isWithinRadius) {
                Boolean allowOverride = DFO_DayAttendance_Service.getConfigBoolean(CFG_ALLOW_GEO_OVERRIDE, true);
                if (!allowOverride || String.isBlank(request.geoOverrideReason)) {
                    throw new AuraHandledException(geoResult.message);
                }
            }
        }

        // Photo requirement check
        Boolean requirePhoto = DFO_DayAttendance_Service.getConfigBoolean(CFG_REQUIRE_PHOTO, false);
        if (requirePhoto && String.isBlank(request.photoBase64)) {
            throw new AuraHandledException('A photo is required for check-in. Please capture a photo and try again.');
        }

        // Calculate visit sequence
        Integer sequence = todaysVisitCount + 1;

        Savepoint sp = Database.setSavepoint();
        try {
            Visit__c visit;
            Boolean isReactivation = false;

            // Check if reactivating an existing skipped visit
            if (request.existingVisitId != null) {
                List<Visit__c> existingVisits = [
                    SELECT Id, Visit_Status__c, Visit_Sequence__c
                    FROM Visit__c
                    WHERE Id = :request.existingVisitId
                      AND Visit_Status__c = 'Skipped'
                    LIMIT 1
                ];
                if (!existingVisits.isEmpty()) {
                    visit = existingVisits[0];
                    isReactivation = true;
                    sequence = visit.Visit_Sequence__c != null ? Integer.valueOf(visit.Visit_Sequence__c) : sequence;
                }
            }

            if (visit == null) {
                visit = new Visit__c();
            }

            visit.Account__c = request.accountId;
            visit.Outlet__c = request.accountId;
            visit.Salesperson__c = currentUserId;
            visit.User__c = currentUserId;
            visit.Beat__c = request.beatId;
            visit.Day_Attendance__c = request.dayAttendanceId;
            visit.Journey_Plan_Day__c = request.journeyPlanDayId;
            visit.Visit_Date__c = today;
            visit.Visit_Status__c = 'Checked In';
            visit.Check_In_Time__c = DateTime.now();
            visit.Check_In_Latitude__c = request.latitude;
            visit.Check_In_Longitude__c = request.longitude;
            visit.Check_In_Lat__c = request.latitude;
            visit.Check_In_Long__c = request.longitude;
            visit.Check_In_Accuracy__c = request.accuracy;
            visit.Check_In_Battery__c = request.batteryLevel != null ? String.valueOf(request.batteryLevel.intValue()) : null;
            visit.Check_In_Network__c = request.networkStatus;
            visit.Visit_Sequence__c = sequence;
            visit.Is_Planned__c = !isAdHoc;
            visit.Is_Ad_Hoc__c = isAdHoc;

            // Clear skip-related fields on reactivation
            if (isReactivation) {
                visit.Missed_Reason__c = null;
                visit.Missed_Notes__c = null;
            }

            if (isAdHoc && String.isNotBlank(request.adHocReason)) {
                visit.Ad_Hoc_Reason__c = request.adHocReason;
            }

            // Geo-fence data
            if (geoResult != null) {
                visit.Distance_To_Outlet__c = geoResult.distanceMeters;
                visit.Is_Geo_Fenced__c = geoResult.isWithinRadius;
                if (!geoResult.isWithinRadius && String.isNotBlank(request.geoOverrideReason)) {
                    visit.Geo_Fence_Override_Reason__c = request.geoOverrideReason;
                }
            }

            // Initialize counters
            visit.Order_Value__c = 0;
            visit.Collection_Amount__c = 0;
            visit.Total_Orders_Count__c = 0;

            if (isReactivation) {
                update visit;
            } else {
                insert visit;
            }

            // Attach check-in photo to visit record
            if (String.isNotBlank(request.photoBase64)) {
                FileAttachment_Util.saveFileToParent(request.photoBase64, 'CheckIn_' + request.accountId, visit.Id);
            }

            // Log GPS for visit check-in
            if (BPM_FeatureToggle_Util.isEnabled(DFO_DayAttendance_Service.FEATURE_GPS_TRACKING) &&
                request.latitude != null && request.longitude != null) {
                GPS_Log__c gpsLog = new GPS_Log__c();
                gpsLog.Day_Attendance__c = request.dayAttendanceId;
                gpsLog.Visit__c = visit.Id;
                gpsLog.Salesperson__c = currentUserId;
                gpsLog.Latitude__c = request.latitude;
                gpsLog.Longitude__c = request.longitude;
                gpsLog.Accuracy__c = request.accuracy;
                gpsLog.Captured_At__c = DateTime.now();
                gpsLog.Log_Type__c = 'Visit_CheckIn';
                gpsLog.Battery_Level__c = request.batteryLevel;
                gpsLog.Network_Status__c = request.networkStatus;
                gpsLog.Is_Offline_Captured__c = false;
                insert gpsLog;
            }

            return visit;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Failed to check in: ' + e.getMessage());
        }
    }

    /**
     * @description Completes a visit (check-out). Validates status transition,
     *              calculates duration, marks productivity, and updates attendance.
     * @param request The CheckOutRequest DTO.
     * @return The updated Visit__c record.
     */
    public static Visit__c checkOut(CheckOutRequest request) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_VISIT_EXECUTION)) {
            throw new AuraHandledException('Visit Execution feature is currently disabled.');
        }

        List<Visit__c> visits = [
            SELECT Id, Visit_Status__c, Check_In_Time__c, Day_Attendance__c,
                   Account__c, Salesperson__c, User__c,
                   Check_In_Latitude__c, Check_In_Longitude__c
            FROM Visit__c
            WHERE Id = :request.visitId
            LIMIT 1
        ];

        if (visits.isEmpty()) {
            throw new AuraHandledException('Visit record not found.');
        }

        Visit__c visit = visits[0];

        // Validate status transition
        if (!DFO_DayAttendance_Service.isValidStatusTransition('Visit__c', visit.Visit_Status__c, 'Completed')) {
            throw new AuraHandledException('Cannot complete visit from current status: ' + visit.Visit_Status__c);
        }

        // Check minimum visit duration
        Integer minDurationSec = DFO_DayAttendance_Service.getConfigInteger(CFG_MIN_VISIT_DURATION, 60);
        DateTime now = DateTime.now();
        Long durationMs = now.getTime() - visit.Check_In_Time__c.getTime();
        Decimal durationMinutes = Decimal.valueOf(durationMs) / 60000.0;

        if (durationMs / 1000 < minDurationSec) {
            throw new AuraHandledException('Minimum visit duration is ' + minDurationSec +
                ' seconds. Please spend more time at the outlet.');
        }

        Savepoint sp = Database.setSavepoint();
        try {
            visit.Visit_Status__c = 'Completed';
            visit.Check_Out_Time__c = now;
            visit.Check_Out_Lat__c = request.latitude;
            visit.Check_Out_Long__c = request.longitude;
            visit.Check_Out_Accuracy__c = request.accuracy;
            visit.Duration_Minutes__c = durationMinutes.setScale(1, RoundingMode.HALF_UP);
            visit.Is_Productive__c = request.isProductive != null ? request.isProductive : true;
            visit.Notes__c = request.notes;

            if (request.isProductive == false && String.isNotBlank(request.nonProductiveReason)) {
                visit.Non_Productive_Reason__c = request.nonProductiveReason;
            }

            if (String.isNotBlank(request.completedActivities)) {
                visit.Completion_Activities__c = request.completedActivities;
            }

            // Aggregate order and collection totals from this visit
            aggregateVisitTotals(visit);

            // Calculate Must Sell compliance if feature is enabled
            if (BPM_FeatureToggle_Util.isEnabled(FEATURE_MUST_SELL)) {
                calculateMustSellCompliance(visit);
            }

            update visit;

            // Attach check-out photo to visit record
            if (String.isNotBlank(request.photoBase64)) {
                FileAttachment_Util.saveFileToParent(request.photoBase64, 'CheckOut_' + visit.Account__c, visit.Id);
            }

            // Log GPS for visit check-out
            if (BPM_FeatureToggle_Util.isEnabled(DFO_DayAttendance_Service.FEATURE_GPS_TRACKING) &&
                request.latitude != null && request.longitude != null) {
                GPS_Log__c gpsLog = new GPS_Log__c();
                gpsLog.Day_Attendance__c = visit.Day_Attendance__c;
                gpsLog.Visit__c = visit.Id;
                gpsLog.Salesperson__c = visit.User__c;
                gpsLog.Latitude__c = request.latitude;
                gpsLog.Longitude__c = request.longitude;
                gpsLog.Accuracy__c = request.accuracy;
                gpsLog.Captured_At__c = DateTime.now();
                gpsLog.Log_Type__c = 'Visit_CheckOut';
                gpsLog.Is_Offline_Captured__c = false;
                insert gpsLog;
            }

            // Recalculate Day Attendance summary
            if (visit.Day_Attendance__c != null) {
                DFO_DayAttendance_Service.recalculateSummary(visit.Day_Attendance__c);
            }

            return visit;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Failed to check out: ' + e.getMessage());
        }
    }

    /**
     * @description Skips a planned visit with a reason.
     * @param visitId The Visit__c Id to skip.
     * @param skipReason The reason for skipping.
     * @return The updated Visit__c record.
     */
    public static Visit__c skipVisit(Id visitId, String skipReason) {
        List<Visit__c> visits = [
            SELECT Id, Visit_Status__c, Day_Attendance__c
            FROM Visit__c WHERE Id = :visitId LIMIT 1
        ];

        if (visits.isEmpty()) {
            throw new AuraHandledException('Visit record not found.');
        }

        Visit__c visit = visits[0];
        if (!DFO_DayAttendance_Service.isValidStatusTransition('Visit__c', visit.Visit_Status__c, 'Skipped')) {
            throw new AuraHandledException('Cannot skip visit from current status: ' + visit.Visit_Status__c);
        }

        visit.Visit_Status__c = 'Skipped';
        visit.Deviation_Reason__c = skipReason;
        visit.Is_Productive__c = false;
        visit.Non_Productive_Reason__c = 'Visit Skipped';
        update visit;

        return visit;
    }

    // ── Geo-Fence Validation ────────────────────────────────────────────────

    /**
     * @description Validates check-in location against outlet's registered location.
     * @param latitude Check-in latitude.
     * @param longitude Check-in longitude.
     * @param accountId The outlet Account Id.
     * @return GeoValidationResult with distance and status.
     */
    public static GeoValidationResult validateGeoFence(Decimal latitude, Decimal longitude, Id accountId) {
        GeoValidationResult result = new GeoValidationResult();
        result.canOverride = DFO_DayAttendance_Service.getConfigBoolean(CFG_ALLOW_GEO_OVERRIDE, true);

        if (accountId == null || latitude == null || longitude == null) {
            result.isWithinRadius = true;
            result.distanceMeters = 0;
            result.allowedRadius = DEFAULT_GEOFENCE_RADIUS;
            result.message = 'Location data unavailable, check-in allowed.';
            return result;
        }

        List<Account> outlets = [
            SELECT Id, Outlet_Latitude__c, Outlet_Longitude__c, Geofence_Radius__c
            FROM Account WHERE Id = :accountId LIMIT 1
        ];

        if (outlets.isEmpty() || outlets[0].Outlet_Latitude__c == null || outlets[0].Outlet_Longitude__c == null) {
            result.isWithinRadius = true;
            result.distanceMeters = 0;
            result.allowedRadius = DEFAULT_GEOFENCE_RADIUS;
            result.message = 'Outlet location not registered, check-in allowed.';
            return result;
        }

        Account outlet = outlets[0];

        // Get configured default radius
        Double configuredRadius = DEFAULT_GEOFENCE_RADIUS;
        try {
            List<Geo_Config__mdt> configs = [
                SELECT Value__c FROM Geo_Config__mdt
                WHERE DeveloperName = 'Default_Geofence_Radius' LIMIT 1
            ];
            if (!configs.isEmpty() && configs[0].Value__c != null) {
                configuredRadius = Double.valueOf(configs[0].Value__c);
            }
        } catch (Exception e) {
            // Use default
        }

        Double allowedRadius = outlet.Geofence_Radius__c != null
            ? outlet.Geofence_Radius__c : configuredRadius;

        Double distance = OVE_GeoValidation_Service.calculateDistance(
            (Double)latitude, (Double)longitude,
            (Double)outlet.Outlet_Latitude__c, (Double)outlet.Outlet_Longitude__c
        );

        result.distanceMeters = distance;
        result.allowedRadius = allowedRadius;
        result.isWithinRadius = distance <= allowedRadius;

        if (result.isWithinRadius) {
            result.message = 'You are within the allowed radius (' + Math.round(distance) + 'm / ' + Math.round(allowedRadius) + 'm).';
        } else {
            result.message = 'You are ' + Math.round(distance) + 'm from the outlet, which exceeds the allowed radius of ' + Math.round(allowedRadius) + 'm.';
            if (result.canOverride) {
                result.message += ' You may override with a reason.';
            }
        }

        return result;
    }

    // ── Query Methods ───────────────────────────────────────────────────────

    /**
     * @description Gets today's visits for a user.
     * @param userId The User Id (null = current user).
     * @return List of Visit__c records ordered by sequence.
     */
    public static List<Visit__c> getTodaysVisits(Id userId) {
        Id targetUserId = userId != null ? userId : UserInfo.getUserId();
        Date today = Date.today();

        return [
            SELECT Id, Name, Account__c, Account__r.Name, Account__r.Type,
                   Beat__c, Beat__r.Name, Visit_Date__c, Visit_Status__c,
                   Check_In_Time__c, Check_Out_Time__c, Duration_Minutes__c,
                   Visit_Sequence__c, Is_Planned__c, Is_Ad_Hoc__c,
                   Is_Productive__c, Non_Productive_Reason__c,
                   Order_Value__c, Collection_Amount__c, Total_Orders_Count__c,
                   Notes__c, Completion_Activities__c,
                   Distance_To_Outlet__c, Is_Geo_Fenced__c,
                   Day_Attendance__c
            FROM Visit__c
            WHERE Salesperson__c = :targetUserId
              AND Visit_Date__c = :today
            ORDER BY Visit_Sequence__c ASC NULLS LAST, Check_In_Time__c ASC
        ];
    }

    /**
     * @description Gets planned visits from today's journey plan for a user.
     * @param userId The User Id.
     * @param visitDate The date.
     * @return List of maps with outlet info and visit status.
     */
    public static List<Map<String, Object>> getPlannedVisits(Id userId, Date visitDate) {
        Id targetUserId = userId != null ? userId : UserInfo.getUserId();
        String dayOfWeek = getDayOfWeek(visitDate);
        List<Map<String, Object>> planned = new List<Map<String, Object>>();

        // Get journey plan days for this user and date — include Draft, Approved, and Active plans
        List<Journey_Plan_Day__c> jpDays = [
            SELECT Id, Beat__c, Beat__r.Name
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c IN (
                SELECT Id FROM Journey_Plan__c
                WHERE Salesperson__c = :targetUserId
                  AND Status__c IN ('Draft', 'Approved', 'Active')
                  AND Effective_From__c <= :visitDate
                  AND Effective_To__c >= :visitDate
            )
            AND (Plan_Date__c = :visitDate OR Day_of_Week__c = :dayOfWeek)
        ];

        Set<Id> beatIds = new Set<Id>();
        Map<Id, Id> beatToJpDay = new Map<Id, Id>();
        for (Journey_Plan_Day__c jpd : jpDays) {
            beatIds.add(jpd.Beat__c);
            beatToJpDay.put(jpd.Beat__c, jpd.Id);
        }

        // Ensure the current attendance beat is always included — handles:
        // 1. No journey plan at all (beatIds is empty)
        // 2. Beat switch to a beat not in today's journey plan
        List<Day_Attendance__c> currentAtt = [
            SELECT Beat__c FROM Day_Attendance__c
            WHERE Salesperson__c = :targetUserId
              AND Attendance_Date__c = :visitDate
              AND Status__c IN ('Started', 'In Progress')
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (!currentAtt.isEmpty() && currentAtt[0].Beat__c != null) {
            beatIds.add(currentAtt[0].Beat__c);
        }

        if (beatIds.isEmpty()) {
            return planned;
        }

        // Get beat outlets
        List<Beat_Outlet__c> beatOutlets = [
            SELECT Id, Beat__c, Beat__r.Name, Account__c,
                   Account__r.Name, Account__r.Type, Account__r.BillingCity,
                   Account__r.Outlet_Latitude__c, Account__r.Outlet_Longitude__c,
                   Visit_Sequence__c
            FROM Beat_Outlet__c
            WHERE Beat__c IN :beatIds
              AND Is_Active__c = true
            ORDER BY Visit_Sequence__c ASC
        ];

        // Check existing visits for today
        Set<Id> accountIds = new Set<Id>();
        for (Beat_Outlet__c bo : beatOutlets) {
            accountIds.add(bo.Account__c);
        }

        Map<Id, Visit__c> existingVisitsByAccount = new Map<Id, Visit__c>();
        for (Visit__c v : [
            SELECT Id, Account__c, Visit_Status__c, Check_In_Time__c, Check_Out_Time__c,
                   Is_Productive__c, Order_Value__c
            FROM Visit__c
            WHERE Salesperson__c = :targetUserId
              AND Visit_Date__c = :visitDate
              AND Account__c IN :accountIds
        ]) {
            existingVisitsByAccount.put(v.Account__c, v);
        }

        // Build planned visits list
        for (Beat_Outlet__c bo : beatOutlets) {
            Map<String, Object> pv = new Map<String, Object>();
            pv.put('beatOutletId', bo.Id);
            pv.put('accountId', bo.Account__c);
            pv.put('accountName', bo.Account__r.Name);
            pv.put('accountType', bo.Account__r.Type);
            pv.put('city', bo.Account__r.BillingCity);
            pv.put('beatId', bo.Beat__c);
            pv.put('beatName', bo.Beat__r.Name);
            pv.put('journeyPlanDayId', beatToJpDay.get(bo.Beat__c));
            pv.put('sequence', bo.Visit_Sequence__c);
            pv.put('outletLatitude', bo.Account__r.Outlet_Latitude__c);
            pv.put('outletLongitude', bo.Account__r.Outlet_Longitude__c);

            Visit__c existingVisit = existingVisitsByAccount.get(bo.Account__c);
            if (existingVisit != null) {
                pv.put('visitId', existingVisit.Id);
                pv.put('visitStatus', existingVisit.Visit_Status__c);
                pv.put('checkInTime', existingVisit.Check_In_Time__c);
                pv.put('checkOutTime', existingVisit.Check_Out_Time__c);
                pv.put('isProductive', existingVisit.Is_Productive__c);
                pv.put('orderValue', existingVisit.Order_Value__c);
            } else {
                pv.put('visitStatus', 'Planned');
            }

            planned.add(pv);
        }

        return planned;
    }

    /**
     * @description Gets a 360-degree view of an outlet for the visit screen.
     * @param accountId The Account Id.
     * @return Map of outlet summary data.
     */
    public static Map<String, Object> getOutletSummary(Id accountId) {
        Map<String, Object> summary = new Map<String, Object>();

        if (accountId == null) {
            return summary;
        }

        // Basic outlet info
        List<Account> outlets = [
            SELECT Id, Name, Type, RecordType.Name, Channel__c, Outlet_Type__c,
                   BillingCity, BillingState, Credit_Limit__c,
                   Credit_Utilized__c, Outstanding_Balance__c,
                   Outlet_Latitude__c, Outlet_Longitude__c, Geofence_Radius__c
            FROM Account WHERE Id = :accountId LIMIT 1
        ];

        if (!outlets.isEmpty()) {
            Account outlet = outlets[0];
            summary.put('outletName', outlet.Name);
            summary.put('outletType', outlet.RecordType != null ? outlet.RecordType.Name : (outlet.Type != null ? outlet.Type : '--'));
            summary.put('outletFormat', outlet.Outlet_Type__c);
            summary.put('channel', outlet.Channel__c);
            summary.put('city', outlet.BillingCity);
            summary.put('creditLimit', outlet.Credit_Limit__c);
            // Credit exposure — the greater of the two divergent fields, so the
            // status is right whether an outlet tracks Credit_Utilized__c or the
            // legacy Outstanding_Balance__c.
            summary.put('creditUtilized', Math.max(
                outlet.Credit_Utilized__c != null ? outlet.Credit_Utilized__c : 0,
                outlet.Outstanding_Balance__c != null ? outlet.Outstanding_Balance__c : 0
            ));
        }

        // Last visit
        List<Visit__c> lastVisits = [
            SELECT Visit_Date__c, Visit_Status__c, Is_Productive__c
            FROM Visit__c
            WHERE Account__c = :accountId
              AND Visit_Status__c = 'Completed'
            ORDER BY Visit_Date__c DESC LIMIT 1
        ];
        summary.put('lastVisitDate', !lastVisits.isEmpty() ?
            String.valueOf(lastVisits[0].Visit_Date__c) : 'No previous visit');

        // Pending orders
        Integer pendingOrders = [
            SELECT COUNT() FROM Sales_Order__c
            WHERE Account__c = :accountId
              AND Status__c NOT IN ('Delivered', 'Cancelled')
        ];
        summary.put('pendingOrders', pendingOrders);

        // Outstanding balance
        Decimal outstandingBalance = 0;
        for (AggregateResult ar : [
            SELECT SUM(Balance_Due__c) totalDue
            FROM Invoice__c
            WHERE Account__c = :accountId
              AND Balance_Due__c > 0
              AND Status__c NOT IN ('Cancelled', 'Credit Note')
        ]) {
            if (ar.get('totalDue') != null) {
                outstandingBalance = (Decimal) ar.get('totalDue');
            }
        }
        summary.put('outstandingBalance', outstandingBalance);
        summary.put('outstandingBalanceFormatted', formatCurrency(outstandingBalance));

        // Active schemes count
        Date today = Date.today();
        Integer activeSchemes = [
            SELECT COUNT() FROM Scheme__c
            WHERE Status__c = 'Active'
              AND Start_Date__c <= :today
              AND End_Date__c >= :today
        ];
        summary.put('activeSchemes', activeSchemes);

        return summary;
    }

    /**
     * @description Gets a visit completion summary (activities during visit).
     * @param visitId The Visit__c Id.
     * @return Map of completion data.
     */
    public static Map<String, Object> getVisitCompletionSummary(Id visitId) {
        Map<String, Object> summary = new Map<String, Object>();

        List<Visit__c> visits = [
            SELECT Id, Account__c, Visit_Status__c, Check_In_Time__c, Check_Out_Time__c,
                   Duration_Minutes__c, Is_Productive__c, Order_Value__c, Collection_Amount__c,
                   Total_Orders_Count__c, Notes__c, Completion_Activities__c,
                   Stock_Check_Completed__c, Competitor_Check_Completed__c,
                   Merchandising_Completed__c, Survey_Completed__c, Ticket_Logged__c,
                   Must_Sell_Compliance__c, Must_Sell_Products_Ordered__c, Must_Sell_Products_Required__c
            FROM Visit__c WHERE Id = :visitId LIMIT 1
        ];

        if (visits.isEmpty()) {
            return summary;
        }

        Visit__c visit = visits[0];
        summary.put('duration', visit.Duration_Minutes__c);
        summary.put('isProductive', visit.Is_Productive__c);
        summary.put('orderValue', visit.Order_Value__c);
        summary.put('collectionAmount', visit.Collection_Amount__c);
        summary.put('ordersCount', visit.Total_Orders_Count__c);
        summary.put('activities', visit.Completion_Activities__c);

        // Get orders placed during this visit
        List<Sales_Order__c> orders = [
            SELECT Id, Name, Total_Net_Amount__c, Status__c, Total_Items__c
            FROM Sales_Order__c
            WHERE Visit__c = :visitId
            ORDER BY CreatedDate DESC
        ];
        summary.put('orders', orders);

        // Get collections during this visit
        List<Collection__c> collections = [
            SELECT Id, Name, Amount__c, Payment_Mode__c, Status__c
            FROM Collection__c
            WHERE Visit__c = :visitId
            ORDER BY CreatedDate DESC
        ];
        summary.put('collections', collections);

        // Return orders
        List<Return_Order__c> returnOrders = [
            SELECT Id, Name, Total_Return_Amount__c, Status__c
            FROM Return_Order__c
            WHERE Visit__c = :visitId
            ORDER BY CreatedDate DESC
        ];
        summary.put('returns', returnOrders);
        summary.put('returnsCount', returnOrders.size());

        // Activity completion flags
        summary.put('stockCheckCompleted', visit.Stock_Check_Completed__c);
        summary.put('competitorCheckCompleted', visit.Competitor_Check_Completed__c);
        summary.put('merchandisingCompleted', visit.Merchandising_Completed__c);
        summary.put('surveyCompleted', visit.Survey_Completed__c);
        summary.put('ticketLogged', visit.Ticket_Logged__c);

        // Must Sell compliance
        summary.put('mustSellCompliance', visit.Must_Sell_Compliance__c);
        summary.put('mustSellOrdered', visit.Must_Sell_Products_Ordered__c);
        summary.put('mustSellRequired', visit.Must_Sell_Products_Required__c);

        return summary;
    }

    /**
     * @description Gets configurable visit activities list.
     * @return List of activity definitions.
     */
    public static List<Map<String, Object>> getVisitActivities(Id visitId) {
        List<Map<String, Object>> activities = new List<Map<String, Object>>();

        // Query visit for completion flags
        Boolean stockCompleted = false;
        Boolean availabilityCompleted = false;
        Boolean competitorCompleted = false;
        Boolean merchandisingCompleted = false;
        Boolean surveyCompleted = false;
        Boolean ticketLogged = false;
        Integer ordersCount = 0;
        Integer collectionsCount = 0;
        Integer returnsCount = 0;

        // The visited outlet's type scopes which activities are shown.
        String outletType = null;

        if (visitId != null) {
            List<Visit__c> visits = [
                SELECT Id, Stock_Check_Completed__c, Availability_Check_Completed__c,
                       Competitor_Check_Completed__c,
                       Merchandising_Completed__c, Survey_Completed__c, Ticket_Logged__c,
                       Account__r.Outlet_Type__c
                FROM Visit__c WHERE Id = :visitId LIMIT 1
            ];
            if (!visits.isEmpty()) {
                Visit__c v = visits[0];
                outletType = (v.Account__r == null) ? null : v.Account__r.Outlet_Type__c;
                stockCompleted = v.Stock_Check_Completed__c == true;
                availabilityCompleted = v.Availability_Check_Completed__c == true;
                competitorCompleted = v.Competitor_Check_Completed__c == true;
                merchandisingCompleted = v.Merchandising_Completed__c == true;
                surveyCompleted = v.Survey_Completed__c == true;
                ticketLogged = v.Ticket_Logged__c == true;
            }
            ordersCount = [SELECT COUNT() FROM Sales_Order__c WHERE Visit__c = :visitId AND Status__c != 'Cancelled'];
            collectionsCount = [SELECT COUNT() FROM Collection__c WHERE Visit__c = :visitId AND Status__c NOT IN ('Cancelled', 'Bounced')];
            returnsCount = [SELECT COUNT() FROM Return_Order__c WHERE Visit__c = :visitId AND Status__c != 'Cancelled'];
        }

        // Which tiles this user, at this outlet type, is allowed to see.
        // VisitActivityConfig applies the feature toggles first (is the module
        // licensed at all) and then the Profile / Outlet Type rules on top, so
        // an org with no rules configured gets exactly the previous behaviour.
        Set<String> visible = VisitActivityConfig.visibleKeys(outletType);
        Map<String, Integer> order = VisitActivityConfig.sortOrders(outletType);

        Map<String, Boolean> completedByKey = new Map<String, Boolean>{
            'order'         => ordersCount > 0,
            'collection'    => collectionsCount > 0,
            'returns'       => returnsCount > 0,
            'stock_check'   => stockCompleted,
            'availability'  => availabilityCompleted,
            'competitor'    => competitorCompleted,
            'merchandising' => merchandisingCompleted,
            'survey'        => surveyCompleted,
            'scheme'        => false,
            'ticket'        => ticketLogged
        };

        List<ActivitySort> sortable = new List<ActivitySort>();
        for (VisitActivityConfig.ActivityDef d : VisitActivityConfig.CATALOG) {
            if (!visible.contains(d.key)) continue;
            Boolean done = completedByKey.containsKey(d.key) && completedByKey.get(d.key) == true;
            Integer pos = order.containsKey(d.key) ? order.get(d.key) : d.sortOrder;
            sortable.add(new ActivitySort(pos, createActivity(d.key, d.label, d.icon, true, done)));
        }
        sortable.sort();
        for (ActivitySort s : sortable) {
            activities.add(s.activity);
        }

        return activities;
    }

    /** Orders the resolved tiles, honouring any per-rule Sort Order override. */
    private class ActivitySort implements Comparable {
        Integer position;
        Map<String, Object> activity;
        ActivitySort(Integer position, Map<String, Object> activity) {
            this.position = position;
            this.activity = activity;
        }
        public Integer compareTo(Object other) {
            ActivitySort o = (ActivitySort) other;
            if (this.position == o.position) return 0;
            return this.position > o.position ? 1 : -1;
        }
    }

    /**
     * @description Gets team visits for a manager on a given date.
     */
    public static List<Map<String, Object>> getTeamVisits(Id managerId, Date visitDate) {
        Set<Id> reportUserIds = getDirectReportUserIds(managerId);
        if (reportUserIds.isEmpty()) {
            return new List<Map<String, Object>>();
        }

        // Use separate queries since SOQL does not support CASE WHEN
        Map<Id, Map<String, Object>> userAggregates = new Map<Id, Map<String, Object>>();

        // Query 1: Total visits + order/collection aggregates per user
        for (AggregateResult ar : [
            SELECT Salesperson__c userId,
                   COUNT(Id) totalVisits,
                   SUM(Order_Value__c) totalOrderValue,
                   SUM(Collection_Amount__c) totalCollection
            FROM Visit__c
            WHERE Salesperson__c IN :reportUserIds
              AND Visit_Date__c = :visitDate
            GROUP BY Salesperson__c
        ]) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('userId', ar.get('userId'));
            row.put('totalVisits', ar.get('totalVisits'));
            row.put('totalOrderValue', ar.get('totalOrderValue'));
            row.put('totalCollection', ar.get('totalCollection'));
            userAggregates.put((Id)ar.get('userId'), row);
        }

        // Query 2: Completed visits per user
        for (AggregateResult ar : [
            SELECT Salesperson__c userId, COUNT(Id) cnt
            FROM Visit__c
            WHERE Salesperson__c IN :reportUserIds
              AND Visit_Date__c = :visitDate
              AND Visit_Status__c = 'Completed'
            GROUP BY Salesperson__c
        ]) {
            Id userId = (Id) ar.get('userId');
            if (userAggregates.containsKey(userId)) {
                userAggregates.get(userId).put('completedVisits', ar.get('cnt'));
            }
        }

        // Query 3: Productive visits per user
        for (AggregateResult ar : [
            SELECT Salesperson__c userId, COUNT(Id) cnt
            FROM Visit__c
            WHERE Salesperson__c IN :reportUserIds
              AND Visit_Date__c = :visitDate
              AND Is_Productive__c = true
            GROUP BY Salesperson__c
        ]) {
            Id userId = (Id) ar.get('userId');
            if (userAggregates.containsKey(userId)) {
                userAggregates.get(userId).put('productiveVisits', ar.get('cnt'));
            }
        }

        // Build result list with defaults for missing counts
        List<Map<String, Object>> teamVisits = new List<Map<String, Object>>();
        for (Map<String, Object> row : userAggregates.values()) {
            if (!row.containsKey('completedVisits')) {
                row.put('completedVisits', 0);
            }
            if (!row.containsKey('productiveVisits')) {
                row.put('productiveVisits', 0);
            }
            teamVisits.add(row);
        }

        return teamVisits;
    }

    // ── Private Helpers ─────────────────────────────────────────────────────

    private static void aggregateVisitTotals(Visit__c visit) {
        // Aggregate orders for this visit
        for (AggregateResult ar : [
            SELECT COUNT(Id) orderCount, SUM(Total_Net_Amount__c) totalValue
            FROM Sales_Order__c
            WHERE Visit__c = :visit.Id
              AND Status__c != 'Cancelled'
        ]) {
            visit.Total_Orders_Count__c = ar.get('orderCount') != null ? (Integer)ar.get('orderCount') : 0;
            Decimal orderVal = (Decimal)ar.get('totalValue');
            visit.Order_Value__c = orderVal != null ? orderVal : 0;
        }

        // Aggregate collections for this visit
        for (AggregateResult ar : [
            SELECT SUM(Amount__c) totalAmount
            FROM Collection__c
            WHERE Visit__c = :visit.Id
              AND Status__c NOT IN ('Cancelled', 'Bounced')
        ]) {
            Decimal collVal = (Decimal)ar.get('totalAmount');
            visit.Collection_Amount__c = collVal != null ? collVal : 0;
        }
    }

    private static void calculateMustSellCompliance(Visit__c visit) {
        Date today = Date.today();

        // Get all must-sell products from active schemes
        List<Scheme_Product__c> mustSellProducts = [
            SELECT Id, Product_Ext__c
            FROM Scheme_Product__c
            WHERE Product_Classification__c = 'Must Sell'
              AND Product_Ext__c != null
              AND Scheme__r.Status__c = 'Active'
              AND Scheme__r.Start_Date__c <= :today
              AND Scheme__r.End_Date__c >= :today
        ];

        if (mustSellProducts.isEmpty()) {
            visit.Must_Sell_Products_Required__c = 0;
            visit.Must_Sell_Products_Ordered__c = 0;
            visit.Must_Sell_Compliance__c = null;
            return;
        }

        Set<Id> mustSellProductIds = new Set<Id>();
        for (Scheme_Product__c sp : mustSellProducts) {
            mustSellProductIds.add(sp.Product_Ext__c);
        }

        // Get products ordered during this visit
        Set<Id> orderedProductIds = new Set<Id>();
        for (Order_Line_Item__c oli : [
            SELECT Product_Ext__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__r.Visit__c = :visit.Id
              AND Sales_Order__r.Status__c != 'Cancelled'
              AND Product_Ext__c IN :mustSellProductIds
        ]) {
            orderedProductIds.add(oli.Product_Ext__c);
        }

        Integer required = mustSellProductIds.size();
        Integer ordered = orderedProductIds.size();

        visit.Must_Sell_Products_Required__c = required;
        visit.Must_Sell_Products_Ordered__c = ordered;
        visit.Must_Sell_Compliance__c = required > 0
            ? (Decimal.valueOf(ordered) / Decimal.valueOf(required) * 100).setScale(2, RoundingMode.HALF_UP)
            : null;
    }

    private static Map<String, Object> createActivity(String id, String label, String icon, Boolean enabled, Boolean completed) {
        Map<String, Object> activity = new Map<String, Object>();
        activity.put('id', id);
        activity.put('label', label);
        activity.put('icon', icon);
        activity.put('enabled', enabled);
        activity.put('completed', completed);
        activity.put('cardClass', completed ? 'activity-card activity-done' : 'activity-card');
        return activity;
    }

    private static Set<Id> getDirectReportUserIds(Id managerId) {
        Set<Id> userIds = new Set<Id>();
        for (Employee__c emp : [
            SELECT User__c FROM Employee__c
            WHERE Reporting_Manager__r.User__c = :managerId
              AND Is_Active__c = true AND User__c != null
        ]) {
            userIds.add(emp.User__c);
        }
        return userIds;
    }

    private static String getDayOfWeek(Date d) {
        // Locale-independent calculation — dt.format('EEEE') returns localized
        // day names (e.g. Hindi) which won't match English picklist values.
        Date refDate = Date.newInstance(2000, 1, 1); // January 1, 2000 was a Saturday
        Integer dayIndex = Math.mod(refDate.daysBetween(d), 7);
        if (dayIndex < 0) dayIndex += 7;
        List<String> dayNames = new List<String>{
            'Saturday', 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'
        };
        return dayNames[dayIndex];
    }

    private static String formatCurrency(Decimal value) {
        if (value == null || value == 0) return '₹0';
        return '₹' + String.valueOf(value.setScale(0, RoundingMode.HALF_UP).format());
    }
}