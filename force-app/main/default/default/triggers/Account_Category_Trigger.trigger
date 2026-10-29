trigger Account_Category_Trigger on Account_Category__c (
    before insert, before update
) {
    MDM_AccountCategory_TriggerHandler handler = new MDM_AccountCategory_TriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            handler.beforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.beforeUpdate(Trigger.new, (Map<Id, Account_Category__c>) Trigger.oldMap);
        }
    }
}