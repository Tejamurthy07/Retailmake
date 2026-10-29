/**
 * @description Controller for Stock Check activity - thin @AuraEnabled wrapper
 *              delegating to OVE_StockCheck_Service.
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class OVE_StockCheckController {

    @AuraEnabled
    public static List<Distributor_Stock__c> getDistributorStock(Id accountId) {
        try {
            return OVE_StockCheck_Service.getDistributorStock(accountId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Product_Extension__c> getProductsForStockCheck(String searchTerm) {
        try {
            return OVE_StockCheck_Service.getProductsForStockCheck(searchTerm);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Distributor_Stock__c> saveStockEntries(String stockJson, Id visitId, Id accountId) {
        try {
            return OVE_StockCheck_Service.saveStockEntries(stockJson, visitId, accountId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Distributor_Stock__c> getLastStockCheck(Id accountId) {
        try {
            return OVE_StockCheck_Service.getLastStockCheck(accountId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}