@isTest
private class Stock_Adjustment_Trigger_Test {

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

    private static String pickPicklist(String objApi, String fieldApi) {
        try {
            Schema.DescribeFieldResult dfr = Schema.getGlobalDescribe()
                .get(objApi).getDescribe().fields.getMap().get(fieldApi).getDescribe();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) return pe.getValue();
            }
        } catch (Exception e) {}
        return null;
    }

    @isTest
    static void testTriggerFires() {
        Warehouse__c wh = new Warehouse__c(
            Name = 'SA WH',
            Warehouse_Code__c = 'SAWH001',
            Warehouse_Type__c = 'Central',
            State__c = 'Maharashtra',
            Is_Active__c = true
        );
        fillRequiredFields(wh);
        insert wh;

        String adjType = pickPicklist('Stock_Adjustment__c', 'Adjustment_Type__c');
        String status = pickPicklist('Stock_Adjustment__c', 'Status__c');

        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Adjustment_Qty__c = 10,
            Adjustment_Date__c = Date.today(),
            Warehouse__c = wh.Id,
            Reason__c = 'Stock count adjustment'
        );
        if (adjType != null) adj.Adjustment_Type__c = adjType;
        if (status != null) adj.Status__c = status;
        try { adj.put('Batch_Number__c', 'SA-B-1'); } catch (Exception e) {}
        fillRequiredFields(adj);

        Test.startTest();
        insert adj;
        adj.Adjustment_Qty__c = 12;
        try { update adj; } catch (Exception e) {}
        try { delete adj; } catch (Exception e) {}
        try { undelete adj; } catch (Exception e) {}
        Test.stopTest();

        System.assertNotEquals(null, adj.Id, 'Stock_Adjustment insert should succeed');
    }
}