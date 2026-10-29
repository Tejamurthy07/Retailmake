/**
 * @description REST API for creating Ticket__c records.
 *              Assumes Ticket__c object and fields exist in org.
 * @author Praveen Kumar
 * @date 2026-04-02
 */
@RestResource(urlMapping='/ticket/*')
global without sharing class API_Ticket_Rest {

    @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/create')) {
                doCreateTicket(req);
            } else if (path.endsWith('/list')) {
                doListTickets(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint. Use /ticket/create or /ticket/list');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    /**
     * @description Creates a Ticket__c from payload.
     * @param req RestRequest with JSON body:
     * {
     *   "userId":"...",
     *   "accountName":"...",
     *   "visitId":"...",
     *   "subject":"...",
     *   "category":"...",
     *   "priority":"...",
     *   "description":"...",
     *   "source":"..."
     * }
     */
    private static void doCreateTicket(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String userId = (String) input.get('userId');
            String accountName = (String) input.get('accountName');
            String visitId = (String) input.get('visitId');
            String subject = (String) input.get('subject');
            String category = (String) input.get('category');
            String priority = (String) input.get('priority');
            String description = (String) input.get('description');
            String source = (String) input.get('source');

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
            if (String.isBlank(subject)) {
                API_ResponseWrapper.sendError('subject is required.');
                return;
            }
            if (String.isBlank(category)) {
                API_ResponseWrapper.sendError('category is required.');
                return;
            }
            if (String.isBlank(priority)) {
                API_ResponseWrapper.sendError('priority is required.');
                return;
            }
            

            List<Employee__c> employees = [SELECT Id,User__c FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found for userId.');
                return;
            }
            Id employeeId = employees[0].Id;

            List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
            if (accounts.isEmpty()) {
                API_ResponseWrapper.sendError('Account not found for accountName.');
                return;
            }
            Id accountId = accounts[0].Id;

            List<Visit__c> visits = [SELECT Id,Account__c FROM Visit__c WHERE Name = :visitId  LIMIT 1];
            if (visits.isEmpty()) {
                API_ResponseWrapper.sendError('Visit not found for visitId.');
                return;
            }
            Id visitRecordId = visits[0].Id;

            Ticket__c ticket = new Ticket__c(
               Reported_By__c = employees[0].User__c,
                Account__c = visits[0].Account__c,
                Visit__c = visitRecordId,
                Subject__c = subject,
                Category__c = category,
                Priority__c = priority,
                Description__c = description
               // Source__c = source
            );
            insert ticket;

            API_ResponseWrapper.sendSuccess('Ticket created successfully', new Map<String, Object>{'ticketId' => ticket.Id});
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    /**
     * @description Lists tickets for user/account/visit.
     * @param req RestRequest with JSON body: {"userId":"...", "siteVisitId":"...", "accountId":"..."}
     */
    private static void doListTickets(RestRequest req) {
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

            List<Ticket__c> tickets = [
                SELECT Id, Name, Subject__c, Category__c, Priority__c, Status__c, CreatedDate
                FROM Ticket__c
                WHERE Reported_By__c = :employees[0].User__c
                  AND Account__c = :visits[0].Account__c
                  AND Visit__c = :visitRecId
                ORDER BY CreatedDate DESC
            ];

            List<Map<String, Object>> ticketList = new List<Map<String, Object>>();
            for (Ticket__c t : tickets) {
                String priorityColor = '#4CAF50'; // default Low
                String indicatorColor = '#4CAF50';
                if (t.Priority__c == 'High') {
                    priorityColor = '#FFA500';
                    indicatorColor = '#FFA500';
                } else if (t.Priority__c == 'Medium') {
                    priorityColor = '#FFFF00';
                    indicatorColor = '#FFFF00';
                }
                String statusColor = '#00AEEF'; // Open
                if (t.Status__c == 'Closed') {
                    statusColor = '#808080';
                }

                String createdDateTime = t.CreatedDate != null ? t.CreatedDate.format('yyyy-MM-dd\'T\'HH:mm:ss') : null;
                String displayDateTime = t.CreatedDate != null ? t.CreatedDate.format('M/d hh:mm a') : null;

                ticketList.add(new Map<String, Object>{
                    'ticketId' => t.Name,
                    'subject' => t.Subject__c,
                    'category' => t.Category__c,
                    'priority' => t.Priority__c,
                    'priorityColor' => priorityColor,
                    'status' => t.Status__c,
                    'statusColor' => statusColor,
                    'createdDateTime' => createdDateTime,
                    'displayDateTime' => displayDateTime,
                    'indicatorColor' => indicatorColor
                });
            }

            Map<String, Object> data = new Map<String, Object>{
                'userId' => userId,
                'accountName' => accountId,
                'totalTickets' => tickets.size(),
                'tickets' => ticketList
            };

            API_ResponseWrapper.sendSuccess('Ticket list fetched successfully', data);
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }
}