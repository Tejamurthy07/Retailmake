trigger Stock_Transfer_Trigger on Stock_Transfer__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new INV_StockTransfer_TriggerHandler().run();
}