/**
 * @description Single trigger for Distributor_Stock__c. Delegates all logic to
 *              INV_DistributorStock_TriggerHandler via the TriggerHandler framework.
 */
trigger Distributor_Stock_Trigger on Distributor_Stock__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new INV_DistributorStock_TriggerHandler().run();
}