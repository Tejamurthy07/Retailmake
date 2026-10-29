/**
 * @description Trigger handler for Stock_Adjustment__c. Snapshots current
 *              system quantity on creation and applies stock changes upon approval.
 * @author  SFA Development Team
 * @date    2024
 */
public class INV_StockAdjustment_TriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        List<Stock_Adjustment__c> newRecords = (List<Stock_Adjustment__c>) Trigger.new;
        snapshotSystemQty(newRecords);
    }

    protected override void afterUpdate() {
        List<Stock_Adjustment__c> newRecords = (List<Stock_Adjustment__c>) Trigger.new;
        Map<Id, Stock_Adjustment__c> oldMap = (Map<Id, Stock_Adjustment__c>) Trigger.oldMap;

        List<Stock_Adjustment__c> approved = new List<Stock_Adjustment__c>();
        for (Stock_Adjustment__c rec : newRecords) {
            Stock_Adjustment__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c == 'Approved' && oldRec.Status__c != 'Approved') {
                approved.add(rec);
            }
        }

        if (!approved.isEmpty()) {
            applyAdjustments(approved);
        }
    }

    private void snapshotSystemQty(List<Stock_Adjustment__c> records) {
        // Distributor-scoped adjustments are not warehouse stock; their snapshot
        // is owned by the DMS distributor-stock logic, so skip them here.
        List<Stock_Adjustment__c> warehouseRecords = new List<Stock_Adjustment__c>();
        for (Stock_Adjustment__c rec : records) {
            if (rec.Location_Type__c != DMS_Constants.LOCATION_DISTRIBUTOR) {
                warehouseRecords.add(rec);
            }
        }
        if (warehouseRecords.isEmpty()) {
            return;
        }

        Set<Id> warehouseIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        for (Stock_Adjustment__c rec : warehouseRecords) {
            warehouseIds.add(rec.Warehouse__c);
            productIds.add(rec.Product_Ext__c);
        }

        Map<String, Decimal> stockMap = new Map<String, Decimal>();
        for (Warehouse_Stock__c stock : [
            SELECT Warehouse__c, Product_Ext__c, Batch_Number__c, Qty_On_Hand__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c IN :warehouseIds AND Product_Ext__c IN :productIds
        ]) {
            String key = String.valueOf(stock.Warehouse__c) + '|' +
                         String.valueOf(stock.Product_Ext__c) + '|' +
                         (String.isNotBlank(stock.Batch_Number__c) ? stock.Batch_Number__c : '');
            Decimal onHand = stock.Qty_On_Hand__c != null ? stock.Qty_On_Hand__c : 0;
            stockMap.put(key, onHand);
        }

        for (Stock_Adjustment__c rec : warehouseRecords) {
            String key = String.valueOf(rec.Warehouse__c) + '|' +
                         String.valueOf(rec.Product_Ext__c) + '|' +
                         (String.isNotBlank(rec.Batch_Number__c) ? rec.Batch_Number__c : '');
            rec.System_Qty__c = stockMap.containsKey(key) ? stockMap.get(key) : 0;
        }
    }

    private void applyAdjustments(List<Stock_Adjustment__c> approvedAdj) {
        for (Stock_Adjustment__c adj : approvedAdj) {
            // Distributor-scoped adjustments belong to DMS_StockAdjustment_TriggerHandler.
            // Guarding only on Warehouse__c != null (below) was not enough: both handlers are
            // wired on this object, and the location validation rule permits a Distributor
            // adjustment that also carries a Warehouse — which then moved BOTH warehouse and
            // distributor stock from a single adjustment. Scope by Location_Type, as
            // snapshotSystemQty already does.
            if (adj.Location_Type__c == DMS_Constants.LOCATION_DISTRIBUTOR) { continue; }

            Decimal qty = adj.Adjustment_Qty__c != null ? adj.Adjustment_Qty__c : 0;
            if (qty == 0 || adj.Product_Ext__c == null || adj.Warehouse__c == null) continue;

            List<INV_WarehouseStock_Service.StockLineItem> items =
                new List<INV_WarehouseStock_Service.StockLineItem>();
            items.add(new INV_WarehouseStock_Service.StockLineItem(
                adj.Product_Ext__c, adj.Batch_Number__c, Math.abs(qty)
            ));

            if (qty > 0) {
                INV_WarehouseStock_Service.addStock(
                    adj.Warehouse__c, items, adj.Id, 'Stock_Adjustment'
                );
            } else {
                INV_WarehouseStock_Service.adjustDeduct(
                    adj.Warehouse__c, items, adj.Id
                );
            }
        }
    }
}