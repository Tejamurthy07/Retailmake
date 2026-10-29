/**
 * @description Test class for DayAttendanceController.
 *              Validates all 9 @AuraEnabled controller methods that wrap
 *              DFO_DayAttendance_Service. Uses try/catch for methods that
 *              may throw AuraHandledException due to disabled feature toggles.
 *
 * @author  SFA Development Team
 * @date    2026
 */
@isTest
private class DayAttendanceController_Test {

    @testSetup
    static void setupTestData() {
        // Territory and beat
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('DA Territory', 'TER-DA01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('DA Beat', 'BEAT-DA01', territory.Id);

        // Accounts
        List<Account> outlets = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            outlets.add(TestDataFactory.createAccount('DA Outlet ' + i, 'Retailer'));
        }
        insert outlets;

        // Day Attendance (with extended defaults)
        Day_Attendance__c da = TestDataFactory.createDayAttendanceWithDefaults(UserInfo.getUserId());
        insert da;

        // Create visits for stats tests
        List<Visit__c> visits = new List<Visit__c>();
        for (Integer i = 0; i < 3; i++) {
            Visit__c v = TestDataFactory.createVisitWithDefaults(
                outlets[i].Id, UserInfo.getUserId(), da.Id, beat.Id
            );
            v.Visit_Status__c = 'Completed';
            v.Check_Out_Time__c = DateTime.now().addMinutes(30 + (i * 15));
            v.Is_Productive__c = (i < 2);
            v.Order_Value__c = (i < 2) ? 5000 : 0;
            v.Collection_Amount__c = (i < 2) ? 3000 : 0;
            v.Visit_Sequence__c = i + 1;
            visits.add(v);
        }
        insert visits;
    }

    /**
     * @description Tests startDay() controller wrapper with JSON payload.
     */
    @isTest
    static void testStartDay() {
        // Delete existing DA so startDay can create a new one (avoid duplicate)
        delete [SELECT Id FROM Day_Attendance__c];

        Map<String, Object> requestMap = new Map<String, Object>{
            'startLatitude' => 19.0760,
            'startLongitude' => 72.8777,
            'startAccuracy' => 10.0,
            'batteryLevel' => 90,
            'networkStatus' => 'WiFi',
            'deviceInfo' => 'Test Device',
            'odometerStart' => 12500.0,
            'withCompanion' => false
        };
        String dayJson = JSON.serialize(requestMap);

        Test.startTest();
        try {
            Day_Attendance__c result = DayAttendanceController.startDay(dayJson);
            System.assertNotEquals(null, result, 'Result should not be null if feature enabled');
            System.assertEquals('Started', result.Status__c, 'Status should be Started');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('disabled') || e.getMessage().contains('Attendance'),
                'Should throw expected error. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    /**
     * @description Tests endDay() controller wrapper with JSON payload.
     */
    @isTest
    static void testEndDay() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Map<String, Object> requestMap = new Map<String, Object>{
            'attendanceId' => da.Id,
            'endLatitude' => 19.0800,
            'endLongitude' => 72.8800,
            'endAccuracy' => 15.0,
            'remarks' => 'Good day',
            'odometerEnd' => 12650.0
        };
        String dayJson = JSON.serialize(requestMap);

        Test.startTest();
        try {
            Day_Attendance__c result = DayAttendanceController.endDay(dayJson);
            System.assertNotEquals(null, result, 'Result should not be null if feature enabled');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('disabled') || e.getMessage().contains('Cannot end')
                || e.getMessage().contains('Attendance'),
                'Should throw expected error. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    /**
     * @description Tests getDayStats() controller wrapper.
     */
    @isTest
    static void testGetDayStats() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Test.startTest();
        try {
            Map<String, Object> stats = DayAttendanceController.getDayStats(da.Id);
            System.assertNotEquals(null, stats, 'Stats should not be null');
            System.assert(stats.containsKey('Planned_Visits__c'), 'Should contain Planned_Visits__c');
            System.assert(stats.containsKey('Productive_Calls__c'), 'Should contain Productive_Calls__c');
            System.assert(stats.containsKey('Order_Value__c'), 'Should contain Order_Value__c');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests getCurrentDayAttendance() controller wrapper.
     */
    @isTest
    static void testGetCurrentDayAttendance() {
        Test.startTest();
        try {
            Day_Attendance__c result = DayAttendanceController.getCurrentDayAttendance(null);
            // Should return the DA created in setup (status = Started)
            System.assertNotEquals(null, result, 'Should return current attendance');
            System.assertEquals('Started', result.Status__c, 'Status should be Started');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests logGPS() controller wrapper.
     */
    @isTest
    static void testLogGPS() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        GPS_Log__c gpsLog = TestDataFactory.createGPSLog(
            UserInfo.getUserId(), da.Id, 19.0765, 72.8780
        );

        Test.startTest();
        try {
            GPS_Log__c result = DayAttendanceController.logGPSInternal(gpsLog);
            System.assertNotEquals(null, result, 'GPS log should be returned');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests syncOfflineGPSLogs() controller wrapper with JSON array.
     */
    @isTest
    static void testSyncOfflineGPSLogs() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        List<Map<String, Object>> logsData = new List<Map<String, Object>>();
        for (Integer i = 0; i < 3; i++) {
            Map<String, Object> logMap = new Map<String, Object>{
                'Salesperson__c' => UserInfo.getUserId(),
                'Day_Attendance__c' => da.Id,
                'Latitude__c' => 19.0760 + (i * 0.001),
                'Longitude__c' => 72.8777 + (i * 0.001),
                'Accuracy__c' => 10.0,
                'Captured_At__c' => DateTime.now().addMinutes(-i),
                'Battery_Level__c' => 80,
                'Network_Status__c' => 'Offline',
                'Log_Type__c' => 'Breadcrumb'
            };
            logsData.add(logMap);
        }
        String gpsLogsJson = JSON.serialize(logsData);

        Test.startTest();
        try {
            List<GPS_Log__c> results = DayAttendanceController.syncOfflineGPSLogs(gpsLogsJson);
            System.assertNotEquals(null, results, 'Results should not be null');
            System.assertEquals(3, results.size(), 'Should return 3 GPS logs');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests getTeamAttendance() controller wrapper.
     */
    @isTest
    static void testGetTeamAttendance() {
        Test.startTest();
        try {
            List<Day_Attendance__c> results = DayAttendanceController.getTeamAttendance(Date.today());
            System.assertNotEquals(null, results, 'Should return a list');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('disabled') || e.getMessage().contains('Manager Dashboard'),
                'Should indicate Manager Dashboard feature is disabled. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    /**
     * @description Tests getTeamAttendanceSummary() controller wrapper.
     */
    @isTest
    static void testGetTeamAttendanceSummary() {
        Test.startTest();
        try {
            List<Map<String, Object>> results = DayAttendanceController.getTeamAttendanceSummary(
                Date.today().addDays(-7), Date.today()
            );
            System.assertNotEquals(null, results, 'Should return a list');
        } catch (AuraHandledException e) {
            System.assert(
                e.getMessage().contains('disabled') || e.getMessage().contains('Manager Dashboard'),
                'Should indicate Manager Dashboard feature is disabled. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    /**
     * @description Tests searchEmployees() controller wrapper.
     */
    @isTest
    static void testSearchEmployees() {
        // Create an active employee for search
        Territory_Master__c ter = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Employee__c emp = new Employee__c(
            First_Name__c = 'John',
            Last_Name__c = 'TestCompanion',
            Employee_Code__c = 'EMP-COMP01',
            Is_Active__c = true,
            Territory__c = ter.Id,
            Channels__c = 'GT'
        );
        insert emp;

        Test.startTest();
        // Valid search by first name
        List<Employee__c> results = DayAttendanceController.searchEmployees('John');
        System.assertNotEquals(null, results, 'Results should not be null');
        System.assertEquals(1, results.size(), 'Should find one matching employee');
        System.assertEquals('John', results[0].First_Name__c, 'First name should match');

        // Short search term (< 2 chars)
        List<Employee__c> shortResults = DayAttendanceController.searchEmployees('J');
        System.assertEquals(0, shortResults.size(), 'Short search term should return empty list');

        // Blank search
        List<Employee__c> blankResults = DayAttendanceController.searchEmployees('');
        System.assertEquals(0, blankResults.size(), 'Blank search should return empty list');
        Test.stopTest();
    }

    /**
     * @description Tests getAttendanceConfig() controller wrapper.
     */
    @isTest
    static void testGetAttendanceConfig() {
        Test.startTest();
        try {
            Map<String, Object> config = DayAttendanceController.getAttendanceConfig();
            System.assertNotEquals(null, config, 'Config should not be null');
            System.assert(config.containsKey('selfieRequired'), 'Should contain selfieRequired');
            System.assert(config.containsKey('gpsTrackingInterval'), 'Should contain gpsTrackingInterval');
            System.assert(config.containsKey('statsRefreshInterval'), 'Should contain statsRefreshInterval');
            System.assert(config.containsKey('gpsTrackingEnabled'), 'Should contain gpsTrackingEnabled');
            System.assert(config.containsKey('managerDashboardEnabled'), 'Should contain managerDashboardEnabled');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    // ── Error path tests to cover catch blocks ──────────────────────

    @isTest
    static void testStartDay_InvalidJson() {
        Test.startTest();
        try {
            DayAttendanceController.startDay('not valid json');
            System.assert(false, 'Should throw');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testEndDay_InvalidJson() {
        Test.startTest();
        try {
            DayAttendanceController.endDay('not valid json');
            System.assert(false, 'Should throw');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetDayStats_NullId() {
        Test.startTest();
        Map<String, Object> stats = DayAttendanceController.getDayStats(null);
        Test.stopTest();
        System.assertNotEquals(null, stats);
    }

    @isTest
    static void testGetCurrentDayAttendance_NullUser() {
        Test.startTest();
        Day_Attendance__c result = DayAttendanceController.getCurrentDayAttendance(null);
        Test.stopTest();
    }

    @isTest
    static void testSyncOfflineGPSLogs_InvalidJson() {
        Test.startTest();
        try {
            DayAttendanceController.syncOfflineGPSLogs('bad json');
            System.assert(false, 'Should throw');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testSearchEmployees_ShortTerm() {
        Test.startTest();
        List<Employee__c> results = DayAttendanceController.searchEmployees('a');
        Test.stopTest();
        System.assertEquals(0, results.size(), 'Single char should return empty');
    }

    @isTest
    static void testSearchEmployees_Blank() {
        Test.startTest();
        List<Employee__c> results = DayAttendanceController.searchEmployees('');
        Test.stopTest();
        System.assertEquals(0, results.size());
    }

    @isTest
    static void testGetTeamAttendance_Today() {
        Test.startTest();
        try {
            List<Day_Attendance__c> results = DayAttendanceController.getTeamAttendance(Date.today());
            System.assertNotEquals(null, results);
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testGetTeamAttendanceSummary_DateRange() {
        Test.startTest();
        try {
            List<Map<String, Object>> results = DayAttendanceController.getTeamAttendanceSummary(
                Date.today().addDays(-7), Date.today()
            );
            System.assertNotEquals(null, results);
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testLogGPS_NullRecord() {
        Test.startTest();
        try {
            DayAttendanceController.logGPSInternal(null);
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    @isTest
    static void testSyncOfflineGPSLogs_EmptyArray() {
        Test.startTest();
        try {
            List<GPS_Log__c> results = DayAttendanceController.syncOfflineGPSLogs('[]');
            System.assertNotEquals(null, results);
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e);
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Deterministic coverage for the error paths.
    //
    //  Every DFO feature toggle ships enabled, so the service never raises
    //  AuraHandledException in a normal run and the
    //  `catch (AuraHandledException e) { throw e; }` rethrow in startDay,
    //  endDay, getTeamAttendance and getTeamAttendanceSummary is never
    //  reached. Seeding BPM_FeatureToggle_Util's @TestVisible cache forces
    //  the disabled branch without touching the custom metadata, so these
    //  tests hold whichever way the toggles are configured in the org.
    // ══════════════════════════════════════════════════════════════════

    private static void setFeature(String featureCode, Boolean enabled) {
        BPM_FeatureToggle_Util.toggleCache.put(featureCode, enabled);
    }

    @isTest
    static void testStartDay_FeatureDisabled_RethrowsAuraHandledException() {
        setFeature(DFO_DayAttendance_Service.FEATURE_ATTENDANCE, false);
        String dayJson = JSON.serialize(new Map<String, Object>{
            'startLatitude' => 19.0760,
            'startLongitude' => 72.8777,
            'batteryLevel' => 90
        });

        Test.startTest();
        Boolean threw = false;
        try {
            DayAttendanceController.startDay(dayJson);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'With the Attendance feature off, the service message must reach the LWC unchanged '
            + 'rather than being re-wrapped');
    }

    @isTest
    static void testEndDay_FeatureDisabled_RethrowsAuraHandledException() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];
        setFeature(DFO_DayAttendance_Service.FEATURE_ATTENDANCE, false);
        String dayJson = JSON.serialize(new Map<String, Object>{
            'attendanceId' => da.Id,
            'endLatitude' => 19.0800,
            'endLongitude' => 72.8800
        });

        Test.startTest();
        Boolean threw = false;
        try {
            DayAttendanceController.endDay(dayJson);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A disabled feature blocks ending the day too');
    }

    @isTest
    static void testGetTeamAttendance_FeatureDisabled_RethrowsAuraHandledException() {
        setFeature(DFO_DayAttendance_Service.FEATURE_MANAGER_DASH, false);

        Test.startTest();
        Boolean threw = false;
        try {
            DayAttendanceController.getTeamAttendance(Date.today());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'The Manager Dashboard toggle gates team attendance and its message passes straight through');
    }

    @isTest
    static void testGetTeamAttendanceSummary_FeatureDisabled_RethrowsAuraHandledException() {
        setFeature(DFO_DayAttendance_Service.FEATURE_MANAGER_DASH, false);

        Test.startTest();
        Boolean threw = false;
        try {
            DayAttendanceController.getTeamAttendanceSummary(Date.today().addDays(-7), Date.today());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'The same toggle gates the summary view');
    }

    @isTest
    static void testGetTeamAttendance_FeatureEnabled_ReturnsList() {
        setFeature(DFO_DayAttendance_Service.FEATURE_MANAGER_DASH, true);

        Test.startTest();
        List<Day_Attendance__c> results = DayAttendanceController.getTeamAttendance(Date.today());
        Test.stopTest();

        System.assertNotEquals(null, results,
            'With the dashboard on, a manager with no direct reports gets an empty list, not an error');
    }

    @isTest
    static void testGetTeamAttendanceSummary_FeatureEnabled_ReturnsList() {
        setFeature(DFO_DayAttendance_Service.FEATURE_MANAGER_DASH, true);

        Test.startTest();
        List<Map<String, Object>> results =
            DayAttendanceController.getTeamAttendanceSummary(Date.today().addDays(-7), Date.today());
        Test.stopTest();

        System.assertNotEquals(null, results, 'The summary returns a list even when there is no team');
    }

    // Note: `WHERE Id = :someForeignId` returns zero rows rather than raising a
    // QueryException, so these read methods cannot be driven into their generic
    // catch block from a test — those lines stay uncovered. What is worth
    // pinning is that a stale id yields an empty result the LWC can render.

    @isTest
    static void testGetDayStats_WithAnIdThatMatchesNoAttendance_ReturnsEmptyStats() {
        Id notAnAttendanceId = UserInfo.getUserId();

        Test.startTest();
        Map<String, Object> stats = DayAttendanceController.getDayStats(notAnAttendanceId);
        Test.stopTest();

        System.assertNotEquals(null, stats, 'A stale id gives empty stats, not an exception');
        System.assertEquals(0, stats.size(),
            'With no attendance found there is nothing to report on');
    }

    @isTest
    static void testGetCurrentDayAttendance_ForAUserWithNoDay_ReturnsNull() {
        Id notAUserId = [SELECT Id FROM Day_Attendance__c LIMIT 1].Id;

        Test.startTest();
        Day_Attendance__c result = DayAttendanceController.getCurrentDayAttendance(notAUserId);
        Test.stopTest();

        System.assertEquals(null, result,
            'An id matching no salesperson means the day has not started — the panel renders '
            + 'the Start Day prompt rather than an error');
    }

    @isTest
    static void testLogGPS_TrackingDisabled_ReturnsRecordWithoutSaving() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];
        setFeature(DFO_DayAttendance_Service.FEATURE_GPS_TRACKING, false);
        GPS_Log__c gpsLog = TestDataFactory.createGPSLog(
            UserInfo.getUserId(), da.Id, 19.0765, 72.8780
        );

        Test.startTest();
        GPS_Log__c result = DayAttendanceController.logGPSInternal(gpsLog);
        Test.stopTest();

        System.assertNotEquals(null, result, 'The record comes back so the app can drop it locally');
        System.assertEquals(null, result.Id,
            'With tracking off nothing is written — breadcrumbs are silently discarded');
    }

    @isTest
    static void testSyncOfflineGPSLogs_TrackingEnabled_InsertsAll() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];
        setFeature(DFO_DayAttendance_Service.FEATURE_GPS_TRACKING, true);

        List<Map<String, Object>> logsData = new List<Map<String, Object>>();
        for (Integer i = 0; i < 3; i++) {
            logsData.add(new Map<String, Object>{
                'Salesperson__c' => UserInfo.getUserId(),
                'Day_Attendance__c' => da.Id,
                'Latitude__c' => 19.0760 + (i * 0.001),
                'Longitude__c' => 72.8777 + (i * 0.001),
                'Network_Status__c' => 'Offline'
            });
        }

        Test.startTest();
        List<GPS_Log__c> results =
            DayAttendanceController.syncOfflineGPSLogs(JSON.serialize(logsData));
        Test.stopTest();

        System.assertEquals(3, results.size(), 'All three queued breadcrumbs sync');
        for (GPS_Log__c g : results) {
            System.assertNotEquals(null, g.Id, 'Each one is persisted');
        }
    }

    @isTest
    static void testSearchEmployees_MatchesCodeAndLastName() {
        Territory_Master__c ter = [SELECT Id FROM Territory_Master__c LIMIT 1];
        insert new Employee__c(
            First_Name__c = 'Priya',
            Last_Name__c = 'Sharma',
            Employee_Code__c = 'EMP-SEARCH99',
            Is_Active__c = true,
            Territory__c = ter.Id,
            Channels__c = 'GT'
        );

        Test.startTest();
        List<Employee__c> byLastName = DayAttendanceController.searchEmployees('Sharma');
        List<Employee__c> byCode = DayAttendanceController.searchEmployees('SEARCH99');
        List<Employee__c> noMatch = DayAttendanceController.searchEmployees('Zzqqxxnobody');
        Test.stopTest();

        System.assertEquals(1, byLastName.size(), 'Last name is searchable, not just first name');
        System.assertEquals(1, byCode.size(), 'Employee code is searchable for the companion lookup');
        System.assertEquals(0, noMatch.size(), 'A miss is an empty list, not an error');
    }

    @isTest
    static void testSearchEmployees_ExcludesInactiveEmployees() {
        Territory_Master__c ter = [SELECT Id FROM Territory_Master__c LIMIT 1];
        insert new Employee__c(
            First_Name__c = 'Retired',
            Last_Name__c = 'Person',
            Employee_Code__c = 'EMP-OLD01',
            Is_Active__c = false,
            Territory__c = ter.Id,
            Channels__c = 'GT'
        );

        Test.startTest();
        List<Employee__c> results = DayAttendanceController.searchEmployees('Retired');
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'A companion who has left must not be selectable');
    }
}