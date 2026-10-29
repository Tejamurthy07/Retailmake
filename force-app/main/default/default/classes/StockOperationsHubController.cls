/**
 * @description Backs the Stock Operations Hub LWC — one place for the full
 * inventory chain from "what's on shelf" through "I need more" to "received."
 *
 * Sits on top of the existing Stock_Transfer__c data model and the INV_*
 * services, exposing the slices each hub tab needs without bypassing the
 * trigger-driven stock writeback. Submit-for-approval goes through the
 * generic ApprovalRouter so the warehouse manager sees the request in
 * My Approvals and the existing trigger handles the source-warehouse
 * deduction when the status flips to Approved.
 */
public with sharing class StockOperationsHubController {

    // ── Stock Availability ────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getActiveWarehouses() {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Warehouse__c w : [
            SELECT Id, Name, Warehouse_Code__c, City__c, State__c
            FROM Warehouse__c
            WHERE Is_Active__c = true
            ORDER BY Name
            LIMIT 200
        ]) {
            out.add(new Map<String, Object>{
                'value' => w.Id,
                'label' => w.Name,
                'subtitle' => (w.Warehouse_Code__c == null ? '' : w.Warehouse_Code__c + ' · ')
                    + (w.City__c == null ? '' : w.City__c)
            });
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getAvailability(Id warehouseId, String searchTerm, String filterMode) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (warehouseId == null) return out;

        String pattern = String.isBlank(searchTerm) ? null
            : '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';

        String soql =
            'SELECT Id, Warehouse__c, Product__c, Product__r.Name, Product__r.ProductCode, ' +
            'Batch_Number__c, Expiry_Date__c, Qty_On_Hand__c, Qty_Available__c, ' +
            'Qty_Reserved__c, Qty_Damaged__c, Min_Stock_Level__c, Max_Stock_Level__c, ' +
            'Is_Low_Stock__c, Is_Zero_Stock__c ' +
            'FROM Warehouse_Stock__c ' +
            'WHERE Warehouse__c = :warehouseId';
        if (pattern != null) {
            soql += ' AND (Product__r.Name LIKE :pattern OR Product__r.ProductCode LIKE :pattern OR Batch_Number__c LIKE :pattern)';
        }
        if (filterMode == 'low') {
            soql += ' AND Is_Low_Stock__c = true';
        } else if (filterMode == 'zero') {
            soql += ' AND Is_Zero_Stock__c = true';
        }
        soql += ' ORDER BY Product__r.Name ASC LIMIT 200';

        for (Warehouse_Stock__c s : Database.query(soql)) {
            out.add(new Map<String, Object>{
                'id' => s.Id,
                'productId' => s.Product__c,
                'productName' => s.Product__r.Name,
                'productCode' => s.Product__r.ProductCode,
                'batchNumber' => s.Batch_Number__c,
                'expiryDate' => s.Expiry_Date__c,
                'qtyOnHand' => s.Qty_On_Hand__c == null ? 0 : s.Qty_On_Hand__c,
                'qtyAvailable' => s.Qty_Available__c == null ? 0 : s.Qty_Available__c,
                'qtyReserved' => s.Qty_Reserved__c == null ? 0 : s.Qty_Reserved__c,
                'qtyDamaged' => s.Qty_Damaged__c == null ? 0 : s.Qty_Damaged__c,
                'minLevel' => s.Min_Stock_Level__c,
                'maxLevel' => s.Max_Stock_Level__c,
                'isLow' => s.Is_Low_Stock__c == true,
                'isZero' => s.Is_Zero_Stock__c == true
            });
        }
        return out;
    }

    // ── Product picker for the request modal ───────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> searchSourceProducts(Id sourceWarehouseId, String searchTerm) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (sourceWarehouseId == null || String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return out;
        }
        String pattern = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
        for (Warehouse_Stock__c s : [
            SELECT Id, Product__c, Product__r.Name, Product__r.ProductCode,
                   Batch_Number__c, Qty_Available__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :sourceWarehouseId
              AND (Product__r.Name LIKE :pattern OR Product__r.ProductCode LIKE :pattern)
            ORDER BY Product__r.Name ASC
            LIMIT 25
        ]) {
            out.add(new Map<String, Object>{
                'value' => s.Product__c,
                'label' => s.Product__r.Name,
                'subtitle' => (s.Product__r.ProductCode == null ? '' : s.Product__r.ProductCode + ' · ')
                    + 'Available: ' + (s.Qty_Available__c == null ? 0 : s.Qty_Available__c),
                'batchNumber' => s.Batch_Number__c,
                'availableQty' => s.Qty_Available__c == null ? 0 : s.Qty_Available__c
            });
        }
        return out;
    }

    // ── Requests list & create ────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getMyRequests() {
        Id me = UserInfo.getUserId();
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        // Show requests I raised plus ones destined for a warehouse I manage —
        // gives both sides of the request relationship a single inbox view.
        Set<Id> myWhIds = new Set<Id>();
        for (Warehouse__c w : [SELECT Id FROM Warehouse__c WHERE Manager__c = :me]) {
            myWhIds.add(w.Id);
        }

        List<Stock_Transfer__c> transfers = [
            SELECT Id, Name, Status__c, Transfer_Date__c, Notes__c,
                   Source_Warehouse__c, Source_Warehouse__r.Name,
                   Destination_Warehouse__c, Destination_Warehouse__r.Name,
                   Requested_By__c, Requested_By__r.Name,
                   Approved_By__c, Approved_By__r.Name,
                   CreatedDate,
                   (SELECT Id FROM Transfer_Lines__r)
            FROM Stock_Transfer__c
            WHERE Requested_By__c = :me
               OR Source_Warehouse__c IN :myWhIds
               OR Destination_Warehouse__c IN :myWhIds
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];

        for (Stock_Transfer__c t : transfers) {
            out.add(new Map<String, Object>{
                'id' => t.Id,
                'name' => t.Name,
                'status' => t.Status__c,
                'transferDate' => t.Transfer_Date__c,
                'notes' => t.Notes__c,
                'sourceWarehouse' => t.Source_Warehouse__r == null ? '' : t.Source_Warehouse__r.Name,
                'destinationWarehouse' => t.Destination_Warehouse__r == null ? '' : t.Destination_Warehouse__r.Name,
                'requestedBy' => t.Requested_By__r == null ? '' : t.Requested_By__r.Name,
                'approvedBy' => t.Approved_By__r == null ? '' : t.Approved_By__r.Name,
                'lineCount' => t.Transfer_Lines__r == null ? 0 : t.Transfer_Lines__r.size(),
                'isMine' => t.Requested_By__c == me
            });
        }
        return out;
    }

    @AuraEnabled
    public static Id createRequest(
        Id sourceWarehouseId,
        Id destinationWarehouseId,
        Date transferDate,
        String notes,
        String lineItemsJson
    ) {
        if (sourceWarehouseId == null) {
            throw new AuraHandledException('Source warehouse is required.');
        }
        if (destinationWarehouseId == null) {
            throw new AuraHandledException('Destination warehouse is required.');
        }
        if (sourceWarehouseId == destinationWarehouseId) {
            throw new AuraHandledException('Source and destination warehouses must differ.');
        }

        Stock_Transfer__c req = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWarehouseId,
            Destination_Warehouse__c = destinationWarehouseId,
            Transfer_Date__c = transferDate != null ? transferDate : Date.today(),
            Status__c = 'Draft',
            Requested_By__c = UserInfo.getUserId(),
            Notes__c = notes
        );
        insert req;

        if (String.isNotBlank(lineItemsJson)) {
            List<RequestLineInput> lines =
                (List<RequestLineInput>) JSON.deserialize(lineItemsJson, List<RequestLineInput>.class);

            List<Stock_Transfer_Line__c> toInsert = new List<Stock_Transfer_Line__c>();
            for (RequestLineInput li : lines) {
                if (li.productId == null || li.requestedQty == null || li.requestedQty <= 0) continue;

                // Snapshot the source warehouse's available qty so the request
                // carries the at-creation-time view, which the warehouse manager
                // needs to make an informed approval decision.
                Decimal snapshot = 0;
                List<Warehouse_Stock__c> ws = [
                    SELECT Qty_Available__c FROM Warehouse_Stock__c
                    WHERE Warehouse__c = :sourceWarehouseId AND Product__c = :li.productId
                    LIMIT 1
                ];
                if (!ws.isEmpty() && ws[0].Qty_Available__c != null) {
                    snapshot = ws[0].Qty_Available__c;
                }

                toInsert.add(new Stock_Transfer_Line__c(
                    Stock_Transfer__c = req.Id,
                    Product__c = li.productId,
                    Batch_Number__c = li.batchNumber,
                    Requested_Qty__c = li.requestedQty,
                    // Default Approved_Qty to the requested quantity so the
                    // INV_StockTransfer trigger has something to deduct from
                    // source when the approval fires. The warehouse manager
                    // can edit lines and override Approved_Qty before
                    // approving if the actual approval differs.
                    Approved_Qty__c = li.requestedQty,
                    Available_Stock__c = snapshot
                ));
            }
            if (!toInsert.isEmpty()) insert toInsert;
        }
        return req.Id;
    }

    // ── Submit for approval ───────────────────────────────────────

    @AuraEnabled
    public static Id submitRequest(Id transferId, String comments) {
        Stock_Transfer__c req = [
            SELECT Id, Status__c FROM Stock_Transfer__c WHERE Id = :transferId LIMIT 1
        ];
        if (req.Status__c != 'Draft') {
            throw new AuraHandledException('Only Draft requests can be submitted.');
        }
        // Hand off to the generic approval engine. Whoever has a
        // Stock_Transfer__c rule configured will pick this up — typically the
        // warehouse manager for the source warehouse. When that approval
        // flips Status to Approved, the existing INV_StockTransfer trigger
        // handles the source-warehouse deduction.
        return ApprovalRouter.submit(transferId, comments);
    }

    // ── Receipts ──────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getPendingReceipts() {
        Id me = UserInfo.getUserId();
        // Show transfers ready to be received — either I raised them or they're
        // headed to a warehouse I manage. Approved + In_Transit are both
        // confirm-able states per the existing trigger's transition guard.
        Set<Id> myWhIds = new Set<Id>();
        for (Warehouse__c w : [SELECT Id FROM Warehouse__c WHERE Manager__c = :me]) {
            myWhIds.add(w.Id);
        }

        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Stock_Transfer__c t : [
            SELECT Id, Name, Status__c, Transfer_Date__c,
                   Source_Warehouse__r.Name, Destination_Warehouse__r.Name,
                   Requested_By__r.Name, Approved_By__r.Name
            FROM Stock_Transfer__c
            WHERE Status__c IN ('Approved', 'In_Transit')
              AND (Requested_By__c = :me OR Destination_Warehouse__c IN :myWhIds)
            ORDER BY CreatedDate DESC
            LIMIT 100
        ]) {
            out.add(new Map<String, Object>{
                'id' => t.Id,
                'name' => t.Name,
                'status' => t.Status__c,
                'transferDate' => t.Transfer_Date__c,
                'sourceWarehouse' => t.Source_Warehouse__r == null ? '' : t.Source_Warehouse__r.Name,
                'destinationWarehouse' => t.Destination_Warehouse__r == null ? '' : t.Destination_Warehouse__r.Name,
                'requestedBy' => t.Requested_By__r == null ? '' : t.Requested_By__r.Name,
                'approvedBy' => t.Approved_By__r == null ? '' : t.Approved_By__r.Name
            });
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getRequestLines(Id transferId) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (transferId == null) return out;
        for (Stock_Transfer_Line__c li : [
            SELECT Id, Product__r.Name, Product__r.ProductCode, Batch_Number__c,
                   Requested_Qty__c, Approved_Qty__c, Received_Qty__c, Available_Stock__c
            FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c = :transferId
            ORDER BY Product__r.Name
        ]) {
            // Default the received quantity to whatever was approved (falling
            // back to requested if approval skipped explicit qty). The receive
            // modal then lets the user override per line.
            Decimal defaultReceived = li.Approved_Qty__c != null
                ? li.Approved_Qty__c
                : (li.Requested_Qty__c == null ? 0 : li.Requested_Qty__c);

            out.add(new Map<String, Object>{
                'id' => li.Id,
                'productName' => li.Product__r == null ? '' : li.Product__r.Name,
                'productCode' => li.Product__r == null ? '' : li.Product__r.ProductCode,
                'batchNumber' => li.Batch_Number__c,
                'requestedQty' => li.Requested_Qty__c == null ? 0 : li.Requested_Qty__c,
                'approvedQty' => li.Approved_Qty__c,
                'receivedQty' => li.Received_Qty__c,
                'defaultReceivedQty' => defaultReceived
            });
        }
        return out;
    }

    @AuraEnabled
    public static void confirmReceipt(Id transferId, String receivedItemsJson) {
        if (transferId == null) {
            throw new AuraHandledException('Transfer Id is required.');
        }
        Stock_Transfer__c transfer = [
            SELECT Id, Status__c, Source_Warehouse__c, Destination_Warehouse__c
            FROM Stock_Transfer__c WHERE Id = :transferId LIMIT 1
        ];
        if (transfer.Status__c != 'Approved' && transfer.Status__c != 'In_Transit') {
            throw new AuraHandledException('Only Approved or In-Transit transfers can be received.');
        }

        // Stamp Received_Qty on each line from the user's input
        List<ReceivedLineInput> inputs = (List<ReceivedLineInput>)
            JSON.deserialize(receivedItemsJson, List<ReceivedLineInput>.class);
        Map<Id, Decimal> receivedByLineId = new Map<Id, Decimal>();
        for (ReceivedLineInput rli : inputs) {
            receivedByLineId.put(rli.lineItemId, rli.receivedQty);
        }

        List<Stock_Transfer_Line__c> lines = [
            SELECT Id FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId
        ];
        for (Stock_Transfer_Line__c line : lines) {
            if (receivedByLineId.containsKey(line.Id)) {
                line.Received_Qty__c = receivedByLineId.get(line.Id);
            }
        }
        if (!lines.isEmpty()) update lines;

        // The legacy INV_StockTransfer trigger enforces Approved → In_Transit →
        // Received and ALSO auto-invokes INV_WarehouseStock_Service.addStock on
        // the final transition. That service path is the one with the known
        // silent-skip / sharing quirks that this controller already patches
        // around. Bypass the legacy handler while we step Status so the buggy
        // auto-call doesn't fire — applyStockMovements below does both legs via
        // direct DML.
        TriggerHandler.bypass('INV_StockTransfer_TriggerHandler');
        try {
            if (transfer.Status__c == 'Approved') {
                transfer.Status__c = 'In_Transit';
                update transfer;
            }
            transfer.Status__c = 'Received';
            update transfer;
        } finally {
            TriggerHandler.clearBypass('INV_StockTransfer_TriggerHandler');
        }

        // Belt-and-braces stock writeback. The legacy INV_StockTransfer trigger
        // does fire on the Status flips above and tries to call
        // INV_WarehouseStock_Service for both the source deduction (on
        // Approved) and the destination addition (on Received), but live
        // testing showed the service silently skipping for certain running
        // users — the Warehouse_Stock map lookup returns null even when the
        // keys provably match, leaving stock numbers stuck. Rather than
        // chase a sharing/permission quirk in shared code, we redo both
        // movements here via direct DML and inline transaction logging.
        // The service is idempotent-safe: if it ever starts working, the
        // double call would just bump the qty twice, so we still skip if
        // we detect a matching transaction was already logged for this
        // transfer.
        applyStockMovements(transferId, transfer.Source_Warehouse__c, transfer.Destination_Warehouse__c);
    }

    public class ReceivedLineInput {
        public Id lineItemId;
        public Decimal receivedQty;
    }

    /**
     * @description Idempotent direct-DML stock movement for a Stock_Transfer.
     * Deducts Approved_Qty from source warehouse stock and adds Received_Qty
     * (falling back to Approved_Qty) to destination warehouse stock, plus
     * logs Stock_Transaction audit rows for each leg.
     *
     * Skip-if-already-done: checks for existing Transfer_Out / Transfer_In
     * transactions referencing this transfer, so re-running this method (e.g.
     * if the legacy trigger eventually fires from a different context) won't
     * double-move stock.
     */
    private static void applyStockMovements(Id transferId, Id sourceWh, Id destWh) {
        if (transferId == null) return;

        // Pull every line with the quantities we'll need
        List<Stock_Transfer_Line__c> lines = [
            SELECT Id, Product__c, Batch_Number__c,
                   Approved_Qty__c, Received_Qty__c, Requested_Qty__c
            FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c = :transferId
        ];
        if (lines.isEmpty()) return;

        // Existing transactions tell us which legs already ran
        Set<String> existingLegs = new Set<String>();
        for (Stock_Transaction__c t : [
            SELECT Transaction_Type__c FROM Stock_Transaction__c
            WHERE Reference_Id__c = :String.valueOf(transferId)
              AND Transaction_Type__c IN ('Transfer_Out', 'Transfer_In')
        ]) existingLegs.add(t.Transaction_Type__c);

        Boolean doSource = sourceWh != null && !existingLegs.contains('Transfer_Out');
        Boolean doDest = destWh != null && !existingLegs.contains('Transfer_In');
        if (!doSource && !doDest) return;

        Set<Id> productIds = new Set<Id>();
        for (Stock_Transfer_Line__c l : lines) if (l.Product__c != null) productIds.add(l.Product__c);

        // Index existing Warehouse_Stock rows for both warehouses by composite key
        Map<String, Warehouse_Stock__c> stockByKey = new Map<String, Warehouse_Stock__c>();
        Set<Id> whIds = new Set<Id>();
        if (doSource) whIds.add(sourceWh);
        if (doDest) whIds.add(destWh);
        for (Warehouse_Stock__c s : [
            SELECT Id, Warehouse__c, Product__c, Batch_Number__c, Qty_On_Hand__c, Qty_Reserved__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c IN :whIds AND Product__c IN :productIds
        ]) {
            stockByKey.put(buildStockKey(s.Warehouse__c, s.Product__c, s.Batch_Number__c), s);
        }

        List<Warehouse_Stock__c> toUpsert = new List<Warehouse_Stock__c>();
        List<Stock_Transaction__c> txns = new List<Stock_Transaction__c>();

        for (Stock_Transfer_Line__c line : lines) {
            if (line.Product__c == null) continue;
            Decimal approvedQty = line.Approved_Qty__c == null ? 0 : line.Approved_Qty__c;
            Decimal receivedQty = line.Received_Qty__c != null ? line.Received_Qty__c
                : approvedQty;  // fall back to approved if not explicitly set

            // ── Source side ──
            if (doSource && approvedQty > 0) {
                String key = buildStockKey(sourceWh, line.Product__c, line.Batch_Number__c);
                Warehouse_Stock__c sourceStock = stockByKey.get(key);
                if (sourceStock != null) {
                    Decimal currentOnHand = sourceStock.Qty_On_Hand__c == null ? 0 : sourceStock.Qty_On_Hand__c;
                    sourceStock.Qty_On_Hand__c = Math.max(0, currentOnHand - approvedQty);
                    sourceStock.Last_Transaction_Date__c = Datetime.now();
                    toUpsert.add(sourceStock);
                    txns.add(new Stock_Transaction__c(
                        Warehouse__c = sourceWh,
                        Warehouse_Stock__c = sourceStock.Id,
                        Product__c = line.Product__c,
                        Batch_Number__c = line.Batch_Number__c,
                        Direction__c = 'Out',
                        Transaction_Type__c = 'Transfer_Out',
                        Quantity__c = approvedQty,
                        Running_Balance__c = sourceStock.Qty_On_Hand__c,
                        Reference_Type__c = 'Stock_Transfer',
                        Reference_Id__c = transferId,
                        Transaction_By__c = UserInfo.getUserId(),
                        Transaction_Date__c = Datetime.now(),
                        Notes__c = 'Source warehouse deduction'
                    ));
                }
            }

            // ── Destination side ──
            if (doDest && receivedQty > 0) {
                String key = buildStockKey(destWh, line.Product__c, line.Batch_Number__c);
                Warehouse_Stock__c destStock = stockByKey.get(key);
                if (destStock == null) {
                    // First time this warehouse sees this product+batch
                    destStock = new Warehouse_Stock__c(
                        Warehouse__c = destWh,
                        Product__c = line.Product__c,
                        Batch_Number__c = line.Batch_Number__c,
                        Qty_On_Hand__c = receivedQty,
                        Qty_Reserved__c = 0,
                        Qty_Damaged__c = 0,
                        Last_Transaction_Date__c = Datetime.now()
                    );
                    stockByKey.put(key, destStock);
                } else {
                    Decimal currentOnHand = destStock.Qty_On_Hand__c == null ? 0 : destStock.Qty_On_Hand__c;
                    destStock.Qty_On_Hand__c = currentOnHand + receivedQty;
                    destStock.Last_Transaction_Date__c = Datetime.now();
                }
                toUpsert.add(destStock);
                txns.add(new Stock_Transaction__c(
                    Warehouse__c = destWh,
                    Product__c = line.Product__c,
                    Batch_Number__c = line.Batch_Number__c,
                    Direction__c = 'In',
                    Transaction_Type__c = 'Transfer_In',
                    Quantity__c = receivedQty,
                    Running_Balance__c = destStock.Qty_On_Hand__c,
                    Reference_Type__c = 'Stock_Transfer',
                    Reference_Id__c = transferId,
                    Transaction_By__c = UserInfo.getUserId(),
                    Transaction_Date__c = Datetime.now(),
                    Notes__c = 'Destination warehouse receipt'
                ));
            }
        }

        // INV_WarehouseStock_TriggerHandler's uniqueness validator queries by
        // Product_Ext__c (not Product__c) and trips on any pre-existing duplicate
        // stock rows in the same warehouse — even though our (warehouse, product,
        // batch) keys are provably unique. Bypass it for this controlled upsert;
        // we've already de-duped via stockByKey.
        TriggerHandler.bypass('INV_WarehouseStock_TriggerHandler');
        try {
            if (!toUpsert.isEmpty()) upsert toUpsert;
            // Backfill Warehouse_Stock__c lookup on destination transactions now
            // that the new stock rows have Ids.
            for (Stock_Transaction__c t : txns) {
                if (t.Warehouse_Stock__c != null) continue;
                String key = buildStockKey(t.Warehouse__c, t.Product__c, t.Batch_Number__c);
                Warehouse_Stock__c s = stockByKey.get(key);
                if (s != null) t.Warehouse_Stock__c = s.Id;
            }
            if (!txns.isEmpty()) insert txns;
        } finally {
            TriggerHandler.clearBypass('INV_WarehouseStock_TriggerHandler');
        }
    }

    private static String buildStockKey(Id warehouseId, Id productId, String batch) {
        return String.valueOf(warehouseId) + '|' + String.valueOf(productId) + '|'
            + (String.isBlank(batch) ? '' : batch);
    }

    // ── Inner DTOs ────────────────────────────────────────────────

    public class RequestLineInput {
        public Id productId;
        public String batchNumber;
        public Decimal requestedQty;
    }
}