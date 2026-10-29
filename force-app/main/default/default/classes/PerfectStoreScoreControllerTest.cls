/**
 * @description Tests for PerfectStoreScoreController — the Perfect Store Score
 * dashboard's KPIs and its outlet / territory / rep leaderboards.
 *
 * The numbers here drive incentive conversations, so the assertions are exact:
 * the average, the perfect-store count at the >= 85 threshold, the
 * distinct-outlet count, and the descending order of every leaderboard.
 * In-progress responses are excluded everywhere — an audit half-filled on a
 * phone must not move anyone's score.
 */
@isTest
private class PerfectStoreScoreControllerTest {

    @testSetup
    static void setupTestData() {
        insert new List<Account>{
            TestDataFactory.createAccount('PSS Outlet One', 'Retailer'),
            TestDataFactory.createAccount('PSS Outlet Two', 'Retailer')
        };

        insert new List<Survey__c>{
            new Survey__c(Name = 'PSS Monthly Audit', Survey_Type__c = 'Outlet Audit', Is_Active__c = true),
            new Survey__c(Name = 'PSS Quarterly Audit', Survey_Type__c = 'Outlet Audit', Is_Active__c = true),
            new Survey__c(Name = 'PSS Retired Audit', Survey_Type__c = 'Outlet Audit', Is_Active__c = false),
            new Survey__c(Name = 'PSS Feedback Form', Survey_Type__c = 'Customer Feedback', Is_Active__c = true)
        };
    }

    // ── Fixtures ──────────────────────────────────────────────────────

    private static Map<String, Id> cachedAccounts;
    private static Map<String, Id> cachedSurveys;

    private static Id outlet(String name) {
        if (cachedAccounts == null) {
            cachedAccounts = new Map<String, Id>();
            for (Account a : [SELECT Id, Name FROM Account WHERE Name LIKE 'PSS Outlet%']) {
                cachedAccounts.put(a.Name, a.Id);
            }
        }
        return cachedAccounts.get(name);
    }

    private static Id survey(String name) {
        if (cachedSurveys == null) {
            cachedSurveys = new Map<String, Id>();
            for (Survey__c s : [SELECT Id, Name FROM Survey__c WHERE Name LIKE 'PSS%']) {
                cachedSurveys.put(s.Name, s.Id);
            }
        }
        return cachedSurveys.get(name);
    }

    private static Survey_Response__c response(
            Id surveyId, Id accountId, Decimal score, Integer daysAgo, String status) {
        return new Survey_Response__c(
            Survey__c = surveyId,
            Account__c = accountId,
            Respondent__c = UserInfo.getUserId(),
            Score_Percentage__c = score,
            Status__c = status,
            Response_Date__c = Datetime.now().addDays(-daysAgo)
        );
    }

    private static Survey_Response__c completed(Id surveyId, Id accountId, Decimal score, Integer daysAgo) {
        return response(surveyId, accountId, score, daysAgo, 'Completed');
    }

    // ── getSurveyOptions ──────────────────────────────────────────────

    @isTest
    static void surveyOptions_listActiveAuditsBehindTheAllOption() {
        Test.startTest();
        List<Map<String, Object>> opts = PerfectStoreScoreController.getSurveyOptions();
        Test.stopTest();

        System.assertEquals('All Audit Surveys', opts[0].get('label'),
            'The All option leads so the dashboard defaults to everything');
        System.assertEquals('', opts[0].get('value'), 'With an empty value the filter treats as no-op');

        Set<Object> labels = new Set<Object>();
        for (Map<String, Object> o : opts) labels.add(o.get('label'));
        System.assert(labels.contains('PSS Monthly Audit'), 'Active audits are offered');
        System.assert(labels.contains('PSS Quarterly Audit'), 'All of them');
        System.assert(!labels.contains('PSS Retired Audit'),
            'A retired audit is not offered as a filter');
        System.assert(!labels.contains('PSS Feedback Form'),
            'And a non-audit survey type never belongs on this dashboard');
    }

    // ── getScoreKPIs ──────────────────────────────────────────────────

    @isTest
    static void kpis_computeAverageThresholdAndDistinctOutlets() {
        Id audit = survey('PSS Monthly Audit');
        insert new List<Survey_Response__c>{
            completed(audit, outlet('PSS Outlet One'), 90, 5),
            completed(audit, outlet('PSS Outlet One'), 80, 4),
            completed(audit, outlet('PSS Outlet Two'), 85, 3),
            // Half-filled audit — must count nowhere.
            response(audit, outlet('PSS Outlet Two'), 100, 2, 'In Progress')
        };

        Test.startTest();
        PerfectStoreScoreController.PerfectStoreKPIs k =
            PerfectStoreScoreController.getScoreKPIs(null, null, null);
        Test.stopTest();

        System.assertEquals(85.0, k.avgScore, '(90 + 80 + 85) / 3 — the In Progress 100 is out');
        System.assertEquals(3, k.totalAudits, 'Three completed audits');
        System.assertEquals(2, k.outletsAudited,
            'Two DISTINCT outlets — one outlet audited twice is still one outlet');
        System.assertEquals(2, k.perfectStores,
            'The threshold is inclusive: 90 and 85 qualify at >= 85, the 80 does not');
        System.assertEquals(85, k.threshold, 'And the threshold rides along for the gauge');
    }

    @isTest
    static void kpis_onAnEmptyOrg_areZeroWithTheThresholdStillSet() {
        Test.startTest();
        PerfectStoreScoreController.PerfectStoreKPIs k =
            PerfectStoreScoreController.getScoreKPIs(null, null, null);
        Test.stopTest();

        System.assertEquals(0, k.avgScore, 'No audits, zero average — not null');
        System.assertEquals(0, k.totalAudits, 'Nothing counted');
        System.assertEquals(0, k.perfectStores, 'Nothing perfect');
        System.assertEquals(85, k.threshold,
            'The threshold is configuration, not data — it renders even on an empty dashboard');
    }

    @isTest
    static void kpis_respectTheSurveyFilter() {
        insert new List<Survey_Response__c>{
            completed(survey('PSS Monthly Audit'), outlet('PSS Outlet One'), 90, 5),
            completed(survey('PSS Quarterly Audit'), outlet('PSS Outlet One'), 50, 4)
        };

        Test.startTest();
        PerfectStoreScoreController.PerfectStoreKPIs monthly =
            PerfectStoreScoreController.getScoreKPIs(String.valueOf(survey('PSS Monthly Audit')), null, null);
        PerfectStoreScoreController.PerfectStoreKPIs all =
            PerfectStoreScoreController.getScoreKPIs('', null, null);
        Test.stopTest();

        System.assertEquals(1, monthly.totalAudits, 'Only the monthly audit counts when filtered');
        System.assertEquals(90.0, monthly.avgScore, 'At its own score');
        System.assertEquals(2, all.totalAudits, 'A blank filter means all audit surveys');
        System.assertEquals(70.0, all.avgScore, 'Averaged across both');
    }

    @isTest
    static void kpis_respectTheDateWindowInclusively() {
        Id audit = survey('PSS Monthly Audit');
        insert new List<Survey_Response__c>{
            completed(audit, outlet('PSS Outlet One'), 90, 10),   // before the window
            completed(audit, outlet('PSS Outlet One'), 80, 5),    // inside
            completed(audit, outlet('PSS Outlet Two'), 70, 0)     // today — the end bound
        };

        Test.startTest();
        PerfectStoreScoreController.PerfectStoreKPIs windowed =
            PerfectStoreScoreController.getScoreKPIs(
                null, Date.today().addDays(-7), Date.today());
        Test.stopTest();

        System.assertEquals(2, windowed.totalAudits,
            'The ten-day-old audit is out; the five-day-old one and TODAY both count — the '
            + 'end date is inclusive, implemented as < end + 1 day');
        System.assertEquals(75.0, windowed.avgScore, '(80 + 70) / 2');
    }

    // ── getOutletRanking ──────────────────────────────────────────────

    @isTest
    static void outletRanking_ordersByAverageWithCountsAndTerritory() {
        Id audit = survey('PSS Monthly Audit');
        insert new List<Survey_Response__c>{
            completed(audit, outlet('PSS Outlet One'), 90, 5),
            completed(audit, outlet('PSS Outlet One'), 70, 4),    // One averages 80
            completed(audit, outlet('PSS Outlet Two'), 88, 3),    // Two averages 88
            // No outlet at all — the ranking must skip it, not render a blank row.
            response(audit, null, 95, 2, 'Completed')
        };

        Test.startTest();
        List<PerfectStoreScoreController.ScoreRankRow> rows =
            PerfectStoreScoreController.getOutletRanking(null, null, null, null);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Two outlets, and the account-less audit is skipped');
        System.assertEquals('PSS Outlet Two', rows[0].name, 'Highest average leads');
        System.assertEquals(88.0, rows[0].avgScore, 'At 88');
        System.assertEquals('PSS Outlet One', rows[1].name, 'Then the 80 average');
        System.assertEquals(2, rows[1].surveyCount, 'With its audit count');
        System.assertNotEquals(null, rows[1].territory,
            'And the territory resolved for the drill-down');
    }

    @isTest
    static void outletRanking_honoursTopNAndDefaultsSillyValues() {
        Id audit = survey('PSS Monthly Audit');
        insert new List<Survey_Response__c>{
            completed(audit, outlet('PSS Outlet One'), 90, 5),
            completed(audit, outlet('PSS Outlet Two'), 80, 4)
        };

        Test.startTest();
        List<PerfectStoreScoreController.ScoreRankRow> topOne =
            PerfectStoreScoreController.getOutletRanking(null, null, null, 1);
        List<PerfectStoreScoreController.ScoreRankRow> absurd =
            PerfectStoreScoreController.getOutletRanking(null, null, null, 5000);
        Test.stopTest();

        System.assertEquals(1, topOne.size(), 'topN truncates the board');
        System.assertEquals('PSS Outlet One', topOne[0].name, 'To the leader');
        System.assertEquals(2, absurd.size(),
            'A topN beyond the 100 cap falls back to the default of 20 — never into the '
            + 'raw query as an unbounded LIMIT');
    }

    // ── getTerritoryRanking ───────────────────────────────────────────

    @isTest
    static void territoryRanking_groupsOutletsUnderTheirTerritory() {
        Id audit = survey('PSS Monthly Audit');
        // Both PSS outlets share the factory default territory, so their four
        // audits roll up into ONE territory row averaging all of them.
        insert new List<Survey_Response__c>{
            completed(audit, outlet('PSS Outlet One'), 90, 5),
            completed(audit, outlet('PSS Outlet One'), 80, 4),
            completed(audit, outlet('PSS Outlet Two'), 70, 3),
            completed(audit, outlet('PSS Outlet Two'), 60, 2)
        };

        Test.startTest();
        List<PerfectStoreScoreController.ScoreRankRow> rows =
            PerfectStoreScoreController.getTerritoryRanking(null, null, null);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'One shared territory, one row');
        System.assertEquals(75.0, rows[0].avgScore,
            'The territory average spans every audit under it: (90+80+70+60)/4');
        System.assertEquals(4, rows[0].surveyCount, 'All four audits counted');
        System.assertNotEquals(null, rows[0].name, 'Named for the board');
    }

    // ── getRepRanking ─────────────────────────────────────────────────

    @isTest
    static void repRanking_averagesPerRespondent() {
        Id audit = survey('PSS Monthly Audit');
        insert new List<Survey_Response__c>{
            completed(audit, outlet('PSS Outlet One'), 92, 5),
            completed(audit, outlet('PSS Outlet Two'), 78, 4)
        };

        Test.startTest();
        List<PerfectStoreScoreController.ScoreRankRow> rows =
            PerfectStoreScoreController.getRepRanking(null, null, null, 10);
        Test.stopTest();

        System.assertEquals(1, rows.size(), 'One rep audited (the running user)');
        System.assertEquals(85.0, rows[0].avgScore, '(92 + 78) / 2');
        System.assertEquals(2, rows[0].surveyCount, 'Across two audits');
        System.assertEquals(null, rows[0].territory,
            'Reps roam territories, so the rep board carries none');
    }

    @isTest
    static void repRanking_ordersMultipleRepsByAverage() {
        // A second rep: User is a setup object, so its DML is isolated in
        // runAs to avoid MIXED_DML with the response inserts.
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User rival = new User(
            ProfileId = p.Id, Alias = 'pssrep',
            Email = 'pssrep@pss.test', EmailEncodingKey = 'UTF-8',
            FirstName = 'Perfect', LastName = 'Auditor',
            LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'pssrep' + System.currentTimeMillis() + '@pss.test');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert rival;
        }

        Id audit = survey('PSS Monthly Audit');
        Survey_Response__c rivals = completed(audit, outlet('PSS Outlet One'), 95, 3);
        rivals.Respondent__c = rival.Id;
        insert new List<Survey_Response__c>{
            completed(audit, outlet('PSS Outlet Two'), 75, 4),   // running user, 75
            rivals                                               // rival, 95
        };

        Test.startTest();
        List<PerfectStoreScoreController.ScoreRankRow> rows =
            PerfectStoreScoreController.getRepRanking(null, null, null, 10);
        Test.stopTest();

        System.assertEquals(2, rows.size(), 'Both reps on the board');
        System.assertEquals(rival.Id, rows[0].id, 'The 95 average leads');
        System.assertEquals(95.0, rows[0].avgScore, 'At its score');
        System.assertEquals(75.0, rows[1].avgScore, 'The running user follows');
    }
}