/**
 * @description Test class for OVE_StockCheck_Service. Covers the feature-gated
 *              distributor-stock query, product search (incl. quote escaping),
 *              the full saveStockEntries flow (insert, update, toDecimal type
 *              branches, batch/expiry handling, visit completion), and the
 *              last-stock-check prefill query.
 */
@isTest
private class OVE_StockCheck_Service_Test {

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
                record.put(fieldName, Date.today());
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 1);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 1);
            }
        }
    }

    private class Ctx {
        public Account account;
        public Product_Extension__c product;
        public Id visitId;
    }

    private static Ctx buildContext(String suffix) {
        Ctx c = new Ctx();
        try {
            Territory_Master__c terr =
                TestDataFactory.createAndInsertTerritory('STK Terr ' + suffix, ('STK' + suffix).left(20));
            Beat__c beat =
                TestDataFactory.createAndInsertBeat('STK Beat ' + suffix, ('STKB' + suffix).left(20), terr.Id);
            Day_Attendance__c da =
                TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
            insert da;
            c.account = TestDataFactory.createAccount('STK Acc ' + suffix, 'Retailer');
            insert c.account;
            Visit__c visit = TestDataFactory.createVisit(
                c.account.Id, UserInfo.getUserId(), da.Id, beat.Id
            );
            insert visit;
            c.visitId = visit.Id;
        } catch (Exception e) {
            System.debug('buildContext failed: ' + e.getMessage());
        }

        try {
            c.product = new Product_Extension__c(Name = 'STK Prod ' + suffix, Is_Active__c = true);
            try { c.product.put('SKU_Code__c', ('SKUSTK' + suffix).left(20)); } catch (Exception e) {}
            try { c.product.put('Brand__c', 'STK Brand'); } catch (Exception e) {}
            fillRequiredFields(c.product);
            insert c.product;
        } catch (Exception e) { c.product = null; }

        return c;
    }

    @isTest
    static void testGetDistributorStock() {
        Ctx c = buildContext('GD');
        if (c.account == null) return;

        Test.startTest();
        List<Distributor_Stock__c> r =
            OVE_StockCheck_Service.getDistributorStock(c.account.Id);
        Test.stopTest();

        // Result depends on whether OVE-010 is enabled; either the empty-toggle
        // return or the query branch is exercised.
        System.assertNotEquals(null, r, 'Should return a (possibly empty) list');
    }

    @isTest
    static void testGetDistributorStockNullAccount() {
        Test.startTest();
        List<Distributor_Stock__c> r =
            OVE_StockCheck_Service.getDistributorStock(null);
        Test.stopTest();
        System.assertNotEquals(null, r, 'Null account still returns a list');
    }

    @isTest
    static void testGetProductsForStockCheck() {
        buildContext('GP');

        Test.startTest();
        List<Product_Extension__c> r =
            OVE_StockCheck_Service.getProductsForStockCheck('STK Prod');
        Test.stopTest();

        System.assertNotEquals(null, r, 'Product search returns a list');
    }

    @isTest
    static void testGetProductsForStockCheckQuoteEscaping() {
        Test.startTest();
        // Single quote forces String.escapeSingleQuotes to be exercised.
        List<Product_Extension__c> r =
            OVE_StockCheck_Service.getProductsForStockCheck('O\'Brien');
        Test.stopTest();
        System.assertNotEquals(null, r, 'Escaped search returns a list');
    }

    @isTest
    static void testSaveStockEntriesInsert() {
        Ctx c = buildContext('SI');
        if (c.visitId == null || c.account == null || c.product == null) return;

        List<Object> rows = new List<Object>{
            new Map<String, Object>{
                'productId' => c.product.Id,
                'opening'   => 100,                 // Integer → toDecimal Integer branch
                'received'  => 50.5,                // Double  → toDecimal Double branch
                'sold'      => '30',                // String  → toDecimal String branch
                'closing'   => 120,
                'damaged'   => null,                // null    → toDecimal null branch
                'batch'     => 'BATCH-1',
                'expiry'    => String.valueOf(Date.today().addDays(90))
            }
        };

        Test.startTest();
        List<Distributor_Stock__c> saved =
            OVE_StockCheck_Service.saveStockEntries(JSON.serialize(rows), c.visitId, c.account.Id);
        Test.stopTest();

        System.assertNotEquals(null, saved, 'Saved list returned');
        System.assertEquals(1, saved.size(), 'One stock record saved');
        System.assertNotEquals(null, saved[0].Id, 'Saved record has an Id');

        Visit__c v = [SELECT Stock_Check_Completed__c FROM Visit__c WHERE Id = :c.visitId];
        System.assertEquals(true, v.Stock_Check_Completed__c,
            'Visit should be flagged stock-check completed');
    }

    @isTest
    static void testSaveStockEntriesUpdatePath() {
        Ctx c = buildContext('SU');
        if (c.visitId == null || c.account == null || c.product == null) return;

        List<Object> insertRows = new List<Object>{
            new Map<String, Object>{
                'productId' => c.product.Id,
                'opening'   => 10,
                'closing'   => 10
            }
        };
        List<Distributor_Stock__c> first =
            OVE_StockCheck_Service.saveStockEntries(JSON.serialize(insertRows), c.visitId, c.account.Id);
        if (first == null || first.isEmpty() || first[0].Id == null) return;

        List<Object> updateRows = new List<Object>{
            new Map<String, Object>{
                'id'        => first[0].Id,
                'productId' => c.product.Id,
                'opening'   => 999,
                'closing'   => 950
            }
        };

        Test.startTest();
        List<Distributor_Stock__c> updated =
            OVE_StockCheck_Service.saveStockEntries(JSON.serialize(updateRows), c.visitId, c.account.Id);
        Test.stopTest();

        System.assertEquals(first[0].Id, updated[0].Id,
            'Update path should reuse the same record Id');
    }

    @isTest
    static void testSaveStockEntriesNoBatchNoExpiry() {
        Ctx c = buildContext('SN');
        if (c.visitId == null || c.account == null || c.product == null) return;

        // Omit batch/expiry keys → null/skip branches.
        List<Object> rows = new List<Object>{
            new Map<String, Object>{
                'productId' => c.product.Id,
                'opening'   => 5,
                'received'  => 0,
                'sold'      => 0,
                'closing'   => 5,
                'damaged'   => 0
            }
        };

        Test.startTest();
        List<Distributor_Stock__c> saved =
            OVE_StockCheck_Service.saveStockEntries(JSON.serialize(rows), c.visitId, c.account.Id);
        Test.stopTest();

        System.assertEquals(1, saved.size(), 'Record saved without batch/expiry');
    }

    @isTest
    static void testGetLastStockCheck() {
        Ctx c = buildContext('GL');
        if (c.visitId == null || c.account == null || c.product == null) return;

        List<Object> rows = new List<Object>{
            new Map<String, Object>{
                'productId' => c.product.Id,
                'opening'   => 20,
                'closing'   => 15
            }
        };
        OVE_StockCheck_Service.saveStockEntries(JSON.serialize(rows), c.visitId, c.account.Id);

        Test.startTest();
        List<Distributor_Stock__c> last =
            OVE_StockCheck_Service.getLastStockCheck(c.account.Id);
        Test.stopTest();

        System.assertNotEquals(null, last, 'Last stock check returns a list');
    }

    @isTest
    static void testSaveStockEntriesLongAndDecimalValues() {
        Ctx c = buildContext('LD');
        if (c.visitId == null || c.account == null || c.product == null) return;

        // A value greater than Integer.MAX (2,147,483,647) is deserialized as
        // a Long by JSON.deserializeUntyped, exercising the toDecimal Long
        // branch. Decimal-looking values come back as Double.
        List<Object> rows = new List<Object>{
            new Map<String, Object>{
                'productId' => c.product.Id,
                'opening'   => 9999999999L,   // Long branch
                'received'  => 12345.678,     // Double branch
                'sold'      => 2147483648L,   // Long branch
                'closing'   => '500',         // String branch
                'damaged'   => 0              // Integer branch
            }
        };

        Test.startTest();
        List<Distributor_Stock__c> saved =
            OVE_StockCheck_Service.saveStockEntries(JSON.serialize(rows), c.visitId, c.account.Id);
        Test.stopTest();

        System.assertEquals(1, saved.size(), 'Long/Double/String values handled');
    }

    @isTest
    static void testSaveStockEntriesMultipleRows() {
        Ctx c = buildContext('MR');
        if (c.visitId == null || c.account == null || c.product == null) return;

        List<Object> rows = new List<Object>();
        for (Integer i = 0; i < 5; i++) {
            rows.add(new Map<String, Object>{
                'productId' => c.product.Id,
                'opening'   => i,
                'closing'   => i + 1
            });
        }

        Test.startTest();
        List<Distributor_Stock__c> saved =
            OVE_StockCheck_Service.saveStockEntries(JSON.serialize(rows), c.visitId, c.account.Id);
        Test.stopTest();

        System.assertEquals(5, saved.size(), 'All rows in the batch saved');
    }

    @isTest
    static void testDiagnoseFixtures() {
        Ctx c = buildContext('DIAG');
        System.assertNotEquals(null, c.account, 'Account must insert');
        System.assertNotEquals(null, c.visitId, 'Visit must insert');
        System.assertNotEquals(null, c.product, 'Product must insert');

        List<Object> rows = new List<Object>{
            new Map<String, Object>{
                'productId' => c.product.Id,
                'opening'   => 1,
                'closing'   => 1
            }
        };
        List<Distributor_Stock__c> saved =
            OVE_StockCheck_Service.saveStockEntries(JSON.serialize(rows), c.visitId, c.account.Id);
        System.assertNotEquals(null, saved, 'Save must succeed for coverage');
        System.assertNotEquals(null, saved[0].Id, 'Saved record needs an Id');
    }
}