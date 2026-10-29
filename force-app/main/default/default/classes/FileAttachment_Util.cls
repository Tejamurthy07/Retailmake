/**
 * @description Utility class for saving files as ContentVersion records
 *              attached to parent records via ContentDocumentLink.
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class FileAttachment_Util {

    private static final String DOWNLOAD_URL_PREFIX = '/sfc/servlet.shepherd/document/download/';

    /**
     * @description Saves a base64-encoded file and attaches it to the given parent record
     *              using FirstPublishLocationId (auto-creates ContentDocumentLink).
     * @param base64Data Base64-encoded file data.
     * @param fileName   File name (without extension for photos).
     * @param parentId   The Id of the record to attach the file to.
     * @return The ContentVersion Id.
     */
    public static Id saveFileToParent(String base64Data, String fileName, Id parentId) {
        if (String.isBlank(base64Data)) return null;
        ContentVersion cv = new ContentVersion();
        cv.Title = fileName;
        cv.PathOnClient = fileName + '.jpg';
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        cv.FirstPublishLocationId = parentId;
        cv.IsMajorVersion = true;
        insert cv;
        return cv.Id;
    }

    /**
     * @description Saves a base64-encoded file as a standalone ContentVersion (no parent link).
     *              Used when the parent record does not yet exist.
     * @param base64Data Base64-encoded file data.
     * @param fileName   File name (without extension for photos).
     * @return The ContentVersion Id.
     */
    public static Id saveFileStandalone(String base64Data, String fileName) {
        if (String.isBlank(base64Data)) return null;
        ContentVersion cv = new ContentVersion();
        cv.Title = fileName;
        cv.PathOnClient = fileName + '.jpg';
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        cv.IsMajorVersion = true;
        insert cv;
        return cv.Id;
    }

    /**
     * @description Links an existing ContentVersion to a parent record by creating
     *              a ContentDocumentLink. Used when the parent record is created
     *              after the file was uploaded.
     * @param contentVersionId The ContentVersion Id.
     * @param parentId         The record to link the file to.
     */
    public static void linkFileToParent(Id contentVersionId, Id parentId) {
        if (contentVersionId == null || parentId == null) return;
        ContentVersion cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :contentVersionId LIMIT 1];
        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = cv.ContentDocumentId;
        cdl.LinkedEntityId = parentId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
        insert cdl;
    }

    /**
     * @description Gets the download URL for the first file attached to a record.
     * @param recordId The parent record Id.
     * @return The download URL, or null if no file is attached.
     */
    public static String getFirstAttachmentUrl(Id recordId) {
        if (recordId == null) return null;
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId
            ORDER BY ContentDocument.CreatedDate DESC
            LIMIT 1
        ];
        if (links.isEmpty()) return null;
        return DOWNLOAD_URL_PREFIX + links[0].ContentDocumentId;
    }

    /**
     * @description Gets download URLs for files attached to multiple records.
     *              Returns a map of recordId → download URL (first/latest file per record).
     * @param recordIds Set of parent record Ids.
     * @return Map of recordId to download URL.
     */
    public static Map<Id, String> getAttachmentUrls(Set<Id> recordIds) {
        Map<Id, String> result = new Map<Id, String>();
        if (recordIds == null || recordIds.isEmpty()) return result;

        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :recordIds
            ORDER BY ContentDocument.CreatedDate DESC
        ]) {
            // Keep only the latest (first) file per record
            if (!result.containsKey(cdl.LinkedEntityId)) {
                result.put(cdl.LinkedEntityId, DOWNLOAD_URL_PREFIX + cdl.ContentDocumentId);
            }
        }
        return result;
    }
}