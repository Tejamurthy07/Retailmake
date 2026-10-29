public with sharing class DKD_MetricManager_Controller {

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getQueryableObjects() {
        List<Map<String, String>> result = new List<Map<String, String>>();
        Set<String> included = new Set<String>{
            'Account', 'Sales_Order__c', 'Order_Line_Item__c', 'Visit__c',
            'Collection__c', 'Return_Order__c', 'Invoice__c', 'Day_Attendance__c',
            'Beat__c', 'Journey_Plan__c', 'Expense__c', 'Expense_Item__c',
            'Stock_Transfer__c', 'GRN__c', 'Warehouse_Stock__c',
            'Distributor_Stock__c', 'Target_Actual__c', 'Incentive__c',
            'Competitor__c', 'Product_Extension__c', 'Scheme__c'
        };
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        for (String apiName : included) {
            if (gd.containsKey(apiName.toLowerCase())) {
                Schema.DescribeSObjectResult d = gd.get(apiName.toLowerCase()).getDescribe();
                if (d.isQueryable() && d.isAccessible()) {
                    Map<String, String> obj = new Map<String, String>();
                    obj.put('api', d.getName());
                    obj.put('label', d.getLabel());
                    result.add(obj);
                }
            }
        }
        result.sort(new MapLabelComparator());
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getObjectFields(String objectApiName) {
        Map<String, Object> result = new Map<String, Object>();
        if (String.isBlank(objectApiName)) return result;

        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectApiName.toLowerCase());
        if (sobjType == null) return result;

        Map<String, Schema.SObjectField> fieldMap = sobjType.getDescribe().fields.getMap();

        List<Map<String, String>> dateFields = new List<Map<String, String>>();
        List<Map<String, String>> numberFields = new List<Map<String, String>>();
        List<Map<String, String>> userFields = new List<Map<String, String>>();
        List<Map<String, String>> allFields = new List<Map<String, String>>();

        for (String fieldName : fieldMap.keySet()) {
            Schema.DescribeFieldResult f = fieldMap.get(fieldName).getDescribe();
            if (!f.isAccessible()) continue;

            String api = f.getName();
            String label = f.getLabel();
            Schema.DisplayType dt = f.getType();

            Map<String, String> entry = new Map<String, String>();
            entry.put('api', api);
            entry.put('label', label + ' (' + api + ')');

            allFields.add(entry);

            if (dt == Schema.DisplayType.DATE || dt == Schema.DisplayType.DATETIME) {
                dateFields.add(entry);
            }

            if (dt == Schema.DisplayType.CURRENCY || dt == Schema.DisplayType.DOUBLE
                || dt == Schema.DisplayType.INTEGER || dt == Schema.DisplayType.PERCENT
                || dt == Schema.DisplayType.LONG) {
                numberFields.add(entry);
            }

            if (dt == Schema.DisplayType.REFERENCE) {
                List<Schema.SObjectType> refs = f.getReferenceTo();
                for (Schema.SObjectType ref : refs) {
                    if (ref.getDescribe().getName() == 'User') {
                        userFields.add(entry);
                        break;
                    }
                }
            }
        }

        dateFields.sort(new MapLabelComparator());
        numberFields.sort(new MapLabelComparator());
        userFields.sort(new MapLabelComparator());

        result.put('dateFields', dateFields);
        result.put('numberFields', numberFields);
        result.put('userFields', userFields);
        return result;
    }

    @AuraEnabled
    public static List<KPI_Metric__c> getAllMetrics() {
        return [
            SELECT Id, Name, Metric_Key__c, Label__c, Description__c,
                   Source_Object__c, Aggregation__c, Aggregate_Field__c,
                   Date_Field__c, User_Field__c, Default_Filter__c,
                   Filters_JSON__c, Filter_Logic__c,
                   Format__c, Icon__c, Color__c, Category__c,
                   Allow_Forecast__c, Is_Active__c, Sort_Order__c
            FROM KPI_Metric__c
            ORDER BY Category__c, Sort_Order__c NULLS LAST, Label__c
        ];
    }

    @AuraEnabled
    public static KPI_Metric__c saveMetric(KPI_Metric__c metric) {
        List<String> errors = DKD_MetricRegistry.validateMetric(metric);
        if (!errors.isEmpty()) {
            throw new AuraHandledException(String.join(errors, '\n'));
        }
        upsert metric;
        DKD_MetricRegistry.clearCache();
        return metric;
    }

    @AuraEnabled
    public static void deleteMetric(Id metricId) {
        delete [SELECT Id FROM KPI_Metric__c WHERE Id = :metricId];
        DKD_MetricRegistry.clearCache();
    }

    private class MapLabelComparator implements Comparator<Map<String, String>> {
        public Integer compare(Map<String, String> a, Map<String, String> b) {
            String la = a.get('label') != null ? a.get('label') : '';
            String lb = b.get('label') != null ? b.get('label') : '';
            return la.compareTo(lb);
        }
    }
}