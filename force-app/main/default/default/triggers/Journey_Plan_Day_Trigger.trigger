/**
 * @description Single trigger for Journey_Plan_Day__c. Delegates all logic to
 *              BPM_JourneyPlanDay_TriggerHandler via the TriggerHandler framework.
 */
trigger Journey_Plan_Day_Trigger on Journey_Plan_Day__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new BPM_JourneyPlanDay_TriggerHandler().run();
}