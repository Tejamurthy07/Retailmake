/**
 * @description Central service for UOM conversions used across order entry,
 *              scheme evaluation, invoicing, and stock management.
 *              Caches UOM lookups and conversion rules to avoid SOQL in loops.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class UOM_Conversion_Service {

    // ── Inner classes ────────────────────────────────────────────────────────

    public class ConversionRequest {
        public Id productId;
        public String fromUomCode;
        public String toUomCode;
        public Decimal quantity;
    }

    public class ConvertedResult {
        @AuraEnabled public Decimal convertedQuantity { get; set; }
        @AuraEnabled public Decimal conversionFactor { get; set; }
        @AuraEnabled public String baseUomCode { get; set; }
        @AuraEnabled public Id baseUomId { get; set; }

        public ConvertedResult() {
            this.convertedQuantity = 0;
            this.conversionFactor = 1;
        }
    }

    // ── Cached lookups (per-transaction) ─────────────────────────────────────

    private static Map<String, Id> uomCodeToIdCache;
    private static Map<Id, String> uomIdToCodeCache;
    private static Map<String, Decimal> conversionCache;

    private static void ensureUOMCache() {
        if (uomCodeToIdCache != null) return;
        uomCodeToIdCache = new Map<String, Id>();
        uomIdToCodeCache = new Map<Id, String>();
        for (UOM__c u : [SELECT Id, UOM_Code__c FROM UOM__c WHERE Is_Active__c = true]) {
            uomCodeToIdCache.put(u.UOM_Code__c, u.Id);
            uomIdToCodeCache.put(u.Id, u.UOM_Code__c);
        }
    }

    private static void ensureConversionCache() {
        ensureConversionCache(null);
    }

    private static void ensureConversionCache(Set<Id> productIds) {
        if (conversionCache != null) return;
        conversionCache = new Map<String, Decimal>();

        String query = 'SELECT From_UOM__c, To_UOM__c, Product__c, Conversion_Factor__c ' +
                        'FROM UOM_Conversion__c WHERE Is_Active__c = true';
        if (productIds != null && !productIds.isEmpty()) {
            query += ' AND (Product__c IN :productIds OR Product__c = null)';
        }
        query += ' ORDER BY Product__c NULLS LAST';

        for (UOM_Conversion__c c : Database.query(query)) {
            if (c.Product__c != null) {
                // Product-specific key
                String prodKey = c.From_UOM__c + '|' + c.To_UOM__c + '|' + c.Product__c;
                if (!conversionCache.containsKey(prodKey)) {
                    conversionCache.put(prodKey, c.Conversion_Factor__c);
                }
            } else {
                // Global key (only from records with no product)
                String globalKey = c.From_UOM__c + '|' + c.To_UOM__c + '|';
                if (!conversionCache.containsKey(globalKey)) {
                    conversionCache.put(globalKey, c.Conversion_Factor__c);
                }
            }
        }
    }

    /**
     * @description Clears the per-transaction cache. Useful in tests.
     */
    public static void clearCache() {
        uomCodeToIdCache = null;
        uomIdToCodeCache = null;
        conversionCache = null;
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Convert quantity from one UOM to another for a given product.
     * @param productId The product Id for product-specific conversions.
     * @param fromUomCode Source UOM code (e.g., 'CS').
     * @param toUomCode Target UOM code (e.g., 'PC').
     * @param quantity The quantity to convert.
     * @return The converted quantity.
     */
    public static Decimal convert(Id productId, String fromUomCode, String toUomCode, Decimal quantity) {
        if (quantity == null || quantity == 0) return 0;
        if (fromUomCode == toUomCode) return quantity;
        if (String.isBlank(fromUomCode) || String.isBlank(toUomCode)) return quantity;

        Decimal factor = getConversionFactor(productId, fromUomCode, toUomCode);
        return quantity * factor;
    }

    /**
     * @description Get conversion factor (product-specific > global > reverse).
     * @param productId Optional product Id.
     * @param fromUomCode Source UOM code.
     * @param toUomCode Target UOM code.
     * @return The conversion factor. Returns 1 if same UOM or no conversion found.
     */
    public static Decimal getConversionFactor(Id productId, String fromUomCode, String toUomCode) {
        if (fromUomCode == toUomCode) return 1;
        if (String.isBlank(fromUomCode) || String.isBlank(toUomCode)) return 1;

        ensureUOMCache();
        ensureConversionCache();

        Id fromId = uomCodeToIdCache.get(fromUomCode);
        Id toId = uomCodeToIdCache.get(toUomCode);

        if (fromId == null || toId == null) return 1;

        // 1. Product-specific direct
        if (productId != null) {
            String prodKey = fromId + '|' + toId + '|' + productId;
            if (conversionCache.containsKey(prodKey)) {
                return conversionCache.get(prodKey);
            }
        }

        // 2. Global direct
        String globalKey = fromId + '|' + toId + '|';
        if (conversionCache.containsKey(globalKey)) {
            return conversionCache.get(globalKey);
        }

        // 3. Product-specific reverse
        if (productId != null) {
            String revProdKey = toId + '|' + fromId + '|' + productId;
            if (conversionCache.containsKey(revProdKey)) {
                Decimal revFactor = conversionCache.get(revProdKey);
                return revFactor != 0 ? (1 / revFactor) : 1;
            }
        }

        // 4. Global reverse
        String revGlobalKey = toId + '|' + fromId + '|';
        if (conversionCache.containsKey(revGlobalKey)) {
            Decimal revFactor = conversionCache.get(revGlobalKey);
            return revFactor != 0 ? (1 / revFactor) : 1;
        }

        // No conversion found — return 1 (no conversion)
        return 1;
    }

    /**
     * @description Get allowed UOM options for a product (for combobox population).
     *              Returns the product's base UOM + any UOMs defined in Ordering_UOMs__c.
     * @param productId The Product_Extension__c Id.
     * @return List of maps with 'label', 'value' (UOM code), 'uomId', and 'isBase' keys.
     */
    public static List<Map<String, Object>> getProductUOMOptions(Id productId) {
        List<Map<String, Object>> options = new List<Map<String, Object>>();

        if (productId == null) {
            return getDefaultUOMOptions();
        }

        List<Product_Extension__c> products = [
            SELECT Base_UOM__c, Base_UOM__r.UOM_Code__c, Base_UOM__r.Name,
                   Secondary_UOM__c, Secondary_UOM__r.UOM_Code__c, Secondary_UOM__r.Name,
                   Ordering_UOMs__c, Unit_of_Measure__c
            FROM Product_Extension__c
            WHERE Id = :productId
            LIMIT 1
        ];

        if (products.isEmpty()) {
            return getDefaultUOMOptions();
        }

        Product_Extension__c prod = products[0];
        Set<String> addedCodes = new Set<String>();

        // Add base UOM first
        if (prod.Base_UOM__c != null && String.isNotBlank(prod.Base_UOM__r.UOM_Code__c)) {
            String code = prod.Base_UOM__r.UOM_Code__c;
            Map<String, Object> opt = new Map<String, Object>();
            opt.put('label', prod.Base_UOM__r.Name + ' (' + code + ')');
            opt.put('value', code);
            opt.put('uomId', prod.Base_UOM__c);
            opt.put('isBase', true);
            options.add(opt);
            addedCodes.add(code);
        }

        // Add secondary UOM
        if (prod.Secondary_UOM__c != null && String.isNotBlank(prod.Secondary_UOM__r.UOM_Code__c)) {
            String code = prod.Secondary_UOM__r.UOM_Code__c;
            if (!addedCodes.contains(code)) {
                Map<String, Object> opt = new Map<String, Object>();
                opt.put('label', prod.Secondary_UOM__r.Name + ' (' + code + ')');
                opt.put('value', code);
                opt.put('uomId', prod.Secondary_UOM__c);
                opt.put('isBase', false);
                options.add(opt);
                addedCodes.add(code);
            }
        }

        // Add from Ordering_UOMs__c field
        if (String.isNotBlank(prod.Ordering_UOMs__c)) {
            ensureUOMCache();
            Map<String, UOM__c> uomMap = new Map<String, UOM__c>();
            for (UOM__c u : [SELECT Id, UOM_Code__c, Name FROM UOM__c WHERE Is_Active__c = true]) {
                uomMap.put(u.UOM_Code__c, u);
            }

            // Ordering_UOMs__c is free text; data uses ',' or ';' (e.g. "PCS;BOX").
            for (String code : prod.Ordering_UOMs__c.split('[,;]')) {
                code = code.trim();
                if (String.isBlank(code) || addedCodes.contains(code)) continue;

                UOM__c uom = uomMap.get(code);
                if (uom != null) {
                    Map<String, Object> opt = new Map<String, Object>();
                    opt.put('label', uom.Name + ' (' + code + ')');
                    opt.put('value', code);
                    opt.put('uomId', uom.Id);
                    opt.put('isBase', false);
                    options.add(opt);
                    addedCodes.add(code);
                }
            }
        }

        // Fallback: if no UOM data at all, return defaults
        if (options.isEmpty()) {
            return getDefaultUOMOptions();
        }

        return options;
    }

    /**
     * @description Bulk convert quantities for multiple line items.
     * @param requests List of ConversionRequest objects.
     * @return Map of request index to ConvertedResult.
     */
    public static List<ConvertedResult> bulkConvert(List<ConversionRequest> requests) {
        List<ConvertedResult> results = new List<ConvertedResult>();
        if (requests == null || requests.isEmpty()) return results;

        // Pre-load caches with all relevant product Ids
        Set<Id> productIds = new Set<Id>();
        for (ConversionRequest req : requests) {
            if (req.productId != null) productIds.add(req.productId);
        }
        ensureUOMCache();
        ensureConversionCache(productIds);

        for (ConversionRequest req : requests) {
            ConvertedResult cr = new ConvertedResult();
            if (req.fromUomCode == req.toUomCode || String.isBlank(req.fromUomCode) || String.isBlank(req.toUomCode)) {
                cr.convertedQuantity = req.quantity != null ? req.quantity : 0;
                cr.conversionFactor = 1;
                cr.baseUomCode = req.toUomCode;
            } else {
                Decimal factor = getConversionFactor(req.productId, req.fromUomCode, req.toUomCode);
                cr.conversionFactor = factor;
                cr.convertedQuantity = req.quantity != null ? req.quantity * factor : 0;
                cr.baseUomCode = req.toUomCode;
            }
            // Resolve base UOM Id
            if (String.isNotBlank(cr.baseUomCode)) {
                cr.baseUomId = uomCodeToIdCache != null ? uomCodeToIdCache.get(cr.baseUomCode) : null;
            }
            results.add(cr);
        }

        return results;
    }

    /**
     * @description Get UOM Id from code.
     */
    public static Id getUOMIdByCode(String uomCode) {
        if (String.isBlank(uomCode)) return null;
        ensureUOMCache();
        return uomCodeToIdCache.get(uomCode);
    }

    /**
     * @description Get UOM code from Id.
     */
    public static String getUOMCodeById(Id uomId) {
        if (uomId == null) return null;
        ensureUOMCache();
        return uomIdToCodeCache.get(uomId);
    }

    /**
     * @description Maps Order_Line_Item__c.UOM__c picklist values to UOM codes.
     */
    public static String mapPicklistToCode(String picklistValue) {
        if (String.isBlank(picklistValue)) return 'PCS';
        Map<String, String> mapping = new Map<String, String>{
            'Pieces' => 'PCS',
            'Cases' => 'CS',
            'Boxes' => 'BOX',
            'Kg' => 'KG',
            'Liters' => 'LTR',
            'Piece' => 'PCS',
            'Box' => 'BOX',
            'Case' => 'CS',
            'Litre' => 'LTR',
            'Dozen' => 'DZ',
            'Pack' => 'PK',
            'Gram' => 'GRM',
            'Millilitre' => 'ML',
            'Kilogram' => 'KG'
        };
        return mapping.containsKey(picklistValue) ? mapping.get(picklistValue) : 'PCS';
    }

    /**
     * @description Maps UOM codes to Order_Line_Item__c.UOM__c picklist values.
     */
    public static String mapCodeToPicklist(String uomCode) {
        if (String.isBlank(uomCode)) return 'Pieces';
        Map<String, String> mapping = new Map<String, String>{
            'PCS' => 'Pieces',
            'PC' => 'Pieces',
            'CS' => 'Cases',
            'BOX' => 'Boxes',
            'BX' => 'Boxes',
            'KG' => 'Kg',
            'LTR' => 'Liters',
            'DZ' => 'Pieces',
            'PK' => 'Pieces',
            'GRM' => 'Kg',
            'G' => 'Kg',
            'ML' => 'Liters'
        };
        return mapping.containsKey(uomCode) ? mapping.get(uomCode) : 'Pieces';
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private static List<Map<String, Object>> getDefaultUOMOptions() {
        List<Map<String, Object>> options = new List<Map<String, Object>>();
        ensureUOMCache();
        for (UOM__c u : [SELECT Id, UOM_Code__c, Name, Is_Base_Unit__c FROM UOM__c WHERE Is_Active__c = true ORDER BY Name]) {
            Map<String, Object> opt = new Map<String, Object>();
            opt.put('label', u.Name + ' (' + u.UOM_Code__c + ')');
            opt.put('value', u.UOM_Code__c);
            opt.put('uomId', u.Id);
            opt.put('isBase', u.Is_Base_Unit__c);
            options.add(opt);
        }
        if (options.isEmpty()) {
            Map<String, Object> fallback = new Map<String, Object>();
            fallback.put('label', 'Piece (PCS)');
            fallback.put('value', 'PCS');
            fallback.put('uomId', null);
            fallback.put('isBase', true);
            options.add(fallback);
        }
        return options;
    }
}