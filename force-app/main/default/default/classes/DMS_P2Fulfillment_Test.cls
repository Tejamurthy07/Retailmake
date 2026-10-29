/**
 * @description Tests for DMS P2 (Super Stockist -> Distributor) fulfillment:
 *              FEFO deduction from super-stockist stock, P2 invoice creation,
 *              receipt into distributor stock via auto-GRN, credit enforcement,
 *              insufficient-stock handling, and toggle gating.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_P2Fulfillment_Test {

    private static void enableToggles() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_P2_FULFILLMENT, true);
    }

    private static void seedBatch(Id accountId, Id productId, String batch, Date expiry, Decimal qty) {
        insert new Distributor_Stock__c(
            Account__c = accountId, Product_Ext__c = productId, Batch_No__c = batch,
            Expiry_Date__c = expiry, Opening_Stock__c = qty, Stock_Date__c = Date.today(), Is_Current__c = true
        );
    }

    private static Decimal onHand(Id accountId, Id productId) {
        Map<String, Decimal> m = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ accountId }, new Set<Id>{ productId });
        String k = DMS_DistributorInventory_Service.key(accountId, productId);
        return m.containsKey(k) ? m.get(k) : 0;
    }

    @isTest
    static void p2_billsFromStockistAndReceivesIntoDistributor() {
        Account ss = TestDataFactory.createAndInsertAccount('SS P2', 'Distributor');
        Account dist = TestDataFactory.createAndInsertAccount('Dist P2', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Id productId = products[0].Id;

        // Super stockist holds two batches; FEFO consumes the earlier-expiry first.
        seedBatch(ss.Id, productId, 'EARLY', Date.today().addDays(10), 30);
        seedBatch(ss.Id, productId, 'LATE',  Date.today().addDays(60), 50);

        enableToggles();
        Test.startTest();
        Id invoiceId = DMS_P2Fulfillment_Service.createP2Invoice(
            ss.Id, dist.Id,
            new List<DMS_P2Fulfillment_Service.LineRequest>{
                new DMS_P2Fulfillment_Service.LineRequest(productId, 60, 10)
            });
        Test.stopTest();

        Invoice__c inv = [
            SELECT Order_Type__c, Account__c, Sold_From_Distributor__c, Total_Amount__c
            FROM Invoice__c WHERE Id = :invoiceId
        ];
        System.assertEquals('P2', inv.Order_Type__c, 'P2 invoice');
        System.assertEquals(dist.Id, inv.Account__c, 'Billed to distributor');
        System.assertEquals(ss.Id, inv.Sold_From_Distributor__c, 'Sourced from super-stockist stock');
        System.assertEquals(600, inv.Total_Amount__c, 'Total = 60 * 10');

        // FEFO: 30 EARLY + 30 LATE.
        List<Invoice_Line__c> ilines = [
            SELECT Batch_No__c, Quantity__c FROM Invoice_Line__c WHERE Invoice__c = :invoiceId ORDER BY Line_Number__c
        ];
        System.assertEquals(2, ilines.size(), 'One line per allocated batch');
        System.assertEquals('EARLY', ilines[0].Batch_No__c, 'Earliest-expiry batch consumed first');

        // Super stockist reduced by 60 (30+50-60 = 20); distributor increased by 60.
        System.assertEquals(20, onHand(ss.Id, productId), 'Super stockist stock reduced to 20');
        System.assertEquals(60, onHand(dist.Id, productId), 'Distributor received 60');

        // GRN audit record created for the buyer against the P2 invoice.
        System.assertEquals(1, [SELECT COUNT() FROM GRN__c WHERE Invoice__c = :invoiceId AND Account__c = :dist.Id],
            'One GRN posted for the distributor');
        Integer inTxns = [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Account__c = :dist.Id AND Direction__c = 'In' AND Reference_Type__c = 'GRN'
        ];
        System.assert(inTxns >= 1, 'Distributor In transactions written');
    }

    @isTest
    static void insufficientStockistStock_throws() {
        Account ss = TestDataFactory.createAndInsertAccount('SS P2b', 'Distributor');
        Account dist = TestDataFactory.createAndInsertAccount('Dist P2b', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedBatch(ss.Id, products[0].Id, 'B1', Date.today().addDays(30), 20);

        enableToggles();
        Boolean thrown = false;
        Test.startTest();
        try {
            DMS_P2Fulfillment_Service.createP2Invoice(ss.Id, dist.Id,
                new List<DMS_P2Fulfillment_Service.LineRequest>{
                    new DMS_P2Fulfillment_Service.LineRequest(products[0].Id, 50, 10)
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Insufficient'), 'Insufficient stock message');
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Should throw on insufficient super-stockist stock');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c WHERE Order_Type__c = 'P2' AND Account__c = :dist.Id],
            'No P2 invoice created on failure');
    }

    @isTest
    static void distributorCreditExceeded_throws() {
        Account ss = TestDataFactory.createAndInsertAccount('SS P2c', 'Distributor');
        Account dist = TestDataFactory.createAndInsertAccount('Dist P2c', 'Distributor');
        dist.Credit_Limit__c = 100;
        dist.Outstanding_Balance__c = 0;
        update dist;
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedBatch(ss.Id, products[0].Id, 'B1', Date.today().addDays(30), 1000);

        enableToggles();
        Boolean thrown = false;
        Test.startTest();
        try {
            DMS_P2Fulfillment_Service.createP2Invoice(ss.Id, dist.Id,
                new List<DMS_P2Fulfillment_Service.LineRequest>{
                    new DMS_P2Fulfillment_Service.LineRequest(products[0].Id, 60, 10) // 600 > 100
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Credit limit exceeded'), 'Credit message');
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Should throw on distributor credit breach');
    }

    /**
     * P2 now allocates through the shared DMS_Fefo_Service, so it consumes the
     * earliest-expiring batch first. (The service also excludes already-expired batches —
     * P2's own FEFO copy had no such filter. That path can't be seeded directly because
     * Distributor_Stock enforces "Current stock entries cannot have a past expiry date";
     * it only arises when stock expires in place, which the SOQL filter now catches.)
     */
    @isTest
    static void p2_consumesEarliestExpiryBatchFirst() {
        Account ss = TestDataFactory.createAndInsertAccount('SS P2x', 'Distributor');
        Account dist = TestDataFactory.createAndInsertAccount('Dist P2x', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        // Seed the later-expiring batch FIRST, so insertion order can't explain the result.
        seedBatch(ss.Id, products[0].Id, 'LATE', Date.today().addDays(90), 100);
        seedBatch(ss.Id, products[0].Id, 'SOON', Date.today().addDays(5), 6);

        enableToggles();
        Test.startTest();
        DMS_P2Fulfillment_Service.createP2Invoice(ss.Id, dist.Id,
            new List<DMS_P2Fulfillment_Service.LineRequest>{
                new DMS_P2Fulfillment_Service.LineRequest(products[0].Id, 10, 10)
            });
        Test.stopTest();

        // 10 requested: the 6 units of the sooner-expiring batch must go first, then 4 from LATE.
        Map<String, Decimal> soldByBatch = new Map<String, Decimal>();
        for (Distributor_Stock__c ds : [
            SELECT Batch_No__c, Sold_Qty__c FROM Distributor_Stock__c
            WHERE Account__c = :ss.Id AND Sold_Qty__c > 0
        ]) {
            soldByBatch.put(ds.Batch_No__c,
                (soldByBatch.containsKey(ds.Batch_No__c) ? soldByBatch.get(ds.Batch_No__c) : 0)
                + ds.Sold_Qty__c);
        }
        System.assertEquals(6, soldByBatch.get('SOON'), 'Earliest-expiring batch drained first (FEFO)');
        System.assertEquals(4, soldByBatch.get('LATE'), 'Remainder taken from the later batch');
    }

    @isTest
    static void disabled_throws() {
        Account ss = TestDataFactory.createAndInsertAccount('SS P2d', 'Distributor');
        Account dist = TestDataFactory.createAndInsertAccount('Dist P2d', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedBatch(ss.Id, products[0].Id, 'B1', Date.today().addDays(30), 100);

        // Disable explicitly: Feature_Toggle__mdt is visible in tests and this org enables all
        // DMS toggles, so relying on the metadata default leaves P2 ON and nothing throws.
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_P2_FULFILLMENT, false);

        Boolean thrown = false;
        Test.startTest();
        try {
            DMS_P2Fulfillment_Service.createP2Invoice(ss.Id, dist.Id,
                new List<DMS_P2Fulfillment_Service.LineRequest>{
                    new DMS_P2Fulfillment_Service.LineRequest(products[0].Id, 10, 10)
                });
        } catch (DMS_SecondaryBillingException e) {
            thrown = true;
            System.assert(e.getMessage().contains('not enabled'), 'Disabled message');
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Should throw when P2 fulfillment disabled');
    }
}