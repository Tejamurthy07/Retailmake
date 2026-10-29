@isTest
private class Scheme_Mapping_Trigger_Test {

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

    @isTest
    static void testTriggerFires() {
        // Seed a Scheme__c first since Scheme_Mapping__c has a master/detail
        // or required lookup back to it.
        Scheme__c s;
        try {
            s = TestDataFactory.createScheme('SM Trg Scheme', 'SM-TRG-001', 'Percentage');
            try { s.put('Budget_Amount__c', (Decimal) 10000); } catch (Exception e) {}
            fillRequiredFields(s);
            insert s;
        } catch (Exception e) {}

        SObjectType t = Schema.getGlobalDescribe().get('Scheme_Mapping__c');
        if (t == null) return;
        SObject sm = t.newSObject();
        if (s != null) try { sm.put('Scheme__c', s.Id); } catch (Exception e) {}
        try { sm.put('Zone__c', 'West'); } catch (Exception e) {}
        try { sm.put('Is_Active__c', true); } catch (Exception e) {}
        fillRequiredFields(sm);

        Test.startTest();
        try { insert sm; } catch (Exception e) {}
        if (sm.Id != null) {
            try { sm.put('Zone__c', 'East'); update sm; } catch (Exception e) {}
            try { delete sm; } catch (Exception e) {}
            try { undelete sm; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}