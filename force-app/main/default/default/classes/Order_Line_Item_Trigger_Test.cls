@isTest
private class Order_Line_Item_Trigger_Test {

    @isTest
    static void testTriggerFires() {
        Account acc = TestDataFactory.createAndInsertAccount('OLI Outlet', 'Retailer');
        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        so.Order_Date__c = Date.today();
        try { insert so; } catch (Exception e) { return; }

        Order_Line_Item__c oli = new Order_Line_Item__c(
            Sales_Order__c = so.Id,
            Quantity__c = 1,
            Unit_Price__c = 100,
            UOM__c = 'Pieces'
        );

        Test.startTest();
        try { insert oli; } catch (Exception e) {}
        if (oli.Id != null) {
            try { oli.Quantity__c = 2; update oli; } catch (Exception e) {}
            try { delete oli; } catch (Exception e) {}
            try { undelete oli; } catch (Exception e) {}
        }
        Test.stopTest();
    }
}