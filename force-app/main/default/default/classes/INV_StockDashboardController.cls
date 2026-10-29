/**
 * @description Controller for the Stock Management Dashboard LWC.
 *              Provides stock overview, low stock alerts, near-expiry tracking,
 *              and stock movement history.
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class INV_StockDashboardController {

    /**
     * @description Gets stock KPI summary across all distributors or for a specific account.
     * @param accountId Optional account filter.
     * @return StockKPIs wrapper with totals.
     */
    @AuraEnabled(cacheable=true)
    public static StockKPIs getStockKPIs(Id accountId) {
        StockKPIs kpis = new StockKPIs();

        String query = 'SELECT COUNT(Id) recordCount, ' +
                       'SUM(Closing_Stock__c) totalClosingStock, ' +
                       'SUM(Opening_Stock__c) totalOpeningStock, ' +
                       'SUM(Received_Qty__c) totalReceived, ' +
                       'SUM(Sold_Qty__c) totalSold, ' +
                       'SUM(Damaged_Qty__c) totalDamaged ' +
                       'FROM Distributor_Stock__c WHERE Is_Current__c = true';

        if (accountId != null) {
            query += ' AND Account__c = :accountId';
        }

        AggregateResult[] results = Database.query(query);
        if (!results.isEmpty()) {
            AggregateResult r = results[0];
            kpis.totalSkus = r.get('recordCount') != null ? (Integer) r.get('recordCount') : 0;
            kpis.totalClosingStock = r.get('totalClosingStock') != null ? (Decimal) r.get('totalClosingStock') : 0;
            kpis.totalOpeningStock = r.get('totalOpeningStock') != null ? (Decimal) r.get('totalOpeningStock') : 0;
            kpis.totalReceived = r.get('totalReceived') != null ? (Decimal) r.get('totalReceived') : 0;
            kpis.totalSold = r.get('totalSold') != null ? (Decimal) r.get('totalSold') : 0;
            kpis.totalDamaged = r.get('totalDamaged') != null ? (Decimal) r.get('totalDamaged') : 0;
        }

        // Low stock count (closing stock <= 10)
        String lowStockQuery = 'SELECT COUNT(Id) cnt FROM Distributor_Stock__c ' +
                               'WHERE Is_Current__c = true AND Closing_Stock__c <= 10 AND Closing_Stock__c > 0';
        if (accountId != null) {
            lowStockQuery += ' AND Account__c = :accountId';
        }
        AggregateResult[] lowResults = Database.query(lowStockQuery);
        kpis.lowStockCount = lowResults[0].get('cnt') != null ? (Integer) lowResults[0].get('cnt') : 0;

        // Zero stock count
        String zeroStockQuery = 'SELECT COUNT(Id) cnt FROM Distributor_Stock__c ' +
                                'WHERE Is_Current__c = true AND Closing_Stock__c = 0';
        if (accountId != null) {
            zeroStockQuery += ' AND Account__c = :accountId';
        }
        AggregateResult[] zeroResults = Database.query(zeroStockQuery);
        kpis.zeroStockCount = zeroResults[0].get('cnt') != null ? (Integer) zeroResults[0].get('cnt') : 0;

        // Near-expiry batch count
        kpis.nearExpiryBatchCount = [
            SELECT COUNT() FROM Batch_Master__c
            WHERE Status__c = 'Active' AND Is_Near_Expiry__c = true
        ];

        return kpis;
    }

    /**
     * @description Gets current stock levels with product and account details.
     * @param accountId Optional account filter.
     * @param productSearch Optional product name search.
     * @param stockFilter Filter type: 'all', 'low', 'zero', 'healthy'.
     * @param limitCount Max records.
     * @param offset Pagination offset.
     * @return StockListResult with records and total count.
     */
    @AuraEnabled(cacheable=true)
    public static StockListResult getCurrentStock(
        Id accountId,
        String productSearch,
        String stockFilter,
        Integer limitCount,
        Integer offset
    ) {
        limitCount = limitCount != null ? Math.min(limitCount, 100) : 25;
        offset = offset != null ? offset : 0;

        String baseFields = 'SELECT Id, Name, Account__c, Account__r.Name, Product_Ext__c, Product_Ext__r.Name, ' +
                           'Product_Ext__r.SKU_Code__c, Stock_Date__c, Opening_Stock__c, Received_Qty__c, ' +
                           'Sold_Qty__c, Damaged_Qty__c, Closing_Stock__c, Batch_No__c, Expiry_Date__c, Is_Current__c ';
        String fromClause = 'FROM Distributor_Stock__c ';
        List<String> conditions = new List<String>{'Is_Current__c = true'};

        if (accountId != null) {
            conditions.add('Account__c = :accountId');
        }

        if (String.isNotBlank(productSearch)) {
            String searchWild = '%' + String.escapeSingleQuotes(productSearch.trim()) + '%';
            conditions.add('(Product_Ext__r.Name LIKE :searchWild OR Product_Ext__r.SKU_Code__c LIKE :searchWild)');
        }

        if (stockFilter == 'low') {
            conditions.add('Closing_Stock__c > 0');
            conditions.add('Closing_Stock__c <= 10');
        } else if (stockFilter == 'zero') {
            conditions.add('Closing_Stock__c = 0');
        } else if (stockFilter == 'healthy') {
            conditions.add('Closing_Stock__c > 10');
        }

        String whereClause = 'WHERE ' + String.join(conditions, ' AND ') + ' ';

        // Count
        Integer totalCount = Database.countQuery('SELECT COUNT() ' + fromClause + whereClause);

        // Data
        String dataQuery = baseFields + fromClause + whereClause +
                          'ORDER BY Closing_Stock__c ASC LIMIT :limitCount OFFSET :offset';
        List<Distributor_Stock__c> records = Database.query(dataQuery);

        StockListResult result = new StockListResult();
        result.totalCount = totalCount;
        result.records = records;
        return result;
    }

    /**
     * @description Gets near-expiry batches with product details.
     * @param daysThreshold Number of days to consider near expiry (default 30).
     * @param limitCount Max records.
     * @return List of Batch_Master__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Batch_Master__c> getNearExpiryBatches(Integer daysThreshold, Integer limitCount) {
        daysThreshold = daysThreshold != null ? daysThreshold : 30;
        limitCount = limitCount != null ? Math.min(limitCount, 100) : 25;
        Date thresholdDate = Date.today().addDays(daysThreshold);

        return [
            SELECT Id, Name, Batch_Number__c, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Manufacturing_Date__c, Expiry_Date__c, Shelf_Life_Remaining_Pct__c,
                   Is_Near_Expiry__c, Status__c, Quantity_Manufactured__c
            FROM Batch_Master__c
            WHERE Status__c = 'Active'
              AND Expiry_Date__c != null
              AND Expiry_Date__c <= :thresholdDate
              AND Expiry_Date__c >= TODAY
            ORDER BY Expiry_Date__c ASC
            LIMIT :limitCount
        ];
    }

    /**
     * @description Gets stock movement history for a specific product at a specific account.
     * @param accountId The distributor account.
     * @param productId The product.
     * @param limitCount Max records.
     * @return List of Distributor_Stock__c records ordered by date.
     */
    @AuraEnabled(cacheable=true)
    public static List<Distributor_Stock__c> getStockMovementHistory(
        Id accountId,
        Id productId,
        Integer limitCount
    ) {
        limitCount = limitCount != null ? Math.min(limitCount, 50) : 20;

        return [
            SELECT Id, Name, Stock_Date__c, Opening_Stock__c, Received_Qty__c,
                   Sold_Qty__c, Damaged_Qty__c, Closing_Stock__c, Batch_No__c, Is_Current__c
            FROM Distributor_Stock__c
            WHERE Account__c = :accountId
              AND Product_Ext__c = :productId
            ORDER BY Stock_Date__c DESC
            LIMIT :limitCount
        ];
    }

    /**
     * @description Gets list of accounts (distributors) that have stock entries.
     * @return List of Account records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Account> getDistributorsWithStock() {
        Set<Id> accountIds = new Set<Id>();
        // Alias the grouped field (aid) so the AggregateResult key is
        // namespace-independent (ftretailmake__Account__c otherwise breaks ar.get).
        for (AggregateResult ar : [
            SELECT Account__c aid FROM Distributor_Stock__c
            WHERE Is_Current__c = true
            GROUP BY Account__c
        ]) {
            accountIds.add((Id) ar.get('aid'));
        }

        if (accountIds.isEmpty()) {
            return new List<Account>();
        }

        return [
            SELECT Id, Name, RecordType.Name
            FROM Account
            WHERE Id IN :accountIds AND Is_Active__c = true
            ORDER BY Name ASC
        ];
    }

    // ── Wrapper Classes ───────────────────────────────────────────────────────

    public class StockKPIs {
        @AuraEnabled public Integer totalSkus = 0;
        @AuraEnabled public Decimal totalClosingStock = 0;
        @AuraEnabled public Decimal totalOpeningStock = 0;
        @AuraEnabled public Decimal totalReceived = 0;
        @AuraEnabled public Decimal totalSold = 0;
        @AuraEnabled public Decimal totalDamaged = 0;
        @AuraEnabled public Integer lowStockCount = 0;
        @AuraEnabled public Integer zeroStockCount = 0;
        @AuraEnabled public Integer nearExpiryBatchCount = 0;
    }

    public class StockListResult {
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public List<Distributor_Stock__c> records;
    }
}