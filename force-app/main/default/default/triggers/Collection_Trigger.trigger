/**
 * @description Single trigger for Collection__c. Delegates all logic to
 *              OVE_Collection_TriggerHandler via the TriggerHandler framework.
 */
trigger Collection_Trigger on Collection__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new OVE_Collection_TriggerHandler().run();
}