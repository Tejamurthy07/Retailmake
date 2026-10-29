/**
 * @description Controller for the Scheme Info display during outlet visits.
 *              Read-only controller that retrieves active schemes applicable
 *              to an outlet based on date range, channel, outlet type, and
 *              territory mapping.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class OVE_SchemeInfoController {

    public static final String FEATURE_SCHEME_INFO = 'SPM-001';

    /**
     * @description Retrieves active schemes valid for today, filtered by the
     *              outlet's type, channel, and territory mapping.
     * @param accountId The outlet Account Id.
     * @return List of active Scheme__c records with key info fields.
     */
    @AuraEnabled(cacheable=true)
    public static List<Scheme__c> getActiveSchemes(Id accountId) {
        try {
            if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_SCHEME_INFO)) {
                throw new AuraHandledException('Scheme Info feature is currently disabled.');
            }

            Date today = Date.today();

            String outletType = null;
            String channel = null;
            if (accountId != null) {
                List<Account> accounts = [
                    SELECT Id, Channel__c, Outlet_Type__c
                    FROM Account WHERE Id = :accountId LIMIT 1
                ];
                if (!accounts.isEmpty()) {
                    outletType = accounts[0].Outlet_Type__c;
                    channel = accounts[0].Channel__c;
                }
            }

            // Get mapped scheme Ids for this outlet
            Set<Id> mappedSchemeIds = new Set<Id>();
            if (accountId != null) {
                for (Scheme_Mapping__c m : [
                    SELECT Scheme__c FROM Scheme_Mapping__c
                    WHERE Is_Active__c = true
                      AND (Account__c = :accountId OR Account__c = null)
                ]) {
                    mappedSchemeIds.add(m.Scheme__c);
                }
            }

            // Pre-query schemes that have active mappings but are NOT mapped to this outlet.
            // These should be excluded. Schemes with no mappings at all are open to everyone.
            Set<Id> allMappedSchemeIds = new Set<Id>();
            for (Scheme_Mapping__c m : [
                SELECT Scheme__c FROM Scheme_Mapping__c
                WHERE Is_Active__c = true
            ]) {
                allMappedSchemeIds.add(m.Scheme__c);
            }
            // Exclude schemes that have mappings but none matching this outlet
            Set<Id> excludedSchemeIds = new Set<Id>();
            for (Id schemeId : allMappedSchemeIds) {
                if (!mappedSchemeIds.contains(schemeId)) {
                    excludedSchemeIds.add(schemeId);
                }
            }

            String query = 'SELECT Id, Name, Scheme_Code__c, Scheme_Category__c, Scheme_Type__c, ' +
                           'Description__c, Start_Date__c, End_Date__c, Status__c, Channel__c, ' +
                           'Discount_Percent__c, Discount_Amount__c, Price_Discount__c, ' +
                           'Reward_Points__c, MOV__c, Max_Discount_Cap__c, ' +
                           'Min_Quantity__c, Max_Quantity__c, Min_Value__c, Max_Value__c, ' +
                           'Invoice_Qty_Threshold__c, Invoice_Val_Threshold__c, ' +
                           'Free_Product_Ext__c, Free_Product_Ext__r.Name, Free_Quantity__c, ' +
                           'Product_Ext__c, Product_Category__c, ' +
                           'Applicable_Outlet_Type__c, Applicable_Channel__c, Applicable_Region__c, ' +
                           'Priority__c, Is_Stackable__c, Budget_Amount__c, Budget_Remaining__c ' +
                           'FROM Scheme__c ' +
                           'WHERE Is_Active__c = true ' +
                           'AND (Start_Date__c = null OR Start_Date__c <= :today) ' +
                           'AND (End_Date__c = null OR End_Date__c >= :today)';

            if (String.isNotBlank(outletType)) {
                query += ' AND (Applicable_Outlet_Type__c = null OR Applicable_Outlet_Type__c = :outletType ' +
                         'OR Outlet_Type__c = null OR Outlet_Type__c = :outletType)';
            }
            if (String.isNotBlank(channel)) {
                query += ' AND (Applicable_Channel__c = null OR Applicable_Channel__c = :channel ' +
                         'OR Channel__c = null OR Channel__c = :channel)';
            }

            // Territory mapping filter — exclude schemes mapped to other outlets only
            if (!excludedSchemeIds.isEmpty()) {
                query += ' AND Id NOT IN :excludedSchemeIds';
            }

            query += ' ORDER BY Priority__c ASC NULLS LAST, Name ASC LIMIT 100';

            return Database.query(query);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}