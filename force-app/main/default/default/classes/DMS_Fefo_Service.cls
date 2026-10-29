/**
 * @description Single FEFO (First-Expiry-First-Out) allocator for distributor stock.
 *
 *              This logic previously existed near-verbatim in BOTH
 *              DMS_SecondaryBilling_Service and DMS_P2Fulfillment_Service, and the two copies
 *              had drifted: secondary billing excluded expired batches, P2 fulfilment did not —
 *              so a P2 dispatch could ship stock that was already past its expiry date.
 *              One implementation, one behaviour: expired batches are never allocated.
 */
public without sharing class DMS_Fefo_Service {

    /** One batch's contribution to satisfying a requested quantity. */
    public class Allocation {
        public Id productId;
        public String batch;
        public Date expiryDate;
        public Decimal quantity;
        public Decimal unitPrice;
        public Decimal currentClosing;
    }

    /**
     * Current, sellable stock for an account keyed by product, earliest expiry first.
     * Nulls sort last so dated batches are consumed before undated ones, and anything
     * already expired is excluded outright.
     */
    public static Map<Id, List<Distributor_Stock__c>> stockByProduct(Id accountId, Set<Id> productIds) {
        Map<Id, List<Distributor_Stock__c>> byProduct = new Map<Id, List<Distributor_Stock__c>>();
        Date today = Date.today();
        for (Distributor_Stock__c ds : [
            SELECT Product_Ext__c, Batch_No__c, Expiry_Date__c, Closing_Stock__c
            FROM Distributor_Stock__c
            WHERE Account__c = :accountId
              AND Product_Ext__c IN :productIds
              AND Is_Current__c = true
              AND Closing_Stock__c > 0
              AND (Expiry_Date__c = null OR Expiry_Date__c >= :today)
            ORDER BY Expiry_Date__c ASC NULLS LAST
        ]) {
            if (!byProduct.containsKey(ds.Product_Ext__c)) {
                byProduct.put(ds.Product_Ext__c, new List<Distributor_Stock__c>());
            }
            byProduct.get(ds.Product_Ext__c).add(ds);
        }
        return byProduct;
    }

    /**
     * Allocate `requested` units across the FEFO-ordered batches for a product.
     * Throws when the account cannot cover the request — callers must not ship short.
     *
     * @param sourceLabel names the stock pool in the error, e.g. 'distributor stock'.
     */
    public static List<Allocation> allocate(
        Id productId, Decimal requested, List<Distributor_Stock__c> batches,
        Decimal unitPrice, String sourceLabel
    ) {
        List<Allocation> result = new List<Allocation>();
        Decimal remaining = requested;

        if (batches != null) {
            for (Distributor_Stock__c ds : batches) {
                if (remaining <= 0) { break; }
                Decimal available = ds.Closing_Stock__c != null ? ds.Closing_Stock__c : 0;
                if (available <= 0) { continue; }

                Decimal take = Math.min(available, remaining);
                Allocation a = new Allocation();
                a.productId = productId;
                a.batch = ds.Batch_No__c;
                a.expiryDate = ds.Expiry_Date__c;
                a.quantity = take;
                a.unitPrice = unitPrice;
                a.currentClosing = available;
                result.add(a);
                remaining -= take;
            }
        }

        if (remaining > 0) {
            // Name the product rather than showing a record Id — this message goes
            // straight to a distributor in the portal, who cannot look an Id up.
            String label = String.valueOf(productId);
            for (Product_Extension__c p : [
                SELECT Name FROM Product_Extension__c WHERE Id = :productId LIMIT 1
            ]) {
                label = p.Name;
            }
            throw new DMS_SecondaryBillingException(
                'Insufficient ' + sourceLabel + ' for ' + label +
                '. Short by ' + remaining + ' unit(s).');
        }
        return result;
    }
}