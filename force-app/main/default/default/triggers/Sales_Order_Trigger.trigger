/**
 * @description Single trigger for Sales_Order__c. Delegates all logic to
 *              OMS_SalesOrder_TriggerHandler via the TriggerHandler framework.
 */
trigger Sales_Order_Trigger on Sales_Order__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new OMS_SalesOrder_TriggerHandler().run();
}