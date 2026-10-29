/**
 * @description Single trigger for Order_Line_Item__c. Delegates all logic to
 *              a lightweight inline handler that invokes pricing services.
 *              Note: Heavy logic is in OMS_OrderPricing_Service.
 */
trigger Order_Line_Item_Trigger on Order_Line_Item__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new OMS_OrderLineItem_TriggerHandler().run();
}