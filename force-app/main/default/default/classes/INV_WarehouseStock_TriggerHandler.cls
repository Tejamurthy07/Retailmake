/**
 * @description Trigger handler for Warehouse_Stock__c. Validates unique
 *              Warehouse+Product+Batch combinations and enforces data integrity.
 * @author  SFA Development Team
 * @date    2024
 */
public class INV_WarehouseStock_TriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        List<Warehouse_Stock__c> newRecords = (List<Warehouse_Stock__c>) Trigger.new;
        validateUniqueKeys(newRecords);
        setDefaults(newRecords);
    }

    protected override void beforeUpdate() {
        List<Warehouse_Stock__c> newRecords = (List<Warehouse_Stock__c>) Trigger.new;
        Map<Id, Warehouse_Stock__c> oldMap = (Map<Id, Warehouse_Stock__c>) Trigger.oldMap;
        validateUniqueKeys(newRecords);
    }

    private void setDefaults(List<Warehouse_Stock__c> records) {
        for (Warehouse_Stock__c rec : records) {
            if (rec.Qty_On_Hand__c == null) rec.Qty_On_Hand__c = 0;
            if (rec.Qty_Reserved__c == null) rec.Qty_Reserved__c = 0;
            if (rec.Qty_Damaged__c == null) rec.Qty_Damaged__c = 0;
        }
    }

    private void validateUniqueKeys(List<Warehouse_Stock__c> records) {
        // Collect keys from incoming records to check for in-batch duplicates
        Map<String, Integer> keyCount = new Map<String, Integer>();
        Set<Id> warehouseIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();

        for (Warehouse_Stock__c rec : records) {
            warehouseIds.add(rec.Warehouse__c);
            productIds.add(rec.Product_Ext__c);
            String key = buildKey(rec);
            Integer count = keyCount.containsKey(key) ? keyCount.get(key) : 0;
            keyCount.put(key, count + 1);
        }

        // Check for in-batch duplicates
        for (Warehouse_Stock__c rec : records) {
            String key = buildKey(rec);
            if (keyCount.get(key) > 1) {
                rec.addError('Duplicate Warehouse + Product + Batch combination in this batch.');
            }
        }

        // Check against existing records (exclude self on update)
        Set<Id> currentIds = new Set<Id>();
        for (Warehouse_Stock__c rec : records) {
            if (rec.Id != null) currentIds.add(rec.Id);
        }

        Map<String, Id> existingKeys = new Map<String, Id>();
        for (Warehouse_Stock__c existing : [
            SELECT Id, Warehouse__c, Product_Ext__c, Batch_Number__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c IN :warehouseIds
              AND Product_Ext__c IN :productIds
              AND Id NOT IN :currentIds
        ]) {
            existingKeys.put(buildKey(existing), existing.Id);
        }

        for (Warehouse_Stock__c rec : records) {
            String key = buildKey(rec);
            if (existingKeys.containsKey(key)) {
                rec.addError('A stock record already exists for this Warehouse + Product + Batch combination.');
            }
        }
    }

    private String buildKey(Warehouse_Stock__c rec) {
        String batch = String.isNotBlank(rec.Batch_Number__c) ? rec.Batch_Number__c : '';
        return String.valueOf(rec.Warehouse__c) + '|' + String.valueOf(rec.Product_Ext__c) + '|' + batch;
    }
}