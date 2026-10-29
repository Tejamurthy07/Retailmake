trigger Indent_Trigger on Indent__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new DMS_Indent_TriggerHandler().run();
}