/**
 * @description Controller for Competitor Activity - thin @AuraEnabled wrapper
 *              delegating to OVE_CompetitorActivity_Service.
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class OVE_CompetitorActivityController {

    @AuraEnabled
    public static List<Competitor__c> getCompetitorEntriesForVisit(Id visitId) {
        try {
            return OVE_CompetitorActivity_Service.getCompetitorEntriesForVisit(visitId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<String> getCompetitorMaster() {
        try {
            return OVE_CompetitorActivity_Service.getCompetitorMaster();
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Competitor__c saveCompetitorEntry(String entryJson) {
        try {
            return OVE_CompetitorActivity_Service.saveCompetitorEntry(entryJson);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteCompetitorEntry(Id entryId) {
        try {
            OVE_CompetitorActivity_Service.deleteCompetitorEntry(entryId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}