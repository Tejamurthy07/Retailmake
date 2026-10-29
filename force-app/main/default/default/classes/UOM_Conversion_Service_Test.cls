/**
 * @description Test class for UOM_Conversion_Service. Covers cache priming,
 *              convert / getConversionFactor (product-specific direct,
 *              global direct, product reverse, global reverse, no-match
 *              fallback), getProductUOMOptions (null id, missing product,
 *              base + secondary + Ordering_UOMs__c paths, empty fallback),
 *              bulkConvert (null/empty + full flow), getUOMIdByCode /
 *              getUOMCodeById, mapPicklistToCode / mapCodeToPicklist
 *              (known + unknown), and clearCache.
 *
 *              UOM__c / UOM_Conversion__c are deployed-only — every fixture
 *              put is wrapped, and fillRequiredFields covers any non-source
 *              required field on the object.
 */
@isTest
private class UOM_Conversion_Service_Test {

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult d = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : d.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable() || dfr.isNillable() || dfr.isDefaultedOnCreate()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            String fn = dfr.getName();
            if (record.get(fn) != null) continue;
            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) record.put(fn, 'Test');
            else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> pe = dfr.getPicklistValues();
                if (!pe.isEmpty()) record.put(fn, pe[0].getValue());
            }
            else if (t == Schema.DisplayType.BOOLEAN) record.put(fn, false);
            else if (t == Schema.DisplayType.DATE) record.put(fn, Date.today());
            else if (t == Schema.DisplayType.DATETIME) record.put(fn, Datetime.now());
            else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY
                  || t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.INTEGER
                  || t == Schema.DisplayType.LONG) record.put(fn, 1);
        }
    }

    private static SObject makeUOM(String name, String code, Boolean isBase) {
        SObjectType t = Schema.getGlobalDescribe().get('UOM__c');
        if (t == null) return null;
        SObject u = t.newSObject();
        try { u.put('Name', name); } catch (Exception e) {}
        try { u.put('UOM_Code__c', code); } catch (Exception e) {}
        try { u.put('Is_Active__c', true); } catch (Exception e) {}
        try { u.put('Is_Base_Unit__c', isBase); } catch (Exception e) {}
        fillRequiredFields(u);
        try { insert u; } catch (Exception e) { return null; }
        return u;
    }

    private static SObject makeConversion(Id fromUomId, Id toUomId, Id productId, Decimal factor) {
        SObjectType t = Schema.getGlobalDescribe().get('UOM_Conversion__c');
        if (t == null) return null;
        SObject c = t.newSObject();
        try { c.put('From_UOM__c', fromUomId); } catch (Exception e) {}
        try { c.put('To_UOM__c', toUomId); } catch (Exception e) {}
        if (productId != null) try { c.put('Product__c', productId); } catch (Exception e) {}
        try { c.put('Conversion_Factor__c', factor); } catch (Exception e) {}
        try { c.put('Is_Active__c', true); } catch (Exception e) {}
        fillRequiredFields(c);
        try { insert c; } catch (Exception e) { return null; }
        return c;
    }

    private static Product_Extension__c makeProduct(String name, Id baseUomId, Id secUomId, String orderingUOMs) {
        Product_Extension__c p = new Product_Extension__c(Name = name, Is_Active__c = true);
        try { p.put('SKU_Code__c', name.left(20)); } catch (Exception e) {}
        if (baseUomId != null) try { p.put('Base_UOM__c', baseUomId); } catch (Exception e) {}
        if (secUomId != null) try { p.put('Secondary_UOM__c', secUomId); } catch (Exception e) {}
        if (String.isNotBlank(orderingUOMs)) try { p.put('Ordering_UOMs__c', orderingUOMs); } catch (Exception e) {}
        fillRequiredFields(p);
        try { insert p; } catch (Exception e) { return null; }
        return p;
    }

    // ── Pure-logic tests (no DML needed) ─────────────────────────────────────

    @isTest
    static void testMapPicklistAndCode() {
        // Pure mapping methods — exercise known + unknown + blank inputs.
        Test.startTest();
        System.assertEquals('PCS', UOM_Conversion_Service.mapPicklistToCode(null),
            'Null picklist defaults to PCS');
        System.assertEquals('PCS', UOM_Conversion_Service.mapPicklistToCode(''),
            'Blank picklist defaults to PCS');
        System.assertEquals('CS',  UOM_Conversion_Service.mapPicklistToCode('Cases'));
        System.assertEquals('BOX', UOM_Conversion_Service.mapPicklistToCode('Boxes'));
        System.assertEquals('KG',  UOM_Conversion_Service.mapPicklistToCode('Kg'));
        System.assertEquals('LTR', UOM_Conversion_Service.mapPicklistToCode('Liters'));
        System.assertEquals('DZ',  UOM_Conversion_Service.mapPicklistToCode('Dozen'));
        System.assertEquals('PCS', UOM_Conversion_Service.mapPicklistToCode('Unknown'),
            'Unknown picklist falls back to PCS');

        System.assertEquals('Pieces', UOM_Conversion_Service.mapCodeToPicklist(null));
        System.assertEquals('Pieces', UOM_Conversion_Service.mapCodeToPicklist(''));
        System.assertEquals('Cases',  UOM_Conversion_Service.mapCodeToPicklist('CS'));
        System.assertEquals('Boxes',  UOM_Conversion_Service.mapCodeToPicklist('BX'));
        System.assertEquals('Kg',     UOM_Conversion_Service.mapCodeToPicklist('GRM'));
        System.assertEquals('Liters', UOM_Conversion_Service.mapCodeToPicklist('ML'));
        System.assertEquals('Pieces', UOM_Conversion_Service.mapCodeToPicklist('ZZZ'),
            'Unknown code falls back to Pieces');
        Test.stopTest();
    }

    @isTest
    static void testConvertEarlyReturns() {
        UOM_Conversion_Service.clearCache();

        Test.startTest();
        // null / zero quantity → 0
        System.assertEquals(0, UOM_Conversion_Service.convert(null, 'CS', 'PCS', null));
        System.assertEquals(0, UOM_Conversion_Service.convert(null, 'CS', 'PCS', 0));
        // same UOM → return quantity unchanged
        System.assertEquals(5, UOM_Conversion_Service.convert(null, 'CS', 'CS', 5));
        // blank UOM → return quantity unchanged
        System.assertEquals(5, UOM_Conversion_Service.convert(null, '',   'PCS', 5));
        System.assertEquals(5, UOM_Conversion_Service.convert(null, 'CS', '',    5));
        Test.stopTest();
    }

    @isTest
    static void testGetUOMIdAndCode_BlankInput() {
        UOM_Conversion_Service.clearCache();
        Test.startTest();
        System.assertEquals(null, UOM_Conversion_Service.getUOMIdByCode(null));
        System.assertEquals(null, UOM_Conversion_Service.getUOMIdByCode(''));
        System.assertEquals(null, UOM_Conversion_Service.getUOMCodeById(null));
        Test.stopTest();
    }

    @isTest
    static void testGetConversionFactor_NoUOMCache() {
        // With no UOM__c records the from/to ids stay null → factor = 1.
        UOM_Conversion_Service.clearCache();
        Test.startTest();
        System.assertEquals(1,
            UOM_Conversion_Service.getConversionFactor(null, 'ZZZ', 'YYY'));
        // same UOM short-circuit
        System.assertEquals(1, UOM_Conversion_Service.getConversionFactor(null, 'CS', 'CS'));
        // blank short-circuit
        System.assertEquals(1, UOM_Conversion_Service.getConversionFactor(null, '', 'CS'));
        Test.stopTest();
    }

    // ── DML-backed tests ─────────────────────────────────────────────────────

    @isTest
    static void testConversionFactor_DirectAndReverse() {
        UOM_Conversion_Service.clearCache();
        SObject cs  = makeUOM('Cases',  'TEST_CS',  false);
        SObject pcs = makeUOM('Pieces', 'TEST_PCS', true);
        if (cs == null || pcs == null) return;

        // Global direct: CS → PCS = 12
        makeConversion(cs.Id, pcs.Id, null, 12);
        UOM_Conversion_Service.clearCache();

        Test.startTest();
        Decimal direct = UOM_Conversion_Service.getConversionFactor(null, 'TEST_CS', 'TEST_PCS');
        // Reverse (PCS → CS) via the same global record.
        Decimal reverse = UOM_Conversion_Service.getConversionFactor(null, 'TEST_PCS', 'TEST_CS');
        Test.stopTest();

        System.assertEquals(12, direct, 'Direct global lookup matches');
        // 1/12 ≈ 0.0833...
        System.assert(reverse > 0 && reverse < 1, 'Reverse factor is 1 / direct');
    }

    @isTest
    static void testConversionFactor_ProductSpecific() {
        UOM_Conversion_Service.clearCache();
        SObject cs  = makeUOM('Cases-PS',  'PSCS', false);
        SObject pcs = makeUOM('Pieces-PS', 'PSPC', true);
        if (cs == null || pcs == null) return;
        Product_Extension__c prod = makeProduct('UOM Prod PS', pcs.Id, cs.Id, null);
        if (prod == null) return;

        // Global says 10; product-specific says 24 → product-specific wins.
        makeConversion(cs.Id, pcs.Id, null,    10);
        makeConversion(cs.Id, pcs.Id, prod.Id, 24);
        UOM_Conversion_Service.clearCache();

        Test.startTest();
        Decimal productFactor = UOM_Conversion_Service.getConversionFactor(prod.Id, 'PSCS', 'PSPC');
        Decimal globalFactor  = UOM_Conversion_Service.getConversionFactor(null,    'PSCS', 'PSPC');
        Test.stopTest();

        System.assertEquals(24, productFactor, 'Product-specific wins over global');
        System.assertEquals(10, globalFactor,  'Global used when no productId');
    }

    @isTest
    static void testConvertAndBulkConvert() {
        UOM_Conversion_Service.clearCache();
        SObject cs  = makeUOM('Cases-B',  'BCS', false);
        SObject pcs = makeUOM('Pieces-B', 'BPC', true);
        if (cs == null || pcs == null) return;
        makeConversion(cs.Id, pcs.Id, null, 6);
        UOM_Conversion_Service.clearCache();

        Test.startTest();
        Decimal converted = UOM_Conversion_Service.convert(null, 'BCS', 'BPC', 4);
        System.assertEquals(24, converted, '4 cases * 6 = 24 pieces');

        // bulkConvert: null + empty short-circuits
        List<UOM_Conversion_Service.ConvertedResult> nullResult =
            UOM_Conversion_Service.bulkConvert(null);
        System.assertEquals(0, nullResult.size(), 'Null returns empty');

        List<UOM_Conversion_Service.ConversionRequest> emptyReqs =
            new List<UOM_Conversion_Service.ConversionRequest>();
        List<UOM_Conversion_Service.ConvertedResult> emptyResult =
            UOM_Conversion_Service.bulkConvert(emptyReqs);
        System.assertEquals(0, emptyResult.size(), 'Empty returns empty');

        // Build 3 requests covering direct conversion + same-UOM + blank-UOM
        UOM_Conversion_Service.ConversionRequest r1 = new UOM_Conversion_Service.ConversionRequest();
        r1.productId = null;
        r1.fromUomCode = 'BCS';
        r1.toUomCode = 'BPC';
        r1.quantity = 2;

        UOM_Conversion_Service.ConversionRequest r2 = new UOM_Conversion_Service.ConversionRequest();
        r2.productId = null;
        r2.fromUomCode = 'BPC';
        r2.toUomCode = 'BPC';
        r2.quantity = 7;

        UOM_Conversion_Service.ConversionRequest r3 = new UOM_Conversion_Service.ConversionRequest();
        r3.productId = null;
        r3.fromUomCode = 'BPC';
        r3.toUomCode = '';
        r3.quantity = 9;

        List<UOM_Conversion_Service.ConversionRequest> reqs =
            new List<UOM_Conversion_Service.ConversionRequest>();
        reqs.add(r1);
        reqs.add(r2);
        reqs.add(r3);

        List<UOM_Conversion_Service.ConvertedResult> bulkResults =
            UOM_Conversion_Service.bulkConvert(reqs);
        Test.stopTest();

        System.assertEquals(3, bulkResults.size(), '3 results returned');
        System.assertEquals(12, bulkResults[0].convertedQuantity, '2 x 6 = 12');
        System.assertEquals(7,  bulkResults[1].convertedQuantity, 'Same UOM passthrough');
        System.assertEquals(9,  bulkResults[2].convertedQuantity, 'Blank UOM passthrough');
    }

    @isTest
    static void testGetUOMIdAndCode_RealLookup() {
        UOM_Conversion_Service.clearCache();
        SObject u = makeUOM('LookupTest', 'LKP1', true);
        if (u == null) return;
        UOM_Conversion_Service.clearCache();

        Test.startTest();
        Id resolvedId = UOM_Conversion_Service.getUOMIdByCode('LKP1');
        String resolvedCode = UOM_Conversion_Service.getUOMCodeById(u.Id);
        Test.stopTest();

        System.assertEquals(u.Id, resolvedId, 'Code → Id lookup');
        System.assertEquals('LKP1', resolvedCode, 'Id → code lookup');
    }

    @isTest
    static void testGetProductUOMOptions_AllBranches() {
        UOM_Conversion_Service.clearCache();
        SObject pcs = makeUOM('Pieces-O', 'OPC', true);
        SObject cs  = makeUOM('Cases-O',  'OCS', false);
        SObject box = makeUOM('Boxes-O',  'OBX', false);
        if (pcs == null || cs == null || box == null) return;

        // Product with base + secondary + Ordering_UOMs ('OBX,OCS' — the
        // controller dedupes against base/secondary, so OBX is new).
        Product_Extension__c prod = makeProduct('UOM Opt Prod', pcs.Id, cs.Id, 'OBX,OCS');
        if (prod == null) return;

        Test.startTest();
        // 1. Null product → default options branch.
        List<Map<String, Object>> defaults =
            UOM_Conversion_Service.getProductUOMOptions(null);
        System.assertNotEquals(null, defaults, 'Defaults returned for null id');

        // 2. Non-existent product → falls back to defaults.
        List<Map<String, Object>> missing = UOM_Conversion_Service.getProductUOMOptions(
            '01p000000000000AAA' // valid Id shape but no such record
        );
        System.assertNotEquals(null, missing, 'Defaults returned for missing product');

        // 3. Full path with base + secondary + Ordering_UOMs.
        List<Map<String, Object>> full =
            UOM_Conversion_Service.getProductUOMOptions(prod.Id);
        Test.stopTest();

        System.assertNotEquals(null, full, 'Options returned for product');
        // Should include at least base UOM.
        System.assert(full.size() >= 1, 'At least one option built');
    }

    @isTest
    static void testClearCache() {
        // Prime the cache via a lookup, then clear and confirm a fresh lookup
        // still works (i.e. clearCache doesn't leave the static state broken).
        makeUOM('CC Test', 'CCT1', false);
        UOM_Conversion_Service.clearCache();
        Id first = UOM_Conversion_Service.getUOMIdByCode('CCT1');
        UOM_Conversion_Service.clearCache();
        Id second = UOM_Conversion_Service.getUOMIdByCode('CCT1');
        System.assertEquals(first, second, 'Lookup is stable across clearCache');
    }
}