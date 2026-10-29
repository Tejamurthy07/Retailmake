/**
 * @description Controller for the Outlet 360-degree View LWC component.
 *              Provides a comprehensive view of an outlet (Account) including details,
 *              KPIs, recent orders, collections, visit history, schemes, stock levels,
 *              credit utilization, and a unified activity timeline.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class OutletThreeSixtyController {

    // ── Get Outlet Details ──────────────────────────────────────────────────────

    /**
     * @description Retrieves full Account details including all standard and custom fields.
     * @param accountId The Account (outlet) Id.
     * @return The Account record with all relevant fields.
     */
    @AuraEnabled(cacheable=true)
    public static Account getOutletDetails(Id accountId) {
        List<Account> accounts = [
            SELECT Id, Name, AccountNumber, RecordType.Name, RecordType.DeveloperName,
                   Type, Industry, Phone, Fax, Website, Description,
                   OwnerId, Owner.Name,
                   BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                   BillingLatitude, BillingLongitude,
                   ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                   Outlet_Type__c, Outlet_Class__c, Channel__c,
                   GSTIN__c, PAN__c, Drug_License_No__c, FSSAI_License_No__c,
                   Owner_Name__c,
                   Beat__c, Beat__r.Name, Beat__r.Beat_Code__c,
                   Territory__c, Territory__r.Name, Territory__r.Territory_Code__c,
                   Outlet_Latitude__c, Outlet_Longitude__c,
                   Credit_Limit__c, Credit_Utilized__c, Outstanding_Balance__c,
                   Visit_Frequency__c, Is_Active__c,
                   Last_Visit_Date__c, Last_Order_Date__c, Last_Order_Value__c,
                   CreatedDate, LastModifiedDate
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        if (accounts.isEmpty()) {
            throw new AuraHandledException('Outlet not found.');
        }
        return accounts[0];
    }

    // ── Get Outlet KPIs ─────────────────────────────────────────────────────────

    /**
     * @description Calculates comprehensive KPIs for an outlet including MTD metrics,
     *              3-month averages, credit utilization, and aging information.
     * @param accountId The Account (outlet) Id.
     * @return Map of KPI metric names to their computed values.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getOutletKPIs(Id accountId) {
        Map<String, Object> kpis = new Map<String, Object>();

        Date today = Date.today();
        Date mtdStart = today.toStartOfMonth();
        Date threeMonthsAgo = today.addMonths(-3);

        // ── MTD Order Metrics ─────────────────────────────────────────────
        AggregateResult[] orderAgg = [
            SELECT COUNT(Id) orderCount, SUM(Total_Net_Amount__c) totalValue
            FROM Sales_Order__c
            WHERE Account__c = :accountId
            AND Order_Date__c >= :mtdStart
            AND Order_Date__c <= :today
            AND Status__c NOT IN ('Cancelled', 'Rejected')
        ];
        Integer mtdOrderCount = 0;
        Decimal mtdOrderValue = 0;
        if (!orderAgg.isEmpty()) {
            mtdOrderCount = orderAgg[0].get('orderCount') != null ? (Integer)orderAgg[0].get('orderCount') : 0;
            Decimal ov = (Decimal)orderAgg[0].get('totalValue');
            mtdOrderValue = ov != null ? ov : 0;
        }
        kpis.put('mtdOrderCount', mtdOrderCount);
        kpis.put('mtdOrderValue', mtdOrderValue);

        // ── MTD Visit Count ───────────────────────────────────────────────
        AggregateResult[] visitAgg = [
            SELECT COUNT(Id) visitCount
            FROM Visit__c
            WHERE (Account__c = :accountId OR Outlet__c = :accountId)
            AND Visit_Date__c >= :mtdStart
            AND Visit_Date__c <= :today
            AND Visit_Status__c = 'Completed'
        ];
        Integer mtdVisitCount = visitAgg.isEmpty() ? 0 : (Integer)visitAgg[0].get('visitCount');
        kpis.put('mtdVisitCount', mtdVisitCount);

        // ── MTD Collection ────────────────────────────────────────────────
        AggregateResult[] collAgg = [
            SELECT SUM(Amount__c) totalCollection
            FROM Collection__c
            WHERE Account__c = :accountId
            AND Collection_Date__c >= :mtdStart
            AND Collection_Date__c <= :today
            AND Status__c != 'Cancelled'
        ];
        Decimal mtdCollection = 0;
        if (!collAgg.isEmpty()) {
            Decimal cv = (Decimal)collAgg[0].get('totalCollection');
            mtdCollection = cv != null ? cv : 0;
        }
        kpis.put('mtdCollection', mtdCollection);

        // ── Outstanding Balance ───────────────────────────────────────────
        AggregateResult[] balAgg = [
            SELECT SUM(Balance_Due__c) totalBalance
            FROM Invoice__c
            WHERE Account__c = :accountId
            AND Balance_Due__c > 0
            AND Status__c NOT IN ('Cancelled', 'Fully Paid')
        ];
        Decimal outstanding = 0;
        if (!balAgg.isEmpty()) {
            Decimal bal = (Decimal)balAgg[0].get('totalBalance');
            outstanding = bal != null ? bal : 0;
        }
        kpis.put('outstandingBalance', outstanding);

        // ── Overdue Amount (past due date) ────────────────────────────────
        AggregateResult[] overdueAgg = [
            SELECT SUM(Balance_Due__c) overdueAmount
            FROM Invoice__c
            WHERE Account__c = :accountId
            AND Balance_Due__c > 0
            AND Due_Date__c < :today
            AND Status__c NOT IN ('Cancelled', 'Fully Paid')
        ];
        Decimal overdueAmount = 0;
        if (!overdueAgg.isEmpty()) {
            Decimal od = (Decimal)overdueAgg[0].get('overdueAmount');
            overdueAmount = od != null ? od : 0;
        }
        kpis.put('overdueAmount', overdueAmount);

        // ── Credit Utilization ────────────────────────────────────────────
        List<Account> accCredit = [
            SELECT Credit_Limit__c, Credit_Utilized__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        if (!accCredit.isEmpty()) {
            Decimal creditLimit = accCredit[0].Credit_Limit__c != null ? accCredit[0].Credit_Limit__c : 0;
            Decimal creditUsed = accCredit[0].Credit_Utilized__c != null ? accCredit[0].Credit_Utilized__c : 0;
            Decimal creditAvailable = creditLimit - creditUsed;
            kpis.put('creditLimit', creditLimit);
            kpis.put('creditUtilized', creditUsed);
            kpis.put('creditAvailable', creditAvailable > 0 ? creditAvailable : 0);
            kpis.put('creditUtilizationPct', creditLimit > 0
                ? ((creditUsed / creditLimit) * 100).setScale(1, RoundingMode.HALF_UP)
                : 0);
        } else {
            kpis.put('creditLimit', 0);
            kpis.put('creditUtilized', 0);
            kpis.put('creditAvailable', 0);
            kpis.put('creditUtilizationPct', 0);
        }

        // ── Average Order Value (last 3 months) ──────────────────────────
        AggregateResult[] avgAgg = [
            SELECT AVG(Total_Net_Amount__c) avgOrderValue, COUNT(Id) totalOrders
            FROM Sales_Order__c
            WHERE Account__c = :accountId
            AND Order_Date__c >= :threeMonthsAgo
            AND Order_Date__c <= :today
            AND Status__c NOT IN ('Cancelled', 'Rejected')
        ];
        if (!avgAgg.isEmpty()) {
            Decimal avgVal = (Decimal)avgAgg[0].get('avgOrderValue');
            kpis.put('avgOrderValue', avgVal != null ? avgVal.setScale(2, RoundingMode.HALF_UP) : 0);
            kpis.put('totalOrders3M', (Integer)avgAgg[0].get('totalOrders'));
        } else {
            kpis.put('avgOrderValue', 0);
            kpis.put('totalOrders3M', 0);
        }

        // ── Average Visit Frequency (per month over 3 months) ────────────
        AggregateResult[] visitFreqAgg = [
            SELECT COUNT(Id) totalVisits
            FROM Visit__c
            WHERE (Account__c = :accountId OR Outlet__c = :accountId)
            AND Visit_Date__c >= :threeMonthsAgo
            AND Visit_Date__c <= :today
            AND Visit_Status__c = 'Completed'
        ];
        Integer totalVisits3M = visitFreqAgg.isEmpty() ? 0 : (Integer)visitFreqAgg[0].get('totalVisits');
        kpis.put('avgVisitsPerMonth', totalVisits3M > 0
            ? (Decimal.valueOf(totalVisits3M) / 3).setScale(1, RoundingMode.HALF_UP)
            : 0);

        // ── Last Order/Visit Dates ────────────────────────────────────────
        List<Sales_Order__c> lastOrder = [
            SELECT Order_Date__c
            FROM Sales_Order__c
            WHERE Account__c = :accountId
            AND Status__c NOT IN ('Cancelled', 'Rejected')
            ORDER BY Order_Date__c DESC
            LIMIT 1
        ];
        kpis.put('lastOrderDate', lastOrder.isEmpty() ? null : lastOrder[0].Order_Date__c);

        List<Visit__c> lastVisit = [
            SELECT Visit_Date__c
            FROM Visit__c
            WHERE (Account__c = :accountId OR Outlet__c = :accountId)
            AND Visit_Status__c = 'Completed'
            ORDER BY Visit_Date__c DESC
            LIMIT 1
        ];
        kpis.put('lastVisitDate', lastVisit.isEmpty() ? null : lastVisit[0].Visit_Date__c);

        return kpis;
    }

    // ── Get Recent Orders ───────────────────────────────────────────────────────

    /**
     * @description Retrieves recent sales orders for an outlet with line item summaries.
     * @param accountId  The Account (outlet) Id.
     * @param limitCount Maximum number of orders to return (default 10, max 100).
     * @return List of Sales_Order__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Sales_Order__c> getRecentOrders(Id accountId, Integer limitCount) {
        Integer queryLimit = (limitCount != null && limitCount > 0) ? limitCount : 10;
        if (queryLimit > 100) {
            queryLimit = 100;
        }

        return [
            SELECT Id, Name, Order_Date__c, Status__c, Order_Type__c,
                   Total_Gross_Amount__c, Total_Discount__c, Total_Tax__c, Total_Net_Amount__c,
                   Total_Items__c, Salesperson__c, Salesperson__r.Name,
                   Delivery_Date__c, Channel__c, Notes__c,
                   (SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                           Quantity__c, Unit_Price__c, Discount_Amount__c, Tax_Amount__c, Line_Total__c
                    FROM Order_Line_Items__r ORDER BY CreatedDate LIMIT 200)
            FROM Sales_Order__c
            WHERE Account__c = :accountId
            ORDER BY Order_Date__c DESC
            LIMIT :queryLimit
        ];
    }

    // ── Get Collection History ──────────────────────────────────────────────────

    /**
     * @description Retrieves recent collection/payment receipts for an outlet.
     * @param accountId  The Account (outlet) Id.
     * @param limitCount Maximum number of collections to return (default 20, max 100).
     * @return List of Collection__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Collection__c> getCollectionHistory(Id accountId, Integer limitCount) {
        Integer queryLimit = (limitCount != null && limitCount > 0) ? limitCount : 20;
        if (queryLimit > 100) {
            queryLimit = 100;
        }

        return [
            SELECT Id, Name, Receipt_Number__c, Collection_Date__c,
                   Amount__c, Payment_Mode__c, Status__c,
                   Cheque_Number__c, Bank_Name__c, Cheque_Date__c,
                   UPI_Reference__c, Transaction_Reference__c,
                   Invoice__c, Invoice__r.Name, Is_On_Account__c,
                   Salesperson__c, Salesperson__r.Name, Notes__c
            FROM Collection__c
            WHERE Account__c = :accountId
            ORDER BY Collection_Date__c DESC
            LIMIT :queryLimit
        ];
    }

    // ── Get Outstanding Balance ─────────────────────────────────────────────────

    /**
     * @description Calculates the total outstanding balance across all unpaid invoices
     *              for a given outlet.
     * @param accountId The Account (outlet) Id.
     * @return The total outstanding Decimal amount.
     */
    @AuraEnabled(cacheable=true)
    public static Decimal getOutstandingBalance(Id accountId) {
        AggregateResult[] results = [
            SELECT SUM(Balance_Due__c) totalBalance
            FROM Invoice__c
            WHERE Account__c = :accountId
            AND Balance_Due__c > 0
            AND Status__c NOT IN ('Cancelled', 'Fully Paid')
        ];
        if (results.isEmpty()) {
            return 0;
        }
        Decimal balance = (Decimal)results[0].get('totalBalance');
        return balance != null ? balance : 0;
    }

    // ── Get Visit History ───────────────────────────────────────────────────────

    /**
     * @description Retrieves recent visit records for an outlet.
     * @param accountId  The Account (outlet) Id.
     * @param limitCount Maximum number of visits to return (default 20, max 100).
     * @return List of Visit__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Visit__c> getVisitHistory(Id accountId, Integer limitCount) {
        Integer queryLimit = (limitCount != null && limitCount > 0) ? limitCount : 20;
        if (queryLimit > 100) {
            queryLimit = 100;
        }

        // Visit__c has two Account lookups (Account__c and Outlet__c). Most
        // service paths populate both, but historical / imported records may
        // have only one set. Match on either to be resilient.
        return [
            SELECT Id, Name, Visit_Date__c, Salesperson__c, Salesperson__r.Name,
                   Check_In_Time__c, Check_Out_Time__c, Duration_Minutes__c,
                   Visit_Status__c, Is_Productive__c, Is_Planned__c,
                   Order_Value__c, Collection_Amount__c, Notes__c,
                   Non_Productive_Reason__c, Visit_Sequence__c,
                   Beat__c, Beat__r.Name
            FROM Visit__c
            WHERE Account__c = :accountId OR Outlet__c = :accountId
            ORDER BY Visit_Date__c DESC, Check_In_Time__c DESC
            LIMIT :queryLimit
        ];
    }

    // ── Get Applicable Schemes ──────────────────────────────────────────────────

    /**
     * @description Retrieves active promotional schemes applicable to this outlet
     *              based on channel, outlet type, and date validity.
     * @param accountId The Account (outlet) Id.
     * @return List of Scheme__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Scheme__c> getApplicableSchemes(Id accountId) {
        List<Account> accounts = [
            SELECT Channel__c, Outlet_Type__c, Territory__r.Region__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        if (accounts.isEmpty()) {
            return new List<Scheme__c>();
        }

        Account acc = accounts[0];
        Date today = Date.today();

        return [
            SELECT Id, Name, Scheme_Code__c, Scheme_Type__c, Description__c,
                   Start_Date__c, End_Date__c, Status__c, Is_Active__c,
                   Applicable_Channel__c, Applicable_Outlet_Type__c,
                   Budget_Amount__c, Budget_Used__c, Budget_Remaining__c,
                   Max_Discount_Cap__c, Is_Stackable__c, Priority__c, Tier__c
            FROM Scheme__c
            WHERE Is_Active__c = true
            AND Status__c = 'Active'
            AND Start_Date__c <= :today
            AND End_Date__c >= :today
            AND (Applicable_Channel__c = null
                 OR Applicable_Channel__c INCLUDES (:acc.Channel__c))
            AND (Applicable_Outlet_Type__c = null
                 OR Applicable_Outlet_Type__c INCLUDES (:acc.Outlet_Type__c))
            ORDER BY Priority__c ASC NULLS LAST, Start_Date__c ASC
        ];
    }

    // ── Get Stock Levels ────────────────────────────────────────────────────────

    /**
     * @description Retrieves current distributor stock levels for this outlet.
     *              Returns the latest stock record per product.
     * @param accountId The Account (outlet) Id.
     * @return List of Distributor_Stock__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Distributor_Stock__c> getStockLevels(Id accountId) {
        return [
            SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Opening_Stock__c, Received_Qty__c, Sold_Qty__c, Damaged_Qty__c,
                   Closing_Stock__c, Batch_No__c, Expiry_Date__c,
                   Stock_Date__c, Is_Current__c
            FROM Distributor_Stock__c
            WHERE Account__c = :accountId
            AND Is_Current__c = true
            ORDER BY Product_Ext__r.Name ASC
        ];
    }

    // ── Get Credit Utilization ──────────────────────────────────────────────────

    /**
     * @description Returns credit limit, utilized amount, available credit, and
     *              utilization percentage for an outlet.
     * @param accountId The Account (outlet) Id.
     * @return Map with creditLimit, creditUtilized, creditAvailable, utilizationPct.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Decimal> getCreditUtilization(Id accountId) {
        Map<String, Decimal> result = new Map<String, Decimal>();

        List<Account> accounts = [
            SELECT Credit_Limit__c, Credit_Utilized__c, Outstanding_Balance__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        if (accounts.isEmpty()) {
            result.put('creditLimit', 0);
            result.put('creditUtilized', 0);
            result.put('creditAvailable', 0);
            result.put('utilizationPct', 0);
            return result;
        }

        Account acc = accounts[0];
        Decimal creditLimit = acc.Credit_Limit__c != null ? acc.Credit_Limit__c : 0;
        Decimal creditUtilized = acc.Credit_Utilized__c != null ? acc.Credit_Utilized__c : 0;
        Decimal creditAvailable = creditLimit - creditUtilized;

        result.put('creditLimit', creditLimit);
        result.put('creditUtilized', creditUtilized);
        result.put('creditAvailable', creditAvailable > 0 ? creditAvailable : 0);
        result.put('utilizationPct', creditLimit > 0
            ? ((creditUtilized / creditLimit) * 100).setScale(1, RoundingMode.HALF_UP)
            : 0);

        return result;
    }

    // ── Get Account Timeline ────────────────────────────────────────────────────

    /**
     * @description Returns a unified activity timeline combining orders, visits,
     *              and collections for the outlet, sorted by date descending.
     * @param accountId  The Account (outlet) Id.
     * @param limitCount Maximum timeline entries (default 30, max 100).
     * @return List of TimelineEntry wrapper objects.
     */
    @AuraEnabled(cacheable=true)
    public static List<TimelineEntry> getAccountTimeline(Id accountId, Integer limitCount) {
        Integer maxEntries = (limitCount != null && limitCount > 0) ? limitCount : 30;
        if (maxEntries > 100) {
            maxEntries = 100;
        }

        List<TimelineEntry> timeline = new List<TimelineEntry>();

        // Orders
        for (Sales_Order__c order : [
            SELECT Id, Name, Order_Date__c, Status__c, Total_Net_Amount__c, Total_Items__c
            FROM Sales_Order__c
            WHERE Account__c = :accountId
            ORDER BY Order_Date__c DESC
            LIMIT :maxEntries
        ]) {
            timeline.add(new TimelineEntry(
                order.Id,
                'Order',
                order.Name,
                'Order placed - ' + (order.Total_Items__c != null ? order.Total_Items__c.intValue() : 0) + ' items',
                order.Order_Date__c,
                order.Total_Net_Amount__c,
                order.Status__c,
                'standard:orders'
            ));
        }

        // Visits
        for (Visit__c visit : [
            SELECT Id, Name, Visit_Date__c, Visit_Status__c, Is_Productive__c,
                   Duration_Minutes__c, Salesperson__r.Name, Order_Value__c, Collection_Amount__c
            FROM Visit__c
            WHERE Account__c = :accountId
            ORDER BY Visit_Date__c DESC
            LIMIT :maxEntries
        ]) {
            String visitDesc = 'Visit by ' + (visit.Salesperson__r != null ? visit.Salesperson__r.Name : 'N/A');
            if (visit.Duration_Minutes__c != null) {
                visitDesc += ' (' + visit.Duration_Minutes__c.intValue() + ' min)';
            }
            timeline.add(new TimelineEntry(
                visit.Id,
                'Visit',
                visit.Name,
                visitDesc,
                visit.Visit_Date__c,
                visit.Order_Value__c,
                visit.Visit_Status__c,
                'standard:visit'
            ));
        }

        // Collections
        for (Collection__c col : [
            SELECT Id, Name, Receipt_Number__c, Collection_Date__c, Amount__c,
                   Payment_Mode__c, Status__c
            FROM Collection__c
            WHERE Account__c = :accountId
            ORDER BY Collection_Date__c DESC
            LIMIT :maxEntries
        ]) {
            timeline.add(new TimelineEntry(
                col.Id,
                'Collection',
                col.Receipt_Number__c != null ? col.Receipt_Number__c : col.Name,
                'Payment via ' + (col.Payment_Mode__c != null ? col.Payment_Mode__c : 'N/A'),
                col.Collection_Date__c,
                col.Amount__c,
                col.Status__c,
                'standard:currency'
            ));
        }

        // Sort by date descending
        timeline.sort();

        // Trim to limit
        if (timeline.size() > maxEntries) {
            List<TimelineEntry> trimmed = new List<TimelineEntry>();
            for (Integer i = 0; i < maxEntries; i++) {
                trimmed.add(timeline[i]);
            }
            return trimmed;
        }

        return timeline;
    }

    // ── Get Tickets ───────────────────────────────────────────────────────────

    @AuraEnabled
    public static List<Ticket__c> getTickets(Id accountId, Integer limitCount) {
        if (limitCount == null) limitCount = 20;
        return [
            SELECT Id, Name, Subject__c, Category__c, Priority__c, Status__c,
                   Ticket_Date__c, Description__c, Resolved_Date__c, Resolution__c
            FROM Ticket__c
            WHERE Account__c = :accountId
            ORDER BY Ticket_Date__c DESC
            LIMIT :limitCount
        ];
    }

    // ── Timeline Entry Wrapper ──────────────────────────────────────────────────

    /**
     * @description Wrapper class for unified timeline entries across different
     *              activity types (Orders, Visits, Collections).
     */
    public class TimelineEntry implements Comparable {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String activityType;
        @AuraEnabled public String title;
        @AuraEnabled public String description;
        @AuraEnabled public Date activityDate;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String status;
        @AuraEnabled public String iconName;

        public TimelineEntry(Id recordId, String activityType, String title,
                           String description, Date activityDate, Decimal amount,
                           String status, String iconName) {
            this.recordId = recordId;
            this.activityType = activityType;
            this.title = title;
            this.description = description;
            this.activityDate = activityDate;
            this.amount = amount;
            this.status = status;
            this.iconName = iconName;
        }

        public Integer compareTo(Object obj) {
            TimelineEntry other = (TimelineEntry)obj;
            if (this.activityDate == null && other.activityDate == null) return 0;
            if (this.activityDate == null) return 1;
            if (other.activityDate == null) return -1;
            // Descending order (newest first)
            if (this.activityDate > other.activityDate) return -1;
            if (this.activityDate < other.activityDate) return 1;
            return 0;
        }
    }
}