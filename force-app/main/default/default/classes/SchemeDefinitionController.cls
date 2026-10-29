/**
 * @description Controller for the Scheme Definition LWC component.
 *              Supports create/edit of Scheme__c with child records:
 *              Scheme_Product__c, Scheme_Slab__c, Scheme_Mapping__c.
 */
public with sharing class SchemeDefinitionController {

    // ── Get Scheme for Edit ───────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Scheme__c getScheme(Id schemeId) {
        List<Scheme__c> schemes = [
            SELECT Id, Name, Scheme_Code__c, Scheme_Category__c, Scheme_Type__c,
                   Description__c, Start_Date__c, End_Date__c, Status__c,
                   Applicable_Channel__c, Applicable_Outlet_Type__c, Applicable_Region__c,
                   Discount_Percent__c, Discount_Amount__c, Price_Discount__c,
                   Reward_Points__c, MOV__c,
                   Free_Product_Ext__c, Free_Quantity__c,
                   Min_Quantity__c, Max_Quantity__c, Min_Value__c, Max_Value__c,
                   Invoice_Qty_Threshold__c, Invoice_Qty_UOM__c, Invoice_Val_Threshold__c,
                   Max_Discount_Cap__c, Priority__c, Is_Stackable__c, Tier__c,
                   Budget_Amount__c, Product_Ext__c, Product_Category__c,
                   (SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                           Is_Buy_Product__c, Is_Get_Product__c, Min_Quantity__c, Product_Category__c
                    FROM Scheme_Products__r ORDER BY Product_Ext__r.Name),
                   (SELECT Id, Slab_Type__c, Min_Value__c, Max_Value__c,
                           Min_Quantity__c, Max_Quantity__c,
                           Discount_Type__c, Discount_Value__c, Discount_Percent__c,
                           Discount_Amount__c, Price_Discount__c, Reward_Points__c,
                           Free_Product_Ext__c, Free_Quantity__c, Is_Active__c
                    FROM Scheme_Slabs__r ORDER BY Min_Value__c),
                   (SELECT Id, Zone__c, Sub_Zone__c, District__c, Area__c,
                           Account__c, Account__r.Name, Customer_Type__c, Is_Active__c
                    FROM Scheme_Mappings__r ORDER BY Zone__c)
            FROM Scheme__c
            WHERE Id = :schemeId
            LIMIT 1
        ];
        if (schemes.isEmpty()) {
            throw new AuraHandledException('Scheme not found.');
        }
        return schemes[0];
    }

    // ── Save Scheme (Create or Update) ────────────────────────────────────

    @AuraEnabled
    public static Id saveScheme(
        String schemeJson,
        String productsJson,
        String slabsJson,
        String mappingsJson,
        List<Id> deletedProductIds,
        List<Id> deletedSlabIds,
        List<Id> deletedMappingIds
    ) {
        // Received as JSON (not typed SObjects) so the LWC's unqualified field keys
        // survive the hop — in the managed-package namespace an SObject param drops
        // any value whose key lacks the ftretailmake__ prefix. Build server-side.
        if (String.isBlank(schemeJson)) {
            throw new AuraHandledException('Scheme is required.');
        }
        Scheme__c scheme = (Scheme__c) buildSObject(
            Scheme__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(schemeJson));
        List<Scheme_Product__c> products = new List<Scheme_Product__c>();
        if (String.isNotBlank(productsJson)) {
            for (Object o : (List<Object>) JSON.deserializeUntyped(productsJson)) {
                products.add((Scheme_Product__c) buildSObject(Scheme_Product__c.SObjectType, (Map<String, Object>) o));
            }
        }
        List<Scheme_Slab__c> slabs = new List<Scheme_Slab__c>();
        if (String.isNotBlank(slabsJson)) {
            for (Object o : (List<Object>) JSON.deserializeUntyped(slabsJson)) {
                slabs.add((Scheme_Slab__c) buildSObject(Scheme_Slab__c.SObjectType, (Map<String, Object>) o));
            }
        }
        List<Scheme_Mapping__c> mappings = new List<Scheme_Mapping__c>();
        if (String.isNotBlank(mappingsJson)) {
            for (Object o : (List<Object>) JSON.deserializeUntyped(mappingsJson)) {
                mappings.add((Scheme_Mapping__c) buildSObject(Scheme_Mapping__c.SObjectType, (Map<String, Object>) o));
            }
        }
        return saveSchemeInternal(scheme, products, slabs, mappings,
            deletedProductIds, deletedSlabIds, deletedMappingIds);
    }

    public static Id saveSchemeInternal(
        Scheme__c scheme,
        List<Scheme_Product__c> products,
        List<Scheme_Slab__c> slabs,
        List<Scheme_Mapping__c> mappings,
        List<Id> deletedProductIds,
        List<Id> deletedSlabIds,
        List<Id> deletedMappingIds
    ) {
        Savepoint sp = Database.setSavepoint();
        try {
            // Upsert the scheme
            upsert scheme;
            Id schemeId = scheme.Id;

            // Delete removed child records
            if (deletedProductIds != null && !deletedProductIds.isEmpty()) {
                delete [SELECT Id FROM Scheme_Product__c WHERE Id IN :deletedProductIds];
            }
            if (deletedSlabIds != null && !deletedSlabIds.isEmpty()) {
                delete [SELECT Id FROM Scheme_Slab__c WHERE Id IN :deletedSlabIds];
            }
            if (deletedMappingIds != null && !deletedMappingIds.isEmpty()) {
                delete [SELECT Id FROM Scheme_Mapping__c WHERE Id IN :deletedMappingIds];
            }

            // Upsert products
            if (products != null && !products.isEmpty()) {
                for (Scheme_Product__c p : products) {
                    p.Scheme__c = schemeId;
                }
                upsert products;
            }

            // Upsert slabs
            if (slabs != null && !slabs.isEmpty()) {
                for (Scheme_Slab__c s : slabs) {
                    s.Scheme__c = schemeId;
                }
                upsert slabs;
            }

            // Upsert mappings
            if (mappings != null && !mappings.isEmpty()) {
                for (Scheme_Mapping__c m : mappings) {
                    m.Scheme__c = schemeId;
                }
                upsert mappings;
            }

            return schemeId;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Search Products ───────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Product_Extension__c> searchProducts(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [
            SELECT Id, Name, SKU_Code__c, Brand__c, MRP__c
            FROM Product_Extension__c
            WHERE Is_Active__c = true
            AND (Name LIKE :term OR SKU_Code__c LIKE :term)
            ORDER BY Name
            LIMIT 20
        ];
    }

    // ── Generate Scheme Code ──────────────────────────────────────────────

    @AuraEnabled
    public static String generateSchemeCode() {
        Integer yr = Date.today().year();
        String prefix = 'SCH-' + yr + '-';
        List<Scheme__c> last = [
            SELECT Scheme_Code__c FROM Scheme__c
            WHERE Scheme_Code__c LIKE :prefix + '%'
            ORDER BY Scheme_Code__c DESC LIMIT 1
        ];
        Integer nextNum = 1;
        if (!last.isEmpty()) {
            String lastCode = last[0].Scheme_Code__c;
            String numPart = lastCode.substringAfterLast('-');
            try {
                nextNum = Integer.valueOf(numPart) + 1;
            } catch (Exception e) {
                nextNum = 1;
            }
        }
        return prefix + String.valueOf(nextNum).leftPad(3, '0');
    }

    // ── Namespace-tolerant SObject building (see saveScheme) ─────────────
    // Builds a typed SObject from a plain Map whose keys may be unqualified
    // (Field__c) or namespaced (ftretailmake__Field__c); resolves either form.
    private static SObject buildSObject(Schema.SObjectType t, Map<String, Object> m) {
        SObject rec = t.newSObject();
        if (m == null) return rec;
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();
        for (String key : m.keySet()) {
            if (key == 'sobjectType' || key == 'attributes' || m.get(key) == null) continue;
            Schema.SObjectField sf = resolveField(fmap, key);
            if (sf == null) continue; // unknown field or relationship (__r) — skip
            Schema.DescribeFieldResult dfr = sf.getDescribe();
            try { rec.put(dfr.getName(), coerceValue(dfr.getType(), m.get(key))); }
            catch (Exception e) { /* skip un-coercible value rather than fail the save */ }
        }
        return rec;
    }

    private static Schema.SObjectField resolveField(Map<String, Schema.SObjectField> fmap, String name) {
        if (String.isBlank(name) || fmap == null) return null;
        Schema.SObjectField f = fmap.get(name);
        if (f != null) return f;
        String bare = unqualify(name);
        for (String key : fmap.keySet()) {
            if (unqualify(key).equalsIgnoreCase(bare)) return fmap.get(key);
        }
        return null;
    }

    private static String unqualify(String api) {
        if (String.isBlank(api)) return api;
        if (api.endsWithIgnoreCase('__c') && api.split('__').size() >= 3) {
            return api.substringAfter('__');
        }
        return api;
    }

    private static Object coerceValue(Schema.DisplayType t, Object val) {
        if (val == null) return null;
        String s = String.valueOf(val);
        if (String.isBlank(s)) return null;
        if (t == Schema.DisplayType.Boolean) return (val instanceof Boolean) ? val : Boolean.valueOf(s);
        if (t == Schema.DisplayType.Date) return Date.valueOf(s.substring(0, 10));
        if (t == Schema.DisplayType.DateTime) return Datetime.valueOf(s.replace('T', ' ').replace('Z', ''));
        if (t == Schema.DisplayType.Double || t == Schema.DisplayType.Currency
            || t == Schema.DisplayType.Percent) return Decimal.valueOf(s);
        if (t == Schema.DisplayType.Integer) return Integer.valueOf(s);
        if (t == Schema.DisplayType.Reference || t == Schema.DisplayType.Id) return (Id) s;
        return s;
    }
}