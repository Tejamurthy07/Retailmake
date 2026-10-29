/**
 * @description Trigger handler for Must_Sell_Config__c (Priority Sell Config).
 *              Validates date ranges, prevents duplicate configurations,
 *              and enforces data integrity using the TriggerHandler framework.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class SPM_MustSellConfig_TriggerHandler extends TriggerHandler {

    protected override void beforeInsert() {
        List<Must_Sell_Config__c> newRecords = (List<Must_Sell_Config__c>) Trigger.new;
        validateDateRanges(newRecords);
        checkDuplicateConfigs(newRecords, null);
    }

    protected override void beforeUpdate() {
        List<Must_Sell_Config__c> newRecords = (List<Must_Sell_Config__c>) Trigger.new;
        Map<Id, Must_Sell_Config__c> oldMap = (Map<Id, Must_Sell_Config__c>) Trigger.oldMap;
        validateDateRanges(newRecords);
        checkDuplicateConfigs(newRecords, oldMap);
    }

    private void validateDateRanges(List<Must_Sell_Config__c> records) {
        for (Must_Sell_Config__c config : records) {
            if (config.Start_Date__c != null && config.End_Date__c != null
                && config.End_Date__c < config.Start_Date__c) {
                config.addError('End Date must be on or after Start Date.');
            }
        }
    }

    private void checkDuplicateConfigs(List<Must_Sell_Config__c> records, Map<Id, Must_Sell_Config__c> oldMap) {
        Set<Id> productIds = new Set<Id>();
        for (Must_Sell_Config__c config : records) {
            if (config.Product_Ext__c != null) {
                productIds.add(config.Product_Ext__c);
            }
        }

        if (productIds.isEmpty()) {
            return;
        }

        // Query existing active configs from database
        Map<Id, List<Must_Sell_Config__c>> existingByProduct = new Map<Id, List<Must_Sell_Config__c>>();
        for (Must_Sell_Config__c existing : [
            SELECT Id, Product_Ext__c, Territory__c, Channel__c,
                   Customer_Type__c, Start_Date__c, End_Date__c, Is_Active__c
            FROM Must_Sell_Config__c
            WHERE Product_Ext__c IN :productIds
              AND Is_Active__c = true
        ]) {
            if (!existingByProduct.containsKey(existing.Product_Ext__c)) {
                existingByProduct.put(existing.Product_Ext__c, new List<Must_Sell_Config__c>());
            }
            existingByProduct.get(existing.Product_Ext__c).add(existing);
        }

        // GAP-031 fix: Also check for intra-batch duplicates
        Map<String, Must_Sell_Config__c> batchKeys = new Map<String, Must_Sell_Config__c>();

        for (Must_Sell_Config__c config : records) {
            if (config.Product_Ext__c == null || !config.Is_Active__c) {
                continue;
            }

            // Skip unchanged key fields on update
            if (oldMap != null && oldMap.get(config.Id) != null) {
                Must_Sell_Config__c oldRec = oldMap.get(config.Id);
                if (oldRec.Product_Ext__c == config.Product_Ext__c
                    && oldRec.Territory__c == config.Territory__c
                    && oldRec.Channel__c == config.Channel__c
                    && oldRec.Customer_Type__c == config.Customer_Type__c) {
                    continue;
                }
            }

            // Build composite key for intra-batch duplicate detection
            String batchKey = buildCompositeKey(config);
            if (batchKeys.containsKey(batchKey)) {
                config.addError('Duplicate Priority Sell configuration found within the same batch for this product, territory, channel, and customer type combination.');
                continue;
            }
            batchKeys.put(batchKey, config);

            // Check against existing database records
            List<Must_Sell_Config__c> existingList = existingByProduct.get(config.Product_Ext__c);
            if (existingList == null) {
                continue;
            }

            for (Must_Sell_Config__c existing : existingList) {
                if (existing.Id == config.Id) {
                    continue;
                }
                if (existing.Territory__c == config.Territory__c
                    && existing.Channel__c == config.Channel__c
                    && existing.Customer_Type__c == config.Customer_Type__c) {
                    Boolean datesOverlap = config.Start_Date__c != null
                        && config.End_Date__c != null
                        && existing.Start_Date__c != null
                        && existing.End_Date__c != null
                        && config.Start_Date__c <= existing.End_Date__c
                        && config.End_Date__c >= existing.Start_Date__c;
                    Boolean eitherOpenEnded = config.End_Date__c == null || existing.End_Date__c == null;

                    if (datesOverlap || eitherOpenEnded) {
                        config.addError('An active Priority Sell configuration already exists for this product, territory, channel, and customer type combination with overlapping dates.');
                    }
                }
            }
        }
    }

    private String buildCompositeKey(Must_Sell_Config__c config) {
        return String.valueOf(config.Product_Ext__c) + '|' +
               String.valueOf(config.Territory__c) + '|' +
               (config.Channel__c != null ? config.Channel__c : '') + '|' +
               (config.Customer_Type__c != null ? config.Customer_Type__c : '');
    }
}