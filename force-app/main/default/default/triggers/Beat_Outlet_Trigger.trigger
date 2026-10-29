/**
 * @description Single trigger for Beat_Outlet__c. Delegates all logic to
 *              BPM_BeatOutlet_TriggerHandler via the TriggerHandler framework.
 */
trigger Beat_Outlet_Trigger on Beat_Outlet__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new BPM_BeatOutlet_TriggerHandler().run();
}