/**
 * @description Trigger handler for Stock_Transfer__c. Manages stock deduction
 *              from source warehouse on approval and stock addition to destination
 *              warehouse on receipt.
 * @author  SFA Development Team
 * @date    2024
 */
public class INV_StockTransfer_TriggerHandler extends TriggerHandler {

    private static final Map<String, Set<String>> VALID_TRANSITIONS = new Map<String, Set<String>>{
        'Draft'      => new Set<String>{ 'Submitted', 'Cancelled' },
        'Submitted'  => new Set<String>{ 'Approved', 'Rejected', 'Cancelled' },
        'Approved'   => new Set<String>{ 'In_Transit', 'Cancelled' },
        'In_Transit' => new Set<String>{ 'Received', 'Cancelled' },
        'Received'   => new Set<String>(),
        'Cancelled'  => new Set<String>()
    };

    protected override void beforeUpdate() {
        List<Stock_Transfer__c> newRecords = (List<Stock_Transfer__c>) Trigger.new;
        Map<Id, Stock_Transfer__c> oldMap = (Map<Id, Stock_Transfer__c>) Trigger.oldMap;
        validateStatusTransitions(newRecords, oldMap);
    }

    protected override void afterUpdate() {
        List<Stock_Transfer__c> newRecords = (List<Stock_Transfer__c>) Trigger.new;
        Map<Id, Stock_Transfer__c> oldMap = (Map<Id, Stock_Transfer__c>) Trigger.oldMap;

        List<Stock_Transfer__c> approved = new List<Stock_Transfer__c>();
        List<Stock_Transfer__c> received = new List<Stock_Transfer__c>();
        List<Stock_Transfer__c> cancelled = new List<Stock_Transfer__c>();

        for (Stock_Transfer__c rec : newRecords) {
            Stock_Transfer__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c != oldRec.Status__c) {
                if (rec.Status__c == 'Approved') {
                    approved.add(rec);
                } else if (rec.Status__c == 'Received') {
                    received.add(rec);
                } else if (rec.Status__c == 'Cancelled' &&
                           (oldRec.Status__c == 'Approved' || oldRec.Status__c == 'In_Transit')) {
                    cancelled.add(rec);
                }
            }
        }

        if (!approved.isEmpty()) {
            deductFromSource(approved);
        }
        if (!received.isEmpty()) {
            addToDestination(received);
        }
        if (!cancelled.isEmpty()) {
            reverseSourceDeduction(cancelled);
        }
    }

    private void validateStatusTransitions(
        List<Stock_Transfer__c> newRecords, Map<Id, Stock_Transfer__c> oldMap
    ) {
        for (Stock_Transfer__c rec : newRecords) {
            Stock_Transfer__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c == oldRec.Status__c) continue;

            String current = oldRec.Status__c;
            String next = rec.Status__c;

            if (!VALID_TRANSITIONS.containsKey(current) ||
                !VALID_TRANSITIONS.get(current).contains(next)) {
                rec.Status__c.addError(
                    'Invalid status transition from \'' + current + '\' to \'' + next + '\'.'
                );
            }
        }
    }

    private void deductFromSource(List<Stock_Transfer__c> transfers) {
        processTransferLines(transfers, true);
    }

    private void addToDestination(List<Stock_Transfer__c> transfers) {
        processTransferLines(transfers, false);
    }

    private void reverseSourceDeduction(List<Stock_Transfer__c> transfers) {
        // Reverse = add back to source
        Set<Id> transferIds = new Set<Id>();
        for (Stock_Transfer__c t : transfers) transferIds.add(t.Id);

        List<Stock_Transfer_Line__c> lines = [
            SELECT Id, Stock_Transfer__c, Product_Ext__c, Batch_Number__c, Approved_Qty__c
            FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c IN :transferIds
        ];

        Map<Id, List<Stock_Transfer_Line__c>> linesByTransfer = new Map<Id, List<Stock_Transfer_Line__c>>();
        for (Stock_Transfer_Line__c line : lines) {
            if (!linesByTransfer.containsKey(line.Stock_Transfer__c)) {
                linesByTransfer.put(line.Stock_Transfer__c, new List<Stock_Transfer_Line__c>());
            }
            linesByTransfer.get(line.Stock_Transfer__c).add(line);
        }

        for (Stock_Transfer__c transfer : transfers) {
            List<Stock_Transfer_Line__c> tLines = linesByTransfer.get(transfer.Id);
            if (tLines == null || tLines.isEmpty()) continue;

            List<INV_WarehouseStock_Service.StockLineItem> items =
                new List<INV_WarehouseStock_Service.StockLineItem>();
            for (Stock_Transfer_Line__c line : tLines) {
                Decimal qty = line.Approved_Qty__c != null ? line.Approved_Qty__c : 0;
                if (qty > 0 && line.Product_Ext__c != null) {
                    items.add(new INV_WarehouseStock_Service.StockLineItem(
                        line.Product_Ext__c, line.Batch_Number__c, qty
                    ));
                }
            }

            if (!items.isEmpty()) {
                INV_WarehouseStock_Service.addStock(
                    transfer.Source_Warehouse__c, items, transfer.Id, 'Stock_Transfer'
                );
            }
        }
    }

    private void processTransferLines(List<Stock_Transfer__c> transfers, Boolean isDeduct) {
        Set<Id> transferIds = new Set<Id>();
        for (Stock_Transfer__c t : transfers) transferIds.add(t.Id);

        // NOTE on transit shortfall: the source is deducted for the APPROVED quantity and the
        // destination credited with the RECEIVED quantity, so units that left but never arrived
        // are the difference. That difference is NOT lost track of — Stock_Transfer_Line__c
        // .Short_Qty__c is a formula (Approved_Qty__c - Received_Qty__c), so the shortfall is
        // computed and reportable on every line, and the warehouse ledger stays correct
        // (Transfer_Out for approved, Transfer_In for received). Nothing to write here.
        List<Stock_Transfer_Line__c> lines = [
            SELECT Id, Stock_Transfer__c, Product_Ext__c, Batch_Number__c,
                   Approved_Qty__c, Received_Qty__c, Short_Qty__c
            FROM Stock_Transfer_Line__c
            WHERE Stock_Transfer__c IN :transferIds
        ];

        Map<Id, List<Stock_Transfer_Line__c>> linesByTransfer = new Map<Id, List<Stock_Transfer_Line__c>>();
        for (Stock_Transfer_Line__c line : lines) {
            if (!linesByTransfer.containsKey(line.Stock_Transfer__c)) {
                linesByTransfer.put(line.Stock_Transfer__c, new List<Stock_Transfer_Line__c>());
            }
            linesByTransfer.get(line.Stock_Transfer__c).add(line);
        }

        for (Stock_Transfer__c transfer : transfers) {
            List<Stock_Transfer_Line__c> tLines = linesByTransfer.get(transfer.Id);
            if (tLines == null || tLines.isEmpty()) continue;

            List<INV_WarehouseStock_Service.StockLineItem> items =
                new List<INV_WarehouseStock_Service.StockLineItem>();
            for (Stock_Transfer_Line__c line : tLines) {
                Decimal qty = isDeduct
                    ? (line.Approved_Qty__c != null ? line.Approved_Qty__c : 0)
                    : (line.Received_Qty__c != null ? line.Received_Qty__c : 0);
                if (qty > 0 && line.Product_Ext__c != null) {
                    items.add(new INV_WarehouseStock_Service.StockLineItem(
                        line.Product_Ext__c, line.Batch_Number__c, qty
                    ));
                }
            }

            if (!items.isEmpty()) {
                Id warehouseId = isDeduct ? transfer.Source_Warehouse__c : transfer.Destination_Warehouse__c;
                if (isDeduct) {
                    INV_WarehouseStock_Service.deductStock(
                        warehouseId, items, transfer.Id, 'Stock_Transfer'
                    );
                } else {
                    INV_WarehouseStock_Service.addStock(
                        warehouseId, items, transfer.Id, 'Stock_Transfer'
                    );
                }
            }
        }
    }
}