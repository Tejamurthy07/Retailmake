/**
 * @description Tests for ApprovalPanelController — the UI-state layer behind
 * the approvalPanel record-page LWC and the myApprovals inbox LWC.
 *
 * Uses Lead as the stand-in business object (same convention as
 * ApprovalRouterTest): it exists in every org and its Status picklist gives
 * the engine somewhere to write the mapped status back to.
 *
 * Covers the three things this class is responsible for:
 *   1. getRecordApprovalState — the canSubmit / canRecall / canSubmitAgain /
 *      canAct flags, and the currentStepId the LWC acts on.
 *   2. The thin delegating methods — submit / approve / reject / recall,
 *      including the guard rails they inherit from ApprovalRouter.
 *   3. getMyPendingApprovals — the inbox rows, scoped to the running user.
 */
@isTest
private class ApprovalPanelControllerTest {

    private static Integer userSeq = 0;

    // ── Fixtures ──────────────────────────────────────────────────────

    /**
     * Creates test users. User is a setup object, so its DML is isolated in a
     * System.runAs block — otherwise the Lead/Approval_Rule__c inserts that
     * follow in the same transaction fail with MIXED_DML_OPERATION.
     * FSCRM_Admin is assigned so a Standard User can read the approval objects
     * when the panel is rendered on their behalf.
     */
    private static List<User> createUsers(Integer count) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (Integer i = 0; i < count; i++) {
            userSeq++;
            String alias = 'apc' + userSeq;
            users.add(new User(
                ProfileId = p.Id,
                Alias = alias,
                Email = alias + '@apc.test',
                EmailEncodingKey = 'UTF-8',
                FirstName = 'Panel',
                LastName = 'Tester' + userSeq,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/Los_Angeles',
                Username = alias + System.currentTimeMillis() + '@apc.test'
            ));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users;
            List<PermissionSet> ps = [
                SELECT Id FROM PermissionSet WHERE Name = 'FSCRM_Admin' LIMIT 1
            ];
            if (!ps.isEmpty()) {
                List<PermissionSetAssignment> asgs = new List<PermissionSetAssignment>();
                for (User u : users) {
                    asgs.add(new PermissionSetAssignment(
                        AssigneeId = u.Id, PermissionSetId = ps[0].Id));
                }
                insert asgs;
            }
        }
        return users;
    }

    private static User createUser() {
        return createUsers(1)[0];
    }

    private static Lead createLead() {
        Lead l = new Lead(
            LastName = 'Panel',
            Company = 'Panel Co',
            Status = 'Open - Not Contacted',
            NumberOfEmployees = 100
        );
        insert l;
        return l;
    }

    private static Approval_Rule__c rule(String obj, Integer level, Id approverId) {
        return rule(obj, level, approverId, false, true);
    }

    private static Approval_Rule__c rule(String obj, Integer level, Id approverId,
            Boolean autoApprove, Boolean isActive) {
        return new Approval_Rule__c(
            Object_Process__c = obj,
            Approval_Level__c = level,
            Approver_Type__c = 'User',
            User__c = approverId,
            Auto_Approve__c = autoApprove,
            Status_Field_API_Name__c = 'Status',
            Status_Value_On_Submit__c = 'Working - Contacted',
            Status_Value_On_Approve__c = 'Working - Contacted',
            Status_Value_On_Reject__c = 'Closed - Not Converted',
            Is_Active__c = isActive
        );
    }

    private static Id stepIdAtLevel(Id requestId, Integer level) {
        return [
            SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :requestId AND Level__c = :level
            LIMIT 1
        ].Id;
    }

    // ── getRecordApprovalState: no request yet ────────────────────────

    @isTest
    static void state_nullRecordId_returnsInactiveStateWithoutQuerying() {
        Test.startTest();
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(null);
        Test.stopTest();

        System.assertEquals(false, state.get('hasRequest'), 'No record means no request');
        System.assertEquals(false, state.get('canSubmit'), 'Nothing to submit without a record');
        System.assertEquals(false, state.containsKey('rulesAvailable'),
            'Null recordId should short-circuit before the rule count query');
    }

    @isTest
    static void state_noRulesConfigured_cannotSubmit() {
        Lead l = createLead();

        Test.startTest();
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        System.assertEquals(false, state.get('hasRequest'), 'Nothing submitted yet');
        System.assertEquals(false, state.get('canSubmit'), 'No rules — panel must hide Submit');
        System.assertEquals(0, state.get('rulesAvailable'), 'Zero active rules for Lead');
    }

    @isTest
    static void state_inactiveRuleDoesNotEnableSubmit() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id, false, false);

        Test.startTest();
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        System.assertEquals(0, state.get('rulesAvailable'), 'Is_Active__c = false must be excluded');
        System.assertEquals(false, state.get('canSubmit'), 'An inactive rule is not a usable rule');
    }

    @isTest
    static void state_ruleForAnotherObjectIsIgnored() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Account', 1, approver.Id);

        Test.startTest();
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        System.assertEquals(0, state.get('rulesAvailable'),
            'Rule count must be scoped to the object type of the record');
        System.assertEquals(false, state.get('canSubmit'), 'An Account rule cannot route a Lead');
    }

    @isTest
    static void state_activeRule_allowsSubmit() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);

        Test.startTest();
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        System.assertEquals(false, state.get('hasRequest'), 'Not submitted yet');
        System.assertEquals(true, state.get('canSubmit'), 'One active Lead rule — Submit is available');
        System.assertEquals(1, state.get('rulesAvailable'), 'Exactly one active rule');
    }

    // ── getRecordApprovalState: with a request ────────────────────────

    @isTest
    static void state_pendingRequest_submitterCanRecallButNotAct() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalRouter.submit(l.Id, 'Please review');

        Test.startTest();
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        System.assertEquals(true, state.get('hasRequest'), 'A request exists for this record');
        System.assertEquals(true, state.get('canRecall'), 'The submitter may recall a Pending request');
        System.assertEquals(false, state.get('canSubmitAgain'),
            'Re-submission is only offered after Rejected/Recalled');
        System.assertEquals(false, state.get('canAct'),
            'The submitter is not the approver, so no Approve/Reject buttons');
        System.assertEquals(null, state.get('currentStepId'),
            'No step id when the running user cannot act');
        System.assertEquals(UserInfo.getUserId(), state.get('currentUserId'),
            'Running user echoed back for the LWC');

        Approval_Request__c req = (Approval_Request__c) state.get('request');
        System.assertEquals(reqId, req.Id, 'The request for this record is returned');
        System.assertEquals('Pending', req.Status__c, 'Freshly submitted requests are Pending');
        System.assertEquals('Please review', req.Comments__c, 'Submit comments are carried through');
        System.assertEquals(approver.Id, req.Current_Approver__c, 'Level 1 approver is current');

        List<Approval_Step__c> steps = (List<Approval_Step__c>) state.get('steps');
        System.assertEquals(1, steps.size(), 'A single-level chain has one step');
        System.assertEquals(true, steps[0].Is_Current__c, 'The only step is the active one');
    }

    @isTest
    static void state_pendingRequest_currentApproverCanAct() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Id expectedStepId = stepIdAtLevel(reqId, 1);

        Test.startTest();
        Map<String, Object> state;
        System.runAs(approver) {
            state = ApprovalPanelController.getRecordApprovalState(l.Id);
        }
        Test.stopTest();

        System.assertEquals(true, state.get('canAct'), 'The current approver gets the action buttons');
        System.assertEquals(expectedStepId, state.get('currentStepId'),
            'The step id handed to approveStep/rejectStep must be the current one');
        System.assertEquals(false, state.get('canRecall'), 'Only the submitter can recall');
        System.assertEquals(approver.Id, state.get('currentUserId'), 'Running user is the approver');
    }

    @isTest
    static void state_multiLevel_stepsOrderedAndOnlyLevelOneActionable() {
        List<User> users = createUsers(2);
        User a1 = users[0];
        User a2 = users[1];
        Lead l = createLead();
        // Inserted out of order on purpose — the panel must sort by level.
        insert new List<Approval_Rule__c>{
            rule('Lead', 2, a2.Id),
            rule('Lead', 1, a1.Id)
        };
        ApprovalRouter.submit(l.Id, null);

        Test.startTest();
        Map<String, Object> asL2;
        System.runAs(a2) {
            asL2 = ApprovalPanelController.getRecordApprovalState(l.Id);
        }
        Test.stopTest();

        List<Approval_Step__c> steps = (List<Approval_Step__c>) asL2.get('steps');
        System.assertEquals(2, steps.size(), 'Two rules, two levels, two steps');
        System.assertEquals(1, steps[0].Level__c, 'Steps come back in level order for the timeline');
        System.assertEquals(2, steps[1].Level__c, 'Level 2 renders second');
        System.assertEquals(a1.Id, steps[0].Approver__c, 'Level 1 routed to the level 1 approver');

        System.assertEquals(false, asL2.get('canAct'),
            'The level 2 approver must wait — their step is not current yet');
        System.assertEquals(null, asL2.get('currentStepId'), 'No actionable step for the L2 approver');

        Approval_Request__c req = (Approval_Request__c) asL2.get('request');
        System.assertEquals(2, req.Total_Levels__c, 'Both levels counted');
        System.assertEquals(1, req.Current_Level__c, 'The chain starts at level 1');
    }

    @isTest
    static void state_rejectedRequest_allowsResubmission() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Id stepId = stepIdAtLevel(reqId, 1);

        Test.startTest();
        System.runAs(approver) { ApprovalPanelController.rejectStep(stepId, 'Not this time'); }
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        Approval_Request__c req = (Approval_Request__c) state.get('request');
        System.assertEquals('Rejected', req.Status__c, 'Rejection closes the request');
        System.assertEquals(true, state.get('canSubmitAgain'),
            'A rejected record can be fixed and re-submitted while rules exist');
        System.assertEquals(false, state.get('canRecall'), 'Nothing left to recall');
        System.assertEquals(false, state.get('canAct'), 'A closed request has no actionable step');
    }

    @isTest
    static void state_recalledRequest_allowsResubmission() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);

        Test.startTest();
        ApprovalPanelController.recallRequest(reqId);
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        Approval_Request__c req = (Approval_Request__c) state.get('request');
        System.assertEquals('Recalled', req.Status__c, 'Recall withdraws the request');
        System.assertEquals(true, state.get('canSubmitAgain'), 'Recalled records can be re-submitted');
        System.assertEquals(false, state.get('canRecall'), 'Already recalled');
    }

    @isTest
    static void state_approvedRequest_offersNoFurtherAction() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalRouter.submit(l.Id, null);
        Id stepId = stepIdAtLevel(reqId, 1);

        Test.startTest();
        System.runAs(approver) { ApprovalPanelController.approveStep(stepId, 'Looks good'); }
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        Approval_Request__c req = (Approval_Request__c) state.get('request');
        System.assertEquals('Approved', req.Status__c, 'The last level approved completes the chain');
        System.assertNotEquals(null, req.Completed_Date__c, 'Completion is stamped');
        System.assertEquals(false, state.get('canRecall'), 'Cannot recall an approved request');
        System.assertEquals(false, state.get('canSubmitAgain'), 'Nothing to re-submit once approved');
        System.assertEquals(false, state.get('canAct'), 'No pending step remains');
    }

    @isTest
    static void state_returnsMostRecentRequestOnly() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);

        Id firstReqId = ApprovalRouter.submit(l.Id, 'First attempt');
        ApprovalRouter.recall(firstReqId);
        // Age the first request so ORDER BY CreatedDate DESC is unambiguous —
        // records created in one test transaction share a CreatedDate.
        Test.setCreatedDate(firstReqId, Datetime.now().addDays(-2));

        Id secondReqId = ApprovalRouter.submit(l.Id, 'Second attempt');

        Test.startTest();
        Map<String, Object> state = ApprovalPanelController.getRecordApprovalState(l.Id);
        Test.stopTest();

        Approval_Request__c req = (Approval_Request__c) state.get('request');
        System.assertEquals(secondReqId, req.Id, 'The panel shows the latest request, not the history');
        System.assertEquals('Second attempt', req.Comments__c, 'Comments of the latest request');
        System.assertEquals(true, state.get('canRecall'), 'The latest request is Pending again');

        List<Approval_Step__c> steps = (List<Approval_Step__c>) state.get('steps');
        System.assertEquals(1, steps.size(), 'Only the steps of the latest request are returned');
    }

    // ── Delegating methods ────────────────────────────────────────────

    @isTest
    static void submitRecord_createsRequestThroughRouter() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);

        Test.startTest();
        Id reqId = ApprovalPanelController.submitRecord(l.Id, 'From the panel');
        Test.stopTest();

        System.assertNotEquals(null, reqId, 'The controller returns the new request id to the LWC');
        Approval_Request__c req = [
            SELECT Status__c, Record_Id__c, Object_Type__c, Comments__c, Submitted_By__c
            FROM Approval_Request__c WHERE Id = :reqId
        ];
        System.assertEquals('Pending', req.Status__c, 'Submitted requests start Pending');
        System.assertEquals(String.valueOf(l.Id), req.Record_Id__c, 'Linked back to the source record');
        System.assertEquals('Lead', req.Object_Type__c, 'Object type resolved from the record id');
        System.assertEquals('From the panel', req.Comments__c, 'Comments passed straight through');
        System.assertEquals(UserInfo.getUserId(), req.Submitted_By__c, 'Running user is the submitter');
    }

    @isTest
    static void submitRecord_withoutRules_throwsHandledException() {
        Lead l = createLead();

        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalPanelController.submitRecord(l.Id, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'Submitting with no configured rule must raise an AuraHandledException');
        System.assertEquals(0, [SELECT COUNT() FROM Approval_Request__c], 'Nothing is persisted');
    }

    @isTest
    static void submitRecord_whileAlreadyPending_throwsHandledException() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        ApprovalPanelController.submitRecord(l.Id, null);

        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalPanelController.submitRecord(l.Id, 'Double click');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A second submit while one is Pending must be blocked');
        System.assertEquals(1, [SELECT COUNT() FROM Approval_Request__c], 'No duplicate request created');
    }

    @isTest
    static void approveStep_recordsDecision() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalPanelController.submitRecord(l.Id, null);
        Id stepId = stepIdAtLevel(reqId, 1);

        Test.startTest();
        System.runAs(approver) { ApprovalPanelController.approveStep(stepId, 'Approved by me'); }
        Test.stopTest();

        Approval_Step__c step = [
            SELECT Status__c, Is_Current__c, Comments__c, Decision_Date__c
            FROM Approval_Step__c WHERE Id = :stepId
        ];
        System.assertEquals('Approved', step.Status__c, 'The step is marked Approved');
        System.assertEquals(false, step.Is_Current__c, 'A decided step is no longer current');
        System.assertEquals('Approved by me', step.Comments__c, 'Approver comments are stored');
        System.assertNotEquals(null, step.Decision_Date__c, 'The decision is timestamped');

        System.assertEquals('Approved',
            [SELECT Status__c FROM Approval_Request__c WHERE Id = :reqId].Status__c,
            'The only level completes the request');
    }

    @isTest
    static void approveStep_byNonApprover_throwsHandledException() {
        List<User> users = createUsers(2);
        User approver = users[0];
        User bystander = users[1];
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalPanelController.submitRecord(l.Id, null);
        Id stepId = stepIdAtLevel(reqId, 1);

        Test.startTest();
        Boolean threw = false;
        System.runAs(bystander) {
            try {
                ApprovalPanelController.approveStep(stepId, 'Not mine to approve');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assert(threw, 'Only the assigned approver may approve a step');
        System.assertEquals('Pending',
            [SELECT Status__c FROM Approval_Step__c WHERE Id = :stepId].Status__c,
            'The step is untouched after a blocked approval');
    }

    @isTest
    static void approveStep_nullStepId_throwsHandledException() {
        Test.startTest();
        Boolean threw = false;
        try {
            ApprovalPanelController.approveStep(null, 'No step');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'A missing step id must be rejected, not silently ignored');
    }

    @isTest
    static void rejectStep_closesRequestAndSkipsRemainingLevels() {
        List<User> users = createUsers(2);
        User a1 = users[0];
        User a2 = users[1];
        Lead l = createLead();
        insert new List<Approval_Rule__c>{
            rule('Lead', 1, a1.Id),
            rule('Lead', 2, a2.Id)
        };
        Id reqId = ApprovalPanelController.submitRecord(l.Id, null);
        Id step1 = stepIdAtLevel(reqId, 1);

        Test.startTest();
        System.runAs(a1) { ApprovalPanelController.rejectStep(step1, 'Numbers are wrong'); }
        Test.stopTest();

        System.assertEquals('Rejected',
            [SELECT Status__c FROM Approval_Step__c WHERE Id = :step1].Status__c,
            'The acted-on step is Rejected');
        System.assertEquals('Skipped',
            [SELECT Status__c FROM Approval_Step__c
             WHERE Approval_Request__c = :reqId AND Level__c = 2].Status__c,
            'Downstream levels are skipped, not left Pending');

        Approval_Request__c req = [
            SELECT Status__c, Current_Approver__c FROM Approval_Request__c WHERE Id = :reqId
        ];
        System.assertEquals('Rejected', req.Status__c, 'Rejection closes the whole request');
        System.assertEquals(null, req.Current_Approver__c, 'No one is left holding the request');
    }

    @isTest
    static void recallRequest_withdrawsPendingRequest() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalPanelController.submitRecord(l.Id, null);

        Test.startTest();
        ApprovalPanelController.recallRequest(reqId);
        Test.stopTest();

        Approval_Request__c req = [
            SELECT Status__c, Completed_Date__c, Current_Approver__c
            FROM Approval_Request__c WHERE Id = :reqId
        ];
        System.assertEquals('Recalled', req.Status__c, 'The submitter withdrew the request');
        System.assertNotEquals(null, req.Completed_Date__c, 'Recall stamps a completion date');
        System.assertEquals(null, req.Current_Approver__c, 'The approver is cleared on recall');
        System.assertEquals('Skipped',
            [SELECT Status__c FROM Approval_Step__c WHERE Approval_Request__c = :reqId].Status__c,
            'The pending step leaves the inbox of the approver');
    }

    @isTest
    static void recallRequest_byNonSubmitter_throwsHandledException() {
        List<User> users = createUsers(2);
        User approver = users[0];
        User bystander = users[1];
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalPanelController.submitRecord(l.Id, null);

        Test.startTest();
        Boolean threw = false;
        System.runAs(bystander) {
            try {
                ApprovalPanelController.recallRequest(reqId);
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assert(threw, 'Only the submitter may recall');
        System.assertEquals('Pending',
            [SELECT Status__c FROM Approval_Request__c WHERE Id = :reqId].Status__c,
            'A blocked recall leaves the request Pending');
    }

    // ── getMyPendingApprovals ─────────────────────────────────────────

    @isTest
    static void inbox_returnsCurrentStepsForRunningUser() {
        User approver = createUser();
        Lead l = createLead();
        insert new List<Approval_Rule__c>{
            rule('Lead', 1, approver.Id),
            rule('Lead', 2, approver.Id)
        };
        Id reqId = ApprovalPanelController.submitRecord(l.Id, 'Inbox check');
        Id step1 = stepIdAtLevel(reqId, 1);

        Test.startTest();
        List<Map<String, Object>> rows;
        System.runAs(approver) {
            rows = ApprovalPanelController.getMyPendingApprovals();
        }
        Test.stopTest();

        System.assertEquals(1, rows.size(),
            'Only the current step shows in the inbox — level 2 is not actionable yet');
        Map<String, Object> row = rows[0];
        System.assertEquals(step1, row.get('stepId'), 'The row carries the step id the LWC acts on');
        System.assertEquals(reqId, row.get('requestId'), 'The row links to its request');
        System.assertEquals('Lead', row.get('objectType'), 'Object type surfaced for the icon/link');
        System.assertEquals(String.valueOf(l.Id), row.get('recordId'), 'The row links to the source record');
        System.assertEquals(1, row.get('level'), 'Current level');
        System.assertEquals(2, row.get('totalLevels'), 'Total levels for the "1 of 2" badge');
        System.assertNotEquals(null, row.get('requestName'), 'Request name is populated');
        System.assertNotEquals(null, row.get('submittedDate'), 'Submitted date drives the sort');
        System.assert(String.isNotBlank((String) row.get('submittedBy')),
            'Submitter name is resolved for display');
    }

    @isTest
    static void inbox_isEmptyForUsersWithNothingAssigned() {
        List<User> users = createUsers(2);
        User approver = users[0];
        User bystander = users[1];
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        ApprovalPanelController.submitRecord(l.Id, null);

        Test.startTest();
        List<Map<String, Object>> rows;
        System.runAs(bystander) {
            rows = ApprovalPanelController.getMyPendingApprovals();
        }
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'The inbox is strictly scoped to the running user');
    }

    @isTest
    static void inbox_handsOffToNextLevelAfterApproval() {
        List<User> users = createUsers(2);
        User a1 = users[0];
        User a2 = users[1];
        Lead l = createLead();
        insert new List<Approval_Rule__c>{
            rule('Lead', 1, a1.Id),
            rule('Lead', 2, a2.Id)
        };
        Id reqId = ApprovalPanelController.submitRecord(l.Id, null);
        Id step1 = stepIdAtLevel(reqId, 1);

        Test.startTest();
        System.runAs(a1) { ApprovalPanelController.approveStep(step1, 'L1 done'); }

        List<Map<String, Object>> a1Rows;
        List<Map<String, Object>> a2Rows;
        System.runAs(a1) { a1Rows = ApprovalPanelController.getMyPendingApprovals(); }
        System.runAs(a2) { a2Rows = ApprovalPanelController.getMyPendingApprovals(); }
        Test.stopTest();

        System.assertEquals(0, a1Rows.size(), 'A decided step drops out of the inbox');
        System.assertEquals(1, a2Rows.size(), 'The level 2 approver now has the request');
        System.assertEquals(2, a2Rows[0].get('level'), 'Handed to level 2');
        System.assertEquals(stepIdAtLevel(reqId, 2), a2Rows[0].get('stepId'), 'Level 2 step id');
    }

    @isTest
    static void inbox_excludesClosedRequests() {
        User approver = createUser();
        Lead l = createLead();
        insert rule('Lead', 1, approver.Id);
        Id reqId = ApprovalPanelController.submitRecord(l.Id, null);

        Test.startTest();
        ApprovalPanelController.recallRequest(reqId);
        List<Map<String, Object>> rows;
        System.runAs(approver) {
            rows = ApprovalPanelController.getMyPendingApprovals();
        }
        Test.stopTest();

        System.assertEquals(0, rows.size(), 'Recalled requests must disappear from the inbox');
    }
}