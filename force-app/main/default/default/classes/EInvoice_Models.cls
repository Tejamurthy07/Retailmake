/**
 * @description DTOs shared across the e-invoicing engine — the provider-agnostic
 *              document snapshot sent to a provider, and the result written back
 *              onto the Invoice. Keeps the EInvoice_Provider interface decoupled
 *              from any concrete provider or the orchestration service.
 */
public class EInvoice_Models {

    /** Invoice snapshot handed to a provider for IRP registration. */
    public class Doc {
        public Id invoiceId;
        public String docNo;          // Invoice_Number__c
        public Date docDate;          // Invoice_Date__c
        public String docType;        // INV / CRN / DBN
        public String sellerGstin;    // supplier GSTIN (warehouse / config)
        public String buyerGstin;     // recipient GSTIN
        public String financialYear;  // e.g. 2025-26
        public Decimal totalValue;    // Total_Amount__c
        public Integer itemCount;
        public String mainHsn;        // representative HSN
        public Boolean ewayRequired;  // value >= e-way threshold
    }

    /** Provider response — the IRP artefacts to persist on the Invoice. */
    public class Result {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public String irn;
        @AuraEnabled public String signedQr;
        @AuraEnabled public String ackNo;
        @AuraEnabled public Datetime ackDate;
        @AuraEnabled public String status;        // Generated / Cancelled / Failed
        @AuraEnabled public String ewbNo;
        @AuraEnabled public Datetime ewbDate;
        @AuraEnabled public Datetime ewbValidUntil;
        @AuraEnabled public String message;       // human-readable info / error
    }
}