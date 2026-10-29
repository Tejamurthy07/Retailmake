/**
 * @description REST API for Account (Outlet) master data (Mobile App).
 *              Covers:
 *                - Account List (active outlets)
 *                - Account Detail by Id
 *
 * @author  SFA Development Team
 * @date    2026
 */
@RestResource(urlMapping='/mobile/account/*')
global with sharing class API_Account_Rest {

    @HttpGet
    global static void handleGet() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/list')) {
                doAccountList();
            } else if (path.endsWith('/detail')) {
                doAccountDetail(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── Account List ──────────────────────────────────────────────────────

    private static void doAccountList() {
        List<Account> accounts = [
            SELECT Id, Name, AccountNumber, Outlet_Type__c, Region__c,Email__c,
                   BillingStreet, BillingCity, BillingState, BillingPostalCode,
                   Phone, Owner_Name__c, Outlet_Latitude__c, Outlet_Longitude__c,
                   Credit_Limit__c, Outstanding_Balance__c, Is_Active__c
            FROM Account
            WHERE Is_Active__c = true
            ORDER BY Name ASC
        ];

        List<Map<String, Object>> dataList = new List<Map<String, Object>>();
        for (Account acc : accounts) {
            dataList.add(buildAccountResponse(acc));
        }

        API_ResponseWrapper.sendSuccess('Accounts fetched successfully', dataList);
    }

    // ── Account Detail ────────────────────────────────────────────────────

    private static void doAccountDetail(RestRequest req) {
        String accountId = req.params.get('accountId');
        if (String.isBlank(accountId)) {
            API_ResponseWrapper.sendError('accountId is required.');
            return;
        }

        List<Account> accounts = [
            SELECT Id, Name, AccountNumber, Outlet_Type__c, Region__c,Email__c,
                   BillingStreet, BillingCity, BillingState, BillingPostalCode,
                   Phone, Owner_Name__c, Outlet_Latitude__c, Outlet_Longitude__c,
                   Credit_Limit__c, Outstanding_Balance__c, Is_Active__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        if (accounts.isEmpty()) {
            API_ResponseWrapper.sendError('Account not found.');
            return;
        }

        API_ResponseWrapper.sendSuccess('Account fetched successfully', buildAccountResponse(accounts[0]));
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static Map<String, Object> buildAccountResponse(Account acc) {
        Map<String, Object> item = new Map<String, Object>();
      //  item.put('_object_name', 'Account');
        item.put('Outlet_Code__c', acc.AccountNumber != null ? acc.AccountNumber : '');
        item.put('Name', acc.Name);
        item.put('Type__c', acc.Outlet_Type__c != null ? acc.Outlet_Type__c : '');
        item.put('Area__c', acc.Region__c != null ? acc.Region__c : '');
        item.put('Address__c', buildAddress(acc));
        item.put('Phone__c', acc.Phone != null ? acc.Phone : '');
        item.put('Email__c', acc.Email__c != null ? acc.Email__c : '');
        item.put('Contact_Person__c', acc.Owner_Name__c != null ? acc.Owner_Name__c : '');
        item.put('Latitude__c', acc.Outlet_Latitude__c);
        item.put('Longitude__c', acc.Outlet_Longitude__c);
        item.put('Credit_Limit__c', acc.Credit_Limit__c != null ? acc.Credit_Limit__c : 0);
        item.put('Outstanding_Amount__c', acc.Outstanding_Balance__c != null ? acc.Outstanding_Balance__c : 0);
        item.put('Is_Active__c', acc.Is_Active__c);
        item.put('accountId', acc.Id);
        return item;
    }

    private static String buildAddress(Account acc) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(acc.BillingStreet)) {
            parts.add(acc.BillingStreet);
        }
        if (String.isNotBlank(acc.BillingCity)) {
            parts.add(acc.BillingCity);
        }
        if (String.isNotBlank(acc.BillingState)) {
            parts.add(acc.BillingState);
        }
        if (String.isNotBlank(acc.BillingPostalCode)) {
            parts.add(acc.BillingPostalCode);
        }
        return String.join(parts, ', ');
    }
}