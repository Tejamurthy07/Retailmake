/**
 * Controller for the Home Page component.
 * Provides summary counts and quick-access data for the dashboard tiles.
 */
public with sharing class HomePageController {

    @AuraEnabled(cacheable=true)
    public static HomePageData getHomePageData() {
        HomePageData data = new HomePageData();
        Id userId = UserInfo.getUserId();
        Date today = Date.today();

        // ── Today's Visits ──
        data.todayVisitCount = [
            SELECT COUNT()
            FROM Visit__c
            WHERE OwnerId = :userId
              AND Visit_Date__c = :today
        ];
        data.completedVisitCount = [
            SELECT COUNT()
            FROM Visit__c
            WHERE OwnerId = :userId
              AND Visit_Date__c = :today
              AND Visit_Status__c = 'Completed'
        ];

        // ── Pending Orders ──
        data.pendingOrderCount = [
            SELECT COUNT()
            FROM Sales_Order__c
            WHERE OwnerId = :userId
              AND Status__c IN ('Draft', 'Pending')
        ];

        // ── Pending Collections ──
        data.pendingCollectionCount = [
            SELECT COUNT()
            FROM Collection__c
            WHERE OwnerId = :userId
              AND Status__c = 'Pending'
        ];

        // ── Open Tickets ──
        data.openTicketCount = [
            SELECT COUNT()
            FROM Ticket__c
            WHERE OwnerId = :userId
              AND Status__c NOT IN ('Closed', 'Resolved')
        ];

        // ── Today's Attendance ──
        List<Day_Attendance__c> att = [
            SELECT Id, Status__c, Day_Start_Time__c
            FROM Day_Attendance__c
            WHERE User__c = :userId
              AND Attendance_Date__c = :today
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        data.isDayStarted = !att.isEmpty();
        data.attendanceStatus = att.isEmpty() ? 'Not Started' : att[0].Status__c;

        // ── Pending Leaves ──
        data.pendingLeaveCount = [
            SELECT COUNT()
            FROM Leave_Request__c
            WHERE OwnerId = :userId
              AND Status__c = 'Pending'
        ];

        // ── Pending Expenses ──
        data.pendingExpenseCount = [
            SELECT COUNT()
            FROM Expense__c
            WHERE OwnerId = :userId
              AND Status__c IN ('Draft', 'Pending')
        ];

        // ── Low Stock Alerts (scoped to current user's records) ──
        data.lowStockAlertCount = [
            SELECT COUNT()
            FROM Distributor_Stock__c
            WHERE Closing_Stock__c <= 10
              AND Closing_Stock__c > 0
              AND OwnerId = :userId
            LIMIT 10000
        ];

        // ── Active Schemes ──
        data.activeSchemeCount = [
            SELECT COUNT()
            FROM Scheme__c
            WHERE Status__c = 'Active'
              AND Start_Date__c <= :today
              AND End_Date__c >= :today
        ];

        // ── Monthly Order Value ──
        Date monthStart = today.toStartOfMonth();
        AggregateResult[] orderAgg = [
            SELECT SUM(Total_Net_Amount__c) totalValue, COUNT(Id) orderCount
            FROM Sales_Order__c
            WHERE OwnerId = :userId
              AND Order_Date__c >= :monthStart
              AND Order_Date__c <= :today
              AND Status__c NOT IN ('Cancelled', 'Rejected')
        ];
        if (!orderAgg.isEmpty() && orderAgg[0].get('totalValue') != null) {
            data.monthlyOrderValue = (Decimal) orderAgg[0].get('totalValue');
            data.monthlyOrderCount = (Integer) orderAgg[0].get('orderCount');
        }

        // ── Monthly Collection Value ──
        AggregateResult[] collAgg = [
            SELECT SUM(Amount__c) totalCollected
            FROM Collection__c
            WHERE OwnerId = :userId
              AND Collection_Date__c >= :monthStart
              AND Collection_Date__c <= :today
              AND Status__c = 'Approved'
        ];
        if (!collAgg.isEmpty() && collAgg[0].get('totalCollected') != null) {
            data.monthlyCollectionValue = (Decimal) collAgg[0].get('totalCollected');
        }

        // ── Pending Return Orders ──
        data.pendingReturnCount = [
            SELECT COUNT()
            FROM Return_Order__c
            WHERE OwnerId = :userId
              AND Status__c IN ('Draft', 'Submitted')
        ];

        // ── Near Expiry Batches (capped to avoid full-org scan) ──
        data.nearExpiryBatchCount = [
            SELECT COUNT()
            FROM Batch_Master__c
            WHERE Status__c = 'Active'
              AND Is_Near_Expiry__c = true
            LIMIT 10000
        ];

        return data;
    }

    public class HomePageData {
        @AuraEnabled public Integer todayVisitCount = 0;
        @AuraEnabled public Integer completedVisitCount = 0;
        @AuraEnabled public Integer pendingOrderCount = 0;
        @AuraEnabled public Integer pendingCollectionCount = 0;
        @AuraEnabled public Integer openTicketCount = 0;
        @AuraEnabled public Boolean isDayStarted = false;
        @AuraEnabled public String attendanceStatus = 'Not Started';
        @AuraEnabled public Integer pendingLeaveCount = 0;
        @AuraEnabled public Integer pendingExpenseCount = 0;
        @AuraEnabled public Integer lowStockAlertCount = 0;
        @AuraEnabled public Integer activeSchemeCount = 0;
        @AuraEnabled public Decimal monthlyOrderValue = 0;
        @AuraEnabled public Integer monthlyOrderCount = 0;
        @AuraEnabled public Decimal monthlyCollectionValue = 0;
        @AuraEnabled public Integer pendingReturnCount = 0;
        @AuraEnabled public Integer nearExpiryBatchCount = 0;
    }
}