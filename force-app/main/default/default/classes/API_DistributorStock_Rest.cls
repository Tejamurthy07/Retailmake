/**
 * @description REST API for Distributor Stock operations (Mobile App).
 *              Covers:
 *                - Create Distributor Stock entries for inventory tracking
 *                - Stock Summary for a visit
 *
 * @author  Praveen Kumar
 * @date    2026
 */
@RestResource(urlMapping='/mobile/distributor-stock/*')
global with sharing class API_DistributorStock_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/create')) {
                doCreateStock(req);
            } else if (path.endsWith('/summary')) {
                doStockSummary(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── Create Distributor Stock ──────────────────────────────────────────

    private static void doCreateStock(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        // Validate userId
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

        // Validate accountId (accept both 'accountId' and 'accoutnId' for typo resilience)
        String accountId = (String) body.get('accountId');
        if (String.isBlank(accountId)) {
            accountId = (String) body.get('accoutnId');
        }
        if (String.isBlank(accountId)) {
            API_ResponseWrapper.sendError('accountId is required.');
            return;
        }

        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountId LIMIT 1];
        if (accounts.isEmpty()) {
            API_ResponseWrapper.sendError('Account not found.');
            return;
        }
        Id resolvedAccountId = accounts[0].Id;

        // Validate visitId (optional)
        Id resolvedVisitId = null;
        String visitId = (String) body.get('visitId');
        if (String.isNotBlank(visitId)) {
            List<Visit__c> visits = [SELECT Id FROM Visit__c WHERE Id = :visitId OR Name = :visitId LIMIT 1];
            if (!visits.isEmpty()) {
                resolvedVisitId = visits[0].Id;
            }
        }

        // Validate products
        List<Object> products = (List<Object>) body.get('products');
        if (products == null || products.isEmpty()) {
            API_ResponseWrapper.sendError('At least one product is required.');
            return;
        }

        // Collect product names for bulk lookup
        Set<String> productNames = new Set<String>();
        for (Object prodObj : products) {
            Map<String, Object> prod = (Map<String, Object>) prodObj;
            String productName = (String) prod.get('productName');
            if (String.isNotBlank(productName)) {
                productNames.add(productName);
            }
        }

        // Bulk query Product_Extension__c by Name
        Map<String, Id> productNameToId = new Map<String, Id>();
        if (!productNames.isEmpty()) {
            List<Product_Extension__c> prodExts = [
                SELECT Id, Name FROM Product_Extension__c
                WHERE Name IN :productNames
            ];
            for (Product_Extension__c pe : prodExts) {
                productNameToId.put(pe.Name, pe.Id);
            }
        }

        // Build Distributor_Stock__c records
        List<Distributor_Stock__c> stockRecords = new List<Distributor_Stock__c>();
        for (Object prodObj : products) {
            Map<String, Object> prod = (Map<String, Object>) prodObj;
            String productName = (String) prod.get('productName');

            if (String.isBlank(productName)) {
                API_ResponseWrapper.sendError('productName is required for each product.');
                return;
            }

            if (!productNameToId.containsKey(productName)) {
                API_ResponseWrapper.sendError('Product not found: ' + productName);
                return;
            }

            Distributor_Stock__c stock = new Distributor_Stock__c();
            stock.Account__c = resolvedAccountId;
            stock.Product_Ext__c = productNameToId.get(productName);
            stock.Opening_Stock__c = toDecimal(prod.get('openingStock'));
            stock.Closing_Stock__c = toDecimal(prod.get('closingStock'));
            stock.Damaged_Qty__c = toDecimal(prod.get('damagedStock'));
            stock.Visit__c = resolvedVisitId;
            stock.Stock_Date__c = Date.today();
            stock.Is_Current__c = true;
            stock.Visit__c = resolvedVisitId;

            stockRecords.add(stock);
        }

        insert stockRecords;

        API_ResponseWrapper.sendSuccess('Distributor stock created successfully', new Map<String, Object>{
            'totalRecords' => stockRecords.size()
        });
    }

    // ── Stock Summary ─────────────────────────────────────────────────────

    private static void doStockSummary(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            req.requestBody.toString()
        );

        // Validate userId
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

        // Validate siteVisitId
        String siteVisitId = (String) body.get('siteVisitId');
        if (String.isBlank(siteVisitId)) {
            API_ResponseWrapper.sendError('siteVisitId is required.');
            return;
        }

        List<Visit__c> visits = [SELECT Id, Name FROM Visit__c WHERE Name = :siteVisitId LIMIT 1];
        if (visits.isEmpty()) {
            API_ResponseWrapper.sendError('Site Visit not found.');
            return;
        }
        Id resolvedVisitId = visits[0].Id;

        // Validate accountId (accept both 'accountId' and 'accoutnId' for typo resilience)
        String accountId = (String) body.get('accountId');
        if (String.isBlank(accountId)) {
            accountId = (String) body.get('accoutnId');
        }
        if (String.isBlank(accountId)) {
            API_ResponseWrapper.sendError('accountId is required.');
            return;
        }

        List<Account> accounts = [SELECT Id, Name FROM Account WHERE Name = :accountId LIMIT 1];
        if (accounts.isEmpty()) {
            API_ResponseWrapper.sendError('Account not found.');
            return;
        }
        String accountName = accounts[0].Name;
        Id resolvedAccountId = accounts[0].Id;

        // Query Distributor Stock for the account and visit
        List<Distributor_Stock__c> stockRecords = [
            SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name,
                   Opening_Stock__c, Closing_Stock__c, Damaged_Qty__c,
                   Stock_Date__c, CreatedDate
            FROM Distributor_Stock__c
            WHERE Account__c = :resolvedAccountId
              AND Visit__c = :resolvedVisitId
            ORDER BY CreatedDate DESC
        ];

        // Build stock details response
        List<Map<String, Object>> stockDetails = new List<Map<String, Object>>();
        for (Distributor_Stock__c stock : stockRecords) {
            Decimal opening = stock.Opening_Stock__c != null ? stock.Opening_Stock__c : 0;
            Decimal closing = stock.Closing_Stock__c != null ? stock.Closing_Stock__c : 0;
            Decimal damaged = stock.Damaged_Qty__c != null ? stock.Damaged_Qty__c : 0;

            Decimal netStock = closing - opening;
            Object variance = opening > 0 ? opening - (closing + damaged) : null;

            Map<String, Object> detail = new Map<String, Object>();
            detail.put('productId', stock.Product_Ext__c);
            detail.put('productName', stock.Product_Ext__r != null ? stock.Product_Ext__r.Name : '');
            detail.put('stockDateTime', stock.CreatedDate != null ? stock.CreatedDate.format('yyyy-MM-dd\'T\'HH:mm:ss') : null);
            detail.put('openingStock', opening);
            detail.put('closingStock', closing);
            detail.put('damagedStock', damaged);
            detail.put('netStock', netStock);
            detail.put('variance', variance);

            stockDetails.add(detail);
        }

        // Build response envelope
        Map<String, Object> data = new Map<String, Object>();
        data.put('accoutnName', accountName);
        data.put('totalRecords', stockDetails.size());
        data.put('stockDetails', stockDetails);

        API_ResponseWrapper.sendSuccess('Stock details fetched successfully', data);
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

    private static Decimal toDecimal(Object val) {
        if (val == null) return 0;
        if (val instanceof Decimal) return (Decimal) val;
        if (val instanceof Integer) return Decimal.valueOf((Integer) val);
        if (val instanceof Long) return Decimal.valueOf((Long) val);
        if (val instanceof Double) return Decimal.valueOf((Double) val);
        return Decimal.valueOf(String.valueOf(val));
    }
}