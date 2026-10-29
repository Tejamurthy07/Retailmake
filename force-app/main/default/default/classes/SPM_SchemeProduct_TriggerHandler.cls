/**
 * @description Trigger handler for Scheme_Product__c. Validates that products
 *              are active and prevents duplicate product entries per scheme.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class SPM_SchemeProduct_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        List<Scheme_Product__c> newRecords = (List<Scheme_Product__c>) Trigger.new;
        validateActiveProducts(newRecords);
        checkDuplicateProducts(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        List<Scheme_Product__c> newRecords = (List<Scheme_Product__c>) Trigger.new;
        validateActiveProducts(newRecords);
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private void validateActiveProducts(List<Scheme_Product__c> records) {
        Set<Id> productIds = new Set<Id>();
        for (Scheme_Product__c rec : records) {
            if (rec.Product_Ext__c != null) {
                productIds.add(rec.Product_Ext__c);
            }
        }

        if (productIds.isEmpty()) return;

        Map<Id, Product_Extension__c> products = new Map<Id, Product_Extension__c>([
            SELECT Id, Is_Active__c, Name
            FROM Product_Extension__c
            WHERE Id IN :productIds
        ]);

        for (Scheme_Product__c rec : records) {
            if (rec.Product_Ext__c != null && products.containsKey(rec.Product_Ext__c)) {
                Product_Extension__c prod = products.get(rec.Product_Ext__c);
                if (!prod.Is_Active__c) {
                    rec.Product_Ext__c.addError('Product "' + prod.Name + '" is inactive and cannot be added to a scheme.');
                }
            }
        }
    }

    private void checkDuplicateProducts(List<Scheme_Product__c> records) {
        Set<Id> schemeIds = new Set<Id>();
        for (Scheme_Product__c rec : records) {
            if (rec.Scheme__c != null) schemeIds.add(rec.Scheme__c);
        }

        if (schemeIds.isEmpty()) return;

        Map<String, Scheme_Product__c> existingProducts = new Map<String, Scheme_Product__c>();
        for (Scheme_Product__c existing : [
            SELECT Id, Scheme__c, Product_Ext__c
            FROM Scheme_Product__c
            WHERE Scheme__c IN :schemeIds
        ]) {
            String key = existing.Scheme__c + '|' + existing.Product_Ext__c;
            existingProducts.put(key, existing);
        }

        Set<String> batchKeys = new Set<String>();
        for (Scheme_Product__c rec : records) {
            String key = rec.Scheme__c + '|' + rec.Product_Ext__c;
            if (existingProducts.containsKey(key) || batchKeys.contains(key)) {
                rec.addError('This product is already added to this scheme.');
            }
            batchKeys.add(key);
        }
    }
}