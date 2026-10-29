@isTest
public class FileAttachment_Util_Test {

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult sObjDesc = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : sObjDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable()) continue;
            if (dfr.isNillable()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            if (dfr.isDefaultedOnCreate()) continue;
            String fieldName = dfr.getName();
            if (record.get(fieldName) != null) continue;

            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) {
                record.put(fieldName, 'Test');
            } else if (t == Schema.DisplayType.EMAIL) {
                record.put(fieldName, 'test@example.com');
            } else if (t == Schema.DisplayType.PHONE) {
                record.put(fieldName, '9999999999');
            } else if (t == Schema.DisplayType.URL) {
                record.put(fieldName, 'https://example.com');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today().addDays(-30));
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 0);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static Account createParent() {
        Territory_Master__c territory = new Territory_Master__c(
            Name = 'FA Util Territory',
            Territory_Code__c = 'FAU-' + String.valueOf(DateTime.now().getTime()).right(6),
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        fillRequiredFields(territory);
        insert territory;

        Account a = new Account(
            Name = 'FA Util Test ' + DateTime.now().getTime(),
            Outlet_Type__c = 'Grocery',
            Channel__c = 'GT',
            Territory__c = territory.Id
        );
        Map<String, Schema.RecordTypeInfo> rtMap =
            Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
        if (rtMap.containsKey('Distributor')) {
            a.RecordTypeId = rtMap.get('Distributor').getRecordTypeId();
        }
        fillRequiredFields(a);
        insert a;
        return a;
    }

    private static String sampleBase64() {
        return EncodingUtil.base64Encode(Blob.valueOf('sample file content'));
    }

    @isTest
    static void testSaveFileToParent() {
        Account parent = createParent();
        String data = sampleBase64();

        Test.startTest();
        Id cvId = FileAttachment_Util.saveFileToParent(data, 'photo', parent.Id);
        Test.stopTest();

        System.assertNotEquals(null, cvId);
        Integer linkCount = [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :parent.Id
        ];
        System.assertEquals(1, linkCount);
    }

    @isTest
    static void testSaveFileToParentBlankData() {
        Account parent = createParent();

        Test.startTest();
        Id cvId = FileAttachment_Util.saveFileToParent('', 'photo', parent.Id);
        Test.stopTest();

        System.assertEquals(null, cvId);
    }

    @isTest
    static void testSaveFileToParentNullData() {
        Account parent = createParent();

        Test.startTest();
        Id cvId = FileAttachment_Util.saveFileToParent(null, 'photo', parent.Id);
        Test.stopTest();

        System.assertEquals(null, cvId);
    }

    @isTest
    static void testSaveFileStandalone() {
        Test.startTest();
        Id cvId = FileAttachment_Util.saveFileStandalone(sampleBase64(), 'photo');
        Test.stopTest();

        System.assertNotEquals(null, cvId);
    }

    @isTest
    static void testSaveFileStandaloneBlankData() {
        Test.startTest();
        Id cvId = FileAttachment_Util.saveFileStandalone('', 'photo');
        Test.stopTest();

        System.assertEquals(null, cvId);
    }

    @isTest
    static void testLinkFileToParent() {
        Account parent = createParent();
        Id cvId = FileAttachment_Util.saveFileStandalone(sampleBase64(), 'photo');

        Test.startTest();
        FileAttachment_Util.linkFileToParent(cvId, parent.Id);
        Test.stopTest();

        Integer linkCount = [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :parent.Id
        ];
        System.assertEquals(1, linkCount);
    }

    @isTest
    static void testLinkFileToParentNullContentVersion() {
        Account parent = createParent();

        Test.startTest();
        FileAttachment_Util.linkFileToParent(null, parent.Id);
        Test.stopTest();

        Integer linkCount = [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :parent.Id
        ];
        System.assertEquals(0, linkCount);
    }

    @isTest
    static void testLinkFileToParentNullParent() {
        Id cvId = FileAttachment_Util.saveFileStandalone(sampleBase64(), 'photo');

        Test.startTest();
        FileAttachment_Util.linkFileToParent(cvId, null);
        Test.stopTest();
    }

    @isTest
    static void testGetFirstAttachmentUrl() {
        Account parent = createParent();
        FileAttachment_Util.saveFileToParent(sampleBase64(), 'photo', parent.Id);

        Test.startTest();
        String url = FileAttachment_Util.getFirstAttachmentUrl(parent.Id);
        Test.stopTest();

        System.assertNotEquals(null, url);
        System.assert(url.startsWith('/sfc/servlet.shepherd/document/download/'));
    }

    @isTest
    static void testGetFirstAttachmentUrlNoFile() {
        Account parent = createParent();

        Test.startTest();
        String url = FileAttachment_Util.getFirstAttachmentUrl(parent.Id);
        Test.stopTest();

        System.assertEquals(null, url);
    }

    @isTest
    static void testGetFirstAttachmentUrlNullId() {
        Test.startTest();
        String url = FileAttachment_Util.getFirstAttachmentUrl(null);
        Test.stopTest();

        System.assertEquals(null, url);
    }

    @isTest
    static void testGetAttachmentUrls() {
        Account p1 = createParent();
        Account p2 = createParent();
        FileAttachment_Util.saveFileToParent(sampleBase64(), 'photo1', p1.Id);
        FileAttachment_Util.saveFileToParent(sampleBase64(), 'photo2', p2.Id);

        Test.startTest();
        Map<Id, String> urls = FileAttachment_Util.getAttachmentUrls(new Set<Id>{ p1.Id, p2.Id });
        Test.stopTest();

        System.assertEquals(2, urls.size());
        System.assertNotEquals(null, urls.get(p1.Id));
        System.assertNotEquals(null, urls.get(p2.Id));
    }

    @isTest
    static void testGetAttachmentUrlsMultipleFilesPerRecord() {
        Account parent = createParent();
        FileAttachment_Util.saveFileToParent(sampleBase64(), 'photoA', parent.Id);
        FileAttachment_Util.saveFileToParent(sampleBase64(), 'photoB', parent.Id);

        Test.startTest();
        Map<Id, String> urls = FileAttachment_Util.getAttachmentUrls(new Set<Id>{ parent.Id });
        Test.stopTest();

        System.assertEquals(1, urls.size(), 'Should keep only the latest file per record');
    }

    @isTest
    static void testGetAttachmentUrlsEmptySet() {
        Test.startTest();
        Map<Id, String> urls = FileAttachment_Util.getAttachmentUrls(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, urls.size());
    }

    @isTest
    static void testGetAttachmentUrlsNull() {
        Test.startTest();
        Map<Id, String> urls = FileAttachment_Util.getAttachmentUrls(null);
        Test.stopTest();

        System.assertEquals(0, urls.size());
    }
}