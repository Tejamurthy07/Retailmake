/**
 * @description Test class for TAM_Rollup_Service.
 *              Validates rollup of achievement values through manager hierarchy.
 */
@isTest
private class TAM_Rollup_Service_Test {

    @testSetup
    static void setupTestData() {
        // Create Target Criteria
        Target_Criteria__c criteria = new Target_Criteria__c(
            Name = 'Test Rollup Criteria',
            Object__c = 'Account',
            Operator__c = 'COUNT',
            Field__c = 'Id',
            Date_Field__c = 'CreatedDate',
            User_Field__c = 'OwnerId',
            Active__c = true
        );
        insert criteria;

        // Create Target Period covering today
        Target_Period__c period = new Target_Period__c(
            Name = 'Test Period',
            Start_Date__c = Date.today().addDays(-15),
            End_Date__c = Date.today().addDays(15),
            Is_Active__c = true,
            Type__c = 'Monthly'
        );
        insert period;

        // Create Target Actual for the running user
        Target_Actual__c ta = new Target_Actual__c(
            User__c = UserInfo.getUserId(),
            Target_Criteria__c = criteria.Id,
            Target_Period__c = period.Id,
            Target_Value__c = 100,
            Achievement_Value__c = 50
        );
        insert ta;
    }

    /**
     * @description Passing an empty list should not cause errors.
     */
    @isTest
    static void testRun_EmptyScope() {
        List<Target_Actual__c> emptyList = new List<Target_Actual__c>();

        Test.startTest();
        TAM_Rollup_Service.run(emptyList);
        Test.stopTest();

        // No exception means success — verify records unchanged
        List<Target_Actual__c> actuals = [SELECT Id FROM Target_Actual__c];
        System.assertNotEquals(null, actuals, 'Query should return a list even if empty');
    }

    /**
     * @description A single Target_Actual__c record should process without error.
     */
    @isTest
    static void testRun_SingleRecord() {
        Target_Actual__c ta = [
            SELECT Id, User__c, Target_Criteria__c, Target_Period__c,
                   Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c
            LIMIT 1
        ];

        Test.startTest();
        TAM_Rollup_Service.run(new List<Target_Actual__c>{ ta });
        Test.stopTest();

        Target_Actual__c updated = [
            SELECT Id, Teams_Target__c, Teams_Achievement__c
            FROM Target_Actual__c
            WHERE Id = :ta.Id
        ];
        System.assertNotEquals(null, updated, 'Record should still exist after rollup');
    }

    /**
     * @description Verifies that Teams_Target__c and Teams_Achievement__c are
     *              calculated when subordinate records exist under a manager.
     */
    @isTest
    static void testRun_WithTeamRollup() {
        Target_Criteria__c criteria = [SELECT Id FROM Target_Criteria__c LIMIT 1];
        Target_Period__c period = [SELECT Id FROM Target_Period__c LIMIT 1];

        // The running user acts as the manager
        Id managerId = UserInfo.getUserId();

        // Create a subordinate user whose ManagerId points to running user
        User subordinate = new User(
            FirstName = 'Sub',
            LastName = 'Ordinate',
            Email = 'sub.ordinate.tam@example.com',
            Username = 'sub.ordinate.tam.' + DateTime.now().getTime() + '@example.com',
            Alias = 'subord',
            TimeZoneSidKey = 'Asia/Kolkata',
            LocaleSidKey = 'en_IN',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
            ManagerId = managerId
        );
        insert subordinate;

        // Create a Target_Actual__c for the subordinate
        Target_Actual__c subTarget = new Target_Actual__c(
            User__c = subordinate.Id,
            Target_Criteria__c = criteria.Id,
            Target_Period__c = period.Id,
            Target_Value__c = 200,
            Achievement_Value__c = 80
        );
        insert subTarget;

        // Re-query the subordinate record so the scope contains required fields
        List<Target_Actual__c> scope = [
            SELECT Id, User__c, Target_Criteria__c, Target_Period__c,
                   Target_Value__c, Achievement_Value__c
            FROM Target_Actual__c
            WHERE User__c = :subordinate.Id
        ];

        Test.startTest();
        TAM_Rollup_Service.run(scope);
        Test.stopTest();

        // The manager's Target_Actual__c should have team rollup values
        Target_Actual__c managerActual = [
            SELECT Id, Teams_Target__c, Teams_Achievement__c
            FROM Target_Actual__c
            WHERE User__c = :managerId
            AND Target_Criteria__c = :criteria.Id
            AND Target_Period__c = :period.Id
            LIMIT 1
        ];

        System.assertNotEquals(null, managerActual.Teams_Target__c,
            'Teams_Target__c should be populated after rollup');
        System.assertNotEquals(null, managerActual.Teams_Achievement__c,
            'Teams_Achievement__c should be populated after rollup');
        System.assertEquals(200, managerActual.Teams_Target__c,
            'Teams_Target__c should equal subordinate target value');
        System.assertEquals(80, managerActual.Teams_Achievement__c,
            'Teams_Achievement__c should equal subordinate achievement value');
    }
}