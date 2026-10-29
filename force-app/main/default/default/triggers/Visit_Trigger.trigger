/**
 * @description Single trigger for Visit__c. Delegates all logic to
 *              OVE_Visit_TriggerHandler via the TriggerHandler framework.
 */
trigger Visit_Trigger on Visit__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new OVE_Visit_TriggerHandler().run();
}