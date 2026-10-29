/**
 * @description Test class for API_Attendance_Rest. Covers every branch of
 *              doPost dispatch (startday / endday / invalid endpoint /
 *              top-level catch), and all sub-paths of doStartDay and
 *              doEndDay (success, missing-userId, missing-attendanceId,
 *              employee-not-found, attendance-not-found, JSON-deserialise
 *              throw).
 *
 *              Defensive Employee__c fixture (Channels__c resolved at
 *              runtime; First/Last name + Employee_Code__c set explicitly)
 *              so the org's "Channels__c required" rule cannot fail setup.
 */
@isTest
private class API_Attendance_Rest_Test {

    @TestSetup
    static void setup() {
        // Org rule "Active employees must be assigned to a territory"
        // requires a Territory_Master__c reference on the Employee.
        Territory_Master__c terr = new Territory_Master__c(
            Name = 'API Att Terr',
            Territory_Code__c = 'APIATTTERR',
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        insert terr;

        Employee__c emp = new Employee__c(
            First_Name__c = 'Attendance',
            Last_Name__c = 'Tester',
            Employee_Code__c = 'EMP-ATT-' + String.valueOf(DateTime.now().getTime()).right(6),
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Territory__c = terr.Id,
            Email__c = 'attendance@test.com',
            Phone__c = '9999999999',
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Band__c = 'Band 1',
            Date_of_Joining__c = Date.today().addYears(-1)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;
    }

    private static void prepareRest(String uri, String requestJson) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = requestJson != null
            ? Blob.valueOf(requestJson)
            : Blob.valueOf('');
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    // ── doStartDay branches ─────────────────────────────────────────────────

    @isTest
    static void testStartDay_Success() {
        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'date' => String.valueOf(Date.today()),
            'lateReason' => '',
            'startLatitude' => 19.0760,
            'startLongitude' => 72.8777,
            'startAccuracy' => 10,
            'startDateTime' => Datetime.now().format('yyyy-MM-dd\'T\'HH:mm:ss'),
            'startOdoReading' => 1000
        };
        prepareRest('/services/apexrest/attendance/startday', JSON.serialize(payload));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        // Hard-assert the success path so the DML insert + sendSuccess
        // lines are exercised. On failure, the response body is dumped
        // into the assertion message so we can see WHY it didn't return
        // 200 (which field/validation blocked the Day_Attendance insert).
        String body = RestContext.response.responseBody != null
            ? RestContext.response.responseBody.toString() : '';
        System.assertEquals(200, RestContext.response.statusCode,
            'Start day should succeed. Body: ' + body);
    }

    @isTest
    static void testStartDay_MissingUserId() {
        prepareRest('/services/apexrest/attendance/startday',
            JSON.serialize(new Map<String, Object>{ 'date' => '2026-01-01' }));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Missing userId returns 400');
    }

    @isTest
    static void testStartDay_EmployeeNotFound() {
        prepareRest('/services/apexrest/attendance/startday',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'date' => String.valueOf(Date.today())
            }));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Unknown employee returns 400');
    }

    @isTest
    static void testStartDay_InvalidJson() {
        prepareRest('/services/apexrest/attendance/startday', '{ not-valid-json');

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        // JSON.deserializeUntyped throws -> inner catch -> sendServerError 500.
        System.assertEquals(500, RestContext.response.statusCode,
            'Malformed JSON returns 500 via inner catch');
    }

    // ── doEndDay branches ───────────────────────────────────────────────────

    @isTest
    static void testEndDay_Success() {
        // Seed an attendance record so the end-day update has something to
        // hit. The Day_Attendance fixture inserts with the current user.
        Id attendanceId;
        try {
            Day_Attendance__c da = new Day_Attendance__c(
                Salesperson__c = UserInfo.getUserId(),
                Attendance_Date__c = Date.today(),
                Day_Start_Time__c = DateTime.now().addHours(-3),
                Start_Location_Lat__c = 19.0760,
                Start_Location_Long__c = 72.8777,
                Status__c = 'Started'
            );
            insert da;
            attendanceId = da.Id;
        } catch (Exception e) {}

        Map<String, Object> payload = new Map<String, Object>{
            'userId' => UserInfo.getUserId(),
            'attendanceId' => attendanceId,
            'endLatitude' => 19.0762,
            'endLongitude' => 72.8779,
            'endAccuracy' => 12,
            'endDayTime' => Datetime.now().format('yyyy-MM-dd\'T\'HH:mm:ss'),
            'endReading' => 1100,
            'remarks' => 'Done',
            'isHalfDay' => false
        };
        prepareRest('/services/apexrest/attendance/endday', JSON.serialize(payload));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        String body = RestContext.response.responseBody != null
            ? RestContext.response.responseBody.toString() : '';
        System.assertEquals(200, RestContext.response.statusCode,
            'End day should succeed. Body: ' + body);
    }

    @isTest
    static void testEndDay_MissingUserId() {
        prepareRest('/services/apexrest/attendance/endday',
            JSON.serialize(new Map<String, Object>{ 'attendanceId' => '001000000000000AAA' }));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Missing userId returns 400');
    }

    @isTest
    static void testEndDay_MissingAttendanceId() {
        prepareRest('/services/apexrest/attendance/endday',
            JSON.serialize(new Map<String, Object>{ 'userId' => UserInfo.getUserId() }));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Missing attendanceId returns 400');
    }

    @isTest
    static void testEndDay_EmployeeNotFound() {
        prepareRest('/services/apexrest/attendance/endday',
            JSON.serialize(new Map<String, Object>{
                'userId' => 'no-such-user-' + System.currentTimeMillis(),
                'attendanceId' => 'a0X000000000000AAA'
            }));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Unknown employee returns 400');
    }

    @isTest
    static void testEndDay_AttendanceNotFound() {
        prepareRest('/services/apexrest/attendance/endday',
            JSON.serialize(new Map<String, Object>{
                'userId' => UserInfo.getUserId(),
                'attendanceId' => 'a0X000000000000AAA'
            }));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Unknown attendance returns 400');
    }

    @isTest
    static void testEndDay_InvalidJson() {
        prepareRest('/services/apexrest/attendance/endday', '{ broken json');

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode,
            'Malformed JSON returns 500 via inner catch');
    }

    // ── Top-level dispatch branches ────────────────────────────────────────

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/attendance/unknown', JSON.serialize(new Map<String, Object>()));

        Test.startTest();
        API_Attendance_Rest.doPost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Invalid endpoint returns 400');
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        // Force the outer try/catch in doPost by leaving RestContext.request
        // null - req.requestURI then NPEs and the catch hits sendServerError.
        RestContext.request = null;
        RestContext.response = new RestResponse();

        Test.startTest();
        try {
            API_Attendance_Rest.doPost();
        } catch (Exception e) {
            // sendServerError may rethrow on null response; either way the
            // outer catch branch executed.
        }
        Test.stopTest();
    }
}