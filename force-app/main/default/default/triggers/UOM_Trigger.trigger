/**
 * @description Single trigger for UOM__c. Prevents deactivation of UOMs
 *              that are referenced in active UOM_Conversion__c records.
 */
trigger UOM_Trigger on UOM__c (before update, after insert, after update, after delete) {
    // Clear UOM conversion cache on any UOM change to prevent stale data
    if (Trigger.isAfter) {
        UOM_Conversion_Service.clearCache();
        return;
    }

    // Before update logic: prevent deactivation of referenced UOMs
    Set<Id> deactivatingIds = new Set<Id>();
    for (UOM__c rec : Trigger.new) {
        UOM__c oldRec = Trigger.oldMap.get(rec.Id);
        if (oldRec.Is_Active__c == true && rec.Is_Active__c == false) {
            deactivatingIds.add(rec.Id);
        }
    }

    if (!deactivatingIds.isEmpty()) {
        Set<Id> referencedUoms = new Set<Id>();
        for (UOM_Conversion__c conv : [
            SELECT From_UOM__c, To_UOM__c
            FROM UOM_Conversion__c
            WHERE Is_Active__c = true
              AND (From_UOM__c IN :deactivatingIds OR To_UOM__c IN :deactivatingIds)
        ]) {
            referencedUoms.add(conv.From_UOM__c);
            referencedUoms.add(conv.To_UOM__c);
        }

        for (UOM__c rec : Trigger.new) {
            if (deactivatingIds.contains(rec.Id) && referencedUoms.contains(rec.Id)) {
                rec.Is_Active__c.addError(
                    'Cannot deactivate: this UOM is referenced in active conversion rules.'
                );
            }
        }
    }
}