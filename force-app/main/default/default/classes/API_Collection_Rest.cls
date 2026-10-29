/**
 * @description REST API for creating Collections and linked Invoice records.
 *              Accepts collection header + invoice list payload and creates records.
 * @author Praveen Kumar
 * @date 2026-04-02
 */
@RestResource(urlMapping='/collection/*')
global without sharing class API_Collection_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/create')) {
                doCreateCollection(req);
            } else if (path.endsWith('/list')) {
                doListCollections(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── Create Collection & Invoices ──────────────────────────────────────────
    /**
     * @description Creates a Collection__c record and then invoices linked to sales orders.
     * @param req RestRequest containing JSON payload with collection and invoices (described in requirements)
     * @return 200 success with collectionId and created invoiceIds
     */
    private static void doCreateCollection(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String userId = (String)input.get('userId');
            String accountName = (String)input.get('accountName');
            String visitId = (String)input.get('visitId');
            String collectionDateStr = (String)input.get('collectionDate');
            Decimal totalAmount = (input.containsKey('totalAmount') && input.get('totalAmount') != null) ? (Decimal)input.get('totalAmount') : null;
            String paymentMode = (String)input.get('paymentMode');
            Decimal amountReceived = (input.containsKey('amountReceived') && input.get('amountReceived') != null) ? (Decimal)input.get('amountReceived') : null;
            String referenceNumber = (String)input.get('referenceNumber');
            String remarks = (String)input.get('remarks');

            if (String.isBlank(userId)) {
                API_ResponseWrapper.sendError('userId is required.');
                return;
            }
            if (String.isBlank(accountName)) {
                API_ResponseWrapper.sendError('accountName is required.');
                return;
            }
            if (String.isBlank(visitId)) {
                API_ResponseWrapper.sendError('visitId is required.');
                return;
            }

            if (totalAmount == null || totalAmount <= 0) {
                API_ResponseWrapper.sendError('totalAmount must be greater than zero.');
                return;
            }
            if (amountReceived == null || amountReceived < 0) {
                API_ResponseWrapper.sendError('amountReceived is required.');
                return;
            }

            // Resolve employee
            List<Employee__c> employees = [SELECT Id,User__c FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found.');
                return;
            }
            Employee__c emp = employees[0];

            // Resolve account
            List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
            if (accounts.isEmpty()) {
                API_ResponseWrapper.sendError('Account not found.');
                return;
            }
            Account account = accounts[0];

            // Resolve visit
            List<Visit__c> visits = [SELECT Id,Account__c FROM Visit__c WHERE Name = :visitId ];
            if (visits.isEmpty()) {
                API_ResponseWrapper.sendError('Visit not found for this account.');
                return;
            }
            Visit__c visit = visits[0];

            DateTime collectionDateTime;
            try {
                String normalDate = collectionDateStr.replace('T', ' ').replace('Z', '');
                collectionDateTime = DateTime.valueOfGmt(normalDate);
            } catch (Exception ce) {
                API_ResponseWrapper.sendError('Invalid collectionDate format. Expected ISO datetime.');
                return;
            }

            Collection__c collection = new Collection__c();
            collection.Account__c = visit.Account__c;
            collection.Visit__c = visit.Id;
            collection.Collection_Date__c = collectionDateTime.date();
            collection.Amount__c = totalAmount;
            collection.Payment_Mode__c = paymentMode;
            collection.Receipt_Number__c = referenceNumber;
            collection.Notes__c = remarks;
            collection.Salesperson__c = emp.User__c;
            collection.Status__c = 'Collected';
            insert collection;

            List<Object> invoiceList = (List<Object>)input.get('invoices');
            List<Invoice__c> invoicesToInsert = new List<Invoice__c>();

            if (invoiceList != null && !invoiceList.isEmpty()) {
                Set<String> orderNames = new Set<String>();
                for (Object invObj : invoiceList) {
                    Map<String, Object> invMap = (Map<String, Object>)invObj;
                    String orderId = (String)invMap.get('orderId');
                    if (String.isNotBlank(orderId)) {
                        orderNames.add(orderId);
                    }
                }

                Map<String, Sales_Order__c> orderMap = new Map<String, Sales_Order__c>();
                if (!orderNames.isEmpty()) {
                    System.debug(orderNames);
                    for (Sales_Order__c so : [
                        SELECT Id, Name, Account__c, Visit__c
                        FROM Sales_Order__c
                        WHERE Name IN :orderNames
                          AND Account__c = :visit.Account__c
                          AND Visit__c = :visit.Id
                    ]) {
                        orderMap.put(so.Name, so);
                    }
                }
                System.debug(invoiceList + ' - ' + orderMap + ' - ' + visit.Account__c + ' - ' + visit.Id);
                for (Object invObj : invoiceList) {
                    System.debug('Processing invoice object: ' + invObj);
                    Map<String, Object> invMap = (Map<String, Object>)invObj;
                    String orderName = (String)invMap.get('orderId');
                    String invoiceDateStr = (String)invMap.get('invoiceDate');
                    Decimal invoiceAmount = (invMap.containsKey('invoiceAmount') && invMap.get('invoiceAmount') != null) ? (Decimal)invMap.get('invoiceAmount') : null;
                    Decimal paidAmount = (invMap.containsKey('paidAmount') && invMap.get('paidAmount') != null) ? (Decimal)invMap.get('paidAmount') : null;

                    if (String.isBlank(orderName) || String.isBlank(invoiceDateStr) || invoiceAmount == null || paidAmount == null) {
                       continue;
                    }

                    if (!orderMap.containsKey(orderName)) {
                       continue;
                    }
                        System.debug('Found matching order for invoice: ' + orderName);
                    Sales_Order__c linkedOrder = orderMap.get(orderName);
                    System.debug('Linking invoice to order: ' + linkedOrder.Id);
                    Invoice__c invoice = new Invoice__c();
                    invoice.Account__c = account.Id;
                    invoice.Sales_Order__c = linkedOrder.Id;
                    invoice.Collection__c = collection.Id;
                    invoice.Invoice_Date__c = Date.valueOf(invoiceDateStr);
                    invoice.Total_Amount__c = invoiceAmount;
                    invoice.Balance_Due__c = invoiceAmount - paidAmount;
                   // invoice.Status__c = (invoice.Balance_Due__c != null && invoice.Balance_Due__c == 0) ? 'Fully Paid' : 'Partially Paid';
                    invoice.Net_Amount__c = paidAmount;
                    invoicesToInsert.add(invoice);
                }
                System.debug('Prepared ' + invoicesToInsert.size() + ' invoices to insert.');
                if (!invoicesToInsert.isEmpty()) {
                    insert invoicesToInsert;
                }
            }

            List<Id> createdInvoiceIds = new List<Id>();
            for (Invoice__c iv: invoicesToInsert) {
                createdInvoiceIds.add(iv.Id);
            }

            Map<String, Object> resultData = new Map<String, Object>{
                'collectionId' => collection.Id,
                'invoiceIds' => createdInvoiceIds
            };

            API_ResponseWrapper.sendSuccess('Collection created successfully', resultData);
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── Fetch Collection Summary ─────────────────────────────────────────────
    /**
     * @description Returns collection summary for user/account/visit with records list.
     * @param req RestRequest containing userId, siteVisitId, accountId
     */
    private static void doListCollections(RestRequest req) {
try {
        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

        String userId = (String)input.get('userId');
        String siteVisitId = (String)input.get('siteVisitId');
        String accountId = (String)input.get('accountId');
        
        if(String.isBlank(userId)) {
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

        List<Employee__c> employees = [SELECT Id,User__c FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
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

        List<Collection__c> collections = [
            SELECT Id, Name, Amount__c, Collection_Date__c, Payment_Mode__c, Receipt_Number__c, Status__c,CreatedDAte
            FROM Collection__c
            WHERE Account__c = :visits[0].Account__c
              AND Visit__c = :visitRecId
              AND Salesperson__c = :employees[0].User__c
            ORDER BY Collection_Date__c DESC
        ];

        List<Map<String, Object>> collectionList = new List<Map<String, Object>>();
        Decimal totalAmount = 0;
        String dateFormat = 'yyyy-MM-dd HH:mm:ss';

        for (Collection__c c : collections) {
            collectionList.add(new Map<String, Object>{
                'collectionId' => c.Name,
                'amount' => c.Amount__c,
                'dateTime' => c.CreatedDate != null ? c.CreatedDate : null,
                'mode' => c.Payment_Mode__c,
                'reference' => c.Receipt_Number__c != null ? c.Receipt_Number__c : '',
                'status' => c.Status__c
            });
            totalAmount += (c.Amount__c != null ? c.Amount__c : 0);
        }

        Map<String, Object> data = new Map<String, Object>{
            'userId' => userId,
            'accountName' => accountId,
            'totalNoOfCollections' => collections.size(),
            'totalAmount' => totalAmount,
            'collections' => collectionList
        };

        API_ResponseWrapper.sendSuccess('Collection details fetched successfully', data);
    } catch (Exception e) {
        API_ResponseWrapper.sendServerError(e.getMessage());
    }
    }
}