/**
 * @description Availability & Stock Depth visit activity. Lists the audited
 *              products (five FMCG categories) with SKU, RSP (product MRP),
 *              minimum qty and system (warehouse) stock, and saves the rep's
 *              per-product capture of observed shelf stock + shelf selling price
 *              into Availability_Check__c, flagging the visit complete.
 */
public with sharing class OVE_AvailabilityController {

    // Categories audited by this activity. Edit to change the demo scope.
    private static final Set<String> CATEGORY_NAMES = new Set<String>{
        'Biscuit', 'Coffee', 'Candy', 'Wafer & Chocolate', 'Instant Food'
    };

    /**
     * @description The products already captured on this visit, so the tab
     *              rehydrates the rep's added list. Empty for a fresh visit —
     *              the rep builds the list with searchAvailabilityProducts.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getAvailabilityData(Id accountId, Id visitId) {
        try {
            Map<Id, Availability_Check__c> priorByProduct = new Map<Id, Availability_Check__c>();
            if (visitId != null) {
                for (Availability_Check__c a : [
                    SELECT Product_Ext__c, Observed_Stock__c, Shelf_Selling_Price__c
                    FROM Availability_Check__c WHERE Visit__c = :visitId
                ]) {
                    priorByProduct.put(a.Product_Ext__c, a);
                }
            }
            if (priorByProduct.isEmpty()) return new List<Map<String, Object>>();

            List<Product_Extension__c> prods = [
                SELECT Id, Name, SKU_Code__c, MRP__c, Min_Order_Qty__c, Product_Category__r.Name
                FROM Product_Extension__c WHERE Id IN :priorByProduct.keySet()
                ORDER BY Product_Category__r.Name, Name
            ];
            return buildRows(prods, priorByProduct);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Searches the audited categories for products to add to the
     *              audit, returning each with its reference data (SKU, RSP, min
     *              qty, system stock). Empty term returns nothing.
     */
    @AuraEnabled
    public static List<Map<String, Object>> searchAvailabilityProducts(String searchTerm) {
        try {
            if (String.isBlank(searchTerm)) return new List<Map<String, Object>>();
            String term = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            List<Product_Extension__c> prods = [
                SELECT Id, Name, SKU_Code__c, MRP__c, Min_Order_Qty__c, Product_Category__r.Name
                FROM Product_Extension__c
                WHERE Is_Active__c = true
                  AND Product_Category__r.Name IN :CATEGORY_NAMES
                  AND (Name LIKE :term OR SKU_Code__c LIKE :term OR Brand__c LIKE :term)
                ORDER BY Product_Category__r.Name, Name
                LIMIT 25
            ];
            return buildRows(prods, new Map<Id, Availability_Check__c>());
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Builds row maps with reference data + system stock + any prior capture. */
    private static List<Map<String, Object>> buildRows(
            List<Product_Extension__c> prods, Map<Id, Availability_Check__c> priorByProduct) {
        Set<Id> productIds = new Set<Id>();
        for (Product_Extension__c p : prods) productIds.add(p.Id);

        Map<Id, Decimal> systemStock = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Product_Ext__c pid, SUM(Qty_Available__c) qty
            FROM Warehouse_Stock__c WHERE Product_Ext__c IN :productIds
            GROUP BY Product_Ext__c
        ]) {
            systemStock.put((Id) ar.get('pid'), (Decimal) ar.get('qty'));
        }

        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Product_Extension__c p : prods) {
            Availability_Check__c prior = priorByProduct.get(p.Id);
            rows.add(new Map<String, Object>{
                'productId'     => p.Id,
                'productName'   => p.Name,
                'sku'           => p.SKU_Code__c,
                'category'      => p.Product_Category__r == null ? '' : p.Product_Category__r.Name,
                'rsp'           => p.MRP__c,
                'minQty'        => p.Min_Order_Qty__c,
                'systemStock'   => systemStock.containsKey(p.Id) ? systemStock.get(p.Id) : 0,
                'observedStock' => prior == null ? null : prior.Observed_Stock__c,
                'sellingPrice'  => prior == null ? null : prior.Shelf_Selling_Price__c
            });
        }
        return rows;
    }

    /**
     * @description Saves the rep's capture. Replaces this visit's rows with the
     *              submitted set (only products the rep entered stock or price
     *              on), snapshots RSP / min qty / system stock for audit, and
     *              marks the visit's Availability activity complete.
     */
    @AuraEnabled
    public static void saveAvailability(String entriesJson, Id visitId, Id accountId) {
        try {
            List<Object> raw = (List<Object>) JSON.deserializeUntyped(entriesJson);

            if (visitId != null) {
                delete [SELECT Id FROM Availability_Check__c WHERE Visit__c = :visitId];
            }

            List<Availability_Check__c> toInsert = new List<Availability_Check__c>();
            for (Object o : raw) {
                Map<String, Object> m = (Map<String, Object>) o;
                Object pid = m.get('productId');
                if (pid == null) continue;
                Decimal observed = toDec(m.get('observedStock'));
                Decimal price = toDec(m.get('sellingPrice'));
                if (observed == null && price == null) continue;   // nothing captured
                toInsert.add(new Availability_Check__c(
                    Visit__c = visitId,
                    Account__c = accountId,
                    Product_Ext__c = (Id) pid,
                    Observed_Stock__c = observed,
                    Shelf_Selling_Price__c = price,
                    System_Stock__c = toDec(m.get('systemStock')),
                    RSP_Snapshot__c = toDec(m.get('rsp')),
                    Min_Qty_Snapshot__c = toDec(m.get('minQty')),
                    Stock_Date__c = Date.today(),
                    Is_Current__c = true
                ));
            }
            if (!toInsert.isEmpty()) insert toInsert;

            if (visitId != null) {
                update new Visit__c(Id = visitId, Availability_Check_Completed__c = true);
            }
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static Decimal toDec(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return (Decimal) ((Integer) v);
        String s = String.valueOf(v).trim();
        if (String.isBlank(s)) return null;
        try { return Decimal.valueOf(s); } catch (Exception e) { return null; }
    }
}