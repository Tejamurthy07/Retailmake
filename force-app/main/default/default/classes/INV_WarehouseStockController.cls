/**
 * @description LWC Controller for the Warehouse Stock Dashboard.
 *              Provides KPIs, paginated stock data, transaction logs,
 *              low stock alerts, and warehouse selection.
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class INV_WarehouseStockController {

    /**
     * @description Gets warehouse stock KPI summary for a given warehouse.
     * @param warehouseId Optional warehouse filter.
     * @return WarehouseStockKPIs wrapper with totals.
     */
    @AuraEnabled(cacheable=true)
    public static WarehouseStockKPIs getWarehouseStockKPIs(Id warehouseId) {
        WarehouseStockKPIs kpis = new WarehouseStockKPIs();

        String query = 'SELECT COUNT(Id) recordCount, ' +
                       'SUM(Qty_On_Hand__c) totalOnHand, ' +
                       'SUM(Qty_Reserved__c) totalReserved, ' +
                       'SUM(Qty_Damaged__c) totalDamaged ' +
                       'FROM Warehouse_Stock__c';

        if (warehouseId != null) {
            query += ' WHERE Warehouse__c = :warehouseId';
        }

        AggregateResult[] results = Database.query(query);
        if (!results.isEmpty()) {
            AggregateResult r = results[0];
            kpis.totalSkus = r.get('recordCount') != null ? (Integer) r.get('recordCount') : 0;
            kpis.totalOnHand = r.get('totalOnHand') != null ? (Decimal) r.get('totalOnHand') : 0;
            kpis.totalReserved = r.get('totalReserved') != null ? (Decimal) r.get('totalReserved') : 0;
            kpis.totalDamaged = r.get('totalDamaged') != null ? (Decimal) r.get('totalDamaged') : 0;
            kpis.totalAvailable = kpis.totalOnHand - kpis.totalReserved;
        }

        // Low stock count
        String lowStockQuery = 'SELECT COUNT(Id) cnt FROM Warehouse_Stock__c ' +
                               'WHERE Is_Low_Stock__c = true';
        if (warehouseId != null) {
            lowStockQuery += ' AND Warehouse__c = :warehouseId';
        }
        AggregateResult[] lowResults = Database.query(lowStockQuery);
        kpis.lowStockCount = lowResults[0].get('cnt') != null ? (Integer) lowResults[0].get('cnt') : 0;

        // Zero stock count
        String zeroStockQuery = 'SELECT COUNT(Id) cnt FROM Warehouse_Stock__c ' +
                                'WHERE Is_Zero_Stock__c = true';
        if (warehouseId != null) {
            zeroStockQuery += ' AND Warehouse__c = :warehouseId';
        }
        AggregateResult[] zeroResults = Database.query(zeroStockQuery);
        kpis.zeroStockCount = zeroResults[0].get('cnt') != null ? (Integer) zeroResults[0].get('cnt') : 0;

        return kpis;
    }

    /**
     * @description Gets paginated warehouse stock records with search and filter.
     * @param warehouseId Optional warehouse filter.
     * @param productSearch Optional product name/code search.
     * @param stockFilter Filter type: 'all', 'low', 'zero', 'healthy'.
     * @param limitCount Max records.
     * @param offset Pagination offset.
     * @return WarehouseStockListResult with records and total count.
     */
    @AuraEnabled(cacheable=true)
    public static WarehouseStockListResult getWarehouseStock(
        Id warehouseId,
        String productSearch,
        String stockFilter,
        Integer limitCount,
        Integer offset
    ) {
        limitCount = limitCount != null ? Math.min(limitCount, 100) : 25;
        offset = offset != null ? offset : 0;

        String baseFields = 'SELECT Id, Name, Warehouse__c, Warehouse__r.Name, ' +
                           'Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                           'Batch_Number__c, Expiry_Date__c, Qty_On_Hand__c, ' +
                           'Qty_Reserved__c, Qty_Available__c, Qty_Damaged__c, ' +
                           'Min_Stock_Level__c, Max_Stock_Level__c, ' +
                           'Is_Low_Stock__c, Is_Zero_Stock__c, Last_Transaction_Date__c ';
        String fromClause = 'FROM Warehouse_Stock__c ';
        List<String> conditions = new List<String>();

        if (warehouseId != null) {
            conditions.add('Warehouse__c = :warehouseId');
        }

        if (String.isNotBlank(productSearch)) {
            String searchWild = '%' + String.escapeSingleQuotes(productSearch.trim()) + '%';
            conditions.add('(Product_Ext__r.Name LIKE :searchWild OR Product_Ext__r.SKU_Code__c LIKE :searchWild)');
        }

        if (stockFilter == 'low') {
            conditions.add('Is_Low_Stock__c = true');
        } else if (stockFilter == 'zero') {
            conditions.add('Is_Zero_Stock__c = true');
        } else if (stockFilter == 'healthy') {
            conditions.add('Is_Low_Stock__c = false');
            conditions.add('Is_Zero_Stock__c = false');
        }

        String whereClause = conditions.isEmpty() ? '' : 'WHERE ' + String.join(conditions, ' AND ') + ' ';

        Integer totalCount = Database.countQuery('SELECT COUNT() ' + fromClause + whereClause);

        String dataQuery = baseFields + fromClause + whereClause +
                          'ORDER BY Qty_Available__c ASC NULLS LAST LIMIT :limitCount OFFSET :offset';
        List<Warehouse_Stock__c> records = Database.query(dataQuery);

        WarehouseStockListResult result = new WarehouseStockListResult();
        result.totalCount = totalCount;
        result.records = records;
        return result;
    }

    /**
     * @description Gets list of active warehouses for selector.
     * @return List of Warehouse__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Warehouse__c> getWarehouses() {
        return [
            SELECT Id, Name, Warehouse_Code__c, Warehouse_Type__c, State__c, Is_Active__c
            FROM Warehouse__c
            WHERE Is_Active__c = true
            ORDER BY Name ASC
        ];
    }

    /**
     * @description Gets stock transactions for a warehouse/product.
     * @param warehouseId The warehouse ID.
     * @param productId Optional product filter.
     * @param limitCount Max records.
     * @return List of Stock_Transaction__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Stock_Transaction__c> getStockTransactions(
        Id warehouseId,
        Id productId,
        Integer limitCount
    ) {
        limitCount = limitCount != null ? Math.min(limitCount, 100) : 50;

        String query = 'SELECT Id, Name, Warehouse__c, Warehouse__r.Name, ' +
                       'Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                       'Transaction_Type__c, Quantity__c, Direction__c, ' +
                       'Reference_Type__c, Reference_Id__c, Batch_Number__c, ' +
                       'Running_Balance__c, Transaction_Date__c, ' +
                       'Transaction_By__c, Transaction_By__r.Name, Notes__c ' +
                       'FROM Stock_Transaction__c ';

        List<String> conditions = new List<String>();
        if (warehouseId != null) {
            conditions.add('Warehouse__c = :warehouseId');
        }
        if (productId != null) {
            conditions.add('Product_Ext__c = :productId');
        }

        if (!conditions.isEmpty()) {
            query += 'WHERE ' + String.join(conditions, ' AND ') + ' ';
        }

        query += 'ORDER BY Transaction_Date__c DESC LIMIT :limitCount';

        return Database.query(query);
    }

    /**
     * @description Gets low stock alerts for a warehouse.
     * @param warehouseId Optional warehouse filter.
     * @return List of Warehouse_Stock__c records below minimum stock level.
     */
    @AuraEnabled(cacheable=true)
    public static List<Warehouse_Stock__c> getLowStockAlerts(Id warehouseId) {
        String query = 'SELECT Id, Name, Warehouse__c, Warehouse__r.Name, ' +
                       'Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                       'Qty_On_Hand__c, Qty_Reserved__c, Qty_Available__c, ' +
                       'Min_Stock_Level__c, Max_Stock_Level__c, Is_Zero_Stock__c ' +
                       'FROM Warehouse_Stock__c ' +
                       'WHERE (Is_Low_Stock__c = true OR Is_Zero_Stock__c = true)';

        if (warehouseId != null) {
            query += ' AND Warehouse__c = :warehouseId';
        }

        query += ' ORDER BY Qty_Available__c ASC NULLS FIRST LIMIT 100';

        return Database.query(query);
    }

    /**
     * @description Checks real-time stock availability for a product at a warehouse.
     * @param warehouseId The warehouse ID.
     * @param productId The product ID.
     * @return StockAvailability wrapper.
     */
    @AuraEnabled
    public static StockAvailability checkStockAvailability(Id warehouseId, Id productId) {
        StockAvailability result = new StockAvailability();

        List<Warehouse_Stock__c> stocks = [
            SELECT Id, Qty_On_Hand__c, Qty_Reserved__c, Qty_Available__c, Qty_Damaged__c,
                   Batch_Number__c, Expiry_Date__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :warehouseId
              AND Product_Ext__c = :productId
        ];

        for (Warehouse_Stock__c stock : stocks) {
            result.totalOnHand += stock.Qty_On_Hand__c != null ? stock.Qty_On_Hand__c : 0;
            result.totalReserved += stock.Qty_Reserved__c != null ? stock.Qty_Reserved__c : 0;
            result.totalDamaged += stock.Qty_Damaged__c != null ? stock.Qty_Damaged__c : 0;
        }
        result.totalAvailable = result.totalOnHand - result.totalReserved;

        return result;
    }

    // ── Wrapper Classes ───────────────────────────────────────────────────────

    public class WarehouseStockKPIs {
        @AuraEnabled public Integer totalSkus = 0;
        @AuraEnabled public Decimal totalOnHand = 0;
        @AuraEnabled public Decimal totalReserved = 0;
        @AuraEnabled public Decimal totalAvailable = 0;
        @AuraEnabled public Decimal totalDamaged = 0;
        @AuraEnabled public Integer lowStockCount = 0;
        @AuraEnabled public Integer zeroStockCount = 0;
    }

    public class WarehouseStockListResult {
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public List<Warehouse_Stock__c> records;
    }

    public class StockAvailability {
        @AuraEnabled public Decimal totalOnHand = 0;
        @AuraEnabled public Decimal totalReserved = 0;
        @AuraEnabled public Decimal totalAvailable = 0;
        @AuraEnabled public Decimal totalDamaged = 0;
    }
}