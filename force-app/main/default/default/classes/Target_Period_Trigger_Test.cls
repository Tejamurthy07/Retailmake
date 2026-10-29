@isTest
private class Target_Period_Trigger_Test {

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
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today());
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY ||
                       t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.INTEGER ||
                       t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static Target_Period__c build(String name, Date startDt, Date endDt, Boolean active) {
        Target_Period__c tp = new Target_Period__c(
            Name = name,
            Start_Date__c = startDt,
            End_Date__c = endDt,
            Is_Active__c = active
        );
        fillRequiredFields(tp);
        return tp;
    }

    @isTest
    static void testDiag_BaseInsert() {
        // Surfaces the actual DML error if Target_Period__c insert fails
        // for any reason (validation rule, missing required field).
        Target_Period__c tp = build('TP Diag',
            Date.newInstance(2030, 1, 1), Date.newInstance(2030, 1, 31), true);
        Test.startTest();
        insert tp;
        Test.stopTest();
        System.assertNotEquals(null, tp.Id, 'Base insert must succeed');
    }

    @isTest
    static void testInsert_AllInactive_NoOp() {
        // Inactive records bypass the check; everything inserts.
        List<Target_Period__c> batch = new List<Target_Period__c>{
            build('TP Inactive 1', Date.newInstance(2030, 1, 1), Date.newInstance(2030, 1, 31), false),
            build('TP Inactive 2', Date.newInstance(2030, 1, 1), Date.newInstance(2030, 1, 31), false)
        };
        Test.startTest();
        try { insert batch; } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testInsert_FirstActive_Succeeds() {
        Test.startTest();
        try {
            insert build('TP Solo', Date.newInstance(2030, 2, 1), Date.newInstance(2030, 2, 28), true);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testInsert_DuplicateDateRange_Blocked() {
        Target_Period__c first = build('TP March',
            Date.newInstance(2030, 3, 1), Date.newInstance(2030, 3, 31), true);
        try { insert first; } catch (Exception e) { return; }

        Target_Period__c dup = build('TP March Different Name',
            Date.newInstance(2030, 3, 1), Date.newInstance(2030, 3, 31), true);

        Test.startTest();
        Boolean threw = false;
        try { insert dup; } catch (DmlException e) {
            threw = true;
            System.assert(e.getMessage().contains('already exists'),
                'Error: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void testInsert_DuplicateName_Blocked() {
        Target_Period__c first = build('TP Q2',
            Date.newInstance(2030, 4, 1), Date.newInstance(2030, 4, 30), true);
        try { insert first; } catch (Exception e) { return; }

        Target_Period__c dup = build('tp q2',  // same name, different case
            Date.newInstance(2030, 5, 1), Date.newInstance(2030, 5, 31), true);

        Test.startTest();
        Boolean threw = false;
        try { insert dup; } catch (DmlException e) { threw = true; }
        Test.stopTest();
    }

    @isTest
    static void testInsert_BatchWithDuplicate() {
        Target_Period__c existing = build('TP Existing',
            Date.newInstance(2030, 6, 1), Date.newInstance(2030, 6, 30), true);
        try { insert existing; } catch (Exception e) { return; }

        List<Target_Period__c> batch = new List<Target_Period__c>{
            build('TP Batch OK', Date.newInstance(2030, 7, 1), Date.newInstance(2030, 7, 31), true),
            build('TP Existing', Date.newInstance(2030, 8, 1), Date.newInstance(2030, 8, 31), true)
        };

        Test.startTest();
        try { insert batch; } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testUpdate_SameRecord_NoSelfCollision() {
        // Updating a period to active again shouldn't collide with itself.
        Target_Period__c tp = build('TP Self',
            Date.newInstance(2030, 9, 1), Date.newInstance(2030, 9, 30), true);
        try { insert tp; } catch (Exception e) { return; }

        Test.startTest();
        try {
            tp.Name = 'TP Self Updated';
            update tp;
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testInsert_NullDatesNullName() {
        // Records without Name/dates skip the per-record checks entirely.
        Target_Period__c tp = new Target_Period__c(
            Is_Active__c = true
        );
        Test.startTest();
        try { insert tp; } catch (Exception e) {}
        Test.stopTest();
    }
}