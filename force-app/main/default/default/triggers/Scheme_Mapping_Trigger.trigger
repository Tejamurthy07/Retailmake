/**
 * @description Single trigger for Scheme_Mapping__c. Delegates all logic to
 *              SPM_SchemeMapping_TriggerHandler via the TriggerHandler framework.
 */
trigger Scheme_Mapping_Trigger on Scheme_Mapping__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new SPM_SchemeMapping_TriggerHandler().run();
}