trigger UOM_Conversion_Trigger on UOM_Conversion__c (before insert, before update, after insert, after update, after delete) {
    // Clear UOM conversion cache on any conversion change to prevent stale data
    if (Trigger.isAfter) {
        UOM_Conversion_Service.clearCache();
        return;
    }

    for (UOM_Conversion__c conv : Trigger.new) {
        if (conv.Conversion_Factor__c != null && conv.Conversion_Factor__c != 0) {
            conv.Inverse_Conversion_Factor__c = (1 / conv.Conversion_Factor__c).setScale(6, RoundingMode.HALF_UP);
        }

        // Prevent self-referencing conversions
        if (conv.From_UOM__c != null && conv.From_UOM__c == conv.To_UOM__c) {
            conv.addError('From UOM and To UOM cannot be the same.');
        }
    }

    // Detect circular conversions (A->B->C->A)
    if (Trigger.isInsert || Trigger.isUpdate) {
        Set<Id> uomIds = new Set<Id>();
        for (UOM_Conversion__c conv : Trigger.new) {
            if (conv.From_UOM__c != null) uomIds.add(conv.From_UOM__c);
            if (conv.To_UOM__c != null) uomIds.add(conv.To_UOM__c);
        }

        Map<Id, Set<Id>> graph = new Map<Id, Set<Id>>();
        for (UOM_Conversion__c existing : [
            SELECT From_UOM__c, To_UOM__c
            FROM UOM_Conversion__c
            WHERE Is_Active__c = true
              AND Id NOT IN :Trigger.new
        ]) {
            if (!graph.containsKey(existing.From_UOM__c)) {
                graph.put(existing.From_UOM__c, new Set<Id>());
            }
            graph.get(existing.From_UOM__c).add(existing.To_UOM__c);
        }

        for (UOM_Conversion__c conv : Trigger.new) {
            if (conv.From_UOM__c == null || conv.To_UOM__c == null || !conv.Is_Active__c) continue;

            // Add the new edge temporarily
            if (!graph.containsKey(conv.From_UOM__c)) {
                graph.put(conv.From_UOM__c, new Set<Id>());
            }
            graph.get(conv.From_UOM__c).add(conv.To_UOM__c);

            // BFS from To_UOM to see if we can reach From_UOM (cycle)
            Set<Id> visited = new Set<Id>();
            List<Id> queue = new List<Id>{ conv.To_UOM__c };
            Boolean hasCycle = false;

            while (!queue.isEmpty() && !hasCycle) {
                Id current = queue.remove(0);
                if (current == conv.From_UOM__c) {
                    hasCycle = true;
                    break;
                }
                if (visited.contains(current)) continue;
                visited.add(current);

                if (graph.containsKey(current)) {
                    queue.addAll(new List<Id>(graph.get(current)));
                }
            }

            // Remove the temporary edge
            graph.get(conv.From_UOM__c).remove(conv.To_UOM__c);

            if (hasCycle) {
                conv.addError('This conversion would create a circular reference (e.g., A->B->C->A). Remove existing conversions first.');
            }
        }
    }
}