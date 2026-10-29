/**
 * @description Tests for DynamicApprovalEngine, the deprecated shim in front of
 * ApprovalRouter.
 *
 * A forwarding class is worth testing for exactly one reason: to prove it still
 * forwards. Nothing in Apex calls it any more — it survives only for Flows,
 * processes and org-side customisations that are still bound to the old name,
 * and those callers are invisible to the compiler. If a signature drifts or a
 * method quietly stops delegating, nothing in the codebase would notice; the
 * first sign would be an approval that silently never routes.
 *
 * So each test drives the shim and then asserts against the records
 * ApprovalRouter produces, rather than mocking the call.
 *
 * One behaviour change from the old engine is pinned deliberately:
 * submit(recordId, submittedBy) no longer honours submittedBy. Anything still
 * passing a different user there is being ignored, which matters because the
 * audit trail records the running user instead.
 */
@isTest
private class DynamicApprovalEngineTest {

    private static Integer userSeq = 0;

    // ── Fixtures ──────────────────────────────────────────────────────

    /**
     * User is a setup object, so its DML is isolated inside System.runAs —
     * otherwise the Lead and rule inserts that follow trip MIXED_DML_OPERATION.
     * FSCRM_Admin is assigned (when present) so a Standard User can read the
     * approval objects while acting on a step.
     */
    private static List<User> newUsers(Integer count) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (Integer i = 0; i < count; i++) {
            userSeq++;
            String alias = 'dae' + userSeq;
            users.add(new User(
                ProfileId = p.Id,
                Alias = alias,
                Email = alias + '@dae.test',
                EmailEncodingKey = 'UTF-8',
                FirstName = 'Shim',
                LastName = 'User' + userSeq,
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'America/Los_Angeles',
                Username = alias + System.currentTimeMillis() + '@dae.test'
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
        return [SELECT Id, Name FROM User WHERE Id IN :users ORDER BY LastName];
    }

    private static Lead newLead() {
        Lead l = new Lead(
            LastName = 'Shim',
            Company = 'Acme Trading',
            Status = 'Open - Not Contacted',
            NumberOfEmployees = 100
        );
        insert l;
        return l;
    }

    /** A rule with no status mapping, so tests stay off the source record. */
    private static Approval_Rule__c ruleFor(Id approverId, Integer level) {
        return new Approval_Rule__c(
            Object_Process__c = 'Lead',
            Approval_Level__c = level,
            Approver_Type__c = 'User',
            User__c = approverId,
            Auto_Approve__c = false,
            Is_Active__c = true
        );
    }

    private static Id stepIdFor(Id requestId) {
        return [SELECT Id FROM Approval_Step__c WHERE Approval_Request__c = :requestId LIMIT 1].Id;
    }

    // ── submitForApproval ─────────────────────────────────────────────

    @isTest
    static void submitForApproval_routesThroughTheRouter() {
        User approver = newUsers(1)[0];
        Lead l = newLead();
        insert ruleFor(approver.Id, 1);

        Test.startTest();
        Id requestId = DynamicApprovalEngine.submitForApproval(l.Id);
        Test.stopTest();

        System.assertNotEquals(null, requestId, 'The shim returns the new request id');
        Approval_Request__c req = [
            SELECT Status__c, Object_Type__c, Record_Id__c, Current_Approver__c, Submitted_By__c
            FROM Approval_Request__c WHERE Id = :requestId
        ];
        System.assertEquals('Pending', req.Status__c, 'A real request was created, not a stub');
        System.assertEquals('Lead', req.Object_Type__c, 'Routed against the right object');
        System.assertEquals(String.valueOf(l.Id), req.Record_Id__c, 'And the right record');
        System.assertEquals(approver.Id, req.Current_Approver__c, 'The rule resolved an approver');
        System.assertEquals(1, [SELECT COUNT() FROM Approval_Step__c
            WHERE Approval_Request__c = :requestId], 'Steps were created too');
    }

    @isTest
    static void submitForApproval_withNoRules_letTheRouterErrorThrough() {
        Lead l = newLead();

        Test.startTest();
        Boolean threw = false;
        try {
            DynamicApprovalEngine.submitForApproval(l.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'The shim must not swallow the router error — an old Flow needs to see the '
            + 'same failure it would get from ApprovalRouter');
        System.assertEquals(0, [SELECT COUNT() FROM Approval_Request__c], 'Nothing created');
    }

    // ── submit(recordId, submittedBy) ─────────────────────────────────

    @isTest
    static void submit_ignoresTheSubmittedByArgument() {
        List<User> users = newUsers(2);
        User approver = users[0];
        User pretendSubmitter = users[1];
        Lead l = newLead();
        insert ruleFor(approver.Id, 1);

        Test.startTest();
        Id requestId = DynamicApprovalEngine.submit(l.Id, pretendSubmitter.Id);
        Test.stopTest();

        Approval_Request__c req = [
            SELECT Submitted_By__c FROM Approval_Request__c WHERE Id = :requestId
        ];
        System.assertEquals(UserInfo.getUserId(), req.Submitted_By__c,
            'The submittedBy argument is deliberately dropped — the audit trail records who '
            + 'actually ran the submission');
        System.assertNotEquals(pretendSubmitter.Id, req.Submitted_By__c,
            'A caller still passing another user is being ignored, not honoured');
    }

    // ── submitForApprovalFlow ─────────────────────────────────────────

    @isTest
    static void flowEntry_forwardsEveryUsableRequest() {
        User approver = newUsers(1)[0];
        Lead first = newLead();
        Lead second = newLead();
        insert ruleFor(approver.Id, 1);

        DynamicApprovalEngine.SubmitRequest a = new DynamicApprovalEngine.SubmitRequest();
        a.recordId = first.Id;
        DynamicApprovalEngine.SubmitRequest b = new DynamicApprovalEngine.SubmitRequest();
        b.recordId = second.Id;

        Test.startTest();
        DynamicApprovalEngine.submitForApprovalFlow(
            new List<DynamicApprovalEngine.SubmitRequest>{ a, b });
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Approval_Request__c],
            'Both records routed — the shim forwards the whole batch, not just the first');
    }

    @isTest
    static void flowEntry_skipsBlankRecordIds() {
        User approver = newUsers(1)[0];
        Lead l = newLead();
        insert ruleFor(approver.Id, 1);

        DynamicApprovalEngine.SubmitRequest good = new DynamicApprovalEngine.SubmitRequest();
        good.recordId = l.Id;
        DynamicApprovalEngine.SubmitRequest blank = new DynamicApprovalEngine.SubmitRequest();
        blank.recordId = null;

        Test.startTest();
        DynamicApprovalEngine.submitForApprovalFlow(
            new List<DynamicApprovalEngine.SubmitRequest>{ blank, good, blank });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Approval_Request__c],
            'A Flow loop that produced an empty row must not stop the usable ones routing');
    }

    @isTest
    static void flowEntry_withNothingToDo_isANoOp() {
        User approver = newUsers(1)[0];
        insert ruleFor(approver.Id, 1);

        DynamicApprovalEngine.SubmitRequest blank = new DynamicApprovalEngine.SubmitRequest();
        blank.recordId = null;

        Test.startTest();
        DynamicApprovalEngine.submitForApprovalFlow(null);
        DynamicApprovalEngine.submitForApprovalFlow(
            new List<DynamicApprovalEngine.SubmitRequest>());
        DynamicApprovalEngine.submitForApprovalFlow(
            new List<DynamicApprovalEngine.SubmitRequest>{ blank });
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Approval_Request__c],
            'A null list, an empty list and a list of blanks all route nothing and throw nothing');
    }

    // ── Decisions ─────────────────────────────────────────────────────

    @isTest
    static void approve_forwardsAndCompletesTheChain() {
        User approver = newUsers(1)[0];
        Lead l = newLead();
        insert ruleFor(approver.Id, 1);
        Id requestId = DynamicApprovalEngine.submitForApproval(l.Id);
        Id stepId = stepIdFor(requestId);

        Test.startTest();
        System.runAs(approver) { DynamicApprovalEngine.approve(stepId, 'Approved via the shim'); }
        Test.stopTest();

        Approval_Step__c step = [
            SELECT Status__c, Comments__c FROM Approval_Step__c WHERE Id = :stepId
        ];
        System.assertEquals('Approved', step.Status__c, 'The decision was recorded');
        System.assertEquals('Approved via the shim', step.Comments__c,
            'Comments are passed through, not dropped by the shim');
        System.assertEquals('Approved',
            [SELECT Status__c FROM Approval_Request__c WHERE Id = :requestId].Status__c,
            'And the chain completed, so processChain ran');
    }

    @isTest
    static void reject_forwardsAndClosesTheRequest() {
        List<User> users = newUsers(2);
        Lead l = newLead();
        insert new List<Approval_Rule__c>{
            ruleFor(users[0].Id, 1),
            ruleFor(users[1].Id, 2)
        };
        Id requestId = DynamicApprovalEngine.submitForApproval(l.Id);
        Id levelOne = [SELECT Id FROM Approval_Step__c
            WHERE Approval_Request__c = :requestId AND Level__c = 1].Id;

        Test.startTest();
        System.runAs(users[0]) { DynamicApprovalEngine.reject(levelOne, 'Not this time'); }
        Test.stopTest();

        System.assertEquals('Rejected',
            [SELECT Status__c FROM Approval_Request__c WHERE Id = :requestId].Status__c,
            'Rejection closed the request');
        System.assertEquals('Skipped',
            [SELECT Status__c FROM Approval_Step__c
             WHERE Approval_Request__c = :requestId AND Level__c = 2].Status__c,
            'And downstream levels were skipped, so the full router logic ran');
    }

    @isTest
    static void reject_byTheWrongUser_stillGuards() {
        List<User> users = newUsers(2);
        Lead l = newLead();
        insert ruleFor(users[0].Id, 1);
        Id requestId = DynamicApprovalEngine.submitForApproval(l.Id);
        Id stepId = stepIdFor(requestId);

        Test.startTest();
        Boolean threw = false;
        System.runAs(users[1]) {
            try {
                DynamicApprovalEngine.reject(stepId, 'Not mine to reject');
            } catch (AuraHandledException e) {
                threw = true;
            }
        }
        Test.stopTest();

        System.assert(threw,
            'Going through the deprecated entry point must not bypass the approver check');
        System.assertEquals('Pending',
            [SELECT Status__c FROM Approval_Step__c WHERE Id = :stepId].Status__c,
            'The step is untouched');
    }

    @isTest
    static void recall_forwardsAndWithdrawsTheRequest() {
        User approver = newUsers(1)[0];
        Lead l = newLead();
        insert ruleFor(approver.Id, 1);
        Id requestId = DynamicApprovalEngine.submitForApproval(l.Id);

        Test.startTest();
        DynamicApprovalEngine.recall(requestId);
        Test.stopTest();

        Approval_Request__c req = [
            SELECT Status__c, Current_Approver__c FROM Approval_Request__c WHERE Id = :requestId
        ];
        System.assertEquals('Recalled', req.Status__c, 'The submitter withdrew it');
        System.assertEquals(null, req.Current_Approver__c, 'And nobody is left holding it');
        System.assertEquals('Skipped',
            [SELECT Status__c FROM Approval_Step__c WHERE Approval_Request__c = :requestId].Status__c,
            'The pending step left the approver inbox');
    }

    // ── getMyApprovals ────────────────────────────────────────────────

    @isTest
    static void getMyApprovals_forwardsAndIsScopedToTheRunningUser() {
        List<User> users = newUsers(2);
        User approver = users[0];
        User bystander = users[1];
        Lead l = newLead();
        insert ruleFor(approver.Id, 1);
        Id requestId = DynamicApprovalEngine.submitForApproval(l.Id);
        Id stepId = stepIdFor(requestId);

        Test.startTest();
        List<Approval_Step__c> mine;
        List<Approval_Step__c> theirs;
        System.runAs(approver) { mine = DynamicApprovalEngine.getMyApprovals(); }
        System.runAs(bystander) { theirs = DynamicApprovalEngine.getMyApprovals(); }
        Test.stopTest();

        System.assertEquals(1, mine.size(), 'The approver sees their pending step');
        System.assertEquals(stepId, mine[0].Id, 'And it is the right one');
        System.assertEquals(0, theirs.size(),
            'The inbox is still scoped to the running user through the shim');
    }
}