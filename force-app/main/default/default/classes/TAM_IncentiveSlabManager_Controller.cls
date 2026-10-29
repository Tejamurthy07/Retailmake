public with sharing class TAM_IncentiveSlabManager_Controller {

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getDashboardData() {
        Map<String, Object> result = new Map<String, Object>();

        result.put('slabs', [
            SELECT Id, Name, Target_Criteria__c, Target_Criteria__r.Name,
                   Min_Percent__c, Max_Percent__c, Payout_Type__c, Payout_Value__c,
                   Multiplier__c, Is_Active__c, Effective_From__c, Effective_To__c,
                   Sort_Order__c, Description__c, Profile_Name__c,
                   Territory__c, Territory__r.Name,
                   CreatedDate, LastModifiedDate
            FROM Incentive_Slab__c
            ORDER BY Sort_Order__c ASC, Min_Percent__c ASC
            LIMIT 200
        ]);

        result.put('criteriaOptions', getCriteriaOptions());
        result.put('profileOptions', getProfileOptions());
        result.put('territoryOptions', getTerritoryOptions());

        return result;
    }

    @AuraEnabled(cacheable=false)
    public static Incentive_Slab__c getSlabDetail(Id slabId) {
        return [
            SELECT Id, Name, Target_Criteria__c, Target_Criteria__r.Name,
                   Min_Percent__c, Max_Percent__c, Payout_Type__c, Payout_Value__c,
                   Multiplier__c, Is_Active__c, Effective_From__c, Effective_To__c,
                   Sort_Order__c, Description__c, Profile_Name__c,
                   Territory__c, Territory__r.Name,
                   CreatedDate, LastModifiedDate
            FROM Incentive_Slab__c
            WHERE Id = :slabId
        ];
    }

    @AuraEnabled
    public static Incentive_Slab__c saveSlab(Incentive_Slab__c slab) {
        upsert slab;
        return getSlabDetail(slab.Id);
    }

    @AuraEnabled
    public static void deleteSlab(Id slabId) {
        delete [SELECT Id FROM Incentive_Slab__c WHERE Id = :slabId];
    }

    @AuraEnabled
    public static void toggleActive(Id slabId, Boolean isActive) {
        Incentive_Slab__c rec = [SELECT Id FROM Incentive_Slab__c WHERE Id = :slabId];
        rec.Is_Active__c = isActive;
        update rec;
    }

    @AuraEnabled
    public static Incentive_Slab__c cloneSlab(Id slabId) {
        Incentive_Slab__c source = [
            SELECT Name, Target_Criteria__c, Min_Percent__c, Max_Percent__c,
                   Payout_Type__c, Payout_Value__c, Multiplier__c,
                   Effective_From__c, Effective_To__c, Sort_Order__c, Description__c,
                   Profile_Name__c, Territory__c
            FROM Incentive_Slab__c
            WHERE Id = :slabId
        ];
        Incentive_Slab__c cloned = source.clone(false, true, false, false);
        cloned.Name = source.Name + ' (Copy)';
        cloned.Is_Active__c = false;
        insert cloned;
        return getSlabDetail(cloned.Id);
    }

    @AuraEnabled
    public static void bulkToggleActive(List<Id> slabIds, Boolean isActive) {
        List<Incentive_Slab__c> recs = [SELECT Id FROM Incentive_Slab__c WHERE Id IN :slabIds];
        for (Incentive_Slab__c r : recs) r.Is_Active__c = isActive;
        update recs;
    }

    @AuraEnabled
    public static void bulkDelete(List<Id> slabIds) {
        delete [SELECT Id FROM Incentive_Slab__c WHERE Id IN :slabIds];
    }

    private static List<Map<String, String>> getCriteriaOptions() {
        List<Map<String, String>> opts = new List<Map<String, String>>();
        opts.add(new Map<String, String>{ 'label' => '-- Universal (All Criteria) --', 'value' => '' });
        for (Target_Criteria__c tc : [
            SELECT Id, Name FROM Target_Criteria__c WHERE Active__c = true ORDER BY Name
        ]) {
            opts.add(new Map<String, String>{ 'label' => tc.Name, 'value' => tc.Id });
        }
        return opts;
    }

    private static List<Map<String, String>> getProfileOptions() {
        List<Map<String, String>> opts = new List<Map<String, String>>();
        opts.add(new Map<String, String>{ 'label' => '-- Universal (All Profiles) --', 'value' => '' });
        for (Profile p : [SELECT Id, Name FROM Profile WHERE UserType = 'Standard' ORDER BY Name]) {
            opts.add(new Map<String, String>{ 'label' => p.Name, 'value' => p.Name });
        }
        return opts;
    }

    private static List<Map<String, String>> getTerritoryOptions() {
        List<Map<String, String>> opts = new List<Map<String, String>>();
        opts.add(new Map<String, String>{ 'label' => '-- Universal (All Territories) --', 'value' => '' });
        for (Territory_Master__c tm : [
            SELECT Id, Name FROM Territory_Master__c WHERE Is_Active__c = true ORDER BY Name
        ]) {
            opts.add(new Map<String, String>{ 'label' => tm.Name, 'value' => tm.Id });
        }
        return opts;
    }
}