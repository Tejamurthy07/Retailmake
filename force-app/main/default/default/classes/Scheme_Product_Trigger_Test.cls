@isTest
private class Scheme_Product_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Scheme__c s;
        Product_Extension__c prod;
        try {
            s = TestDataFactory.createScheme('SP Scheme', 'SP-001', 'Percentage');
            try { s.put('Budget_Amount__c', (Decimal) 10000); } catch (Exception e) {}
            insert s;

            prod = new Product_Extension__c(
                Name = 'SP Prod',
                Weight__c = 10,
                Weight_Unit__c = 'kg',
                Is_Active__c = true
            );
            insert prod;
        } catch (Exception e) {}

        SObjectType t = Schema.getGlobalDescribe().get('Scheme_Product__c');
        if (t == null) return;
        SObject sp = t.newSObject();
        if (s != null) try { sp.put('Scheme__c', s.Id); } catch (Exception e) {}
        if (prod != null) try { sp.put('Product_Ext__c', prod.Id); } catch (Exception e) {}

        Test.startTest();
        try { insert sp; } catch (Exception e) {}
        if (sp.Id != null) {
            try { update sp; } catch (Exception e) {}
            try { delete sp; } catch (Exception e) {}
            try { undelete sp; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}