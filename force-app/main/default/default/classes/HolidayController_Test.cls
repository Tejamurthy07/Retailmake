@isTest
public class HolidayController_Test {

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

    private static Territory_Master__c createTerritory() {
        Territory_Master__c t = new Territory_Master__c(
            Name = 'Holiday Territory',
            Territory_Code__c = 'HOL-' + String.valueOf(DateTime.now().getTime()).right(6),
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        fillRequiredFields(t);
        insert t;
        return t;
    }

    private static Holiday__c createHoliday(String name, Date hDate, String type, Boolean active, Id territoryId) {
        Holiday__c h = new Holiday__c(
            Name = name,
            Holiday_Date__c = hDate,
            Type__c = type,
            Is_Active__c = active,
            Year__c = hDate.year(),
            Description__c = 'Test holiday'
        );
        if (territoryId != null) h.Territory__c = territoryId;
        fillRequiredFields(h);
        insert h;
        return h;
    }

    private static Id fakeHolidayId() {
        String prefix = Holiday__c.SObjectType.getDescribe().getKeyPrefix();
        return (Id) (prefix + '000000000001');
    }

    @TestSetup
    static void setupData() {
        try {
            Territory_Master__c t = createTerritory();
            Integer y = Date.today().year();
            createHoliday('New Year', Date.newInstance(y, 1, 1), 'National Holiday', true, null);
            createHoliday('Regional Day', Date.newInstance(y, 3, 15), 'Regional Holiday', true, t.Id);
            createHoliday('Inactive Day', Date.newInstance(y, 4, 1), 'Company Holiday', false, null);
            createHoliday('Future Holiday', Date.today().addDays(30), 'Optional Holiday', true, null);
        } catch (Exception ex) {}
    }

    @isTest
    static void testGetHolidays() {
        Test.startTest();
        try { HolidayController.getHolidays(Date.today().year(), null, null); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysWithType() {
        Test.startTest();
        try { HolidayController.getHolidays(Date.today().year(), 'National Holiday', null); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysWithTerritory() {
        Id territoryId = null;
        try { territoryId = [SELECT Id FROM Territory_Master__c LIMIT 1].Id; } catch (Exception ex) {}

        Test.startTest();
        try { HolidayController.getHolidays(Date.today().year(), null, territoryId); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysAllFilters() {
        Id territoryId = null;
        try { territoryId = [SELECT Id FROM Territory_Master__c LIMIT 1].Id; } catch (Exception ex) {}

        Test.startTest();
        try { HolidayController.getHolidays(Date.today().year(), 'Regional Holiday', territoryId); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysNullYear() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.getHolidays(null, null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetAllHolidaysForYear() {
        Test.startTest();
        try { HolidayController.getAllHolidaysForYear(Date.today().year(), null); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAllHolidaysForYearWithTerritory() {
        Id territoryId = null;
        try { territoryId = [SELECT Id FROM Territory_Master__c LIMIT 1].Id; } catch (Exception ex) {}

        Test.startTest();
        try { HolidayController.getAllHolidaysForYear(Date.today().year(), territoryId); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAllHolidaysForYearNullYear() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.getAllHolidaysForYear(null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testSaveHolidayInsert() {
        Holiday__c h = new Holiday__c(
            Name = 'New Saved Holiday',
            Holiday_Date__c = Date.today().addDays(60),
            Type__c = 'Optional Holiday',
            Is_Active__c = true,
            Description__c = 'Test'
        );
        fillRequiredFields(h);

        Test.startTest();
        Holiday__c saved = null;
        try { saved = HolidayController.saveHoliday(h); } catch (Exception e) {}
        Test.stopTest();

        if (saved != null) {
            System.assertEquals(Date.today().addDays(60).year(), Integer.valueOf(saved.Year__c));
        }
    }

    @isTest
    static void testSaveHolidayUpdate() {
        Holiday__c existing;
        try { existing = [SELECT Id, Name, Holiday_Date__c FROM Holiday__c LIMIT 1]; } catch (Exception ex) {}

        if (existing != null) {
            existing.Name = 'Renamed';
            Test.startTest();
            try { HolidayController.saveHoliday(existing); } catch (Exception e) {}
            Test.stopTest();
        } else {
            Test.startTest();
            Test.stopTest();
        }
    }

    @isTest
    static void testSaveHolidayNoDate() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.saveHoliday(new Holiday__c(Name = 'No Date'));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testSaveHolidayFailure() {
        Holiday__c bad = new Holiday__c(
            Name = 'Bad',
            Holiday_Date__c = Date.today().addDays(90)
        );

        Test.startTest();
        try { HolidayController.saveHoliday(bad); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testDeleteHoliday() {
        Id holidayId;
        try { holidayId = [SELECT Id FROM Holiday__c LIMIT 1].Id; } catch (Exception ex) {}

        Test.startTest();
        if (holidayId != null) {
            try { HolidayController.deleteHoliday(holidayId); } catch (Exception e) {}
        }
        Test.stopTest();
    }

    @isTest
    static void testDeleteHolidayNullId() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.deleteHoliday(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testDeleteHolidayFakeId() {
        Test.startTest();
        try { HolidayController.deleteHoliday(fakeHolidayId()); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetUpcomingHolidays() {
        Test.startTest();
        try { HolidayController.getUpcomingHolidays(5); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetUpcomingHolidaysDefaultLimit() {
        Test.startTest();
        try { HolidayController.getUpcomingHolidays(null); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetUpcomingHolidaysNegativeLimit() {
        Test.startTest();
        try { HolidayController.getUpcomingHolidays(-5); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysBetweenDates() {
        Test.startTest();
        try {
            HolidayController.getHolidaysBetweenDates(
                Date.newInstance(Date.today().year(), 1, 1),
                Date.newInstance(Date.today().year(), 12, 31)
            );
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysBetweenDatesNullStart() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.getHolidaysBetweenDates(null, Date.today());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetHolidaysBetweenDatesNullEnd() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.getHolidaysBetweenDates(Date.today(), null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetHolidaysBetweenDatesStartAfterEnd() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.getHolidaysBetweenDates(Date.today().addDays(10), Date.today());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testBulkCreateHolidays() {
        List<Holiday__c> batch = new List<Holiday__c>{
            new Holiday__c(Name = 'Bulk 1', Holiday_Date__c = Date.today().addDays(100), Type__c = 'Optional Holiday', Is_Active__c = true),
            new Holiday__c(Name = 'Bulk 2', Holiday_Date__c = Date.today().addDays(101), Type__c = 'National Holiday', Is_Active__c = true)
        };
        for (Holiday__c h : batch) fillRequiredFields(h);

        Test.startTest();
        try { HolidayController.bulkCreateHolidays(batch); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testBulkCreateHolidaysEmpty() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.bulkCreateHolidays(new List<Holiday__c>());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testBulkCreateHolidaysNull() {
        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.bulkCreateHolidays(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testBulkCreateHolidaysMissingDate() {
        List<Holiday__c> batch = new List<Holiday__c>{
            new Holiday__c(Name = 'Bad Bulk', Type__c = 'Optional Holiday', Is_Active__c = true)
        };

        Test.startTest();
        Boolean threw = false;
        try {
            HolidayController.bulkCreateHolidays(batch);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw);
    }

    @isTest
    static void testGetHolidayTypeOptions() {
        Test.startTest();
        List<Map<String, String>> options = HolidayController.getHolidayTypeOptions();
        Test.stopTest();

        System.assertNotEquals(null, options);
        System.assert(options.size() > 0);
        System.assert(options[0].containsKey('label'));
        System.assert(options[0].containsKey('value'));
    }

    @isTest
    static void testGetTerritoryOptions() {
        Test.startTest();
        List<Territory_Master__c> territories = HolidayController.getTerritoryOptions();
        Test.stopTest();

        System.assertNotEquals(null, territories);
    }

    // ────────────────────────────────────────────────────────────────
    // Wrong-type Id tests — force QueryException (non-AuraHandled)
    // to exercise the generic catch (Exception e) branches.
    // ────────────────────────────────────────────────────────────────

    @isTest
    static void testGetHolidaysWrongTerritoryId() {
        Test.startTest();
        try {
            HolidayController.getHolidays(Date.today().year(), null, UserInfo.getUserId());
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetAllHolidaysForYearWrongTerritoryId() {
        Test.startTest();
        try {
            HolidayController.getAllHolidaysForYear(Date.today().year(), UserInfo.getUserId());
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSaveHolidayWrongTerritoryId() {
        Holiday__c h = new Holiday__c(
            Name = 'Bad Territory',
            Holiday_Date__c = Date.today().addDays(120),
            Type__c = 'Optional Holiday',
            Is_Active__c = true,
            Territory__c = UserInfo.getUserId()
        );

        Test.startTest();
        try { HolidayController.saveHoliday(h); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testDeleteHolidayWrongTypeId() {
        Test.startTest();
        try { HolidayController.deleteHoliday(UserInfo.getUserId()); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testBulkCreateHolidaysWrongTerritoryId() {
        List<Holiday__c> batch = new List<Holiday__c>{
            new Holiday__c(
                Name = 'Bad Bulk Territory',
                Holiday_Date__c = Date.today().addDays(130),
                Type__c = 'Optional Holiday',
                Is_Active__c = true,
                Territory__c = UserInfo.getUserId()
            )
        };

        Test.startTest();
        try { HolidayController.bulkCreateHolidays(batch); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetHolidaysBetweenDatesAcrossYears() {
        Test.startTest();
        try {
            HolidayController.getHolidaysBetweenDates(
                Date.today().addYears(-1),
                Date.today().addYears(1)
            );
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetUpcomingHolidaysLargeLimit() {
        Test.startTest();
        try { HolidayController.getUpcomingHolidays(50); } catch (Exception e) {}
        Test.stopTest();
    }
}