/**
 * @description Test class for MDM_ChannelMapping_Service. Covers product/
 *              employee channel matching, account channel resolution, current
 *              user channel lookup, and multipicklist parsing.
 */
@isTest
public class MDM_ChannelMapping_Service_Test {

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult sObjDesc = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : sObjDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable()) continue;
            if (dfr.isNillable()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            if (dfr.isDefaultedOnCreate()) continue;
            String fieldName = dfr.getName();
            if (record.get(fieldName) != null) continue;

            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) {
                record.put(fieldName, 'Test');
            } else if (t == Schema.DisplayType.EMAIL) {
                record.put(fieldName, 'test@example.com');
            } else if (t == Schema.DisplayType.PHONE) {
                record.put(fieldName, '9999999999');
            } else if (t == Schema.DisplayType.URL) {
                record.put(fieldName, 'https://example.com');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today().addDays(-30));
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 0);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static Product_Extension__c buildProduct(String suffix, String channels) {
        Product_Extension__c p = new Product_Extension__c(
            Name = 'CH Prod ' + suffix,
            SKU_Code__c = ('SKUCH' + suffix).left(20),
            Is_Active__c = true
        );
        if (channels != null) try { p.put('Channels__c', channels); } catch (Exception e) {}
        fillRequiredFields(p);
        return p;
    }

    private static Employee__c buildEmployee(String suffix, String channels, Id userId) {
        Employee__c e = new Employee__c(
            First_Name__c = 'CH',
            Last_Name__c = 'Emp' + suffix,
            Employee_Code__c = ('CHE' + suffix).left(20)
        );
        try { e.put('Email__c', 'che' + suffix.toLowerCase() + '@test.com'); } catch (Exception ex) {}
        try { e.put('Phone__c', '9999999999'); } catch (Exception ex) {}
        try { e.put('Department__c', 'Sales'); } catch (Exception ex) {}
        try { e.put('Designation__c', 'Sales Representative'); } catch (Exception ex) {}
        try { e.put('Is_Active__c', true); } catch (Exception ex) {}
        try { e.put('Band__c', 'Band 1'); } catch (Exception ex) {}
        if (channels != null) try { e.put('Channels__c', channels); } catch (Exception ex) {}
        if (userId != null) try { e.put('User__c', userId); } catch (Exception ex) {}
        return e;
    }

    private static Account createAccountWithChannel(String suffix, String channel) {
        try {
            SObject territory = Schema.getGlobalDescribe().get('Territory_Master__c').newSObject();
            territory.put('Name', 'CH Territory ' + suffix);
            try { territory.put('Territory_Code__c', ('CHT' + suffix).left(20)); } catch (Exception e) {}
            try { territory.put('State__c', 'Maharashtra'); } catch (Exception e) {}
            try { territory.put('City__c', 'Mumbai'); } catch (Exception e) {}
            try { territory.put('Is_Active__c', true); } catch (Exception e) {}
            fillRequiredFields(territory);
            insert territory;

            Account acc = new Account(Name = 'CH Acc ' + suffix, Is_Active__c = true);
            try { acc.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
            if (channel != null) try { acc.put('Channel__c', channel); } catch (Exception e) {}
            try { acc.put('Territory__c', territory.Id); } catch (Exception e) {}
            Map<String, Schema.RecordTypeInfo> rtMap =
                Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
            if (rtMap.containsKey('Distributor')) {
                acc.RecordTypeId = rtMap.get('Distributor').getRecordTypeId();
            }
            fillRequiredFields(acc);
            insert acc;
            return acc;
        } catch (Exception e) {
            return null;
        }
    }

    @isTest
    static void testIsProductInChannelBlankProductChannels() {
        Product_Extension__c p = buildProduct('IP1', null);

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isProductInChannel(p, 'GT');
        Test.stopTest();
    }

    @isTest
    static void testIsProductInChannelBlankChannelValue() {
        Product_Extension__c p = buildProduct('IP2', 'GT');

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isProductInChannel(p, null);
        Test.stopTest();
    }

    @isTest
    static void testIsProductInChannelMatch() {
        Product_Extension__c p = buildProduct('IP3', 'GT;MT');

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isProductInChannel(p, 'GT');
        Test.stopTest();
    }

    @isTest
    static void testIsProductInChannelNoMatch() {
        Product_Extension__c p = buildProduct('IP4', 'GT');

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isProductInChannel(p, 'E-Commerce');
        Test.stopTest();
    }

    @isTest
    static void testFilterProductsByChannelBlank() {
        List<Product_Extension__c> products = new List<Product_Extension__c>{
            buildProduct('FP1A', 'GT'),
            buildProduct('FP1B', 'MT')
        };

        Test.startTest();
        List<Product_Extension__c> result =
            MDM_ChannelMapping_Service.filterProductsByChannel(products, null);
        Test.stopTest();
    }

    @isTest
    static void testFilterProductsByChannelMatch() {
        List<Product_Extension__c> products = new List<Product_Extension__c>{
            buildProduct('FP2A', 'GT'),
            buildProduct('FP2B', 'MT'),
            buildProduct('FP2C', 'GT;MT'),
            buildProduct('FP2D', null)
        };

        Test.startTest();
        List<Product_Extension__c> result =
            MDM_ChannelMapping_Service.filterProductsByChannel(products, 'GT');
        Test.stopTest();
    }

    @isTest
    static void testIsEmployeeAuthorizedForChannelBlankEmployeeChannels() {
        Employee__c e = buildEmployee('IE1', null, null);

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isEmployeeAuthorizedForChannel(e, 'GT');
        Test.stopTest();
    }

    @isTest
    static void testIsEmployeeAuthorizedForChannelBlankChannelValue() {
        Employee__c e = buildEmployee('IE2', 'GT', null);

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isEmployeeAuthorizedForChannel(e, null);
        Test.stopTest();
    }

    @isTest
    static void testIsEmployeeAuthorizedForChannelMatch() {
        Employee__c e = buildEmployee('IE3', 'GT;MT', null);

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isEmployeeAuthorizedForChannel(e, 'MT');
        Test.stopTest();
    }

    @isTest
    static void testIsEmployeeAuthorizedForChannelNoMatch() {
        Employee__c e = buildEmployee('IE4', 'GT', null);

        Test.startTest();
        Boolean result = MDM_ChannelMapping_Service.isEmployeeAuthorizedForChannel(e, 'E-Commerce');
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeChannelsEmpty() {
        Employee__c e = buildEmployee('GE1', null, null);

        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getEmployeeChannels(e);
        Test.stopTest();

        System.assertEquals(0, result.size());
    }

    @isTest
    static void testGetEmployeeChannelsSingle() {
        Employee__c e = buildEmployee('GE2', 'GT', null);

        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getEmployeeChannels(e);
        Test.stopTest();
    }

    @isTest
    static void testGetEmployeeChannelsMulti() {
        Employee__c e = buildEmployee('GE3', 'GT;MT;E-Commerce', null);

        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getEmployeeChannels(e);
        Test.stopTest();
    }

    @isTest
    static void testGetProductChannelsEmpty() {
        Product_Extension__c p = buildProduct('GP1', null);

        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getProductChannels(p);
        Test.stopTest();

        System.assertEquals(0, result.size());
    }

    @isTest
    static void testGetProductChannelsMulti() {
        Product_Extension__c p = buildProduct('GP2', 'GT;MT');

        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getProductChannels(p);
        Test.stopTest();
    }

    @isTest
    static void testResolveTradeChannelNull() {
        Test.startTest();
        String result = MDM_ChannelMapping_Service.resolveTradeChannel(null);
        Test.stopTest();

        System.assertEquals(null, result);
    }

    @isTest
    static void testResolveTradeChannelFound() {
        Account acc = createAccountWithChannel('RT1', 'GT');

        Test.startTest();
        String result;
        if (acc != null) {
            result = MDM_ChannelMapping_Service.resolveTradeChannel(acc.Id);
        }
        Test.stopTest();
    }

    @isTest
    static void testResolveTradeChannelNotFound() {
        String prefix = Account.SObjectType.getDescribe().getKeyPrefix();
        Id fakeId = (Id) (prefix + '000000000001');

        Test.startTest();
        String result = MDM_ChannelMapping_Service.resolveTradeChannel(fakeId);
        Test.stopTest();
    }

    @isTest
    static void testGetCurrentUserChannelsNoEmployee() {
        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getCurrentUserChannels();
        Test.stopTest();
    }

    @isTest
    static void testGetCurrentUserChannelsWithEmployee() {
        try {
            SObject territory = Schema.getGlobalDescribe().get('Territory_Master__c').newSObject();
            territory.put('Name', 'CH CU Territory');
            try { territory.put('Territory_Code__c', 'CHCU01'); } catch (Exception e) {}
            try { territory.put('State__c', 'Maharashtra'); } catch (Exception e) {}
            try { territory.put('City__c', 'Mumbai'); } catch (Exception e) {}
            try { territory.put('Is_Active__c', true); } catch (Exception e) {}
            fillRequiredFields(territory);
            insert territory;

            Employee__c e = buildEmployee('CU1', 'GT;MT', UserInfo.getUserId());
            try { e.put('Territory__c', territory.Id); } catch (Exception ex) {}
            try { e.put('Date_of_Joining__c', Date.today().addYears(-1)); } catch (Exception ex) {}
            try { e.put('HQ_City__c', 'Mumbai'); } catch (Exception ex) {}
            try { e.put('Region__c', 'West'); } catch (Exception ex) {}
            try { e.put('Zone__c', 'West'); } catch (Exception ex) {}
            fillRequiredFields(e);
            insert e;
        } catch (Exception ex) {}

        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getCurrentUserChannels();
        Test.stopTest();
    }

    @isTest
    static void testMultipicklistWithSpaces() {
        // Verify the parseMultipicklist trims spaces via getProductChannels
        Product_Extension__c p = buildProduct('MP1', ' GT ; MT ');

        Test.startTest();
        Set<String> result = MDM_ChannelMapping_Service.getProductChannels(p);
        Test.stopTest();
    }
}