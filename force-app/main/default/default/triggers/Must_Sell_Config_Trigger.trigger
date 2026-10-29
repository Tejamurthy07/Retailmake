trigger Must_Sell_Config_Trigger on Must_Sell_Config__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new SPM_MustSellConfig_TriggerHandler().run();
}