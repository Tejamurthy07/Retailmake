trigger GRN_Trigger on GRN__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new INV_GRN_TriggerHandler().run();
    new DMS_GRN_TriggerHandler().run();
}