/**
 * @description Aggregates completed Outlet Audit survey scores into the Perfect
 *              Store Score dashboard: headline KPIs plus outlet / territory /
 *              rep leaderboards. Score_Percentage__c is a Percent field — it can
 *              be AVG'd but not grouped, so we group by the lookups and average
 *              the score. A "Perfect Store" is a score at or above the threshold.
 */
public with sharing class PerfectStoreScoreController {

    private static final Decimal PERFECT_STORE_THRESHOLD = 85;

    /** Audit surveys for the filter, with an "All" option. */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getSurveyOptions() {
        List<Map<String, Object>> opts = new List<Map<String, Object>>();
        opts.add(new Map<String, Object>{ 'label' => 'All Audit Surveys', 'value' => '' });
        for (Survey__c s : [
            SELECT Id, Name FROM Survey__c
            WHERE Survey_Type__c = 'Outlet Audit' AND Is_Active__c = true ORDER BY Name
        ]) {
            opts.add(new Map<String, Object>{ 'label' => s.Name, 'value' => s.Id });
        }
        return opts;
    }

    @AuraEnabled(cacheable=false)
    public static PerfectStoreKPIs getScoreKPIs(String surveyId, Date startDate, Date endDate) {
        PerfectStoreKPIs k = new PerfectStoreKPIs();
        k.threshold = PERFECT_STORE_THRESHOLD;
        String whereClause = buildWhere(surveyId, startDate, endDate);
        for (AggregateResult ar : Database.query(
            'SELECT AVG(Score_Percentage__c) avgScore, COUNT(Id) cnt, COUNT_DISTINCT(Account__c) outlets '
            + 'FROM Survey_Response__c ' + whereClause)) {
            k.avgScore = ar.get('avgScore') != null ? ((Decimal) ar.get('avgScore')).setScale(1) : 0;
            k.totalAudits = ar.get('cnt') != null ? (Integer) ar.get('cnt') : 0;
            k.outletsAudited = ar.get('outlets') != null ? (Integer) ar.get('outlets') : 0;
        }
        k.perfectStores = Database.countQuery(
            'SELECT COUNT() FROM Survey_Response__c ' + whereClause
            + ' AND Score_Percentage__c >= ' + PERFECT_STORE_THRESHOLD);
        return k;
    }

    @AuraEnabled(cacheable=false)
    public static List<ScoreRankRow> getOutletRanking(String surveyId, Date startDate, Date endDate, Integer topN) {
        List<ScoreRankRow> rows = new List<ScoreRankRow>();
        String whereClause = buildWhere(surveyId, startDate, endDate);
        for (AggregateResult ar : Database.query(
            'SELECT Account__c aid, Account__r.Name aname, Account__r.Territory__r.Name terr, '
            + 'AVG(Score_Percentage__c) avgScore, COUNT(Id) cnt FROM Survey_Response__c '
            + whereClause + ' AND Account__c != null '
            + 'GROUP BY Account__c, Account__r.Name, Account__r.Territory__r.Name '
            + 'ORDER BY AVG(Score_Percentage__c) DESC LIMIT ' + safeLimit(topN))) {
            rows.add(rowFrom((Id) ar.get('aid'), (String) ar.get('aname'), (String) ar.get('terr'), ar));
        }
        return rows;
    }

    @AuraEnabled(cacheable=false)
    public static List<ScoreRankRow> getTerritoryRanking(String surveyId, Date startDate, Date endDate) {
        List<ScoreRankRow> rows = new List<ScoreRankRow>();
        String whereClause = buildWhere(surveyId, startDate, endDate);
        for (AggregateResult ar : Database.query(
            'SELECT Account__r.Territory__c tid, Account__r.Territory__r.Name terr, '
            + 'AVG(Score_Percentage__c) avgScore, COUNT(Id) cnt FROM Survey_Response__c '
            + whereClause + ' AND Account__r.Territory__c != null '
            + 'GROUP BY Account__r.Territory__c, Account__r.Territory__r.Name '
            + 'ORDER BY AVG(Score_Percentage__c) DESC')) {
            rows.add(rowFrom((Id) ar.get('tid'), (String) ar.get('terr'), (String) ar.get('terr'), ar));
        }
        return rows;
    }

    @AuraEnabled(cacheable=false)
    public static List<ScoreRankRow> getRepRanking(String surveyId, Date startDate, Date endDate, Integer topN) {
        List<ScoreRankRow> rows = new List<ScoreRankRow>();
        String whereClause = buildWhere(surveyId, startDate, endDate);
        for (AggregateResult ar : Database.query(
            'SELECT Respondent__c rid, Respondent__r.Name rname, '
            + 'AVG(Score_Percentage__c) avgScore, COUNT(Id) cnt FROM Survey_Response__c '
            + whereClause + ' AND Respondent__c != null '
            + 'GROUP BY Respondent__c, Respondent__r.Name '
            + 'ORDER BY AVG(Score_Percentage__c) DESC LIMIT ' + safeLimit(topN))) {
            rows.add(rowFrom((Id) ar.get('rid'), (String) ar.get('rname'), null, ar));
        }
        return rows;
    }

    // ── helpers ──
    private static ScoreRankRow rowFrom(Id id, String name, String territory, AggregateResult ar) {
        ScoreRankRow r = new ScoreRankRow();
        r.id = id;
        r.name = String.isBlank(name) ? '(Unassigned)' : name;
        r.territory = territory;
        r.avgScore = ar.get('avgScore') != null ? ((Decimal) ar.get('avgScore')).setScale(1) : 0;
        r.surveyCount = ar.get('cnt') != null ? (Integer) ar.get('cnt') : 0;
        return r;
    }

    private static Integer safeLimit(Integer topN) {
        return (topN != null && topN > 0 && topN <= 100) ? topN : 20;
    }

    /** Completed responses, optionally scoped by survey and date window. */
    private static String buildWhere(String surveyId, Date startDate, Date endDate) {
        List<String> conds = new List<String>{ 'Status__c = \'Completed\'' };
        if (String.isNotBlank(surveyId)) {
            conds.add('Survey__c = \'' + String.escapeSingleQuotes(surveyId) + '\'');
        }
        if (startDate != null) {
            conds.add('Response_Date__c >= '
                + Datetime.newInstanceGmt(startDate, Time.newInstance(0, 0, 0, 0))
                    .formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        }
        if (endDate != null) {
            conds.add('Response_Date__c < '
                + Datetime.newInstanceGmt(endDate.addDays(1), Time.newInstance(0, 0, 0, 0))
                    .formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        }
        return 'WHERE ' + String.join(conds, ' AND ');
    }

    // ── wrappers ──
    public class PerfectStoreKPIs {
        @AuraEnabled public Decimal avgScore = 0;
        @AuraEnabled public Integer totalAudits = 0;
        @AuraEnabled public Integer perfectStores = 0;
        @AuraEnabled public Integer outletsAudited = 0;
        @AuraEnabled public Decimal threshold = 0;
    }

    public class ScoreRankRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String territory;
        @AuraEnabled public Decimal avgScore = 0;
        @AuraEnabled public Integer surveyCount = 0;
    }
}