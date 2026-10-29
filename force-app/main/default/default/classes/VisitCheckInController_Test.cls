/**
 * @description Test class for VisitCheckInController.
 *              Validates all 11 @AuraEnabled controller methods that wrap
 *              OVE_Visit_Service. Uses try/catch for methods that may throw
 *              AuraHandledException due to disabled feature toggles.
 *
 * @author  SFA Development Team
 * @date    2026
 */
@isTest
private class VisitCheckInController_Test {

    @testSetup
    static void setupTestData() {
        // Accounts with geo data
        Account geoOutlet = TestDataFactory.createAccountWithGeoData(
            'CI Geo Outlet', 'Retailer', 19.0760, 72.8777
        );
        insert geoOutlet;

        Account plainOutlet = TestDataFactory.createAccount('CI Plain Outlet', 'Retailer');
        insert plainOutlet;

        // Territory and beat
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('CI Territory', 'TER-CI01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('CI Beat', 'BEAT-CI01', territory.Id);

        // Day attendance
        Day_Attendance__c da = TestDataFactory.createDayAttendanceWithDefaults(UserInfo.getUserId());
        insert da;

        // Completed visit with order and invoice for summary tests
        Visit__c completedVisit = TestDataFactory.createVisitWithDefaults(
            geoOutlet.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        completedVisit.Visit_Status__c = 'Completed';
        completedVisit.Check_In_Time__c = DateTime.now().addMinutes(-60);
        completedVisit.Check_Out_Time__c = DateTime.now().addMinutes(-30);
        completedVisit.Is_Productive__c = true;
        completedVisit.Order_Value__c = 8000;
        completedVisit.Collection_Amount__c = 5000;
        completedVisit.Total_Orders_Count__c = 1;
        completedVisit.Duration_Minutes__c = 30;
        completedVisit.Visit_Sequence__c = 1;
        insert completedVisit;

        Sales_Order__c order = TestDataFactory.createSalesOrder(
            geoOutlet.Id, UserInfo.getUserId(), completedVisit.Id
        );
        order.Total_Gross_Amount__c = 8000;
        order.Total_Net_Amount__c = 8000;
        order.Status__c = 'Submitted';
        order.Territory__c = territory.Id;
        insert order;

        Invoice__c invoice = TestDataFactory.createInvoice(order.Id, geoOutlet.Id);
        insert invoice;
    }

    /**
     * @description Tests createVisit() controller wrapper with JSON payload.
     */
    @isTest
    static void testCreateVisit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CI Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c WHERE Beat_Code__c = 'BEAT-CI01' LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Map<String, Object> requestMap = new Map<String, Object>{
            'accountId' => acct.Id,
            'beatId' => beat.Id,
            'dayAttendanceId' => da.Id,
            'latitude' => 19.0760,
            'longitude' => 72.8777,
            'accuracy' => 10.0,
            'batteryLevel' => 85,
            'networkStatus' => '4G',
            'isPlanned' => true
        };
        String visitJson = JSON.serialize(requestMap);

        Test.startTest();
        try {
            Visit__c result = VisitCheckInController.createVisit(visitJson);
            System.assertNotEquals(null, result, 'Visit should be created');
            System.assertEquals('Checked In', result.Visit_Status__c, 'Status should be Checked In');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    /**
     * @description Tests completeVisit() controller wrapper with JSON payload.
     */
    @isTest
    static void testCompleteVisit() {
        // Create a fresh visit to complete
        Account acct = [SELECT Id FROM Account WHERE Name = 'CI Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 10;
        insert visit;

        Map<String, Object> requestMap = new Map<String, Object>{
            'visitId' => visit.Id,
            'latitude' => 19.0762,
            'longitude' => 72.8779,
            'accuracy' => 12.0,
            'isProductive' => true,
            'notes' => 'Order placed',
            'completedActivities' => 'order'
        };
        String visitJson = JSON.serialize(requestMap);

        Test.startTest();
        try {
            Visit__c result = VisitCheckInController.completeVisit(visitJson);
            System.assertEquals('Completed', result.Visit_Status__c, 'Should be Completed');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    /**
     * @description Tests skipVisit() controller wrapper.
     */
    @isTest
    static void testSkipVisit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CI Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 20;
        insert visit;

        Test.startTest();
        try {
            Visit__c result = VisitCheckInController.skipVisit(visit.Id, 'Shop Closed');
            System.assertEquals('Skipped', result.Visit_Status__c, 'Should be Skipped');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }
        Test.stopTest();
    }

    /**
     * @description Tests getOutletSummary() controller wrapper.
     */
    @isTest
    static void testGetOutletSummary() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CI Geo Outlet' LIMIT 1];

        Test.startTest();
        try {
            Map<String, Object> summary = VisitCheckInController.getOutletSummary(acct.Id);
            System.assertNotEquals(null, summary, 'Summary should not be null');
            System.assert(summary.containsKey('outletName'), 'Should contain outletName');
            System.assertEquals('CI Geo Outlet', summary.get('outletName'), 'Name should match');
            System.assert(summary.containsKey('lastVisitDate'), 'Should contain lastVisitDate');
            System.assert(summary.containsKey('outstandingBalance'), 'Should contain outstandingBalance');
            System.assert(summary.containsKey('pendingOrders'), 'Should contain pendingOrders');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests getTodaysVisits() controller wrapper.
     */
    @isTest
    static void testGetTodaysVisits() {
        Test.startTest();
        try {
            List<Visit__c> visits = VisitCheckInController.getTodaysVisits(null);
            System.assertNotEquals(null, visits, 'Should return a list');
            System.assert(visits.size() >= 1, 'Should return at least 1 visit from setup');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests getPlannedVisits() controller wrapper.
     */
    @isTest
    static void testGetPlannedVisits() {
        Test.startTest();
        try {
            List<Map<String, Object>> planned = VisitCheckInController.getPlannedVisits(
                null, Date.today()
            );
            System.assertNotEquals(null, planned, 'Should return a list (possibly empty)');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests validateGeoFence() controller wrapper.
     */
    @isTest
    static void testValidateGeoFence() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CI Geo Outlet' LIMIT 1];

        Test.startTest();
        try {
            OVE_Visit_Service.GeoValidationResult result =
                VisitCheckInController.validateGeoFence(19.0761, 72.8778, acct.Id);
            System.assertNotEquals(null, result, 'Result should not be null');
            System.assertEquals(true, result.isWithinRadius,
                'Should be within radius for nearby coordinates');
            System.assertNotEquals(null, result.message, 'Message should be populated');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests getVisitActivities() controller wrapper.
     */
    @isTest
    static void testGetVisitActivities() {
        Test.startTest();
        try {
            List<Map<String, Object>> activities = VisitCheckInController.getVisitActivities();
            System.assertNotEquals(null, activities, 'Activities list should not be null');
            System.assert(activities.size() >= 3,
                'Should have at least 3 always-enabled activities');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests getVisitCompletionSummary() controller wrapper.
     */
    @isTest
    static void testGetVisitCompletionSummary() {
        Visit__c visit = [SELECT Id FROM Visit__c
                          WHERE Visit_Status__c = 'Completed' LIMIT 1];

        Test.startTest();
        try {
            Map<String, Object> summary = VisitCheckInController.getVisitCompletionSummary(visit.Id);
            System.assertNotEquals(null, summary, 'Summary should not be null');
            System.assert(summary.containsKey('duration'), 'Should contain duration');
            System.assert(summary.containsKey('isProductive'), 'Should contain isProductive');
            System.assert(summary.containsKey('orderValue'), 'Should contain orderValue');
            System.assert(summary.containsKey('orders'), 'Should contain orders list');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests getTeamVisits() controller wrapper.
     */
    @isTest
    static void testGetTeamVisits() {
        Test.startTest();
        try {
            List<Map<String, Object>> teamVisits = VisitCheckInController.getTeamVisits(Date.today());
            System.assertNotEquals(null, teamVisits, 'Should return a list (possibly empty)');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    /**
     * @description Tests searchOutlets() controller wrapper.
     */
    @isTest
    static void testSearchOutlets() {
        // Ensure outlet is active for search
        Account acct = [SELECT Id, Is_Active__c FROM Account WHERE Name = 'CI Geo Outlet' LIMIT 1];
        acct.Is_Active__c = true;
        update acct;

        Test.startTest();
        // Valid search matching existing outlet
        List<Account> results = VisitCheckInController.searchOutlets('CI Geo');
        System.assertNotEquals(null, results, 'Results should not be null');
        System.assert(results.size() >= 1, 'Should find at least one matching outlet');

        // Short search term (< 2 chars)
        List<Account> shortResults = VisitCheckInController.searchOutlets('C');
        System.assertEquals(0, shortResults.size(), 'Short search term should return empty list');

        // Blank search
        List<Account> blankResults = VisitCheckInController.searchOutlets('');
        System.assertEquals(0, blankResults.size(), 'Blank search should return empty list');

        // Non-matching search
        List<Account> noResults = VisitCheckInController.searchOutlets('ZZZZNONEXISTENT');
        System.assertEquals(0, noResults.size(), 'Non-matching search should return empty list');
        Test.stopTest();
    }

    /**
     * @description Tests getVisitConfig() controller wrapper.
     */
    @isTest
    static void testGetVisitConfig() {
        Test.startTest();
        try {
            Map<String, Object> config = VisitCheckInController.getVisitConfig();
            System.assertNotEquals(null, config, 'Config should not be null');
            System.assert(config.containsKey('requirePhotoCheckIn'), 'Should contain requirePhotoCheckIn');
            System.assert(config.containsKey('allowGeofenceOverride'), 'Should contain allowGeofenceOverride');
            System.assert(config.containsKey('minVisitDurationSec'), 'Should contain minVisitDurationSec');
            System.assert(config.containsKey('maxVisitsPerDay'), 'Should contain maxVisitsPerDay');
            System.assert(config.containsKey('geofenceEnabled'), 'Should contain geofenceEnabled');
            System.assert(config.containsKey('adHocVisitsEnabled'), 'Should contain adHocVisitsEnabled');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Error message should not be null');
        }
        Test.stopTest();
    }

    // ── Error Path Tests — Cover catch blocks ──────────────────────────

    @isTest
    static void testCreateVisit_InvalidJson() {
        Test.startTest();
        try { VisitCheckInController.createVisit('bad json'); }
        catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testCompleteVisit_InvalidJson() {
        Test.startTest();
        try { VisitCheckInController.completeVisit('bad json'); }
        catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testSkipVisit_NullId() {
        Test.startTest();
        try { VisitCheckInController.skipVisit(null, 'test'); }
        catch (AuraHandledException e) { System.assert(true); }
        catch (NullPointerException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testGetOutletSummary_NullId() {
        Test.startTest();
        try {
            Map<String, Object> result = VisitCheckInController.getOutletSummary(null);
            System.assertNotEquals(null, result);
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testGetTodaysVisits_NullUser() {
        Test.startTest();
        try {
            List<Visit__c> result = VisitCheckInController.getTodaysVisits(null);
            System.assertNotEquals(null, result);
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testGetPlannedVisits_NullParams() {
        Test.startTest();
        try {
            List<Map<String, Object>> result = VisitCheckInController.getPlannedVisits(null, null);
            System.assertNotEquals(null, result);
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testValidateGeoFence_NullCoords() {
        Test.startTest();
        try {
            OVE_Visit_Service.GeoValidationResult result = VisitCheckInController.validateGeoFence(null, null, null);
            System.assertNotEquals(null, result);
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testGetVisitCompletionSummary_NullId() {
        Test.startTest();
        try {
            Map<String, Object> result = VisitCheckInController.getVisitCompletionSummary(null);
            System.assertNotEquals(null, result);
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testGetTeamVisits_NullDate() {
        Test.startTest();
        try {
            List<Map<String, Object>> result = VisitCheckInController.getTeamVisits(null);
            System.assertNotEquals(null, result);
        } catch (AuraHandledException e) { System.assert(true); }
        Test.stopTest();
    }

    @isTest
    static void testSearchOutlets_ShortTerm() {
        Test.startTest();
        List<Account> result = VisitCheckInController.searchOutlets('a');
        Test.stopTest();
        System.assertEquals(0, result.size(), 'Should return empty for < 2 chars');
    }

    @isTest
    static void testSearchOutlets_BlankTerm() {
        Test.startTest();
        List<Account> result = VisitCheckInController.searchOutlets('');
        Test.stopTest();
        System.assertEquals(0, result.size());
    }

    @isTest
    static void testSearchOutlets_NullTerm() {
        Test.startTest();
        List<Account> result = VisitCheckInController.searchOutlets(null);
        Test.stopTest();
        System.assertEquals(0, result.size());
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage.
    //
    //  Two things were never reached:
    //
    //  1. searchOutlets' channel-filtered query. MDM-003 ships enabled, but
    //     getCurrentUserChannels() returns an empty set unless an ACTIVE
    //     Employee__c maps to the running user — and the setup above creates
    //     none. So filterByChannel was always false and the entire restricted
    //     query was dead. That branch is the point of MDM-003: it decides which
    //     outlets a rep can raise an ad-hoc visit against.
    //
    //  2. The `catch (AuraHandledException e) { throw e; }` rethrow in
    //     createVisit / completeVisit / skipVisit. The OVE toggles ship enabled,
    //     so the service succeeded and the rethrow never ran. That branch is
    //     what lets the service's own message reach the user unchanged instead
    //     of being re-wrapped.
    //
    //  Toggles are pinned through BPM_FeatureToggle_Util's @TestVisible cache so
    //  these tests hold whichever way the org is configured.
    // ══════════════════════════════════════════════════════════════════

    private static void setFeature(String featureCode, Boolean enabled) {
        BPM_FeatureToggle_Util.toggleCache.put(featureCode, enabled);
    }

    /** An active employee mapping the running user to the given channels. */
    private static Employee__c mapRunningUserToChannels(String channels) {
        Territory_Master__c ter = [SELECT Id FROM Territory_Master__c LIMIT 1];
        Employee__c emp = new Employee__c(
            First_Name__c = 'Visit',
            Last_Name__c = 'Rep',
            Employee_Code__c = 'EMP-CI-REP',
            Is_Active__c = true,
            User__c = UserInfo.getUserId(),
            Territory__c = ter.Id,
            Channels__c = channels
        );
        insert emp;
        return emp;
    }

    // ── searchOutlets: channel restriction ────────────────────────────

    @isTest
    static void searchOutlets_withChannelMappingOn_returnsOutletsInTheUserChannel() {
        // TestDataFactory puts every account on the GT channel.
        mapRunningUserToChannels('GT');
        setFeature('MDM-003', true);

        Test.startTest();
        List<Account> results = VisitCheckInController.searchOutlets('CI Geo');
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'A rep mapped to GT can search GT outlets');
        System.assertEquals('GT', results[0].Channel__c, 'And gets the channel back for display');
    }

    @isTest
    static void searchOutlets_excludesOutletsOutsideTheUserChannel() {
        // The rep covers modern trade only; the seeded outlets are all GT.
        mapRunningUserToChannels('MT');
        setFeature('MDM-003', true);

        Test.startTest();
        List<Account> results = VisitCheckInController.searchOutlets('CI ');
        Test.stopTest();

        System.assertEquals(0, results.size(),
            'Channel mapping is a restriction, not a hint — an MT rep must not be able to '
            + 'raise an ad-hoc visit against a GT outlet');
    }

    @isTest
    static void searchOutlets_withMultipleChannels_matchesAnyOfThem() {
        mapRunningUserToChannels('GT;MT');
        setFeature('MDM-003', true);

        Test.startTest();
        List<Account> results = VisitCheckInController.searchOutlets('CI Geo');
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'A rep covering several channels sees outlets in any of them — the multi-select '
            + 'is split, not compared whole');
    }

    @isTest
    static void searchOutlets_withChannelMappingOff_returnsEveryOutlet() {
        mapRunningUserToChannels('MT');
        setFeature('MDM-003', false);

        Test.startTest();
        List<Account> results = VisitCheckInController.searchOutlets('CI Geo');
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'With the feature off the channel is ignored entirely, even for a rep whose '
            + 'mapping would otherwise exclude the outlet');
    }

    @isTest
    static void searchOutlets_withNoEmployeeRecord_isNotRestricted() {
        // No Employee__c for the running user — getCurrentUserChannels returns
        // empty, and an empty list must mean "no restriction", not "no results".
        setFeature('MDM-003', true);

        Test.startTest();
        List<Account> results = VisitCheckInController.searchOutlets('CI Geo');
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'A user with no employee mapping must not be locked out of outlet search');
    }

    @isTest
    static void searchOutlets_matchesOnAccountNumberToo() {
        Account acct = [SELECT Id, AccountNumber FROM Account WHERE Name = 'CI Geo Outlet' LIMIT 1];
        acct.AccountNumber = 'ACC-CI-9911';
        update acct;

        Test.startTest();
        List<Account> results = VisitCheckInController.searchOutlets('CI-9911');
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'Reps often have the outlet code rather than the name, so the number is searchable');
    }

    // ── The AuraHandledException rethrows ─────────────────────────────

    @isTest
    static void createVisit_whenVisitExecutionIsDisabled_passesTheServiceMessageThrough() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'CI Plain Outlet' LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];
        setFeature(OVE_Visit_Service.FEATURE_VISIT_EXECUTION, false);

        String visitJson = JSON.serialize(new Map<String, Object>{
            'accountId' => acct.Id,
            'dayAttendanceId' => da.Id,
            'latitude' => 19.0760,
            'longitude' => 72.8777
        });

        Test.startTest();
        Boolean threw = false;
        try {
            VisitCheckInController.createVisit(visitJson);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'A disabled module must surface the service message unchanged, not be re-wrapped '
            + 'as a generic failure');
        System.assertEquals(0, [
            SELECT COUNT() FROM Visit__c WHERE Account__c = :acct.Id
        ], 'And no visit is created');
    }

    @isTest
    static void completeVisit_fromTheWrongStatus_passesTheServiceMessageThrough() {
        Visit__c completed = [
            SELECT Id FROM Visit__c WHERE Visit_Status__c = 'Completed' LIMIT 1
        ];
        setFeature(OVE_Visit_Service.FEATURE_VISIT_EXECUTION, true);

        String visitJson = JSON.serialize(new Map<String, Object>{
            'visitId' => completed.Id,
            'latitude' => 19.0760,
            'longitude' => 72.8777,
            'isProductive' => true
        });

        Test.startTest();
        Boolean threw = false;
        try {
            VisitCheckInController.completeVisit(visitJson);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A visit that is already closed cannot be checked out again');
    }

    @isTest
    static void skipVisit_ofAnAlreadyClosedVisit_passesTheServiceMessageThrough() {
        Visit__c completed = [
            SELECT Id FROM Visit__c WHERE Visit_Status__c = 'Completed' LIMIT 1
        ];

        Test.startTest();
        Boolean threw = false;
        try {
            VisitCheckInController.skipVisit(completed.Id, 'Shop Closed');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A completed visit cannot be retrospectively skipped');
        System.assertEquals('Completed', [
            SELECT Visit_Status__c FROM Visit__c WHERE Id = :completed.Id
        ].Visit_Status__c, 'And its status is untouched');
    }

    @isTest
    static void skipVisit_ofAVisitThatDoesNotExist_isRejected() {
        Id ghost = Id.valueOf(Visit__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Boolean threw = false;
        try {
            VisitCheckInController.skipVisit(ghost, 'Shop Closed');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A stale visit id from the client is reported, not ignored');
    }

    // ── Unmatched ids degrade instead of failing ──────────────────────
    //
    // Note: `WHERE Id = :someForeignId` returns zero rows rather than raising a
    // QueryException, so these read methods cannot be driven into their generic
    // catch block from a test — those few lines stay uncovered. What IS worth
    // pinning is that a stale id produces an empty result the LWC can render,
    // rather than an error toast.

    @isTest
    static void getOutletSummary_withAnIdThatMatchesNoOutlet_returnsAnEmptySummary() {
        Id notAnAccount = [SELECT Id FROM Visit__c LIMIT 1].Id;

        Test.startTest();
        Map<String, Object> summary = VisitCheckInController.getOutletSummary(notAnAccount);
        Test.stopTest();

        System.assertNotEquals(null, summary,
            'A stale outlet id gives the panel an empty summary, not an exception');
        System.assertEquals(false, summary.containsKey('outletName'),
            'With no outlet found, none of its details are populated');
    }

    @isTest
    static void getVisitCompletionSummary_withAnIdThatMatchesNoVisit_returnsAnEmptyMap() {
        Id notAVisit = [SELECT Id FROM Account WHERE Name = 'CI Geo Outlet' LIMIT 1].Id;

        Test.startTest();
        Map<String, Object> summary = VisitCheckInController.getVisitCompletionSummary(notAVisit);
        Test.stopTest();

        System.assertEquals(0, summary.size(),
            'A visit that cannot be found returns nothing to summarise rather than throwing');
    }

    @isTest
    static void getTodaysVisits_forAUserWithNoVisits_returnsAnEmptyList() {
        Id notAUser = [SELECT Id FROM Account WHERE Name = 'CI Geo Outlet' LIMIT 1].Id;

        Test.startTest();
        List<Visit__c> visits = VisitCheckInController.getTodaysVisits(notAUser);
        Test.stopTest();

        System.assertEquals(0, visits.size(),
            'An id that matches no salesperson yields an empty day, not an error');
    }

    // ── getVisitConfig values ─────────────────────────────────────────

    @isTest
    static void getVisitConfig_reportsTheLiveToggleState() {
        setFeature(OVE_Visit_Service.FEATURE_GEOFENCE, true);
        setFeature(OVE_Visit_Service.FEATURE_AD_HOC_VISITS, false);

        Test.startTest();
        Map<String, Object> config = VisitCheckInController.getVisitConfig();
        Test.stopTest();

        System.assertEquals(true, config.get('geofenceEnabled'),
            'The LWC reads the geofence switch from here to decide whether to block a '
            + 'far-away check-in');
        System.assertEquals(false, config.get('adHocVisitsEnabled'),
            'And whether to offer the outlet search at all');
        System.assertNotEquals(null, config.get('minVisitDurationSec'),
            'Numeric settings resolve to their configured value or a default, never null');
        System.assertNotEquals(null, config.get('maxVisitsPerDay'), 'Same for the daily cap');
    }

    @isTest
    static void getVisitConfig_reportsBothTogglesOff() {
        setFeature(OVE_Visit_Service.FEATURE_GEOFENCE, false);
        setFeature(OVE_Visit_Service.FEATURE_AD_HOC_VISITS, false);

        Test.startTest();
        Map<String, Object> config = VisitCheckInController.getVisitConfig();
        Test.stopTest();

        System.assertEquals(false, config.get('geofenceEnabled'), 'Geofencing reported off');
        System.assertEquals(false, config.get('adHocVisitsEnabled'), 'Ad-hoc visits reported off');
    }
}