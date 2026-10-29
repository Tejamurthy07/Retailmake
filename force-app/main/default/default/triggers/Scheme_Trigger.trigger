/**
 * @description Single trigger for Scheme__c. Delegates all logic to
 *              SPM_Scheme_TriggerHandler via the TriggerHandler framework.
 */
trigger Scheme_Trigger on Scheme__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new SPM_Scheme_TriggerHandler().run();
}