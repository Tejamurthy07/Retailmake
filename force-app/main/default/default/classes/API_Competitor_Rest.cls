/**
 * @description REST API for Competitor operations (create competitor records).
 *              Assumes Competitor__c object exists in org.
 * @author Praveen Kumar
 * @date 2026-04-02
 */
@RestResource(urlMapping='/competitor/*')
global without sharing class API_Competitor_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/create')) {
                doCreateCompetitors(req);
            } else if (path.endsWith('/list')) {
                doListCompetitors(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint. Use /competitor/create or /competitor/list');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    /**
     * @description Creates Competitor__c records from payload.
     * @param req RestRequest with JSON body containing accountId, userId, visitId, competitors array
     */
    private static void doCreateCompetitors(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String accountId = (String) input.get('accountId');
            String userId = (String) input.get('userId');
            String visitId = (String) input.get('visitId');
            List<Object> competitorsRaw = (List<Object>) input.get('competitors');

            if (String.isBlank(accountId)) {
                API_ResponseWrapper.sendError('accountId is required.');
                return;
            }
            if (String.isBlank(userId)) {
                API_ResponseWrapper.sendError('userId is required.');
                return;
            }
            if (String.isBlank(visitId)) {
                API_ResponseWrapper.sendError('visitId is required.');
                return;
            }
            if (competitorsRaw == null || competitorsRaw.isEmpty()) {
                API_ResponseWrapper.sendError('competitors array is required and cannot be empty.');
                return;
            }

            List<Employee__c> employees = [SELECT Id FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found.');
                return;
            }
            Id empId = employees[0].Id;

            List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountId LIMIT 1];
            if (accounts.isEmpty()) {
                API_ResponseWrapper.sendError('Account not found.');
                return;
            }
            Id accId = accounts[0].Id;

            List<Visit__c> visits = [SELECT Id,Account__c FROM Visit__c WHERE Name = :visitId  LIMIT 1];
            if (visits.isEmpty()) {
                API_ResponseWrapper.sendError('Visit not found.');
                return;
            }
            Id visitRecId = visits[0].Id;

            List<Competitor__c> competitorsToInsert = new List<Competitor__c>();
            for (Object compRaw : competitorsRaw) {
                Map<String, Object> comp = (Map<String, Object>) compRaw;
                String competitorName = (String) comp.get('competitorName');
                String productId = (String) comp.get('productId');
                String productName = (String) comp.get('productName');
                Decimal discountPercentage = comp.containsKey('discountPercentage') && comp.get('discountPercentage') != null ? (Decimal) comp.get('discountPercentage') : null;
                Decimal price = comp.containsKey('price') && comp.get('price') != null ? (Decimal) comp.get('price') : null;
                String remarks = (String) comp.get('remarks');

                if (String.isBlank(competitorName)) {
                    API_ResponseWrapper.sendError('competitorName is required for each competitor.');
                    return;
                }
                if (String.isBlank(productId)) {
                    API_ResponseWrapper.sendError('productId is required for each competitor.');
                    return;
                }

                List<Product_Extension__c> products = [SELECT Id FROM Product_Extension__c WHERE HSN_SAC_Code__c = :productId LIMIT 1];
                if (products.isEmpty()) {
                    API_ResponseWrapper.sendError('Product not found for productId: ' + productId);
                    return;
                }
                Id prodId = products[0].Id;

                Competitor__c compRec = new Competitor__c(
                    Account__c = visits[0].Account__c,
                   // Employee__c = empId,
                    Visit__c = visitRecId,
                    Name = competitorName,
                    Own_Product_Ext__c = prodId,
                   // Product_Name__c = productName,
                    Shelf_Percent__c = discountPercentage,
                    Competitor_Price__c = price,
                    Notes__c = remarks
                );
                competitorsToInsert.add(compRec);
            }

            insert competitorsToInsert;

            List<String> competitorIds = new List<String>();
            for (Competitor__c c : competitorsToInsert) {
                competitorIds.add(c.Id);
            }

            API_ResponseWrapper.sendSuccess('Competitors created successfully', new Map<String, Object>{'competitorIds' => competitorIds});
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    /**
     * @description Lists competitors for user/account/visit.
     * @param req RestRequest with JSON body {"userId":"...","siteVisitId":"...","accountId":"..."}
     */
    private static void doListCompetitors(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String userId = (String) input.get('userId');
            String siteVisitId = (String) input.get('siteVisitId');
            String accountId = (String) input.get('accountId');

            if (String.isBlank(userId)) {
                API_ResponseWrapper.sendError('userId is required.');
                return;
            }
            if (String.isBlank(siteVisitId)) {
                API_ResponseWrapper.sendError('siteVisitId is required.');
                return;
            }
            if (String.isBlank(accountId)) {
                API_ResponseWrapper.sendError('accountId is required.');
                return;
            }

            List<Employee__c> employees = [SELECT Id FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found.');
                return;
            }
            Id empId = employees[0].Id;

            List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountId LIMIT 1];
            if (accounts.isEmpty()) {
                API_ResponseWrapper.sendError('Account not found.');
                return;
            }
            Id accId = accounts[0].Id;

            List<Visit__c> visits = [SELECT Id,Account__c FROM Visit__c WHERE Name = :siteVisitId  LIMIT 1];
            if (visits.isEmpty()) {
                API_ResponseWrapper.sendError('Visit not found.');
                return;
            }
            Id visitRecId = visits[0].Id;

            List<Competitor__c> competitors = [
                SELECT Id, Name, Own_Product_Ext__r.Name, Shelf_Percent__c, Competitor_Price__c, Notes__c, CreatedDate
                FROM Competitor__c
                WHERE  Account__c = :visits[0].Account__c
                  AND Visit__c = :visitRecId
                ORDER BY CreatedDate DESC
            ];

            List<Map<String, Object>> competitorList = new List<Map<String, Object>>();
            for (Competitor__c c : competitors) {
                String createdDateTime = c.CreatedDate != null ? c.CreatedDate.format('yyyy-MM-dd\'T\'HH:mm:ss') : null;
                competitorList.add(new Map<String, Object>{
                    'competitorId' => c.Id,
                    'competitorName' => c.Name,
                    'productId' => c.Own_Product_Ext__r != null ? c.Own_Product_Ext__r.Name : null,
                    'productName' => c.Own_Product_Ext__r.Name,
                    'discountPercentage' => c.Shelf_Percent__c,
                    'price' => c.Competitor_Price__c,
                    'remarks' => c.Notes__c,
                    'createdDateTime' => createdDateTime
                });
            }

            Map<String, Object> data = new Map<String, Object>{
                'accountName' => accountId,
                'totalRecords' => competitors.size()
            };

            Map<String, Object> response = new Map<String, Object>{
                'status' => true,
                'message' => 'Competitor details fetched successfully',
                'data' => data,
                'competitorList' => competitorList
            };

            RestContext.response.statusCode = 200;
            RestContext.response.responseBody = Blob.valueOf(JSON.serialize(response));
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }
}