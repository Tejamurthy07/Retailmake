/**
 * @description Single trigger for Beat__c. Delegates all logic to
 *              BPM_Beat_TriggerHandler via the TriggerHandler framework.
 */
trigger Beat_Trigger on Beat__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new BPM_Beat_TriggerHandler().run();
}