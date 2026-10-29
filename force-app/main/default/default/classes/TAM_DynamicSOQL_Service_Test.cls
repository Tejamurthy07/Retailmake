/**
 * @description Test class for TAM_DynamicSOQL_Service.
 *              Validates dynamic SOQL generation for target achievement calculations.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class TAM_DynamicSOQL_Service_Test {

    @testSetup
    static void setupData() {
        Target_Period__c period = new Target_Period__c(
            Name = 'Test Period',
            Start_Date__c = Date.today().toStartOfMonth(),
            End_Date__c = Date.today().toStartOfMonth().addMonths(1).addDays(-1),
            Is_Active__c = true,
            Type__c = 'Monthly'
        );
        insert period;

        Target_Criteria__c criteria = new Target_Criteria__c(
            Name = 'Test Criteria',
            Object__c = 'Sales_Order__c',
            Operator__c = 'SUM',
            Field__c = 'Amount__c',
            Date_Field__c = 'Order_Date__c',
            User_Field__c = 'OwnerId',
            Active__c = true
        );
        insert criteria;
    }

    @isTest
    static void testBuildSOQL_SumFunction() {
        TAM_DynamicSOQL_Service.Context ctx = new TAM_DynamicSOQL_Service.Context();
        ctx.objectName = 'Sales_Order__c';
        ctx.userField = 'OwnerId';
        ctx.aggField = 'Amount__c';
        ctx.aggFunction = 'SUM';
        ctx.dateField = 'Order_Date__c';
        ctx.startDate = Date.today().toStartOfMonth();
        ctx.endDate = Date.today().toStartOfMonth().addMonths(1).addDays(-1);
        ctx.filtersJson = null;
        ctx.logic = null;
        ctx.userIds = new Set<Id>{ UserInfo.getUserId() };

        Test.startTest();
        String soql = TAM_DynamicSOQL_Service.buildSOQL(ctx);
        Test.stopTest();

        System.assert(soql.contains('SUM(Amount__c)'), 'SOQL should contain SUM aggregation');
        System.assert(soql.contains('FROM Sales_Order__c'), 'SOQL should contain object name');
        System.assert(soql.contains('GROUP BY OwnerId'), 'SOQL should group by user field');
        System.assert(soql.contains('HAVING OwnerId IN :userIds'), 'SOQL should have user filter in HAVING');
    }

    @isTest
    static void testBuildSOQL_CountFunction() {
        TAM_DynamicSOQL_Service.Context ctx = new TAM_DynamicSOQL_Service.Context();
        ctx.objectName = 'Sales_Order__c';
        ctx.userField = 'OwnerId';
        ctx.aggField = null;
        ctx.aggFunction = 'COUNT';
        ctx.dateField = 'Order_Date__c';
        ctx.startDate = Date.today().toStartOfMonth();
        ctx.endDate = Date.today().toStartOfMonth().addMonths(1).addDays(-1);
        ctx.filtersJson = null;
        ctx.logic = null;
        ctx.userIds = new Set<Id>{ UserInfo.getUserId() };

        Test.startTest();
        String soql = TAM_DynamicSOQL_Service.buildSOQL(ctx);
        Test.stopTest();

        System.assert(soql.contains('COUNT(Id)'), 'COUNT function should use COUNT(Id)');
        System.assert(!soql.contains('SUM'), 'COUNT query should not contain SUM');
    }

    @isTest
    static void testBuildSOQL_WithFilters() {
        String filtersJson = '{"filters": [{"id": 1, "field": "Status__c", "operator": "=", "value": "Approved", "type": "String"}]}';

        TAM_DynamicSOQL_Service.Context ctx = new TAM_DynamicSOQL_Service.Context();
        ctx.objectName = 'Sales_Order__c';
        ctx.userField = 'OwnerId';
        ctx.aggField = 'Amount__c';
        ctx.aggFunction = 'SUM';
        ctx.dateField = 'Order_Date__c';
        ctx.startDate = Date.today().toStartOfMonth();
        ctx.endDate = Date.today().toStartOfMonth().addMonths(1).addDays(-1);
        ctx.filtersJson = filtersJson;
        ctx.logic = null;
        ctx.userIds = new Set<Id>{ UserInfo.getUserId() };

        Test.startTest();
        String soql = TAM_DynamicSOQL_Service.buildSOQL(ctx);
        Test.stopTest();

        System.assert(soql.contains('Status__c'), 'SOQL should incorporate filter field');
        System.assert(soql.contains('Approved'), 'SOQL should incorporate filter value');
    }

    @isTest
    static void testBuildSOQL_WithoutFilters() {
        TAM_DynamicSOQL_Service.Context ctx = new TAM_DynamicSOQL_Service.Context();
        ctx.objectName = 'Sales_Order__c';
        ctx.userField = 'OwnerId';
        ctx.aggField = 'Amount__c';
        ctx.aggFunction = 'SUM';
        ctx.dateField = 'Order_Date__c';
        ctx.startDate = Date.today().toStartOfMonth();
        ctx.endDate = Date.today().toStartOfMonth().addMonths(1).addDays(-1);
        ctx.filtersJson = null;
        ctx.logic = null;
        ctx.userIds = new Set<Id>{ UserInfo.getUserId() };

        Test.startTest();
        String soql = TAM_DynamicSOQL_Service.buildSOQL(ctx);
        Test.stopTest();

        System.assert(soql.contains('Order_Date__c >= :startDate'), 'SOQL should contain start date condition');
        System.assert(soql.contains('Order_Date__c <= :endDate'), 'SOQL should contain end date condition');
        System.assert(soql.contains('SELECT OwnerId'), 'SOQL should select user field');
    }
}