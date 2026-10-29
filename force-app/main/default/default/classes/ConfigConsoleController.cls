/**
 * @description Controller for the Configuration Console LWC. Provides read +
 *              delete operations for the two runtime-editable configuration
 *              objects: Notification_Setting__c and Approval_Rule__c.
 *              Create/Edit is handled client-side by lightning-record-edit-form,
 *              so this controller deliberately only lists and deletes.
 */
public with sharing class ConfigConsoleController {

    /**
     * @description Returns all notification settings for the console table.
     */
    @AuraEnabled(cacheable=true)
    public static List<Notification_Setting__c> getNotificationSettings() {
        return [
            SELECT Id, Name, Event_Object__c, Event_Type__c, Recipient_Type__c,
                   Recipient_User__r.Name, Recipient_Reference__c,
                   Channel_InApp__c, Channel_Email__c, Channel_SMS__c, Channel_WhatsApp__c,
                   Is_Active__c
            FROM Notification_Setting__c
            ORDER BY Event_Object__c, Event_Type__c
        ];
    }

    /**
     * @description Returns all approval matrix rules for the console table.
     */
    @AuraEnabled(cacheable=true)
    public static List<Approval_Rule__c> getApprovalRules() {
        return [
            SELECT Id, Name, Object_Process__c, Approval_Level__c, Approver_Type__c,
                   Approver_Role_Queue__c, User__r.Name, Condition_Field__c,
                   Min_Value__c, Max_Value__c, Auto_Approve__c, Is_Active__c
            FROM Approval_Rule__c
            ORDER BY Object_Process__c, Approval_Level__c
        ];
    }

    /**
     * @description Returns all approval requests for the monitoring tab (read-only).
     */
    @AuraEnabled(cacheable=true)
    public static List<Approval_Request__c> getApprovalRequests() {
        return [
            SELECT Id, Name, Record_Name__c, Object_Type__c, Status__c,
                   Current_Level__c, Total_Levels__c, Current_Approver__r.Name,
                   Submitted_By__r.Name, Submitted_Date__c, Completed_Date__c
            FROM Approval_Request__c
            ORDER BY Submitted_Date__c DESC NULLS LAST
            LIMIT 500
        ];
    }

    /**
     * @description Deletes any configuration record by Id (works for both objects).
     * @param recordId Id of the record to delete.
     */
    @AuraEnabled
    public static void deleteRecord(Id recordId) {
        try {
            SObject rec = recordId.getSObjectType().newSObject(recordId);
            delete rec;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}