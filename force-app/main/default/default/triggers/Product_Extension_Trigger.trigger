/**
 * @description Single trigger for Product_Extension__c. Delegates all logic to
 *              MDM_ProductExtension_TriggerHandler via the TriggerHandler framework.
 */
trigger Product_Extension_Trigger on Product_Extension__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new MDM_ProductExtension_TriggerHandler().run();
}