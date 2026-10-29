/**
 * @description  REST API for Sales Order operations in FMCG CRM.
 *               Provides endpoints to create sales orders, fetch order summaries, and list all orders.
 * @author       Praveen Kumar
 * @date         2026-04-01
 *
 * Endpoints:
 *   POST /services/apexrest/salesorder/create    - Create a new Sales Order with line items
 *   POST /services/apexrest/salesorder/summary   - Get Sales Order summary aggregated by outlets for a visit
 *   POST /services/apexrest/salesorder/allorders - Get all orders as a list for user/visit/account
 */
@RestResource(urlMapping='/salesorder/*')
global without sharing class API_SalesOrder_Rest {
    /**
     * @description Main entry point for Sales Order REST API. Routes requests based on endpoint path.
     *              Supported endpoints: /create, /summary, /allorders
     * @author Praveen Kumar
     */
    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/create')) {
                doCreateSalesOrder(req);
            } else if (path.endsWith('/summary')) {
                doOrderSummary(req);
            } else if (path.endsWith('/allorders')) {
                doAllOrders(req);
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 1. Create Sales Order ──────────────────────────────────────────────
    /**
     * @description Creates a new Sales Order with line items from request payload.
     *              Validates and lookups Account, Visit (optional), and Salesperson.
     *              Inserts Order and its associated Order_Line_Item__c records.
     * @param req RestRequest containing: accountName, orderDate, visitNumber (optional),
     *            userId (optional), summary (subTotal, discountAmount, taxAmount, grandTotal),
     *            items (productName, quantity, unit, pricePerKg, amount)
     * @return 200 with orderId on success, 400 on validation error, 500 on exception
     * @author Praveen Kumar
     */
    private static void doCreateSalesOrder(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            // Validate and lookup Account
            String accountName = (String)input.get('accountName');
            if (String.isBlank(accountName)) {
                API_ResponseWrapper.sendError('accountName is required.');
                return;
            }
            List<Account> accs = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
            if (accs.isEmpty()) {
                API_ResponseWrapper.sendError('Account not found.');
                return;
            }
            Account acc = accs[0];

            // Lookup Visit (optional, fallback to null)
            Id visitId = null;
            if (input.containsKey('visitNumber')) {
                String visitNumber = (String)input.get('visitNumber');
                if (!String.isBlank(visitNumber)) {
                    List<Visit__c> visits = [SELECT Id FROM Visit__c WHERE Name = :visitNumber LIMIT 1];
                    if (!visits.isEmpty()) visitId = visits[0].Id;
                }
            }

            // Lookup User (optional, fallback to null)
            Id userId = null;
            if (input.containsKey('userId')) {
                String userIdStr = (String)input.get('userId');
                if (!String.isBlank(userIdStr)) {
                    List<Employee__c> users = [
                        SELECT Id, User__c FROM Employee__c
                        WHERE User__c = :userIdStr OR Name = :userIdStr
                        LIMIT 1
                    ];
                    if (!users.isEmpty()) userId = users[0].Id;
                }
            }

            Map<String, Object> summary = (Map<String, Object>)input.get('summary');
            if (summary == null) {
                API_ResponseWrapper.sendError('summary is required.');
                return;
            }

            Sales_Order__c so = new Sales_Order__c();
            so.Account__c = acc.Id;
            so.Order_Date__c = Date.valueOf((String)input.get('orderDate'));
            so.Visit__c = visitId;
            so.Salesperson__c = userId;
            so.Total_Gross_Amount__c = (Decimal)summary.get('subTotal');
            so.Total_Discount__c = (Decimal)summary.get('discountAmount');
            so.Total_Tax__c = (Decimal)summary.get('taxAmount');
            so.Total_Net_Amount__c = (Decimal)summary.get('grandTotal');
            so.Status__c = 'Draft';
            insert so;

            // Prepare Order Line Items
            List<Object> items = (List<Object>)input.get('items');
            if (items == null || items.isEmpty()) {
                API_ResponseWrapper.sendError('At least one item is required.');
                return;
            }
            List<Order_Line_Item__c> olis = new List<Order_Line_Item__c>();
            for (Object itemObj : items) {
                Map<String, Object> item = (Map<String, Object>)itemObj;
                String prodName = (String)item.get('productName');
                if (String.isBlank(prodName)) {
                    API_ResponseWrapper.sendError('productName is required for each item.');
                    return;
                }
                List<Product_Extension__c> prods = [SELECT Id FROM Product_Extension__c WHERE Name = :prodName LIMIT 1];
                if (prods.isEmpty()) {
                    API_ResponseWrapper.sendError('Product not found: ' + prodName);
                    return;
                }
                Product_Extension__c prod = prods[0];
                Order_Line_Item__c oli = new Order_Line_Item__c();
                oli.Sales_Order__c = so.Id;
                oli.Product_Ext__c = prod.Id;
                oli.Quantity__c = (Decimal)item.get('quantity');
                oli.UOM__c = (String)item.get('unit');
                oli.Unit_Price__c = (Decimal)item.get('pricePerKg');
                oli.Line_Amount__c = (Decimal)item.get('amount');
                oli.Tax_Rate__c = (summary.containsKey('taxPercentage')) ? (Decimal)summary.get('taxPercentage') : null;
                olis.add(oli);
            }
            insert olis;

            API_ResponseWrapper.sendSuccess('Sales Order created successfully', new Map<String, Object>{'orderId'=>so.Id});
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 2. Order Summary ──────────────────────────────────────────────────
    /**
     * @description Fetches Sales Order summary aggregated by outlet/account for a given visit.
     *              Groups orders by Account and calculates totals (count, value) per outlet.
     * @param req RestRequest containing: userId (Employee__c Name or User__c), 
     *            siteVisitId (Visit__c Name)
     * @return 200 with summaryData including summaryDate, employeName, summary totals, outlets array
     * @author Praveen Kumar
     */
    private static void doOrderSummary(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            // Validate userId
            String userId = (String)input.get('userId');
            if (String.isBlank(userId)) {
                API_ResponseWrapper.sendError('userId is required.');
                return;
            }

            // Validate siteVisitId
            String siteVisitId = (String)input.get('siteVisitId');
            if (String.isBlank(siteVisitId)) {
                API_ResponseWrapper.sendError('siteVisitId is required.');
                return;
            }

            // Lookup Employee
            List<Employee__c> employees = [SELECT Id, Name, User__c FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found.');
                return;
            }
            Employee__c emp = employees[0];
            String empName = emp.Name;

            // Lookup Visit
            List<Visit__c> visits = [SELECT Id, Name, Visit_Date__c FROM Visit__c WHERE Name = :siteVisitId LIMIT 1];
            if (visits.isEmpty()) {
                API_ResponseWrapper.sendError('Site Visit not found.');
                return;
            }
            Visit__c visit = visits[0];

            // Fetch all Sales Orders for this Visit
            List<Sales_Order__c> salesOrders = [
                SELECT Id, Name, Account__c, Account__r.Name, Account__r.AccountNumber, 
                       Total_Net_Amount__c, Status__c, Order_Date__c,
                       (SELECT Id, Product__c, Product__r.Name, Quantity__c, Unit_Price__c, Line_Amount__c FROM Order_Line_Items__r)
                FROM Sales_Order__c
                WHERE Visit__c = :visit.Id
                ORDER BY Order_Date__c DESC
            ];

            // Build summary response
            Map<String, Object> summaryData = new Map<String, Object>();
            summaryData.put('summaryDate', String.valueOf(Date.today()));
            summaryData.put('employeName', empName);

            // Calculate totals
            Decimal totalValue = 0;
            Integer totalOrders = salesOrders.size();
            Map<Id, Map<String, Object>> outletsMap = new Map<Id, Map<String, Object>>();

            for (Sales_Order__c so : salesOrders) {
                Id accId = so.Account__c;
                if (!outletsMap.containsKey(accId)) {
                    Map<String, Object> outletData = new Map<String, Object>();
                    outletData.put('outlateCode', so.Account__r.AccountNumber != null ? so.Account__r.AccountNumber : '');
                    outletData.put('retailerName', so.Account__r.Name);
                    outletData.put('location', '');
                    outletData.put('totalOrders', 0);
                    outletData.put('totalValue', 0.0);
                    outletData.put('orders', new List<Map<String, Object>>());
                    outletsMap.put(accId, outletData);
                }

                Map<String, Object> outletData = outletsMap.get(accId);
                Integer orderCount = (Integer)outletData.get('totalOrders');
                Decimal orderValue = (Decimal)outletData.get('totalValue');
                orderCount++;
                orderValue += so.Total_Net_Amount__c != null ? so.Total_Net_Amount__c : 0;
                outletData.put('totalOrders', orderCount);
                outletData.put('totalValue', orderValue);

                // Build order data
                Map<String, Object> orderData = new Map<String, Object>();
                orderData.put('orderId', so.Name);
                orderData.put('status', so.Status__c);
                
                List<Map<String, Object>> itemsList = new List<Map<String, Object>>();
                for (Order_Line_Item__c oli : so.Order_Line_Items__r) {
                    Map<String, Object> itemData = new Map<String, Object>();
                    itemData.put('productName', oli.Product__r.Name);
                    itemData.put('quantity', oli.Quantity__c);
                    itemData.put('price', oli.Line_Amount__c);
                    itemsList.add(itemData);
                }
                orderData.put('items', itemsList);
                orderData.put('totalAmount', so.Total_Net_Amount__c);

                List<Map<String, Object>> orders = (List<Map<String, Object>>)outletData.get('orders');
                orders.add(orderData);
            }

            // Build summary totals
            Map<String, Object> totals = new Map<String, Object>();
            totals.put('totaloutlets', outletsMap.size());
            totals.put('totalOrders', totalOrders);
            
            for (Map<String, Object> outlet : outletsMap.values()) {
                totalValue += (Decimal)outlet.get('totalValue');
            }
            totals.put('totalValue', totalValue);
            summaryData.put('summary', totals);

            // Add outlets
            List<Map<String, Object>> outletsList = new List<Map<String, Object>>();
            for (Map<String, Object> outlet : outletsMap.values()) {
                outletsList.add(outlet);
            }
            summaryData.put('outlets', outletsList);

            API_ResponseWrapper.sendSuccess('Order Summary Data', summaryData);
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── 3. All Orders for User/Visit/Account ──────────────────────────────
    /**
     * @description Fetches all Sales Orders as a list for a given user, visit, and account.
     *              Returns orders with details: orderId, orderDate, totalItems, totalAmount, 
     *              currency, and status.
     * @param req RestRequest containing: userId (Employee__c Name or User__c),
     *            siteVisitId (Visit__c Name),
     *            accountId (Account Name or AccountNumber)
     * @return 200 with orders array containing order details, 400 on validation error, 500 on exception
     * @author Praveen Kumar
     */
    private static void doAllOrders(RestRequest req) {
        try {
            Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());

            String userId = (String)input.get('userId');
            if (String.isBlank(userId)) {
                API_ResponseWrapper.sendError('userId is required.');
                return;
            }

            String siteVisitId = (String)input.get('siteVisitId');
            if (String.isBlank(siteVisitId)) {
                API_ResponseWrapper.sendError('siteVisitId is required.');
                return;
            }

            String accountId = (String)input.get('accountId');
            if (String.isBlank(accountId)) {
                API_ResponseWrapper.sendError('accountId is required.');
                return;
            }

            // Validate employee
            List<Employee__c> employees = [SELECT Id,User__c FROM Employee__c WHERE Name = :userId OR User__c = :userId LIMIT 1];
            if (employees.isEmpty()) {
                API_ResponseWrapper.sendError('Employee not found.');
                return;
            }

            // Validate visit
            List<Visit__c> visits = [SELECT Id,Account__c FROM Visit__c WHERE Name = :siteVisitId AND OwnerId = :employees[0].User__c
              AND Account__r.Name = :accountId LIMIT 1];
            if (visits.isEmpty()) {
                API_ResponseWrapper.sendError('Site Visit not found.');
                return;
            }
            Visit__c visit = visits[0];
            System.debug('Found visit: ' + visit.Id);
            // Validate account
            List<Account> accounts = [SELECT Id FROM Account WHERE Name = :accountId OR AccountNumber = :accountId LIMIT 1];
            if (accounts.isEmpty()) {
                API_ResponseWrapper.sendError('Account not found.');
                return;
            }
            Account account = accounts[0];
            System.debug('Found account: ' + account.Id);
            List<Sales_Order__c> salesOrders = [
                SELECT Id, Name, Order_Date__c, Total_Net_Amount__c, Status__c,
                       (SELECT Id FROM Order_Line_Items__r)
                FROM Sales_Order__c
                WHERE Visit__c = :visit.Id AND Account__c = :visit.Account__c
                ORDER BY Order_Date__c DESC
            ];

            List<Map<String, Object>> orders = new List<Map<String, Object>>();
            for (Sales_Order__c so : salesOrders) {
                Integer totalItems = (so.Order_Line_Items__r != null) ? so.Order_Line_Items__r.size() : 0;
                String orderDate = (so.Order_Date__c != null)
                    ? DateTime.newInstance(so.Order_Date__c, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd\'T\'HH:mm:ss')
                    : null;

                orders.add(new Map<String, Object>{
                    'orderId' => so.Name,
                    'orderDate' => orderDate,
                    'totalItems' => totalItems,
                    'totalAmount' => so.Total_Net_Amount__c,
                    'currency' => 'INR',
                    'status' => so.Status__c
                });
            }

            Map<String, Object> data = new Map<String, Object>{
                'orders' => orders
            };

            API_ResponseWrapper.sendSuccess('Orders fetched successfully', data);
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }
}