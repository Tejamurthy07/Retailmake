/**
 * @description REST API for User Profile operations (Mobile App).
 *              Covers:
 *                - Login (stub — on hold)
 *                - Get User Profile
 *
 * @author  SFA Development Team
 * @date    2026
 */
@RestResource(urlMapping='/mobile/user/*')
global with sharing class API_UserProfile_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/login')) {
                doLogin(req);
            } else if (path.endsWith('/profile')) {
                doGetProfile(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 1. Login (On Hold) ─────────────────────────────────────────────────

    private static void doLogin(RestRequest req) {
        API_ResponseWrapper.sendError('Login API is currently on hold.');
    }

    // ── 2. Get User Profile ────────────────────────────────────────────────

    private static void doGetProfile(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        String userId = (String) body.get('userId');
        if (String.isBlank(userId)) {
            API_ResponseWrapper.sendError('userId is required.');
            return;
        }

        // Look up Employee by User__c or by Employee Id
        List<Employee__c> employees = [
            SELECT Id, Employee_Code__c,Name, First_Name__c, Last_Name__c,
                   Phone__c, Email__c
            FROM Employee__c
            WHERE User__c = :userId
               OR Name = :userId
            LIMIT 1
        ];

        if (employees.isEmpty()) {
            API_ResponseWrapper.sendError('User not found.');
            return;
        }

        Employee__c emp = employees[0];

        Map<String, Object> data = new Map<String, Object>();
        data.put('userId', emp.Employee_Code__c);
        data.put('name', emp.Name);
        data.put('mobileNumber', emp.Phone__c);
        data.put('emailAddress', emp.Email__c);

        API_ResponseWrapper.sendSuccess('User profile', data);
    }
}