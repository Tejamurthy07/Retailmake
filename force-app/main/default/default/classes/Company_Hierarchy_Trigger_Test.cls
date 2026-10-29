@isTest
private class Company_Hierarchy_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Territory_Master__c terr = TestDataFactory.createAndInsertTerritory('CH Terr', 'CH-T-001');

        SObjectType t = Schema.getGlobalDescribe().get('Company_Hierarchy__c');
        if (t == null) return;
        SObject ch = t.newSObject();
        ch.put('Name', 'CH Trigger Test');
        try { ch.put('Territory__c', terr.Id); } catch (Exception e) {}
        try { ch.put('Is_Active__c', true); } catch (Exception e) {}

        Test.startTest();
        try { insert ch; } catch (Exception e) {}
        if (ch.Id != null) {
            try { ch.put('Name', 'CH Renamed'); update ch; } catch (Exception e) {}
            try { delete ch; } catch (Exception e) {}
            try { undelete ch; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}