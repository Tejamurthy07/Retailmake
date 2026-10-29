/**
 * @description Service class for Competitor Activity tracking during outlet visits.
 *              Uses existing Competitor__c object with new Visit__c and Account__c lookups.
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class OVE_CompetitorActivity_Service {

    public static final String FEATURE_COMPETITOR = 'OVE-011';

    /**
     * Get competitor entries for a specific visit
     */
    public static List<Competitor__c> getCompetitorEntriesForVisit(Id visitId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_COMPETITOR)) {
            return new List<Competitor__c>();
        }
        return [
            SELECT Id, Name, Competitor_Company__c, Competitor_SKU__c, Competitor_Price__c,
                   Own_Product_Ext__c, Product_Category__c, Product_Category__r.Name,
                   Notes__c, Photo_URL__c, Activity_Date__c, Is_Active__c
            FROM Competitor__c
            WHERE Visit__c = :visitId
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Get distinct competitor companies for dropdown
     */
    public static List<String> getCompetitorMaster() {
        List<String> companies = new List<String>();
        for (AggregateResult ar : [
            SELECT Competitor_Company__c comp
            FROM Competitor__c
            WHERE Competitor_Company__c != null AND Is_Active__c = true
            GROUP BY Competitor_Company__c
            ORDER BY Competitor_Company__c
            LIMIT 200
        ]) {
            companies.add((String) ar.get('comp'));
        }
        return companies;
    }

    /**
     * Save a competitor entry linked to visit and account
     */
    public static Competitor__c saveCompetitorEntry(String entryJson) {
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(entryJson);

        Competitor__c entry = new Competitor__c();
        if (data.containsKey('id') && data.get('id') != null) {
            entry.Id = (Id) data.get('id');
        }
        entry.Visit__c = (Id) data.get('visitId');
        entry.Account__c = (Id) data.get('accountId');
        entry.Competitor_Company__c = (String) data.get('competitorCompany');
        entry.Competitor_SKU__c = (String) data.get('competitorSKU');
        if (data.containsKey('competitorPrice') && data.get('competitorPrice') != null) {
            entry.Competitor_Price__c = (Decimal) data.get('competitorPrice');
        }
        if (data.containsKey('ownProductId') && data.get('ownProductId') != null) {
            entry.Own_Product_Ext__c = (Id) data.get('ownProductId');
        }
        if (data.containsKey('productCategory') && data.get('productCategory') != null) {
            entry.Product_Category__c = (Id) data.get('productCategory');
        }
        entry.Notes__c = (String) data.get('notes');
        entry.Photo_URL__c = (String) data.get('photoURL');
        entry.Activity_Date__c = Date.today();
        entry.Is_Active__c = true;

        upsert entry;

        // Link an uploaded photo (ContentVersion) to this competitor record
        if (data.containsKey('photoContentVersionId') && data.get('photoContentVersionId') != null) {
            Id cvId = (Id) data.get('photoContentVersionId');
            FileAttachment_Util.linkFileToParent(cvId, entry.Id);
            String photoUrl = FileAttachment_Util.getFirstAttachmentUrl(entry.Id);
            if (photoUrl != null) {
                entry.Photo_URL__c = photoUrl;
                update entry;
            }
        }

        // Mark visit competitor check completed
        if (data.containsKey('visitId') && data.get('visitId') != null) {
            Visit__c visit = new Visit__c(Id = (Id) data.get('visitId'), Competitor_Check_Completed__c = true);
            update visit;
        }

        return entry;
    }

    /**
     * Delete a competitor entry
     */
    public static void deleteCompetitorEntry(Id entryId) {
        Competitor__c entry = [SELECT Id FROM Competitor__c WHERE Id = :entryId LIMIT 1];
        delete entry;
    }
}