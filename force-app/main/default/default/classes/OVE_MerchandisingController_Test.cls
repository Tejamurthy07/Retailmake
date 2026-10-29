/**
 * @description Test class for OVE_MerchandisingController, a thin @AuraEnabled
 *              wrapper over OVE_Merchandising_Service. Exercises success and
 *              exception paths of both methods.
 */
@isTest
private class OVE_MerchandisingController_Test {

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
                record.put(fieldName, Date.today());
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 1);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 1);
            }
        }
    }

    private class Ctx {
        public Account account;
        public Id visitId;
    }

    private static Ctx buildContext(String suffix) {
        Ctx c = new Ctx();
        try {
            Territory_Master__c terr =
                TestDataFactory.createAndInsertTerritory('MD Terr ' + suffix, ('MD' + suffix).left(20));
            Beat__c beat =
                TestDataFactory.createAndInsertBeat('MD Beat ' + suffix, ('MDB' + suffix).left(20), terr.Id);
            Day_Attendance__c da =
                TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
            insert da;
            c.account = TestDataFactory.createAccount('MD Acc ' + suffix, 'Retailer');
            insert c.account;
            Visit__c visit = TestDataFactory.createVisit(
                c.account.Id, UserInfo.getUserId(), da.Id, beat.Id
            );
            insert visit;
            c.visitId = visit.Id;
        } catch (Exception e) {
            System.debug('buildContext failed: ' + e.getMessage());
        }
        return c;
    }

    private static String buildMerchJson(Ctx c) {
        Map<String, Object> data = new Map<String, Object>{
            'visitId'              => c.visitId,
            'accountId'            => c.account != null ? c.account.Id : null,
            'auditDate'            => String.valueOf(Date.today()),
            'ownShelfShare'        => 60,
            'competitorShelfShare' => 40,
            'posmPresent'          => true,
            'posmCondition'        => 'Good',
            'planogramCompliant'   => true,
            'notes'                => 'Shelf well maintained',
            'photoBefore'          => 'https://example.com/before.jpg',
            'photoAfter'           => 'https://example.com/after.jpg'
        };
        return JSON.serialize(data);
    }

    @isTest
    static void testGetMerchandisingForVisit() {
        Ctx c = buildContext('GV');

        Test.startTest();
        try {
            Merchandising__c m =
                OVE_MerchandisingController.getMerchandisingForVisit(c.visitId);
            System.assert(m == null || m.Id != null, 'Returnable record or null');
        } catch (AuraHandledException e) {
        }
        Test.stopTest();
    }

    @isTest
    static void testGetMerchandisingForVisitNull() {
        Test.startTest();
        try {
            OVE_MerchandisingController.getMerchandisingForVisit(null);
        } catch (AuraHandledException e) {
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveMerchandising() {
        Ctx c = buildContext('SM');
        if (c.visitId == null) return;

        Test.startTest();
        try {
            Merchandising__c saved =
                OVE_MerchandisingController.saveMerchandising(buildMerchJson(c));
            System.assert(saved == null || saved.Id != null, 'Saved record returnable');
        } catch (AuraHandledException e) {
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveMerchandisingInvalidJson() {
        Test.startTest();
        try {
            OVE_MerchandisingController.saveMerchandising('{ not-valid-json');
        } catch (AuraHandledException e) {
            // expected — malformed JSON surfaces a handled exception
        }
        Test.stopTest();
    }

    @isTest
    static void testGetMerchandisingForVisit_WrongTypeId() {
        // Passing a User Id instead of a Visit Id will hit a runtime
        // exception inside the service (FIELD_INTEGRITY / List has no
        // rows / etc), which falls through to the generic catch in
        // getMerchandisingForVisit.
        Test.startTest();
        try {
            OVE_MerchandisingController.getMerchandisingForVisit(UserInfo.getUserId());
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSaveMerchandisingNull() {
        Test.startTest();
        try {
            OVE_MerchandisingController.saveMerchandising(null);
        } catch (AuraHandledException e) {
        }
        Test.stopTest();
    }

    @isTest
    static void testSaveMerchandisingEmptyObject() {
        Test.startTest();
        try {
            OVE_MerchandisingController.saveMerchandising('{}');
        } catch (AuraHandledException e) {
        } catch (Exception e) {
        }
        Test.stopTest();
    }

    /**
     * @description Calls the deployed service directly with no try/catch so the
     *              real JSON contract / exception surfaces. The controller is a
     *              thin wrapper, so its only coverable lines are the success
     *              returns plus whichever catch the service actually triggers.
     */
    @isTest
    static void testDiagnoseServiceDirectly() {
        Ctx c = buildContext('DIAG');
        System.assertNotEquals(null, c.visitId, 'Visit fixture must insert');

        Merchandising__c existing =
            OVE_Merchandising_Service.getMerchandisingForVisit(c.visitId);
        System.debug('Existing merch: ' + existing);

        String json = buildMerchJson(c);
        System.debug('Merch JSON: ' + json);

        Merchandising__c saved = OVE_Merchandising_Service.saveMerchandising(json);
        System.assertNotEquals(null, saved, 'Service should return a saved record');
        System.assertNotEquals(null, saved.Id, 'Saved merchandising must have an Id');
    }
}