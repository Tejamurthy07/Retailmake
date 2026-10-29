@isTest
private class BPM_Beat_TriggerHandler_Test {

    @testSetup
    static void setupTestData() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory(
            'Beat Test Territory', 'TER-BT01');

        Beat__c beat = TestDataFactory.createBeat('Existing Beat', 'BEAT-EXIST01', territory.Id);
        beat.Day_of_Week__c = 'Monday;Wednesday';
        beat.Frequency__c = 'Weekly';
        insert beat;
    }

    @isTest
    static void testDefaultValues() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Test.startTest();
        Beat__c beat = new Beat__c(
            Name = 'New Beat',
            Beat_Code__c = 'BEAT-NEW01',
            Territory__c = territory.Id,
            Day_of_Week__c = 'Monday'
        );
        insert beat;
        Test.stopTest();

        Beat__c inserted = [SELECT Is_Active__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals(true, inserted.Is_Active__c, 'Is_Active__c should default to true');
    }

    @isTest
    static void testDefaultValues_AlreadySet() {
        // Is_Active__c explicitly false should not be overwritten by setDefaults.
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Test.startTest();
        Beat__c beat = new Beat__c(
            Name = 'Already Inactive',
            Beat_Code__c = 'BEAT-INAC01',
            Territory__c = territory.Id,
            Is_Active__c = false
        );
        insert beat;
        Test.stopTest();
        Beat__c inserted = [SELECT Is_Active__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals(false, inserted.Is_Active__c,
            'Explicit false should be preserved');
    }

    @isTest
    static void testDeprecatedFieldSync() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Test.startTest();
        Beat__c beat = new Beat__c(
            Name = 'Sync Beat',
            Beat_Code__c = 'BEAT-SYNC01',
            Territory__c = territory.Id,
            Day_of_Week__c = 'Tuesday;Thursday',
            Frequency__c = 'Bi-Weekly'
        );
        insert beat;
        Test.stopTest();

        Beat__c inserted = [SELECT Beat_Day__c, Beat_Frequency__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals('Tuesday;Thursday', inserted.Beat_Day__c);
        System.assertEquals('Bi-Weekly', inserted.Beat_Frequency__c);
    }

    @isTest
    static void testBeatCodeUniqueness() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Test.startTest();
        try {
            Beat__c duplicate = new Beat__c(
                Name = 'Duplicate Beat',
                Beat_Code__c = 'BEAT-EXIST01',
                Territory__c = territory.Id,
                Day_of_Week__c = 'Monday'
            );
            insert duplicate;
            System.assert(false, 'Should have thrown for duplicate Beat_Code__c');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('already in use'),
                'Error should mention beat code is already in use');
        }
        Test.stopTest();
    }

    @isTest
    static void testBeatCodeUniquenessInBatch() {
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];

        Test.startTest();
        try {
            List<Beat__c> beats = new List<Beat__c>();
            beats.add(new Beat__c(
                Name = 'Batch Beat 1',
                Beat_Code__c = 'BEAT-BATCH01',
                Territory__c = territory.Id,
                Day_of_Week__c = 'Monday'
            ));
            beats.add(new Beat__c(
                Name = 'Batch Beat 2',
                Beat_Code__c = 'BEAT-BATCH01',
                Territory__c = territory.Id,
                Day_of_Week__c = 'Monday'
            ));
            insert beats;
            System.assert(false, 'Should have thrown for duplicate codes in batch');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Duplicate'),
                'Error should mention duplicate Beat Code');
        }
        Test.stopTest();
    }

    @isTest
    static void testDeactivation_DeletesFuturePlans() {
        // The handler auto-deletes future Journey_Plan_Day__c rows when a
        // beat is deactivated. It does not throw.
        Beat__c beat = [SELECT Id, Is_Active__c FROM Beat__c
            WHERE Beat_Code__c = 'BEAT-EXIST01' LIMIT 1];

        Journey_Plan__c jp = TestDataFactory.createJourneyPlan(
            UserInfo.getUserId(), 'December', '2030');
        insert jp;

        Journey_Plan_Day__c jpd = new Journey_Plan_Day__c(
            Journey_Plan__c = jp.Id,
            Beat__c = beat.Id,
            Day_of_Week__c = 'Monday',
            Plan_Date__c = Date.newInstance(2030, 12, 1),
            Planned_Outlets__c = 5
        );
        insert jpd;

        Test.startTest();
        beat.Is_Active__c = false;
        update beat;
        Test.stopTest();

        List<Journey_Plan_Day__c> remaining = [
            SELECT Id FROM Journey_Plan_Day__c WHERE Id = :jpd.Id
        ];
        System.assertEquals(0, remaining.size(),
            'Future Journey_Plan_Day should be deleted on deactivation');
    }

    @isTest
    static void testDeactivation_NoFuturePlans() {
        Beat__c beat = [SELECT Id, Is_Active__c FROM Beat__c
            WHERE Beat_Code__c = 'BEAT-EXIST01' LIMIT 1];

        Test.startTest();
        beat.Is_Active__c = false;
        update beat;
        Test.stopTest();

        Beat__c after = [SELECT Is_Active__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals(false, after.Is_Active__c);
    }

    @isTest
    static void testUpdateNoTransition() {
        // Update without flipping Is_Active__c from true to false - exercises
        // the "no deactivation" branch.
        Beat__c beat = [SELECT Id FROM Beat__c
            WHERE Beat_Code__c = 'BEAT-EXIST01' LIMIT 1];
        Test.startTest();
        beat.Day_of_Week__c = 'Friday;Saturday';
        beat.Frequency__c = 'Monthly';
        update beat;
        Test.stopTest();

        Beat__c updated = [SELECT Beat_Day__c, Beat_Frequency__c
            FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals('Friday;Saturday', updated.Beat_Day__c);
        System.assertEquals('Monthly', updated.Beat_Frequency__c);
    }

    @isTest
    static void testInsertWithoutBeatCode() {
        // Blank Beat_Code__c -> uniqueness check returns early (newCodes empty).
        Territory_Master__c territory = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Test.startTest();
        Beat__c beat = new Beat__c(
            Name = 'No Code Beat',
            Territory__c = territory.Id
        );
        try {
            insert beat;
        } catch (DmlException e) {
            // Beat_Code__c may be required - either branch is fine, just
            // exercise the early return path.
        }
        Test.stopTest();
    }
}