/**
 * @description Manages per-customer scheme usage tracking and enforcement of the
 *              Max_Uses_Per_Customer__c cap. Writes Scheme_Usage__c ledger rows
 *              when Sales Orders reach Delivered status and exposes a filter
 *              the scheme engine uses to drop schemes a customer has maxed out.
 *
 * One usage row per (Account, Scheme, Sales Order). A single order touching the
 * same scheme on multiple lines counts as ONE use — see notes on
 * recordDeliveredUsage.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class SPM_SchemeUsage_Service {

    /**
     * @description Writes one Scheme_Usage__c row per (Account, Scheme) for the
     *              given Sales Orders. Called from OMS_SalesOrder_TriggerHandler
     *              when Order_Status__c transitions to 'Delivered'. Idempotent:
     *              if a usage row already exists for an (Account, Scheme, Order)
     *              we skip it, so re-firing the trigger never double-counts.
     */
    public static void recordDeliveredUsage(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) return;

        // Pull every line that used a scheme, plus the parent order's account
        List<Order_Line_Item__c> lines = [
            SELECT Id, Sales_Order__c, Sales_Order__r.Account__c,
                   Scheme__c, Scheme_Discount__c, Free_Quantity__c, Quantity__c,
                   Scheme__r.Scheme_Type__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :orderIds
              AND Scheme__c != null
              AND Sales_Order__r.Account__c != null
        ];
        if (lines.isEmpty()) return;

        // Group by (orderId, schemeId) — one usage row per pair, summing benefits
        Map<String, Scheme_Usage__c> byPair = new Map<String, Scheme_Usage__c>();
        for (Order_Line_Item__c line : lines) {
            String key = String.valueOf(line.Sales_Order__c) + '|' + String.valueOf(line.Scheme__c);
            Scheme_Usage__c u = byPair.get(key);
            if (u == null) {
                u = new Scheme_Usage__c(
                    Account__c = line.Sales_Order__r.Account__c,
                    Scheme__c = line.Scheme__c,
                    Sales_Order__c = line.Sales_Order__c,
                    Benefit_Type__c = mapBenefitType(line),
                    Benefit_Amount__c = 0,
                    Used_At__c = Datetime.now()
                );
                byPair.put(key, u);
            }
            Decimal disc = line.Scheme_Discount__c == null ? 0 : line.Scheme_Discount__c;
            u.Benefit_Amount__c = (u.Benefit_Amount__c == null ? 0 : u.Benefit_Amount__c) + disc;
        }

        // Skip pairs that already have a usage row (idempotency).
        Set<Id> orderIdsToCheck = new Set<Id>();
        Set<Id> schemeIdsToCheck = new Set<Id>();
        for (Scheme_Usage__c u : byPair.values()) {
            orderIdsToCheck.add(u.Sales_Order__c);
            schemeIdsToCheck.add(u.Scheme__c);
        }
        Set<String> existingPairs = new Set<String>();
        for (Scheme_Usage__c existing : [
            SELECT Sales_Order__c, Scheme__c
            FROM Scheme_Usage__c
            WHERE Sales_Order__c IN :orderIdsToCheck
              AND Scheme__c IN :schemeIdsToCheck
        ]) {
            existingPairs.add(String.valueOf(existing.Sales_Order__c) + '|' +
                              String.valueOf(existing.Scheme__c));
        }

        List<Scheme_Usage__c> toInsert = new List<Scheme_Usage__c>();
        for (String key : byPair.keySet()) {
            if (!existingPairs.contains(key)) toInsert.add(byPair.get(key));
        }
        if (!toInsert.isEmpty()) insert toInsert;
    }

    /**
     * @description Returns the schemes (from the input list) that the given
     *              account has NOT yet maxed out. Schemes with a null or zero
     *              Max_Uses_Per_Customer__c are treated as unlimited and always
     *              pass through.
     */
    public static Set<Id> filterExhaustedSchemes(Id accountId, List<Scheme__c> schemes) {
        Set<Id> allowed = new Set<Id>();
        if (accountId == null || schemes == null || schemes.isEmpty()) return allowed;

        // Capture the per-scheme cap up front
        Map<Id, Decimal> capByScheme = new Map<Id, Decimal>();
        for (Scheme__c s : schemes) {
            capByScheme.put(s.Id, s.Max_Uses_Per_Customer__c);
        }

        // One aggregate query: how many times has THIS account used each scheme?
        Map<Id, Integer> usageByScheme = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Scheme__c sid, COUNT(Id) c
            FROM Scheme_Usage__c
            WHERE Account__c = :accountId
              AND Scheme__c IN :capByScheme.keySet()
            GROUP BY Scheme__c
        ]) {
            usageByScheme.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        }

        for (Scheme__c s : schemes) {
            Decimal cap = capByScheme.get(s.Id);
            if (cap == null || cap <= 0) {
                allowed.add(s.Id);   // unlimited
                continue;
            }
            Integer used = usageByScheme.containsKey(s.Id) ? usageByScheme.get(s.Id) : 0;
            if (used < cap) allowed.add(s.Id);
        }
        return allowed;
    }

    // ── Authoritative per-customer usage ledger (all scheme types) ───────────

    /**
     * @description Records one Scheme_Usage__c row per (Account, Scheme) for each
     *              order that has been placed. Unlike recordDeliveredUsage (which
     *              reads the line's Scheme__c lookup and therefore MISSES
     *              order/invoice-level schemes that are never stamped onto a
     *              line), this re-evaluates the order through the scheme engine so
     *              EVERY scheme that applied — product, assorted, AND invoice/
     *              order-level — is captured. That makes the per-customer usage
     *              count reliable for all scheme categories.
     *
     *              Idempotent: a row already present for an (Order, Scheme) pair
     *              is skipped, so re-firing on later status changes never
     *              double-counts.
     *
     * @param orderIds The Sales Orders that were just placed/submitted.
     */
    public static void recordOrderUsage(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) return;

        Map<Id, Sales_Order__c> orders = new Map<Id, Sales_Order__c>([
            SELECT Id, Account__c, Order_Date__c
            FROM Sales_Order__c
            WHERE Id IN :orderIds AND Account__c != null
        ]);
        if (orders.isEmpty()) return;

        // Group line items per order for engine evaluation.
        Map<Id, List<Order_Line_Item__c>> linesByOrder = new Map<Id, List<Order_Line_Item__c>>();
        for (Order_Line_Item__c li : [
            SELECT Id, Sales_Order__c, Product_Ext__c, Quantity__c, UOM__c,
                   Unit_Price__c, Net_Amount__c, Line_Amount__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :orderIds
        ]) {
            if (!linesByOrder.containsKey(li.Sales_Order__c)) {
                linesByOrder.put(li.Sales_Order__c, new List<Order_Line_Item__c>());
            }
            linesByOrder.get(li.Sales_Order__c).add(li);
        }

        // Existing rows so we stay idempotent.
        Set<String> existingPairs = new Set<String>();
        for (Scheme_Usage__c u : [
            SELECT Sales_Order__c, Scheme__c
            FROM Scheme_Usage__c
            WHERE Sales_Order__c IN :orderIds
        ]) {
            existingPairs.add(pairKey(u.Sales_Order__c, u.Scheme__c));
        }

        List<Scheme_Usage__c> toInsert = new List<Scheme_Usage__c>();
        for (Id orderId : orders.keySet()) {
            Sales_Order__c o = orders.get(orderId);
            List<Order_Line_Item__c> lines = linesByOrder.get(orderId);
            if (lines == null || lines.isEmpty()) continue;

            List<SPM_SchemeEngine_Service.SchemeResult> applied =
                SPM_SchemeEngine_Service.getApplicableSchemes(o.Account__c, lines, o.Order_Date__c);
            if (applied == null) continue;

            Set<Id> seen = new Set<Id>();
            for (SPM_SchemeEngine_Service.SchemeResult r : applied) {
                if (r == null || r.schemeId == null || seen.contains(r.schemeId)) continue;
                seen.add(r.schemeId);
                if (existingPairs.contains(pairKey(orderId, r.schemeId))) continue;

                Decimal benefit = (r.discountAmount == null ? 0 : r.discountAmount)
                    + (r.priceDiscount == null ? 0 : r.priceDiscount);
                toInsert.add(new Scheme_Usage__c(
                    Account__c     = o.Account__c,
                    Scheme__c      = r.schemeId,
                    Sales_Order__c = orderId,
                    Usage_Count__c = 1,
                    Benefit_Type__c = mapBenefitTypeFromCategory(r.schemeCategory),
                    Benefit_Amount__c = benefit,
                    Used_At__c     = Datetime.now()
                ));
            }
        }

        if (!toInsert.isEmpty()) insert toInsert;
    }

    /**
     * @description Removes the usage rows for the given orders (e.g. when an order
     *              is cancelled) so the use is returned to the customer.
     * @param orderIds The Sales Orders whose usage should be released.
     */
    public static void reverseOrderUsage(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) return;
        List<Scheme_Usage__c> rows = [
            SELECT Id FROM Scheme_Usage__c WHERE Sales_Order__c IN :orderIds
        ];
        if (!rows.isEmpty()) delete rows;
    }

    /**
     * @description Returns how many distinct placed orders the given customer has
     *              used each of the requested schemes on, read from the usage
     *              ledger. The single source of truth for the per-customer cap.
     * @param accountId The customer Account Id.
     * @param schemeIds The schemes to count.
     * @return Map of Scheme Id → distinct-order usage count.
     */
    public static Map<Id, Integer> getUsageCounts(Id accountId, Set<Id> schemeIds) {
        return getUsageCounts(accountId, schemeIds, null);
    }

    /**
     * @description Usage counts with an optional set of orders to EXCLUDE — used
     *              by the save-time guard so an order being (re)saved does not
     *              count against its own cap.
     */
    public static Map<Id, Integer> getUsageCounts(
        Id accountId, Set<Id> schemeIds, Set<Id> excludeOrderIds
    ) {
        Map<Id, Integer> counts = new Map<Id, Integer>();
        if (accountId == null || schemeIds == null || schemeIds.isEmpty()) {
            return counts;
        }
        Set<Id> exclude = excludeOrderIds == null ? new Set<Id>() : excludeOrderIds;
        for (AggregateResult ar : [
            SELECT Scheme__c sid, COUNT_DISTINCT(Sales_Order__c) c
            FROM Scheme_Usage__c
            WHERE Account__c = :accountId
              AND Scheme__c IN :schemeIds
              AND Sales_Order__c NOT IN :exclude
            GROUP BY Scheme__c
        ]) {
            counts.put((Id) ar.get('sid'), (Integer) ar.get('c'));
        }
        return counts;
    }

    // ── Private helpers ─────────────────────────────────────────────────────

    private static String mapBenefitType(Order_Line_Item__c line) {
        String schemeType = line.Scheme__r != null ? line.Scheme__r.Scheme_Type__c : null;
        if (schemeType == 'Buy X Get Y' || schemeType == 'Combo Offer') return 'Free Product';
        if (schemeType == 'Reward Points') return 'Points';
        return 'Discount';
    }

    private static String mapBenefitTypeFromCategory(String schemeCategory) {
        if (schemeCategory == 'Reward Points') return 'Points';
        if (schemeCategory == 'Free Products') return 'Free Product';
        return 'Discount';
    }

    private static String pairKey(Id orderId, Id schemeId) {
        return String.valueOf(orderId) + '|' + String.valueOf(schemeId);
    }
}