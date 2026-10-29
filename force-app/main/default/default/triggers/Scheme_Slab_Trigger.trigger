/**
 * @description Single trigger for Scheme_Slab__c. Delegates all logic to
 *              SPM_SchemeSlab_TriggerHandler via the TriggerHandler framework.
 */
trigger Scheme_Slab_Trigger on Scheme_Slab__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new SPM_SchemeSlab_TriggerHandler().run();
}