/**
 * @description Smoke tests for ApprovalRouter — submit, approve, reject,
 * recall, auto-approve cascade. Uses Lead as a stand-in object since it
 * exists in every org and has Status (picklist) for status mapping.
 */
@isTest
private class ApprovalRouterTest {

    private static User createTestUser(String alias) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            ProfileId = p.Id,
            Alias = alias,
            Email = alias + '@apr.test',
            EmailEncodingKey = 'UTF-8',
            FirstName = 'Test',
            LastName = alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = alias + System.currentTimeMillis() + '@apr.test'
        );
        insert u;
        return u;
    }

    private static Approval_Rule__c rule(String obj, Integer level, String approverType,
            Id userId, Boolean autoApprove, String condField,
            Decimal minVal, Decimal maxVal) {
        return new Approval_Rule__c(
            Object_Process__c = obj,
            Approval_Level__c = level,
            Approver_Type__c = approverType,
            User__c = userId,
            Auto_Approve__c = autoApprove,
            Condition_Field__c = condField,
            Min_Value__c = minVal,
            Max_Value__c = maxVal,
            Status_Field_API_Name__c = 'Status',
            Status_Value_On_Submit__c = 'Working - Contacted',
            Status_Value_On_Approve__c = 'Closed - Converted',
            Status_Value_On_Reject__c = 'Closed - Not Converted',
            Is_Active__c = true
        );
    }

    @isTest
    static void submit_creates_request_and_steps() {
        User approver = createTestUser('aprv1');
        Lead l = new Lead(LastName = 'Test', Company = 'X', Status = 'Open - Not Contacted',
            NumberOfEmployees = 100);
        insert l;

        insert rule('Lead', 1, 'User', approver.Id, false, null, null, null);

        Test.startTest();
        Id reqId;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            reqId = ApprovalRouter.submit(l.Id, 'Please review');
        }
        Test.stopTest();

        Approval_Request__c req = [SELECT Status__c, Current_Level__c, Total_Levels__c,
            Current_Approver__c FROM Approval_Request__c WHERE Id = :reqId];
        System.assertEquals('Pending', req.Status__c);
        System.assertEquals(1, req.Total_Levels__c);
        System.assertEquals(approver.Id, req.Current_Approver__c);

        List<Approval_Step__c> steps = [SELECT Status__c, Is_Current__c FROM Approval_Step__c
            WHERE Approval_Request__c = :reqId];
        System.assertEquals(1, steps.size());
        System.assertEquals('Pending', steps[0].Status__c);
        System.assert(steps[0].Is_Current__c);
    }

    @isTest
    static void approve_advances_or_completes() {
        User a1 = createTestUser('aprv2a');
        User a2 = createTestUser('aprv2b');
        Lead l = new Lead(LastName = 'Test', Company = 'X', Status = 'Open - Not Contacted',
            NumberOfEmployees = 100);
        insert l;

        insert new List<Approval_Rule__c>{
            rule('Lead', 1, 'User', a1.Id, false, null, null, null),
            rule('Lead', 2, 'User', a2.Id, false, null, null, null)
        };

        Id reqId = ApprovalRouter.submit(l.Id, 'Multi-level');

        Approval_Step__c s1 = [SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :reqId AND Level__c = 1];

        Test.startTest();
        System.runAs(a1) { ApprovalRouter.approve(s1.Id, 'OK'); }
        Test.stopTest();

        Approval_Request__c req = [SELECT Status__c, Current_Level__c, Current_Approver__c
            FROM Approval_Request__c WHERE Id = :reqId];
        System.assertEquals('Pending', req.Status__c, 'Still pending after L1 approval');
        System.assertEquals(2, req.Current_Level__c);
        System.assertEquals(a2.Id, req.Current_Approver__c);
    }

    @isTest
    static void reject_closes_request_and_skips_remaining() {
        User a1 = createTestUser('aprv3a');
        User a2 = createTestUser('aprv3b');
        Lead l = new Lead(LastName = 'Test', Company = 'X', Status = 'Open - Not Contacted',
            NumberOfEmployees = 100);
        insert l;
        insert new List<Approval_Rule__c>{
            rule('Lead', 1, 'User', a1.Id, false, null, null, null),
            rule('Lead', 2, 'User', a2.Id, false, null, null, null)
        };
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c s1 = [SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :reqId AND Level__c = 1];

        Test.startTest();
        System.runAs(a1) { ApprovalRouter.reject(s1.Id, 'No'); }
        Test.stopTest();

        Approval_Request__c req = [SELECT Status__c FROM Approval_Request__c WHERE Id = :reqId];
        System.assertEquals('Rejected', req.Status__c);

        Approval_Step__c s2 = [SELECT Status__c FROM Approval_Step__c
            WHERE Approval_Request__c = :reqId AND Level__c = 2];
        System.assertEquals('Skipped', s2.Status__c);
    }

    @isTest
    static void auto_approve_cascades() {
        User a2 = createTestUser('aprv4');
        Lead l = new Lead(LastName = 'Test', Company = 'X', Status = 'Open - Not Contacted',
            NumberOfEmployees = 100);
        insert l;
        // L1 auto-approves (NumberOfEmployees 100 is within 0-1000)
        // L2 is manual
        insert new List<Approval_Rule__c>{
            rule('Lead', 1, 'User', a2.Id, true, 'NumberOfEmployees', 0, 1000),
            rule('Lead', 2, 'User', a2.Id, false, null, null, null)
        };

        Test.startTest();
        Id reqId = ApprovalRouter.submit(l.Id, 'Auto then manual');
        Test.stopTest();

        Approval_Request__c req = [SELECT Status__c, Current_Level__c
            FROM Approval_Request__c WHERE Id = :reqId];
        System.assertEquals(2, req.Current_Level__c, 'Auto-approved L1, now on L2');

        Approval_Step__c s1 = [SELECT Status__c FROM Approval_Step__c
            WHERE Approval_Request__c = :reqId AND Level__c = 1];
        System.assertEquals('Auto-Approved', s1.Status__c);
    }

    @isTest
    static void recall_only_by_submitter() {
        User a1 = createTestUser('aprv5');
        Lead l = new Lead(LastName = 'Test', Company = 'X', Status = 'Open - Not Contacted');
        insert l;
        insert rule('Lead', 1, 'User', a1.Id, false, null, null, null);

        Id reqId = ApprovalRouter.submit(l.Id, null);

        Test.startTest();
        ApprovalRouter.recall(reqId);
        Test.stopTest();

        Approval_Request__c req = [SELECT Status__c FROM Approval_Request__c WHERE Id = :reqId];
        System.assertEquals('Recalled', req.Status__c);
    }

    @isTest
    static void condition_filter_blocks_non_matching() {
        User a1 = createTestUser('aprv6');
        Lead l = new Lead(LastName = 'Test', Company = 'X', Status = 'Open - Not Contacted',
            NumberOfEmployees = 50);
        insert l;
        // Rule requires >= 1000 — should not apply
        insert rule('Lead', 1, 'User', a1.Id, false, 'NumberOfEmployees', 1000, null);

        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalRouter.submit(l.Id, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Should fail — no rule matches NumberOfEmployees=50');
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage: simulate, escalation, criteria operators,
    //  approver resolution and the guard clauses.
    // ══════════════════════════════════════════════════════════════════

    private static Integer userSeq = 0;

    /**
     * User is a setup object, so its DML is isolated inside System.runAs —
     * otherwise the Lead and rule inserts that follow in the same transaction
     * trip MIXED_DML_OPERATION.
     */
    private static List<User> newUsers(Integer count) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (Integer i = 0; i < count; i++) {
            userSeq++;
            String alias = 'arx' + userSeq;
            users.add(new User(
                ProfileId = p.Id,
                Alias = alias,
                Email = alias + '@apr.test',
                EmailEncodingKey = 'UTF-8',
                FirstName = 'Router',
                LastName = 'User' + userSeq,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/Los_Angeles',
                Username = alias + System.currentTimeMillis() + '@apr.test'
            ));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) { insert users; }
        // Name is derived server-side, so re-read before anything asserts on it.
        return [SELECT Id, Name, Email FROM User WHERE Id IN :users ORDER BY LastName];
    }

    private static Lead newLead() {
        Lead l = new Lead(
            LastName = 'Router',
            Company = 'Acme Trading',
            Status = 'Open - Not Contacted',
            NumberOfEmployees = 100
        );
        insert l;
        return l;
    }

    /** A rule with no status mapping — keeps tests off the source record. */
    private static Approval_Rule__c plainRule(String obj, Integer level,
            String approverType, Id userId) {
        return new Approval_Rule__c(
            Object_Process__c = obj,
            Approval_Level__c = level,
            Approver_Type__c = approverType,
            User__c = userId,
            Auto_Approve__c = false,
            Is_Active__c = true
        );
    }

    private static Approval_Rule_Condition__c cond(Id ruleId, String field,
            String op, String val, Integer seq) {
        return new Approval_Rule_Condition__c(
            Approval_Rule__c = ruleId,
            Field_API_Name__c = field,
            Operator__c = op,
            Value__c = val,
            Sequence__c = seq
        );
    }

    private static List<Map<String, Object>> matchedOf(Map<String, Object> sim) {
        return (List<Map<String, Object>>) sim.get('matched');
    }

    private static List<Map<String, Object>> skippedOf(Map<String, Object> sim) {
        return (List<Map<String, Object>>) sim.get('skipped');
    }

    // ── Submit guard clauses ──────────────────────────────────────────

    @isTest
    static void submit_nullRecordId_throws() {
        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalRouter.submit(null, 'no record');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A null record id must be rejected before any DML');
    }

    @isTest
    static void submit_whilePendingRequestExists_throws() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', a1.Id);
        ApprovalRouter.submit(l.Id, 'first');

        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalRouter.submit(l.Id, 'second');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A record already in flight cannot be submitted again');
        System.assertEquals(1, [SELECT COUNT() FROM Approval_Request__c],
            'No second request was created');
    }

    @isTest
    static void submit_unresolvableApprover_throwsBeforeCreatingAnything() {
        Lead l = newLead();
        // Role approver with no role named — resolveApprover returns null and
        // the step would be actionable by nobody, so submit must refuse.
        insert plainRule('Lead', 1, 'Role', null);

        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalRouter.submit(l.Id, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A rule whose approver cannot be resolved must fail loudly');
        System.assertEquals(0, [SELECT COUNT() FROM Approval_Request__c],
            'Approvers resolve before anything is created, so nothing is left behind');
        System.assertEquals(0, [SELECT COUNT() FROM Approval_Step__c], 'No orphan steps');
    }

    @isTest
    static void submit_missingStatusField_completesWithoutWriteback() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        Approval_Rule__c r = plainRule('Lead', 1, 'User', a1.Id);
        r.Status_Field_API_Name__c = 'Not_A_Real_Field__c';
        r.Status_Value_On_Submit__c = 'Whatever';
        insert r;

        Test.startTest();
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, reqId,
            'A rule naming a field that no longer exists must not break the submit');
        System.assertEquals('Open - Not Contacted',
            [SELECT Status FROM Lead WHERE Id = :l.Id].Status,
            'The write-back is skipped rather than throwing mid-approval');
    }

    // ── Flow entry point ──────────────────────────────────────────────

    @isTest
    static void flowSubmit_routesValidRecordsAndSwallowsFailures() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', a1.Id);

        // An Account id is enough to prove the "no rules for this object" path
        // is swallowed — the engine reads the object type off the id and bails
        // before touching the record, so nothing needs to be inserted (and the
        // org's Outlet Type validation rule stays out of this test).
        Id noRulesId = Id.valueOf(
            Account.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        ApprovalRouter.SubmitRequest good = new ApprovalRouter.SubmitRequest();
        good.recordId = l.Id;
        good.comments = 'via flow';
        ApprovalRouter.SubmitRequest blank = new ApprovalRouter.SubmitRequest();
        blank.recordId = null;
        ApprovalRouter.SubmitRequest fails = new ApprovalRouter.SubmitRequest();
        fails.recordId = noRulesId;

        Test.startTest();
        ApprovalRouter.submitForApprovalFlow(
            new List<ApprovalRouter.SubmitRequest>{ good, blank, fails });
        ApprovalRouter.submitForApprovalFlow(null);
        Test.stopTest();

        List<Approval_Request__c> reqs = [
            SELECT Object_Type__c, Comments__c FROM Approval_Request__c
        ];
        System.assertEquals(1, reqs.size(),
            'One routable record in, one request out — the other two are skipped');
        System.assertEquals('Lead', reqs[0].Object_Type__c, 'The Lead is the one that routed');
        System.assertEquals('via flow', reqs[0].Comments__c, 'Flow comments carried through');
    }

    // ── Step action guards ────────────────────────────────────────────

    @isTest
    static void approve_nullStepId_throws() {
        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalRouter.approve(null, 'nothing to approve');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A missing step id must be rejected');
    }

    @isTest
    static void approve_alreadyDecidedStep_throws() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', a1.Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c s = [SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :reqId];

        Test.startTest();
        Boolean threw = false;
        System.runAs(a1) {
            ApprovalRouter.approve(s.Id, 'first time');
            try {
                ApprovalRouter.approve(s.Id, 'second time');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assert(threw, 'A step that has already been decided cannot be decided again');
    }

    @isTest
    static void approve_stepThatIsNotCurrent_throws() {
        List<User> us = newUsers(2);
        Lead l = newLead();
        insert new List<Approval_Rule__c>{
            plainRule('Lead', 1, 'User', us[0].Id),
            plainRule('Lead', 2, 'User', us[1].Id)
        };
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c level2 = [
            SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :reqId AND Level__c = 2
        ];

        Test.startTest();
        Boolean threw = false;
        System.runAs(us[1]) {
            try {
                ApprovalRouter.approve(level2.Id, 'jumping the queue');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assert(threw, 'A later level cannot be approved while an earlier one is open');
    }

    @isTest
    static void reject_byNonApprover_throws() {
        List<User> us = newUsers(2);
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', us[0].Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c s = [SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :reqId];

        Test.startTest();
        Boolean threw = false;
        System.runAs(us[1]) {
            try {
                ApprovalRouter.reject(s.Id, 'not mine');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assert(threw, 'Only the assigned approver may reject');
        System.assertEquals('Pending',
            [SELECT Status__c FROM Approval_Step__c WHERE Id = :s.Id].Status__c,
            'The step is untouched');
    }

    // ── Chain completion and parallel modes ───────────────────────────

    @isTest
    static void approve_lastLevel_completesRequest() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', a1.Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c s = [SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :reqId];

        Test.startTest();
        System.runAs(a1) { ApprovalRouter.approve(s.Id, 'done'); }
        Test.stopTest();

        Approval_Request__c req = [
            SELECT Status__c, Completed_Date__c, Current_Approver__c
            FROM Approval_Request__c WHERE Id = :reqId
        ];
        System.assertEquals('Approved', req.Status__c, 'Nothing pending left — the chain completes');
        System.assertNotEquals(null, req.Completed_Date__c, 'Completion is stamped');
        System.assertEquals(null, req.Current_Approver__c, 'No approver holds a finished request');
    }

    @isTest
    static void submit_allLevelsAutoApprove_completesImmediately() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        Approval_Rule__c r = plainRule('Lead', 1, 'User', a1.Id);
        r.Auto_Approve__c = true;
        insert r;

        Test.startTest();
        Id reqId = ApprovalRouter.submit(l.Id, 'straight through');
        Test.stopTest();

        System.assertEquals('Approved',
            [SELECT Status__c FROM Approval_Request__c WHERE Id = :reqId].Status__c,
            'A chain of nothing but auto-approve levels finishes inside submit');
        System.assertEquals('Auto-Approved',
            [SELECT Status__c FROM Approval_Step__c WHERE Approval_Request__c = :reqId].Status__c,
            'The step records that no human signed it');
    }

    @isTest
    static void parallelAny_oneApprovalRetiresTheSiblings() {
        List<User> us = newUsers(2);
        Lead l = newLead();
        Approval_Rule__c r1 = plainRule('Lead', 1, 'User', us[0].Id);
        r1.Approval_Mode__c = 'Parallel Any';
        Approval_Rule__c r2 = plainRule('Lead', 1, 'User', us[1].Id);
        r2.Approval_Mode__c = 'Parallel Any';
        insert new List<Approval_Rule__c>{ r1, r2 };

        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c mine = [
            SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :reqId AND Approver__c = :us[0].Id
        ];

        Test.startTest();
        System.runAs(us[0]) { ApprovalRouter.approve(mine.Id, 'one signature is enough'); }
        Test.stopTest();

        System.assertEquals('Skipped',
            [SELECT Status__c FROM Approval_Step__c
             WHERE Approval_Request__c = :reqId AND Approver__c = :us[1].Id].Status__c,
            'The sibling step leaves the other approver inbox');
        System.assertEquals('Approved',
            [SELECT Status__c FROM Approval_Request__c WHERE Id = :reqId].Status__c,
            'The level closed, so the request completed');
    }

    // ── Recall guards ─────────────────────────────────────────────────

    @isTest
    static void recall_byNonSubmitter_throws() {
        List<User> us = newUsers(2);
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', us[0].Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);

        Test.startTest();
        Boolean threw = false;
        System.runAs(us[1]) {
            try {
                ApprovalRouter.recall(reqId);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assert(threw, 'Only the submitter may recall');
        System.assertEquals('Pending',
            [SELECT Status__c FROM Approval_Request__c WHERE Id = :reqId].Status__c,
            'The request stays in flight');
    }

    @isTest
    static void recall_alreadyClosedRequest_throws() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', a1.Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);
        ApprovalRouter.recall(reqId);

        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalRouter.recall(reqId);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Only a Pending request can be recalled');
    }

    // ── Approver inbox ────────────────────────────────────────────────

    @isTest
    static void getMyApprovals_returnsCurrentPendingStepsForRunningUser() {
        List<User> us = newUsers(2);
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', us[0].Id);
        Id reqId = ApprovalRouter.submit(l.Id, 'inbox');
        Id stepId = [SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :reqId].Id;

        Test.startTest();
        List<Approval_Step__c> mine;
        List<Approval_Step__c> theirs;
        System.runAs(us[0]) { mine = ApprovalRouter.getMyApprovals(); }
        System.runAs(us[1]) { theirs = ApprovalRouter.getMyApprovals(); }
        Test.stopTest();

        System.assertEquals(1, mine.size(), 'The assigned approver sees the step');
        System.assertEquals(stepId, mine[0].Id, 'It is the step waiting on them');
        System.assertEquals('Router', mine[0].Approval_Request__r.Record_Name__c,
            'The inbox row carries the source record name for display');
        System.assertEquals(0, theirs.size(), 'Nobody else sees it');
    }

    // ── simulate ──────────────────────────────────────────────────────

    @isTest
    static void simulate_nullRecordId_returnsError() {
        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(null);
        Test.stopTest();

        System.assertEquals('Record Id is required.', sim.get('error'), 'Guard clause message');
    }

    @isTest
    static void simulate_noRulesForObject_returnsError() {
        Lead l = newLead();

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals('Lead', sim.get('objectType'), 'Object resolved from the record id');
        System.assert(String.valueOf(sim.get('error')).contains('No active approval rules'),
            'An unconfigured object is reported, not silently empty');
    }

    @isTest
    static void simulate_deletedRecord_returnsNotFound() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', a1.Id);
        Id goneId = l.Id;
        delete l;

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(goneId);
        Test.stopTest();

        System.assertEquals('Record not found.', sim.get('error'),
            'A record that no longer exists is reported cleanly');
    }

    @isTest
    static void simulate_splitsMatchedFromSkippedAndNamesApprovers() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        Approval_Rule__c matches = plainRule('Lead', 1, 'User', a1.Id);
        Approval_Rule__c misses = plainRule('Lead', 2, 'User', a1.Id);
        misses.Condition_Field__c = 'NumberOfEmployees';
        misses.Min_Value__c = 1000;
        insert new List<Approval_Rule__c>{ matches, misses };

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(true, sim.get('willRoute'), 'At least one rule matched');
        System.assertEquals('Router', sim.get('recordName'), 'Lead name resolved');
        System.assertEquals(1, matchedOf(sim).size(), 'Only the unconditional rule matched');
        System.assertEquals(1, skippedOf(sim).size(), 'The 1000-employee band did not');
        System.assertEquals(a1.Id, matchedOf(sim)[0].get('approverId'), 'Approver resolved');
        System.assertEquals(a1.Name, matchedOf(sim)[0].get('approverName'),
            'Approver name is resolved so the admin sees a person, not an id');
        System.assertEquals('Entry criteria not met', skippedOf(sim)[0].get('reason'),
            'Skipped rules explain themselves');
    }

    @isTest
    static void simulate_unresolvableApprover_flagsWarningWithoutThrowing() {
        Lead l = newLead();
        insert plainRule('Lead', 1, 'Role', null);

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(1, matchedOf(sim).size(), 'The rule matches on criteria');
        System.assertEquals(null, matchedOf(sim)[0].get('approverId'), 'But nobody resolves');
        System.assertNotEquals(null, matchedOf(sim)[0].get('warning'),
            'Simulation warns instead of throwing — that is the point of a dry run');
    }

    // ── Criteria: operators, AND/OR, legacy band ──────────────────────

    @isTest
    static void criteria_everyOperatorEvaluates() {
        User a1 = newUsers(1)[0];
        Lead l = newLead(); // Company 'Acme Trading', NumberOfEmployees 100

        List<String> fields = new List<String>{
            'Status', 'Status', 'Company', 'Company', 'Company',
            'NumberOfEmployees', 'NumberOfEmployees', 'NumberOfEmployees',
            'NumberOfEmployees', 'Company', 'Company'
        };
        List<String> ops = new List<String>{
            'equals', 'not equal to', 'starts with', 'contains', 'does not contain',
            'less than', 'greater than', 'less or equal', 'greater or equal',
            'includes', 'excludes'
        };
        List<String> vals = new List<String>{
            'Open - Not Contacted', 'Zzz', 'Acme', 'Trad', 'Zzz',
            '200', '50', '100', '100', 'Acme', 'Zzz'
        };

        List<Approval_Rule__c> rules = new List<Approval_Rule__c>();
        for (Integer i = 0; i < ops.size(); i++) {
            rules.add(plainRule('Lead', i + 1, 'User', a1.Id));
        }
        insert rules;

        List<Approval_Rule_Condition__c> conds = new List<Approval_Rule_Condition__c>();
        for (Integer i = 0; i < ops.size(); i++) {
            conds.add(cond(rules[i].Id, fields[i], ops[i], vals[i], 0));
        }
        insert conds;

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(ops.size(), matchedOf(sim).size(),
            'Every operator was written to match this Lead — none should be skipped');
        System.assertEquals(0, skippedOf(sim).size(), 'No rule was filtered out');
    }

    @isTest
    static void criteria_falseCasesAreSkipped() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();

        List<Approval_Rule__c> rules = new List<Approval_Rule__c>{
            plainRule('Lead', 1, 'User', a1.Id),
            plainRule('Lead', 2, 'User', a1.Id),
            plainRule('Lead', 3, 'User', a1.Id),
            plainRule('Lead', 4, 'User', a1.Id)
        };
        insert rules;

        insert new List<Approval_Rule_Condition__c>{
            // value simply does not match
            cond(rules[0].Id, 'Status', 'equals', 'Working - Contacted', 0),
            // field is null on the record
            cond(rules[1].Id, 'Rating', 'equals', 'Hot', 0),
            // numeric operator against non-numeric operands
            cond(rules[2].Id, 'Company', 'greater than', 'abc', 0),
            // relationship paths are not supported in criteria
            cond(rules[3].Id, 'Owner.Name', 'equals', 'Anyone', 0)
        };

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(0, matchedOf(sim).size(), 'None of these criteria hold');
        System.assertEquals(4, skippedOf(sim).size(), 'All four rules are filtered out');
        System.assertEquals(false, sim.get('willRoute'), 'Nothing would route');
    }

    @isTest
    static void criteria_andRequiresAllRowsWhileOrRequiresOne() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();

        Approval_Rule__c andPasses = plainRule('Lead', 1, 'User', a1.Id);
        andPasses.Criteria_Logic__c = 'AND';
        Approval_Rule__c andFails = plainRule('Lead', 2, 'User', a1.Id);
        andFails.Criteria_Logic__c = 'AND';
        Approval_Rule__c orPasses = plainRule('Lead', 3, 'User', a1.Id);
        orPasses.Criteria_Logic__c = 'OR';
        Approval_Rule__c orFails = plainRule('Lead', 4, 'User', a1.Id);
        orFails.Criteria_Logic__c = 'OR';
        insert new List<Approval_Rule__c>{ andPasses, andFails, orPasses, orFails };

        insert new List<Approval_Rule_Condition__c>{
            cond(andPasses.Id, 'Status', 'equals', 'Open - Not Contacted', 0),
            cond(andPasses.Id, 'NumberOfEmployees', 'greater than', '50', 1),
            cond(andFails.Id, 'Status', 'equals', 'Open - Not Contacted', 0),
            cond(andFails.Id, 'NumberOfEmployees', 'greater than', '5000', 1),
            cond(orPasses.Id, 'Status', 'equals', 'Zzz', 0),
            cond(orPasses.Id, 'NumberOfEmployees', 'greater than', '50', 1),
            cond(orFails.Id, 'Status', 'equals', 'Zzz', 0),
            cond(orFails.Id, 'NumberOfEmployees', 'greater than', '5000', 1)
        };

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        Set<Id> matchedIds = new Set<Id>();
        for (Map<String, Object> row : matchedOf(sim)) matchedIds.add((Id) row.get('ruleId'));

        System.assertEquals(2, matchedIds.size(), 'One AND rule and one OR rule qualify');
        System.assert(matchedIds.contains(andPasses.Id), 'AND with every row true matches');
        System.assert(!matchedIds.contains(andFails.Id), 'AND with one row false does not');
        System.assert(matchedIds.contains(orPasses.Id), 'OR with one row true matches');
        System.assert(!matchedIds.contains(orFails.Id), 'OR with every row false does not');
    }

    @isTest
    static void criteria_legacyBandHandlesNullAndNonNumericValues() {
        User a1 = newUsers(1)[0];
        Lead l = newLead(); // Rating is null, Company is text

        Approval_Rule__c nullNoBand = plainRule('Lead', 1, 'User', a1.Id);
        nullNoBand.Condition_Field__c = 'Rating'; // null field, no Min/Max -> matches
        Approval_Rule__c nullWithBand = plainRule('Lead', 2, 'User', a1.Id);
        nullWithBand.Condition_Field__c = 'Rating';
        nullWithBand.Min_Value__c = 1; // null field but a band -> does not match
        Approval_Rule__c nonNumeric = plainRule('Lead', 3, 'User', a1.Id);
        nonNumeric.Condition_Field__c = 'Company';
        nonNumeric.Min_Value__c = 10; // text cannot satisfy a numeric band
        Approval_Rule__c overMax = plainRule('Lead', 4, 'User', a1.Id);
        overMax.Condition_Field__c = 'NumberOfEmployees';
        overMax.Max_Value__c = 10; // 100 is above the ceiling
        insert new List<Approval_Rule__c>{ nullNoBand, nullWithBand, nonNumeric, overMax };

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        Set<Id> matchedIds = new Set<Id>();
        for (Map<String, Object> row : matchedOf(sim)) matchedIds.add((Id) row.get('ruleId'));

        System.assertEquals(1, matchedIds.size(), 'Only the unbounded rule applies');
        System.assert(matchedIds.contains(nullNoBand.Id),
            'A null field with no band is not a filter at all');
        System.assert(!matchedIds.contains(nullWithBand.Id), 'A null field cannot satisfy a band');
        System.assert(!matchedIds.contains(nonNumeric.Id), 'Text cannot satisfy a numeric band');
        System.assert(!matchedIds.contains(overMax.Id), 'A value above Max is out of band');
    }

    // ── Approver resolution ───────────────────────────────────────────

    @isTest
    static void resolveApprover_managerTypeUsesRecordOwnersManager() {
        List<User> us = newUsers(2);
        User manager = us[0];
        User owner = us[1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = owner.Id, ManagerId = manager.Id);
        }

        Lead l = new Lead(LastName = 'Router', Company = 'Acme Trading',
            Status = 'Open - Not Contacted', NumberOfEmployees = 100, OwnerId = owner.Id);
        insert l;
        insert plainRule('Lead', 1, 'Manager', null);

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(manager.Id, matchedOf(sim)[0].get('approverId'),
            'A Manager rule routes to the manager of the record owner');
    }

    @isTest
    static void resolveApprover_managerTypeWithNoManager_resolvesToNobody() {
        User owner = newUsers(1)[0];
        Lead l = new Lead(LastName = 'Router', Company = 'Acme Trading',
            Status = 'Open - Not Contacted', OwnerId = owner.Id);
        insert l;
        insert plainRule('Lead', 1, 'Manager', null);

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(null, matchedOf(sim)[0].get('approverId'),
            'An owner with no manager leaves the rule unresolved');
        System.assertNotEquals(null, matchedOf(sim)[0].get('warning'), 'And the dry run says so');
    }

    @isTest
    static void resolveApprover_roleTypeFindsAnActiveRoleMember() {
        UserRole role;
        User roleUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            role = new UserRole(Name = 'Approval Router Test Role',
                DeveloperName = 'Approval_Router_Test_Role');
            insert role;

            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            roleUser = new User(
                ProfileId = p.Id, UserRoleId = role.Id, Alias = 'arrole',
                Email = 'arrole@apr.test', EmailEncodingKey = 'UTF-8',
                FirstName = 'Role', LastName = 'Approver',
                LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/Los_Angeles',
                Username = 'arrole' + System.currentTimeMillis() + '@apr.test'
            );
            insert roleUser;
        }

        Lead l = newLead();
        Approval_Rule__c r = plainRule('Lead', 1, 'Role', null);
        r.Approver_Role_Queue__c = 'Approval_Router_Test_Role';
        insert r;

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(roleUser.Id, matchedOf(sim)[0].get('approverId'),
            'A Role rule routes to an active member of that role');
    }

    @isTest
    static void resolveApprover_queueTypeFindsAQueueMember() {
        User member = newUsers(1)[0];
        Group queue;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            queue = new Group(Name = 'Approval Router Test Queue',
                DeveloperName = 'Approval_Router_Test_Queue', Type = 'Queue');
            insert queue;
            insert new QueueSObject(QueueId = queue.Id, SObjectType = 'Lead');
            insert new GroupMember(GroupId = queue.Id, UserOrGroupId = member.Id);
        }

        Lead l = newLead();
        Approval_Rule__c r = plainRule('Lead', 1, 'Queue', null);
        r.Approver_Role_Queue__c = 'Approval_Router_Test_Queue';
        insert r;

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(member.Id, matchedOf(sim)[0].get('approverId'),
            'A Queue rule routes to a user in that queue');
    }

    @isTest
    static void resolveApprover_unknownRoleOrQueueName_resolvesToNobody() {
        Lead l = newLead();
        Approval_Rule__c badRole = plainRule('Lead', 1, 'Role', null);
        badRole.Approver_Role_Queue__c = 'No_Such_Role';
        Approval_Rule__c badQueue = plainRule('Lead', 2, 'Queue', null);
        badQueue.Approver_Role_Queue__c = 'No_Such_Queue';
        Approval_Rule__c blankQueue = plainRule('Lead', 3, 'Queue', null);
        insert new List<Approval_Rule__c>{ badRole, badQueue, blankQueue };

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        for (Map<String, Object> row : matchedOf(sim)) {
            System.assertEquals(null, row.get('approverId'),
                'A role or queue that does not exist cannot produce an approver');
        }
    }

    @isTest
    static void resolveApprover_blankTypeFallsBackToTheNamedUser() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, null, a1.Id);

        Test.startTest();
        Map<String, Object> sim = ApprovalRouter.simulate(l.Id);
        Test.stopTest();

        System.assertEquals(a1.Id, matchedOf(sim)[0].get('approverId'),
            'With no approver type set, the rule falls back to the User lookup');
    }

    // ── Escalation ────────────────────────────────────────────────────

    @isTest
    static void processEscalations_withNothingOverdue_returnsZero() {
        User a1 = newUsers(1)[0];
        Lead l = newLead();
        insert plainRule('Lead', 1, 'User', a1.Id);
        ApprovalRouter.submit(l.Id, null);

        Test.startTest();
        Integer moved = ApprovalRouter.processEscalations();
        Test.stopTest();

        System.assertEquals(0, moved, 'A step with no due date is never overdue');
    }

    @isTest
    static void processEscalations_reassignsToTheEscalationApprover() {
        List<User> us = newUsers(2);
        User approver = us[0];
        User escalateTo = us[1];
        Lead l = newLead();
        Approval_Rule__c r = plainRule('Lead', 1, 'User', approver.Id);
        r.Escalation_Hours__c = 1;
        r.Escalation_Approver__c = escalateTo.Id;
        insert r;

        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c step = [
            SELECT Id, Due_Date__c FROM Approval_Step__c WHERE Approval_Request__c = :reqId
        ];
        System.assertNotEquals(null, step.Due_Date__c,
            'Escalation_Hours__c gives the step a due date when it is activated');
        step.Due_Date__c = Datetime.now().addHours(-2);
        update step;

        Test.startTest();
        Integer moved = ApprovalRouter.processEscalations();
        Test.stopTest();

        System.assertEquals(1, moved, 'The overdue step escalated');
        Approval_Step__c after = [
            SELECT Approver__c, Original_Approver__c, Escalated__c, Due_Date__c
            FROM Approval_Step__c WHERE Id = :step.Id
        ];
        System.assertEquals(escalateTo.Id, after.Approver__c, 'Reassigned to the escalation approver');
        System.assertEquals(approver.Id, after.Original_Approver__c,
            'The original approver is kept for the audit trail');
        System.assertEquals(true, after.Escalated__c, 'Flagged so it never escalates twice');
        System.assertEquals(escalateTo.Id,
            [SELECT Current_Approver__c FROM Approval_Request__c WHERE Id = :reqId].Current_Approver__c,
            'The request follows the step to its new approver');
    }

    @isTest
    static void processEscalations_fallsBackToTheApproversManager() {
        List<User> us = newUsers(2);
        User manager = us[0];
        User approver = us[1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = approver.Id, ManagerId = manager.Id);
        }

        Lead l = newLead();
        Approval_Rule__c r = plainRule('Lead', 1, 'User', approver.Id);
        r.Escalation_Hours__c = 2; // no explicit escalation approver
        insert r;

        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c step = [
            SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :reqId
        ];
        step.Due_Date__c = Datetime.now().addHours(-3);
        update step;

        Test.startTest();
        Integer moved = ApprovalRouter.processEscalations();
        Test.stopTest();

        System.assertEquals(1, moved, 'The step escalated');
        System.assertEquals(manager.Id,
            [SELECT Approver__c FROM Approval_Step__c WHERE Id = :step.Id].Approver__c,
            'With no escalation approver configured it climbs to the approver manager');
    }

    @isTest
    static void processEscalations_withNoOneToEscalateTo_leavesTheStepAlone() {
        User approver = newUsers(1)[0]; // no manager, no escalation approver
        Lead l = newLead();
        Approval_Rule__c r = plainRule('Lead', 1, 'User', approver.Id);
        r.Escalation_Hours__c = 1;
        insert r;

        Id reqId = ApprovalRouter.submit(l.Id, null);
        Approval_Step__c step = [
            SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :reqId
        ];
        step.Due_Date__c = Datetime.now().addHours(-5);
        update step;

        Test.startTest();
        Integer moved = ApprovalRouter.processEscalations();
        Test.stopTest();

        System.assertEquals(0, moved, 'Nowhere to escalate to');
        Approval_Step__c after = [
            SELECT Approver__c, Escalated__c FROM Approval_Step__c WHERE Id = :step.Id
        ];
        System.assertEquals(approver.Id, after.Approver__c, 'The step keeps its approver');
        System.assertEquals(false, after.Escalated__c,
            'It is not marked escalated, so it stays eligible once a target exists');
    }
}