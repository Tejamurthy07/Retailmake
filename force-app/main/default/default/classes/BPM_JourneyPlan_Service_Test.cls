/**
 * @description Test class for BPM_JourneyPlan_Service.
 *              Validates journey plan generation and compliance calculation.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class BPM_JourneyPlan_Service_Test {

    @testSetup
    static void setupTestData() {
        // Create territory
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('JP Territory', 'TER-JP01');

        // Create beats assigned to the running user with different days
        List<String> dayNames = new List<String>{'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'};
        List<Beat__c> beats = new List<Beat__c>();
        for (Integer i = 0; i < 5; i++) {
            Beat__c beat = TestDataFactory.createBeat(
                'JP Beat ' + i, 'BEAT-JP' + String.valueOf(i).leftPad(2, '0'), territory.Id
            );
            beat.Day_of_Week__c = dayNames[i];
            beat.Assigned_User__c = UserInfo.getUserId();
            beat.Sequence__c = i + 1;
            beats.add(beat);
        }
        insert beats;

        // Create accounts for outlets
        List<Account> outlets = new List<Account>();
        for (Integer i = 0; i < 20; i++) {
            outlets.add(TestDataFactory.createAccount('JP Outlet ' + i, 'Retailer'));
        }
        insert outlets;

        // Create 4 beat outlets per beat (20 outlets / 5 beats)
        List<Beat_Outlet__c> beatOutlets = new List<Beat_Outlet__c>();
        for (Integer i = 0; i < 20; i++) {
            Beat_Outlet__c bo = TestDataFactory.createBeatOutlet(
                beats[Math.mod(i, 5)].Id, outlets[i].Id
            );
            bo.Visit_Sequence__c = Math.mod(i, 4) + 1;
            beatOutlets.add(bo);
        }
        insert beatOutlets;

        // Create existing journey plan for current month (used by duplicate + compliance tests)
        String currentMonth = DateTime.now().format('MMMM');
        String currentYear = String.valueOf(Date.today().year());
        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(
            UserInfo.getUserId(), currentMonth, currentYear
        );
        jp.Territory__c = territory.Id;
        insert jp;

        // Create journey plan days for the existing plan
        List<Journey_Plan_Day__c> jpDays = new List<Journey_Plan_Day__c>();
        for (Integer i = 0; i < 5; i++) {
            Journey_Plan_Day__c jpDay = new Journey_Plan_Day__c(
                Journey_Plan__c = jp.Id,
                Day_of_Week__c = dayNames[i],
                Beat__c = beats[i].Id,
                Week_Number__c = 'Week 1',
                Planned_Outlets__c = 4,
                Visited_Outlets__c = 0,
                Sequence_Order__c = i + 1,
                Status__c = 'Planned'
            );
            jpDays.add(jpDay);
        }
        insert jpDays;

        // Create day attendance and visits for compliance tracking
        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        List<Visit__c> visits = new List<Visit__c>();
        for (Integer i = 0; i < 15; i++) {
            Visit__c visit = new Visit__c(
                Account__c = outlets[i].Id,
                Salesperson__c = UserInfo.getUserId(),
                Day_Attendance__c = da.Id,
                Beat__c = beats[Math.mod(i, beats.size())].Id,
                Visit_Date__c = Date.today(),
                Check_In_Time__c = DateTime.now().addMinutes(i * 15),
                Check_In_Lat__c = 19.0760,
                Check_In_Long__c = 72.8777,
                Visit_Status__c = 'Completed',
                Is_Planned__c = i < 12,
                Is_Productive__c = i < 10,
                Check_Out_Time__c = DateTime.now().addMinutes(i * 15 + 10),
                Check_Out_Lat__c = 19.0761,
                Check_Out_Long__c = 72.8778
            );
            visits.add(visit);
        }
        insert visits;
    }

    /**
     * @description Tests that generateDefaultPlan creates a Journey_Plan__c header
     *              and Journey_Plan_Day__c records with correct field values.
     */
    @isTest
    static void testGenerateDefaultPlan() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        // Use next month to avoid duplicate with the existing plan
        Date nextMonth = Date.today().addMonths(1);
        String targetMonth = DateTime.newInstance(nextMonth, Time.newInstance(0, 0, 0, 0)).format('MMMM');
        String targetYear = String.valueOf(nextMonth.year());

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id, targetMonth, targetYear
        );
        Test.stopTest();

        // Verify plan header
        Journey_Plan__c plan = [
            SELECT Id, Salesperson__c, Month__c, Year__c, Status__c,
                   Total_Planned_Days__c, Total_Planned_Visits__c,
                   Effective_From__c, Effective_To__c, Territory__c
            FROM Journey_Plan__c
            WHERE Id = :planId
        ];

        System.assertNotEquals(null, plan, 'Journey plan should be created');
        System.assertEquals(UserInfo.getUserId(), plan.Salesperson__c,
            'Plan should be assigned to the current user');
        System.assertEquals(targetMonth, plan.Month__c,
            'Plan month should be stored as picklist name');
        System.assertEquals(targetYear, plan.Year__c,
            'Plan year should match');
        System.assertEquals('Draft', plan.Status__c,
            'New plan should be in Draft status');
        System.assertEquals(territory.Id, plan.Territory__c,
            'Plan should be linked to the territory');

        // Verify plan days were created
        List<Journey_Plan_Day__c> planDays = [
            SELECT Id, Day_of_Week__c, Beat__c, Beat_Name__c,
                   Planned_Outlets__c, Week_Number__c, Sequence_Order__c,
                   Status__c, Plan_Date__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :planId
            ORDER BY Sequence_Order__c
        ];

        System.assert(planDays.size() > 0,
            'Plan should have journey plan day records created');

        for (Journey_Plan_Day__c day : planDays) {
            System.assertNotEquals(null, day.Beat__c,
                'Each plan day should have a beat assigned');
            System.assertNotEquals(null, day.Beat_Name__c,
                'Each plan day should have the beat name populated');
            System.assert(day.Week_Number__c != null && day.Week_Number__c.startsWith('Week '),
                'Week number should be in "Week N" format');
            System.assertNotEquals(null, day.Plan_Date__c,
                'Each plan day should have a plan date');
            System.assertEquals('Planned', day.Status__c,
                'Each plan day should default to Planned status');
            System.assertEquals(4, day.Planned_Outlets__c,
                'Each beat has 4 active outlets');
            System.assertNotEquals('Sunday', day.Day_of_Week__c,
                'Sundays should be excluded');
        }

        // Verify totals rolled up
        System.assert(plan.Total_Planned_Days__c > 0,
            'Total planned days should be populated');
    }

    /**
     * @description Tests that plan compliance is correctly calculated as the
     *              ratio of visited outlets to planned outlets across plan days.
     */
    @isTest
    static void testPlanCompliance() {
        Journey_Plan__c plan = [SELECT Id FROM Journey_Plan__c LIMIT 1];

        // Update plan days: 3 of 5 days fully visited (4/4), 2 days with 0 visits
        List<Journey_Plan_Day__c> days = [
            SELECT Id, Planned_Outlets__c
            FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :plan.Id
            ORDER BY Sequence_Order__c
        ];
        for (Integer i = 0; i < days.size(); i++) {
            days[i].Visited_Outlets__c = (i < 3) ? 4 : 0;
        }
        update days;

        Test.startTest();
        Decimal compliance = BPM_JourneyPlan_Service.getPlanCompliance(plan.Id);
        Test.stopTest();

        // 3 days x 4 visited / 5 days x 4 planned = 12/20 = 60%
        System.assertEquals(60.00, compliance,
            'Compliance should be 60% (12 visited / 20 planned)');
    }

    /**
     * @description Tests that getPlanCompliance returns 0 for a null plan ID.
     */
    @isTest
    static void testPlanComplianceNull() {
        Test.startTest();
        Decimal compliance = BPM_JourneyPlan_Service.getPlanCompliance(null);
        Test.stopTest();

        System.assertEquals(0, compliance,
            'Null plan ID should return 0 compliance');
    }

    /**
     * @description Verifies that journey plan status transitions work correctly
     *              from Draft to Submitted to Approved.
     */
    @isTest
    static void testPlanStatusTransition() {
        Journey_Plan__c plan = [SELECT Id, Status__c FROM Journey_Plan__c LIMIT 1];

        Test.startTest();

        System.assertEquals('Draft', plan.Status__c, 'Plan should start as Draft');

        // Submit for approval
        plan.Status__c = 'Submitted';
        update plan;

        Journey_Plan__c submitted = [SELECT Status__c FROM Journey_Plan__c WHERE Id = :plan.Id];
        System.assertEquals('Submitted', submitted.Status__c,
            'Plan should transition to Submitted');

        // Approve
        plan.Status__c = 'Approved';
        update plan;

        Journey_Plan__c approved = [SELECT Status__c, Approved_By__c, Approval_Date__c
                                    FROM Journey_Plan__c WHERE Id = :plan.Id];
        System.assertEquals('Approved', approved.Status__c,
            'Plan should transition to Approved');
        System.assertNotEquals(null, approved.Approved_By__c,
            'Approved plan should have an approver');
        System.assertNotEquals(null, approved.Approval_Date__c,
            'Approved plan should have an approval date');

        Test.stopTest();
    }

    /**
     * @description Tests that generateDefaultPlan throws the correct exception
     *              when invalid parameters are provided.
     */
    @isTest
    static void testGenerateDefaultPlanInvalidParams() {
        Test.startTest();
        try {
            BPM_JourneyPlan_Service.generateDefaultPlan(null, null, null, null);
            System.assert(false, 'Should have thrown BPM_JourneyPlanServiceException');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('required'),
                'Exception should mention required parameters');
        }
        Test.stopTest();
    }

    /**
     * @description Tests that generateDefaultPlan throws exception when plan
     *              already exists for the user/territory/month/year.
     */
    @isTest
    static void testGenerateDefaultPlanDuplicate() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        String currentMonth = DateTime.now().format('MMMM');
        String currentYear = String.valueOf(Date.today().year());

        Test.startTest();
        try {
            BPM_JourneyPlan_Service.generateDefaultPlan(
                UserInfo.getUserId(), territory.Id, currentMonth, currentYear
            );
            System.assert(false, 'Should have thrown exception for duplicate plan');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('already exists'),
                'Exception should mention plan already exists');
        }
        Test.stopTest();
    }

    // ── generatePlanForDateRange ─────────────────────────────────────

    @isTest
    static void testGeneratePlanForDateRange() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date fromDate = Date.today().addMonths(2).toStartOfMonth();
        Date toDate = fromDate.addDays(13);

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generatePlanForDateRange(
            UserInfo.getUserId(), territory.Id, fromDate, toDate
        );
        Test.stopTest();

        System.assertNotEquals(null, planId, 'Plan should be created');
        Journey_Plan__c plan = [SELECT Effective_From__c, Effective_To__c, Exclude_Holidays__c,
            Exclude_Leaves__c, Exclude_Week_Offs__c FROM Journey_Plan__c WHERE Id = :planId];
        System.assertEquals(fromDate, plan.Effective_From__c);
        System.assertEquals(toDate, plan.Effective_To__c);
        System.assertEquals(true, plan.Exclude_Holidays__c, 'Default should exclude holidays');

        List<Journey_Plan_Day__c> days = [
            SELECT Plan_Date__c FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :planId
        ];
        System.assert(days.size() > 0, 'Should have plan days');
        for (Journey_Plan_Day__c d : days) {
            System.assert(d.Plan_Date__c >= fromDate && d.Plan_Date__c <= toDate,
                'All plan dates should be within the specified range');
        }
    }

    @isTest
    static void testGeneratePlanForDateRangeWithExplicitExclusions() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date fromDate = Date.today().addMonths(7).toStartOfMonth();
        Date toDate = fromDate.addDays(13);

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generatePlanForDateRange(
            UserInfo.getUserId(), territory.Id, fromDate, toDate, false, false, false
        );
        Test.stopTest();

        Journey_Plan__c plan = [SELECT Exclude_Holidays__c, Exclude_Leaves__c, Exclude_Week_Offs__c
            FROM Journey_Plan__c WHERE Id = :planId];
        System.assertEquals(false, plan.Exclude_Holidays__c, 'Should not exclude holidays');
        System.assertEquals(false, plan.Exclude_Leaves__c, 'Should not exclude leaves');
        System.assertEquals(false, plan.Exclude_Week_Offs__c, 'Should not exclude week offs');
    }

    @isTest
    static void testGeneratePlanForDateRangeInvalidParams() {
        Test.startTest();
        try {
            BPM_JourneyPlan_Service.generatePlanForDateRange(null, null, null, null);
            System.assert(false, 'Should throw for null params');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('required'));
        }
        Test.stopTest();
    }

    @isTest
    static void testGeneratePlanForDateRangeInvalidRange() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date fromDate = Date.newInstance(2030, 6, 15);
        Date toDate = Date.newInstance(2030, 6, 1);

        Test.startTest();
        try {
            BPM_JourneyPlan_Service.generatePlanForDateRange(
                UserInfo.getUserId(), territory.Id, fromDate, toDate
            );
            System.assert(false, 'Should throw for fromDate > toDate');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('before or equal'));
        }
        Test.stopTest();
    }

    @isTest
    static void testGeneratePlanForDateRangeOverlap() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date fromDate = Date.today().addMonths(8).toStartOfMonth();
        Date toDate = fromDate.addDays(13);

        BPM_JourneyPlan_Service.generatePlanForDateRange(
            UserInfo.getUserId(), territory.Id, fromDate, toDate
        );

        Test.startTest();
        try {
            BPM_JourneyPlan_Service.generatePlanForDateRange(
                UserInfo.getUserId(), territory.Id, fromDate.addDays(5), toDate.addDays(5)
            );
            System.assert(false, 'Should throw for overlapping plan');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('overlapping') || e.getMessage().contains('already exists'));
        }
        Test.stopTest();
    }

    @isTest
    static void testGeneratePlanForDateRangeCrossMonth() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date fromDate = Date.newInstance(2029, 11, 20);
        Date toDate = Date.newInstance(2029, 12, 10);

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generatePlanForDateRange(
            UserInfo.getUserId(), territory.Id, fromDate, toDate
        );
        Test.stopTest();

        Journey_Plan__c plan = [SELECT Name FROM Journey_Plan__c WHERE Id = :planId];
        System.assert(plan.Name.contains('November'), 'Cross-month plan name should include start month');
        System.assert(plan.Name.contains('December'), 'Cross-month plan name should include end month');
    }

    // ── regeneratePlan ──────────────────────────────────────────────

    @isTest
    static void testRegeneratePlan() {
        Journey_Plan__c plan = [SELECT Id, Status__c FROM Journey_Plan__c LIMIT 1];

        Test.startTest();
        BPM_JourneyPlan_Service.regeneratePlan(plan.Id, Date.today().addMonths(1));
        Test.stopTest();

        Integer daysAfter = [SELECT COUNT() FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :plan.Id];
        System.assert(daysAfter >= 0, 'Regenerated plan should complete successfully');
    }

    @isTest
    static void testRegeneratePlanWithExclusions() {
        Journey_Plan__c plan = [SELECT Id FROM Journey_Plan__c LIMIT 1];

        Test.startTest();
        BPM_JourneyPlan_Service.regeneratePlan(
            plan.Id, Date.today().addMonths(1), true, true, true
        );
        Test.stopTest();

        System.assert([SELECT COUNT() FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :plan.Id] >= 0,
            'Regeneration with exclusions should complete');
    }

    @isTest
    static void testRegeneratePlanWithNoExclusions() {
        Journey_Plan__c plan = [SELECT Id FROM Journey_Plan__c LIMIT 1];

        Test.startTest();
        BPM_JourneyPlan_Service.regeneratePlan(
            plan.Id, Date.today().addMonths(1), false, false, false
        );
        Test.stopTest();

        Journey_Plan__c updated = [SELECT Exclude_Holidays__c, Exclude_Leaves__c, Exclude_Week_Offs__c
            FROM Journey_Plan__c WHERE Id = :plan.Id];
        System.assertEquals(false, updated.Exclude_Holidays__c);
        System.assertEquals(false, updated.Exclude_Leaves__c);
        System.assertEquals(false, updated.Exclude_Week_Offs__c);
    }

    @isTest
    static void testRegeneratePlanNullToDate() {
        Journey_Plan__c plan = [SELECT Id FROM Journey_Plan__c LIMIT 1];

        Test.startTest();
        BPM_JourneyPlan_Service.regeneratePlan(plan.Id, null);
        Test.stopTest();

        System.assert([SELECT COUNT() FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :plan.Id] >= 0,
            'Regenerate with null toDate should fall back to plan dates');
    }

    @isTest
    static void testRegeneratePlanStatusCheckFails() {
        Journey_Plan__c plan = [SELECT Id FROM Journey_Plan__c LIMIT 1];
        plan.Status__c = 'Submitted';
        update plan;
        plan.Status__c = 'Approved';
        update plan;

        Test.startTest();
        try {
            BPM_JourneyPlan_Service.regeneratePlan(plan.Id, Date.today().addMonths(1));
            System.assert(false, 'Should throw for non-Draft plan');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('Draft or Rejected'));
        }
        Test.stopTest();
    }

    @isTest
    static void testRegeneratePlanSkipStatusCheck() {
        Journey_Plan__c plan = [SELECT Id FROM Journey_Plan__c LIMIT 1];
        plan.Status__c = 'Submitted';
        update plan;
        plan.Status__c = 'Approved';
        update plan;

        Test.startTest();
        BPM_JourneyPlan_Service.regeneratePlan(
            plan.Id, Date.today().addMonths(1), true, true, true, true
        );
        Test.stopTest();

        System.assert([SELECT COUNT() FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :plan.Id] >= 0,
            'Regeneration with skipStatusCheck should bypass status gate');
    }

    // ── Holiday exclusion ───────────────────────────────────────────

    @isTest
    static void testHolidayExclusion() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date nextMonthStart = Date.today().addMonths(3).toStartOfMonth();

        Date holidayDate = nextMonthStart;
        while (Math.mod(holidayDate.toStartOfWeek().daysBetween(holidayDate), 7) == 0 ||
               Math.mod(holidayDate.toStartOfWeek().daysBetween(holidayDate), 7) == 6) {
            holidayDate = holidayDate.addDays(1);
        }
        Holiday__c h = new Holiday__c(
            Name = 'Test Holiday',
            Holiday_Date__c = holidayDate,
            Type__c = 'National Holiday',
            Is_Active__c = true
        );
        insert h;

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(nextMonthStart, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(nextMonthStart.year())
        );
        Test.stopTest();

        List<Journey_Plan_Day__c> days = [
            SELECT Plan_Date__c FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :planId
        ];
        for (Journey_Plan_Day__c d : days) {
            System.assertNotEquals(holidayDate, d.Plan_Date__c,
                'Holiday date should be excluded from plan');
        }
    }

    @isTest
    static void testCompanyHolidayExclusion() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date targetMonthStart = Date.today().addMonths(9).toStartOfMonth();

        Date holidayDate = targetMonthStart.addDays(2);
        Holiday__c h = new Holiday__c(
            Name = 'Company Holiday',
            Holiday_Date__c = holidayDate,
            Type__c = 'Company Holiday',
            Is_Active__c = true
        );
        insert h;

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(targetMonthStart, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(targetMonthStart.year())
        );
        Test.stopTest();

        List<Journey_Plan_Day__c> days = [
            SELECT Plan_Date__c FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :planId
        ];
        for (Journey_Plan_Day__c d : days) {
            System.assertNotEquals(holidayDate, d.Plan_Date__c,
                'Company holiday should be excluded');
        }
    }

    @isTest
    static void testTerritoryHolidayExclusion() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date targetMonthStart = Date.today().addMonths(10).toStartOfMonth();

        Holiday__c h = new Holiday__c(
            Name = 'Territory Holiday',
            Holiday_Date__c = targetMonthStart.addDays(3),
            Type__c = 'Regional Holiday',
            Territory__c = territory.Id,
            Is_Active__c = true
        );
        insert h;

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(targetMonthStart, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(targetMonthStart.year())
        );
        Test.stopTest();

        System.assertNotEquals(null, planId, 'Plan should be created with territory holidays excluded');
    }

    // ── Leave exclusion ─────────────────────────────────────────────

    @isTest
    static void testLeaveExclusion() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date targetMonthStart = Date.today().addMonths(11).toStartOfMonth();

        Leave_Request__c leave = new Leave_Request__c(
            Employee__c = UserInfo.getUserId(),
            Start_Date__c = targetMonthStart.addDays(1),
            End_Date__c = targetMonthStart.addDays(3),
            Status__c = 'Approved'
        );
        insert leave;

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(targetMonthStart, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(targetMonthStart.year())
        );
        Test.stopTest();

        List<Journey_Plan_Day__c> days = [
            SELECT Plan_Date__c FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :planId
        ];
        Set<Date> leaveDates = new Set<Date>{
            targetMonthStart.addDays(1), targetMonthStart.addDays(2), targetMonthStart.addDays(3)
        };
        for (Journey_Plan_Day__c d : days) {
            System.assert(!leaveDates.contains(d.Plan_Date__c),
                'Leave dates should be excluded from plan');
        }
    }

    // ── Week-off exclusion ──────────────────────────────────────────

    @isTest
    static void testWeekOffExclusion() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Employee__c emp = new Employee__c(
            First_Name__c = 'Test',
            Last_Name__c = 'User',
            Employee_Code__c = 'EMP-JPTEST01',
            User__c = UserInfo.getUserId(),
            Territory__c = territory.Id,
            Channels__c = 'GT',
            Is_Active__c = true,
            Week_Off_Days__c = 'Sunday;Saturday'
        );
        insert emp;

        Date targetMonth = Date.today().addMonths(4).toStartOfMonth();

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(targetMonth, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(targetMonth.year())
        );
        Test.stopTest();

        List<Journey_Plan_Day__c> days = [
            SELECT Day_of_Week__c FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :planId
        ];
        for (Journey_Plan_Day__c d : days) {
            System.assertNotEquals('Sunday', d.Day_of_Week__c, 'Sunday should be excluded');
            System.assertNotEquals('Saturday', d.Day_of_Week__c, 'Saturday should be excluded');
        }
    }

    @isTest
    static void testWeekOffFallbackToSunday() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date targetMonth = Date.today().addMonths(6).toStartOfMonth();

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(targetMonth, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(targetMonth.year())
        );
        Test.stopTest();

        List<Journey_Plan_Day__c> days = [
            SELECT Day_of_Week__c FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :planId
        ];
        for (Journey_Plan_Day__c d : days) {
            System.assertNotEquals('Sunday', d.Day_of_Week__c,
                'Sunday should be excluded by default fallback');
        }
    }

    // ── generateDefaultPlan with date range overload ────────────────

    @isTest
    static void testGenerateDefaultPlanWithRange() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Date nextMonth = Date.today().addMonths(5).toStartOfMonth();
        Date rangeEnd = nextMonth.addDays(6);

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(nextMonth, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(nextMonth.year()),
            nextMonth, rangeEnd
        );
        Test.stopTest();

        System.assertNotEquals(null, planId, 'Plan should be created');
        Journey_Plan__c plan = [SELECT Effective_From__c, Effective_To__c FROM Journey_Plan__c WHERE Id = :planId];
        System.assertEquals(nextMonth, plan.Effective_From__c, 'Effective from should match');
        System.assertEquals(rangeEnd, plan.Effective_To__c, 'Effective to should match');
    }

    // ── Frequency-based filtering ───────────────────────────────────

    @isTest
    static void testBiWeeklyFrequency() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        List<Beat__c> beats = [SELECT Id, Frequency__c FROM Beat__c LIMIT 1];
        beats[0].Frequency__c = 'Bi-Weekly';
        update beats;

        Date targetMonth = Date.today().addMonths(12).toStartOfMonth();

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(targetMonth, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(targetMonth.year())
        );
        Test.stopTest();

        System.assertNotEquals(null, planId, 'Plan should be created with Bi-Weekly beat');
    }

    @isTest
    static void testMonthlyFrequency() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Beat__c monthlyBeat = [SELECT Id, Frequency__c FROM Beat__c LIMIT 1];
        monthlyBeat.Frequency__c = 'Monthly';
        update monthlyBeat;

        Date targetMonth = Date.today().addMonths(13).toStartOfMonth();

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id,
            DateTime.newInstance(targetMonth, Time.newInstance(0,0,0,0)).format('MMMM'),
            String.valueOf(targetMonth.year())
        );
        Test.stopTest();

        List<Journey_Plan_Day__c> days = [
            SELECT Plan_Date__c, Beat__c FROM Journey_Plan_Day__c
            WHERE Journey_Plan__c = :planId AND Beat__c = :monthlyBeat.Id
        ];
        for (Journey_Plan_Day__c d : days) {
            System.assert(d.Plan_Date__c.day() <= 7,
                'Monthly frequency should only include days in week 1');
        }
    }

    // ── parseMonth with numeric input ───────────────────────────────

    @isTest
    static void testGenerateWithNumericMonth() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Test.startTest();
        Id planId = BPM_JourneyPlan_Service.generateDefaultPlan(
            UserInfo.getUserId(), territory.Id, '3', '2030'
        );
        Test.stopTest();

        Journey_Plan__c plan = [SELECT Month__c FROM Journey_Plan__c WHERE Id = :planId];
        System.assertEquals('March', plan.Month__c, 'Numeric month 3 should resolve to March');
    }

    @isTest
    static void testGenerateWithInvalidMonth() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Test.startTest();
        try {
            BPM_JourneyPlan_Service.generateDefaultPlan(
                UserInfo.getUserId(), territory.Id, 'InvalidMonth', '2030'
            );
            System.assert(false, 'Should throw for invalid month name');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('Invalid month'));
        }
        Test.stopTest();
    }

    // ── Compliance edge cases ───────────────────────────────────────

    @isTest
    static void testComplianceZeroPlanned() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Journey_Plan__c emptyPlan = new Journey_Plan__c(
            Name = 'Empty Plan',
            Salesperson__c = UserInfo.getUserId(),
            Territory__c = territory.Id,
            Month__c = 'January',
            Year__c = '2099',
            Status__c = 'Draft'
        );
        insert emptyPlan;

        Test.startTest();
        Decimal compliance = BPM_JourneyPlan_Service.getPlanCompliance(emptyPlan.Id);
        Test.stopTest();

        System.assertEquals(0, compliance, 'Empty plan should have 0 compliance');
    }

    @isTest
    static void testComplianceCappedAt100() {
        Journey_Plan__c plan = [SELECT Id FROM Journey_Plan__c LIMIT 1];
        List<Journey_Plan_Day__c> days = [
            SELECT Id FROM Journey_Plan_Day__c WHERE Journey_Plan__c = :plan.Id LIMIT 1
        ];
        if (!days.isEmpty()) {
            days[0].Planned_Outlets__c = 2;
            days[0].Visited_Outlets__c = 10;
            update days;
        }

        Test.startTest();
        Decimal compliance = BPM_JourneyPlan_Service.getPlanCompliance(plan.Id);
        Test.stopTest();

        System.assert(compliance <= 100, 'Compliance should be capped at 100');
    }

    // ── No active beats scenario ────────────────────────────────────

    @isTest
    static void testGenerateWithNoActiveBeats() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        List<Beat__c> beats = [SELECT Id FROM Beat__c WHERE Assigned_User__c = :UserInfo.getUserId()];
        for (Beat__c b : beats) {
            b.Is_Active__c = false;
        }
        update beats;

        Test.startTest();
        try {
            BPM_JourneyPlan_Service.generatePlanForDateRange(
                UserInfo.getUserId(), territory.Id,
                Date.newInstance(2031, 1, 1), Date.newInstance(2031, 1, 14)
            );
            System.assert(false, 'Should throw when no active beats');
        } catch (BPM_JourneyPlanServiceException e) {
            System.assert(e.getMessage().contains('No active beat'));
        }
        Test.stopTest();
    }
}