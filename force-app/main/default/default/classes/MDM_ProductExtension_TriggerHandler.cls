/**
 * @description Trigger handler for Product_Extension__c. Prevents deactivation
 *              of products that are referenced in active schemes or open orders.
 *
 * @author  SFA Development Team
 * @date    2024
 */
    public class MDM_ProductExtension_TriggerHandler extends TriggerHandler {

    protected override void beforeUpdate() {
        List<Product_Extension__c> newRecords = (List<Product_Extension__c>) Trigger.new;
        Map<Id, Product_Extension__c> oldMap = (Map<Id, Product_Extension__c>) Trigger.oldMap;
        preventDeactivationWithActiveReferences(newRecords, oldMap);
    }

    private void preventDeactivationWithActiveReferences(
        List<Product_Extension__c> newRecords,
        Map<Id, Product_Extension__c> oldMap
    ) {
        Set<Id> deactivatingIds = new Set<Id>();
        for (Product_Extension__c rec : newRecords) {
            Product_Extension__c oldRec = oldMap.get(rec.Id);
            if (oldRec.Is_Active__c == true && rec.Is_Active__c == false) {
                deactivatingIds.add(rec.Id);
            }
        }

        if (deactivatingIds.isEmpty()) return;

        // Check active schemes
        Set<Id> inActiveSchemes = new Set<Id>();
        for (Scheme_Product__c sp : [
            SELECT Product_Ext__c
            FROM Scheme_Product__c
            WHERE Product_Ext__c IN :deactivatingIds
              AND Scheme__r.Status__c = 'Active'
        ]) {
            inActiveSchemes.add(sp.Product_Ext__c);
        }

        // Check open orders
        Set<Id> inOpenOrders = new Set<Id>();
        for (Order_Line_Item__c oli : [
            SELECT Product_Ext__c
            FROM Order_Line_Item__c
            WHERE Product_Ext__c IN :deactivatingIds
              AND Sales_Order__r.Status__c NOT IN ('Delivered', 'Cancelled', 'Rejected')
        ]) {
            inOpenOrders.add(oli.Product_Ext__c);
        }

        for (Product_Extension__c rec : newRecords) {
            if (deactivatingIds.contains(rec.Id)) {
                if (inActiveSchemes.contains(rec.Id)) {
                    rec.Is_Active__c.addError('Cannot deactivate: product is referenced in active schemes.');
                }
                if (inOpenOrders.contains(rec.Id)) {
                    rec.Is_Active__c.addError('Cannot deactivate: product is referenced in open orders.');
                }
            }
        }
    }
}