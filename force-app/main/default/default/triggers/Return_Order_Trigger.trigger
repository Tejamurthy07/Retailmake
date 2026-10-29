/**
 * @description Single trigger for Return_Order__c. Delegates all logic to
 *              OMS_ReturnOrder_TriggerHandler via the TriggerHandler framework.
 */
trigger Return_Order_Trigger on Return_Order__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new OMS_ReturnOrder_TriggerHandler().run();
    new DMS_ReturnOrder_TriggerHandler().run();
}