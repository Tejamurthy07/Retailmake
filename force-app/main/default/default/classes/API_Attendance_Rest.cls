/**
 * @description REST API for Attendance operations in FMCG CRM.
 *              Handles day start/end attendance tracking.
 * @author Praveen Kumar
 * @date 2026-04-02
 *
 * Endpoints:
 *   POST /services/apexrest/attendance/startday - Start day attendance
 *   POST /services/apexrest/attendance/endday   - End day attendance
 */
@RestResource(urlMapping='/attendance/*')
global without sharing class API_Attendance_Rest {
    /**
     * @description Main entry point for Attendance REST API. Routes requests based on endpoint path.
     * @author Praveen Kumar
     */
    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/startday')) {
                doStartDay(req);
            } else if (path.endsWith('/endday')) {
                doEndDay(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 1. Start Day Attendance ───────────────────────────────────────────
    /**
     * @description Starts a new day attendance record for the user.
     *              Validates userId and inserts Day_Attendance__c record with provided details.
     * @param req RestRequest containing: userId, date, isLate, lateByMinutes, lateReason,
     *            startLatitude, startLongitude, startAccuracy, startDateTime, startOdoReading
     * @return 200 with message 'Day Started' and attendanceId, 400 on validation error, 500 on exception
     * @author Praveen Kumar
     */
    private static void doStartDay(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String userId = (String)input.get('userId');
            if (String.isBlank(userId)) {
                API_ResponseWrapper.sendError('userId is required.');
                return;
            }

            // Validate Employee
            List<Employee__c> employees = [SELECT Id,User__c FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found.');
                return;
            }
            Employee__c emp = employees[0];

            // Create Day Attendance record
            Day_Attendance__c da = new Day_Attendance__c();
            da.Salesperson__c = emp.User__c;
            da.Attendance_Date__c = Date.valueOf((String)input.get('date'));
            //da.Is_Late__c = (Boolean)input.get('isLate');
            //da.Late_By_Minutes__c = (Decimal)input.get('lateByMinutes');
            da.Late_Reason__c = (String)input.get('lateReason');
            da.Start_Location_Lat__c = (Decimal)input.get('startLatitude');
            da.Start_Location_Long__c = (Decimal)input.get('startLongitude');
            da.Start_Accuracy__c = (Decimal)input.get('startAccuracy');
            da.Day_Start_Time__c = DateTime.valueOf(((String)input.get('startDateTime')).replace('T', ' '));
            da.Odometer_Start__c = (Decimal)input.get('startOdoReading');
            insert da;

            API_ResponseWrapper.sendSuccess('Day Started', new Map<String, Object>{'attendanceId' => da.Id});
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 2. End Day Attendance ────────────────────────────────────────────
    /**
     * @description Ends the day attendance by updating the Day_Attendance__c record.
     *              Validates userId and attendanceId, fetches the record, and updates end details.
     * @param req RestRequest containing: userId, attendanceId, date, isHalfDay, endLatitude, endLongitude,
     *            endAccuracy, endDayTime, endReading, remarks
     * @return 200 with message 'Day Ended', 400 on validation error, 500 on exception
     * @author Praveen Kumar
     */
    private static void doEndDay(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String userId = (String)input.get('userId');
            if (String.isBlank(userId)) {
                API_ResponseWrapper.sendError('userId is required.');
                return;
            }

            String attendanceId = (String)input.get('attendanceId');
            if (String.isBlank(attendanceId)) {
                API_ResponseWrapper.sendError('attendanceId is required.');
                return;
            }

            // Validate Employee
            List<Employee__c> employees = [SELECT Id,User__c FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found.');
                return;
            }
            Employee__c emp = employees[0];

            // Fetch Day Attendance record
            List<Day_Attendance__c> attendances = [SELECT Id FROM Day_Attendance__c WHERE Id = :attendanceId AND Salesperson__c = :emp.User__c LIMIT 1];
            if (attendances.isEmpty()) {
                API_ResponseWrapper.sendError('Attendance record not found.');
                return;
            }

            // Update Day Attendance record
            Day_Attendance__c da = attendances[0];
            da.End_Location_Lat__c = (Decimal)input.get('endLatitude');
            da.End_Location_Long__c = (Decimal)input.get('endLongitude');
            da.End_Accuracy__c = (Decimal)input.get('endAccuracy');
            da.Day_End_Time__c = DateTime.valueOf(((String)input.get('endDayTime')).replace('T', ' '));
            da.Odometer_End__c = (Decimal)input.get('endReading');
            da.Remarks__c = (String)input.get('remarks');
            da.Is_Half_Day__c = (Boolean)input.get('isHalfDay');
            update da;

            API_ResponseWrapper.sendSuccess('Day Ended', new Map<String, Object>{'attendanceId' => da.Id});
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }
}