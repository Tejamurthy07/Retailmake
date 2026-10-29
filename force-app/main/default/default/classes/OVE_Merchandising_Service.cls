/**
 * @description Service class for Merchandising Audit activity during outlet visits.
 *              Uses existing Merchandising__c object.
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class OVE_Merchandising_Service {

    public static final String FEATURE_MERCHANDISING = 'OVE-004';

    /**
     * Get merchandising record for a visit
     */
    public static Merchandising__c getMerchandisingForVisit(Id visitId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_MERCHANDISING)) {
            return null;
        }
        List<Merchandising__c> records = [
            SELECT Id, Name, Visit__c, Account__c, Audit_Date__c,
                   Own_Shelf_Share__c, Competitor_Shelf_Share__c, Planogram_Compliant__c,
                   POSM_Present__c, POSM_Condition__c, Photo_Before__c, Photo_After__c, Notes__c
            FROM Merchandising__c
            WHERE Visit__c = :visitId
            LIMIT 1
        ];
        return records.isEmpty() ? null : records[0];
    }

    /**
     * Save merchandising audit record
     */
    public static Merchandising__c saveMerchandising(String merchandisingJson) {
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(merchandisingJson);

        Merchandising__c merch = new Merchandising__c();
        if (data.containsKey('id') && data.get('id') != null) {
            merch.Id = (Id) data.get('id');
        }
        merch.Visit__c = (Id) data.get('visitId');
        merch.Account__c = (Id) data.get('accountId');
        merch.Audit_Date__c = Date.today();

        if (data.containsKey('ownShelfShare')) {
            merch.Own_Shelf_Share__c = data.get('ownShelfShare') != null ? (Decimal) data.get('ownShelfShare') : null;
        }
        if (data.containsKey('competitorShelfShare')) {
            merch.Competitor_Shelf_Share__c = data.get('competitorShelfShare') != null ? (Decimal) data.get('competitorShelfShare') : null;
        }
        if (data.containsKey('planogramCompliant')) {
            merch.Planogram_Compliant__c = (Boolean) data.get('planogramCompliant');
        }
        if (data.containsKey('posmPresent')) {
            merch.POSM_Present__c = (Boolean) data.get('posmPresent');
        }
        if (data.containsKey('posmCondition')) {
            merch.POSM_Condition__c = (String) data.get('posmCondition');
        }
        if (data.containsKey('photoBefore')) {
            merch.Photo_Before__c = (String) data.get('photoBefore');
        }
        if (data.containsKey('photoAfter')) {
            merch.Photo_After__c = (String) data.get('photoAfter');
        }
        merch.Notes__c = (String) data.get('notes');

        upsert merch;

        // Mark visit merchandising completed
        if (data.containsKey('visitId') && data.get('visitId') != null) {
            Visit__c visit = new Visit__c(Id = (Id) data.get('visitId'), Merchandising_Completed__c = true);
            update visit;
        }

        return merch;
    }
}