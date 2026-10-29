/**
 * @description DMS replenishment engine. Compares current distributor on-hand
 *              against active Distributor_Stock_Norm__c records and, where on-hand
 *              has fallen to/below the reorder level, builds replenishment
 *              suggestions sized to (Max - on-hand). Suggestions can be returned
 *              for review or materialized as DRAFT replenishment orders
 *              (Primary_Order__c) which still require manual submit + approval
 *              before any fulfillment occurs.
 *
 *              Gated by the DMS master + norms/replenishment toggles.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_Replenishment_Service {

    /** A single product replenishment recommendation for one distributor. */
    public class Suggestion {
        public Id accountId;
        public Id productId;
        public Decimal onHand;
        public Decimal reorderLevel;
        public Decimal suggestedQty;

        public Suggestion(Id accountId, Id productId, Decimal onHand,
                          Decimal reorderLevel, Decimal suggestedQty) {
            this.accountId = accountId;
            this.productId = productId;
            this.onHand = onHand;
            this.reorderLevel = reorderLevel;
            this.suggestedQty = suggestedQty;
        }
    }

    /**
     * @description Builds replenishment suggestions without creating any records.
     * @param accountIds Optional distributor filter; null/empty = all distributors with active norms.
     */
    public static List<Suggestion> buildSuggestions(Set<Id> accountIds) {
        List<Suggestion> suggestions = new List<Suggestion>();

        Boolean filterAccounts = (accountIds != null && !accountIds.isEmpty());
        List<Distributor_Stock_Norm__c> norms = filterAccounts
            ? [SELECT Account__c, Product_Ext__c, Reorder_Level__c, Max_Stock_Level__c
               FROM Distributor_Stock_Norm__c
               WHERE Is_Active__c = true AND Account__c != null
                 AND Product_Ext__c != null AND Account__c IN :accountIds]
            : [SELECT Account__c, Product_Ext__c, Reorder_Level__c, Max_Stock_Level__c
               FROM Distributor_Stock_Norm__c
               WHERE Is_Active__c = true AND Account__c != null
                 AND Product_Ext__c != null];
        if (norms.isEmpty()) {
            return suggestions;
        }

        Set<Id> normAccountIds = new Set<Id>();
        Set<Id> normProductIds = new Set<Id>();
        for (Distributor_Stock_Norm__c n : norms) {
            normAccountIds.add(n.Account__c);
            normProductIds.add(n.Product_Ext__c);
        }

        Map<String, Decimal> onHand =
            DMS_DistributorInventory_Service.getCurrentOnHand(normAccountIds, normProductIds);

        for (Distributor_Stock_Norm__c n : norms) {
            String key = DMS_DistributorInventory_Service.key(n.Account__c, n.Product_Ext__c);
            Decimal have = onHand.containsKey(key) ? onHand.get(key) : 0;
            Decimal reorder = n.Reorder_Level__c != null ? n.Reorder_Level__c : 0;
            Decimal maxLevel = n.Max_Stock_Level__c != null ? n.Max_Stock_Level__c : 0;

            if (have <= reorder) {
                Decimal qty = maxLevel - have;
                if (qty > 0) {
                    suggestions.add(new Suggestion(n.Account__c, n.Product_Ext__c, have, reorder, qty));
                }
            }
        }
        return suggestions;
    }

    /**
     * @description Materializes replenishment suggestions as DRAFT indents, one
     *              indent per distributor with a line per replenished product.
     * @param accountIds Optional distributor filter; null/empty = all.
     * @return Ids of the indents created.
     */
    public static List<Id> generateReplenishmentIndents(Set<Id> accountIds) {
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_NORMS_REPLENISH)) {
            return new List<Id>();
        }

        List<Suggestion> suggestions = buildSuggestions(accountIds);
        if (suggestions.isEmpty()) {
            return new List<Id>();
        }

        // Group suggestions by distributor.
        Map<Id, List<Suggestion>> byAccount = new Map<Id, List<Suggestion>>();
        for (Suggestion s : suggestions) {
            if (!byAccount.containsKey(s.accountId)) {
                byAccount.put(s.accountId, new List<Suggestion>());
            }
            byAccount.get(s.accountId).add(s);
        }

        // Source warehouse so the order can be dispatched once approved.
        List<Warehouse__c> whs = [SELECT Id FROM Warehouse__c WHERE Is_Active__c = true ORDER BY Name LIMIT 1];
        Id sourceWh = whs.isEmpty() ? null : whs[0].Id;

        // One draft primary order per distributor.
        Map<Id, Primary_Order__c> orderByAccount = new Map<Id, Primary_Order__c>();
        for (Id acctId : byAccount.keySet()) {
            orderByAccount.put(acctId, new Primary_Order__c(
                Account__c = acctId,
                Order_Date__c = Date.today(),
                Status__c = DMS_Constants.INDENT_DRAFT,
                Warehouse__c = sourceWh,
                Notes__c = 'Auto-generated replenishment suggestion'
            ));
        }
        insert orderByAccount.values();

        List<Primary_Order_Line__c> lines = new List<Primary_Order_Line__c>();
        for (Id acctId : byAccount.keySet()) {
            Primary_Order__c order = orderByAccount.get(acctId);
            for (Suggestion s : byAccount.get(acctId)) {
                lines.add(new Primary_Order_Line__c(
                    Primary_Order__c = order.Id,
                    Product_Ext__c = s.productId,
                    Quantity__c = s.suggestedQty,
                    Base_Quantity__c = s.suggestedQty
                ));
            }
        }
        if (!lines.isEmpty()) {
            insert lines;
        }

        // Return the created order ids (the map is keyed by account, not order).
        List<Id> orderIds = new List<Id>();
        for (Primary_Order__c o : orderByAccount.values()) {
            orderIds.add(o.Id);
        }
        return orderIds;
    }

    /** @description Convenience entry point: replenish across all distributors. */
    public static List<Id> generateAll() {
        return generateReplenishmentIndents(null);
    }
}