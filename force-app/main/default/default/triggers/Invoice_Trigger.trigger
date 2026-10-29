/**
 * @description Single trigger for Invoice__c. Placeholder for invoice-level
 *              trigger logic via the TriggerHandler framework.
 */
trigger Invoice_Trigger on Invoice__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new OMS_Invoice_TriggerHandler().run();
}