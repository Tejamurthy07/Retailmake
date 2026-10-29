@isTest
private class API_Product_Rest_Test {

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            Schema.DescribeFieldResult dfr = Schema.getGlobalDescribe()
                .get(sObjectName).getDescribe().fields.getMap()
                .get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) { active.add(pe.getValue()); }
            }
            for (String p : preferred) {
                if (active.contains(p)) { return p; }
            }
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) { return pe.getValue(); }
            }
        } catch (Exception e) {}
        return null;
    }

    @TestSetup
    static void setup() {
        Product_Category__c category = new Product_Category__c(
            Name = 'Grains',
            Category_Code__c = 'GRN',
            Is_Active__c = true,
            Level__c = 'Category'
        );
        insert category;

        Product_Extension__c pe1 = new Product_Extension__c(
            Name = 'Rice Premium 25kg',
            Product_Category__c = category.Id,
            HSN_SAC_Code__c = 'RICE-P-25',
            Weight__c = 25,
            Weight_Unit__c = 'kg',
            Is_Active__c = true,
            Min_Order_Qty__c = 1,
            Barcode_EAN__c = '1234567890123'
        );

        // Second product without category/HSN to exercise null-handling branches.
        Product_Extension__c pe2 = new Product_Extension__c(
            Name = 'Rice Basic 10kg',
            Weight__c = 10,
            Weight_Unit__c = 'kg',
            Is_Active__c = true
        );

        // Third product inactive - must NOT appear (Is_Active__c=true filter).
        Product_Extension__c pe3 = new Product_Extension__c(
            Name = 'Discontinued SKU',
            Weight__c = 5,
            Weight_Unit__c = 'kg',
            Is_Active__c = false
        );

        insert new List<Product_Extension__c>{ pe1, pe2, pe3 };

        // Two active schemes for pe1 to exercise the "keep highest priority" branch.
        String schemeType = pickPicklistValue('Scheme__c', 'Scheme_Type__c',
            new List<String>{ 'Percentage', 'Discount', 'Flat', 'Slab', 'Trade' });

        Scheme__c scheme1 = TestDataFactory.createScheme('Rice Premium Discount A', 'SCH-001', schemeType);
        scheme1.Product_Ext__c = pe1.Id;
        scheme1.Discount_Percent__c = 5.00;
        scheme1.Priority__c = 1;
        scheme1.put('Budget_Amount__c', (Decimal) 10000);

        Scheme__c scheme2 = TestDataFactory.createScheme('Rice Premium Discount B', 'SCH-002', schemeType);
        scheme2.Product_Ext__c = pe1.Id;
        scheme2.Discount_Percent__c = 10.00;
        scheme2.Priority__c = 2;
        scheme2.put('Budget_Amount__c', (Decimal) 10000);

        insert new List<Scheme__c>{ scheme1, scheme2 };
    }

    @isTest
    static void testProductList() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/mobile/product/list';
        req.httpMethod = 'GET';

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        API_Product_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(res.responseBody.toString());
        System.assertEquals(true, result.get('status'));

        List<Object> data = (List<Object>) result.get('data');
        System.assert(!data.isEmpty(), 'Should return at least one product');

        // Find the premium row by name (order is ASC by Name; depends on data).
        Map<String, Object> premium;
        for (Object o : data) {
            Map<String, Object> row = (Map<String, Object>) o;
            if ('Rice Premium 25kg'.equals(row.get('Name'))) { premium = row; break; }
        }
        System.assertNotEquals(null, premium, 'Premium row found');
        System.assertEquals('Grains', premium.get('Category__c'));
        System.assertEquals('RICE-P-25', premium.get('Product_Code__c'));
        System.assertEquals('kg', premium.get('Unit__c'));
        System.assertEquals(true, premium.get('Is_Active__c'));
        // First scheme by priority (1) is kept.
        System.assertEquals(5.00, ((Decimal) premium.get('Discount_Percentage__c')));
    }

    @isTest
    static void testProductListNoDiscount() {
        delete [SELECT Id FROM Scheme__c];

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/mobile/product/list';
        req.httpMethod = 'GET';

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        API_Product_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(200, res.statusCode);
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(res.responseBody.toString());
        List<Object> data = (List<Object>) result.get('data');
        Map<String, Object> first = (Map<String, Object>) data[0];
        System.assertEquals(0, (Integer) first.get('Discount_Percentage__c'));
        System.assertEquals('', first.get('Discount_Valid_From__c'));
        System.assertEquals('', first.get('Discount_Valid_To__c'));
    }

    @isTest
    static void testProductListNoProducts() {
        // Deactivate all products so the Is_Active__c=true filter returns empty.
        List<Product_Extension__c> pes = [SELECT Id, Is_Active__c FROM Product_Extension__c];
        for (Product_Extension__c pe : pes) pe.Is_Active__c = false;
        update pes;

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/mobile/product/list';
        req.httpMethod = 'GET';

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        API_Product_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(200, res.statusCode,
            'Empty product set still returns 200 with empty data list');
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(res.responseBody.toString());
        List<Object> data = (List<Object>) result.get('data');
        System.assertEquals(0, data.size(), 'No active products -> empty data');
    }

    @isTest
    static void testInvalidEndpoint() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.requestURI = '/services/apexrest/mobile/product/unknown';
        req.httpMethod = 'GET';

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        API_Product_Rest.handleGet();
        Test.stopTest();

        System.assertEquals(400, res.statusCode);
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_Product_Rest.handleGet(); } catch (Exception e) {}
        Test.stopTest();
    }
}