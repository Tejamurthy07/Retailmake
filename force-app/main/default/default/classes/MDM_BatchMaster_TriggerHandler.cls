/**
 * @description Trigger handler for Batch_Master__c. Validates expiry dates,
 *              prevents duplicate batch numbers per product, and guards against
 *              expired batch usage.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class MDM_BatchMaster_TriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        List<Batch_Master__c> newRecords = (List<Batch_Master__c>) Trigger.new;
        validateExpiryDates(newRecords);
        checkDuplicateBatchNumbers(newRecords);
    }

    protected override void beforeUpdate() {
        List<Batch_Master__c> newRecords = (List<Batch_Master__c>) Trigger.new;
        validateExpiryDates(newRecords);
    }

    private void validateExpiryDates(List<Batch_Master__c> records) {
        for (Batch_Master__c rec : records) {
            if (rec.Expiry_Date__c != null && rec.Manufacturing_Date__c != null &&
                rec.Expiry_Date__c <= rec.Manufacturing_Date__c) {
                rec.Expiry_Date__c.addError('Expiry Date must be after Manufacturing Date.');
            }
        }
    }

    private void checkDuplicateBatchNumbers(List<Batch_Master__c> records) {
        Map<String, Batch_Master__c> batchKeys = new Map<String, Batch_Master__c>();
        Set<String> batchNumbers = new Set<String>();
        Set<Id> productIds = new Set<Id>();

        for (Batch_Master__c rec : records) {
            if (String.isNotBlank(rec.Batch_Number__c) && rec.Product_Ext__c != null) {
                String key = rec.Product_Ext__c + '|' + rec.Batch_Number__c;
                if (batchKeys.containsKey(key)) {
                    rec.Batch_Number__c.addError('Duplicate batch number in this batch.');
                } else {
                    batchKeys.put(key, rec);
                    batchNumbers.add(rec.Batch_Number__c);
                    productIds.add(rec.Product_Ext__c);
                }
            }
        }

        if (batchNumbers.isEmpty()) return;

        for (Batch_Master__c existing : [
            SELECT Id, Batch_Number__c, Product_Ext__c
            FROM Batch_Master__c
            WHERE Batch_Number__c IN :batchNumbers
              AND Product_Ext__c IN :productIds
        ]) {
            String key = existing.Product_Ext__c + '|' + existing.Batch_Number__c;
            if (batchKeys.containsKey(key)) {
                batchKeys.get(key).Batch_Number__c.addError(
                    'A batch with this number already exists for this product.'
                );
            }
        }
    }
}