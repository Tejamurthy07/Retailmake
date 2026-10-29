/**
 * @description Read helpers over distributor inventory (Distributor_Stock__c).
 *              Aggregates current on-hand per distributor+product across batches
 *              and surfaces near-expiry stock. Shared by the replenishment engine
 *              and (later) FEFO secondary billing.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_DistributorInventory_Service {

    /**
     * @description Current total on-hand per distributor+product, summed across
     *              all current batch snapshots.
     * @param accountIds Distributor account ids (required).
     * @param productIds Optional product filter; null/empty = all products.
     * @return Map keyed by "accountId|productId" to total closing stock.
     */
    public static Map<String, Decimal> getCurrentOnHand(Set<Id> accountIds, Set<Id> productIds) {
        Map<String, Decimal> onHand = new Map<String, Decimal>();
        if (accountIds == null || accountIds.isEmpty()) {
            return onHand;
        }
        Boolean filterProducts = (productIds != null && !productIds.isEmpty());

        List<Distributor_Stock__c> rows = filterProducts
            ? [SELECT Account__c, Product_Ext__c, Closing_Stock__c
               FROM Distributor_Stock__c
               WHERE Account__c IN :accountIds AND Is_Current__c = true
                 AND Product_Ext__c != null AND Product_Ext__c IN :productIds]
            : [SELECT Account__c, Product_Ext__c, Closing_Stock__c
               FROM Distributor_Stock__c
               WHERE Account__c IN :accountIds AND Is_Current__c = true
                 AND Product_Ext__c != null];

        for (Distributor_Stock__c ds : rows) {
            String key = key(ds.Account__c, ds.Product_Ext__c);
            Decimal closing = ds.Closing_Stock__c != null ? ds.Closing_Stock__c : 0;
            onHand.put(key, (onHand.containsKey(key) ? onHand.get(key) : 0) + closing);
        }
        return onHand;
    }

    /**
     * @description Current batch snapshots expiring within the given number of
     *              days (inclusive) that still hold stock.
     * @param withinDays Days-ahead window from today.
     * @return Distributor_Stock__c records nearing expiry, FEFO-ordered.
     */
    public static List<Distributor_Stock__c> getNearExpiry(Integer withinDays) {
        Date cutoff = Date.today().addDays(withinDays != null ? withinDays : 0);
        return [
            SELECT Id, Account__c, Product_Ext__c, Batch_No__c, Expiry_Date__c, Closing_Stock__c
            FROM Distributor_Stock__c
            WHERE Is_Current__c = true
              AND Closing_Stock__c > 0
              AND Expiry_Date__c != null
              AND Expiry_Date__c <= :cutoff
            ORDER BY Expiry_Date__c ASC
        ];
    }

    public static String key(Id accountId, Id productId) {
        return String.valueOf(accountId) + '|' + String.valueOf(productId);
    }
}