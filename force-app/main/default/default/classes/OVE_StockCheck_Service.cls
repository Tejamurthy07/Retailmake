/**
 * @description Service class for Stock Check activity during outlet visits.
 *              Uses existing Distributor_Stock__c and Product_Extension__c objects.
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class OVE_StockCheck_Service {

    public static final String FEATURE_STOCK_CHECK = 'OVE-010';

    /**
     * Get distributor stock for an account (outlet)
     */
    public static List<Distributor_Stock__c> getDistributorStock(Id accountId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_STOCK_CHECK)) {
            return new List<Distributor_Stock__c>();
        }
        return [
            SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Opening_Stock__c,
                   Received_Qty__c, Sold_Qty__c, Closing_Stock__c, Damaged_Qty__c,
                   Batch_No__c, Expiry_Date__c, Is_Current__c, Stock_Date__c
            FROM Distributor_Stock__c
            WHERE Account__c = :accountId
              AND Is_Current__c = true
            ORDER BY Product_Ext__r.Name
            LIMIT 200
        ];
    }

    /**
     * Search products for stock check
     */
    public static List<Product_Extension__c> getProductsForStockCheck(String searchTerm) {
        String searchKey = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [
            SELECT Id, Name, SKU_Code__c, Product_Category__c, Product_Category__r.Name,
                   Brand__c, Unit_of_Measure__c, MRP__c
            FROM Product_Extension__c
            WHERE Is_Active__c = true
              AND (Name LIKE :searchKey OR SKU_Code__c LIKE :searchKey OR Brand__c LIKE :searchKey)
            ORDER BY Name
            LIMIT 20
        ];
    }

    /**
     * Save stock entries linked to a visit
     */
    public static List<Distributor_Stock__c> saveStockEntries(String stockJson, Id visitId, Id accountId) {
        List<Object> rawEntries = (List<Object>) JSON.deserializeUntyped(stockJson);

        List<Map<String, Object>> entries = new List<Map<String, Object>>();
        Set<Id> productIds = new Set<Id>();
        for (Object rawEntry : rawEntries) {
            Map<String, Object> e = (Map<String, Object>) rawEntry;
            if (e.get('productId') == null) { continue; }
            entries.add(e);
            productIds.add((Id) e.get('productId'));
        }
        if (entries.isEmpty()) { return new List<Distributor_Stock__c>(); }

        // The distributor's transactional position (GRN in, secondary sell-out, returns...).
        // A stock check must chain from THIS, not from the opening figure the rep's phone
        // happened to be holding — that could be stale and silently overwrote the real book
        // position, because this snapshot is inserted with Is_Current__c = true.
        Map<String, Decimal> systemClosing = new Map<String, Decimal>();
        for (Distributor_Stock__c ds : [
            SELECT Product_Ext__c, Batch_No__c, Closing_Stock__c
            FROM Distributor_Stock__c
            WHERE Account__c = :accountId AND Product_Ext__c IN :productIds AND Is_Current__c = true
        ]) {
            systemClosing.put(checkKey(ds.Product_Ext__c, ds.Batch_No__c),
                              ds.Closing_Stock__c != null ? ds.Closing_Stock__c : 0);
        }

        List<Distributor_Stock__c> stockRecords = new List<Distributor_Stock__c>();
        List<Decimal> variances = new List<Decimal>();          // index-aligned with stockRecords
        List<Id> varProducts = new List<Id>();
        List<String> varBatches = new List<String>();

        for (Map<String, Object> entry : entries) {
            Id productId = (Id) entry.get('productId');
            String batch = entry.get('batch') != null ? String.valueOf(entry.get('batch')) : null;
            String key = checkKey(productId, batch);

            Decimal opening  = systemClosing.containsKey(key) ? systemClosing.get(key) : 0;
            Decimal received = toDecimal(entry.get('received'));
            Decimal sold     = toDecimal(entry.get('sold'));
            Decimal damaged  = toDecimal(entry.get('damaged'));

            // A stock check is a PHYSICAL COUNT, so the counted figure wins. Previously the
            // rep's closing was written and then immediately overwritten by the trigger's
            // formula (opening + received - sold - damaged), so what they counted was lost.
            // Now the difference from the book position is booked as a real variance —
            // found stock (received) or shrinkage (damaged) — which makes the derived closing
            // equal the counted figure and leaves an auditable trail.
            Decimal variance = 0;
            if (entry.containsKey('closing') && entry.get('closing') != null) {
                variance = toDecimal(entry.get('closing')) - (opening + received - sold - damaged);
                if (variance > 0) {
                    received += variance;
                } else if (variance < 0) {
                    damaged += Math.abs(variance);
                }
            }

            Distributor_Stock__c stock = new Distributor_Stock__c();
            if (entry.containsKey('id') && entry.get('id') != null) {
                stock.Id = (Id) entry.get('id');
            }
            stock.Account__c = accountId;
            stock.Visit__c = visitId;
            stock.Product_Ext__c = productId;
            stock.Batch_No__c = batch;
            stock.Opening_Stock__c = opening;
            stock.Received_Qty__c = received;
            stock.Sold_Qty__c = sold;
            stock.Damaged_Qty__c = damaged;
            // Closing_Stock__c is derived by INV_DistributorStock_TriggerHandler and now
            // resolves to the counted figure; setting it here would just be overwritten.
            if (entry.containsKey('expiry') && entry.get('expiry') != null) {
                stock.Expiry_Date__c = Date.valueOf(String.valueOf(entry.get('expiry')));
            }
            stock.Stock_Date__c = Date.today();
            stock.Is_Current__c = true;

            stockRecords.add(stock);
            variances.add(variance);
            varProducts.add(productId);
            varBatches.add(batch);
        }

        upsert stockRecords;

        // Audit trail. The stock check was the only distributor-stock writer that recorded no
        // Stock_Transaction__c at all, so a physical count could move the position with nothing
        // in the ledger to explain it.
        List<Stock_Transaction__c> txns = new List<Stock_Transaction__c>();
        for (Integer i = 0; i < stockRecords.size(); i++) {
            Decimal variance = variances[i];
            if (variance == 0) { continue; }
            txns.add(new Stock_Transaction__c(
                Account__c          = accountId,
                Product_Ext__c      = varProducts[i],
                Batch_Number__c     = varBatches[i],
                Direction__c        = variance > 0 ? DMS_Constants.DIRECTION_IN : DMS_Constants.DIRECTION_OUT,
                Transaction_Type__c = variance > 0
                    ? DMS_Constants.TXN_ADJUSTMENT_ADD : DMS_Constants.TXN_ADJUSTMENT_DEDUCT,
                Quantity__c         = Math.abs(variance),
                Transaction_Date__c = Datetime.now(),
                Reference_Type__c   = 'Stock_Check',
                Reference_Id__c     = visitId
            ));
        }
        if (!txns.isEmpty()) { insert txns; }

        // Mark visit as stock check completed
        Visit__c visit = new Visit__c(Id = visitId, Stock_Check_Completed__c = true);
        update visit;

        return stockRecords;
    }

    private static String checkKey(Id productId, String batch) {
        return String.valueOf(productId) + '|' + (String.isNotBlank(batch) ? batch : '');
    }

    /**
     * Get last stock check entries for pre-fill
     */
    public static List<Distributor_Stock__c> getLastStockCheck(Id accountId) {
        return [
            SELECT Id, Product_Ext__c, Product_Ext__r.Name, Opening_Stock__c,
                   Received_Qty__c, Sold_Qty__c, Closing_Stock__c, Damaged_Qty__c,
                   Batch_No__c, Expiry_Date__c, Stock_Date__c
            FROM Distributor_Stock__c
            WHERE Account__c = :accountId
              AND Is_Current__c = true
            ORDER BY Product_Ext__r.Name
            LIMIT 200
        ];
    }

    private static Decimal toDecimal(Object val) {
        if (val == null) return 0;
        if (val instanceof Decimal) return (Decimal) val;
        if (val instanceof Integer) return Decimal.valueOf((Integer) val);
        if (val instanceof Long) return Decimal.valueOf((Long) val);
        if (val instanceof Double) return Decimal.valueOf((Double) val);
        return Decimal.valueOf(String.valueOf(val));
    }
}