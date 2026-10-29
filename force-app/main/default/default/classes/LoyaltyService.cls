/**
 * @description Manages the reward-points wallet ledger (Loyalty_Points__c) for
 *              customer accounts. Credits points earned and debits points
 *              redeemed when a Sales Order reaches Approved status, reverses
 *              those movements if the order is later cancelled, and exposes
 *              balance/ledger read APIs for LWCs.
 *
 * The wallet balance is the running sum of Points__c across all Loyalty_Points
 * rows for an Account. Earned rows are positive; Redeemed/Expired rows are
 * stored as negative. Balance_After__c is a per-row running-balance snapshot.
 *
 * Crediting/debiting per order is idempotent — keyed on the order Name and
 * transaction type — so re-processing the same Delivered order never
 * double-credits or double-debits.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class LoyaltyService {

    private static final String TX_EARNED    = 'Earned';
    private static final String TX_REDEEMED  = 'Redeemed';
    private static final String TX_ADJUSTED  = 'Adjusted';
    private static final String REVERSAL_SUFFIX = ' (reversal)';

    /**
     * @description For each Sales Order in orderIds, writes Earned and Redeemed
     *              ledger rows where appropriate. Idempotent — skips orders that
     *              already have a row of the corresponding type referenced.
     *              Intended to be called when orders transition to Approved.
     */
    public static void recordWalletMovements(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return;
        }

        List<Sales_Order__c> orders = [
            SELECT Id, Name, Account__c,
                   Total_Reward_Points__c, Reward_Points_Redeemed__c
            FROM Sales_Order__c
            WHERE Id IN :orderIds AND Account__c != null
        ];
        if (orders.isEmpty()) {
            return;
        }

        // Pre-check existing ledger rows to keep this idempotent across retries.
        Set<String> existing = new Set<String>();
        for (Loyalty_Points__c lp : [
            SELECT Reference__c, Transaction_Type__c
            FROM Loyalty_Points__c
            WHERE Reference__c IN :collectOrderRefs(orders)
              AND Transaction_Type__c IN (:TX_EARNED, :TX_REDEEMED)
        ]) {
            existing.add(lp.Reference__c + '|' + lp.Transaction_Type__c);
        }

        // Current balances per account so Balance_After is computed in one pass.
        Map<Id, Decimal> balanceByAccount = computeCurrentBalances(collectAccountIds(orders));

        List<Loyalty_Points__c> toInsert = new List<Loyalty_Points__c>();
        for (Sales_Order__c o : orders) {
            Decimal earnedQty = o.Total_Reward_Points__c == null ? 0 : o.Total_Reward_Points__c;
            Decimal redeemedQty = o.Reward_Points_Redeemed__c == null ? 0 : o.Reward_Points_Redeemed__c;
            Decimal currentBalance = balanceByAccount.containsKey(o.Account__c)
                ? balanceByAccount.get(o.Account__c) : 0;

            if (earnedQty > 0 && !existing.contains(o.Name + '|' + TX_EARNED)) {
                currentBalance += earnedQty;
                toInsert.add(new Loyalty_Points__c(
                    Account__c          = o.Account__c,
                    Points__c           = earnedQty,
                    Balance_After__c    = currentBalance,
                    Transaction_Type__c = TX_EARNED,
                    Transaction_Date__c = Date.today(),
                    Reference__c        = o.Name,
                    Notes__c            = 'Earned on delivery of order ' + o.Name
                ));
                balanceByAccount.put(o.Account__c, currentBalance);
            }

            if (redeemedQty > 0 && !existing.contains(o.Name + '|' + TX_REDEEMED)) {
                currentBalance -= redeemedQty;
                toInsert.add(new Loyalty_Points__c(
                    Account__c          = o.Account__c,
                    Points__c           = -redeemedQty,
                    Balance_After__c    = currentBalance,
                    Transaction_Type__c = TX_REDEEMED,
                    Transaction_Date__c = Date.today(),
                    Reference__c        = o.Name,
                    Notes__c            = 'Redeemed on order ' + o.Name
                ));
                balanceByAccount.put(o.Account__c, currentBalance);
            }
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
    }

    /**
     * @description Reverses the wallet movements previously recorded for the
     *              given orders (used when an approved order is cancelled).
     *              Writes compensating Adjusted rows: earned points are removed
     *              and redeemed points are returned to the customer. Idempotent
     *              — an order whose movements were already reversed is skipped.
     */
    public static void reverseWalletMovements(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return;
        }

        Map<Id, Sales_Order__c> orders = new Map<Id, Sales_Order__c>([
            SELECT Id, Name, Account__c FROM Sales_Order__c WHERE Id IN :orderIds
        ]);
        if (orders.isEmpty()) {
            return;
        }

        // Map order Name -> order so we can match ledger rows by Reference__c.
        Map<String, Sales_Order__c> orderByName = new Map<String, Sales_Order__c>();
        for (Sales_Order__c o : orders.values()) {
            orderByName.put(o.Name, o);
        }

        // References to look up: the original order refs plus their type-specific
        // reversal refs (an order may have both an Earned and a Redeemed row).
        Set<String> lookupRefs = new Set<String>();
        for (String nm : orderByName.keySet()) {
            lookupRefs.add(nm);
            lookupRefs.add(reversalRef(nm, TX_EARNED));
            lookupRefs.add(reversalRef(nm, TX_REDEEMED));
        }

        // Existing original movements (Earned/Redeemed) for these orders, and any
        // reversals already written (so we don't reverse twice).
        Set<String> alreadyReversed = new Set<String>();
        List<Loyalty_Points__c> originals = new List<Loyalty_Points__c>();
        for (Loyalty_Points__c lp : [
            SELECT Account__c, Points__c, Transaction_Type__c, Reference__c
            FROM Loyalty_Points__c
            WHERE Reference__c IN :lookupRefs
        ]) {
            if (lp.Transaction_Type__c == TX_ADJUSTED && lp.Reference__c != null
                && lp.Reference__c.contains(REVERSAL_SUFFIX)) {
                alreadyReversed.add(lp.Reference__c);
            } else if (lp.Transaction_Type__c == TX_EARNED || lp.Transaction_Type__c == TX_REDEEMED) {
                originals.add(lp);
            }
        }
        if (originals.isEmpty()) {
            return;
        }

        Map<Id, Decimal> balanceByAccount = computeCurrentBalances(collectAccountIds(orders.values()));

        List<Loyalty_Points__c> toInsert = new List<Loyalty_Points__c>();
        for (Loyalty_Points__c orig : originals) {
            String reversalRef = reversalRef(orig.Reference__c, orig.Transaction_Type__c);
            // Compensating delta is the negation of the original signed points.
            Decimal compensating = -(orig.Points__c == null ? 0 : orig.Points__c);
            if (compensating == 0 || alreadyReversed.contains(reversalRef)) {
                continue;
            }
            Decimal currentBalance = balanceByAccount.containsKey(orig.Account__c)
                ? balanceByAccount.get(orig.Account__c) : 0;
            currentBalance += compensating;
            toInsert.add(new Loyalty_Points__c(
                Account__c          = orig.Account__c,
                Points__c           = compensating,
                Balance_After__c    = currentBalance,
                Transaction_Type__c = TX_ADJUSTED,
                Transaction_Date__c = Date.today(),
                Reference__c        = reversalRef,
                Notes__c            = 'Reversed ' + orig.Transaction_Type__c.toLowerCase()
                                      + ' points on cancellation of order ' + orig.Reference__c
            ));
            balanceByAccount.put(orig.Account__c, currentBalance);
            // Guard against reversing the same original twice within this batch.
            alreadyReversed.add(reversalRef);
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
    }

    // ── @AuraEnabled read APIs for LWCs ─────────────────────────────────────

    /**
     * @description Returns the current points balance for an Account — the sum
     *              of all Loyalty_Points.Points (Earned/Redeemed/Expired/Adjusted).
     */
    @AuraEnabled(cacheable=true)
    public static Decimal getBalance(Id accountId) {
        if (accountId == null) {
            return 0;
        }
        AggregateResult ar = [
            SELECT SUM(Points__c) total
            FROM Loyalty_Points__c
            WHERE Account__c = :accountId
        ];
        Decimal total = (Decimal) ar.get('total');
        return total == null ? 0 : total;
    }

    /**
     * @description Returns the most recent wallet transactions for a customer.
     */
    @AuraEnabled(cacheable=true)
    public static List<Loyalty_Points__c> getLedger(Id accountId, Integer recordLimit) {
        if (accountId == null) {
            return new List<Loyalty_Points__c>();
        }
        Integer lim = (recordLimit == null || recordLimit <= 0) ? 20 : recordLimit;
        return [
            SELECT Id, Name, Points__c, Balance_After__c, Transaction_Type__c,
                   Transaction_Date__c, Reference__c, Notes__c, Expiry_Date__c
            FROM Loyalty_Points__c
            WHERE Account__c = :accountId
            ORDER BY Transaction_Date__c DESC, CreatedDate DESC
            LIMIT :lim
        ];
    }

    // ── Private helpers ─────────────────────────────────────────────────────

    // Builds the unique reversal reference for an original movement of a given
    // transaction type, e.g. "SO-0001 (reversal) Earned".
    private static String reversalRef(String orderName, String origType) {
        return orderName + REVERSAL_SUFFIX + ' ' + origType;
    }

    private static Set<String> collectOrderRefs(List<Sales_Order__c> orders) {
        Set<String> refs = new Set<String>();
        for (Sales_Order__c o : orders) {
            refs.add(o.Name);
        }
        return refs;
    }

    private static Set<Id> collectAccountIds(List<Sales_Order__c> orders) {
        Set<Id> ids = new Set<Id>();
        for (Sales_Order__c o : orders) {
            if (o.Account__c != null) {
                ids.add(o.Account__c);
            }
        }
        return ids;
    }

    private static Map<Id, Decimal> computeCurrentBalances(Set<Id> accountIds) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        if (accountIds.isEmpty()) {
            return result;
        }
        for (AggregateResult ar : [
            SELECT Account__c acc, SUM(Points__c) total
            FROM Loyalty_Points__c
            WHERE Account__c IN :accountIds
            GROUP BY Account__c
        ]) {
            Decimal total = (Decimal) ar.get('total');
            result.put((Id) ar.get('acc'), total == null ? 0 : total);
        }
        return result;
    }
}