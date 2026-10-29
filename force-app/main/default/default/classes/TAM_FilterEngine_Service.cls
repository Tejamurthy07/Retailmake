public class TAM_FilterEngine_Service {

    public class FilterRow {
        public Integer id;
        public String field;
        public String operator;
        public Object value;
        public String type;
    }

    public class FilterDefinition {
        public List<FilterRow> filters;
    }

    // Main entry
    public static String buildWhereClause(String jsonFilters, String logicString) {

        FilterDefinition def = parseFilters(jsonFilters);
        if (def.filters == null || def.filters.isEmpty()) return '';

        Map<Integer, String> idToCondition = new Map<Integer, String>();

        for (FilterRow row : def.filters) {
            idToCondition.put(row.id, buildCondition(row));
        }

        // If no logic, join using AND
        if (String.isBlank(logicString)) {
            return String.join(idToCondition.values(), ' AND ');
        }

        // Replace IDs in logic string — process in DESCENDING order
        // to avoid replacing "1" inside "12"
        List<Integer> sortedIds = new List<Integer>(idToCondition.keySet());
        sortedIds.sort();

        String resolvedLogic = logicString;
        // Process from highest to lowest
        for (Integer i = sortedIds.size() - 1; i >= 0; i--) {
            Integer id = sortedIds[i];
            resolvedLogic = resolvedLogic.replace(String.valueOf(id), idToCondition.get(id));
        }

        return '(' + resolvedLogic + ')';
    }

    // UNTYPED JSON PARSER
    public static FilterDefinition parseFilters(String jsonFilters) {
        FilterDefinition def = new FilterDefinition();
        def.filters = new List<FilterRow>();

        if (String.isBlank(jsonFilters)) return def;

        Map<String, Object> root =
            (Map<String, Object>) JSON.deserializeUntyped(jsonFilters);

        List<Object> rows = (List<Object>) root.get('filters');
        if (rows == null) return def;

        for (Object r : rows) {
            Map<String, Object> row = (Map<String, Object>) r;

            FilterRow f = new FilterRow();
            f.id = Integer.valueOf(row.get('id'));
            f.field = (String) row.get('field');
            f.operator = (String) row.get('operator');
            f.type = (String) row.get('type');
            f.value = row.get('value'); // keep dynamic

            def.filters.add(f);
        }

        return def;
    }

    // MASTER CONDITION BUILDER
    private static String buildCondition(FilterRow f) {

        // Handle NULL conditions
        if (f.type == 'Null') {
            if (f.operator == 'IS NULL') {
                return '(' + f.field + ' = NULL)';
            }
            if (f.operator == 'IS NOT NULL') {
                return '(' + f.field + ' != NULL)';
            }
        }

        // Handle IN / NOT IN for any type that has a list value
        if ((f.operator == 'IN' || f.operator == 'NOT IN') && f.value instanceof List<Object>) {
            List<Object> vals = (List<Object>) f.value;
            List<String> quoted = new List<String>();

            for (Object v : vals) {
                String sv = String.valueOf(v);
                // Numbers don't need quotes
                if (f.type == 'Number' || f.type == 'Currency' || f.type == 'Percent') {
                    quoted.add(sv);
                } else {
                    quoted.add('\'' + String.escapeSingleQuotes(sv) + '\'');
                }
            }

            return '(' + f.field + ' ' + f.operator + ' (' +
                String.join(quoted, ',') + '))';
        }

        // String types
        if (f.type == 'String') {
            if (f.operator == 'LIKE' || f.operator == 'NOT LIKE') {
                return '(' + f.field + ' ' + f.operator + ' \'%' +
                    String.escapeSingleQuotes(String.valueOf(f.value)) + '%\')';
            }
            return '(' + f.field + ' ' + f.operator + ' \'' +
                String.escapeSingleQuotes(String.valueOf(f.value)) + '\')';
        }

        // Number / Currency / Percent (scalar)
        if (f.type == 'Number' || f.type == 'Currency' || f.type == 'Percent') {
            return '(' + f.field + ' ' + f.operator + ' ' +
                String.valueOf(f.value) + ')';
        }

        // Boolean — JSON deserialize returns String "true"/"false", not Boolean
        if (f.type == 'Boolean') {
            String boolStr = String.valueOf(f.value).toLowerCase();
            return '(' + f.field + ' = ' +
                (boolStr == 'true' ? 'TRUE' : 'FALSE') + ')';
        }

        // Date — use SOQL date literal format YYYY-MM-DD
        if (f.type == 'Date') {
            String dateStr = String.valueOf(f.value);
            // Validate it parses, then use ISO format
            Date d = Date.valueOf(dateStr);
            String isoDate = String.valueOf(d.year()) + '-' +
                String.valueOf(d.month()).leftPad(2, '0') + '-' +
                String.valueOf(d.day()).leftPad(2, '0');
            return '(' + f.field + ' ' + f.operator + ' ' + isoDate + ')';
        }

        // DateTime — use SOQL datetime literal format
        if (f.type == 'DateTime') {
            String dtStr = String.valueOf(f.value);
            Datetime dt = Datetime.valueOf(dtStr);
            return '(' + f.field + ' ' + f.operator + ' ' +
                dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + ')';
        }

        // Picklist (scalar = / !=)
        if (f.type == 'Picklist') {
            return '(' + f.field + ' ' + f.operator + ' \'' +
                String.escapeSingleQuotes(String.valueOf(f.value)) + '\')';
        }

        // MultiPicklist (INCLUDES / EXCLUDES)
        if (f.type == 'PicklistMulti' || f.type == 'MultiPicklist') {
            if (f.value instanceof List<Object>) {
                List<Object> vals = (List<Object>) f.value;
                List<String> quoted = new List<String>();
                for (Object v : vals) {
                    quoted.add('\'' + String.escapeSingleQuotes(String.valueOf(v)) + '\'');
                }
                return '(' + f.field + ' ' + f.operator + ' (' +
                    String.join(quoted, ',') + '))';
            }
            return '(' + f.field + ' ' + f.operator + ' (\'' +
                String.escapeSingleQuotes(String.valueOf(f.value)) + '\'))';
        }

        // Fallback: treat as string
        return '(' + f.field + ' ' + f.operator + ' \'' +
            String.escapeSingleQuotes(String.valueOf(f.value)) + '\')';
    }
}