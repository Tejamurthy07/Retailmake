public with sharing class MDM_ChannelMapping_Service {

    private static final String FEATURE_CODE = 'MDM-003';

    public static Boolean isProductInChannel(Product_Extension__c product, String channelValue) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            return true;
        }
        if (String.isBlank(product.Channels__c)) {
            return true;
        }
        if (String.isBlank(channelValue)) {
            return true;
        }
        return parseMultipicklist(product.Channels__c).contains(channelValue);
    }

    public static List<Product_Extension__c> filterProductsByChannel(
        List<Product_Extension__c> products, String channelValue
    ) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            return products;
        }
        if (String.isBlank(channelValue)) {
            return products;
        }
        List<Product_Extension__c> filtered = new List<Product_Extension__c>();
        for (Product_Extension__c p : products) {
            if (isProductInChannel(p, channelValue)) {
                filtered.add(p);
            }
        }
        return filtered;
    }

    public static Boolean isEmployeeAuthorizedForChannel(Employee__c emp, String channelValue) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            return true;
        }
        if (String.isBlank(emp.Channels__c)) {
            return true;
        }
        if (String.isBlank(channelValue)) {
            return true;
        }
        return parseMultipicklist(emp.Channels__c).contains(channelValue);
    }

    public static Set<String> getEmployeeChannels(Employee__c emp) {
        if (String.isBlank(emp.Channels__c)) {
            return new Set<String>();
        }
        return parseMultipicklist(emp.Channels__c);
    }

    public static Set<String> getProductChannels(Product_Extension__c prod) {
        if (String.isBlank(prod.Channels__c)) {
            return new Set<String>();
        }
        return parseMultipicklist(prod.Channels__c);
    }

    public static String resolveTradeChannel(Id accountId) {
        if (accountId == null) {
            return null;
        }
        List<Account> accts = [
            SELECT Channel__c FROM Account WHERE Id = :accountId LIMIT 1
        ];
        return accts.isEmpty() ? null : accts[0].Channel__c;
    }

    public static Set<String> getCurrentUserChannels() {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_CODE)) {
            return new Set<String>();
        }
        List<Employee__c> emps = [
            SELECT Id, Channels__c FROM Employee__c
            WHERE User__c = :UserInfo.getUserId() AND Is_Active__c = true
            LIMIT 1
        ];
        if (emps.isEmpty()) {
            return new Set<String>();
        }
        return getEmployeeChannels(emps[0]);
    }

    private static Set<String> parseMultipicklist(String value) {
        Set<String> result = new Set<String>();
        if (String.isNotBlank(value)) {
            for (String s : value.split(';')) {
                result.add(s.trim());
            }
        }
        return result;
    }
}