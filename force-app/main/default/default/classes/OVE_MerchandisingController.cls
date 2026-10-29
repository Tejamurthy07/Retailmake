/**
 * @description Controller for Merchandising Audit - thin @AuraEnabled wrapper
 *              delegating to OVE_Merchandising_Service.
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class OVE_MerchandisingController {

    @AuraEnabled
    public static Merchandising__c getMerchandisingForVisit(Id visitId) {
        try {
            return OVE_Merchandising_Service.getMerchandisingForVisit(visitId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Merchandising__c saveMerchandising(String merchandisingJson) {
        try {
            return OVE_Merchandising_Service.saveMerchandising(merchandisingJson);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}