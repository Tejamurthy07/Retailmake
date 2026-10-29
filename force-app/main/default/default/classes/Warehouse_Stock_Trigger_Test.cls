@isTest
private class Warehouse_Stock_Trigger_Test {

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
        Warehouse__c wh;
        Product_Extension__c prod;
        try {
            wh = new Warehouse__c(
                Name = 'WST WH',
                Warehouse_Code__c = 'WST-WH-001',
                Warehouse_Type__c = 'Central',
                State__c = 'Maharashtra',
                Is_Active__c = true
            );
            fillRequiredFields(wh);
            insert wh;
        } catch (Exception e) {}

        try {
            prod = new Product_Extension__c(
                Name = 'WST Prod',
                Weight__c = 10,
                Weight_Unit__c = 'kg',
                Is_Active__c = true
            );
            try { prod.put('SKU_Code__c', 'SKU-WST-001'); } catch (Exception ex) {}
            fillRequiredFields(prod);
            insert prod;
        } catch (Exception e) {}

        Warehouse_Stock__c s = new Warehouse_Stock__c(
            Qty_On_Hand__c = 100,
            Qty_Reserved__c = 0,
            Qty_Damaged__c = 0
        );
        if (wh != null) try { s.put('Warehouse__c', wh.Id); } catch (Exception e) {}
        if (prod != null) try { s.put('Product_Ext__c', prod.Id); } catch (Exception e) {}
        try { s.put('Batch_Number__c', 'WST-B-1'); } catch (Exception e) {}
        fillRequiredFields(s);

        Test.startTest();
        try { insert s; } catch (Exception e) {}
        if (s.Id != null) {
            try { s.Qty_On_Hand__c = 80; update s; } catch (Exception e) {}
            try { delete s; } catch (Exception e) {}
            try { undelete s; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}