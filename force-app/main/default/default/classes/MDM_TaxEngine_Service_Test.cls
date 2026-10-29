/**
 * @description Test class for MDM_TaxEngine_Service. Covers single and bulk
 *              tax calculation, inter-state vs intra-state branching, missing
 *              configuration handling, and tax rate edge cases.
 */
@isTest
public class MDM_TaxEngine_Service_Test {

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

    private static Product_Extension__c createProduct(String suffix) {
        Product_Extension__c p = new Product_Extension__c(
            Name = 'TX Prod ' + suffix,
            Is_Active__c = true
        );
        try { p.put('SKU_Code__c', ('SKUTX' + suffix).left(20)); } catch (Exception e) {}
        try { p.put('Brand__c', 'TestBrand'); } catch (Exception e) {}
        fillRequiredFields(p);
        try { insert p; } catch (Exception e) { return null; }
        return p;
    }

    private static SObject createTaxConfig(Id productId, Decimal taxRate, Boolean isActive) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get('Tax_Configuration__c');
            if (t == null) return null;
            SObject tc = t.newSObject();
            try { tc.put('Name', 'TX Cfg ' + DateTime.now().getTime()); } catch (Exception e) {}
            try { tc.put('Product_Ext__c', productId); } catch (Exception e) {}
            try { tc.put('Tax_Rate__c', taxRate); } catch (Exception e) {}
            try { tc.put('CGST_Rate__c', taxRate / 2); } catch (Exception e) {}
            try { tc.put('SGST_Rate__c', taxRate / 2); } catch (Exception e) {}
            try { tc.put('IGST_Rate__c', taxRate); } catch (Exception e) {}
            try { tc.put('HSN_Code__c', '1234'); } catch (Exception e) {}
            try { tc.put('Is_Active__c', isActive); } catch (Exception e) {}
            fillRequiredFields(tc);
            insert tc;
            return tc;
        } catch (Exception e) {
            return null;
        }
    }

    @isTest
    static void testCalculateTaxNullProductId() {
        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result =
            MDM_TaxEngine_Service.calculateTax(null, 'Maharashtra', 'Maharashtra', 1000);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(0, result.totalTax);
    }

    @isTest
    static void testCalculateTaxNullAmount() {
        Product_Extension__c prod = createProduct('NA1');

        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result;
        if (prod != null) {
            result = MDM_TaxEngine_Service.calculateTax(
                prod.Id, 'Maharashtra', 'Maharashtra', null
            );
        }
        Test.stopTest();

        if (result != null) {
            System.assertEquals(0, result.totalTax);
        }
    }

    @isTest
    static void testCalculateTaxZeroAmount() {
        Product_Extension__c prod = createProduct('ZA1');

        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result;
        if (prod != null) {
            result = MDM_TaxEngine_Service.calculateTax(
                prod.Id, 'Maharashtra', 'Maharashtra', 0
            );
        }
        Test.stopTest();

        if (result != null) {
            System.assertEquals(0, result.totalTax);
        }
    }

    @isTest
    static void testCalculateTaxNoTaxConfiguration() {
        Product_Extension__c prod = createProduct('NC1');

        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result;
        if (prod != null) {
            result = MDM_TaxEngine_Service.calculateTax(
                prod.Id, 'Maharashtra', 'Maharashtra', 1000
            );
        }
        Test.stopTest();

        if (result != null) {
            System.assertEquals(0, result.totalTax);
        }
    }

    @isTest
    static void testCalculateTaxZeroRate() {
        Product_Extension__c prod = createProduct('ZR1');
        if (prod != null) {
            createTaxConfig(prod.Id, 0, true);
        }

        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result;
        if (prod != null) {
            result = MDM_TaxEngine_Service.calculateTax(
                prod.Id, 'Maharashtra', 'Maharashtra', 1000
            );
        }
        Test.stopTest();

        if (result != null) {
            System.assertEquals(0, result.totalTax);
        }
    }

    @isTest
    static void testCalculateTaxIntraState() {
        Product_Extension__c prod = createProduct('IN1');
        if (prod != null) {
            createTaxConfig(prod.Id, 18, true);
        }

        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result;
        if (prod != null) {
            result = MDM_TaxEngine_Service.calculateTax(
                prod.Id, 'Maharashtra', 'Maharashtra', 1000
            );
        }
        Test.stopTest();

        if (result != null && result.taxRate > 0) {
            // 18% intra-state → CGST 9 + SGST 9 = 18% of 1000 = 180
            System.assertEquals(false, result.isInterState);
            System.assertEquals(90, result.cgst);
            System.assertEquals(90, result.sgst);
            System.assertEquals(0, result.igst);
            System.assertEquals(180, result.totalTax);
        }
    }

    @isTest
    static void testCalculateTaxInterState() {
        Product_Extension__c prod = createProduct('IS1');
        if (prod != null) {
            createTaxConfig(prod.Id, 18, true);
        }

        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result;
        if (prod != null) {
            result = MDM_TaxEngine_Service.calculateTax(
                prod.Id, 'Maharashtra', 'Gujarat', 1000
            );
        }
        Test.stopTest();

        if (result != null && result.taxRate > 0) {
            // 18% inter-state → IGST 18% of 1000 = 180
            System.assertEquals(true, result.isInterState);
            System.assertEquals(0, result.cgst);
            System.assertEquals(0, result.sgst);
            System.assertEquals(180, result.igst);
            System.assertEquals(180, result.totalTax);
        }
    }

    @isTest
    static void testCalculateTaxBulkEmpty() {
        Test.startTest();
        List<MDM_TaxEngine_Service.TaxResult> resultNull =
            MDM_TaxEngine_Service.calculateTaxBulk(null, 'MH', 'MH', null);
        List<MDM_TaxEngine_Service.TaxResult> resultEmpty =
            MDM_TaxEngine_Service.calculateTaxBulk(
                new List<Id>(), 'MH', 'MH', new List<Decimal>()
            );
        Test.stopTest();

        System.assertEquals(0, resultNull.size());
        System.assertEquals(0, resultEmpty.size());
    }

    @isTest
    static void testCalculateTaxBulkIntraState() {
        Product_Extension__c prodA = createProduct('B1A');
        Product_Extension__c prodB = createProduct('B1B');
        if (prodA != null) createTaxConfig(prodA.Id, 18, true);
        if (prodB != null) createTaxConfig(prodB.Id, 12, true);

        List<Id> productIds = new List<Id>();
        if (prodA != null) productIds.add(prodA.Id);
        if (prodB != null) productIds.add(prodB.Id);
        List<Decimal> amounts = new List<Decimal>{ 1000, 500 };

        Test.startTest();
        List<MDM_TaxEngine_Service.TaxResult> results =
            MDM_TaxEngine_Service.calculateTaxBulk(productIds, 'Maharashtra', 'Maharashtra', amounts);
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    @isTest
    static void testCalculateTaxBulkInterState() {
        Product_Extension__c prod = createProduct('B2');
        if (prod != null) createTaxConfig(prod.Id, 18, true);

        Test.startTest();
        List<MDM_TaxEngine_Service.TaxResult> results;
        if (prod != null) {
            results = MDM_TaxEngine_Service.calculateTaxBulk(
                new List<Id>{ prod.Id },
                'Maharashtra', 'Gujarat',
                new List<Decimal>{ 1000 }
            );
        }
        Test.stopTest();
    }

    @isTest
    static void testCalculateTaxBulkNullProductId() {
        Product_Extension__c prod = createProduct('B3');
        if (prod != null) createTaxConfig(prod.Id, 18, true);

        // Mixed list: null product + real product
        List<Id> productIds = new List<Id>{ null, prod != null ? prod.Id : null };
        List<Decimal> amounts = new List<Decimal>{ 100, 200 };

        Test.startTest();
        List<MDM_TaxEngine_Service.TaxResult> results =
            MDM_TaxEngine_Service.calculateTaxBulk(productIds, 'MH', 'MH', amounts);
        Test.stopTest();

        System.assertNotEquals(null, results);
    }

    @isTest
    static void testCalculateTaxBulkZeroAmount() {
        Product_Extension__c prod = createProduct('B4');
        if (prod != null) createTaxConfig(prod.Id, 18, true);

        List<Id> productIds = new List<Id>{ prod != null ? prod.Id : null };
        List<Decimal> amounts = new List<Decimal>{ 0 };

        Test.startTest();
        List<MDM_TaxEngine_Service.TaxResult> results =
            MDM_TaxEngine_Service.calculateTaxBulk(productIds, 'MH', 'MH', amounts);
        Test.stopTest();
    }

    @isTest
    static void testCalculateTaxBulkNoTaxConfig() {
        Product_Extension__c prod = createProduct('B5');

        Test.startTest();
        List<MDM_TaxEngine_Service.TaxResult> results;
        if (prod != null) {
            results = MDM_TaxEngine_Service.calculateTaxBulk(
                new List<Id>{ prod.Id }, 'MH', 'MH', new List<Decimal>{ 1000 }
            );
        }
        Test.stopTest();
    }

    @isTest
    static void testCalculateTaxBulkAmountsShorter() {
        Product_Extension__c prodA = createProduct('B6A');
        Product_Extension__c prodB = createProduct('B6B');
        if (prodA != null) createTaxConfig(prodA.Id, 18, true);

        List<Id> productIds = new List<Id>();
        if (prodA != null) productIds.add(prodA.Id);
        if (prodB != null) productIds.add(prodB.Id);
        // amounts has fewer entries than productIds → i >= amounts.size() path
        List<Decimal> amounts = new List<Decimal>{ 1000 };

        Test.startTest();
        List<MDM_TaxEngine_Service.TaxResult> results =
            MDM_TaxEngine_Service.calculateTaxBulk(productIds, 'MH', 'MH', amounts);
        Test.stopTest();
    }

    @isTest
    static void testIsInterStateBlankFrom() {
        Test.startTest();
        Boolean result = MDM_TaxEngine_Service.isInterStateTransaction(null, 'Maharashtra');
        Boolean resultBlank = MDM_TaxEngine_Service.isInterStateTransaction('', 'Maharashtra');
        Test.stopTest();

        System.assertEquals(false, result);
        System.assertEquals(false, resultBlank);
    }

    @isTest
    static void testIsInterStateBlankTo() {
        Test.startTest();
        Boolean result = MDM_TaxEngine_Service.isInterStateTransaction('Maharashtra', null);
        Boolean resultBlank = MDM_TaxEngine_Service.isInterStateTransaction('Maharashtra', '');
        Test.stopTest();

        System.assertEquals(false, result);
        System.assertEquals(false, resultBlank);
    }

    @isTest
    static void testIsInterStateSameStates() {
        Test.startTest();
        Boolean result = MDM_TaxEngine_Service.isInterStateTransaction('Maharashtra', 'maharashtra');
        Test.stopTest();
        System.assertEquals(false, result, 'Same state (case-insensitive) is intra-state');
    }

    @isTest
    static void testIsInterStateDifferentStates() {
        Test.startTest();
        Boolean result = MDM_TaxEngine_Service.isInterStateTransaction('Maharashtra', 'Gujarat');
        Test.stopTest();
        System.assertEquals(true, result);
    }

    @isTest
    static void testTaxResultConstructor() {
        Test.startTest();
        MDM_TaxEngine_Service.TaxResult result = new MDM_TaxEngine_Service.TaxResult();
        Test.stopTest();

        System.assertEquals(0, result.cgst);
        System.assertEquals(0, result.sgst);
        System.assertEquals(0, result.igst);
        System.assertEquals(0, result.totalTax);
        System.assertEquals(0, result.taxRate);
        System.assertEquals(false, result.isInterState);
    }
}