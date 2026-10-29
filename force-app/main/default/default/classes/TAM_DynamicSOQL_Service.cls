public class TAM_DynamicSOQL_Service {

    public class Context {
        public String objectName;
        public String userField;
        public String aggField;
        public String aggFunction; // SUM or COUNT
        public String dateField;

        public Date startDate;
        public Date endDate;

        public String filtersJson;
        public String logic;

        public Set<Id> userIds;
    }

    public static String buildSOQL(Context ctx) {

        // 1) Build WHERE segments
        List<String> whereSegments = new List<String>();

        whereSegments.add(ctx.dateField + ' >= :startDate');
        whereSegments.add(ctx.dateField + ' <= :endDate');

        // JSON filters — buildWhereClause now returns clean condition without leading AND
        String whereFilters =
            TAM_FilterEngine_Service.buildWhereClause(ctx.filtersJson, ctx.logic);
        if (!String.isBlank(whereFilters)) {
            whereSegments.add(whereFilters);
        }

        String whereClause = String.join(whereSegments, ' AND ');

        // 2) Aggregation
        String agg =
            (ctx.aggFunction == 'COUNT')
            ? 'COUNT(Id)'
            : ctx.aggFunction + '(' + ctx.aggField + ')';

        // 3) Build full SOQL
        String soql =
            'SELECT ' + ctx.userField + ', ' + agg +
            ' FROM ' + ctx.objectName +
            ' WHERE ' + whereClause +
            ' GROUP BY ' + ctx.userField +
            ' HAVING ' + ctx.userField + ' IN :userIds';

        return soql;
    }
}