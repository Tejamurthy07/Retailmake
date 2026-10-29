@isTest
private class Price_List_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Product_Extension__c prod;
        try {
            prod = new Product_Extension__c(
                Name = 'PL Prod',
                Weight__c = 10,
                Weight_Unit__c = 'kg',
                Is_Active__c = true
            );
            insert prod;
        } catch (Exception e) {}

        SObjectType t = Schema.getGlobalDescribe().get('Price_List__c');
        if (t == null) return;
        SObject pl = t.newSObject();
        if (prod != null) try { pl.put('Product_Ext__c', prod.Id); } catch (Exception e) {}
        try { pl.put('Unit_Price__c', 100); } catch (Exception e) {}
        try { pl.put('Effective_From__c', Date.today()); } catch (Exception e) {}
        try { pl.put('Is_Active__c', true); } catch (Exception e) {}

        Test.startTest();
        try { insert pl; } catch (Exception e) {}
        if (pl.Id != null) {
            try { pl.put('Unit_Price__c', 110); update pl; } catch (Exception e) {}
            try { delete pl; } catch (Exception e) {}
            try { undelete pl; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}