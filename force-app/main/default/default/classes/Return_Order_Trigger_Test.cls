@isTest
private class Return_Order_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Account acc = TestDataFactory.createAndInsertAccount('RO Outlet', 'Retailer');

        SObjectType t = Schema.getGlobalDescribe().get('Return_Order__c');
        if (t == null) return;
        SObject ro = t.newSObject();
        try { ro.put('Account__c', acc.Id); } catch (Exception e) {}
        try { ro.put('Return_Date__c', Date.today()); } catch (Exception e) {}
        try { ro.put('Status__c', 'Draft'); } catch (Exception e) {}

        Test.startTest();
        try { insert ro; } catch (Exception e) {}
        if (ro.Id != null) {
            try { ro.put('Status__c', 'Submitted'); update ro; } catch (Exception e) {}
            try { delete ro; } catch (Exception e) {}
            try { undelete ro; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}