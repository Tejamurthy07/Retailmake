trigger Employee_Category_Trigger on Employee_Category__c (
    before insert, before update
) {
    MDM_EmployeeCategory_TriggerHandler handler = new MDM_EmployeeCategory_TriggerHandler();

    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            handler.beforeInsert(Trigger.new);
        } else if (Trigger.isUpdate) {
            handler.beforeUpdate(Trigger.new, (Map<Id, Employee_Category__c>) Trigger.oldMap);
        }
    }
}