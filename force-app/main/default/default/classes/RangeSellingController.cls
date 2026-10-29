public without sharing class RangeSellingController {

    // Whitelist of groupings -> relationship field on Order_Line_Item__c
    private static final Map<String, String> GROUP_FIELDS = new Map<String, String>{
        'Brand'     => 'Product_Ext__r.Brand__c',
        'Sub-Brand' => 'Product_Ext__r.Sub_Brand__c',
        'SKU'       => 'Product_Ext__r.Name'
    };

    public class CoverageRow {
        @AuraEnabled public String name;
        @AuraEnabled public Integer covered;
        @AuraEnabled public Integer total;
        @AuraEnabled public Decimal pct;
    }

    @AuraEnabled(cacheable=true)
    public static List<CoverageRow> getCoverage(String groupBy) {
        String field = GROUP_FIELDS.get(groupBy);
        if (field == null) {
            throw new AuraHandledException('Invalid grouping: ' + groupBy);
        }

        // Denominator: total billed outlets (distinct accounts with a sales order)
        AggregateResult billed = [
            SELECT COUNT_DISTINCT(Account__c) cnt
            FROM Sales_Order__c
            WHERE Account__c != null
        ];
        Integer totalOutlets = (Integer) billed.get('cnt');

        // Numerators: distinct outlets per brand / sub-brand / sku
        String soql =
            'SELECT ' + field + ' val, ' +
            'COUNT_DISTINCT(Sales_Order__r.Account__c) covered ' +
            'FROM Order_Line_Item__c ' +
            'WHERE ' + field + ' != null ' +
            'AND Sales_Order__r.Account__c != null ' +
            'GROUP BY ' + field + ' ' +
            'ORDER BY COUNT_DISTINCT(Sales_Order__r.Account__c) DESC';

        List<CoverageRow> rows = new List<CoverageRow>();
        for (AggregateResult ar : Database.query(soql)) {
            CoverageRow row = new CoverageRow();
            row.name    = (String) ar.get('val');
            row.covered = (Integer) ar.get('covered');
            row.total   = totalOutlets;
            row.pct     = (totalOutlets == 0)
                          ? 0
                          : ((Decimal) row.covered * 100 / totalOutlets).setScale(0);
            rows.add(row);
        }
        return rows;
    }
}