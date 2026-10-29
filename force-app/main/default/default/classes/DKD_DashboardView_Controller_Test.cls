/**
 * @description Tests for DKD_DashboardView_Controller.
 */
@IsTest
private class DKD_DashboardView_Controller_Test {

    private static final String SAMPLE_CONFIG = '{"userScope":"self","datePreset":"mtd","selectedMetricKeys":["revenue_total","order_count"]}';

    @IsTest
    static void testCreateView() {
        Test.startTest();
        Dashboard_View__c created = DKD_DashboardView_Controller.createView(
            'My Sales View',
            'Default sales dashboard',
            SAMPLE_CONFIG,
            false,
            'utility:money'
        );
        Test.stopTest();

        System.assertNotEquals(null, created.Id);
        System.assertEquals('My Sales View', created.Name);
        System.assertEquals(UserInfo.getUserId(), created.Owner_User__c);
        System.assertEquals(false, created.Is_Shared__c);
    }

    @IsTest
    static void testCreateView_MissingName() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_DashboardView_Controller.createView('', 'desc', SAMPLE_CONFIG, false, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Should throw when name is blank');
    }

    @IsTest
    static void testCreateView_MissingConfig() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_DashboardView_Controller.createView('Name', 'desc', '', false, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Should throw when config is blank');
    }

    @IsTest
    static void testUpdateView() {
        Dashboard_View__c v = DKD_DashboardView_Controller.createView(
            'Initial', 'Initial desc', SAMPLE_CONFIG, false, null
        );

        Test.startTest();
        Dashboard_View__c updated = DKD_DashboardView_Controller.updateView(
            v.Id, 'Updated', 'New desc', '{"updated":true}', true, 'utility:chart'
        );
        Test.stopTest();

        System.assertEquals('Updated', updated.Name);
        System.assertEquals('New desc', updated.Description__c);
        System.assertEquals(true, updated.Is_Shared__c);
        System.assertEquals('utility:chart', updated.Icon__c);
    }

    @IsTest
    static void testDeleteView() {
        Dashboard_View__c v = DKD_DashboardView_Controller.createView(
            'Delete Me', null, SAMPLE_CONFIG, false, null
        );
        Id vid = v.Id;

        Test.startTest();
        DKD_DashboardView_Controller.deleteView(vid);
        Test.stopTest();

        List<Dashboard_View__c> remaining = [SELECT Id FROM Dashboard_View__c WHERE Id = :vid];
        System.assertEquals(0, remaining.size());
    }

    @IsTest
    static void testGetMyViews_OwnOnly() {
        DKD_DashboardView_Controller.createView('View 1', null, SAMPLE_CONFIG, false, null);
        DKD_DashboardView_Controller.createView('View 2', null, SAMPLE_CONFIG, true, null);

        Test.startTest();
        List<Map<String, Object>> views = DKD_DashboardView_Controller.getMyViews();
        Test.stopTest();

        System.assertEquals(2, views.size());
        for (Map<String, Object> v : views) {
            System.assertEquals(true, (Boolean) v.get('isOwn'));
        }
    }

    @IsTest
    static void testSetDefaultView() {
        Dashboard_View__c a = DKD_DashboardView_Controller.createView('A', null, SAMPLE_CONFIG, false, null);
        Dashboard_View__c b = DKD_DashboardView_Controller.createView('B', null, SAMPLE_CONFIG, false, null);

        Test.startTest();
        DKD_DashboardView_Controller.setDefaultView(a.Id);
        Dashboard_View__c defaultOne = DKD_DashboardView_Controller.getDefaultView();

        DKD_DashboardView_Controller.setDefaultView(b.Id);
        Dashboard_View__c defaultTwo = DKD_DashboardView_Controller.getDefaultView();
        Test.stopTest();

        System.assertEquals(a.Id, defaultOne.Id, 'First call sets A as default');
        System.assertEquals(b.Id, defaultTwo.Id, 'Second call replaces default with B');

        // Verify A is no longer default
        Dashboard_View__c aReloaded = [SELECT Id, Is_Default__c FROM Dashboard_View__c WHERE Id = :a.Id];
        System.assertEquals(false, aReloaded.Is_Default__c, 'A should be unset');
    }

    @IsTest
    static void testClearDefaultView() {
        Dashboard_View__c v = DKD_DashboardView_Controller.createView('Clear', null, SAMPLE_CONFIG, false, null);
        DKD_DashboardView_Controller.setDefaultView(v.Id);

        Test.startTest();
        DKD_DashboardView_Controller.clearDefaultView();
        Dashboard_View__c defaultView = DKD_DashboardView_Controller.getDefaultView();
        Test.stopTest();

        System.assertEquals(null, defaultView);
    }

    @IsTest
    static void testGetDefaultView_None() {
        DKD_DashboardView_Controller.createView('Not Default', null, SAMPLE_CONFIG, false, null);
        Test.startTest();
        Dashboard_View__c defaultView = DKD_DashboardView_Controller.getDefaultView();
        Test.stopTest();
        System.assertEquals(null, defaultView);
    }

    @IsTest
    static void testDuplicateView() {
        Dashboard_View__c src = DKD_DashboardView_Controller.createView(
            'Original', 'Source desc', SAMPLE_CONFIG, false, 'utility:chart'
        );

        Test.startTest();
        Dashboard_View__c copy = DKD_DashboardView_Controller.duplicateView(src.Id, 'My Copy');
        Test.stopTest();

        System.assertEquals('My Copy', copy.Name);
        System.assertEquals(src.Description__c, copy.Description__c);
        System.assertEquals(src.Configuration_JSON__c, copy.Configuration_JSON__c);
        System.assertEquals(false, copy.Is_Default__c, 'Copy should not inherit default flag');
    }

    @IsTest
    static void testDuplicateView_AutoName() {
        Dashboard_View__c src = DKD_DashboardView_Controller.createView(
            'Source', null, SAMPLE_CONFIG, false, null
        );

        Test.startTest();
        Dashboard_View__c copy = DKD_DashboardView_Controller.duplicateView(src.Id, null);
        Test.stopTest();

        System.assertEquals('Source (Copy)', copy.Name);
    }

    @IsTest
    static void testDuplicateView_NotFound() {
        Boolean thrown = false;
        Test.startTest();
        try {
            // Valid Id format but no matching record
            DKD_DashboardView_Controller.duplicateView('a00000000000000AAA', 'x');
        } catch (AuraHandledException e) {
            thrown = true;
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown);
    }

    @IsTest
    static void testCannotUpdateOthersView() {
        // Create a view owned by a different user
        User otherUser = [
            SELECT Id FROM User
            WHERE IsActive = true AND Id != :UserInfo.getUserId()
            LIMIT 1
        ];
        Dashboard_View__c foreign = new Dashboard_View__c(
            Name = 'Not Mine',
            Owner_User__c = otherUser.Id,
            Configuration_JSON__c = SAMPLE_CONFIG,
            Is_Shared__c = true
        );
        insert foreign;

        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_DashboardView_Controller.updateView(
                foreign.Id, 'Hacked', null, SAMPLE_CONFIG, false, null
            );
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Should throw when trying to modify another user\'s view');
    }

    @IsTest
    static void testDeleteView_NullId() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DKD_DashboardView_Controller.deleteView(null);
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown);
    }
}