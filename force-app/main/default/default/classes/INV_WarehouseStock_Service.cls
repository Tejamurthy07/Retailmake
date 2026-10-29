/**
 * @description Core service class for all warehouse stock operations. All stock
 *              mutations (add, deduct, reserve, release) must go through this
 *              service to maintain data integrity and audit trail.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class INV_WarehouseStock_Service {

    /**
     * @description Checks available stock for a list of products at a warehouse.
     * @param warehouseId The warehouse to check.
     * @param productIds  List of product IDs to check availability for.
     * @return Map of Product ID to available quantity.
     */
    public static Map<Id, Decimal> checkAvailability(Id warehouseId, List<Id> productIds) {
        Map<Id, Decimal> availabilityMap = new Map<Id, Decimal>();
        for (Id productId : productIds) {
            availabilityMap.put(productId, 0);
        }

        for (Warehouse_Stock__c stock : [
            SELECT Product_Ext__c, Qty_On_Hand__c, Qty_Reserved__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :warehouseId
              AND Product_Ext__c IN :productIds
              AND (Expiry_Date__c = null OR Expiry_Date__c > TODAY)
        ]) {
            Decimal onHand = stock.Qty_On_Hand__c != null ? stock.Qty_On_Hand__c : 0;
            Decimal reserved = stock.Qty_Reserved__c != null ? stock.Qty_Reserved__c : 0;
            Decimal available = onHand - reserved;

            Decimal current = availabilityMap.get(stock.Product_Ext__c);
            availabilityMap.put(stock.Product_Ext__c, current + available);
        }

        return availabilityMap;
    }

    /**
     * @description Reserves stock for confirmed invoices. Increases Qty_Reserved
     *              on the matching Warehouse_Stock__c records.
     * @param warehouseId  The warehouse to reserve stock in.
     * @param items        Line items with product, batch, and quantity.
     * @param referenceId  The source record ID (e.g., Invoice ID).
     */
    public static void reserveStock(Id warehouseId, List<StockLineItem> items, String referenceId) {
        List<Warehouse_Stock__c> stockRecords = getOrCreateStockRecords(warehouseId, items);
        Map<String, Warehouse_Stock__c> stockMap = buildStockMap(stockRecords);

        List<Warehouse_Stock__c> toUpdate = new List<Warehouse_Stock__c>();
        List<Stock_Transaction__c> transactions = new List<Stock_Transaction__c>();

        for (StockLineItem item : items) {
            String key = buildKey(warehouseId, item.productId, item.batchNumber);
            Warehouse_Stock__c stock = stockMap.get(key);
            if (stock == null) {
                continue;
            }

            Decimal reserved = stock.Qty_Reserved__c != null ? stock.Qty_Reserved__c : 0;
            stock.Qty_Reserved__c = reserved + item.quantity;
            stock.Last_Transaction_Date__c = Datetime.now();
            toUpdate.add(stock);

            transactions.add(createTransaction(
                stock, 'Reservation', item.quantity, 'Out',
                'Invoice', referenceId, item.batchNumber,
                stock.Qty_On_Hand__c, 'Stock reserved for invoice'
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!transactions.isEmpty()) {
            insert transactions;
        }
    }

    /**
     * @description Releases previously reserved stock. Decreases Qty_Reserved.
     * @param warehouseId  The warehouse to release reservation in.
     * @param items        Line items with product, batch, and quantity.
     * @param referenceId  The source record ID.
     */
    public static void releaseReservation(Id warehouseId, List<StockLineItem> items, String referenceId) {
        List<Warehouse_Stock__c> stockRecords = queryStockRecords(warehouseId, items);
        Map<String, Warehouse_Stock__c> stockMap = buildStockMap(stockRecords);

        List<Warehouse_Stock__c> toUpdate = new List<Warehouse_Stock__c>();
        List<Stock_Transaction__c> transactions = new List<Stock_Transaction__c>();

        for (StockLineItem item : items) {
            String key = buildKey(warehouseId, item.productId, item.batchNumber);
            Warehouse_Stock__c stock = stockMap.get(key);
            if (stock == null) {
                continue;
            }

            Decimal reserved = stock.Qty_Reserved__c != null ? stock.Qty_Reserved__c : 0;
            stock.Qty_Reserved__c = Math.max(0, reserved - item.quantity);
            stock.Last_Transaction_Date__c = Datetime.now();
            toUpdate.add(stock);

            transactions.add(createTransaction(
                stock, 'Release_Reservation', item.quantity, 'In',
                'Invoice', referenceId, item.batchNumber,
                stock.Qty_On_Hand__c, 'Reservation released'
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!transactions.isEmpty()) {
            insert transactions;
        }
    }

    /**
     * @description Deducts stock from a warehouse. Decreases both Qty_On_Hand
     *              and Qty_Reserved (if previously reserved).
     * @param warehouseId   The warehouse to deduct from.
     * @param items         Line items with product, batch, and quantity.
     * @param referenceId   The source record ID.
     * @param referenceType The type of source record (Invoice, Stock_Transfer, etc.).
     */
    public static void deductStock(Id warehouseId, List<StockLineItem> items, String referenceId, String referenceType) {
        List<Warehouse_Stock__c> stockRecords = queryStockRecords(warehouseId, items);
        Map<String, Warehouse_Stock__c> stockMap = buildStockMap(stockRecords);

        List<Warehouse_Stock__c> toUpdate = new List<Warehouse_Stock__c>();
        List<Stock_Transaction__c> transactions = new List<Stock_Transaction__c>();

        for (StockLineItem item : items) {
            String key = buildKey(warehouseId, item.productId, item.batchNumber);
            Warehouse_Stock__c stock = stockMap.get(key);
            if (stock == null) {
                continue;
            }

            Decimal onHand = stock.Qty_On_Hand__c != null ? stock.Qty_On_Hand__c : 0;
            Decimal reserved = stock.Qty_Reserved__c != null ? stock.Qty_Reserved__c : 0;

            stock.Qty_On_Hand__c = Math.max(0, onHand - item.quantity);
            // Also release the reservation if stock was reserved
            if (reserved > 0) {
                stock.Qty_Reserved__c = Math.max(0, reserved - item.quantity);
            }
            stock.Last_Transaction_Date__c = Datetime.now();
            toUpdate.add(stock);

            String txnType = referenceType == 'Stock_Transfer' ? 'Transfer_Out' : 'Outbound_Dispatch';
            transactions.add(createTransaction(
                stock, txnType, item.quantity, 'Out',
                referenceType, referenceId, item.batchNumber,
                stock.Qty_On_Hand__c, 'Stock deducted'
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!transactions.isEmpty()) {
            insert transactions;
        }
    }

    /**
     * @description Adds stock to a warehouse. Increases Qty_On_Hand.
     * @param warehouseId   The warehouse to add stock to.
     * @param items         Line items with product, batch, and quantity.
     * @param referenceId   The source record ID.
     * @param referenceType The type of source record (GRN, Return_Order, Stock_Transfer, etc.).
     */
    public static void addStock(Id warehouseId, List<StockLineItem> items, String referenceId, String referenceType) {
        List<Warehouse_Stock__c> stockRecords = getOrCreateStockRecords(warehouseId, items);
        Map<String, Warehouse_Stock__c> stockMap = buildStockMap(stockRecords);

        List<Warehouse_Stock__c> toUpdate = new List<Warehouse_Stock__c>();
        List<Stock_Transaction__c> transactions = new List<Stock_Transaction__c>();

        for (StockLineItem item : items) {
            String key = buildKey(warehouseId, item.productId, item.batchNumber);
            Warehouse_Stock__c stock = stockMap.get(key);
            if (stock == null) {
                continue;
            }

            Decimal onHand = stock.Qty_On_Hand__c != null ? stock.Qty_On_Hand__c : 0;
            stock.Qty_On_Hand__c = onHand + item.quantity;
            stock.Last_Transaction_Date__c = Datetime.now();
            toUpdate.add(stock);

            String txnType;
            if (referenceType == 'GRN') {
                txnType = 'Inbound_GRN';
            } else if (referenceType == 'Return_Order') {
                txnType = 'Return_Inbound';
            } else if (referenceType == 'Stock_Transfer') {
                txnType = 'Transfer_In';
            } else if (referenceType == 'Stock_Adjustment') {
                txnType = 'Adjustment_Add';
            } else {
                txnType = 'Inbound_GRN';
            }

            transactions.add(createTransaction(
                stock, txnType, item.quantity, 'In',
                referenceType, referenceId, item.batchNumber,
                stock.Qty_On_Hand__c, 'Stock added'
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!transactions.isEmpty()) {
            insert transactions;
        }
    }

    /**
     * @description Deducts stock via adjustment (negative adjustment).
     * @param warehouseId   The warehouse.
     * @param items         Line items.
     * @param referenceId   The adjustment record ID.
     */
    public static void adjustDeduct(Id warehouseId, List<StockLineItem> items, String referenceId) {
        List<Warehouse_Stock__c> stockRecords = queryStockRecords(warehouseId, items);
        Map<String, Warehouse_Stock__c> stockMap = buildStockMap(stockRecords);

        List<Warehouse_Stock__c> toUpdate = new List<Warehouse_Stock__c>();
        List<Stock_Transaction__c> transactions = new List<Stock_Transaction__c>();

        for (StockLineItem item : items) {
            String key = buildKey(warehouseId, item.productId, item.batchNumber);
            Warehouse_Stock__c stock = stockMap.get(key);
            if (stock == null) {
                continue;
            }

            Decimal onHand = stock.Qty_On_Hand__c != null ? stock.Qty_On_Hand__c : 0;
            stock.Qty_On_Hand__c = Math.max(0, onHand - item.quantity);
            stock.Last_Transaction_Date__c = Datetime.now();
            toUpdate.add(stock);

            transactions.add(createTransaction(
                stock, 'Adjustment_Deduct', item.quantity, 'Out',
                'Stock_Adjustment', referenceId, item.batchNumber,
                stock.Qty_On_Hand__c, 'Stock adjusted (deduct)'
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!transactions.isEmpty()) {
            insert transactions;
        }
    }

    // ── Private helpers ─────────────────────────────────────────────────────

    /**
     * @description Queries existing stock records or creates new ones if they
     *              don't exist for the given warehouse + product + batch combos.
     */
    private static List<Warehouse_Stock__c> getOrCreateStockRecords(
        Id warehouseId, List<StockLineItem> items
    ) {
        Set<Id> productIds = new Set<Id>();
        Set<String> batchNumbers = new Set<String>();
        for (StockLineItem item : items) {
            productIds.add(item.productId);
            batchNumbers.add(item.batchNumber != null ? item.batchNumber : '');
        }

        List<Warehouse_Stock__c> existing = [
            SELECT Id, Warehouse__c, Product_Ext__c, Batch_Number__c,
                   Qty_On_Hand__c, Qty_Reserved__c, Qty_Damaged__c,
                   Last_Transaction_Date__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :warehouseId
              AND Product_Ext__c IN :productIds
        ];

        Map<String, Warehouse_Stock__c> existingMap = buildStockMap(existing);

        List<Warehouse_Stock__c> toInsert = new List<Warehouse_Stock__c>();
        for (StockLineItem item : items) {
            String key = buildKey(warehouseId, item.productId, item.batchNumber);
            if (!existingMap.containsKey(key)) {
                Warehouse_Stock__c newStock = new Warehouse_Stock__c(
                    Warehouse__c = warehouseId,
                    Product_Ext__c = item.productId,
                    Batch_Number__c = item.batchNumber,
                    Batch_Master__c = item.batchMasterId,
                    // Carry the batch's expiry onto the stock row. It was never populated, so
                    // every "Expiry_Date__c = null OR > TODAY" filter in this class and in
                    // OMS_StockAvailability_Service silently matched everything — expiry
                    // handling on the warehouse was dead code, and FEFO had nothing to sort by.
                    Expiry_Date__c = item.expiryDate,
                    Qty_On_Hand__c = 0,
                    Qty_Reserved__c = 0,
                    Qty_Damaged__c = 0
                );
                toInsert.add(newStock);
                existingMap.put(key, newStock);
            }
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }

        // Re-query to get IDs for newly inserted records
        if (!toInsert.isEmpty()) {
            existing = [
                SELECT Id, Warehouse__c, Product_Ext__c, Batch_Number__c,
                       Qty_On_Hand__c, Qty_Reserved__c, Qty_Damaged__c,
                       Last_Transaction_Date__c
                FROM Warehouse_Stock__c
                WHERE Warehouse__c = :warehouseId
                  AND Product_Ext__c IN :productIds
            ];
        }

        return existing.isEmpty() ? new List<Warehouse_Stock__c>(existingMap.values()) : existing;
    }

    /**
     * @description Queries existing stock records (does not create).
     */
    private static List<Warehouse_Stock__c> queryStockRecords(
        Id warehouseId, List<StockLineItem> items
    ) {
        Set<Id> productIds = new Set<Id>();
        for (StockLineItem item : items) {
            productIds.add(item.productId);
        }

        return [
            SELECT Id, Warehouse__c, Product_Ext__c, Batch_Number__c,
                   Qty_On_Hand__c, Qty_Reserved__c, Qty_Damaged__c,
                   Last_Transaction_Date__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :warehouseId
              AND Product_Ext__c IN :productIds
        ];
    }

    /**
     * @description Builds a map keyed by Warehouse|Product|Batch composite key.
     */
    private static Map<String, Warehouse_Stock__c> buildStockMap(List<Warehouse_Stock__c> records) {
        Map<String, Warehouse_Stock__c> stockMap = new Map<String, Warehouse_Stock__c>();
        for (Warehouse_Stock__c stock : records) {
            String key = buildKey(stock.Warehouse__c, stock.Product_Ext__c, stock.Batch_Number__c);
            stockMap.put(key, stock);
        }
        return stockMap;
    }

    /**
     * @description Builds a composite key for stock record lookup.
     */
    private static String buildKey(Id warehouseId, Id productId, String batchNumber) {
        String batch = String.isNotBlank(batchNumber) ? batchNumber : '';
        return String.valueOf(warehouseId) + '|' + String.valueOf(productId) + '|' + batch;
    }

    /**
     * @description Creates a Stock_Transaction__c record for the audit trail.
     */
    private static Stock_Transaction__c createTransaction(
        Warehouse_Stock__c stock,
        String txnType,
        Decimal quantity,
        String direction,
        String refType,
        String refId,
        String batchNumber,
        Decimal runningBalance,
        String notes
    ) {
        return new Stock_Transaction__c(
            Warehouse_Stock__c = stock.Id,
            Warehouse__c       = stock.Warehouse__c,
            Product_Ext__c         = stock.Product_Ext__c,
            Transaction_Type__c = txnType,
            Quantity__c        = quantity,
            Direction__c       = direction,
            Reference_Type__c  = refType,
            Reference_Id__c    = refId,
            Batch_Number__c    = batchNumber,
            Running_Balance__c = runningBalance,
            Transaction_Date__c = Datetime.now(),
            Transaction_By__c  = UserInfo.getUserId(),
            Notes__c           = notes
        );
    }

    // ── Inner class ─────────────────────────────────────────────────────────

    /**
     * @description Wrapper for stock line item data passed to service methods.
     */
    public class StockLineItem {
        @AuraEnabled public Id productId;
        @AuraEnabled public String batchNumber;
        @AuraEnabled public Id batchMasterId;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Date expiryDate;

        public StockLineItem() {}

        public StockLineItem(Id productId, String batchNumber, Decimal quantity) {
            this.productId = productId;
            this.batchNumber = batchNumber;
            this.quantity = quantity;
        }

        public StockLineItem(Id productId, String batchNumber, Id batchMasterId, Decimal quantity) {
            this.productId = productId;
            this.batchNumber = batchNumber;
            this.batchMasterId = batchMasterId;
            this.quantity = quantity;
        }

        /** Inbound with a dated batch — carries the expiry onto the warehouse stock row. */
        public StockLineItem(Id productId, String batchNumber, Decimal quantity, Date expiryDate) {
            this.productId = productId;
            this.batchNumber = batchNumber;
            this.quantity = quantity;
            this.expiryDate = expiryDate;
        }
    }

    /**
     * @description Allocate a required quantity per product across the warehouse's batch rows,
     *              earliest expiry first (FEFO), skipping anything already expired.
     *
     *              Primary dispatch previously passed `batch = null`, so it never chose a batch
     *              at all — there was no FEFO anywhere on the warehouse, and stock could ship in
     *              arbitrary batch order while dated stock aged out. Undated rows sort last, so
     *              a warehouse that holds no batch information behaves exactly as before.
     *
     * @param warehouseId The source warehouse.
     * @param requiredByProduct Quantity needed per product.
     * @return Batch-specific line items ready for deductStock.
     */
    public static List<StockLineItem> allocateFefo(Id warehouseId, Map<Id, Decimal> requiredByProduct) {
        List<StockLineItem> allocated = new List<StockLineItem>();
        if (requiredByProduct == null || requiredByProduct.isEmpty()) { return allocated; }

        Set<Id> productIds = requiredByProduct.keySet();
        Date today = Date.today();

        Map<Id, List<Warehouse_Stock__c>> batchesByProduct = new Map<Id, List<Warehouse_Stock__c>>();
        for (Warehouse_Stock__c ws : [
            SELECT Product_Ext__c, Batch_Number__c, Batch_Master__c, Expiry_Date__c, Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :warehouseId
              AND Product_Ext__c IN :productIds
              AND Qty_On_Hand__c > 0
              AND (Expiry_Date__c = null OR Expiry_Date__c >= :today)
            ORDER BY Expiry_Date__c ASC NULLS LAST
        ]) {
            if (!batchesByProduct.containsKey(ws.Product_Ext__c)) {
                batchesByProduct.put(ws.Product_Ext__c, new List<Warehouse_Stock__c>());
            }
            batchesByProduct.get(ws.Product_Ext__c).add(ws);
        }

        for (Id productId : productIds) {
            Decimal remaining = requiredByProduct.get(productId);
            if (remaining == null || remaining <= 0) { continue; }

            for (Warehouse_Stock__c ws : (batchesByProduct.containsKey(productId)
                    ? batchesByProduct.get(productId) : new List<Warehouse_Stock__c>())) {
                if (remaining <= 0) { break; }
                Decimal onHand = ws.Qty_On_Hand__c != null ? ws.Qty_On_Hand__c : 0;
                if (onHand <= 0) { continue; }

                Decimal take = Math.min(onHand, remaining);
                StockLineItem item = new StockLineItem();
                item.productId = productId;
                item.batchNumber = ws.Batch_Number__c;
                item.batchMasterId = ws.Batch_Master__c;
                item.expiryDate = ws.Expiry_Date__c;
                item.quantity = take;
                allocated.add(item);
                remaining -= take;
            }

            if (remaining > 0) {
                throw new WarehouseStockException(
                    'Insufficient warehouse stock for product ' + productId +
                    '. Short by ' + remaining + ' unit(s) (expired batches are not allocatable).');
            }
        }
        return allocated;
    }

    public class WarehouseStockException extends Exception {}
}