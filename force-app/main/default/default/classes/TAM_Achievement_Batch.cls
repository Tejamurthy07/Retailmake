public class TAM_Achievement_Batch implements Database.Batchable<SObject>, Database.Stateful {

    private Id targetPeriodId;

    public TAM_Achievement_Batch() {
        this.targetPeriodId = null;
    }

    public TAM_Achievement_Batch(Id periodId) {
        this.targetPeriodId = periodId;
    }

    // ===============================
    // START — Load active period rows
    // ===============================
    public Database.QueryLocator start(Database.BatchableContext bc) {

        if (this.targetPeriodId != null) {
            return Database.getQueryLocator([
                SELECT
                    Id,
                    User__c,
                    Target_Criteria__c,
                    Target_Period__c,
                    Target_Period__r.Start_Date__c,
                    Target_Period__r.End_Date__c,
                    User__r.ManagerId
                FROM Target_Actual__c
                WHERE Target_Period__c = :targetPeriodId
            ]);
        }

        Date today = Date.today();

        return Database.getQueryLocator([
            SELECT
                Id,
                User__c,
                Target_Criteria__c,
                Target_Period__c,
                Target_Period__r.Start_Date__c,
                Target_Period__r.End_Date__c,
                User__r.ManagerId
            FROM Target_Actual__c
            WHERE Target_Period__r.Start_Date__c <= :today
              AND Target_Period__r.End_Date__c   >= :today
        ]);
    }

    // ===============================
    // EXECUTE — Main logic
    // ===============================
    public void execute(Database.BatchableContext bc, List<Target_Actual__c> scope) {

        if (scope.isEmpty()) return;

        // GROUP RECORDS BY (CriteriaId + PeriodId)
        Map<String, List<Target_Actual__c>> groupMap = new Map<String, List<Target_Actual__c>>();

        for (Target_Actual__c row : scope) {
            String key = row.Target_Criteria__c + '-' + row.Target_Period__c;

            if (!groupMap.containsKey(key)) {
                groupMap.put(key, new List<Target_Actual__c>());
            }

            groupMap.get(key).add(row);
        }

        // Load all criteria in one go
        Set<Id> critIds = new Set<Id>();
        for (Target_Actual__c t : scope) critIds.add(t.Target_Criteria__c);

        Map<Id, Target_Criteria__c> critMap = new Map<Id, Target_Criteria__c>(
            [
                SELECT Id, Name,
                    Object__c,
                    Operator__c,
                    Field__c,
                    Date_Field__c,
                    User_Field__c,
                    Filters__c,
                    Filter_Logic__c
                FROM Target_Criteria__c
                WHERE Id IN :critIds
            ]
        );

        List<Target_Actual__c> updates = new List<Target_Actual__c>();

        // PROCESS EACH GROUP
        for (String key : groupMap.keySet()) {

            List<Target_Actual__c> rows = groupMap.get(key);

            String[] parts = key.split('-');
            Id critId   = parts[0];
            Id periodId = parts[1];

            Target_Criteria__c crit = critMap.get(critId);

            // Skip criteria with incomplete configuration — otherwise the
            // dynamic SOQL would be malformed and blow up the whole batch chunk.
            if (crit == null || String.isBlank(crit.Object__c)
                || String.isBlank(crit.Operator__c) || String.isBlank(crit.Date_Field__c)
                || String.isBlank(crit.User_Field__c)
                || (crit.Operator__c != 'COUNT' && String.isBlank(crit.Field__c))) {
                System.debug(LoggingLevel.WARN,
                    'TAM_Achievement_Batch: skipping criteria ' + critId + ' — incomplete config');
                continue;
            }

            // Period boundaries
            Date startDate = rows[0].Target_Period__r.Start_Date__c;
            Date endDate   = rows[0].Target_Period__r.End_Date__c;

            // User IDs impacted
            Set<Id> userIds = new Set<Id>();
            for (Target_Actual__c ta : rows) userIds.add(ta.User__c);

            // Build WHERE from JSON
            String jsonWhere = TAM_FilterEngine_Service.buildWhereClause(
                crit.Filters__c,
                crit.Filter_Logic__c
            );

            // Build full SOQL string
            TAM_DynamicSOQL_Service.Context ctx = new TAM_DynamicSOQL_Service.Context();
            ctx.objectName   = crit.Object__c;
            ctx.userField    = crit.User_Field__c;
            ctx.aggField     = crit.Field__c;
            ctx.aggFunction  = crit.Operator__c;
            ctx.dateField    = crit.Date_Field__c;
            ctx.startDate    = startDate;
            ctx.endDate      = endDate;
            ctx.filtersJson  = crit.Filters__c;
            ctx.logic        = crit.Filter_Logic__c;
            ctx.userIds      = userIds;

            String soql = TAM_DynamicSOQL_Service.buildSOQL(ctx);

            System.debug('TAM_Achievement_Batch QUERY → ' + soql);

            // Execute with proper BIND ORDER
            List<AggregateResult> agg = Database.query(soql);

            // MAP results
            Map<Id, Decimal> achievementMap = new Map<Id, Decimal>();

            for (AggregateResult ar : agg) {

                Object keyVal = ar.get(ctx.userField);
                Object achVal = ar.get('expr0');

                if (keyVal != null) {
                    achievementMap.put(
                        (Id) keyVal,
                        achVal == null ? 0 : (Decimal) achVal
                    );
                }
            }

            // Assign to Target_Actual__c
            for (Target_Actual__c ta : rows) {
                ta.Achievement_Value__c =
                    achievementMap.containsKey(ta.User__c)
                    ? achievementMap.get(ta.User__c)
                    : 0;

                ta.Last_Updated__c = System.now();
                updates.add(ta);
            }
        }

        if (!updates.isEmpty()) update updates;

        // RUN rollup engine for hierarchical distribution
        TAM_Rollup_Service.run(scope);
    }

    // ===============================
    // FINISH
    // ===============================
    public void finish(Database.BatchableContext bc) {
        System.debug('TAM_Achievement_Batch completed successfully.');
    }
}