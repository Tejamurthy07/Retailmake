/**
 * @description Controller for the full Visit Execution module LWC.
 *              Provides a comprehensive visit workflow: day start/end integration,
 *              beat-based sequential visits, beat switching with reason,
 *              missed visits with reschedule, and ad-hoc visit support.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class VisitExecutionController {

    // ── Day Context ──────────────────────────────────────────────────────────

    /**
     * @description Gets the full visit execution context for the current day:
     *              attendance record, current beat, outlets in sequence, and visit statuses.
     * @return VisitDayContext wrapper with all day data.
     */
    @AuraEnabled
    public static VisitDayContext getDayContext() {
        try {
            Id currentUserId = UserInfo.getUserId();
            Date today = Date.today();
            VisitDayContext ctx = new VisitDayContext();

            // Get current day attendance
            Day_Attendance__c attendance = DFO_DayAttendance_Service.getCurrentAttendance(currentUserId);
            ctx.dayAttendance = attendance;
            ctx.isDayStarted = (attendance != null);

            if (attendance == null) {
                ctx.currentBeat = null;
                ctx.outlets = new List<BeatOutletInfo>();
                ctx.todaysVisits = new List<Visit__c>();
                ctx.availableBeats = new List<Beat__c>();
                return ctx;
            }

            // Get current beat from attendance or journey plan
            Id currentBeatId = attendance.Beat__c;
            if (currentBeatId != null) {
                List<Beat__c> beats = [
                    SELECT Id, Name, Beat_Code__c, Day_of_Week__c, Total_Outlets__c,
                           Territory__c, Territory__r.Name
                    FROM Beat__c WHERE Id = :currentBeatId LIMIT 1
                ];
                ctx.currentBeat = beats.isEmpty() ? null : beats[0];
            }

            // Check if beat was switched (defensive — field may not be queried in all paths)
            try {
                ctx.isBeatSwitched = attendance.Beat_Switched__c == true;
                ctx.originalBeatId = attendance.Original_Beat__c;
                ctx.beatSwitchReason = attendance.Beat_Switch_Reason__c;
            } catch (SObjectException e) {
                ctx.isBeatSwitched = false;
                ctx.originalBeatId = null;
                ctx.beatSwitchReason = null;
            }

            // Get beat outlets in visit sequence
            if (currentBeatId != null) {
                ctx.outlets = getBeatOutletsWithStatus(currentBeatId, currentUserId, today, attendance.Id);
            } else {
                ctx.outlets = new List<BeatOutletInfo>();
            }

            // Get today's actual visits
            ctx.todaysVisits = OVE_Visit_Service.getTodaysVisits(currentUserId);

            // Get available beats for switching
            ctx.availableBeats = getAvailableBeatsForUser(currentUserId);

            // Calculate summary stats
            ctx.totalPlanned = ctx.outlets.size();
            ctx.completedCount = 0;
            ctx.missedCount = 0;
            ctx.skippedCount = 0;
            ctx.pendingCount = 0;
            ctx.adHocCount = 0;

            for (Visit__c v : ctx.todaysVisits) {
                if (v.Visit_Status__c == 'Completed') ctx.completedCount++;
                else if (v.Visit_Status__c == 'Missed') ctx.missedCount++;
                else if (v.Visit_Status__c == 'Skipped') ctx.skippedCount++;
                if (v.Is_Ad_Hoc__c == true) ctx.adHocCount++;
            }
            ctx.pendingCount = ctx.totalPlanned - ctx.completedCount - ctx.missedCount - ctx.skippedCount;
            if (ctx.pendingCount < 0) ctx.pendingCount = 0;

            // Get visit config
            ctx.config = getVisitModuleConfig();

            return ctx;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Beat Switching ───────────────────────────────────────────────────────

    /**
     * @description Switches the current beat for today's visits. Requires a reason.
     *              Updates the Day_Attendance__c record and returns the new beat outlets.
     * @param newBeatId The new Beat__c Id to switch to.
     * @param switchReason The reason for switching (picklist value).
     * @param switchNotes Additional notes for the switch.
     * @return Updated VisitDayContext.
     */
    @AuraEnabled
    public static VisitDayContext switchBeat(Id newBeatId, String switchReason, String switchNotes) {
        try {
            if (newBeatId == null) {
                throw new AuraHandledException('Please select a beat to switch to.');
            }
            if (String.isBlank(switchReason)) {
                throw new AuraHandledException('A reason is required for switching beats.');
            }

            Id currentUserId = UserInfo.getUserId();
            Day_Attendance__c attendance = DFO_DayAttendance_Service.getCurrentAttendance(currentUserId);
            if (attendance == null) {
                throw new AuraHandledException('Please start your day before switching beats.');
            }

            // Store original beat if this is the first switch
            Id originalBeatId = attendance.Original_Beat__c != null
                ? attendance.Original_Beat__c
                : attendance.Beat__c;

            String fullReason = switchReason;
            if (String.isNotBlank(switchNotes)) {
                fullReason += ' - ' + switchNotes;
            }

            // Update attendance record
            attendance.Original_Beat__c = originalBeatId;
            attendance.Beat__c = newBeatId;
            attendance.Beat_Switched__c = true;
            attendance.Beat_Switch_Reason__c = fullReason;

            TriggerHandler.bypass('DFO_DayAttendance_TriggerHandler');
            update attendance;
            TriggerHandler.clearBypass('DFO_DayAttendance_TriggerHandler');

            // Return updated context
            return getDayContext();
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to switch beat: ' + e.getMessage());
        }
    }

    // ── Sequential Visit Check-In ────────────────────────────────────────────

    /**
     * @description Creates a visit check-in for the next outlet in the beat sequence.
     *              Enforces that visits must be done in sequence order.
     * @param visitJson JSON string with CheckInRequest fields.
     * @return The created Visit__c record.
     */
    @AuraEnabled
    public static Visit__c checkInFromSequence(String visitJson) {
        try {
            OVE_Visit_Service.CheckInRequest request =
                (OVE_Visit_Service.CheckInRequest)
                JSON.deserialize(visitJson, OVE_Visit_Service.CheckInRequest.class);

            // Validate sequence enforcement
            Id currentUserId = UserInfo.getUserId();
            Day_Attendance__c attendance = DFO_DayAttendance_Service.getCurrentAttendance(currentUserId);
            if (attendance == null) {
                throw new AuraHandledException('Please start your day before checking in.');
            }

            request.dayAttendanceId = attendance.Id;

            if (attendance.Beat__c != null && request.beatId == null) {
                request.beatId = attendance.Beat__c;
            }

            // For planned visits, verify sequence order
            if (request.isPlanned == true && request.beatId != null) {
                validateVisitSequence(request.accountId, request.beatId, currentUserId, Date.today());
            }

            return OVE_Visit_Service.checkIn(request);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Completes a visit check-out.
     * @param visitJson JSON string with CheckOutRequest fields.
     * @return The updated Visit__c record.
     */
    @AuraEnabled
    public static Visit__c checkOutVisit(String visitJson) {
        try {
            OVE_Visit_Service.CheckOutRequest request =
                (OVE_Visit_Service.CheckOutRequest)
                JSON.deserialize(visitJson, OVE_Visit_Service.CheckOutRequest.class);
            return OVE_Visit_Service.checkOut(request);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Missed Visit ─────────────────────────────────────────────────────────

    /**
     * @description Marks a planned visit as Missed with a reason and optional reschedule date.
     * @param accountId The outlet Account Id.
     * @param beatId The Beat__c Id.
     * @param missedReason The reason for missing (picklist value).
     * @param missedNotes Additional notes.
     * @param rescheduleDate Optional date to reschedule the visit.
     * @return The created/updated Visit__c record.
     */
    @AuraEnabled
    public static Visit__c markVisitMissed(
        Id accountId, Id beatId, String missedReason,
        String missedNotes, Date rescheduleDate
    ) {
        try {
            if (accountId == null) {
                throw new AuraHandledException('Account is required.');
            }
            if (String.isBlank(missedReason)) {
                throw new AuraHandledException('A reason is required for marking a visit as missed.');
            }

            Id currentUserId = UserInfo.getUserId();
            Date today = Date.today();

            Day_Attendance__c attendance = DFO_DayAttendance_Service.getCurrentAttendance(currentUserId);
            if (attendance == null) {
                throw new AuraHandledException('Please start your day before marking visits.');
            }

            // Check if there's already a visit for this account today
            List<Visit__c> existingVisits = [
                SELECT Id, Visit_Status__c FROM Visit__c
                WHERE Account__c = :accountId
                  AND Salesperson__c = :currentUserId
                  AND Visit_Date__c = :today
                  AND Visit_Status__c NOT IN ('Missed', 'Skipped')
                LIMIT 1
            ];

            if (!existingVisits.isEmpty()) {
                throw new AuraHandledException('An active visit already exists for this outlet today. Please complete or skip it first.');
            }

            Savepoint sp = Database.setSavepoint();
            try {
                // Calculate visit sequence
                Integer todaysVisitCount = [
                    SELECT COUNT() FROM Visit__c
                    WHERE Day_Attendance__c = :attendance.Id
                ];

                // Create the missed visit record
                Visit__c missedVisit = new Visit__c();
                missedVisit.Account__c = accountId;
                missedVisit.Outlet__c = accountId;
                missedVisit.Salesperson__c = currentUserId;
                missedVisit.User__c = currentUserId;
                missedVisit.Beat__c = beatId;
                missedVisit.Day_Attendance__c = attendance.Id;
                missedVisit.Visit_Date__c = today;
                missedVisit.Visit_Status__c = 'Missed';
                missedVisit.Missed_Reason__c = missedReason;
                missedVisit.Missed_Notes__c = missedNotes;
                missedVisit.Is_Planned__c = true;
                missedVisit.Is_Productive__c = false;
                missedVisit.Visit_Sequence__c = todaysVisitCount + 1;
                missedVisit.Order_Value__c = 0;
                missedVisit.Collection_Amount__c = 0;
                missedVisit.Total_Orders_Count__c = 0;

                if (rescheduleDate != null) {
                    if (rescheduleDate <= today) {
                        throw new AuraHandledException('Reschedule date must be a future date.');
                    }
                    missedVisit.Reschedule_Date__c = rescheduleDate;
                }

                insert missedVisit;

                // If reschedule is requested, create a planned visit for the future date
                if (rescheduleDate != null) {
                    Visit__c rescheduledVisit = new Visit__c();
                    rescheduledVisit.Account__c = accountId;
                    rescheduledVisit.Outlet__c = accountId;
                    rescheduledVisit.Salesperson__c = currentUserId;
                    rescheduledVisit.User__c = currentUserId;
                    rescheduledVisit.Beat__c = beatId;
                    rescheduledVisit.Visit_Date__c = rescheduleDate;
                    rescheduledVisit.Visit_Status__c = 'Planned';
                    rescheduledVisit.Is_Planned__c = true;
                    rescheduledVisit.Is_Rescheduled__c = true;
                    rescheduledVisit.Original_Visit__c = missedVisit.Id;
                    rescheduledVisit.Order_Value__c = 0;
                    rescheduledVisit.Collection_Amount__c = 0;
                    rescheduledVisit.Total_Orders_Count__c = 0;
                    insert rescheduledVisit;
                }

                // Recalculate day summary
                DFO_DayAttendance_Service.recalculateSummary(attendance.Id);

                return missedVisit;
            } catch (AuraHandledException e) {
                Database.rollback(sp);
                throw e;
            } catch (Exception e) {
                Database.rollback(sp);
                throw new AuraHandledException('Failed to mark visit as missed: ' + e.getMessage());
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Reschedule Missed Visit ──────────────────────────────────────────────

    /**
     * @description Reschedules an already-missed visit to a new date.
     * @param visitId The missed Visit__c Id.
     * @param rescheduleDate The new date for the visit.
     * @return The updated missed Visit__c record.
     */
    @AuraEnabled
    public static Visit__c rescheduleVisit(Id visitId, Date rescheduleDate) {
        try {
            if (visitId == null || rescheduleDate == null) {
                throw new AuraHandledException('Visit and reschedule date are required.');
            }
            if (rescheduleDate <= Date.today()) {
                throw new AuraHandledException('Reschedule date must be a future date.');
            }

            List<Visit__c> visits = [
                SELECT Id, Account__c, Outlet__c, Salesperson__c, User__c,
                       Beat__c, Visit_Status__c, Reschedule_Date__c
                FROM Visit__c WHERE Id = :visitId LIMIT 1
            ];

            if (visits.isEmpty()) {
                throw new AuraHandledException('Visit record not found.');
            }

            Visit__c missedVisit = visits[0];
            if (missedVisit.Visit_Status__c != 'Missed') {
                throw new AuraHandledException('Only missed visits can be rescheduled.');
            }

            Savepoint sp = Database.setSavepoint();
            try {
                // Update the missed visit with the reschedule date
                missedVisit.Reschedule_Date__c = rescheduleDate;
                update missedVisit;

                // Check if a rescheduled visit already exists
                List<Visit__c> existingReschedule = [
                    SELECT Id FROM Visit__c
                    WHERE Original_Visit__c = :visitId
                      AND Is_Rescheduled__c = true
                    LIMIT 1
                ];

                if (!existingReschedule.isEmpty()) {
                    // Update existing reschedule
                    existingReschedule[0].put('Visit_Date__c', rescheduleDate);
                    update existingReschedule;
                } else {
                    // Create new rescheduled visit
                    Visit__c rescheduledVisit = new Visit__c();
                    rescheduledVisit.Account__c = missedVisit.Account__c;
                    rescheduledVisit.Outlet__c = missedVisit.Outlet__c;
                    rescheduledVisit.Salesperson__c = missedVisit.Salesperson__c;
                    rescheduledVisit.User__c = missedVisit.User__c;
                    rescheduledVisit.Beat__c = missedVisit.Beat__c;
                    rescheduledVisit.Visit_Date__c = rescheduleDate;
                    rescheduledVisit.Visit_Status__c = 'Planned';
                    rescheduledVisit.Is_Planned__c = true;
                    rescheduledVisit.Is_Rescheduled__c = true;
                    rescheduledVisit.Original_Visit__c = missedVisit.Id;
                    rescheduledVisit.Order_Value__c = 0;
                    rescheduledVisit.Collection_Amount__c = 0;
                    rescheduledVisit.Total_Orders_Count__c = 0;
                    insert rescheduledVisit;
                }

                return missedVisit;
            } catch (AuraHandledException e) {
                Database.rollback(sp);
                throw e;
            } catch (Exception e) {
                Database.rollback(sp);
                throw new AuraHandledException('Failed to reschedule: ' + e.getMessage());
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Ad-Hoc Visit ─────────────────────────────────────────────────────────

    /**
     * @description Creates an ad-hoc visit for an outlet not in the current beat.
     * @param accountId The outlet Account Id.
     * @param adHocReason The reason for the ad-hoc visit.
     * @return The created Visit__c record.
     */
    @AuraEnabled
    public static Visit__c createAdHocVisit(Id accountId, String adHocReason) {
        try {
            if (accountId == null) {
                throw new AuraHandledException('Please select an outlet.');
            }

            Id currentUserId = UserInfo.getUserId();
            Day_Attendance__c attendance = DFO_DayAttendance_Service.getCurrentAttendance(currentUserId);
            if (attendance == null) {
                throw new AuraHandledException('Please start your day before creating visits.');
            }

            OVE_Visit_Service.CheckInRequest request = new OVE_Visit_Service.CheckInRequest();
            request.accountId = accountId;
            request.dayAttendanceId = attendance.Id;
            request.beatId = attendance.Beat__c;
            request.isPlanned = false;
            request.adHocReason = String.isNotBlank(adHocReason) ? adHocReason : 'Ad-hoc visit';
            request.latitude = 0;
            request.longitude = 0;
            request.accuracy = 0;

            return OVE_Visit_Service.checkIn(request);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Search Outlets ───────────────────────────────────────────────────────

    /**
     * @description Searches outlets for ad-hoc visit creation.
     * @param searchTerm The search string.
     * @return List of matching Account records.
     */
    @AuraEnabled
    public static List<Account> searchOutlets(String searchTerm) {
        try {
            if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
                return new List<Account>();
            }
            String searchPattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            return [
                SELECT Id, Name, BillingStreet, BillingCity, Type
                FROM Account
                WHERE Name LIKE :searchPattern
                ORDER BY Name ASC
                LIMIT 20
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Skip Visit ───────────────────────────────────────────────────────────

    /**
     * @description Skips a planned visit with a reason.
     * @param visitId The Visit__c Id (or null for planned-only outlets).
     * @param accountId The Account Id (for outlets without a visit record yet).
     * @param beatId The Beat Id.
     * @param skipReason The reason for skipping.
     * @return The updated/created Visit__c record.
     */
    @AuraEnabled
    public static Visit__c skipPlannedVisit(Id visitId, Id accountId, Id beatId, String skipReason) {
        try {
            if (String.isBlank(skipReason)) {
                throw new AuraHandledException('A reason is required for skipping a visit.');
            }

            // If we have a visit record, use the existing skip
            if (visitId != null) {
                return OVE_Visit_Service.skipVisit(visitId, skipReason);
            }

            // Otherwise create a skipped visit record for the planned outlet
            if (accountId == null) {
                throw new AuraHandledException('Account is required.');
            }

            Id currentUserId = UserInfo.getUserId();
            Day_Attendance__c attendance = DFO_DayAttendance_Service.getCurrentAttendance(currentUserId);
            if (attendance == null) {
                throw new AuraHandledException('Please start your day first.');
            }

            Integer todaysVisitCount = [
                SELECT COUNT() FROM Visit__c
                WHERE Day_Attendance__c = :attendance.Id
            ];

            Visit__c skippedVisit = new Visit__c();
            skippedVisit.Account__c = accountId;
            skippedVisit.Outlet__c = accountId;
            skippedVisit.Salesperson__c = currentUserId;
            skippedVisit.User__c = currentUserId;
            skippedVisit.Beat__c = beatId;
            skippedVisit.Day_Attendance__c = attendance.Id;
            skippedVisit.Visit_Date__c = Date.today();
            skippedVisit.Visit_Status__c = 'Skipped';
            skippedVisit.Deviation_Reason__c = skipReason;
            skippedVisit.Is_Planned__c = true;
            skippedVisit.Is_Productive__c = false;
            skippedVisit.Non_Productive_Reason__c = 'Visit Skipped';
            skippedVisit.Visit_Sequence__c = todaysVisitCount + 1;
            skippedVisit.Order_Value__c = 0;
            skippedVisit.Collection_Amount__c = 0;
            skippedVisit.Total_Orders_Count__c = 0;
            insert skippedVisit;

            return skippedVisit;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Private Helpers ──────────────────────────────────────────────────────

    /**
     * @description Gets beat outlets with their visit status for today.
     */
    private static List<BeatOutletInfo> getBeatOutletsWithStatus(
        Id beatId, Id userId, Date visitDate, Id attendanceId
    ) {
        List<Beat_Outlet__c> beatOutlets = [
            SELECT Id, Beat__c, Beat__r.Name, Account__c,
                   Account__r.Name, Account__r.Type, Account__r.BillingCity,
                   Account__r.BillingStreet, Account__r.Outlet_Latitude__c,
                   Account__r.Outlet_Longitude__c, Visit_Sequence__c
            FROM Beat_Outlet__c
            WHERE Beat__c = :beatId AND Is_Active__c = true
            ORDER BY Visit_Sequence__c ASC
        ];

        // Get existing visits for today
        Set<Id> accountIds = new Set<Id>();
        for (Beat_Outlet__c bo : beatOutlets) {
            accountIds.add(bo.Account__c);
        }

        Map<Id, Visit__c> visitsByAccount = new Map<Id, Visit__c>();
        for (Visit__c v : [
            SELECT Id, Account__c, Visit_Status__c, Check_In_Time__c, Check_Out_Time__c,
                   Duration_Minutes__c, Is_Productive__c, Order_Value__c, Collection_Amount__c,
                   Missed_Reason__c, Missed_Notes__c, Reschedule_Date__c, Deviation_Reason__c,
                   Visit_Sequence__c
            FROM Visit__c
            WHERE Salesperson__c = :userId
              AND Visit_Date__c = :visitDate
              AND Account__c IN :accountIds
            ORDER BY CreatedDate DESC
        ]) {
            if (!visitsByAccount.containsKey(v.Account__c)) {
                visitsByAccount.put(v.Account__c, v);
            }
        }

        List<BeatOutletInfo> result = new List<BeatOutletInfo>();
        for (Beat_Outlet__c bo : beatOutlets) {
            BeatOutletInfo info = new BeatOutletInfo();
            info.beatOutletId = bo.Id;
            info.accountId = bo.Account__c;
            info.accountName = bo.Account__r.Name;
            info.accountType = bo.Account__r.Type;
            info.city = bo.Account__r.BillingCity;
            info.address = bo.Account__r.BillingStreet;
            info.beatId = bo.Beat__c;
            info.beatName = bo.Beat__r.Name;
            info.sequence = Integer.valueOf(bo.Visit_Sequence__c != null ? bo.Visit_Sequence__c : 0);
            info.outletLatitude = bo.Account__r.Outlet_Latitude__c;
            info.outletLongitude = bo.Account__r.Outlet_Longitude__c;

            Visit__c existingVisit = visitsByAccount.get(bo.Account__c);
            if (existingVisit != null) {
                info.visitId = existingVisit.Id;
                info.visitStatus = existingVisit.Visit_Status__c;
                info.checkInTime = existingVisit.Check_In_Time__c;
                info.checkOutTime = existingVisit.Check_Out_Time__c;
                info.durationMinutes = existingVisit.Duration_Minutes__c;
                info.isProductive = existingVisit.Is_Productive__c;
                info.orderValue = existingVisit.Order_Value__c;
                info.collectionAmount = existingVisit.Collection_Amount__c;
                info.missedReason = existingVisit.Missed_Reason__c;
                info.rescheduleDate = existingVisit.Reschedule_Date__c;
            } else {
                info.visitStatus = 'Planned';
            }

            result.add(info);
        }

        return result;
    }

    /**
     * @description Gets available beats for the current user to switch to.
     */
    private static List<Beat__c> getAvailableBeatsForUser(Id userId) {
        // Get territory IDs from user's journey plans
        Set<Id> territoryIds = new Set<Id>();
        for (Journey_Plan_Day__c jpd : [
            SELECT Beat__r.Territory__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__r.Salesperson__c = :userId
              AND Beat__r.Territory__c != null
        ]) {
            territoryIds.add(jpd.Beat__r.Territory__c);
        }

        if (territoryIds.isEmpty()) {
            return [
                SELECT Id, Name, Beat_Code__c, Day_of_Week__c,
                       Total_Outlets__c, Territory__r.Name
                FROM Beat__c
                WHERE Is_Active__c = true
                ORDER BY Name
                LIMIT 50
            ];
        }

        return [
            SELECT Id, Name, Beat_Code__c, Day_of_Week__c,
                   Total_Outlets__c, Territory__r.Name
            FROM Beat__c
            WHERE Territory__c IN :territoryIds AND Is_Active__c = true
            ORDER BY Name
        ];
    }

    /**
     * @description Validates that the visit is being done in sequence order from the beat.
     *              Checks that all prior outlets in the sequence have been visited/missed/skipped.
     */
    private static void validateVisitSequence(Id accountId, Id beatId, Id userId, Date visitDate) {
        // Get the sequence for the target outlet
        List<Beat_Outlet__c> targetOutlets = [
            SELECT Visit_Sequence__c FROM Beat_Outlet__c
            WHERE Beat__c = :beatId AND Account__c = :accountId AND Is_Active__c = true
            LIMIT 1
        ];

        if (targetOutlets.isEmpty()) {
            return; // Not a beat outlet, skip validation
        }

        Decimal targetSequence = targetOutlets[0].Visit_Sequence__c;
        if (targetSequence == null || targetSequence <= 1) {
            return; // First in sequence, always allowed
        }

        // Get all outlets before this one in sequence
        List<Beat_Outlet__c> priorOutlets = [
            SELECT Account__c, Visit_Sequence__c FROM Beat_Outlet__c
            WHERE Beat__c = :beatId
              AND Is_Active__c = true
              AND Visit_Sequence__c < :targetSequence
            ORDER BY Visit_Sequence__c ASC
        ];

        if (priorOutlets.isEmpty()) {
            return;
        }

        // Get which ones have been handled today
        Set<Id> priorAccountIds = new Set<Id>();
        for (Beat_Outlet__c bo : priorOutlets) {
            priorAccountIds.add(bo.Account__c);
        }

        Set<Id> handledAccountIds = new Set<Id>();
        for (Visit__c v : [
            SELECT Account__c FROM Visit__c
            WHERE Salesperson__c = :userId
              AND Visit_Date__c = :visitDate
              AND Account__c IN :priorAccountIds
              AND Visit_Status__c IN ('Checked In', 'In Progress', 'Completed', 'Skipped', 'Missed')
        ]) {
            handledAccountIds.add(v.Account__c);
        }

        // Check for unhandled prior outlets
        List<String> unhandledOutlets = new List<String>();
        for (Beat_Outlet__c bo : priorOutlets) {
            if (!handledAccountIds.contains(bo.Account__c)) {
                unhandledOutlets.add('#' + String.valueOf(bo.Visit_Sequence__c != null ? bo.Visit_Sequence__c.intValue() : 0));
            }
        }

        if (!unhandledOutlets.isEmpty()) {
            throw new AuraHandledException(
                'Please complete or mark outlets in sequence first. Pending outlets: ' +
                String.join(unhandledOutlets, ', ') +
                '. You can mark them as Missed or Skipped to proceed.'
            );
        }
    }

    /**
     * @description Gets visit module configuration.
     */
    private static Map<String, Object> getVisitModuleConfig() {
        Map<String, Object> config = new Map<String, Object>();
        config.put('requirePhotoCheckIn', DFO_DayAttendance_Service.getConfigBoolean('REQUIRE_PHOTO_CHECKIN', false));
        config.put('allowGeofenceOverride', DFO_DayAttendance_Service.getConfigBoolean('ALLOW_GEOFENCE_OVERRIDE', true));
        config.put('minVisitDurationSec', DFO_DayAttendance_Service.getConfigInteger('MIN_VISIT_DURATION_SEC', 60));
        config.put('maxVisitsPerDay', DFO_DayAttendance_Service.getConfigInteger('MAX_VISITS_PER_DAY', 30));
        config.put('geofenceEnabled', BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_GEOFENCE));
        config.put('adHocVisitsEnabled', BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_AD_HOC_VISITS));
        config.put('sequenceEnforced', DFO_DayAttendance_Service.getConfigBoolean('ENFORCE_VISIT_SEQUENCE', true));
        return config;
    }

    // ── DTO Classes ──────────────────────────────────────────────────────────

    public class VisitDayContext {
        @AuraEnabled public Day_Attendance__c dayAttendance;
        @AuraEnabled public Boolean isDayStarted;
        @AuraEnabled public Beat__c currentBeat;
        @AuraEnabled public Boolean isBeatSwitched;
        @AuraEnabled public Id originalBeatId;
        @AuraEnabled public String beatSwitchReason;
        @AuraEnabled public List<BeatOutletInfo> outlets;
        @AuraEnabled public List<Visit__c> todaysVisits;
        @AuraEnabled public List<Beat__c> availableBeats;
        @AuraEnabled public Integer totalPlanned;
        @AuraEnabled public Integer completedCount;
        @AuraEnabled public Integer missedCount;
        @AuraEnabled public Integer skippedCount;
        @AuraEnabled public Integer pendingCount;
        @AuraEnabled public Integer adHocCount;
        @AuraEnabled public Map<String, Object> config;
    }

    public class BeatOutletInfo {
        @AuraEnabled public Id beatOutletId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountType;
        @AuraEnabled public String city;
        @AuraEnabled public String address;
        @AuraEnabled public Id beatId;
        @AuraEnabled public String beatName;
        @AuraEnabled public Integer sequence;
        @AuraEnabled public Decimal outletLatitude;
        @AuraEnabled public Decimal outletLongitude;
        @AuraEnabled public Id visitId;
        @AuraEnabled public String visitStatus;
        @AuraEnabled public DateTime checkInTime;
        @AuraEnabled public DateTime checkOutTime;
        @AuraEnabled public Decimal durationMinutes;
        @AuraEnabled public Boolean isProductive;
        @AuraEnabled public Decimal orderValue;
        @AuraEnabled public Decimal collectionAmount;
        @AuraEnabled public String missedReason;
        @AuraEnabled public Date rescheduleDate;
    }
}