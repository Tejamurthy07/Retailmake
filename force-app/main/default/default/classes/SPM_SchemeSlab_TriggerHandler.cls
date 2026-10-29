/**
 * @description Trigger handler for Scheme_Slab__c. Validates slab ranges
 *              and detects overlapping slabs within the same scheme.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class SPM_SchemeSlab_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        List<Scheme_Slab__c> newRecords = (List<Scheme_Slab__c>) Trigger.new;
        validateSlabRanges(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        List<Scheme_Slab__c> newRecords = (List<Scheme_Slab__c>) Trigger.new;
        validateSlabRanges(newRecords);
    }

    // ── After Insert ──────────────────────────────────────────────────────────

    protected override void afterInsert() {
        List<Scheme_Slab__c> newRecords = (List<Scheme_Slab__c>) Trigger.new;
        detectOverlappingSlabs(newRecords);
    }

    // ── After Update ──────────────────────────────────────────────────────────

    protected override void afterUpdate() {
        List<Scheme_Slab__c> newRecords = (List<Scheme_Slab__c>) Trigger.new;
        detectOverlappingSlabs(newRecords);
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private void validateSlabRanges(List<Scheme_Slab__c> records) {
        for (Scheme_Slab__c rec : records) {
            if (rec.Min_Quantity__c != null && rec.Max_Quantity__c != null &&
                rec.Min_Quantity__c > rec.Max_Quantity__c) {
                rec.Max_Quantity__c.addError('Max Quantity must be greater than or equal to Min Quantity.');
            }
            if (rec.Min_Value__c != null && rec.Max_Value__c != null &&
                rec.Min_Value__c > rec.Max_Value__c) {
                rec.Max_Value__c.addError('Max Value must be greater than or equal to Min Value.');
            }
        }
    }

    private void detectOverlappingSlabs(List<Scheme_Slab__c> records) {
        Set<Id> schemeIds = new Set<Id>();
        Set<Id> currentIds = new Set<Id>();
        for (Scheme_Slab__c rec : records) {
            if (rec.Scheme__c != null && rec.Is_Active__c == true) {
                schemeIds.add(rec.Scheme__c);
                currentIds.add(rec.Id);
            }
        }

        if (schemeIds.isEmpty()) return;

        List<Scheme_Slab__c> existingSlabs = [
            SELECT Id, Scheme__c, Min_Quantity__c, Max_Quantity__c,
                   Min_Value__c, Max_Value__c, Is_Active__c
            FROM Scheme_Slab__c
            WHERE Scheme__c IN :schemeIds
              AND Is_Active__c = true
              AND Id NOT IN :currentIds
        ];

        Map<Id, List<Scheme_Slab__c>> slabsByScheme = new Map<Id, List<Scheme_Slab__c>>();
        for (Scheme_Slab__c s : existingSlabs) {
            if (!slabsByScheme.containsKey(s.Scheme__c)) {
                slabsByScheme.put(s.Scheme__c, new List<Scheme_Slab__c>());
            }
            slabsByScheme.get(s.Scheme__c).add(s);
        }

        for (Scheme_Slab__c rec : records) {
            if (!rec.Is_Active__c || !slabsByScheme.containsKey(rec.Scheme__c)) continue;

            for (Scheme_Slab__c existing : slabsByScheme.get(rec.Scheme__c)) {
                Boolean qtyOverlap = (rec.Min_Quantity__c != null && existing.Min_Quantity__c != null &&
                    rec.Min_Quantity__c <= existing.Max_Quantity__c &&
                    rec.Max_Quantity__c >= existing.Min_Quantity__c);
                Boolean valOverlap = (rec.Min_Value__c != null && existing.Min_Value__c != null &&
                    rec.Min_Value__c <= existing.Max_Value__c &&
                    rec.Max_Value__c >= existing.Min_Value__c);

                if (qtyOverlap || valOverlap) {
                    rec.addError('This slab overlaps with an existing active slab in the same scheme.');
                    break;
                }
            }
        }
    }
}