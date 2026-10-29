/**
 * @description REST API for Site Visit operations (Mobile App).
 *              Covers:
 *                - My Site Visit List
 *                - Site Visit Detail
 *                - Add Site Visit
 *
 * @author  Praveen Kumar
 * @date    2026
 */
@RestResource(urlMapping='/mobile/visit/*')
global with sharing class API_Visit_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/list')) {
                doVisitList(req);
            } else if (path.endsWith('/detail')) {
                doVisitDetail(req);
            } else if (path.endsWith('/add')) {
                doAddVisit(req);
            } else if (path.endsWith('/checkin')) {
                doCheckInVisit(req);
            } else if (path.endsWith('/checkout')) {
                doCheckOutVisit(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 4. My Site Visit List ──────────────────────────────────────────────

    private static void doVisitList(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }

        Id sfUserId = resolveUserId(userId);
        if (sfUserId == null) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        String scheduleDateStr = (String) body.get('schdduleDate');
        if (String.isBlank(scheduleDateStr)) {
            scheduleDateStr = (String) body.get('scheduleDate');
        }
        String status = (String) body.get('status');
        Integer pageSize = body.get('pageSize') != null ? ((Decimal) body.get('pageSize')).intValue() : 50;
        if (pageSize <= 0) {
            pageSize = 50;
        }

        // Build dynamic query
        String query = 'SELECT Id, Name, Account__r.Name, Visit_Status__c, Visit_Date__c ' +
                        'FROM Visit__c WHERE Salesperson__c = :sfUserId';

        Date scheduleDate = null;
        if (String.isNotBlank(scheduleDateStr)) {
            try {
                scheduleDate = Date.valueOf(scheduleDateStr);
                query += ' AND Visit_Date__c = :scheduleDate';
            } catch (Exception e) {
                // Ignore invalid date, return all
            }
        }

        if (String.isNotBlank(status)) {
            query += ' AND Visit_Status__c = :status';
        }

        query += ' ORDER BY Visit_Date__c DESC, CreatedDate DESC LIMIT :pageSize';

        List<Visit__c> visits = Database.query(query);

        List<Map<String, Object>> dataList = new List<Map<String, Object>>();
        for (Visit__c v : visits) {
            Map<String, Object> item = new Map<String, Object>();
            item.put('accoutName', v.Account__r != null ? v.Account__r.Name : '');
            item.put('siteVisitId', v.Name != null ? v.Name : '');
            item.put('status', v.Visit_Status__c);
            item.put('scheduleDate', v.Visit_Date__c != null ? String.valueOf(v.Visit_Date__c) : '');
            dataList.add(item);
        }

        API_ResponseWrapper.sendSuccess('Site Visit list fetched successfully', dataList);
    }

    // ── 5. Site Visit Detail ───────────────────────────────────────────────

    private static void doVisitDetail(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        String siteVisitId = (String) body.get('siteVisitId');

        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }
        if (String.isBlank(siteVisitId)) {
            API_ResponseWrapper.sendError('siteVisitId is required.');
            return;
        }

        Id sfUserId = resolveUserId(userId);
        if (sfUserId == null) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        List<Visit__c> visits = [
            SELECT Id, Name, Account__r.Name, Account__r.AccountNumber,
                   Account__r.BillingStreet, Account__r.BillingCity,
                   Account__r.BillingState, Account__r.BillingPostalCode,
                   Visit_Status__c, Visit_Date__c,
                   Check_In_Time__c, Check_Out_Time__c,
                   Check_In_Latitude__c, Check_In_Longitude__c,
                   Is_Planned__c, Ad_Hoc_Reason__c, Notes__c,
                   Order_Value__c, Total_Orders_Count__c,
                   Missed_Reason__c
            FROM Visit__c
            WHERE Name = :siteVisitId
              AND OwnerId = :sfUserId
            LIMIT 1
        ];

        if (visits.isEmpty()) {
            API_ResponseWrapper.sendError('Site Visit not found.');
            return;
        }

        Visit__c v = visits[0];

        Map<String, Object> data = new Map<String, Object>();
        data.put('outletName', v.Account__r != null ? v.Account__r.Name : '');
        data.put('outletCode', v.Account__r != null ? v.Account__r.AccountNumber : '');
        data.put('outletAddress', buildAddress(v));
        data.put('visitType', v.Is_Planned__c ? 'Scheduled' : 'Ad-Hoc');
        data.put('status', v.Visit_Status__c);
        data.put('scheduledDate', v.Visit_Date__c != null ? String.valueOf(v.Visit_Date__c) : null);
        data.put('scheduledTime', v.Check_In_Time__c != null ? v.Check_In_Time__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : null);
        data.put('checkInTime', v.Check_In_Time__c != null ? v.Check_In_Time__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : null);
        data.put('checkOutTime', v.Check_Out_Time__c != null ? v.Check_Out_Time__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') : null);
        data.put('purpose', v.Ad_Hoc_Reason__c);
        data.put('notes', v.Notes__c);
        data.put('latitude', v.Check_In_Latitude__c);
        data.put('longitude', v.Check_In_Longitude__c);
        data.put('hasOrder', v.Total_Orders_Count__c != null && v.Total_Orders_Count__c > 0);
        data.put('orderAmount', v.Order_Value__c != null ? v.Order_Value__c : 0);
        data.put('missedReason', v.Missed_Reason__c);

        API_ResponseWrapper.sendSuccess('Site Visit Detail', data);
    }

    // ── 6. Add Site Visit ──────────────────────────────────────────────────

    private static void doAddVisit(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        String accountId = (String) body.get('accountId');
        String purpose = (String) body.get('purpose');
        String notes = (String) body.get('Notes');

        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }
        if (String.isBlank(accountId)) {
            API_ResponseWrapper.sendError('accountId is required.');
            return;
        }

        Id sfUserId = resolveUserId(userId);
        if (sfUserId == null) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        // Validate account exists
        List<Account> accounts = [SELECT Id FROM Account WHERE Id = :accountId LIMIT 1];
        if (accounts.isEmpty()) {
            API_ResponseWrapper.sendError('Account not found.');
            return;
        }

        Visit__c newVisit = new Visit__c();
        newVisit.Salesperson__c = sfUserId;
        newVisit.Account__c = accountId;
        newVisit.Visit_Date__c = Date.today();
        newVisit.Visit_Status__c = 'Planned';
        newVisit.Is_Planned__c = false;
        newVisit.Is_Ad_Hoc__c = true;
        newVisit.Notes__c = notes;
        newVisit.Purpose__c = purpose;

        insert newVisit;

        API_ResponseWrapper.sendSuccess('Site Visit Created Successfully', null);
    }

    // ── 7. Site Visit Check-In ─────────────────────────────────────────────────────────────────

    private static void doCheckInVisit(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

        String userId = (String) body.get('userId');
        String visitId = (String) body.get('visitId');
        String outletName = (String) body.get('outletName');
        DateTime checkInTimeStr = null;
        String checkInTimeRaw = (String)body.get('checkInTime');
        if (String.isNotBlank(checkInTimeRaw)) {
            try {
                // Parse ISO 8601 format: "2026-04-06T15:30:00Z"
                String formatted = checkInTimeRaw.replace('Z', '').replace('T', ' ');
                checkInTimeStr = DateTime.valueOfGmt(formatted);
            } catch (Exception e) {
                checkInTimeStr = null;
            }
        }
        Decimal checkInLatitude = body.get('checkInlatitude') != null ? (Decimal) body.get('checkInlatitude') : null;
        Decimal checkInLongitude = body.get('checkInlongitude') != null ? (Decimal) body.get('checkInlongitude') : null;
        if (checkInLongitude == null && body.containsKey('CheckInlongitude')) {
            checkInLongitude = body.get('CheckInlongitude') != null ? (Decimal) body.get('CheckInlongitude') : null;
        }
        Decimal checkInAccuracy = body.get('CheckInaccuracy') != null ? (Decimal) body.get('CheckInaccuracy') : null;
        String status = (String) body.get('status');
        Decimal distanceFromOutlet = body.get('distanceFromOutlet') != null ? (Decimal) body.get('distanceFromOutlet') : null;
        Boolean isWithinGeofence = body.get('isWithinGeofence') != null ? (Boolean) body.get('isWithinGeofence') : false;
        String geofenceMessage = (String) body.get('geofenceMessage');

        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }
        if (String.isBlank(visitId)) {
            API_ResponseWrapper.sendError('visitId is required.');
            return;
        }
        if (String.isBlank(outletName)) {
            API_ResponseWrapper.sendError('outletName is required.');
            return;
        }

        Id sfUserId = resolveUserId(userId);
        if (sfUserId == null) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        List<Visit__c> visits = [
            SELECT Id, Account__r.Name, Visit_Status__c
            FROM Visit__c
            WHERE Name = :visitId
              AND OwnerId = :sfUserId
              AND Account__r.Name = :outletName
            LIMIT 1
        ];

        if (visits.isEmpty()) {
            API_ResponseWrapper.sendError('Visit not found for userId/account/outletName.');
            return;
        }

        Visit__c visitRec = visits[0];

        if (checkInTimeStr!=null) {
            try {
                visitRec.Check_In_Time__c = checkInTimeStr;
            } catch (Exception e) {
                API_ResponseWrapper.sendError('Invalid checkInTime format. Use yyyy-MM-ddTHH:mm:ss');
                return;
            }
        }

        if (checkInLatitude != null) visitRec.Check_In_Latitude__c = checkInLatitude;
        if (checkInLongitude != null) visitRec.Check_In_Longitude__c = checkInLongitude;
        if (checkInAccuracy != null) visitRec.Check_In_Accuracy__c = checkInAccuracy;
       // if (String.isNotBlank(status)) visitRec.Visit_Status__c = status;
        if (distanceFromOutlet != null) visitRec.Distance_To_Outlet__c = distanceFromOutlet;
        visitRec.Is_Geo_Fenced__c = isWithinGeofence;
        if (String.isNotBlank(geofenceMessage)) visitRec.Geo_Fence_Override_Reason__c = geofenceMessage;

        update visitRec;

        API_ResponseWrapper.sendSuccess('Visit checked in successfully', null);
    }

    // ── 8. Site Visit Check-Out ─────────────────────────────────────────────────────────────────

    private static void doCheckOutVisit(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

        String userId = (String) body.get('userId');
        String visitId = (String) body.get('visitId');
        String outletName = (String) body.get('outletName');
        if (String.isBlank(outletName)) {
            outletName = (String) body.get('outletName');
        }

        String checkOutTimeStr = (String) body.get('checkOutTime');
        Decimal checkOutLatitude = body.get('checkOutlatitude') != null ? (Decimal) body.get('checkOutlatitude') : null;
        if (checkOutLatitude == null && body.containsKey('lcheckOutongitude')) {
            // fallback if the typo field indicates wrong key; no latitude available there
            checkOutLatitude = body.get('checkOutlatitude') != null ? (Decimal) body.get('checkOutlatitude') : null;
        }
        Decimal checkOutLongitude = body.get('checkOutlongitude') != null ? (Decimal) body.get('checkOutlongitude') : null;
        if (checkOutLongitude == null && body.containsKey('lcheckOutongitude')) {
            checkOutLongitude = body.get('lcheckOutongitude') != null ? (Decimal) body.get('lcheckOutongitude') : null;
        }

        String comments = (String) body.get('comments');

        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }
        if (String.isBlank(visitId)) {
            API_ResponseWrapper.sendError('visitId is required.');
            return;
        }
        if (String.isBlank(outletName)) {
            API_ResponseWrapper.sendError('outletName is required.');
            return;
        }

        Id sfUserId = resolveUserId(userId);
        if (sfUserId == null) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        List<Visit__c> visits = [
            SELECT Id, Account__r.Name
            FROM Visit__c
            WHERE Name = :visitId
              AND OwnerId = :sfUserId
              AND Account__r.Name = :outletName
            LIMIT 1
        ];

        if (visits.isEmpty()) {
            API_ResponseWrapper.sendError('Visit not found for userId/outletName/visitId.');
            return;
        }

        Visit__c visitRec = visits[0];

        if (String.isNotBlank(checkOutTimeStr)) {
            try {
                // Parse ISO 8601 format: "2026-04-06T15:30:00Z"
                String formatted = checkOutTimeStr.replace('Z', '').replace('T', ' ');
                visitRec.Check_Out_Time__c = DateTime.valueOfGmt(formatted);
            } catch (Exception e) {
                API_ResponseWrapper.sendError('Invalid checkOutTime format. Use ISO 8601 format (yyyy-MM-ddTHH:mm:ssZ)');
                return;
            }
        }
/*
        if (checkOutLatitude != null) {
          //  visitRec.Check_Out_Lat__c = checkOutLatitude;
        }
        if (checkOutLongitude != null) {
          //  visitRec.Check_Out_Long__c = checkOutLongitude;
        }
        */
        if (String.isNotBlank(comments)) {
            visitRec.Notes__c = comments;
        }

        update visitRec;

        API_ResponseWrapper.sendSuccess('Visit checked out successfully', null);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private static Id resolveUserId(String userId) {
        List<Employee__c> employees = [
            SELECT Id, User__c FROM Employee__c
            WHERE User__c = :userId OR Name = :userId
            LIMIT 1
        ];
        return employees.isEmpty() ? null : employees[0].User__c;
    }

    private static String buildAddress(Visit__c v) {
        if (v.Account__r == null) {
            return '';
        }
        List<String> parts = new List<String>();
        if (String.isNotBlank(v.Account__r.BillingStreet)) {
            parts.add(v.Account__r.BillingStreet);
        }
        if (String.isNotBlank(v.Account__r.BillingCity)) {
            parts.add(v.Account__r.BillingCity);
        }
        if (String.isNotBlank(v.Account__r.BillingState)) {
            parts.add(v.Account__r.BillingState);
        }
        if (String.isNotBlank(v.Account__r.BillingPostalCode)) {
            parts.add(v.Account__r.BillingPostalCode);
        }
        return String.join(parts, ', ');
    }
}