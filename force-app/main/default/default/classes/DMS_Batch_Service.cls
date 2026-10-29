/**
 * @description Resolves free-text batch numbers to their Batch_Master__c record.
 *
 *              Batch identity across the system is a plain string (`Batch_No__c` /
 *              `Batch_Number__c` on Warehouse_Stock, Distributor_Stock, GRN_Line, Return_Line,
 *              Stock_Adjustment and Stock_Transfer_Line) with no referential integrity, so a
 *              typo silently creates a phantom batch that no master describes — and each
 *              document re-types its own expiry date rather than inheriting the batch's.
 *
 *              Batch_Master__c.Batch_Number__c is unique, so a batch number alone identifies the
 *              master. Stock writers use this to stamp the Batch_Master lookup and to take the
 *              expiry from the master, which is authoritative, falling back to the document's
 *              own value when the batch has no master (nothing is rejected — resolution is
 *              additive, so existing free-text batches keep working).
 */
public without sharing class DMS_Batch_Service {

    /** Batch number -> master. Blank/unknown batch numbers are simply absent from the map. */
    public static Map<String, Batch_Master__c> resolve(Set<String> batchNumbers) {
        Map<String, Batch_Master__c> byNumber = new Map<String, Batch_Master__c>();
        if (batchNumbers == null || batchNumbers.isEmpty()) { return byNumber; }

        Set<String> clean = new Set<String>();
        for (String b : batchNumbers) {
            if (String.isNotBlank(b)) { clean.add(b); }
        }
        if (clean.isEmpty()) { return byNumber; }

        for (Batch_Master__c bm : [
            SELECT Id, Batch_Number__c, Product_Ext__c, Expiry_Date__c, Status__c
            FROM Batch_Master__c
            WHERE Batch_Number__c IN :clean
        ]) {
            byNumber.put(bm.Batch_Number__c, bm);
        }
        return byNumber;
    }

    /** The master's Id for a batch number, or null when it has no master. */
    public static Id masterId(Map<String, Batch_Master__c> masters, String batchNumber) {
        Batch_Master__c bm = master(masters, batchNumber);
        return bm == null ? null : bm.Id;
    }

    /**
     * Expiry for a batch: the master's date wins, because it is the batch's own definition.
     * Falls back to the date the document carried when the batch has no master.
     */
    public static Date expiryFor(Map<String, Batch_Master__c> masters, String batchNumber, Date fallback) {
        Batch_Master__c bm = master(masters, batchNumber);
        return (bm != null && bm.Expiry_Date__c != null) ? bm.Expiry_Date__c : fallback;
    }

    private static Batch_Master__c master(Map<String, Batch_Master__c> masters, String batchNumber) {
        if (masters == null || String.isBlank(batchNumber)) { return null; }
        return masters.get(batchNumber);
    }
}