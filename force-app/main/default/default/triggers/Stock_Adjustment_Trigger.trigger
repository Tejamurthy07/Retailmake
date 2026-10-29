trigger Stock_Adjustment_Trigger on Stock_Adjustment__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new INV_StockAdjustment_TriggerHandler().run();
    new DMS_StockAdjustment_TriggerHandler().run();
}