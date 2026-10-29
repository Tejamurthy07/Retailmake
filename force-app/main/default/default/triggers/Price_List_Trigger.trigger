/**
 * @description Single trigger for Price_List__c. Delegates all logic to
 *              MDM_PriceList_Handler via the TriggerHandler framework.
 */
trigger Price_List_Trigger on Price_List__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new MDM_PriceList_Handler().run();
}