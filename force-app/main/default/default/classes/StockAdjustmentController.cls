/**
 * @description Backs the Stock Adjustment Manager LWC and the on-approval
 * stock writeback service.
 *
 * Flow:
 *   1. User picks Warehouse + Product (+ Batch) → getStockInfo() returns
 *      the live Qty_On_Hand from Warehouse_Stock__c so the form can
 *      pre-fill System_Qty__c
 *   2. User enters Actual_Qty__c — Adjustment_Qty__c (= Actual - System)
 *      is computed client-side and round-tripped to save
 *   3. saveDraft() upserts as Draft
 *   4. submitForApproval() defers to ApprovalRouter — Status flips to
 *      "Submitted", routes to whoever the Approval_Rule__c for
 *      Stock_Adjustment__c points to
 *   5. On Approve (handled by trigger, not here): Warehouse_Stock__c
 *      Qty_On_Hand is updated and a Stock_Transaction__c row is logged
 */
public with sharing class StockAdjustmentController {

    @AuraEnabled(cacheable=true)
    public static List<Stock_Adjustment__c> getAllAdjustments() {
        return [
            SELECT Id, Name,
                   Warehouse__c, Warehouse__r.Name, Warehouse__r.Warehouse_Code__c,
                   Product__c, Product__r.Name, Product__r.ProductCode,
                   Batch_Number__c,
                   System_Qty__c, Actual_Qty__c, Adjustment_Qty__c,
                   Adjustment_Type__c, Reason__c,
                   Adjustment_Date__c, Status__c,
                   Adjusted_By__c, Adjusted_By__r.Name,
                   Approved_By__c, Approved_By__r.Name,
                   CreatedDate, LastModifiedDate
            FROM Stock_Adjustment__c
            ORDER BY CreatedDate DESC
            LIMIT 500
        ];
    }

    @AuraEnabled
    public static Stock_Adjustment__c saveDraft(Stock_Adjustment__c adjustment) {
        if (adjustment == null) {
            throw new AuraHandledException('Adjustment data is required.');
        }
        // Always recompute Adjustment_Qty server-side — never trust client math
        if (adjustment.Actual_Qty__c != null && adjustment.System_Qty__c != null) {
            adjustment.Adjustment_Qty__c = adjustment.Actual_Qty__c - adjustment.System_Qty__c;
        }
        if (adjustment.Adjustment_Date__c == null) adjustment.Adjustment_Date__c = Date.today();
        if (adjustment.Adjusted_By__c == null) adjustment.Adjusted_By__c = UserInfo.getUserId();
        if (String.isBlank(adjustment.Status__c)) adjustment.Status__c = 'Draft';

        upsert adjustment;
        return reloadOne(adjustment.Id);
    }

    @AuraEnabled
    public static void deleteAdjustment(Id adjustmentId) {
        if (adjustmentId == null) return;
        Stock_Adjustment__c existing = [
            SELECT Id, Status__c FROM Stock_Adjustment__c WHERE Id = :adjustmentId LIMIT 1
        ];
        if (existing.Status__c != 'Draft') {
            throw new AuraHandledException('Only Draft adjustments can be deleted.');
        }
        delete existing;
    }

    @AuraEnabled
    public static Id submitForApproval(Id adjustmentId, String comments) {
        if (adjustmentId == null) {
            throw new AuraHandledException('Adjustment Id is required.');
        }
        Stock_Adjustment__c adj = [
            SELECT Id, Status__c, Warehouse__c, Product__c, Reason__c,
                   Actual_Qty__c, System_Qty__c, Adjustment_Type__c
            FROM Stock_Adjustment__c WHERE Id = :adjustmentId LIMIT 1
        ];
        if (adj.Status__c != 'Draft') {
            throw new AuraHandledException('Only Draft adjustments can be submitted.');
        }
        // Basic validation before kicking the approval engine
        if (adj.Warehouse__c == null) throw new AuraHandledException('Warehouse is required.');
        if (adj.Product__c == null) throw new AuraHandledException('Product is required.');
        if (String.isBlank(adj.Adjustment_Type__c)) throw new AuraHandledException('Adjustment Type is required.');
        if (String.isBlank(adj.Reason__c)) throw new AuraHandledException('Reason is required.');
        if (adj.Actual_Qty__c == null) throw new AuraHandledException('Actual Quantity is required.');

        return ApprovalRouter.submit(adjustmentId, comments);
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getStockInfo(Id warehouseId, Id productId, String batchNumber) {
        Map<String, Object> result = new Map<String, Object>();
        result.put('exists', false);
        result.put('qtyOnHand', 0);
        result.put('qtyAvailable', 0);
        result.put('qtyReserved', 0);
        result.put('qtyDamaged', 0);

        if (warehouseId == null || productId == null) return result;

        String soql = 'SELECT Id, Qty_On_Hand__c, Qty_Available__c, Qty_Reserved__c, Qty_Damaged__c, '
            + 'Batch_Number__c FROM Warehouse_Stock__c '
            + 'WHERE Warehouse__c = :warehouseId AND Product__c = :productId';
        if (String.isNotBlank(batchNumber)) {
            soql += ' AND Batch_Number__c = :batchNumber';
        }
        soql += ' LIMIT 1';

        List<Warehouse_Stock__c> stocks = Database.query(soql);
        if (stocks.isEmpty()) return result;

        Warehouse_Stock__c s = stocks[0];
        result.put('exists', true);
        result.put('stockId', s.Id);
        result.put('qtyOnHand', s.Qty_On_Hand__c == null ? 0 : s.Qty_On_Hand__c);
        result.put('qtyAvailable', s.Qty_Available__c == null ? 0 : s.Qty_Available__c);
        result.put('qtyReserved', s.Qty_Reserved__c == null ? 0 : s.Qty_Reserved__c);
        result.put('qtyDamaged', s.Qty_Damaged__c == null ? 0 : s.Qty_Damaged__c);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, List<Map<String, String>>> getPicklistOptions() {
        Map<String, List<Map<String, String>>> result = new Map<String, List<Map<String, String>>>();
        result.put('Adjustment_Type__c', describePicklist('Adjustment_Type__c'));
        return result;
    }

    private static List<Map<String, String>> describePicklist(String fieldName) {
        List<Map<String, String>> values = new List<Map<String, String>>();
        Schema.DescribeFieldResult f = Stock_Adjustment__c.SObjectType
            .getDescribe().fields.getMap().get(fieldName).getDescribe();
        for (Schema.PicklistEntry e : f.getPicklistValues()) {
            if (e.isActive()) {
                values.add(new Map<String, String>{
                    'label' => e.getLabel(), 'value' => e.getValue()
                });
            }
        }
        return values;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchWarehouses(String term) {
        String pattern = String.isBlank(term) ? '%' : '%' + String.escapeSingleQuotes(term) + '%';
        List<Warehouse__c> rows = [
            SELECT Id, Name, Warehouse_Code__c, City__c
            FROM Warehouse__c
            WHERE Is_Active__c = true
              AND (Name LIKE :pattern OR Warehouse_Code__c LIKE :pattern)
            ORDER BY Name LIMIT 25
        ];
        List<Map<String, String>> out = new List<Map<String, String>>();
        for (Warehouse__c w : rows) {
            out.add(new Map<String, String>{
                'value' => w.Id, 'label' => w.Name,
                'subtitle' => (w.Warehouse_Code__c == null ? '' : w.Warehouse_Code__c + ' · ')
                    + (w.City__c == null ? '' : w.City__c)
            });
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> searchProducts(String term, Id warehouseId) {
        String pattern = String.isBlank(term) ? '%' : '%' + String.escapeSingleQuotes(term) + '%';
        // If a warehouse is given, only suggest products that already have a
        // stock row there — keeps the picker tightly relevant.
        List<Product2> rows;
        if (warehouseId != null) {
            Set<Id> warehouseProducts = new Set<Id>();
            for (Warehouse_Stock__c s : [
                SELECT Product__c FROM Warehouse_Stock__c
                WHERE Warehouse__c = :warehouseId
            ]) warehouseProducts.add(s.Product__c);

            if (warehouseProducts.isEmpty()) {
                // Fall through to global product search rather than returning
                // an empty list — admin should still be able to log a brand-new
                // product's first stock adjustment.
                rows = [
                    SELECT Id, Name, ProductCode FROM Product2
                    WHERE IsActive = true AND (Name LIKE :pattern OR ProductCode LIKE :pattern)
                    ORDER BY Name LIMIT 25
                ];
            } else {
                rows = [
                    SELECT Id, Name, ProductCode FROM Product2
                    WHERE Id IN :warehouseProducts
                      AND IsActive = true
                      AND (Name LIKE :pattern OR ProductCode LIKE :pattern)
                    ORDER BY Name LIMIT 25
                ];
            }
        } else {
            rows = [
                SELECT Id, Name, ProductCode FROM Product2
                WHERE IsActive = true AND (Name LIKE :pattern OR ProductCode LIKE :pattern)
                ORDER BY Name LIMIT 25
            ];
        }
        List<Map<String, String>> out = new List<Map<String, String>>();
        for (Product2 p : rows) {
            out.add(new Map<String, String>{
                'value' => p.Id, 'label' => p.Name,
                'subtitle' => p.ProductCode == null ? '' : p.ProductCode
            });
        }
        return out;
    }

    private static Stock_Adjustment__c reloadOne(Id adjId) {
        return [
            SELECT Id, Name,
                   Warehouse__c, Warehouse__r.Name, Warehouse__r.Warehouse_Code__c,
                   Product__c, Product__r.Name, Product__r.ProductCode,
                   Batch_Number__c,
                   System_Qty__c, Actual_Qty__c, Adjustment_Qty__c,
                   Adjustment_Type__c, Reason__c,
                   Adjustment_Date__c, Status__c,
                   Adjusted_By__c, Adjusted_By__r.Name,
                   Approved_By__c, Approved_By__r.Name,
                   CreatedDate, LastModifiedDate
            FROM Stock_Adjustment__c WHERE Id = :adjId
        ];
    }
}