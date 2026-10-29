trigger Claim_Trigger on Claim__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new DMS_Claim_TriggerHandler().run();
}