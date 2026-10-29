trigger Warehouse_Stock_Trigger on Warehouse_Stock__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new INV_WarehouseStock_TriggerHandler().run();
}