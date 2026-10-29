/**
 * @description Service class for handling offline data synchronization.
 *              Processes records created offline (Offline_Created__c = true)
 *              and marks them as synced (Is_Synced__c = true) after validation.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class DFO_OfflineSync_Service {

    public class SyncResult {
        @AuraEnabled public Integer totalProcessed { get; set; }
        @AuraEnabled public Integer successCount { get; set; }
        @AuraEnabled public Integer errorCount { get; set; }
        @AuraEnabled public List<String> errors { get; set; }

        public SyncResult() {
            this.totalProcessed = 0;
            this.successCount = 0;
            this.errorCount = 0;
            this.errors = new List<String>();
        }
    }

    /**
     * @description Sync unsynced visits for a given salesperson.
     * @param userId The salesperson User Id.
     * @return SyncResult with counts and any errors.
     */
    @AuraEnabled
    public static SyncResult syncVisits(Id userId) {
        SyncResult result = new SyncResult();

        List<Visit__c> unsyncedVisits = [
            SELECT Id, Account__c, Visit_Date__c, Check_In_Time__c,
                   Check_In_Lat__c, Check_In_Long__c,
                   Offline_Created__c, Is_Synced__c
            FROM Visit__c
            WHERE Salesperson__c = :userId
              AND Offline_Created__c = true
              AND Is_Synced__c = false
            ORDER BY Check_In_Time__c ASC
            LIMIT 200
        ];

        if (unsyncedVisits.isEmpty()) return result;

        result.totalProcessed = unsyncedVisits.size();

        for (Visit__c v : unsyncedVisits) {
            v.Is_Synced__c = true;
            v.Sync_Time__c = DateTime.now();
        }

        List<Database.SaveResult> saveResults = Database.update(unsyncedVisits, false);
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (saveResults[i].isSuccess()) {
                result.successCount++;
            } else {
                result.errorCount++;
                for (Database.Error err : saveResults[i].getErrors()) {
                    result.errors.add('Visit ' + unsyncedVisits[i].Id + ': ' + err.getMessage());
                }
            }
        }

        return result;
    }

    /**
     * @description Sync unsynced orders for a given salesperson.
     * @param userId The salesperson User Id.
     * @return SyncResult with counts and any errors.
     */
    @AuraEnabled
    public static SyncResult syncOrders(Id userId) {
        SyncResult result = new SyncResult();

        List<Sales_Order__c> unsyncedOrders = [
            SELECT Id, Account__c, Order_Date__c,
                   Offline_Created__c, Is_Synced__c
            FROM Sales_Order__c
            WHERE Salesperson__c = :userId
              AND Offline_Created__c = true
              AND Is_Synced__c = false
            ORDER BY Order_Date__c ASC
            LIMIT 200
        ];

        if (unsyncedOrders.isEmpty()) return result;

        result.totalProcessed = unsyncedOrders.size();

        for (Sales_Order__c o : unsyncedOrders) {
            o.Is_Synced__c = true;
            o.Sync_Time__c = DateTime.now();
        }

        List<Database.SaveResult> saveResults = Database.update(unsyncedOrders, false);
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (saveResults[i].isSuccess()) {
                result.successCount++;
            } else {
                result.errorCount++;
                for (Database.Error err : saveResults[i].getErrors()) {
                    result.errors.add('Order ' + unsyncedOrders[i].Id + ': ' + err.getMessage());
                }
            }
        }

        return result;
    }

    /**
     * @description Sync all unsynced records (visits, orders, attendance) for a user.
     * @param userId The salesperson User Id.
     * @return Combined SyncResult.
     */
    @AuraEnabled
    public static SyncResult syncAll(Id userId) {
        SyncResult combined = new SyncResult();

        SyncResult visitResult = syncVisits(userId);
        SyncResult orderResult = syncOrders(userId);

        combined.totalProcessed = visitResult.totalProcessed + orderResult.totalProcessed;
        combined.successCount = visitResult.successCount + orderResult.successCount;
        combined.errorCount = visitResult.errorCount + orderResult.errorCount;
        combined.errors.addAll(visitResult.errors);
        combined.errors.addAll(orderResult.errors);

        return combined;
    }
}