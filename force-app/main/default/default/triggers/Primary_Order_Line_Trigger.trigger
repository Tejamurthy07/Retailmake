/**
 * @description Keeps the Primary_Order__c header totals in step with its lines.
 *              Logic lives in DMS_PrimaryOrderLine_TriggerHandler.
 */
trigger Primary_Order_Line_Trigger on Primary_Order_Line__c (
    after insert, after update, after delete, after undelete
) {
    new DMS_PrimaryOrderLine_TriggerHandler().run();
}