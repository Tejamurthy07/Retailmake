/**
 * @description Trigger handler for Company_Hierarchy__c. Manages hierarchical
 *              data integrity including circular-reference prevention, unique code
 *              enforcement, and territory rollup updates.
 * @author  SFA Development Team
 * @date    2024
 */
public class MDM_CompanyHierarchy_Handler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    /**
     * @description Validates no circular hierarchy exists and enforces unique
     *              hierarchy codes on new records.
     */
    protected override void beforeInsert() {
        List<Company_Hierarchy__c> newRecords = (List<Company_Hierarchy__c>) Trigger.new;
        validateUniqueCode(newRecords);
        validateNoCircularHierarchy(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    /**
     * @description Re-validates hierarchy integrity when parent assignments change.
     */
    protected override void beforeUpdate() {
        List<Company_Hierarchy__c> newRecords = (List<Company_Hierarchy__c>) Trigger.new;
        Map<Id, Company_Hierarchy__c> oldMap = (Map<Id, Company_Hierarchy__c>) Trigger.oldMap;

        List<Company_Hierarchy__c> parentChanged = new List<Company_Hierarchy__c>();
        List<Company_Hierarchy__c> codeChanged = new List<Company_Hierarchy__c>();

        for (Company_Hierarchy__c rec : newRecords) {
            Company_Hierarchy__c oldRec = oldMap.get(rec.Id);
            if (rec.Parent_Hierarchy__c != oldRec.Parent_Hierarchy__c) {
                parentChanged.add(rec);
            }
            if (rec.Hierarchy_Code__c != oldRec.Hierarchy_Code__c) {
                codeChanged.add(rec);
            }
        }

        if (!codeChanged.isEmpty()) {
            validateUniqueCode(codeChanged);
        }
        if (!parentChanged.isEmpty()) {
            validateNoCircularHierarchy(parentChanged);
        }
    }

    // ── After Insert ──────────────────────────────────────────────────────────

    /**
     * @description Updates territory rollup counts when new hierarchy nodes
     *              are created.
     */
    protected override void afterInsert() {
        List<Company_Hierarchy__c> newRecords = (List<Company_Hierarchy__c>) Trigger.new;
        updateTerritoryRollups(newRecords);
    }

    // ── After Update ──────────────────────────────────────────────────────────

    /**
     * @description Refreshes territory rollups when hierarchy relationships
     *              or territory assignments change.
     */
    protected override void afterUpdate() {
        List<Company_Hierarchy__c> newRecords = (List<Company_Hierarchy__c>) Trigger.new;
        Map<Id, Company_Hierarchy__c> oldMap = (Map<Id, Company_Hierarchy__c>) Trigger.oldMap;

        List<Company_Hierarchy__c> relevantChanges = new List<Company_Hierarchy__c>();
        for (Company_Hierarchy__c rec : newRecords) {
            Company_Hierarchy__c oldRec = oldMap.get(rec.Id);
            if (rec.Parent_Hierarchy__c != oldRec.Parent_Hierarchy__c ||
                rec.Territory__c != oldRec.Territory__c ||
                rec.Is_Active__c != oldRec.Is_Active__c) {
                relevantChanges.add(rec);
            }
        }

        if (!relevantChanges.isEmpty()) {
            updateTerritoryRollups(relevantChanges);
        }
    }

    // ── Private helper methods ────────────────────────────────────────────────

    /**
     * @description Validates that Hierarchy_Code__c values are unique across
     *              existing records and within the current batch.
     * @param records The records to validate.
     */
    private void validateUniqueCode(List<Company_Hierarchy__c> records) {
        Set<String> newCodes = new Set<String>();
        Set<String> duplicatesInBatch = new Set<String>();

        // Check for duplicates within the incoming batch
        for (Company_Hierarchy__c rec : records) {
            if (String.isNotBlank(rec.Hierarchy_Code__c)) {
                String code = rec.Hierarchy_Code__c.toUpperCase();
                if (newCodes.contains(code)) {
                    duplicatesInBatch.add(code);
                }
                newCodes.add(code);
            }
        }

        // Query existing records with the same codes (excluding current records for updates)
        Set<Id> currentIds = new Set<Id>();
        for (Company_Hierarchy__c rec : records) {
            if (rec.Id != null) {
                currentIds.add(rec.Id);
            }
        }

        Set<String> existingCodes = new Set<String>();
        for (Company_Hierarchy__c existing : [
            SELECT Hierarchy_Code__c
            FROM Company_Hierarchy__c
            WHERE Hierarchy_Code__c IN :newCodes
              AND Id NOT IN :currentIds
        ]) {
            existingCodes.add(existing.Hierarchy_Code__c.toUpperCase());
        }

        // Apply errors
        for (Company_Hierarchy__c rec : records) {
            if (String.isNotBlank(rec.Hierarchy_Code__c)) {
                String code = rec.Hierarchy_Code__c.toUpperCase();
                if (existingCodes.contains(code)) {
                    rec.Hierarchy_Code__c.addError(
                        'Hierarchy Code \'' + rec.Hierarchy_Code__c +
                        '\' already exists. Please use a unique code.'
                    );
                } else if (duplicatesInBatch.contains(code)) {
                    rec.Hierarchy_Code__c.addError(
                        'Duplicate Hierarchy Code \'' + rec.Hierarchy_Code__c +
                        '\' found within the same batch.'
                    );
                }
            }
        }
    }

    /**
     * @description Validates that assigning a parent would not create a circular
     *              reference in the hierarchy tree. Walks up the parent chain to
     *              detect cycles.
     * @param records The records with parent assignments to validate.
     */
    private void validateNoCircularHierarchy(List<Company_Hierarchy__c> records) {
        // Collect all parent IDs we need to walk
        Set<Id> parentIds = new Set<Id>();
        Map<Id, Company_Hierarchy__c> recordsById = new Map<Id, Company_Hierarchy__c>();

        for (Company_Hierarchy__c rec : records) {
            if (rec.Parent_Hierarchy__c != null) {
                parentIds.add(rec.Parent_Hierarchy__c);
                if (rec.Id != null) {
                    recordsById.put(rec.Id, rec);
                }
            }
        }

        if (parentIds.isEmpty()) {
            return;
        }

        // Build a map of Id -> Parent Id by querying the full hierarchy
        Map<Id, Id> hierarchyParentMap = new Map<Id, Id>();
        for (Company_Hierarchy__c ch : [
            SELECT Id, Parent_Hierarchy__c
            FROM Company_Hierarchy__c
            WHERE Id != null
        ]) {
            hierarchyParentMap.put(ch.Id, ch.Parent_Hierarchy__c);
        }

        // For each record, walk up the parent chain and check for cycles
        for (Company_Hierarchy__c rec : records) {
            if (rec.Parent_Hierarchy__c == null || rec.Id == null) {
                continue;
            }

            Set<Id> visited = new Set<Id>();
            visited.add(rec.Id);
            Id currentParent = rec.Parent_Hierarchy__c;
            Boolean isCircular = false;

            // Walk up to a maximum depth to prevent governor limit issues
            Integer maxDepth = 50;
            Integer depth = 0;

            while (currentParent != null && depth < maxDepth) {
                if (visited.contains(currentParent)) {
                    isCircular = true;
                    break;
                }
                visited.add(currentParent);
                currentParent = hierarchyParentMap.get(currentParent);
                depth++;
            }

            if (isCircular) {
                rec.Parent_Hierarchy__c.addError(
                    'Circular hierarchy detected. The selected parent would create ' +
                    'a circular reference in the hierarchy tree.'
                );
            }
        }
    }

    /**
     * @description Updates territory rollup fields on parent hierarchy nodes.
     *              Aggregates child counts, active outlet counts, and territory
     *              coverage metrics.
     * @param records The records whose parent rollups should be refreshed.
     */
    private void updateTerritoryRollups(List<Company_Hierarchy__c> records) {
        // Collect all parent IDs that need rollup recalculation
        Set<Id> parentIds = new Set<Id>();
        for (Company_Hierarchy__c rec : records) {
            if (rec.Parent_Hierarchy__c != null) {
                parentIds.add(rec.Parent_Hierarchy__c);
            }
        }

        if (parentIds.isEmpty()) {
            return;
        }

        // Aggregate child counts per parent
        Map<Id, Integer> totalChildCount = new Map<Id, Integer>();
        Map<Id, Integer> activeChildCount = new Map<Id, Integer>();

        for (AggregateResult ar : [
            SELECT Parent_Hierarchy__c parentId,
                   COUNT(Id) totalChildren
            FROM Company_Hierarchy__c
            WHERE Parent_Hierarchy__c IN :parentIds
            GROUP BY Parent_Hierarchy__c
        ]) {
            Id parentId = (Id) ar.get('parentId');
            totalChildCount.put(parentId, (Integer) ar.get('totalChildren'));
        }

        for (AggregateResult ar : [
            SELECT Parent_Hierarchy__c parentId,
                   COUNT(Id) activeChildren
            FROM Company_Hierarchy__c
            WHERE Parent_Hierarchy__c IN :parentIds
              AND Is_Active__c = true
            GROUP BY Parent_Hierarchy__c
        ]) {
            Id parentId = (Id) ar.get('parentId');
            activeChildCount.put(parentId, (Integer) ar.get('activeChildren'));
        }

        // Update parent records
        List<Company_Hierarchy__c> parentsToUpdate = new List<Company_Hierarchy__c>();
        for (Id parentId : parentIds) {
            parentsToUpdate.add(new Company_Hierarchy__c(
                Id = parentId,
                Total_Child_Nodes__c = totalChildCount.containsKey(parentId)
                    ? totalChildCount.get(parentId) : 0,
                Active_Child_Nodes__c = activeChildCount.containsKey(parentId)
                    ? activeChildCount.get(parentId) : 0
            ));
        }

        if (!parentsToUpdate.isEmpty()) {
            // Bypass self to prevent recursion during rollup update
            TriggerHandler.bypass('MDM_CompanyHierarchy_Handler');
            try {
                update parentsToUpdate;
            } finally {
                TriggerHandler.clearBypass('MDM_CompanyHierarchy_Handler');
            }
        }
    }
}