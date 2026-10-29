/**
 * @description Service class for Journey Plan (Beat Plan) management. Generates
 *              default journey plans based on beat assignments and calculates
 *              plan compliance metrics. Supports configurable exclusion of
 *              holidays, leaves, and employee week-off days.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class BPM_JourneyPlan_Service {

    /** Days of the week mapped to their index (1 = Monday). */
    private static final Map<String, Integer> DAY_INDEX_MAP = new Map<String, Integer>{
        'Monday'    => 1,
        'Tuesday'   => 2,
        'Wednesday' => 3,
        'Thursday'  => 4,
        'Friday'    => 5,
        'Saturday'  => 6,
        'Sunday'    => 7
    };

    /**
     * @description Generates a default journey plan for a user in a given territory
     *              for a specified month and year.
     */
    public static Id generateDefaultPlan(
        Id userId,
        Id territoryId,
        String month,
        String year
    ) {
        return generateDefaultPlan(userId, territoryId, month, year, null, null);
    }

    /**
     * @description Overloaded version that accepts an optional date range.
     */
    public static Id generateDefaultPlan(
        Id userId,
        Id territoryId,
        String month,
        String year,
        Date rangeStartDate,
        Date rangeEndDate
    ) {
        if (userId == null || territoryId == null ||
            String.isBlank(month) || String.isBlank(year)) {
            throw new BPM_JourneyPlanServiceException(
                'All parameters (userId, territoryId, month, year) are required.'
            );
        }

        Integer monthInt = parseMonth(month);
        Integer yearInt = Integer.valueOf(year);
        String monthName = normalizeMonthName(monthInt);

        // Validate no existing plan for this user/territory/month/year
        List<Journey_Plan__c> existingPlans = [
            SELECT Id
            FROM Journey_Plan__c
            WHERE Salesperson__c = :userId
              AND Territory__c = :territoryId
              AND Month__c = :monthName
              AND Year__c = :year
              AND Status__c != 'Cancelled'
            LIMIT 1
        ];

        if (!existingPlans.isEmpty()) {
            throw new BPM_JourneyPlanServiceException(
                'A journey plan already exists for this user, territory, month, and year.'
            );
        }

        // Fetch user and territory names for the plan name
        String userName = [SELECT Name FROM User WHERE Id = :userId LIMIT 1].Name;
        String territoryName = [SELECT Name FROM Territory_Master__c WHERE Id = :territoryId LIMIT 1].Name;
        String planName = monthName + ' ' + year + ' - ' + userName + ' - ' + territoryName;

        // Fetch ALL beat assignments for the user (across all territories) so
        // the calendar shows every assigned beat. Territory on the plan header
        // is retained for display/reporting but does not filter which beats
        // appear on the calendar.
        List<Beat__c> beats = [
            SELECT Id, Name, Day_of_Week__c, Frequency__c,
                   Territory__c, Sequence__c,
                   (SELECT Id, Account__c, Account__r.Name, Visit_Sequence__c
                    FROM Beat_Outlets__r
                    WHERE Is_Active__c = true
                    ORDER BY Visit_Sequence__c ASC)
            FROM Beat__c
            WHERE Assigned_User__c = :userId
              AND Is_Active__c = true
            ORDER BY Sequence__c NULLS LAST, Name
        ];

        if (beats.isEmpty()) {
            throw new BPM_JourneyPlanServiceException(
                'No active beat assignments found for this user.'
            );
        }

        // Create the journey plan header (default: exclude all)
        Journey_Plan__c plan = new Journey_Plan__c(
            Name               = planName,
            Salesperson__c     = userId,
            Territory__c       = territoryId,
            Month__c           = monthName,
            Year__c            = year,
            Status__c          = 'Draft',
            Plan_Date__c       = Date.today(),
            Exclude_Holidays__c = true,
            Exclude_Leaves__c   = true,
            Exclude_Week_Offs__c = true
        );
        if (rangeStartDate != null) {
            plan.Effective_From__c = rangeStartDate;
        }
        if (rangeEndDate != null) {
            plan.Effective_To__c = rangeEndDate;
        }
        insert plan;

        // Determine date range for exclusion lookups
        Date planStartDate = rangeStartDate != null ? rangeStartDate : Date.newInstance(yearInt, monthInt, 1);
        Date planEndDate = rangeEndDate != null ? rangeEndDate : Date.newInstance(yearInt, monthInt, Date.daysInMonth(yearInt, monthInt));

        // Build exclusion sets
        Set<Date> holidayDates = getHolidayDates(planStartDate, planEndDate, territoryId, userId);
        Set<Date> leaveDates = getLeaveDates(userId, planStartDate, planEndDate);
        Set<String> weekOffDays = getEmployeeWeekOffDays(userId);

        // Generate journey plan days
        List<Journey_Plan_Day__c> planDays = new List<Journey_Plan_Day__c>();
        Integer daysInMonth = Date.daysInMonth(yearInt, monthInt);

        // Build a map of day-of-week -> beats
        Map<String, List<Beat__c>> beatsByDay = buildBeatsByDayMap(beats);

        // Iterate through each day of the month
        Integer sequenceOrder = 0;
        for (Integer dayNum = 1; dayNum <= daysInMonth; dayNum++) {
            Date currentDate = Date.newInstance(yearInt, monthInt, dayNum);

            // Skip dates outside the specified range
            if (rangeStartDate != null && currentDate < rangeStartDate) {
                continue;
            }
            if (rangeEndDate != null && currentDate > rangeEndDate) {
                continue;
            }

            String dayOfWeek = getDayOfWeek(currentDate);

            // Skip employee week-off days
            if (weekOffDays.contains(dayOfWeek)) {
                continue;
            }

            // Skip holidays
            if (holidayDates.contains(currentDate)) {
                continue;
            }

            // Skip leave dates
            if (leaveDates.contains(currentDate)) {
                continue;
            }

            List<Beat__c> daysBeats = beatsByDay.get(dayOfWeek);
            if (daysBeats == null || daysBeats.isEmpty()) {
                continue;
            }

            String weekNumber = getWeekNumber(dayNum);

            for (Beat__c beat : daysBeats) {
                if (!shouldIncludeForFrequency(beat.Frequency__c, dayNum, daysInMonth)) {
                    continue;
                }

                sequenceOrder++;
                Journey_Plan_Day__c planDay = new Journey_Plan_Day__c(
                    Journey_Plan__c     = plan.Id,
                    Plan_Date__c        = currentDate,
                    Day_Of_Week__c      = dayOfWeek,
                    Beat__c             = beat.Id,
                    Beat_Name__c        = beat.Name,
                    Planned_Outlets__c  = beat.Beat_Outlets__r != null
                        ? beat.Beat_Outlets__r.size() : 0,
                    Status__c           = 'Planned',
                    Sequence__c         = beat.Sequence__c,
                    Week_Number__c      = weekNumber,
                    Sequence_Order__c   = sequenceOrder
                );
                planDays.add(planDay);
            }
        }

        if (!planDays.isEmpty()) {
            insert planDays;
        }

        // Update plan with total planned days
        plan.Total_Planned_Days__c = planDays.size();
        update plan;

        return plan.Id;
    }

    /**
     * @description Generates a single journey plan spanning a date range with
     *              configurable exclusion of holidays, leaves, and week-off days.
     *
     * @param userId           The user (sales rep) for whom to generate the plan.
     * @param territoryId      The territory under which beats are assigned.
     * @param fromDate         Start date of the plan range.
     * @param toDate           End date of the plan range.
     * @param excludeHolidays  When true, holiday dates are excluded from plan days.
     * @param excludeLeaves    When true, approved/pending leave dates are excluded.
     * @param excludeWeekOffs  When true, employee's configured week-off days are excluded.
     * @return The Id of the created Journey_Plan__c record.
     */
    public static Id generatePlanForDateRange(
        Id userId,
        Id territoryId,
        Date fromDate,
        Date toDate,
        Boolean excludeHolidays,
        Boolean excludeLeaves,
        Boolean excludeWeekOffs
    ) {
        if (userId == null || territoryId == null || fromDate == null || toDate == null) {
            throw new BPM_JourneyPlanServiceException(
                'All parameters (userId, territoryId, fromDate, toDate) are required.'
            );
        }
        if (fromDate > toDate) {
            throw new BPM_JourneyPlanServiceException('From Date must be before or equal to To Date.');
        }

        // Default exclusion flags
        if (excludeHolidays == null) excludeHolidays = true;
        if (excludeLeaves == null) excludeLeaves = true;
        if (excludeWeekOffs == null) excludeWeekOffs = true;

        // Validate no overlapping plan exists. We over-fetch candidate plans
        // that *could* overlap and then filter in Apex with a precise
        // date-range check. The old query's `OR (Month__c = :startMonth AND
        // Year__c = :startYear)` fallback was designed to catch plans that
        // don't have effective dates populated, but it caused false positives
        // when plans created via different paths had Month__c set to a month
        // that happens to match the requested fromDate's month while their
        // Effective_* dates clearly didn't overlap. The Apex-side filter below
        // is strict about true date-range overlap and only falls back to the
        // month match when the candidate's Effective_* fields are actually
        // null.
        String startMonthCheck = normalizeMonthName(fromDate.month());
        String startYearCheck = String.valueOf(fromDate.year());

        List<Journey_Plan__c> candidates = [
            SELECT Id, Name, Effective_From__c, Effective_To__c, Month__c, Year__c
            FROM Journey_Plan__c
            WHERE Salesperson__c = :userId
              AND Territory__c = :territoryId
              AND Status__c != 'Cancelled'
              AND (
                  (Effective_From__c != null AND Effective_To__c != null
                   AND Effective_From__c <= :toDate AND Effective_To__c >= :fromDate)
                  OR (Effective_From__c = null
                      AND Month__c = :startMonthCheck AND Year__c = :startYearCheck)
              )
        ];

        Journey_Plan__c existing = null;
        for (Journey_Plan__c cand : candidates) {
            // Strict date-range overlap: [A,B] overlaps [C,D] iff A <= D and C <= B
            if (cand.Effective_From__c != null && cand.Effective_To__c != null) {
                if (cand.Effective_From__c <= toDate && fromDate <= cand.Effective_To__c) {
                    existing = cand;
                    break;
                }
            } else if (cand.Month__c == startMonthCheck && cand.Year__c == startYearCheck) {
                existing = cand;
                break;
            }
        }

        if (existing != null) {
            String detail = existing.Effective_From__c != null && existing.Effective_To__c != null
                ? ' (' + String.valueOf(existing.Effective_From__c)
                  + ' to ' + String.valueOf(existing.Effective_To__c) + ')'
                : ' (' + existing.Month__c + ' ' + existing.Year__c + ')';
            throw new BPM_JourneyPlanServiceException(
                'An overlapping journey plan already exists: ' + existing.Name + detail
                + '. Requested range: ' + String.valueOf(fromDate) + ' to ' + String.valueOf(toDate)
                + '. Use Regenerate to update the existing plan.'
            );
        }

        // Fetch user and territory names
        String userName = [SELECT Name FROM User WHERE Id = :userId LIMIT 1].Name;
        String territoryName = [SELECT Name FROM Territory_Master__c WHERE Id = :territoryId LIMIT 1].Name;

        String startMonthName = normalizeMonthName(fromDate.month());
        String startYearStr = String.valueOf(fromDate.year());
        String planName;
        if (fromDate.month() == toDate.month() && fromDate.year() == toDate.year()) {
            planName = startMonthName + ' ' + startYearStr + ' - ' + userName + ' - ' + territoryName;
        } else {
            String endMonthName = normalizeMonthName(toDate.month());
            planName = startMonthName + ' ' + startYearStr + ' to '
                + endMonthName + ' ' + String.valueOf(toDate.year())
                + ' - ' + userName + ' - ' + territoryName;
        }

        // Fetch ALL beats assigned to this user (across all territories)
        List<Beat__c> beats = [
            SELECT Id, Name, Day_of_Week__c, Frequency__c,
                   Territory__c, Sequence__c,
                   (SELECT Id, Account__c, Account__r.Name, Visit_Sequence__c
                    FROM Beat_Outlets__r
                    WHERE Is_Active__c = true
                    ORDER BY Visit_Sequence__c ASC)
            FROM Beat__c
            WHERE Assigned_User__c = :userId
              AND Is_Active__c = true
            ORDER BY Sequence__c NULLS LAST, Name
        ];

        if (beats.isEmpty()) {
            throw new BPM_JourneyPlanServiceException(
                'No active beat assignments found for this user.'
            );
        }

        // Create single journey plan header with exclusion preferences
        Journey_Plan__c plan = new Journey_Plan__c(
            Name               = planName,
            Salesperson__c     = userId,
            Territory__c       = territoryId,
            Month__c           = startMonthName,
            Year__c            = startYearStr,
            Status__c          = 'Draft',
            Plan_Date__c       = Date.today(),
            Effective_From__c  = fromDate,
            Effective_To__c    = toDate,
            Exclude_Holidays__c  = excludeHolidays,
            Exclude_Leaves__c    = excludeLeaves,
            Exclude_Week_Offs__c = excludeWeekOffs
        );
        insert plan;

        // Build exclusion sets based on user preferences
        Set<Date> holidayDates = excludeHolidays ? getHolidayDates(fromDate, toDate, territoryId, userId) : new Set<Date>();
        Set<Date> leaveDates = excludeLeaves ? getLeaveDates(userId, fromDate, toDate) : new Set<Date>();
        Set<String> weekOffDays = excludeWeekOffs ? getEmployeeWeekOffDays(userId) : new Set<String>();

        // Build day-of-week -> beats map
        Map<String, List<Beat__c>> beatsByDay = buildBeatsByDayMap(beats);

        // Iterate through every day in the date range
        List<Journey_Plan_Day__c> planDays = new List<Journey_Plan_Day__c>();
        Integer sequenceOrder = 0;
        Date currentDate = fromDate;

        while (currentDate <= toDate) {
            String dayOfWeek = getDayOfWeek(currentDate);

            // Skip week-off days
            if (!weekOffDays.contains(dayOfWeek)) {
                // Skip holidays
                if (!holidayDates.contains(currentDate)) {
                    // Skip leave dates
                    if (!leaveDates.contains(currentDate)) {
                        List<Beat__c> daysBeats = beatsByDay.get(dayOfWeek);
                        if (daysBeats != null && !daysBeats.isEmpty()) {
                            Integer dayOfMonth = currentDate.day();
                            Integer daysInMonth = Date.daysInMonth(currentDate.year(), currentDate.month());
                            String weekNumber = getWeekNumber(dayOfMonth);

                            for (Beat__c beat : daysBeats) {
                                if (shouldIncludeForFrequency(beat.Frequency__c, dayOfMonth, daysInMonth)) {
                                    sequenceOrder++;
                                    planDays.add(new Journey_Plan_Day__c(
                                        Journey_Plan__c     = plan.Id,
                                        Plan_Date__c        = currentDate,
                                        Day_Of_Week__c      = dayOfWeek,
                                        Beat__c             = beat.Id,
                                        Beat_Name__c        = beat.Name,
                                        Planned_Outlets__c  = beat.Beat_Outlets__r != null
                                            ? beat.Beat_Outlets__r.size() : 0,
                                        Status__c           = 'Planned',
                                        Sequence__c         = beat.Sequence__c,
                                        Week_Number__c      = weekNumber,
                                        Sequence_Order__c   = sequenceOrder
                                    ));
                                }
                            }
                        }
                    }
                }
            }

            currentDate = currentDate.addDays(1);
        }

        if (!planDays.isEmpty()) {
            insert planDays;
        }

        plan.Total_Planned_Days__c = planDays.size();
        update plan;

        return plan.Id;
    }

    /**
     * @description Backward-compatible overload without exclusion parameters.
     *              Defaults to excluding holidays, leaves, and week-offs.
     */
    public static Id generatePlanForDateRange(
        Id userId,
        Id territoryId,
        Date fromDate,
        Date toDate
    ) {
        return generatePlanForDateRange(userId, territoryId, fromDate, toDate, true, true, true);
    }

    /**
     * @description Backward-compatible overload that reads exclusion preferences
     *              from the plan's stored settings.
     *
     * @param journeyPlanId The Journey_Plan__c record to regenerate.
     * @param toDate        The new end date for the plan.
     */
    public static void regeneratePlan(Id journeyPlanId, Date toDate) {
        regeneratePlan(journeyPlanId, toDate, null, null, null);
    }

    /**
     * @description Regenerates a journey plan by deleting all future plan days
     *              (from today onwards) and recreating them using the user's
     *              current beat assignments. When exclusion parameters are provided
     *              they override the plan's stored settings and the plan record is
     *              updated with the new preferences.
     *
     * @param journeyPlanId   The Journey_Plan__c record to regenerate.
     * @param toDate          The new end date for the plan.
     * @param excludeHolidays When true, holiday dates are excluded. Null falls back to stored preference.
     * @param excludeLeaves   When true, leave dates are excluded. Null falls back to stored preference.
     * @param excludeWeekOffs When true, week-off days are excluded. Null falls back to stored preference.
     */
    public static void regeneratePlan(Id journeyPlanId, Date toDate,
            Boolean excludeHolidays, Boolean excludeLeaves, Boolean excludeWeekOffs) {
        regeneratePlan(journeyPlanId, toDate, excludeHolidays, excludeLeaves, excludeWeekOffs, false);
    }

    /**
     * @description Regenerate overload that can bypass the Draft/Rejected
     *              status gate. Used by the LWC's admin-override path so
     *              sys-admins can regenerate Approved/Active plans without
     *              manually flipping the Status__c field first.
     *              Regular users should call the 5-arg variant above.
     */
    public static void regeneratePlan(Id journeyPlanId, Date toDate,
            Boolean excludeHolidays, Boolean excludeLeaves, Boolean excludeWeekOffs,
            Boolean skipStatusCheck) {
        Journey_Plan__c plan = [
            SELECT Id, Salesperson__c, Territory__c, Status__c,
                   Effective_From__c, Effective_To__c,
                   Exclude_Holidays__c, Exclude_Leaves__c, Exclude_Week_Offs__c
            FROM Journey_Plan__c
            WHERE Id = :journeyPlanId
            LIMIT 1
        ];

        if (skipStatusCheck != true
            && plan.Status__c != 'Draft' && plan.Status__c != 'Rejected') {
            throw new BPM_JourneyPlanServiceException('Only Draft or Rejected plans can be regenerated.');
        }

        Date fromDate = Date.today();
        if (toDate == null) {
            toDate = plan.Effective_To__c != null ? plan.Effective_To__c : fromDate.addMonths(1).addDays(-1);
        }

        // Delete all plan days from today onwards
        List<Journey_Plan_Day__c> futureDays = [
            SELECT Id FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :journeyPlanId AND Plan_Date__c >= :fromDate
        ];
        if (!futureDays.isEmpty()) {
            delete futureDays;
        }

        // Fetch ALL current beat assignments for the user (across all territories)
        Id userId = plan.Salesperson__c;

        List<Beat__c> beats = [
            SELECT Id, Name, Day_of_Week__c, Frequency__c,
                   Territory__c, Sequence__c,
                   (SELECT Id, Account__c, Account__r.Name, Visit_Sequence__c
                    FROM Beat_Outlets__r
                    WHERE Is_Active__c = true
                    ORDER BY Visit_Sequence__c ASC)
            FROM Beat__c
            WHERE Assigned_User__c = :userId
              AND Is_Active__c = true
            ORDER BY Sequence__c NULLS LAST, Name
        ];

        if (beats.isEmpty()) {
            throw new BPM_JourneyPlanServiceException(
                'No active beat assignments found for this user.'
            );
        }

        // Resolve exclusion flags: use provided values or fall back to stored preferences
        if (excludeHolidays == null) {
            excludeHolidays = plan.Exclude_Holidays__c != null ? plan.Exclude_Holidays__c : true;
        }
        if (excludeLeaves == null) {
            excludeLeaves = plan.Exclude_Leaves__c != null ? plan.Exclude_Leaves__c : true;
        }
        if (excludeWeekOffs == null) {
            excludeWeekOffs = plan.Exclude_Week_Offs__c != null ? plan.Exclude_Week_Offs__c : true;
        }

        // Build exclusion sets based on resolved preferences
        Set<Date> holidayDates = excludeHolidays ? getHolidayDates(fromDate, toDate, plan.Territory__c, userId) : new Set<Date>();
        Set<Date> leaveDates = excludeLeaves ? getLeaveDates(userId, fromDate, toDate) : new Set<Date>();
        Set<String> weekOffDays = excludeWeekOffs ? getEmployeeWeekOffDays(userId) : new Set<String>();

        // Build day-of-week -> beats map
        Map<String, List<Beat__c>> beatsByDay = buildBeatsByDayMap(beats);

        // Get max sequence from remaining (past) plan days
        List<AggregateResult> maxSeq = [
            SELECT MAX(Sequence_Order__c) maxVal
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :journeyPlanId
        ];
        Integer sequenceOrder = 0;
        if (maxSeq[0].get('maxVal') != null) {
            sequenceOrder = ((Decimal) maxSeq[0].get('maxVal')).intValue();
        }

        // Create new plan days from today to toDate
        List<Journey_Plan_Day__c> planDays = new List<Journey_Plan_Day__c>();
        Date currentDate = fromDate;

        while (currentDate <= toDate) {
            String dayOfWeek = getDayOfWeek(currentDate);

            if (!weekOffDays.contains(dayOfWeek) &&
                !holidayDates.contains(currentDate) &&
                !leaveDates.contains(currentDate)) {

                List<Beat__c> daysBeats = beatsByDay.get(dayOfWeek);
                if (daysBeats != null && !daysBeats.isEmpty()) {
                    Integer dayOfMonth = currentDate.day();
                    Integer daysInMonth = Date.daysInMonth(currentDate.year(), currentDate.month());
                    String weekNumber = getWeekNumber(dayOfMonth);

                    for (Beat__c beat : daysBeats) {
                        if (shouldIncludeForFrequency(beat.Frequency__c, dayOfMonth, daysInMonth)) {
                            sequenceOrder++;
                            planDays.add(new Journey_Plan_Day__c(
                                Journey_Plan__c     = plan.Id,
                                Plan_Date__c        = currentDate,
                                Day_Of_Week__c      = dayOfWeek,
                                Beat__c             = beat.Id,
                                Beat_Name__c        = beat.Name,
                                Planned_Outlets__c  = beat.Beat_Outlets__r != null
                                    ? beat.Beat_Outlets__r.size() : 0,
                                Status__c           = 'Planned',
                                Sequence__c         = beat.Sequence__c,
                                Week_Number__c      = weekNumber,
                                Sequence_Order__c   = sequenceOrder
                            ));
                        }
                    }
                }
            }

            currentDate = currentDate.addDays(1);
        }

        if (!planDays.isEmpty()) {
            insert planDays;
        }

        // Update plan dates, exclusion preferences, and total
        plan.Effective_To__c = toDate;
        plan.Exclude_Holidays__c = excludeHolidays;
        plan.Exclude_Leaves__c = excludeLeaves;
        plan.Exclude_Week_Offs__c = excludeWeekOffs;
        plan.Total_Planned_Days__c = [
            SELECT COUNT() FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :journeyPlanId
        ];
        update plan;
    }

    /**
     * @description Calculates the compliance percentage for a journey plan by
     *              comparing executed visits against planned visits.
     *
     * @param journeyPlanId The Journey_Plan__c record ID.
     * @return The compliance percentage (0-100).
     */
    public static Decimal getPlanCompliance(Id journeyPlanId) {
        if (journeyPlanId == null) {
            return 0;
        }

        // Get plan days with execution status
        List<Journey_Plan_Day__c> planDays = [
            SELECT Id, Status__c, Planned_Outlets__c, Visited_Outlets__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :journeyPlanId
        ];

        if (planDays.isEmpty()) {
            return 0;
        }

        Decimal totalPlanned = 0;
        Decimal totalExecuted = 0;

        for (Journey_Plan_Day__c day : planDays) {
            Decimal planned = day.Planned_Outlets__c != null ? day.Planned_Outlets__c : 0;
            Decimal visited = day.Visited_Outlets__c != null ? day.Visited_Outlets__c : 0;

            totalPlanned += planned;
            totalExecuted += visited;
        }

        if (totalPlanned == 0) {
            return 0;
        }

        Decimal compliance = (totalExecuted / totalPlanned * 100)
            .setScale(2, RoundingMode.HALF_UP);

        // Cap at 100%
        return Math.min(compliance, 100);
    }

    // ── Exclusion Helpers ─────────────────────────────────────────────────────

    /**
     * @description Retrieves the set of holiday dates within a date range that
     *              apply to the given territory and employee's region.
     *              Includes national holidays (Applicable_Region = 'All'),
     *              regional holidays matching the employee's region/zone,
     *              and territory-specific holidays.
     */
    private static Set<Date> getHolidayDates(Date fromDate, Date toDate, Id territoryId, Id userId) {
        Set<Date> holidays = new Set<Date>();

        // Lookup the employee's region/zone for regional holiday matching
        String employeeRegion = null;
        String employeeZone = null;
        List<Employee__c> employees = [
            SELECT Id, Region__c, Zone__c
            FROM Employee__c
            WHERE User__c = :userId AND Is_Active__c = true
            LIMIT 1
        ];
        if (!employees.isEmpty()) {
            employeeRegion = employees[0].Region__c;
            employeeZone = employees[0].Zone__c;
        }

        // Fetch all active holidays in the date range
        List<Holiday__c> holidayRecords = [
            SELECT Id, Holiday_Date__c, Territory__c, Type__c
            FROM Holiday__c
            WHERE Holiday_Date__c >= :fromDate
            AND Holiday_Date__c <= :toDate
            AND Is_Active__c = true
        ];

        for (Holiday__c h : holidayRecords) {
            Boolean applies = false;

            // National and Company holidays apply to everyone
            if (h.Type__c == 'National Holiday' || h.Type__c == 'Company Holiday') {
                applies = true;
            }
            // Territory-specific holiday
            else if (h.Territory__c != null && h.Territory__c == territoryId) {
                applies = true;
            }
            // If no territory specified, treat as org-wide
            else if (h.Territory__c == null) {
                applies = true;
            }

            if (applies) {
                holidays.add(h.Holiday_Date__c);
            }
        }

        return holidays;
    }

    /**
     * @description Retrieves the set of leave dates for a user within a date range.
     *              Includes dates from Approved and Pending leave requests.
     *              Expands multi-day leaves into individual dates.
     */
    private static Set<Date> getLeaveDates(Id userId, Date fromDate, Date toDate) {
        Set<Date> leaveDates = new Set<Date>();

        // Find leave requests that overlap with the date range
        List<Leave_Request__c> leaves = [
            SELECT Id, Start_Date__c, End_Date__c
            FROM Leave_Request__c
            WHERE Employee__c = :userId
            AND Status__c IN ('Approved', 'Pending')
            AND Start_Date__c <= :toDate
            AND End_Date__c >= :fromDate
        ];

        for (Leave_Request__c leave : leaves) {
            // Expand each leave into individual dates within the plan range
            Date leaveStart = leave.Start_Date__c < fromDate ? fromDate : leave.Start_Date__c;
            Date leaveEnd = leave.End_Date__c > toDate ? toDate : leave.End_Date__c;

            Date d = leaveStart;
            while (d <= leaveEnd) {
                leaveDates.add(d);
                d = d.addDays(1);
            }
        }

        return leaveDates;
    }

    /**
     * @description Retrieves the set of week-off day names for an employee.
     *              Reads from the Employee__c.Week_Off_Days__c multi-select picklist.
     *              Falls back to 'Sunday' if no configuration exists.
     */
    private static Set<String> getEmployeeWeekOffDays(Id userId) {
        Set<String> weekOffDays = new Set<String>();

        List<Employee__c> employees = [
            SELECT Id, Week_Off_Days__c
            FROM Employee__c
            WHERE User__c = :userId AND Is_Active__c = true
            LIMIT 1
        ];

        if (!employees.isEmpty() && String.isNotBlank(employees[0].Week_Off_Days__c)) {
            for (String day : employees[0].Week_Off_Days__c.split(';')) {
                weekOffDays.add(day.trim());
            }
        } else {
            // Default fallback: Sunday is the week-off
            weekOffDays.add('Sunday');
        }

        return weekOffDays;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Builds a map of day-of-week name to list of beats assigned to that day.
     */
    private static Map<String, List<Beat__c>> buildBeatsByDayMap(List<Beat__c> beats) {
        Map<String, List<Beat__c>> beatsByDay = new Map<String, List<Beat__c>>();
        for (Beat__c beat : beats) {
            if (String.isNotBlank(beat.Day_of_Week__c)) {
                List<String> days = beat.Day_of_Week__c.split(';');
                for (String day : days) {
                    String trimmedDay = day.trim();
                    if (!beatsByDay.containsKey(trimmedDay)) {
                        beatsByDay.put(trimmedDay, new List<Beat__c>());
                    }
                    beatsByDay.get(trimmedDay).add(beat);
                }
            }
        }
        return beatsByDay;
    }

    /**
     * @description Parses the month parameter which can be a number (1-12) or
     *              a month name.
     */
    private static Integer parseMonth(String month) {
        Map<String, Integer> monthNames = new Map<String, Integer>{
            'january' => 1, 'february' => 2, 'march' => 3,
            'april' => 4, 'may' => 5, 'june' => 6,
            'july' => 7, 'august' => 8, 'september' => 9,
            'october' => 10, 'november' => 11, 'december' => 12
        };

        // Try as number first
        try {
            Integer monthInt = Integer.valueOf(month);
            if (monthInt >= 1 && monthInt <= 12) {
                return monthInt;
            }
        } catch (Exception e) {
            // Not a number, try as name
        }

        String lowerMonth = month.toLowerCase().trim();
        if (monthNames.containsKey(lowerMonth)) {
            return monthNames.get(lowerMonth);
        }

        throw new BPM_JourneyPlanServiceException('Invalid month value: ' + month);
    }

    /**
     * @description Returns the day-of-week name for a given date.
     */
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

    /**
     * @description Determines whether a beat should be included based on its
     *              frequency and the day of the month.
     */
    private static Boolean shouldIncludeForFrequency(
        String frequency,
        Integer dayOfMonth,
        Integer daysInMonth
    ) {
        if (String.isBlank(frequency) || frequency == 'Daily' || frequency == 'Weekly') {
            return true;
        }

        if (frequency == 'Bi-Weekly') {
            // Include beats in alternating weeks: week 1 (days 1-7) and week 3 (days 15-21)
            return (dayOfMonth >= 1 && dayOfMonth <= 7) || (dayOfMonth >= 15 && dayOfMonth <= 21);
        }

        if (frequency == 'Monthly') {
            return dayOfMonth <= 7;
        }

        return true;
    }

    /**
     * @description Returns the week number label ("Week 1" through "Week 4")
     *              for a given day of the month.
     */
    private static String getWeekNumber(Integer dayOfMonth) {
        if (dayOfMonth <= 7) return 'Week 1';
        if (dayOfMonth <= 14) return 'Week 2';
        if (dayOfMonth <= 21) return 'Week 3';
        return 'Week 4';
    }

    /**
     * @description Converts a month integer (1-12) to the standard picklist
     *              name (e.g. "January").
     */
    private static String normalizeMonthName(Integer monthInt) {
        List<String> names = new List<String>{
            'January', 'February', 'March', 'April', 'May', 'June',
            'July', 'August', 'September', 'October', 'November', 'December'
        };
        return names[monthInt - 1];
    }
}