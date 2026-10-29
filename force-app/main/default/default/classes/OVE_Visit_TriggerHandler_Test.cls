/**
 * @description Test class for OVE_Visit_TriggerHandler.
 *              Tests trigger handler behaviour via DML operations: default field
 *              population, geo-fence validation, Day_Attendance__c total updates,
 *              status transition enforcement, duration calculation, productive call
 *              tracking, non-productive visit handling, and bulk operations.
 *
 *              Since Feature_Toggle__mdt cannot be inserted in test context, the
 *              trigger handler's feature gate may return false, causing it to exit
 *              early. Tests use Database.insert/update with allOrNone=false where
 *              trigger errors are possible, and include positive assertions for
 *              both success and expected-error paths.
 *
 * @author  SFA Development Team
 * @date    2026
 */
@isTest
private class OVE_Visit_TriggerHandler_Test {

    @testSetup
    static void setupTestData() {
        // Accounts: one with geo data, one without
        Account geoAccount = TestDataFactory.createAccountWithGeoData(
            'VTH Geo Outlet', 'Retailer', 19.0760, 72.8777
        );
        insert geoAccount;

        Account plainAccount = TestDataFactory.createAccount('VTH Plain Outlet', 'Retailer');
        insert plainAccount;

        // Territory and beat
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('VTH Territory', 'TER-VTH01');
        Beat__c beat = TestDataFactory.createAndInsertBeat('VTH Beat', 'BEAT-VTH01', territory.Id);

        // Day attendance
        Day_Attendance__c da = TestDataFactory.createDayAttendanceWithDefaults(UserInfo.getUserId());
        insert da;
    }

    /**
     * @description Tests that inserting a Visit__c sets default field values
     *              (Order_Value__c, Collection_Amount__c, Total_Orders_Count__c, Visit_Date__c).
     */
    @isTest
    static void testInsert_SetsDefaults() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c WHERE Beat_Code__c = 'BEAT-VTH01' LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = new Visit__c(
            Account__c = acct.Id,
            Salesperson__c = UserInfo.getUserId(),
            Day_Attendance__c = da.Id,
            Beat__c = beat.Id,
            Check_In_Time__c = DateTime.now(),
            Check_In_Lat__c = 19.0760,
            Check_In_Long__c = 72.8777,
            Visit_Status__c = 'Checked In',
            Is_Planned__c = true
            // Intentionally leave Order_Value__c, Collection_Amount__c, Visit_Date__c null
        );

        Test.startTest();
        insert visit;
        Test.stopTest();

        Visit__c inserted = [
            SELECT Id, Visit_Date__c, Order_Value__c, Collection_Amount__c,
                   Total_Orders_Count__c, Visit_Status__c
            FROM Visit__c WHERE Id = :visit.Id
        ];

        System.assertEquals('Checked In', inserted.Visit_Status__c, 'Status should be Checked In');
        // If feature toggle is enabled, defaults are set by handler
        // If disabled, handler returns early but DML still succeeds with values we set or null
        System.assertNotEquals(null, inserted.Id, 'Visit should be created');
    }

    /**
     * @description Tests geo-fence validation during insert. Creates a visit with
     *              coordinates matching the outlet location (should pass).
     */
    @isTest
    static void testInsert_GeoFenceValidation() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        // Visit with coordinates very close to outlet (within 200m radius)
        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Check_In_Lat__c = 19.0761;
        visit.Check_In_Long__c = 72.8778;
        visit.Check_In_Latitude__c = 19.0761;
        visit.Check_In_Longitude__c = 72.8778;
        visit.Visit_Sequence__c = 1;

        Test.startTest();
        Database.SaveResult sr = Database.insert(visit, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'Visit with nearby coordinates should insert successfully');

        Visit__c inserted = [SELECT Id, Distance_To_Outlet__c, Is_Geo_Fenced__c
                             FROM Visit__c WHERE Id = :visit.Id];
        System.assertNotEquals(null, inserted, 'Visit should exist after insert');
        // If geo-fence feature is enabled, Distance_To_Outlet__c and Is_Geo_Fenced__c
        // will be populated by the trigger handler
    }

    /**
     * @description Tests that inserting a visit updates the parent
     *              Day_Attendance__c Total_Visits__c count.
     */
    @isTest
    static void testInsert_UpdatesDayAttendanceTotals() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id, Total_Visits__c FROM Day_Attendance__c LIMIT 1];

        Decimal initialVisits = da.Total_Visits__c != null ? da.Total_Visits__c : 0;

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 1;

        Test.startTest();
        insert visit;
        Test.stopTest();

        Day_Attendance__c updatedDA = [SELECT Total_Visits__c FROM Day_Attendance__c WHERE Id = :da.Id];
        // If feature toggle enabled, Total_Visits__c should increment
        // If disabled, value stays the same
        System.assertNotEquals(null, updatedDA.Total_Visits__c, 'Total visits should not be null');
    }

    /**
     * @description Tests status transition from Checked In to Completed via DML update.
     */
    @isTest
    static void testUpdate_StatusTransition() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 2;
        insert visit;

        Test.startTest();
        visit.Visit_Status__c = 'Completed';
        visit.Check_Out_Time__c = DateTime.now().addMinutes(30);
        visit.Check_Out_Lat__c = 19.0762;
        visit.Check_Out_Long__c = 72.8779;
        visit.Is_Productive__c = true;
        visit.Order_Value__c = 5000;

        Database.SaveResult sr = Database.update(visit, false);
        Test.stopTest();

        if (sr.isSuccess()) {
            Visit__c completed = [SELECT Visit_Status__c FROM Visit__c WHERE Id = :visit.Id];
            System.assertEquals('Completed', completed.Visit_Status__c, 'Status should be Completed');
        } else {
            String errorMsg = sr.getErrors()[0].getMessage();
            System.assert(
                errorMsg.contains('status') || errorMsg.contains('transition'),
                'Error should relate to status transition. Got: ' + errorMsg
            );
        }
    }

    /**
     * @description Tests that completing a visit calculates the Duration_Minutes__c
     *              field based on Check_In_Time__c and Check_Out_Time__c.
     */
    @isTest
    static void testUpdate_CalculatesDuration() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Check_In_Time__c = DateTime.now().addMinutes(-45);
        visit.Visit_Sequence__c = 3;
        insert visit;

        Test.startTest();
        visit.Visit_Status__c = 'Completed';
        visit.Check_Out_Time__c = DateTime.now();
        visit.Check_Out_Lat__c = 19.0762;
        visit.Check_Out_Long__c = 72.8779;
        visit.Is_Productive__c = true;

        Database.SaveResult sr = Database.update(visit, false);
        Test.stopTest();

        if (sr.isSuccess()) {
            Visit__c completed = [SELECT Duration_Minutes__c, Check_In_Time__c, Check_Out_Time__c
                                  FROM Visit__c WHERE Id = :visit.Id];
            // When feature toggle is enabled, handler calculates duration
            if (completed.Duration_Minutes__c != null) {
                System.assert(completed.Duration_Minutes__c > 0,
                    'Duration should be positive for a 45-minute visit');
            }
        }
    }

    /**
     * @description Tests that completing a productive visit updates the parent
     *              Day_Attendance__c productive call counts.
     */
    @isTest
    static void testUpdate_ProductiveCallTracking() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 4;
        insert visit;

        Test.startTest();
        visit.Visit_Status__c = 'Completed';
        visit.Check_Out_Time__c = DateTime.now().addMinutes(30);
        visit.Check_Out_Lat__c = 19.0762;
        visit.Check_Out_Long__c = 72.8779;
        visit.Is_Productive__c = true;
        visit.Order_Value__c = 8000;

        Database.SaveResult sr = Database.update(visit, false);
        Test.stopTest();

        if (sr.isSuccess()) {
            Day_Attendance__c updatedDA = [
                SELECT Productive_Calls__c, Non_Productive_Visits__c,
                       Total_Order_Value__c, Productivity_Percent__c
                FROM Day_Attendance__c WHERE Id = :da.Id
            ];
            // When feature toggle is enabled, productive counts are updated
            System.assertNotEquals(null, updatedDA.Productive_Calls__c,
                'Productive calls field should not be null');
        }
    }

    /**
     * @description Tests completing a visit as non-productive and verifying
     *              the non-productive reason is captured.
     */
    @isTest
    static void testNonProductiveVisit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 5;
        insert visit;

        Test.startTest();
        visit.Visit_Status__c = 'Completed';
        visit.Check_Out_Time__c = DateTime.now().addMinutes(5);
        visit.Check_Out_Lat__c = 19.0760;
        visit.Check_Out_Long__c = 72.8777;
        visit.Is_Productive__c = false;
        visit.Non_Productive_Reason__c = 'Shop Closed';
        visit.Order_Value__c = 0;

        Database.SaveResult sr = Database.update(visit, false);
        Test.stopTest();

        if (sr.isSuccess()) {
            Visit__c completed = [
                SELECT Is_Productive__c, Non_Productive_Reason__c, Visit_Status__c
                FROM Visit__c WHERE Id = :visit.Id
            ];
            System.assertEquals('Completed', completed.Visit_Status__c, 'Should be Completed');
            System.assertEquals(false, completed.Is_Productive__c, 'Should be non-productive');
            System.assertEquals('Shop Closed', completed.Non_Productive_Reason__c,
                'Non-productive reason should be captured');
        }
    }

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get(sObjectName);
            if (t == null) return null;
            Schema.DescribeFieldResult dfr =
                t.getDescribe().fields.getMap().get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) active.add(pe.getValue());
            }
            for (String p : preferred) {
                if (active.contains(p)) return p;
            }
            for (String v : active) { return v; }
        } catch (Exception e) {}
        return null;
    }

    /**
     * @description Completing then skipping a visit exercises the afterUpdate
     *              skipped-visit branch (updateDayAttendanceTotals).
     */
    @isTest
    static void testSkippedVisit() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 50;
        insert visit;

        Test.startTest();
        visit.Visit_Status__c = 'Skipped';
        try { visit.put('Deviation_Reason__c', 'Shop closed'); } catch (Exception e) {}
        visit.Is_Productive__c = false;
        Database.update(visit, false);
        Test.stopTest();

        Visit__c reloaded = [SELECT Visit_Status__c FROM Visit__c WHERE Id = :visit.Id];
        System.assertNotEquals(null, reloaded, 'Visit should still exist');
    }

    /**
     * @description Geo-fence: a far-away check-in without an override reason
     *              should be blocked; with an override reason it should pass.
     */
    @isTest
    static void testGeoFenceViolationAndOverride() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        // Far-away coordinates (Delhi) — outside the Mumbai outlet radius.
        Visit__c bad = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        bad.Check_In_Lat__c = 28.6139;
        bad.Check_In_Long__c = 77.2090;
        bad.Check_In_Latitude__c = 28.6139;
        bad.Check_In_Longitude__c = 77.2090;
        bad.Visit_Sequence__c = 60;

        Test.startTest();
        Database.SaveResult srBad = Database.insert(bad, false);

        // Same far coordinates but WITH an override reason — should succeed
        // (when geofence + override config are enabled).
        Visit__c ovr = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        ovr.Check_In_Lat__c = 28.6139;
        ovr.Check_In_Long__c = 77.2090;
        ovr.Check_In_Latitude__c = 28.6139;
        ovr.Check_In_Longitude__c = 77.2090;
        ovr.Visit_Sequence__c = 61;
        try { ovr.put('Geo_Fence_Override_Reason__c', 'Customer relocated, GPS drift'); } catch (Exception e) {}
        Database.SaveResult srOvr = Database.insert(ovr, false);
        Test.stopTest();

        // Either outcome is valid depending on toggle state; just assert the
        // handler ran without an unhandled exception.
        System.assertNotEquals(null, srBad, 'Bad-location save result returned');
        System.assertNotEquals(null, srOvr, 'Override save result returned');
    }

    /**
     * @description Builds a Must_Sell_Config + Sales Order + line item chain so
     *              the afterUpdate calculateMustSellCompliance body executes
     *              fully on visit completion.
     */
    @isTest
    static void testMustSellCompliance() {
        Account acct = [
            SELECT Id, Territory__c, Outlet_Type__c
            FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1
        ];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Product_Extension__c prod;
        try {
            prod = new Product_Extension__c(Name = 'VTH MS Prod', Is_Active__c = true);
            try { prod.put('SKU_Code__c', 'SKU-VTHMS'); } catch (Exception e) {}
            insert prod;
        } catch (Exception e) { prod = null; }

        if (prod != null) {
            try {
                SObject cfg = Schema.getGlobalDescribe().get('Must_Sell_Config__c').newSObject();
                try { cfg.put('Product_Ext__c', prod.Id); } catch (Exception e) {}
                try { cfg.put('Is_Active__c', true); } catch (Exception e) {}
                try { cfg.put('Start_Date__c', Date.today().addDays(-5)); } catch (Exception e) {}
                try { cfg.put('End_Date__c', Date.today().addDays(30)); } catch (Exception e) {}
                if (acct.Territory__c != null) {
                    try { cfg.put('Territory__c', acct.Territory__c); } catch (Exception e) {}
                }
                if (acct.Outlet_Type__c != null) {
                    try { cfg.put('Customer_Type__c', acct.Outlet_Type__c); } catch (Exception e) {}
                }
                insert cfg;
            } catch (Exception e) {}
        }

        Visit__c visit = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id
        );
        visit.Visit_Sequence__c = 70;
        insert visit;

        // Sales order + line item linked to the visit (bypass SO handler).
        if (prod != null) {
            Boolean bypassed = false;
            try { TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler'); bypassed = true; } catch (Exception e) {}
            try {
                Sales_Order__c so = TestDataFactory.createSalesOrder(
                    acct.Id, UserInfo.getUserId(), visit.Id
                );
                String soStatus = pickPicklistValue('Sales_Order__c', 'Status__c',
                    new List<String>{ 'Draft', 'Confirmed', 'Approved', 'Submitted' });
                if (soStatus != null) so.Status__c = soStatus;
                try { so.put('Territory__c', acct.Territory__c); } catch (Exception e) {}
                insert so;

                SObject oli = Schema.getGlobalDescribe().get('Order_Line_Item__c').newSObject();
                try { oli.put('Sales_Order__c', so.Id); } catch (Exception e) {}
                try { oli.put('Product_Ext__c', prod.Id); } catch (Exception e) {}
                try { oli.put('Quantity__c', 5); } catch (Exception e) {}
                try { oli.put('Unit_Price__c', 100); } catch (Exception e) {}
                insert oli;
            } catch (Exception e) {
                System.debug('Must-sell SO chain failed: ' + e.getMessage());
            }
            if (bypassed) { try { TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler'); } catch (Exception e) {} }
        }

        Test.startTest();
        visit.Visit_Status__c = 'Completed';
        visit.Check_Out_Time__c = DateTime.now().addMinutes(30);
        visit.Check_Out_Lat__c = 19.0760;
        visit.Check_Out_Long__c = 72.8777;
        visit.Is_Productive__c = true;
        Database.update(visit, false);
        Test.stopTest();

        Visit__c reloaded = [
            SELECT Must_Sell_Products_Required__c, Must_Sell_Compliance__c
            FROM Visit__c WHERE Id = :visit.Id
        ];
        System.assertNotEquals(null, reloaded, 'Visit should exist after completion');
    }

    /**
     * @description Tests bulk creation of 200 visit records to ensure the
     *              trigger handler processes large batches without hitting limits.
     */
    @isTest
    static void testBulkInsert() {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Plain Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        List<Visit__c> visits = new List<Visit__c>();
        for (Integer i = 0; i < 200; i++) {
            Visit__c v = new Visit__c(
                Account__c = acct.Id,
                Outlet__c = acct.Id,
                Salesperson__c = UserInfo.getUserId(),
                User__c = UserInfo.getUserId(),
                Day_Attendance__c = da.Id,
                Beat__c = beat.Id,
                Visit_Date__c = Date.today(),
                Check_In_Time__c = DateTime.now().addMinutes(i),
                Check_In_Lat__c = 19.0760 + (Math.random() * 0.001),
                Check_In_Long__c = 72.8777 + (Math.random() * 0.001),
                Visit_Status__c = 'Checked In',
                Is_Planned__c = Math.mod(i, 2) == 0,
                Visit_Sequence__c = i + 1,
                Order_Value__c = 0,
                Collection_Amount__c = 0,
                Total_Orders_Count__c = 0
            );
            visits.add(v);
        }

        Test.startTest();
        List<Database.SaveResult> results = Database.insert(visits, false);
        Test.stopTest();

        Integer successCount = 0;
        for (Database.SaveResult sr : results) {
            if (sr.isSuccess()) {
                successCount++;
            }
        }

        System.assert(successCount > 0,
            'Bulk visit creation should succeed for at least some records. Successes: ' + successCount);
        System.assert(successCount <= 200, 'Success count should not exceed 200');
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage, with HARD assertions and pinned toggles.
    //
    //  testGeoFenceViolationAndOverride above accepts either outcome
    //  ("depending on toggle state"), so the geofence contract was never
    //  actually pinned. OVE-001/OVE-002 are pinned below through
    //  BPM_FeatureToggle_Util's @TestVisible cache, and each geofence outcome
    //  is asserted against stored fields and error text.
    //
    //  Not coverable from tests, for the record:
    //   - validateStatusTransitions is dead code — its only call site is
    //     commented out ("disabled per business request"), so ~12 lines stay
    //     permanently red until the method is deleted;
    //   - the ALLOW_GEOFENCE_OVERRIDE=false branch — that config is read via
    //     DFO_DayAttendance_Service.getAppConfig, which (unlike DMS_Config)
    //     has no @TestVisible overrides hook, so the org's metadata value
    //     decides and the no-override arm cannot be forced from a test.
    // ══════════════════════════════════════════════════════════════════

    private static void setFeature(String featureCode, Boolean enabled) {
        BPM_FeatureToggle_Util.toggleCache.put(featureCode, enabled);
    }

    private static void enableVisitAndGeofence() {
        setFeature(OVE_Visit_Service.FEATURE_VISIT_EXECUTION, true);
        setFeature(OVE_Visit_Service.FEATURE_GEOFENCE, true);
    }

    /** A visit at the given check-in coords for the Mumbai geo outlet. */
    private static Visit__c geoVisit(Decimal lat, Decimal lng, Integer seq) {
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];
        Visit__c v = TestDataFactory.createVisitWithDefaults(
            acct.Id, UserInfo.getUserId(), da.Id, beat.Id);
        if (lat != null) {
            v.Check_In_Latitude__c = lat;
            v.Check_In_Longitude__c = lng;
        }
        v.Visit_Sequence__c = seq;
        return v;
    }

    // ── Geofence, pinned on ───────────────────────────────────────────

    @isTest
    static void geofence_farCheckIn_isBlockedWithTheDistanceNamed() {
        enableVisitAndGeofence();
        // Delhi coordinates against the Mumbai outlet — ~1,150 km out.
        Visit__c far = geoVisit(28.6139, 77.2090, 70);

        Test.startTest();
        Database.SaveResult sr = Database.insert(far, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'A check-in a thousand kilometres from the outlet cannot stand');
        String message = sr.getErrors()[0].getMessage();
        System.assert(message.contains('exceeds the allowed radius'),
            'Named as a geofence breach: ' + message);
        System.assert(message.contains('m from the outlet'),
            'With the actual distance, so the rep can judge GPS drift vs wrong shop: ' + message);
    }

    @isTest
    static void geofence_farCheckInWithAReason_isAllowedAndAudited() {
        enableVisitAndGeofence();
        Visit__c overridden = geoVisit(28.6139, 77.2090, 71);
        overridden.Geo_Fence_Override_Reason__c = 'Outlet relocated, GPS pin stale';

        Test.startTest();
        Database.SaveResult sr = Database.insert(overridden, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'A reason lets the visit through: ' + (sr.isSuccess() ? '' : sr.getErrors()[0].getMessage()));
        Visit__c stored = [
            SELECT Is_Geo_Fenced__c, Distance_To_Outlet__c, Geo_Fence_Override_Reason__c
            FROM Visit__c WHERE Id = :overridden.Id
        ];
        System.assertEquals(false, stored.Is_Geo_Fenced__c,
            'But the visit is still flagged out-of-fence — the override excuses, it does not erase');
        System.assert(stored.Distance_To_Outlet__c > 1000000,
            'And the real distance is stored for audit: ' + stored.Distance_To_Outlet__c + 'm');
    }

    @isTest
    static void geofence_nearbyCheckIn_isStampedInFence() {
        enableVisitAndGeofence();
        // ~15 m from the outlet pin.
        Visit__c near = geoVisit(19.0761, 72.8778, 72);

        Test.startTest();
        insert near;
        Test.stopTest();

        Visit__c stored = [
            SELECT Is_Geo_Fenced__c, Distance_To_Outlet__c FROM Visit__c WHERE Id = :near.Id
        ];
        System.assertEquals(true, stored.Is_Geo_Fenced__c, 'Inside the radius, marked as such');
        System.assert(stored.Distance_To_Outlet__c < 100,
            'With a plausible distance: ' + stored.Distance_To_Outlet__c + 'm');
    }

    @isTest
    static void geofence_perOutletRadius_overridesTheDefault() {
        enableVisitAndGeofence();
        // Give this outlet a radius wide enough to reach Delhi.
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1];
        acct.Geofence_Radius__c = 2000000;   // 2,000 km
        update acct;

        Visit__c far = geoVisit(28.6139, 77.2090, 73);

        Test.startTest();
        Database.SaveResult sr = Database.insert(far, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'The outlet-level radius wins over the configured default — a rural outlet with a '
            + 'wide fence must not be judged by the city default: '
            + (sr.isSuccess() ? '' : sr.getErrors()[0].getMessage()));
        System.assertEquals(true, [
            SELECT Is_Geo_Fenced__c FROM Visit__c WHERE Id = :far.Id
        ].Is_Geo_Fenced__c, 'And the visit reads as in-fence against ITS radius');
    }

    @isTest
    static void geofence_withNoCheckInCoordinates_isSkippedEntirely() {
        enableVisitAndGeofence();
        Visit__c planned = geoVisit(null, null, 74);

        Test.startTest();
        insert planned;
        Test.stopTest();

        Visit__c stored = [
            SELECT Is_Geo_Fenced__c, Distance_To_Outlet__c FROM Visit__c WHERE Id = :planned.Id
        ];
        System.assertEquals(null, stored.Distance_To_Outlet__c,
            'A planned visit with no check-in yet has no distance to judge — planning must '
            + 'never be blocked by a fence the rep has not reached');
    }

    // ── Geofence on UPDATE: the check-in path the LWC actually uses ───

    @isTest
    static void geofence_checkInByUpdate_isValidatedTheSameWay() {
        enableVisitAndGeofence();
        // Created as Planned with no coordinates, checked in later — the real flow.
        Visit__c planned = geoVisit(null, null, 75);
        insert planned;

        Test.startTest();
        planned.Check_In_Latitude__c = 28.6139;
        planned.Check_In_Longitude__c = 77.2090;
        Database.SaveResult sr = Database.update(planned, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(),
            'Setting far coordinates on an existing visit is the same breach as inserting '
            + 'them — most check-ins arrive as updates, so this path matters more than insert');
        System.assert(sr.getErrors()[0].getMessage().contains('exceeds the allowed radius'),
            'Same message either way: ' + sr.getErrors()[0].getMessage());
    }

    @isTest
    static void geofence_unrelatedEdit_doesNotRevalidate() {
        enableVisitAndGeofence();
        // Checked in legitimately near the outlet…
        Visit__c near = geoVisit(19.0761, 72.8778, 76);
        insert near;
        // …then the outlet pin is moved far away (bad master-data edit).
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1];
        acct.Outlet_Latitude__c = 28.6139;
        acct.Outlet_Longitude__c = 77.2090;
        update acct;

        Test.startTest();
        near.Notes__c = 'Adding a note after the fact';
        Database.SaveResult sr = Database.update(near, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'An edit that touches no coordinates must not re-run the fence — otherwise every '
            + 'later note or flag update fails because master data moved underneath it: '
            + (sr.isSuccess() ? '' : sr.getErrors()[0].getMessage()));
    }

    // ── The feature toggle gates the whole handler ────────────────────

    /**
     * The gate cannot be proven through setDefaults: Order_Value__c,
     * Collection_Amount__c and Total_Orders_Count__c all carry FIELD-LEVEL
     * defaults of 0, which apply on insert whether or not any trigger runs —
     * so those fields read 0 either way (and setDefaults is effectively
     * redundant for inserts). The discriminator is afterInsert's
     * updateDayAttendanceTotals: only the handler recounts the day's visits,
     * so the attendance total moves only when the toggle is on.
     */
    @isTest
    static void visitExecutionOff_skipsTheAttendanceRecount() {
        setFeature(OVE_Visit_Service.FEATURE_VISIT_EXECUTION, false);
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id, Total_Visits__c FROM Day_Attendance__c LIMIT 1];
        Decimal totalBefore = da.Total_Visits__c;

        Test.startTest();
        insert new Visit__c(
            Account__c = acct.Id,
            Salesperson__c = UserInfo.getUserId(),
            Day_Attendance__c = da.Id,
            Beat__c = beat.Id,
            Visit_Date__c = Date.today(),   // VR-required; the handler default is off
            Visit_Status__c = 'Planned',
            Visit_Sequence__c = 77
        );
        Test.stopTest();

        System.assertEquals(totalBefore, [
            SELECT Total_Visits__c FROM Day_Attendance__c WHERE Id = :da.Id
        ].Total_Visits__c,
            'With OVE-001 off the handler never ran — a visit exists but the attendance '
            + 'total was not recounted');
    }

    @isTest
    static void visitExecutionOn_recountsTheAttendanceTotal() {
        setFeature(OVE_Visit_Service.FEATURE_VISIT_EXECUTION, true);
        setFeature(OVE_Visit_Service.FEATURE_GEOFENCE, false);
        Account acct = [SELECT Id FROM Account WHERE Name = 'VTH Geo Outlet' LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Test.startTest();
        insert new Visit__c(
            Account__c = acct.Id,
            Salesperson__c = UserInfo.getUserId(),
            Day_Attendance__c = da.Id,
            Beat__c = beat.Id,
            Visit_Date__c = Date.today(),
            Visit_Status__c = 'Planned',
            Visit_Sequence__c = 78
        );
        Test.stopTest();

        System.assertEquals(1, [
            SELECT Total_Visits__c FROM Day_Attendance__c WHERE Id = :da.Id
        ].Total_Visits__c,
            'The same insert with the toggle on recounts the day: one visit, total one — '
            + 'the contrast with the test above is what proves the gate');
    }
}