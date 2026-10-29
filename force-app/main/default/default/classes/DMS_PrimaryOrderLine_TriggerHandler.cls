/**
 * @description Keeps Primary_Order__c header totals in step with its lines.
 *
 * The header totals are plain Currency fields that several services set by hand
 * after inserting lines. Nothing kept them in sync afterwards, so any path that
 * added, repriced or removed a line — or created an order by cloning one — left
 * a header describing a different order than the lines did.
 *
 * That is not merely cosmetic. Primary_Order_Trigger's credit enforcement reads
 * Total_Amount__c in preference to summing the lines ("prefer header total, else
 * compute from lines"), so a stale or understated header lets an order through
 * that should have breached the distributor's credit limit. A cloned order once
 * carried its template's 56k total while its real lines came to ~11.4 lakh, and
 * the check waved it through.
 *
 * Roll-up summary fields would be the declarative answer, but Total_Amount__c
 * and friends are written directly by DMS_PortalController,
 * DMS_PrimaryOrderFulfillment_Service and DMS_IndentFulfillment_Service; making
 * them read-only roll-ups would break all three. Recalculating here keeps those
 * writes valid and simply guarantees the last word is always the lines.
 *
 * Totals follow the conventions already established in
 * DMS_PortalController.createIndent:
 *   Total_Gross_Amount__c = SUM(Line_Amount__c)
 *   Total_Discount__c     = SUM(Scheme_Discount__c)
 *   Total_Tax__c          = SUM(Tax_Amount__c)
 *   Total_Net_Amount__c   = Total_Amount__c = SUM(line net)
 *   Total_Items__c        = number of lines
 */
public with sharing class DMS_PrimaryOrderLine_TriggerHandler extends TriggerHandler {

    protected override void afterInsert()   { syncParents(parentIdsFrom(Trigger.new, null)); }
    protected override void afterUndelete() { syncParents(parentIdsFrom(Trigger.new, null)); }
    protected override void afterDelete()   { syncParents(parentIdsFrom(null, Trigger.old)); }

    protected override void afterUpdate() {
        // A line can be reparented, so both sides need recalculating.
        syncParents(parentIdsFrom(Trigger.new, Trigger.old));
    }

    // ── Internals ─────────────────────────────────────────────────────

    private static Set<Id> parentIdsFrom(List<SObject> newRecords, List<SObject> oldRecords) {
        Set<Id> ids = new Set<Id>();
        for (List<SObject> batch : new List<List<SObject>>{ newRecords, oldRecords }) {
            if (batch == null) { continue; }
            for (SObject s : batch) {
                Id parentId = (Id) s.get('Primary_Order__c');
                if (parentId != null) { ids.add(parentId); }
            }
        }
        return ids;
    }

    /**
     * @description Recomputes and writes the header totals for the given orders.
     *              Public so a backfill or a data-repair job can reuse exactly
     *              the same arithmetic rather than reimplementing it.
     */
    public static void syncParents(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) { return; }

        Map<Id, Primary_Order__c> totals = new Map<Id, Primary_Order__c>();
        for (Id orderId : orderIds) {
            totals.put(orderId, new Primary_Order__c(
                Id = orderId,
                Total_Gross_Amount__c = 0,
                Total_Discount__c     = 0,
                Total_Tax__c          = 0,
                Total_Net_Amount__c   = 0,
                Total_Amount__c       = 0,
                Total_Items__c        = 0
            ));
        }

        for (Primary_Order_Line__c l : [
            SELECT Primary_Order__c, Line_Amount__c, Scheme_Discount__c, Tax_Amount__c,
                   Total_Amount__c, Quantity__c, Unit_Price__c
            FROM Primary_Order_Line__c
            WHERE Primary_Order__c IN :orderIds
        ]) {
            Primary_Order__c hdr = totals.get(l.Primary_Order__c);
            if (hdr == null) { continue; }
            hdr.Total_Gross_Amount__c += nz(l.Line_Amount__c);
            hdr.Total_Discount__c     += nz(l.Scheme_Discount__c);
            hdr.Total_Tax__c          += nz(l.Tax_Amount__c);
            hdr.Total_Net_Amount__c   += lineNet(l);
            hdr.Total_Items__c        += 1;
        }

        for (Primary_Order__c hdr : totals.values()) {
            hdr.Total_Amount__c = hdr.Total_Net_Amount__c;
        }

        try {
            update totals.values();
        } catch (DmlException e) {
            // Never let a totals refresh break the DML that triggered it. The
            // parent may legitimately refuse an update (locked, validation rule,
            // credit block on an approval already in flight) and the caller's own
            // work should still stand.
            System.debug(LoggingLevel.WARN,
                'Primary order total sync skipped: ' + e.getDmlMessage(0));
        }
    }

    /**
     * @description The line's net contribution to the header.
     *
     *              Priced lines carry Total_Amount__c (post-tax). Lines created
     *              by simpler paths — a portal quick order, a data load, a demo
     *              helper — often set only Quantity and Unit Price. Falling back
     *              means the header still reflects real value instead of zero,
     *              which matters because the credit check trusts it.
     */
    private static Decimal lineNet(Primary_Order_Line__c l) {
        if (nz(l.Total_Amount__c) > 0) { return l.Total_Amount__c; }
        if (nz(l.Line_Amount__c) > 0)  { return l.Line_Amount__c; }
        return nz(l.Quantity__c) * nz(l.Unit_Price__c);
    }

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }
}