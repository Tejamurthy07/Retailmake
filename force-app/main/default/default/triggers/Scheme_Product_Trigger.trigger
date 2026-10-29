/**
 * @description Single trigger for Scheme_Product__c. Delegates all logic to
 *              SPM_SchemeProduct_TriggerHandler via the TriggerHandler framework.
 */
trigger Scheme_Product_Trigger on Scheme_Product__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new SPM_SchemeProduct_TriggerHandler().run();
}