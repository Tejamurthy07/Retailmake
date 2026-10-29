/**
 * @description LWC Controller for Stock Transfer operations.
 *              Provides create, list, detail, submit, and receive functionality.
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class INV_StockTransferController {

    /**
     * @description Creates a new stock transfer with line items.
     * @param sourceWarehouseId Source warehouse ID.
     * @param destinationWarehouseId Destination warehouse ID.
     * @param transferDate The transfer date.
     * @param notes Optional notes.
     * @param lineItems JSON array of line items with productId, batchNumber, requestedQty.
     * @return The created Stock_Transfer__c ID.
     */
    @AuraEnabled
    public static Id createTransfer(
        Id sourceWarehouseId,
        Id destinationWarehouseId,
        Date transferDate,
        String notes,
        String lineItems
    ) {
        Stock_Transfer__c transfer = new Stock_Transfer__c(
            Source_Warehouse__c = sourceWarehouseId,
            Destination_Warehouse__c = destinationWarehouseId,
            Transfer_Date__c = transferDate != null ? transferDate : Date.today(),
            Status__c = 'Draft',
            Requested_By__c = UserInfo.getUserId(),
            Notes__c = notes
        );
        insert transfer;

        List<TransferLineInput> lines = (List<TransferLineInput>) JSON.deserialize(
            lineItems, List<TransferLineInput>.class
        );

        List<Stock_Transfer_Line__c> transferLines = new List<Stock_Transfer_Line__c>();
        for (TransferLineInput line : lines) {
            if (line.productId == null || line.requestedQty == null || line.requestedQty <= 0) {
                continue;
            }

            // Snapshot available stock at source
            Decimal availableStock = 0;
            List<Warehouse_Stock__c> stocks = [
                SELECT Qty_Available__c
                FROM Warehouse_Stock__c
                WHERE Warehouse__c = :sourceWarehouseId
                  AND Product_Ext__c = :line.productId
                LIMIT 1
            ];
            if (!stocks.isEmpty() && stocks[0].Qty_Available__c != null) {
                availableStock = stocks[0].Qty_Available__c;
            }

            transferLines.add(new Stock_Transfer_Line__c(
                Stock_Transfer__c = transfer.Id,
                Product_Ext__c = line.productId,
                Batch_Number__c = line.batchNumber,
                Requested_Qty__c = line.requestedQty,
                Available_Stock__c = availableStock
            ));
        }

        if (!transferLines.isEmpty()) {
            insert transferLines;
        }

        return transfer.Id;
    }

    /**
     * @description Gets transfers for a warehouse with optional status filter.
     * @param warehouseId Warehouse ID (matches source or destination).
     * @param status Optional status filter.
     * @return List of Stock_Transfer__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Stock_Transfer__c> getTransfers(Id warehouseId, String status) {
        String query = 'SELECT Id, Name, Source_Warehouse__c, Source_Warehouse__r.Name, ' +
                       'Destination_Warehouse__c, Destination_Warehouse__r.Name, ' +
                       'Transfer_Date__c, Status__c, Requested_By__c, Requested_By__r.Name, ' +
                       'Approved_By__c, Approved_By__r.Name, Notes__c ' +
                       'FROM Stock_Transfer__c ';

        List<String> conditions = new List<String>();
        if (warehouseId != null) {
            conditions.add('(Source_Warehouse__c = :warehouseId OR Destination_Warehouse__c = :warehouseId)');
        }
        if (String.isNotBlank(status) && status != 'all') {
            conditions.add('Status__c = :status');
        }

        if (!conditions.isEmpty()) {
            query += 'WHERE ' + String.join(conditions, ' AND ') + ' ';
        }

        query += 'ORDER BY CreatedDate DESC LIMIT 50';
        return Database.query(query);
    }

    /**
     * @description Gets transfer detail with header and line items.
     * @param transferId The transfer ID.
     * @return TransferDetail wrapper.
     */
    @AuraEnabled
    public static TransferDetail getTransferDetail(Id transferId) {
        TransferDetail detail = new TransferDetail();

        detail.transfer = [
            SELECT Id, Name, Source_Warehouse__c, Source_Warehouse__r.Name,
                   Destination_Warehouse__c, Destination_Warehouse__r.Name,
                   Transfer_Date__c, Status__c, Requested_By__c, Requested_By__r.Name,
                   Approved_By__c, Approved_By__r.Name, Notes__c
            FROM Stock_Transfer__c
            WHERE Id = :transferId
            LIMIT 1
        ];

        detail.lineItems = [
            SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Batch_Number__c, Requested_Qty__c, Approved_Qty__c,
                   Received_Qty__c, Short_Qty__c, Available_Stock__c
            FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c = :transferId
            ORDER BY Name ASC
        ];

        return detail;
    }

    /**
     * @description Submits a draft transfer for approval.
     * @param transferId The transfer ID.
     */
    @AuraEnabled
    public static void submitTransfer(Id transferId) {
        Stock_Transfer__c transfer = [
            SELECT Id, Status__c FROM Stock_Transfer__c WHERE Id = :transferId LIMIT 1
        ];

        if (transfer.Status__c != 'Draft') {
            throw new AuraHandledException('Only draft transfers can be submitted.');
        }

        transfer.Status__c = 'Submitted';
        update transfer;
    }

    /**
     * @description Approves a submitted transfer: approves the full requested quantity on each
     *              line (the source-warehouse deduction keys off Approved_Qty__c) and moves the
     *              header to Approved, which fires the trigger that deducts the source stock and
     *              writes the Transfer_Out ledger entry. Without this, a submitted transfer had
     *              no path to Approved, so it could never move stock.
     * @param transferId The transfer ID.
     */
    @AuraEnabled
    public static void approveTransfer(Id transferId) {
        Stock_Transfer__c transfer = [
            SELECT Id, Status__c FROM Stock_Transfer__c WHERE Id = :transferId LIMIT 1
        ];
        if (transfer.Status__c != 'Submitted') {
            throw new AuraHandledException('Only submitted transfers can be approved.');
        }

        List<Stock_Transfer_Line__c> lines = [
            SELECT Id, Requested_Qty__c, Approved_Qty__c
            FROM Stock_Transfer_Line__c WHERE Stock_Transfer__c = :transferId
        ];
        for (Stock_Transfer_Line__c l : lines) {
            l.Approved_Qty__c = l.Requested_Qty__c;
        }
        if (!lines.isEmpty()) { update lines; }

        transfer.Status__c = 'Approved';
        update transfer;   // trigger deducts source stock + logs Transfer_Out
    }

    /**
     * @description Records receipt of a transfer at the destination warehouse.
     * @param transferId The transfer ID.
     * @param receivedItems JSON array of {lineItemId, receivedQty}.
     */
    @AuraEnabled
    public static void receiveTransfer(Id transferId, String receivedItems) {
        Stock_Transfer__c transfer = [
            SELECT Id, Status__c FROM Stock_Transfer__c WHERE Id = :transferId LIMIT 1
        ];

        if (transfer.Status__c != 'In_Transit' && transfer.Status__c != 'Approved') {
            throw new AuraHandledException('Only approved or in-transit transfers can be received.');
        }

        List<ReceivedLineInput> inputs = (List<ReceivedLineInput>) JSON.deserialize(
            receivedItems, List<ReceivedLineInput>.class
        );

        Map<Id, Decimal> receivedByLineId = new Map<Id, Decimal>();
        for (ReceivedLineInput input : inputs) {
            receivedByLineId.put(input.lineItemId, input.receivedQty);
        }

        List<Stock_Transfer_Line__c> lines = [
            SELECT Id, Received_Qty__c
            FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c = :transferId
        ];

        for (Stock_Transfer_Line__c line : lines) {
            if (receivedByLineId.containsKey(line.Id)) {
                line.Received_Qty__c = receivedByLineId.get(line.Id);
            }
        }

        if (!lines.isEmpty()) {
            update lines;
        }

        // The permitted flow is Approved -> In_Transit -> Received; Approved -> Received directly
        // is not an allowed transition. The source was already deducted at approval and In_Transit
        // moves no stock, so advance through it, then Received (which adds the destination stock).
        if (transfer.Status__c == 'Approved') {
            update new Stock_Transfer__c(Id = transfer.Id, Status__c = 'In_Transit');
        }
        update new Stock_Transfer__c(Id = transfer.Id, Status__c = 'Received');
    }

    /**
     * @description Gets products available at a warehouse for transfer line selection.
     * @param warehouseId The source warehouse.
     * @param searchTerm Optional product search.
     * @return List of available products with stock info.
     */
    @AuraEnabled(cacheable=true)
    public static List<Warehouse_Stock__c> getAvailableProducts(Id warehouseId, String searchTerm) {
        String query = 'SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                       'Batch_Number__c, Qty_On_Hand__c, Qty_Available__c ' +
                       'FROM Warehouse_Stock__c ' +
                       'WHERE Warehouse__c = :warehouseId AND Qty_Available__c > 0';

        if (String.isNotBlank(searchTerm)) {
            String searchWild = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' AND (Product_Ext__r.Name LIKE :searchWild OR Product_Ext__r.SKU_Code__c LIKE :searchWild)';
        }

        query += ' ORDER BY Product_Ext__r.Name ASC LIMIT 50';
        return Database.query(query);
    }

    // ── Inner Classes ─────────────────────────────────────────────────────────

    public class TransferLineInput {
        public Id productId;
        public String batchNumber;
        public Decimal requestedQty;
    }

    public class ReceivedLineInput {
        public Id lineItemId;
        public Decimal receivedQty;
    }

    public class TransferDetail {
        @AuraEnabled public Stock_Transfer__c transfer;
        @AuraEnabled public List<Stock_Transfer_Line__c> lineItems;
    }
}