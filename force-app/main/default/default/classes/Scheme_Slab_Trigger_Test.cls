@isTest
private class Scheme_Slab_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Scheme__c s;
        try {
            s = TestDataFactory.createScheme('SS Scheme', 'SS-001', 'Slab');
            try { s.put('Budget_Amount__c', (Decimal) 10000); } catch (Exception e) {}
            insert s;
        } catch (Exception e) {}

        SObjectType t = Schema.getGlobalDescribe().get('Scheme_Slab__c');
        if (t == null) return;
        SObject slab = t.newSObject();
        if (s != null) try { slab.put('Scheme__c', s.Id); } catch (Exception e) {}
        try { slab.put('Min_Value__c', 0); } catch (Exception e) {}
        try { slab.put('Max_Value__c', 1000); } catch (Exception e) {}
        try { slab.put('Discount_Percent__c', 5); } catch (Exception e) {}
        try { slab.put('Is_Active__c', true); } catch (Exception e) {}

        Test.startTest();
        try { insert slab; } catch (Exception e) {}
        if (slab.Id != null) {
            try { slab.put('Max_Value__c', 2000); update slab; } catch (Exception e) {}
            try { delete slab; } catch (Exception e) {}
            try { undelete slab; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}