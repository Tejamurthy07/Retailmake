public with sharing class SalesOrderPdfMobileController {

    @AuraEnabled
    public static String generatePdf(Id orderId) {
        if (orderId == null) {
            throw new AuraHandledException('Sales Order Id is required.');
        }

        try {
            Sales_Order__c so = [
                SELECT Id, Name FROM Sales_Order__c WHERE Id = :orderId LIMIT 1
            ];

            PageReference pg = new PageReference('/apex/SalesOrderPDF');
            pg.getParameters().put('id', orderId);

            Blob pdfBlob;
            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('Test PDF content');
            } else {
                pdfBlob = pg.getContentAsPDF();
            }

            String fileName = (so.Name != null ? so.Name : 'SalesOrder') + '.pdf';

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
            link.LinkedEntityId = orderId;
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