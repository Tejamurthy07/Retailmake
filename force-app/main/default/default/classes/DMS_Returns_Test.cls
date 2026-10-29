/**
 * @description Tests for DMS secondary returns (retailer → distributor): returned
 *              goods post back into distributor stock + a distributor stock-in
 *              transaction, while the retailer credit note is still issued by the
 *              existing return handler. Includes toggle gating.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_Returns_Test {

    private static void enableReturns() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_RETURNS, true);
    }

    private static void seedStock(Id accountId, Id productId, String batch, Decimal qty) {
        insert new Distributor_Stock__c(
            Account__c = accountId, Product_Ext__c = productId, Batch_No__c = batch,
            Opening_Stock__c = qty, Stock_Date__c = Date.today(), Is_Current__c = true
        );
    }

    private static Decimal onHand(Id accountId, Id productId) {
        Map<String, Decimal> m = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ accountId }, new Set<Id>{ productId });
        String k = DMS_DistributorInventory_Service.key(accountId, productId);
        return m.containsKey(k) ? m.get(k) : 0;
    }

    private static Id createSecondaryReturn(Id retailerId, Id distributorId, Id productId, Decimal qty) {
        Return_Order__c ro = new Return_Order__c(
            Account__c = retailerId,
            Return_Type__c = 'Secondary',
            Returned_To_Distributor__c = distributorId,
            Return_Date__c = Date.today(),
            Return_Quantity__c = qty, // header qty (OMS validateReturnQuantity requires > 0)
            Return_Amount__c = 100,
            Status__c = 'Draft'
        );
        insert ro;
        insert new Return_Line__c(
            Return_Order__c = ro.Id, Product_Ext__c = productId,
            Return_Quantity__c = qty, Batch_No__c = 'B1'
        );
        return ro.Id;
    }

    private static Id createPrimaryReturn(Id distributorId, Id productId, Decimal qty) {
        Return_Order__c ro = new Return_Order__c(
            Account__c = distributorId, // distributor returning to the company
            Return_Type__c = 'Primary',
            Return_Date__c = Date.today(),
            Return_Quantity__c = qty,
            Return_Amount__c = 100,
            Status__c = 'Draft'
        );
        insert ro;
        insert new Return_Line__c(
            Return_Order__c = ro.Id, Product_Ext__c = productId,
            Return_Quantity__c = qty, Batch_No__c = 'B1'
        );
        return ro.Id;
    }

    @isTest
    static void secondaryReturn_restocksDistributor_andCreditsRetailer() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist RT', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer RT', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedStock(dist.Id, products[0].Id, 'B1', 50);

        Id roId = createSecondaryReturn(retailer.Id, dist.Id, products[0].Id, 10);

        enableReturns();
        Test.startTest();
        update new Return_Order__c(Id = roId, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(60, onHand(dist.Id, products[0].Id),
            'Returned goods added back to distributor stock (50 + 10)');

        System.assertEquals(1, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Account__c = :dist.Id AND Direction__c = 'In' AND Reference_Type__c = 'Return_Order'
        ], 'Distributor stock-in transaction written');

        System.assertEquals(1, [
            SELECT COUNT() FROM Ledger_Entry__c
            WHERE Account__c = :retailer.Id AND Entry_Type__c = 'Credit Note'
              AND Reference_Type__c = 'Return Order'
        ], 'Retailer credit note still issued by existing handler');
    }

    @isTest
    static void secondaryReturn_togglesOff_noRestock() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist RT2', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer RT2', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedStock(dist.Id, products[0].Id, 'B1', 50);

        Id roId = createSecondaryReturn(retailer.Id, dist.Id, products[0].Id, 10);

        // Explicitly disable in the cache (the org enables the DMS toggles as real
        // Feature_Toggle__mdt, which are visible in tests).
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_RETURNS, false);
        Test.startTest();
        update new Return_Order__c(Id = roId, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(50, onHand(dist.Id, products[0].Id),
            'Distributor stock unchanged when DMS returns disabled');
    }

    @isTest
    static void primaryReturn_decrementsDistributor() {
        // Distributor returns goods to the company: its own on-hand must drop.
        Account dist = TestDataFactory.createAndInsertAccount('Dist PR', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedStock(dist.Id, products[0].Id, 'B1', 50);

        Id roId = createPrimaryReturn(dist.Id, products[0].Id, 10);

        enableReturns();
        Test.startTest();
        update new Return_Order__c(Id = roId, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(40, onHand(dist.Id, products[0].Id),
            'Primary return removes goods from distributor stock (50 - 10)');
        System.assertEquals(1, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Account__c = :dist.Id AND Direction__c = 'Out' AND Reference_Type__c = 'Return_Order'
        ], 'Distributor stock-out transaction written for the primary return');
    }
}