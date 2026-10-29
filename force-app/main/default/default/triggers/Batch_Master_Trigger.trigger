/**
 * @description Single trigger for Batch_Master__c. Delegates all logic to
 *              MDM_BatchMaster_TriggerHandler via the TriggerHandler framework.
 */
trigger Batch_Master_Trigger on Batch_Master__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new MDM_BatchMaster_TriggerHandler().run();
}