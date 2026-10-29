/**
 * @description REST API for My Planner (Mobile App).
 *              Covers:
 *                - My Planner list (visits grouped by date)
 *
 * @author  SFA Development Team
 * @date    2026
 */
@RestResource(urlMapping='/mobile/planner/*')
global with sharing class API_Planner_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/list')) {
                doPlannerList(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 7. My Planner ─────────────────────────────────────────────────────

    private static void doPlannerList(RestRequest req) {
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

        String fromDateStr = (String) body.get('fromDate');
        String toDateStr = (String) body.get('toDate');
        String search = (String) body.get('search');
        Integer pageSize = body.get('pageSize') != null ? ((Decimal) body.get('pageSize')).intValue() : 100;
        if (pageSize <= 0) {
            pageSize = 100;
        }

        // Default date range: current week
        Date fromDate;
        Date toDate;
        try {
            fromDate = String.isNotBlank(fromDateStr) ? Date.valueOf(fromDateStr) : Date.today();
            toDate = String.isNotBlank(toDateStr) ? Date.valueOf(toDateStr) : fromDate.addDays(7);
        } catch (Exception e) {
            fromDate = Date.today();
            toDate = fromDate.addDays(7);
        }

        // Query visits in date range
        String query = 'SELECT Id, Name, Account__r.Name, ' +
                        'Account__r.BillingStreet, Account__r.BillingCity, ' +
                        'Visit_Status__c, Visit_Date__c, Check_In_Time__c ' +
                        'FROM Visit__c ' +
                        'WHERE Salesperson__c = :sfUserId ' +
                        'AND Visit_Date__c >= :fromDate ' +
                        'AND Visit_Date__c <= :toDate';

        if (String.isNotBlank(search)) {
            String searchKey = '%' + String.escapeSingleQuotes(search.trim()) + '%';
            query += ' AND Account__r.Name LIKE :searchKey';
        }

        query += ' ORDER BY Visit_Date__c ASC, Check_In_Time__c ASC NULLS LAST LIMIT :pageSize';

        List<Visit__c> visits = Database.query(query);

        // Group visits by date
        Map<Date, List<Visit__c>> grouped = new Map<Date, List<Visit__c>>();
        for (Visit__c v : visits) {
            Date vDate = v.Visit_Date__c;
            if (!grouped.containsKey(vDate)) {
                grouped.put(vDate, new List<Visit__c>());
            }
            grouped.get(vDate).add(v);
        }

        // Build response sorted by date
        List<Date> sortedDates = new List<Date>(grouped.keySet());
        sortedDates.sort();

        List<Map<String, Object>> dataList = new List<Map<String, Object>>();
        for (Date d : sortedDates) {
            List<Visit__c> dayVisits = grouped.get(d);

            Map<String, Object> dayEntry = new Map<String, Object>();
            dayEntry.put('date', String.valueOf(d));
            dayEntry.put('totalVisits', dayVisits.size());

            List<Map<String, Object>> visitList = new List<Map<String, Object>>();
            for (Visit__c v : dayVisits) {
                Map<String, Object> visitMap = new Map<String, Object>();
                visitMap.put('visitId', v.Name);
                visitMap.put('accountName', v.Account__r != null ? v.Account__r.Name : '');
                visitMap.put('address', buildAddress(v));
                visitMap.put('status', v.Visit_Status__c);
                visitMap.put('scheduledDateTime', v.Check_In_Time__c != null
                    ? v.Check_In_Time__c.format('yyyy-MM-dd\'T\'HH:mm:ss') : '');
                visitList.add(visitMap);
            }

            dayEntry.put('visits', visitList);
            dataList.add(dayEntry);
        }

        API_ResponseWrapper.sendSuccess('Referral list fetched successfully', dataList);
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
        return String.join(parts, ', ');
    }
}