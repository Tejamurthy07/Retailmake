/**
 * @description Admin controller for managing Expense Eligibility rules and rate configurations.
 */
public with sharing class EXP_EligibilityAdmin_Controller {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAdminData() {
        Map<String, Object> result = new Map<String, Object>();

        // Get all eligibility rules with child rate slabs
        List<Expense_Eligibility__c> rules = [
            SELECT Id, Name, Band__c, Expense_Type__c, Expense_Category__c,
                   Rate_Type__c, Rate_Amount__c, Max_Per_Day__c, Max_Per_Month__c,
                   Min_Distance_KM__c, Receipt_Required__c, Receipt_Threshold__c,
                   Is_Active__c, Sort_Order__c, Description__c,
                   Auto_Create__c, Travel_Type__c, Travel_Mode__c, Mandatory_Remarks__c,
                   Daily_KM_Limit__c, Lodging_Metro_Limit__c, Lodging_Non_Metro_Limit__c,
                   Allowed_Travel_Modes__c, Effective_From__c, Effective_To__c,
                   City_Tier_1_Limit__c, City_Tier_2_Limit__c, City_Tier_3_Limit__c,
                   (SELECT Id, Travel_Mode__c, Rate_Type__c, Rate_Amount__c, Max_Amount__c,
                           Distance_From__c, Distance_To__c, Sort_Order__c
                    FROM Expense_Rate_Slabs__r ORDER BY Travel_Mode__c ASC, Sort_Order__c ASC)
            FROM Expense_Eligibility__c
            ORDER BY Band__c ASC, Sort_Order__c ASC, Expense_Type__c ASC
        ];
        result.put('rules', rules);

        // Get city tiers
        List<City_Tier__c> cityTiers = [
            SELECT Id, Name, Tier__c, State__c, Is_Active__c
            FROM City_Tier__c
            ORDER BY Tier__c ASC, Name ASC
        ];
        result.put('cityTiers', cityTiers);

        return result;
    }

    @AuraEnabled
    public static Map<String, Object> refreshAdminData() {
        return getAdminData();
    }

    @AuraEnabled
    public static Expense_Eligibility__c saveEligibilityRule(Expense_Eligibility__c rule) {
        try {
            upsert rule;
            // Re-query to get full record with Name
            return [
                SELECT Id, Name, Band__c, Expense_Type__c, Expense_Category__c,
                       Rate_Type__c, Rate_Amount__c, Max_Per_Day__c, Max_Per_Month__c,
                       Min_Distance_KM__c, Receipt_Required__c, Receipt_Threshold__c,
                       Is_Active__c, Sort_Order__c, Description__c,
                       Auto_Create__c, Travel_Type__c, Travel_Mode__c, Mandatory_Remarks__c,
                       Daily_KM_Limit__c, Lodging_Metro_Limit__c, Lodging_Non_Metro_Limit__c,
                       Allowed_Travel_Modes__c, Effective_From__c, Effective_To__c,
                       City_Tier_1_Limit__c, City_Tier_2_Limit__c, City_Tier_3_Limit__c,
                       (SELECT Id, Travel_Mode__c, Rate_Type__c, Rate_Amount__c, Max_Amount__c,
                               Distance_From__c, Distance_To__c, Sort_Order__c
                        FROM Expense_Rate_Slabs__r ORDER BY Travel_Mode__c ASC, Sort_Order__c ASC)
                FROM Expense_Eligibility__c WHERE Id = :rule.Id LIMIT 1
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Expense_Rate_Slab__c> saveRateSlabs(Id eligibilityId, List<Expense_Rate_Slab__c> slabs, List<Id> deletedSlabIds) {
        try {
            // Delete removed slabs
            if (deletedSlabIds != null && !deletedSlabIds.isEmpty()) {
                delete [SELECT Id FROM Expense_Rate_Slab__c WHERE Id IN :deletedSlabIds];
            }

            // Set parent for new slabs and upsert
            for (Expense_Rate_Slab__c slab : slabs) {
                if (slab.Expense_Eligibility__c == null) {
                    slab.Expense_Eligibility__c = eligibilityId;
                }
            }
            upsert slabs;

            // Return updated list
            return [
                SELECT Id, Travel_Mode__c, Rate_Type__c, Rate_Amount__c, Max_Amount__c,
                       Distance_From__c, Distance_To__c, Sort_Order__c
                FROM Expense_Rate_Slab__c
                WHERE Expense_Eligibility__c = :eligibilityId
                ORDER BY Travel_Mode__c ASC, Sort_Order__c ASC
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteEligibilityRule(Id ruleId) {
        try {
            delete [SELECT Id FROM Expense_Eligibility__c WHERE Id = :ruleId];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Expense_Eligibility__c cloneEligibilityRule(Id sourceRuleId, String newBand, String newDutyType) {
        try {
            Expense_Eligibility__c source = [
                SELECT Band__c, Expense_Type__c, Expense_Category__c,
                       Rate_Type__c, Rate_Amount__c, Max_Per_Day__c, Max_Per_Month__c,
                       Min_Distance_KM__c, Receipt_Required__c, Receipt_Threshold__c,
                       Sort_Order__c, Description__c, Auto_Create__c, Travel_Type__c,
                       Mandatory_Remarks__c, Daily_KM_Limit__c,
                       Lodging_Metro_Limit__c, Lodging_Non_Metro_Limit__c,
                       Allowed_Travel_Modes__c, Effective_From__c, Effective_To__c,
                       City_Tier_1_Limit__c, City_Tier_2_Limit__c, City_Tier_3_Limit__c,
                       (SELECT Travel_Mode__c, Rate_Type__c, Rate_Amount__c, Max_Amount__c,
                               Distance_From__c, Distance_To__c, Sort_Order__c
                        FROM Expense_Rate_Slabs__r)
                FROM Expense_Eligibility__c WHERE Id = :sourceRuleId LIMIT 1
            ];

            // Create clone
            Expense_Eligibility__c clone = source.clone(false, true);
            clone.Band__c = String.isNotBlank(newBand) ? newBand : source.Band__c;
            clone.Travel_Type__c = String.isNotBlank(newDutyType) ? newDutyType : source.Travel_Type__c;
            clone.Is_Active__c = true;
            insert clone;

            // Clone child slabs
            List<Expense_Rate_Slab__c> clonedSlabs = new List<Expense_Rate_Slab__c>();
            if (source.Expense_Rate_Slabs__r != null) {
                for (Expense_Rate_Slab__c slab : source.Expense_Rate_Slabs__r) {
                    Expense_Rate_Slab__c clonedSlab = slab.clone(false, true);
                    clonedSlab.Expense_Eligibility__c = clone.Id;
                    clonedSlabs.add(clonedSlab);
                }
                if (!clonedSlabs.isEmpty()) {
                    insert clonedSlabs;
                }
            }

            // Return full record
            return [
                SELECT Id, Name, Band__c, Expense_Type__c, Expense_Category__c,
                       Rate_Type__c, Rate_Amount__c, Max_Per_Day__c, Max_Per_Month__c,
                       Min_Distance_KM__c, Receipt_Required__c, Receipt_Threshold__c,
                       Is_Active__c, Sort_Order__c, Description__c,
                       Auto_Create__c, Travel_Type__c, Travel_Mode__c, Mandatory_Remarks__c,
                       Daily_KM_Limit__c, Lodging_Metro_Limit__c, Lodging_Non_Metro_Limit__c,
                       Allowed_Travel_Modes__c, Effective_From__c, Effective_To__c,
                       City_Tier_1_Limit__c, City_Tier_2_Limit__c, City_Tier_3_Limit__c,
                       (SELECT Id, Travel_Mode__c, Rate_Type__c, Rate_Amount__c, Max_Amount__c,
                               Distance_From__c, Distance_To__c, Sort_Order__c
                        FROM Expense_Rate_Slabs__r ORDER BY Travel_Mode__c ASC, Sort_Order__c ASC)
                FROM Expense_Eligibility__c WHERE Id = :clone.Id LIMIT 1
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static City_Tier__c saveCityTier(City_Tier__c cityTier) {
        try {
            upsert cityTier;
            return [SELECT Id, Name, Tier__c, State__c, Is_Active__c FROM City_Tier__c WHERE Id = :cityTier.Id];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteCityTier(Id cityTierId) {
        try {
            delete [SELECT Id FROM City_Tier__c WHERE Id = :cityTierId];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}