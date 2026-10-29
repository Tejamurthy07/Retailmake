/**
 * @description Trigger for Account object delegating to MDM_Account_TriggerHandler.
 *              Handles before/after insert, update, and delete events.
 */
trigger Account_Trigger on Account (
    before insert, before update,
    after insert, after update, after delete
) {
    MDM_Account_TriggerHandler handler = new MDM_Account_TriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            handler.beforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.beforeUpdate(Trigger.new, Trigger.oldMap);
        }
    } else if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            handler.afterInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.afterUpdate(Trigger.new, Trigger.oldMap);
        } else if (Trigger.isDelete) {
            handler.afterDelete(Trigger.old);
        }
    }
}