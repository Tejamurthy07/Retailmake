/**
 * @description Single trigger for Day_Attendance__c. Delegates all logic to
 *              DFO_DayAttendance_TriggerHandler via the TriggerHandler framework.
 */
trigger Day_Attendance_Trigger on Day_Attendance__c (
    before insert, before update, before delete,
    after insert, after update, after delete, after undelete
) {
    new DFO_DayAttendance_TriggerHandler().run();
}