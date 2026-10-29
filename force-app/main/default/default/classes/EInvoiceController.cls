/**
 * @description Aura/LWC controller for the invoice-record e-invoice panel: read the
 *              current e-invoice state, generate (register with the IRP) and cancel.
 */
public with sharing class EInvoiceController {

    @AuraEnabled(cacheable=true)
    public static EInvoiceView getEInvoice(Id invoiceId) {
        Invoice__c inv = [
            SELECT Id, Invoice_Number__c, Total_Amount__c,
                   E_Invoice_IRN__c, E_Invoice_QR__c, E_Invoice_Ack_No__c,
                   E_Invoice_Ack_Date__c, E_Invoice_Status__c,
                   E_Way_Bill_No__c, E_Way_Bill_Date__c, E_Way_Bill_Valid_Until__c
            FROM Invoice__c WHERE Id = :invoiceId
        ];
        EInvoiceView v = new EInvoiceView();
        v.invoiceId = inv.Id;
        v.invoiceNumber = inv.Invoice_Number__c;
        v.totalAmount = inv.Total_Amount__c;
        v.irn = inv.E_Invoice_IRN__c;
        v.signedQr = inv.E_Invoice_QR__c;
        v.ackNo = inv.E_Invoice_Ack_No__c;
        v.ackDate = inv.E_Invoice_Ack_Date__c;
        v.status = inv.E_Invoice_Status__c;
        v.ewbNo = inv.E_Way_Bill_No__c;
        v.ewbDate = inv.E_Way_Bill_Date__c;
        v.ewbValidUntil = inv.E_Way_Bill_Valid_Until__c;
        v.generated = String.isNotBlank(inv.E_Invoice_IRN__c);
        v.enabled = EInvoice_Service.isEnabled();
        return v;
    }

    @AuraEnabled
    public static EInvoice_Models.Result generate(Id invoiceId) {
        try {
            return EInvoice_Service.generateOne(invoiceId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static EInvoice_Models.Result cancel(Id invoiceId, String reason) {
        try {
            return EInvoice_Service.cancel(invoiceId, reason);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    public class EInvoiceView {
        @AuraEnabled public Id invoiceId;
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public String irn;
        @AuraEnabled public String signedQr;
        @AuraEnabled public String ackNo;
        @AuraEnabled public Datetime ackDate;
        @AuraEnabled public String status;
        @AuraEnabled public String ewbNo;
        @AuraEnabled public Datetime ewbDate;
        @AuraEnabled public Datetime ewbValidUntil;
        @AuraEnabled public Boolean generated;
        @AuraEnabled public Boolean enabled;
    }
}