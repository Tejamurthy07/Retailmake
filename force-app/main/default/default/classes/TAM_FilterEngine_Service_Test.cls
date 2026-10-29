/**
 * @description Test class for TAM_FilterEngine_Service. Pure-logic service
 *              with no DML or feature toggles — covers every branch of
 *              parseFilters, buildWhereClause, and buildCondition (Null /
 *              IN-NOT IN / String / Number / Currency / Percent / Boolean /
 *              Date / DateTime / Picklist / MultiPicklist scalar+list /
 *              fallback) plus the LIKE/NOT LIKE branch, the empty/blank-input
 *              early returns, and the logic-string-with-id replacement path.
 */
@isTest
private class TAM_FilterEngine_Service_Test {

    // ── Helpers ─────────────────────────────────────────────────────────────

    /**
     * @description Builds a JSON string with a "filters" array from a list of
     *              row maps so each test can assemble exactly the input shape
     *              the service parses.
     */
    private static String filtersJson(List<Map<String, Object>> rows) {
        return JSON.serialize(new Map<String, Object>{ 'filters' => rows });
    }

    private static Map<String, Object> row(Integer id, String field, String op, Object value, String type) {
        return new Map<String, Object>{
            'id' => id, 'field' => field, 'operator' => op,
            'value' => value, 'type' => type
        };
    }

    // ── buildWhereClause / parseFilters edge cases ──────────────────────────

    @isTest
    static void testBlankAndEmptyInputs() {
        // Blank JSON → empty string.
        System.assertEquals('', TAM_FilterEngine_Service.buildWhereClause(null, null),
            'Null JSON returns empty');
        System.assertEquals('', TAM_FilterEngine_Service.buildWhereClause('', null),
            'Empty JSON returns empty');

        // JSON without "filters" key → empty.
        String noKey = JSON.serialize(new Map<String, Object>{ 'other' => 'x' });
        System.assertEquals('', TAM_FilterEngine_Service.buildWhereClause(noKey, null),
            'Missing filters key returns empty');

        // Explicit empty filters array → empty.
        String empty = filtersJson(new List<Map<String, Object>>());
        System.assertEquals('', TAM_FilterEngine_Service.buildWhereClause(empty, null),
            'Empty filters array returns empty');
    }

    @isTest
    static void testParseFilters_PopulatesEveryProperty() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(7, 'Name', '=', 'Acme', 'String')
        });
        TAM_FilterEngine_Service.FilterDefinition def =
            TAM_FilterEngine_Service.parseFilters(j);
        System.assertEquals(1, def.filters.size(), 'One row parsed');
        TAM_FilterEngine_Service.FilterRow f = def.filters[0];
        System.assertEquals(7, f.id, 'id parsed');
        System.assertEquals('Name', f.field, 'field parsed');
        System.assertEquals('=', f.operator, 'operator parsed');
        System.assertEquals('String', f.type, 'type parsed');
        System.assertEquals('Acme', (String) f.value, 'value parsed');
    }

    // ── Default AND join (no logic string) ──────────────────────────────────

    @isTest
    static void testNoLogic_JoinsWithAnd() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'Name', '=', 'Acme', 'String'),
            row(2, 'AnnualRevenue', '>', 1000, 'Number')
        });

        String where1 = TAM_FilterEngine_Service.buildWhereClause(j, null);
        String where2 = TAM_FilterEngine_Service.buildWhereClause(j, '');

        System.assert(where1.contains('AND'), 'Null logic joins with AND');
        System.assert(where2.contains('AND'), 'Blank logic joins with AND');
        System.assert(where1.contains('Name'), 'Includes string condition');
        System.assert(where1.contains('AnnualRevenue'), 'Includes numeric condition');
    }

    // ── Logic string replacement ────────────────────────────────────────────

    @isTest
    static void testLogicString_ReplacesIdsDescending() {
        // 12 and 1 — the descending sort prevents "1" being substituted
        // inside "12" first.
        String j = filtersJson(new List<Map<String, Object>>{
            row(1,  'Name',          '=', 'Acme', 'String'),
            row(12, 'AnnualRevenue', '>', 100,   'Number')
        });

        String result = TAM_FilterEngine_Service.buildWhereClause(j, '1 AND 12');
        System.assert(result.startsWith('('), 'Wrapped in parens');
        System.assert(result.contains('Name'), 'Filter 1 substituted');
        System.assert(result.contains('AnnualRevenue'), 'Filter 12 substituted');
    }

    // ── buildCondition branches ─────────────────────────────────────────────

    @isTest
    static void testNullTypeOperators() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'Description', 'IS NULL',     null, 'Null'),
            row(2, 'Description', 'IS NOT NULL', null, 'Null')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('= NULL'),  'IS NULL handled');
        System.assert(w.contains('!= NULL'), 'IS NOT NULL handled');
    }

    @isTest
    static void testInNotIn_StringAndNumber() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'Name', 'IN',
                new List<Object>{ 'A', 'B', 'O\'Brien' }, 'String'),
            row(2, 'AnnualRevenue', 'NOT IN',
                new List<Object>{ 100, 200, 300 }, 'Number')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('Name IN'),         'String IN list');
        System.assert(w.contains('\'A\''),           'String values quoted');
        System.assert(w.contains('O\\\'Brien'),      'Single quote escaped');
        System.assert(w.contains('AnnualRevenue NOT IN'), 'Number NOT IN list');
        System.assert(w.contains('100,200,300'),     'Number values unquoted');
    }

    @isTest
    static void testStringLikeAndEquals() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'Name', 'LIKE',     'Acm', 'String'),
            row(2, 'Name', 'NOT LIKE', 'Foo', 'String'),
            row(3, 'Name', '=',        'Bar', 'String')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('LIKE \'%Acm%\''),      'LIKE wraps in % %');
        System.assert(w.contains('NOT LIKE \'%Foo%\''),  'NOT LIKE wraps in % %');
        System.assert(w.contains('= \'Bar\''),           'Equals uses bare quotes');
    }

    @isTest
    static void testNumericTypes() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'AnnualRevenue',   '>=', 1000, 'Number'),
            row(2, 'Currency_Field__c', '<', 50.5, 'Currency'),
            row(3, 'Percent_Field__c',  '=', 25,   'Percent')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('AnnualRevenue >= 1000'),    'Number scalar unquoted');
        System.assert(w.contains('Currency_Field__c < 50.5'), 'Currency scalar unquoted');
        System.assert(w.contains('Percent_Field__c = 25'),    'Percent scalar unquoted');
    }

    @isTest
    static void testBooleanTrueAndFalse() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'Is_Active__c', '=', 'true',  'Boolean'),
            row(2, 'Is_Active__c', '=', 'false', 'Boolean')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('= TRUE'),  'Boolean true mapped');
        System.assert(w.contains('= FALSE'), 'Boolean false mapped');
    }

    @isTest
    static void testDateAndDateTime() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'CreatedDate', '>=', '2024-01-15',           'Date'),
            row(2, 'CreatedDate', '<=', '2024-01-15 10:00:00',  'DateTime')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('2024-01-15'),    'Date ISO formatted');
        // DateTime formatted with T...Z
        System.assert(w.contains('T') && w.contains('Z'), 'DateTime ISO formatted');
    }

    @isTest
    static void testPicklistAndMultiPicklist() {
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'Status__c',       '=',        'Open',                            'Picklist'),
            row(2, 'Channels__c',     'INCLUDES', new List<Object>{ 'GT', 'MT' },    'PicklistMulti'),
            row(3, 'Channels__c',     'EXCLUDES', 'GT',                              'MultiPicklist')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('Status__c = \'Open\''),       'Picklist scalar quoted');
        System.assert(w.contains('INCLUDES (\'GT\',\'MT\')'),   'MultiPicklist list');
        System.assert(w.contains('EXCLUDES (\'GT\')'),          'MultiPicklist scalar (list-wrap)');
    }

    @isTest
    static void testFallbackTypeTreatedAsString() {
        // Unknown type falls through to the string fallback at the end.
        String j = filtersJson(new List<Map<String, Object>>{
            row(1, 'Custom_Field__c', '=', 'foo', 'UnknownType')
        });
        String w = TAM_FilterEngine_Service.buildWhereClause(j, null);
        System.assert(w.contains('Custom_Field__c = \'foo\''),
            'Unknown type falls back to string-style quoting');
    }
}