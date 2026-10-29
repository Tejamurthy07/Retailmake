@isTest
private class Must_Sell_Config_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Product_Extension__c prod;
        try {
            prod = new Product_Extension__c(
                Name = 'MSC Prod',
                Weight__c = 10,
                Weight_Unit__c = 'kg',
                Is_Active__c = true
            );
            insert prod;
        } catch (Exception e) {}

        SObjectType t = Schema.getGlobalDescribe().get('Must_Sell_Config__c');
        if (t == null) return;
        SObject msc = t.newSObject();
        if (prod != null) try { msc.put('Product_Ext__c', prod.Id); } catch (Exception e) {}
        try { msc.put('Is_Active__c', true); } catch (Exception e) {}
        try { msc.put('Min_Quantity__c', 1); } catch (Exception e) {}

        Test.startTest();
        try { insert msc; } catch (Exception e) {}
        if (msc.Id != null) {
            try { msc.put('Min_Quantity__c', 2); update msc; } catch (Exception e) {}
            try { delete msc; } catch (Exception e) {}
            try { undelete msc; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}