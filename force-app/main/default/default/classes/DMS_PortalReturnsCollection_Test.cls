/**
 * @description Tests for the distributor-portal Returns and Collection controller
 *              methods on DMS_PortalController: account-scoped reads, raising a
 *              return (with correct type + valuation), and recording a collection
 *              (which the collection trigger posts to the ledger + reduces balance).
 */
@isTest
private class DMS_PortalReturnsCollection_Test {

    private static void enablePortal() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_PORTAL, true);
    }

    private static Invoice__c invoiceWithLine(Id accountId, String orderType, Id productId, Decimal qty, Decimal price) {
        Invoice__c inv = new Invoice__c(
            Account__c = accountId, Order_Type__c = orderType, Invoice_Date__c = Date.today(),
            Invoice_Number__c = 'INV-RC-' + String.valueOf(Datetime.now().getTime()) + '-' + String.valueOf(Math.mod(qty.intValue() + price.intValue(), 9999)),
            Status__c = 'Draft', Total_Amount__c = qty * price, Balance_Due__c = qty * price
        );
        TriggerHandler.bypass('OMS_Invoice_TriggerHandler');
        insert inv;
        TriggerHandler.clearBypass('OMS_Invoice_TriggerHandler');
        insert new Invoice_Line__c(
            Invoice__c = inv.Id, Product_Ext__c = productId, Quantity__c = qty,
            Unit_Price__c = price, Line_Number__c = 1, Batch_No__c = 'B1'
        );
        return inv;
    }

    @isTest
    static void placeReturn_createsPrimaryReturn_valued() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PRC', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = invoiceWithLine(dist.Id, 'Primary', products[0].Id, 10, 100);

        enablePortal();
        DMS_PortalController.testAccountIdOverride = dist.Id;
        Test.startTest();
        String linesJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'productId' => products[0].Id, 'quantity' => 4, 'batch' => 'B1' }
        });
        Id roId = DMS_PortalController.placeReturn(inv.Id, linesJson, 'Damaged');
        Test.stopTest();

        Return_Order__c ro = [
            SELECT Return_Type__c, Account__c, Return_Quantity__c, Return_Amount__c, Status__c
            FROM Return_Order__c WHERE Id = :roId
        ];
        System.assertEquals('Primary', ro.Return_Type__c, 'Primary invoice -> primary return');
        System.assertEquals(dist.Id, ro.Account__c, 'Return raised by the distributor');
        System.assertEquals(4, ro.Return_Quantity__c, 'Header qty = sum of lines');
        System.assertEquals(400, ro.Return_Amount__c, 'Valued at 4 * 100 from the invoice line');
        System.assertEquals(1, [SELECT COUNT() FROM Return_Line__c WHERE Return_Order__c = :roId], 'One return line');

        System.assertEquals(1, DMS_PortalController.getReturns().size(), 'getReturns is scoped to the distributor');
    }

    @isTest
    static void placeReturn_secondaryInvoice_yieldsSecondaryReturn() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PRCs', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer PRCs', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        // Secondary invoice: billed to the retailer, sold from the distributor.
        Invoice__c inv = invoiceWithLine(retailer.Id, 'Secondary', products[0].Id, 6, 50);
        inv.Sold_From_Distributor__c = dist.Id;
        update inv;

        enablePortal();
        DMS_PortalController.testAccountIdOverride = dist.Id;
        Test.startTest();
        String linesJson = JSON.serialize(new List<Object>{
            new Map<String, Object>{ 'productId' => products[0].Id, 'quantity' => 2 }
        });
        Id roId = DMS_PortalController.placeReturn(inv.Id, linesJson, 'Quality Issue');
        Test.stopTest();

        Return_Order__c ro = [
            SELECT Return_Type__c, Account__c, Returned_To_Distributor__c FROM Return_Order__c WHERE Id = :roId
        ];
        System.assertEquals('Secondary', ro.Return_Type__c, 'Secondary invoice -> secondary return');
        System.assertEquals(retailer.Id, ro.Account__c, 'Returning account is the retailer');
        System.assertEquals(dist.Id, ro.Returned_To_Distributor__c, 'Received by the distributor');
    }

    @isTest
    static void recordCollection_reducesBalance_andScopes() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PRC2', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = invoiceWithLine(dist.Id, 'Primary', products[0].Id, 10, 100); // balance 1000

        enablePortal();
        DMS_PortalController.testAccountIdOverride = dist.Id;
        Test.startTest();
        Id collId = DMS_PortalController.recordCollection(inv.Id, 400, 'Cash', 'REF-1');
        Test.stopTest();

        Collection__c coll = [SELECT Amount__c, Account__c, Invoice__c FROM Collection__c WHERE Id = :collId];
        System.assertEquals(400, coll.Amount__c, 'Collection amount');
        System.assertEquals(dist.Id, coll.Account__c, 'Posted to the invoice debtor');
        System.assertEquals(inv.Id, coll.Invoice__c, 'Linked to the invoice');

        // The collection trigger (single writer) reduced the invoice balance.
        Invoice__c after = [SELECT Balance_Due__c FROM Invoice__c WHERE Id = :inv.Id];
        System.assertEquals(600, after.Balance_Due__c, '1000 - 400');

        System.assertEquals(1, DMS_PortalController.getCollections().size(), 'getCollections scoped');
        System.assert(!DMS_PortalController.getCollectibleInvoices().isEmpty(), 'Outstanding invoice still collectible');
    }

    @isTest
    static void recordCollection_onAccount_noInvoice() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist ONA', 'Distributor');
        enablePortal();
        DMS_PortalController.testAccountIdOverride = dist.Id;
        Test.startTest();
        Id collId = DMS_PortalController.recordCollection(null, 1000, 'Cheque', '3423423423');
        Test.stopTest();

        Collection__c coll = [
            SELECT Amount__c, Account__c, Is_On_Account__c, Invoice__c, Payment_Mode__c
            FROM Collection__c WHERE Id = :collId
        ];
        System.assertEquals(1000, coll.Amount__c, 'Amount saved');
        System.assertEquals(dist.Id, coll.Account__c, 'Posted on the distributor account');
        System.assertEquals(true, coll.Is_On_Account__c, 'Flagged on-account');
        System.assertEquals(null, coll.Invoice__c, 'No invoice link');
    }

    @isTest
    static void recordCollection_rejectsOverpayment() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist PRC3', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = invoiceWithLine(dist.Id, 'Primary', products[0].Id, 5, 100); // balance 500

        enablePortal();
        DMS_PortalController.testAccountIdOverride = dist.Id;
        Boolean thrown = false;
        Test.startTest();
        try {
            DMS_PortalController.recordCollection(inv.Id, 900, 'Cash', null);
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Overpayment beyond invoice balance is rejected');
    }
}