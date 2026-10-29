/**
 * @description Single trigger for Journey_Plan__c. Delegates all logic to
 *              BPM_JourneyPlan_TriggerHandler via the TriggerHandler framework.
 */
trigger Journey_Plan_Trigger on Journey_Plan__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new BPM_JourneyPlan_TriggerHandler().run();
}