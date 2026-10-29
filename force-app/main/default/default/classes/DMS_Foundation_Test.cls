/**
 * @description Phase 0 foundation tests for the Distributor Management System.
 *              Covers DMS_Constants, the distributor-aware stock-model fields,
 *              the new Distributor_Stock_Norm__c object, and the
 *              Stock_Adjustment__c location-reference validation rule.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_Foundation_Test {

    @isTest
    static void constants_exposeExpectedValues() {
        System.assertEquals('DMS-001', DMS_Constants.TOGGLE_MASTER, 'Master toggle code');
        System.assertEquals('DMS-010', DMS_Constants.TOGGLE_PORTAL, 'Portal toggle code');
        System.assertEquals('Distributor', DMS_Constants.LOCATION_DISTRIBUTOR, 'Distributor location value');
        System.assertEquals('Warehouse', DMS_Constants.LOCATION_WAREHOUSE, 'Warehouse location value');
        System.assertEquals('Primary', DMS_Constants.ORDER_TYPE_PRIMARY, 'Primary order type');
        System.assertEquals('Secondary', DMS_Constants.ORDER_TYPE_SECONDARY, 'Secondary order type');
    }

    @isTest
    static void distributorStockNorm_insertsAndPersists() {
        Account dist = TestDataFactory.createAndInsertAccount('Test Distributor', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);

        Test.startTest();
        Distributor_Stock_Norm__c norm =
            TestDataFactory.createDistributorStockNorm(dist.Id, products[0].Id);
        Test.stopTest();

        Distributor_Stock_Norm__c saved = [
            SELECT Account__c, Product_Ext__c, Reorder_Level__c, Max_Stock_Level__c, Is_Active__c
            FROM Distributor_Stock_Norm__c
            WHERE Id = :norm.Id
        ];
        System.assertEquals(dist.Id, saved.Account__c, 'Norm linked to distributor');
        System.assertEquals(products[0].Id, saved.Product_Ext__c, 'Norm linked to product');
        System.assertEquals(50, saved.Reorder_Level__c, 'Reorder level persisted');
        System.assertEquals(200, saved.Max_Stock_Level__c, 'Max level persisted');
        System.assertEquals(true, saved.Is_Active__c, 'Norm active by default');
    }

    @isTest
    static void stockAdjustment_distributorLocation_requiresAccount() {
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);

        // Distributor adjustment without an Account must fail the validation rule.
        Stock_Adjustment__c bad = new Stock_Adjustment__c(
            Location_Type__c = DMS_Constants.LOCATION_DISTRIBUTOR,
            Product_Ext__c = products[0].Id,
            System_Qty__c = 100,
            Actual_Qty__c = 90,
            Adjustment_Qty__c = -10
        );

        Test.startTest();
        Boolean blocked = false;
        try {
            insert bad;
        } catch (DmlException e) {
            blocked = true;
            System.assert(
                e.getMessage().contains('Distributor (Account) is required'),
                'Expected location-reference validation message, got: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assertEquals(true, blocked, 'Distributor adjustment without Account should be blocked');
    }

    @isTest
    static void stockAdjustment_distributorLocation_succeedsWithAccount() {
        Account dist = TestDataFactory.createAndInsertAccount('Test Distributor', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);

        Stock_Adjustment__c good = new Stock_Adjustment__c(
            Location_Type__c = DMS_Constants.LOCATION_DISTRIBUTOR,
            Account__c = dist.Id,
            Product_Ext__c = products[0].Id,
            System_Qty__c = 100,
            Actual_Qty__c = 95,
            Adjustment_Qty__c = -5,
            // Reason_Required VR: every adjustment must say why.
            Reason__c = 'Physical count variance'
        );

        Test.startTest();
        insert good;
        Test.stopTest();

        System.assertNotEquals(null, good.Id, 'Distributor adjustment with Account should insert');
    }

    @isTest
    static void stockTransaction_acceptsDistributorReference() {
        Account dist = TestDataFactory.createAndInsertAccount('Test Distributor', 'Distributor');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);

        Stock_Transaction__c txn = new Stock_Transaction__c(
            Account__c = dist.Id,
            Product_Ext__c = products[0].Id,
            Direction__c = DMS_Constants.DIRECTION_IN,
            Quantity__c = 25
        );

        Test.startTest();
        insert txn;
        Test.stopTest();

        Stock_Transaction__c saved = [
            SELECT Account__c, Direction__c, Quantity__c FROM Stock_Transaction__c WHERE Id = :txn.Id
        ];
        System.assertEquals(dist.Id, saved.Account__c, 'Transaction linked to distributor');
        System.assertEquals('In', saved.Direction__c, 'Direction persisted');
    }
}