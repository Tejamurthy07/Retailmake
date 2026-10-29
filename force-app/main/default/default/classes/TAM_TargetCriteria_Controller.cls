public with sharing class TAM_TargetCriteria_Controller {

    // ======================
    // 1. GET ALL OBJECT NAMES
    // ======================
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAllObjects() {

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        List<Map<String, String>> result = new List<Map<String, String>>();

        for (String apiName : gd.keySet()) {

            if (isSystemObject(apiName)) continue;

            Schema.DescribeSObjectResult d = gd.get(apiName).getDescribe();

            if (!d.isQueryable() || !d.isAccessible()) {
                continue;
            }

            if (!d.isCreateable() && !d.isUpdateable() && !d.isDeletable()) continue;

            result.add(new Map<String, String>{
                'api' => apiName,
                'label' => d.getLabel()
            });
        }

        // Sort by label
        List<String> labels = new List<String>();
        Map<String, Map<String, String>> index = new Map<String, Map<String, String>>();

        for (Map<String, String> rec : result) {
            String key = rec.get('label') + '___' + rec.get('api');
            labels.add(key);
            index.put(key, rec);
        }

        labels.sort();

        List<Map<String, String>> sorted = new List<Map<String, String>>();
        for (String k : labels) {
            sorted.add(index.get(k));
        }

        return sorted;
    }

    // ====================================
    // 2. GET FIELDS FOR GIVEN OBJECT
    // ====================================
    @AuraEnabled(cacheable=true)
    public static Map<String, List<String>> getFieldCategories(String objectName) {

        Map<String, List<String>> response = new Map<String, List<String>>();
        response.put('numberFields', new List<String>());
        response.put('dateFields', new List<String>());
        response.put('userFields', new List<String>());
        response.put('allFields', new List<String>());

        Schema.SObjectType typeObj = Schema.getGlobalDescribe().get(objectName);
        Map<String, Schema.SObjectField> fields = typeObj.getDescribe().fields.getMap();

        for (String fname : fields.keySet()) {

            Schema.DescribeFieldResult d = fields.get(fname).getDescribe();
            response.get('allFields').add(fname);

            // NUMBER / CURRENCY / PERCENT
            if (d.getType() == Schema.DisplayType.Double ||
                d.getType() == Schema.DisplayType.Currency ||
                d.getType() == Schema.DisplayType.Percent) {
                response.get('numberFields').add(fname);
            }

            // FORMULA (NUMBER) SUPPORT
            if (d.isCalculated() && d.getType() == Schema.DisplayType.Double) {
                response.get('numberFields').add(fname);
            }

            // DATE FIELDS
            if (d.getType() == Schema.DisplayType.Date ||
                d.getType() == Schema.DisplayType.DateTime) {
                response.get('dateFields').add(fname);
            }

            // USER LOOKUP FIELDS
            if (d.getType() == Schema.DisplayType.Reference &&
                d.getReferenceTo().size() > 0 &&
                d.getReferenceTo()[0] == Schema.User.getSObjectType()) {
                response.get('userFields').add(fname);
            }
        }

        return response;
    }

    // =====================
    // 3. GET ALL CRITERIA (List view)
    // =====================
    @AuraEnabled(cacheable=false)
    public static List<Target_Criteria__c> getAllCriteria() {
        return [
            SELECT Id, Name, Object__c, Operator__c, Field__c,
                   Date_Field__c, User_Field__c,
                   Filters__c, Filter_Logic__c,
                   Active__c, Enable_Customer_Targets__c,
                   Category__c, Incentive_Weight__c,
                   Prerequisite_Criteria__c, Prerequisite_Criteria__r.Name,
                   Prerequisite_Min_Percent__c,
                   CreatedDate, LastModifiedDate
            FROM Target_Criteria__c
            ORDER BY LastModifiedDate DESC
            LIMIT 200
        ];
    }

    // =====================
    // 4. GET EXISTING CRITERIA
    // =====================
    @AuraEnabled(cacheable=false)
    public static Target_Criteria__c getCriteria(Id criteriaId) {
        return [
            SELECT Id, Name, Object__c, Operator__c, Field__c,
                   Date_Field__c, User_Field__c,
                   Filters__c, Filter_Logic__c,
                   Enable_Customer_Targets__c, Active__c, Category__c,
                   Incentive_Weight__c, Prerequisite_Criteria__c,
                   Prerequisite_Criteria__r.Name, Prerequisite_Min_Percent__c
            FROM Target_Criteria__c
            WHERE Id = :criteriaId
        ];
    }

    // =====================
    // 5. SAVE CRITERIA
    // =====================
    @AuraEnabled
    public static Target_Criteria__c saveCriteria(Target_Criteria__c criteria) {
        upsert criteria;
        return getCriteria(criteria.Id);
    }

    // =====================
    // 5b. GET CRITERIA OPTIONS (for prerequisite dropdown)
    // =====================
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getCriteriaOptions() {
        List<Map<String, String>> opts = new List<Map<String, String>>();
        opts.add(new Map<String, String>{ 'label' => '-- None (No Prerequisite) --', 'value' => '' });
        for (Target_Criteria__c tc : [
            SELECT Id, Name FROM Target_Criteria__c WHERE Active__c = true ORDER BY Name
        ]) {
            opts.add(new Map<String, String>{ 'label' => tc.Name, 'value' => tc.Id });
        }
        return opts;
    }

    // =====================
    // 6. GET LINKED TARGET COUNT (for delete confirmation)
    // =====================
    @AuraEnabled
    public static Integer getLinkedTargetCount(Id criteriaId) {
        return [SELECT COUNT() FROM Target_Actual__c WHERE Target_Criteria__c = :criteriaId];
    }

    // =====================
    // 7. DELETE CRITERIA (cascade deletes linked Target_Actual__c)
    // =====================
    @AuraEnabled
    public static void deleteCriteria(Id criteriaId) {
        List<Target_Actual__c> linkedActuals = [
            SELECT Id FROM Target_Actual__c WHERE Target_Criteria__c = :criteriaId
        ];
        if (!linkedActuals.isEmpty()) {
            delete linkedActuals;
        }
        Target_Criteria__c rec = [SELECT Id FROM Target_Criteria__c WHERE Id = :criteriaId LIMIT 1];
        delete rec;
    }

    // =====================
    // 8. BULK UPDATE ACTIVE STATUS
    // =====================
    @AuraEnabled
    public static void bulkToggleActive(List<Id> criteriaIds, Boolean isActive) {
        List<Target_Criteria__c> recs = [SELECT Id, Active__c FROM Target_Criteria__c WHERE Id IN :criteriaIds];
        for (Target_Criteria__c r : recs) {
            r.Active__c = isActive;
        }
        update recs;
    }

    // =====================
    // 9. BULK DELETE
    // =====================
    @AuraEnabled
    public static void bulkDelete(List<Id> criteriaIds) {
        // Cascade: delete linked target actuals first
        List<Target_Actual__c> linkedActuals = [
            SELECT Id FROM Target_Actual__c WHERE Target_Criteria__c IN :criteriaIds
        ];
        if (!linkedActuals.isEmpty()) {
            delete linkedActuals;
        }
        List<Target_Criteria__c> recs = [SELECT Id FROM Target_Criteria__c WHERE Id IN :criteriaIds];
        delete recs;
    }

    // =====================
    // 10. TOGGLE ACTIVE STATUS (single)
    // =====================
    @AuraEnabled
    public static void toggleActive(Id criteriaId, Boolean isActive) {
        Target_Criteria__c rec = [SELECT Id, Active__c FROM Target_Criteria__c WHERE Id = :criteriaId LIMIT 1];
        rec.Active__c = isActive;
        update rec;
    }

    // =====================
    // 9. CLONE CRITERIA
    // =====================
    @AuraEnabled
    public static Target_Criteria__c cloneCriteria(Id criteriaId) {
        Target_Criteria__c source = [
            SELECT Name, Object__c, Operator__c, Field__c,
                   Date_Field__c, User_Field__c,
                   Filters__c, Filter_Logic__c,
                   Enable_Customer_Targets__c,
                   Category__c, Incentive_Weight__c,
                   Prerequisite_Criteria__c, Prerequisite_Min_Percent__c
            FROM Target_Criteria__c
            WHERE Id = :criteriaId
        ];

        Target_Criteria__c cloned = source.clone(false, true, false, false);
        cloned.Name = source.Name + ' (Copy)';
        cloned.Active__c = false;
        insert cloned;

        return getCriteria(cloned.Id);
    }

    // =====================
    // 10. PREVIEW CRITERIA (run SOQL with LIMIT 5)
    // =====================
    @AuraEnabled
    public static Map<String, Object> previewCriteria(Id criteriaId) {
        Target_Criteria__c crit = getCriteria(criteriaId);
        Map<String, Object> result = new Map<String, Object>();

        String whereFilters = TAM_FilterEngine_Service.buildWhereClause(
            crit.Filters__c, crit.Filter_Logic__c
        );

        String agg = (crit.Operator__c == 'COUNT')
            ? 'COUNT(Id)'
            : crit.Operator__c + '(' + crit.Field__c + ')';

        // Build date range for current month
        Date startDate = Date.today().toStartOfMonth();
        Date endDate = startDate.addMonths(1).addDays(-1);

        List<String> whereSegments = new List<String>();
        whereSegments.add(crit.Date_Field__c + ' >= :startDate');
        whereSegments.add(crit.Date_Field__c + ' <= :endDate');
        if (!String.isBlank(whereFilters)) {
            whereSegments.add(whereFilters);
        }

        String soql = 'SELECT ' + crit.User_Field__c + ', ' + agg + ' val' +
            ' FROM ' + crit.Object__c +
            ' WHERE ' + String.join(whereSegments, ' AND ') +
            ' GROUP BY ' + crit.User_Field__c +
            ' LIMIT 5';

        result.put('query', soql);
        result.put('period', startDate.format() + ' to ' + endDate.format());

        try {
            List<AggregateResult> rows = Database.query(soql);
            List<Map<String, Object>> data = new List<Map<String, Object>>();
            for (AggregateResult ar : rows) {
                Map<String, Object> row = new Map<String, Object>();
                row.put('userId', ar.get(crit.User_Field__c));
                row.put('value', ar.get('val'));
                data.add(row);
            }
            result.put('data', data);
            result.put('rowCount', data.size());
            result.put('success', true);
        } catch (Exception e) {
            result.put('success', false);
            result.put('error', e.getMessage());
            result.put('data', new List<Map<String, Object>>());
            result.put('rowCount', 0);
        }

        return result;
    }

    static Boolean isSystemObject(String apiName) {
        String lower = apiName.toLowerCase();
        return lower.endsWith('history') ||
            lower.endsWith('feed') ||
            lower.endsWith('fieldhistory') ||
            lower.endsWith('share') ||
            lower.endsWith('tag') ||
            lower.endsWith('vote') ||
            lower.contains('changeevent') ||
            lower.endsWith('event') ||
            lower.contains('cleaninfo') ||
            lower.contains('duplicate') ||
            lower.contains('suggestion');
    }
}