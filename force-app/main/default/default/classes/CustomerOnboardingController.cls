/**
 * @description  Controller for the CustomerOnboarding Visualforce page, which is
 *               launched from the "Onboard Customer" button on Account. The page
 *               keeps its own multi-step JavaScript, so this class only supplies
 *               the picklist data it needs and performs the save.
 *
 *               The standard "New" action on Account is deliberately left alone;
 *               this is an additional entry point, not an override.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class CustomerOnboardingController {

    // Uploads are sent as base64 over Visualforce remoting, which inflates the
    // payload by about a third, so the per-file ceiling is kept well under the
    // synchronous heap limit.
    private static final Integer MAX_FILE_BYTES = 3 * 1024 * 1024;

    /**
     * @description Options for the page's dropdowns, fetched in one round trip.
     */
    public class OnboardingOptions {
        @AuraEnabled public List<Option> customerTypes = new List<Option>();
        @AuraEnabled public List<Option> territories = new List<Option>();
        @AuraEnabled public List<Option> outletTypes = new List<Option>();
        @AuraEnabled public List<Option> outletClasses = new List<Option>();
        @AuraEnabled public List<Option> channels = new List<Option>();
        @AuraEnabled public List<Option> creditPeriods = new List<Option>();
        @AuraEnabled public List<Option> paymentTerms = new List<Option>();
    }

    public class Option {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        public Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    /**
     * @description Everything the form's dropdowns need.
     *              Customer Type is driven by the Account record types that
     *              actually exist rather than a hardcoded list, so the value
     *              can be used directly as the record type on save.
     */
    public String getOptionsJson() {
        OnboardingOptions options = new OnboardingOptions();

        for (Schema.RecordTypeInfo info : Account.SObjectType.getDescribe().getRecordTypeInfos()) {
            if (info.isAvailable() && !info.isMaster()) {
                options.customerTypes.add(new Option(info.getRecordTypeId(), info.getName()));
            }
        }

        for (Territory_Master__c territory : [
            SELECT Id, Name FROM Territory_Master__c ORDER BY Name LIMIT 1000
        ]) {
            options.territories.add(new Option(territory.Id, territory.Name));
        }

        options.outletTypes   = picklistOptions(Account.Outlet_Type__c);
        options.outletClasses = picklistOptions(Account.Outlet_Class__c);
        options.channels      = picklistOptions(Account.Channel__c);
        options.creditPeriods = picklistOptions(Account.Credit_Period_Days__c);
        options.paymentTerms  = picklistOptions(Account.Payment_Terms__c);

        return JSON.serialize(options);
    }

    private static List<Option> picklistOptions(Schema.SObjectField field) {
        List<Option> options = new List<Option>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new Option(entry.getValue(), entry.getLabel()));
            }
        }
        return options;
    }

    /**
     * @description Incoming form values, deserialized from the page's payload.
     */
    public class OnboardingRequest {
        public String customerName;
        public String recordTypeId;
        public String email;
        public String phone;
        public String gstin;
        public String pan;
        public String address;
        public String city;
        public String state;
        public String pincode;
        public String territoryId;
        public String outletType;
        public String outletClass;
        public String channel;
        public Decimal creditLimit;
        public String creditPeriod;
        public Decimal annualTurnover;
        public String paymentTerms;
        public String remarks;
    }

    /**
     * @description One uploaded document.
     */
    public class OnboardingFile {
        public String name;
        public String base64;
    }

    /**
     * @description Creates the Account and attaches the KYC documents.
     * @param requestJson Serialized OnboardingRequest.
     * @param filesJson   Serialized list of OnboardingFile. May be empty.
     * @return The new Account Id, for the page to redirect to.
     */
    @RemoteAction
    public static String createCustomer(String requestJson, String filesJson) {
        OnboardingRequest request =
            (OnboardingRequest) JSON.deserialize(requestJson, OnboardingRequest.class);

        if (String.isBlank(request.customerName)) {
            throw new AuraHandledException('Customer name is required.');
        }
        if (String.isBlank(request.territoryId)) {
            // Territory_Required_When_Active rejects an active account without
            // one, so this is caught here to give a clearer message.
            throw new AuraHandledException('Territory is required before the customer can be saved.');
        }

        Account outlet = new Account(
            Name                  = request.customerName,
            Phone                 = request.phone,
            Email__c              = request.email,
            GSTIN__c              = String.isBlank(request.gstin) ? null : request.gstin,
            PAN__c                = String.isBlank(request.pan) ? null : request.pan,
            BillingStreet         = request.address,
            BillingCity           = request.city,
            BillingState          = request.state,
            BillingPostalCode     = request.pincode,
            BillingCountry        = 'India',
            Territory__c          = request.territoryId,
            Outlet_Type__c        = request.outletType,
            Outlet_Class__c       = request.outletClass,
            Channel__c            = request.channel,
            Credit_Limit__c       = request.creditLimit,
            Credit_Period_Days__c = request.creditPeriod,
            Annual_Turnover__c    = request.annualTurnover,
            Payment_Terms__c      = request.paymentTerms,
            Credit_Remarks__c     = request.remarks,
            // Approval happens from the record page, not from this form.
            Onboarding_Status__c  = 'Pending Approval'
        );

        if (String.isNotBlank(request.recordTypeId)) {
            outlet.RecordTypeId = request.recordTypeId;
        }

        insert outlet;

        attachDocuments(outlet.Id, filesJson);

        return outlet.Id;
    }

    /**
     * @description Saves each uploaded document as a File linked to the Account.
     * @param accountId The account the documents belong to.
     * @param filesJson Serialized list of OnboardingFile.
     */
    private static void attachDocuments(Id accountId, String filesJson) {
        if (String.isBlank(filesJson)) {
            return;
        }

        List<OnboardingFile> files =
            (List<OnboardingFile>) JSON.deserialize(filesJson, List<OnboardingFile>.class);
        if (files.isEmpty()) {
            return;
        }

        List<ContentVersion> versions = new List<ContentVersion>();
        for (OnboardingFile file : files) {
            if (String.isBlank(file.base64) || String.isBlank(file.name)) {
                continue;
            }
            Blob body = EncodingUtil.base64Decode(file.base64);
            if (body.size() > MAX_FILE_BYTES) {
                throw new AuraHandledException(
                    file.name + ' is larger than the 3 MB upload limit.');
            }
            versions.add(new ContentVersion(
                Title        = file.name,
                PathOnClient = file.name,
                VersionData  = body,
                Origin       = 'H'
            ));
        }

        if (versions.isEmpty()) {
            return;
        }
        insert versions;

        Set<Id> versionIds = new Set<Id>();
        for (ContentVersion version : versions) {
            versionIds.add(version.Id);
        }

        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentVersion version : [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :versionIds
        ]) {
            links.add(new ContentDocumentLink(
                ContentDocumentId = version.ContentDocumentId,
                LinkedEntityId    = accountId,
                ShareType         = 'V',
                Visibility        = 'AllUsers'
            ));
        }
        insert links;
    }
}