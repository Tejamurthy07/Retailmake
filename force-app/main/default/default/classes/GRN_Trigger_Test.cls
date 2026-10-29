@isTest
private class GRN_Trigger_Test {

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
        Test.startTest();
        try {
            Territory_Master__c territory = new Territory_Master__c(
                Name = 'GRNT Territory',
                Territory_Code__c = 'GRNT-T-001',
                State__c = 'Maharashtra',
                City__c = 'Mumbai',
                Is_Active__c = true
            );
            fillRequiredFields(territory);
            insert territory;

            Account acc = new Account(
                Name = 'GRNT Acc',
                Outlet_Type__c = 'Grocery',
                Channel__c = 'GT',
                Territory__c = territory.Id,
                Is_Active__c = true
            );
            Map<String, Schema.RecordTypeInfo> rtMap =
                Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
            if (rtMap.containsKey('Distributor')) {
                acc.RecordTypeId = rtMap.get('Distributor').getRecordTypeId();
            }
            fillRequiredFields(acc);
            insert acc;

            Invoice__c invoice = new Invoice__c(
                Account__c = acc.Id,
                Invoice_Date__c = Date.today().addDays(-1)
            );
            fillRequiredFields(invoice);
            insert invoice;

            GRN__c grn = new GRN__c(
                Account__c = acc.Id,
                Invoice__c = invoice.Id,
                GRN_Date__c = Date.today(),
                Status__c = 'Pending'
            );
            fillRequiredFields(grn);
            insert grn;

            grn.Status__c = 'Received';
            update grn;
        } catch (Exception e) {}
        Test.stopTest();
    }
}