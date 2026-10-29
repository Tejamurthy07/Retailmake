/**
 * @description DMS price resolution. Resolves the applicable distributor-specific
 *              price for products from Price_List__c, honoring the same dimensions
 *              and priority as OMS_OrderPricing_Service (Customer > Category >
 *              Territory > Channel), effective dates, and Min_Qty tiers. Falls back
 *              to the product master Unit_Price__c when no price-list entry applies.
 *
 *              Used by the portal catalog/order entry (display + live qty tiers) and
 *              by the P1/P2/secondary fulfillment services (billed price).
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_Pricing_Service {

    /** A price break: unit price that applies from minQty upward. */
    public class PriceTier {
        @AuraEnabled public Decimal minQty;
        @AuraEnabled public Decimal unitPrice;
    }

    /** Resolved pricing for one product in an account context. */
    public class ProductPrice {
        @AuraEnabled public Id productId;
        @AuraEnabled public Decimal basePrice;          // product master Unit_Price__c
        @AuraEnabled public Decimal listPrice;          // applicable price at qty 1
        @AuraEnabled public Boolean fromPriceList = false;
        @AuraEnabled public List<PriceTier> tiers = new List<PriceTier>();
    }

    /**
     * @description Resolves pricing (with qty tiers) for a set of products in the
     *              given account context.
     */
    public static Map<Id, ProductPrice> resolve(Set<Id> productIds, Id accountId) {
        Map<Id, ProductPrice> out = new Map<Id, ProductPrice>();
        if (productIds == null || productIds.isEmpty()) {
            return out;
        }

        Map<Id, Product_Extension__c> prods = new Map<Id, Product_Extension__c>([
            SELECT Id, Unit_Price__c, Product_Category__c FROM Product_Extension__c WHERE Id IN :productIds
        ]);

        Id accId = null, terrId = null;
        String channel = null;
        if (accountId != null) {
            List<Account> a = [SELECT Id, Channel__c, Territory__c FROM Account WHERE Id = :accountId];
            if (!a.isEmpty()) { accId = a[0].Id; terrId = a[0].Territory__c; channel = a[0].Channel__c; }
        }

        Map<Id, List<Price_List__c>> byProduct = new Map<Id, List<Price_List__c>>();
        for (Price_List__c pl : [
            SELECT Id, Product_Ext__c, Channel__c, Customer__c, Category__c, Territory__c,
                   Priority__c, Unit_Price__c, Min_Qty__c
            FROM Price_List__c
            WHERE Product_Ext__c IN :productIds AND Is_Active__c = true
              AND Effective_From__c <= TODAY AND (Effective_To__c >= TODAY OR Effective_To__c = null)
            ORDER BY Priority__c ASC, Effective_From__c DESC
        ]) {
            if (!byProduct.containsKey(pl.Product_Ext__c)) {
                byProduct.put(pl.Product_Ext__c, new List<Price_List__c>());
            }
            byProduct.get(pl.Product_Ext__c).add(pl);
        }

        for (Id pid : productIds) {
            ProductPrice pp = new ProductPrice();
            pp.productId = pid;
            Decimal master = prods.containsKey(pid) ? nz(prods.get(pid).Unit_Price__c) : 0;
            pp.basePrice = master;
            Id catId = prods.containsKey(pid) ? prods.get(pid).Product_Category__c : null;

            // Candidate entries matching the account/product dimensions (priority order, min-qty ignored here).
            List<Price_List__c> cands = new List<Price_List__c>();
            if (byProduct.containsKey(pid)) {
                for (Price_List__c pl : byProduct.get(pid)) {
                    if (dimMatch(pl, accId, catId, terrId, channel)) { cands.add(pl); }
                }
            }

            // Quantity breakpoints (always include 1).
            Set<Decimal> bpSet = new Set<Decimal>{ 1 };
            for (Price_List__c pl : cands) {
                bpSet.add((pl.Min_Qty__c != null && pl.Min_Qty__c > 1) ? pl.Min_Qty__c : 1);
            }
            List<Decimal> bps = new List<Decimal>(bpSet);
            bps.sort();

            Decimal prev = null;
            for (Decimal q : bps) {
                Decimal price = priceAtQty(cands, q, master);
                if (prev == null || price != prev) {
                    PriceTier t = new PriceTier();
                    t.minQty = q;
                    t.unitPrice = price;
                    pp.tiers.add(t);
                    prev = price;
                }
            }
            if (pp.tiers.isEmpty()) {
                PriceTier t = new PriceTier();
                t.minQty = 1;
                t.unitPrice = master;
                pp.tiers.add(t);
            }
            pp.listPrice = pp.tiers[0].unitPrice;
            pp.fromPriceList = !cands.isEmpty();
            out.put(pid, pp);
        }
        return out;
    }

    /**
     * @description Qty-aware billed price per product for fulfillment. Returns the
     *              applicable unit price for each product at its ordered quantity.
     */
    public static Map<Id, Decimal> priceForLines(Map<Id, Decimal> qtyByProduct, Id accountId) {
        Map<Id, Decimal> out = new Map<Id, Decimal>();
        if (qtyByProduct == null || qtyByProduct.isEmpty()) {
            return out;
        }
        Map<Id, ProductPrice> resolved = resolve(qtyByProduct.keySet(), accountId);
        for (Id pid : qtyByProduct.keySet()) {
            ProductPrice pp = resolved.get(pid);
            Decimal qty = nz(qtyByProduct.get(pid));
            Decimal price = (pp != null) ? pp.basePrice : 0;
            if (pp != null) {
                for (PriceTier t : pp.tiers) { if (qty >= t.minQty) { price = t.unitPrice; } }
            }
            out.put(pid, price);
        }
        return out;
    }

    // ── Helpers ───────────────────────────────────────────────────────────
    private static Boolean dimMatch(Price_List__c pl, Id accId, Id catId, Id terrId, String channel) {
        if (pl.Customer__c != null && (accId == null || pl.Customer__c != accId)) { return false; }
        if (pl.Category__c != null && (catId == null || pl.Category__c != catId)) { return false; }
        if (pl.Territory__c != null && (terrId == null || pl.Territory__c != terrId)) { return false; }
        if (String.isNotBlank(pl.Channel__c) && (String.isBlank(channel) || pl.Channel__c != channel)) { return false; }
        return true;
    }

    private static Decimal priceAtQty(List<Price_List__c> cands, Decimal qty, Decimal fallback) {
        // Among entries whose min-qty is met, prefer the most specific dimension
        // (lowest Priority__c); within the same priority prefer the highest min-qty break.
        Price_List__c best = null;
        Decimal bestPrio = null, bestMq = null;
        for (Price_List__c pl : cands) {
            Decimal mq = (pl.Min_Qty__c != null && pl.Min_Qty__c > 0) ? pl.Min_Qty__c : 0;
            if (qty < mq) { continue; }
            Decimal prio = (pl.Priority__c != null) ? pl.Priority__c : 999;
            if (best == null || prio < bestPrio || (prio == bestPrio && mq > bestMq)) {
                best = pl; bestPrio = prio; bestMq = mq;
            }
        }
        return best != null ? best.Unit_Price__c : fallback;
    }

    private static Decimal nz(Decimal d) { return d == null ? 0 : d; }
}