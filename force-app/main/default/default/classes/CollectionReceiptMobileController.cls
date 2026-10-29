public with sharing class CollectionReceiptMobileController {

    @AuraEnabled
    public static String generateReceipt(Id collectionId) {
        if (collectionId == null) {
            throw new AuraHandledException('Collection Id is required.');
        }

        try {
            Collection__c c = [
                SELECT Id, Name FROM Collection__c WHERE Id = :collectionId LIMIT 1
            ];

            PageReference pg = new PageReference('/apex/CollectionReceipt');
            pg.getParameters().put('id', collectionId);

            Blob pdfBlob;
            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('Test Receipt content');
            } else {
                pdfBlob = pg.getContentAsPDF();
            }

            String fileName = (c.Name != null ? c.Name : 'Receipt') + '.pdf';

            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName;
            cv.VersionData = pdfBlob;
            cv.IsMajorVersion = true;
            cv.Origin = 'H';
            insert cv;

            ContentVersion inserted = [
                SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1
            ];

            ContentDocumentLink link = new ContentDocumentLink();
            link.ContentDocumentId = inserted.ContentDocumentId;
            link.LinkedEntityId = collectionId;
            link.ShareType = 'V';
            link.Visibility = 'AllUsers';
            insert link;

            return inserted.Id;
        } catch (Exception e) {
            AuraHandledException ahe = new AuraHandledException(e.getMessage());
            ahe.setMessage(e.getMessage());
            throw ahe;
        }
    }
}