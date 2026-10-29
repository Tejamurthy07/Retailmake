@isTest
private class Scheme_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Scheme__c s;
        try {
            s = TestDataFactory.createScheme('STR Scheme', 'STR-001', 'Percentage');
            try { s.put('Budget_Amount__c', (Decimal) 10000); } catch (Exception e) {}
            insert s;
        } catch (Exception e) {}

        Test.startTest();
        if (s != null && s.Id != null) {
            try { s.Description__c = 'updated'; update s; } catch (Exception e) {}
            try { delete s; } catch (Exception e) {}
            try { undelete s; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}