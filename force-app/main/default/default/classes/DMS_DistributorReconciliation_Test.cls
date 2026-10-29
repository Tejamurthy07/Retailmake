/**
 * @description Phase 2 tests for distributor stock reconciliation via
 *              Stock_Adjustment__c (Location_Type = Distributor): System_Qty
 *              snapshot on insert, and applying the adjustment to
 *              Distributor_Stock__c + Stock_Transaction__c on approval.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_DistributorReconciliation_Test {

    private static void enableToggles() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_STOCK_ACTIVITIES, true);
    }

    private static void seedStock(Id accountId, Id productId, Decimal onHand) {
        insert new Distributor_Stock__c(
            Account__c = accountId,
            Product_Ext__c = productId,
            Opening_Stock__c = onHand,
            Stock_Date__c = Date.today(),
            Is_Current__c = true
        );
    }

    private static Decimal currentOnHand(Id accountId, Id productId) {
        Map<String, Decimal> onHand = DMS_DistributorInventory_Service.getCurrentOnHand(
            new Set<Id>{ accountId }, new Set<Id>{ productId });
        String key = DMS_DistributorInventory_Service.key(accountId, productId);
        return onHand.containsKey(key) ? onHand.get(key) : 0;
    }

    @isTest
    static void insert_snapshotsSystemQty_fromCurrentOnHand() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist X', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedStock(dist.Id, products[0].Id, 100);

        enableToggles();
        Test.startTest();
        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Location_Type__c = DMS_Constants.LOCATION_DISTRIBUTOR,
            Account__c = dist.Id,
            Product_Ext__c = products[0].Id,
            Adjustment_Type__c = 'Physical_Count',
            Actual_Qty__c = 90,
            Status__c = 'Draft',
            // Reason_Required VR: every adjustment must say why.
            Reason__c = 'Cycle count reconciliation'
        );
        insert adj;
        Test.stopTest();

        Stock_Adjustment__c saved = [SELECT System_Qty__c FROM Stock_Adjustment__c WHERE Id = :adj.Id];
        System.assertEquals(100, saved.System_Qty__c, 'System qty snapshotted from current on-hand');
    }

    @isTest
    static void approval_appliesNegativeAdjustment() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist Y', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedStock(dist.Id, products[0].Id, 100);

        enableToggles();
        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Location_Type__c = DMS_Constants.LOCATION_DISTRIBUTOR,
            Account__c = dist.Id,
            Product_Ext__c = products[0].Id,
            Adjustment_Type__c = 'Correction_Deduct',
            Adjustment_Qty__c = -10,
            Status__c = 'Draft',
            // Reason_Required VR: every adjustment must say why.
            Reason__c = 'Cycle count reconciliation'
        );
        insert adj;

        Test.startTest();
        update new Stock_Adjustment__c(Id = adj.Id, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(90, currentOnHand(dist.Id, products[0].Id),
            'On-hand reduced by 10 after approval');

        System.assertEquals(1, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Account__c = :dist.Id AND Direction__c = 'Out'
              AND Transaction_Type__c = 'Adjustment_Deduct' AND Reference_Type__c = 'Stock_Adjustment'
        ], 'Deduct stock transaction written');
    }

    @isTest
    static void approval_appliesPositiveAdjustment() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist Z', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedStock(dist.Id, products[0].Id, 100);

        enableToggles();
        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Location_Type__c = DMS_Constants.LOCATION_DISTRIBUTOR,
            Account__c = dist.Id,
            Product_Ext__c = products[0].Id,
            Adjustment_Type__c = 'Correction_Add',
            Adjustment_Qty__c = 20,
            Status__c = 'Draft',
            // Reason_Required VR: every adjustment must say why.
            Reason__c = 'Cycle count reconciliation'
        );
        insert adj;

        Test.startTest();
        update new Stock_Adjustment__c(Id = adj.Id, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(120, currentOnHand(dist.Id, products[0].Id),
            'On-hand increased by 20 after approval');
    }

    @isTest
    static void approval_withTogglesOff_doesNotApply() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist Q', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        seedStock(dist.Id, products[0].Id, 100);

        // Toggles pinned OFF explicitly — unpinned, the test inherits the org's
        // Feature_Toggle__mdt state, where DMS is active, and the adjustment
        // applied anyway. Master stays ON so this isolates the stock-activities
        // toggle itself.
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_STOCK_ACTIVITIES, false);
        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Location_Type__c = DMS_Constants.LOCATION_DISTRIBUTOR,
            Account__c = dist.Id,
            Product_Ext__c = products[0].Id,
            Adjustment_Type__c = 'Correction_Deduct',
            Adjustment_Qty__c = -10,
            Status__c = 'Draft',
            // Reason_Required VR: every adjustment must say why.
            Reason__c = 'Cycle count reconciliation'
        );
        insert adj;

        Test.startTest();
        update new Stock_Adjustment__c(Id = adj.Id, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(100, currentOnHand(dist.Id, products[0].Id),
            'On-hand unchanged when DMS disabled');
    }
}