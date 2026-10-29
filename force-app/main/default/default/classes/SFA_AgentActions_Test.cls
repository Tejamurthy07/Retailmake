/**
 * @description Coverage for the SFA Field Copilot Agentforce actions. Invokes
 *              each action exactly as Agentforce does — List<Request> in,
 *              List<Response> out — and asserts the response shape, including
 *              the with-sharing access guard.
 */
@IsTest
private class SFA_AgentActions_Test {

    private static List<SFA_AgentActions.OutletRequest> reqFor(Id accountId) {
        SFA_AgentActions.OutletRequest req = new SFA_AgentActions.OutletRequest();
        req.accountId = accountId;
        return new List<SFA_AgentActions.OutletRequest>{ req };
    }

    @IsTest
    static void allThreeActions_returnGroundedSummary() {
        Account outlet = TestDataFactory.createAndInsertAccount('Copilot Test Outlet', 'Retailer');
        List<SFA_AgentActions.OutletRequest> reqs = reqFor(outlet.Id);

        Test.startTest();
        SFA_AgentActions.OutletBriefing brief = SFA_OutletBriefingAction.run(reqs)[0];
        SFA_AgentActions.SellSuggestions sell = SFA_WhatToSellAction.run(reqs)[0];
        SFA_AgentActions.OutstandingSummary owed = SFA_OutstandingAction.run(reqs)[0];
        Test.stopTest();

        System.assertEquals(true, brief.hasAccess, 'Briefing should see an accessible outlet');
        System.assertEquals('Copilot Test Outlet', brief.outletName, 'Briefing names the outlet');
        System.assertNotEquals(null, brief.summary, 'Briefing carries a narratable summary');

        System.assertEquals(true, sell.hasAccess, 'Suggestions should see an accessible outlet');
        System.assertNotEquals(null, sell.mustSellProducts, 'Must-sell text is always initialised');
        System.assertNotEquals(null, sell.summary, 'Suggestions carry a summary');

        System.assertEquals(true, owed.hasAccess, 'Outstanding should see an accessible outlet');
        System.assertNotEquals(null, owed.openInvoices, 'Open-invoice text is always initialised');
        System.assertNotEquals(null, owed.summary, 'Outstanding carries a summary');
    }

    @IsTest
    static void nullAccount_isRefusedNotLeaked() {
        List<SFA_AgentActions.OutletRequest> reqs = reqFor(null);

        Test.startTest();
        SFA_AgentActions.OutletBriefing brief = SFA_OutletBriefingAction.run(reqs)[0];
        SFA_AgentActions.SellSuggestions sell = SFA_WhatToSellAction.run(reqs)[0];
        SFA_AgentActions.OutstandingSummary owed = SFA_OutstandingAction.run(reqs)[0];
        Test.stopTest();

        System.assertEquals(false, brief.hasAccess, 'No id -> no access');
        System.assertEquals(false, sell.hasAccess, 'No id -> no access');
        System.assertEquals(false, owed.hasAccess, 'No id -> no access');
        System.assert(brief.summary.contains('not found') || brief.summary.contains('access'),
            'Refusal explains itself: ' + brief.summary);
    }

    @IsTest
    static void findOutlet_resolvesNameToIdAndChains() {
        Account outlet = TestDataFactory.createAndInsertAccount('Findable Kirana', 'Retailer');

        Test.startTest();
        SFA_FindOutletAction.FindRequest fr = new SFA_FindOutletAction.FindRequest();
        fr.searchText = 'Findable';
        SFA_FindOutletAction.FindResult found = SFA_FindOutletAction.run(
            new List<SFA_FindOutletAction.FindRequest>{ fr })[0];
        Test.stopTest();

        System.assertEquals(1, found.matchCount, 'Should find the one outlet by partial name');
        System.assertEquals(outlet.Id, found.accountId, 'Returns the matching account id for chaining');
        System.assertEquals('Findable Kirana', found.outletName, 'Returns the outlet name');
        System.assert(found.matches.contains('Findable Kirana'), 'Match text names the outlet: ' + found.matches);
    }

    @IsTest
    static void findOutlet_handlesNoMatchAndBlank() {
        Test.startTest();
        SFA_FindOutletAction.FindRequest none = new SFA_FindOutletAction.FindRequest();
        none.searchText = 'Zzz Nonexistent Outlet Name';
        SFA_FindOutletAction.FindResult noMatch = SFA_FindOutletAction.run(
            new List<SFA_FindOutletAction.FindRequest>{ none })[0];

        SFA_FindOutletAction.FindRequest blank = new SFA_FindOutletAction.FindRequest();
        blank.searchText = '   ';
        SFA_FindOutletAction.FindResult blankRes = SFA_FindOutletAction.run(
            new List<SFA_FindOutletAction.FindRequest>{ blank })[0];
        Test.stopTest();

        System.assertEquals(0, noMatch.matchCount, 'No match returns zero');
        System.assertEquals(null, noMatch.accountId, 'No match has no id');
        System.assert(blankRes.summary.contains('name'), 'Blank asks for a name: ' + blankRes.summary);
    }

    @IsTest
    static void nullAndEmptyRequests_areSafe() {
        Test.startTest();
        System.assertEquals(0, SFA_OutletBriefingAction.run(null).size(), 'Null request list is safe');
        System.assertEquals(0, SFA_WhatToSellAction.run(
            new List<SFA_AgentActions.OutletRequest>()).size(), 'Empty request list is safe');
        Test.stopTest();
    }
}