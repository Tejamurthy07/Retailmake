/**
 * @description Phase 2 tests for the DMS replenishment engine: norm-vs-on-hand
 *              comparison, draft-indent generation, and toggle gating.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_Replenishment_Test {

    private static void enableToggles() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_NORMS_REPLENISH, true);
    }

    /** Inserts a current distributor-stock snapshot with the given on-hand. */
    private static void seedStock(Id accountId, Id productId, Decimal onHand) {
        insert new Distributor_Stock__c(
            Account__c = accountId,
            Product_Ext__c = productId,
            Opening_Stock__c = onHand,
            Received_Qty__c = 0,
            Sold_Qty__c = 0,
            Damaged_Qty__c = 0,
            Stock_Date__c = Date.today(),
            Is_Current__c = true
        );
    }

    @isTest
    static void generatesDraftIndent_forBelowReorderProductOnly() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist R', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(2);

        // Norms default to reorder 50, max 200 (TestDataFactory).
        TestDataFactory.createDistributorStockNorm(dist.Id, products[0].Id); // low
        TestDataFactory.createDistributorStockNorm(dist.Id, products[1].Id); // well stocked

        seedStock(dist.Id, products[0].Id, 10);   // <= reorder 50 -> replenish
        seedStock(dist.Id, products[1].Id, 120);  // > reorder 50 -> skip

        enableToggles();
        Test.startTest();
        List<Id> indentIds = DMS_Replenishment_Service.generateReplenishmentIndents(
            new Set<Id>{ dist.Id });
        Test.stopTest();

        System.assertEquals(1, indentIds.size(), 'One draft order for the distributor');

        Primary_Order__c order = [SELECT Status__c FROM Primary_Order__c WHERE Id = :indentIds[0]];
        System.assertEquals('Draft', order.Status__c, 'Replenishment order is Draft');

        List<Primary_Order_Line__c> lines = [
            SELECT Product_Ext__c, Quantity__c
            FROM Primary_Order_Line__c WHERE Primary_Order__c = :indentIds[0]
        ];
        System.assertEquals(1, lines.size(), 'Only the below-reorder product is replenished');
        System.assertEquals(products[0].Id, lines[0].Product_Ext__c, 'Correct product');
        System.assertEquals(190, lines[0].Quantity__c, 'Qty = Max(200) - onHand(10)');
    }

    @isTest
    static void buildSuggestions_returnsExpected() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist S', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        TestDataFactory.createDistributorStockNorm(dist.Id, products[0].Id);
        seedStock(dist.Id, products[0].Id, 5);

        Test.startTest();
        List<DMS_Replenishment_Service.Suggestion> suggestions =
            DMS_Replenishment_Service.buildSuggestions(new Set<Id>{ dist.Id });
        Test.stopTest();

        System.assertEquals(1, suggestions.size(), 'One suggestion');
        System.assertEquals(195, suggestions[0].suggestedQty, 'Qty = 200 - 5');
    }

    @isTest
    static void togglesOff_createsNothing() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist T', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        TestDataFactory.createDistributorStockNorm(dist.Id, products[0].Id);
        seedStock(dist.Id, products[0].Id, 1);

        // Explicitly disable in the cache (the org enables the DMS toggles as real
        // Feature_Toggle__mdt, which are visible in tests).
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_NORMS_REPLENISH, false);
        Test.startTest();
        List<Id> indentIds = DMS_Replenishment_Service.generateAll();
        Test.stopTest();

        System.assertEquals(0, indentIds.size(), 'No orders when DMS disabled');
    }

    @isTest
    static void scheduler_runsWithoutError() {
        enableToggles();
        Test.startTest();
        new DMS_Replenishment_Scheduler().execute(null);
        Test.stopTest();
        // No norms -> nothing generated; asserting it executes cleanly.
        System.assertEquals(0, [SELECT COUNT() FROM Primary_Order__c], 'No orders generated with no norms');
    }

    @isTest
    static void scheduler_schedule_registersJob() {
        Test.startTest();
        Id jobId = DMS_Replenishment_Scheduler.schedule();
        Test.stopTest();
        System.assertNotEquals(null, jobId, 'Scheduled job id returned');
        System.assertEquals(1, [
            SELECT COUNT() FROM CronTrigger WHERE Id = :jobId
        ], 'Replenishment job registered');
    }
}