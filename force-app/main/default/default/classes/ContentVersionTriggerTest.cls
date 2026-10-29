/**
 * @description Tests for ContentVersionTrigger.
 *
 * The trigger does two independent things on after insert:
 *   1. Creates a public ContentDistribution (a shareable delivery link) for
 *      every file version, with browser viewing and downloads enabled.
 *   2. When the file came from the mobile app — flagged by
 *      ExternalDocumentInfo2 = 'FromApp' — links it to the record whose id was
 *      passed in ExternalDocumentInfo1, since the app cannot set
 *      FirstPublishLocationId directly.
 *
 * Note: ContentDistribution requires Content Deliveries to be enabled in the
 * org. If that setting is ever turned off, these tests fail at the insert —
 * and so would every file upload in the product, because the trigger inserts
 * the distribution unconditionally.
 */
@isTest
private class ContentVersionTriggerTest {

    private static ContentVersion newVersion(String title, Id linkedEntityId, String source) {
        return new ContentVersion(
            Title = title,
            PathOnClient = title + '.txt',
            VersionData = Blob.valueOf('test file body for ' + title),
            IsMajorVersion = true,
            ExternalDocumentInfo1 = linkedEntityId == null ? null : String.valueOf(linkedEntityId),
            ExternalDocumentInfo2 = source
        );
    }

    private static Lead newLead() {
        Lead l = new Lead(
            LastName = 'FileOwner',
            Company = 'Acme Trading',
            Status = 'Open - Not Contacted'
        );
        insert l;
        return l;
    }

    private static Id documentIdOf(Id versionId) {
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :versionId].ContentDocumentId;
    }

    // ── Content delivery creation ─────────────────────────────────────

    @isTest
    static void uploadingAFileCreatesADeliveryLink() {
        ContentVersion cv = newVersion('Invoice Scan', null, null);

        Test.startTest();
        insert cv;
        Test.stopTest();

        List<ContentDistribution> dists = [
            SELECT Name, ContentVersionId FROM ContentDistribution
            WHERE ContentVersionId = :cv.Id
        ];
        System.assertEquals(1, dists.size(), 'Every uploaded file gets exactly one delivery');
        System.assertEquals('Invoice Scan', dists[0].Name,
            'The delivery is named after the file so it is recognisable in Setup');
    }

    @isTest
    static void deliveryAllowsBrowserViewingAndDownloadsWithoutNotifications() {
        ContentVersion cv = newVersion('Price List', null, null);

        Test.startTest();
        insert cv;
        Test.stopTest();

        ContentDistribution dist = [
            SELECT PreferencesAllowViewInBrowser, PreferencesLinkLatestVersion,
                   PreferencesNotifyOnVisit, PreferencesAllowOriginalDownload,
                   PreferencesAllowPDFDownload
            FROM ContentDistribution WHERE ContentVersionId = :cv.Id
        ];
        System.assertEquals(true, dist.PreferencesAllowViewInBrowser,
            'Recipients must be able to preview without downloading');
        System.assertEquals(true, dist.PreferencesLinkLatestVersion,
            'The link follows the newest version rather than pinning to this one');
        System.assertEquals(false, dist.PreferencesNotifyOnVisit,
            'Uploaders are not emailed every time someone opens the file');
        System.assertEquals(true, dist.PreferencesAllowOriginalDownload, 'Original download allowed');
        System.assertEquals(true, dist.PreferencesAllowPDFDownload, 'PDF download allowed');
    }

    @isTest
    static void bulkUploadCreatesOneDeliveryPerFile() {
        List<ContentVersion> versions = new List<ContentVersion>();
        for (Integer i = 0; i < 20; i++) {
            versions.add(newVersion('Bulk File ' + i, null, null));
        }

        Test.startTest();
        insert versions;
        Test.stopTest();

        Set<Id> versionIds = new Set<Id>();
        for (ContentVersion cv : versions) versionIds.add(cv.Id);

        System.assertEquals(20, [
            SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId IN :versionIds
        ], 'The deliveries are built in one list and inserted once, not one DML per file');
    }

    // ── Linking app uploads to their record ───────────────────────────

    @isTest
    static void fileFromTheAppIsLinkedToTheRecordItNames() {
        Lead target = newLead();
        ContentVersion cv = newVersion('Visit Photo', target.Id, 'FromApp');

        Test.startTest();
        insert cv;
        Test.stopTest();

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, Visibility FROM ContentDocumentLink
            WHERE LinkedEntityId = :target.Id
        ];
        System.assertEquals(1, links.size(),
            'A file uploaded from the app attaches itself to the record it came from');
        System.assertEquals(documentIdOf(cv.Id), links[0].ContentDocumentId,
            'And it is the document that was just uploaded');
        System.assertEquals('AllUsers', links[0].Visibility,
            'Visibility is AllUsers so the whole team can see the evidence, not just the uploader');
    }

    @isTest
    static void fileNotFlaggedAsFromTheAppIsNotLinked() {
        Lead target = newLead();
        // The record id is present but the source flag is not 'FromApp' — this
        // is an ordinary desktop upload and must not be auto-attached.
        ContentVersion cv = newVersion('Desktop Upload', target.Id, 'FromWeb');

        Test.startTest();
        insert cv;
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :target.Id
        ], 'Only uploads explicitly flagged FromApp are auto-linked');
        System.assertEquals(1, [
            SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :cv.Id
        ], 'The delivery is still created — that part is unconditional');
    }

    @isTest
    static void fileFromTheAppWithNoTargetRecordIsNotLinked() {
        ContentVersion cv = newVersion('Orphan Photo', null, 'FromApp');

        Test.startTest();
        insert cv;
        Test.stopTest();

        System.assertEquals(1, [
            SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :cv.Id
        ], 'The file still uploads and still gets a delivery');
        System.assertNotEquals(null, documentIdOf(cv.Id),
            'A missing target id is skipped rather than throwing and losing the upload');
    }

    @isTest
    static void mixedBatchLinksOnlyTheAppUploads() {
        Lead linked = newLead();
        Lead untouched = newLead();

        List<ContentVersion> versions = new List<ContentVersion>{
            newVersion('App Photo A', linked.Id, 'FromApp'),
            newVersion('Web Upload', untouched.Id, 'FromWeb'),
            newVersion('Plain Upload', null, null)
        };

        Test.startTest();
        insert versions;
        Test.stopTest();

        System.assertEquals(1, [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :linked.Id
        ], 'The app upload is linked');
        System.assertEquals(0, [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :untouched.Id
        ], 'The web upload is left alone even though it names a record');

        Set<Id> versionIds = new Set<Id>();
        for (ContentVersion cv : versions) versionIds.add(cv.Id);
        System.assertEquals(3, [
            SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId IN :versionIds
        ], 'All three still get a delivery regardless of source');
    }
}