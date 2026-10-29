/**
 * @description Single trigger for Company_Hierarchy__c. Delegates all logic to
 *              MDM_CompanyHierarchy_Handler via the TriggerHandler framework.
 */
trigger Company_Hierarchy_Trigger on Company_Hierarchy__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new MDM_CompanyHierarchy_Handler().run();
}