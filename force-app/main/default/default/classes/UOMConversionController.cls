/**
 * @description Controller for UOM (Unit of Measure) conversion operations.
 *              Provides methods for managing UOMs, conversion rules, and
 *              performing quantity conversions between units.
 */
public with sharing class UOMConversionController {

    /**
     * @description Retrieves all active UOM records.
     * @return List of active UOM__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<UOM__c> getActiveUOMs() {
        return [
            SELECT Id, Name, UOM_Code__c, UOM_Type__c, Is_Base_Unit__c,
                   Is_Active__c, Description__c
            FROM UOM__c
            WHERE Is_Active__c = true
            ORDER BY UOM_Type__c, Name
        ];
    }

    /**
     * @description Retrieves all UOM records (active and inactive) for admin views.
     * @return List of all UOM__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<UOM__c> getAllUOMs() {
        return [
            SELECT Id, Name, UOM_Code__c, UOM_Type__c, Is_Base_Unit__c,
                   Is_Active__c, Description__c
            FROM UOM__c
            ORDER BY UOM_Type__c, Name
        ];
    }

    /**
     * @description Retrieves UOM conversion rules, optionally filtered by product.
     * @param productId Optional product Id to get product-specific conversions.
     * @return List of UOM_Conversion__c records (global + product-specific).
     */
    @AuraEnabled(cacheable=true)
    public static List<UOM_Conversion__c> getConversions(Id productId) {
        if (productId != null) {
            return [
                SELECT Id, Name, From_UOM__c, From_UOM__r.Name, From_UOM__r.UOM_Code__c,
                       To_UOM__c, To_UOM__r.Name, To_UOM__r.UOM_Code__c,
                       Conversion_Factor__c, Inverse_Conversion_Factor__c,
                       Product__c, Product__r.Name, Is_Active__c
                FROM UOM_Conversion__c
                WHERE Is_Active__c = true
                AND (Product__c = :productId OR Product__c = null)
                ORDER BY Product__c NULLS LAST, From_UOM__r.Name, To_UOM__r.Name
            ];
        }
        return [
            SELECT Id, Name, From_UOM__c, From_UOM__r.Name, From_UOM__r.UOM_Code__c,
                   To_UOM__c, To_UOM__r.Name, To_UOM__r.UOM_Code__c,
                   Conversion_Factor__c, Inverse_Conversion_Factor__c,
                   Product__c, Product__r.Name, Is_Active__c
            FROM UOM_Conversion__c
            WHERE Is_Active__c = true
            AND Product__c = null
            ORDER BY From_UOM__r.Name, To_UOM__r.Name
        ];
    }

    /**
     * @description Converts a quantity from one UOM to another.
     *              First checks for a product-specific conversion, then falls back to global.
     * @param quantity The quantity to convert.
     * @param fromUOMId The source UOM Id.
     * @param toUOMId The target UOM Id.
     * @param productId Optional product Id for product-specific conversions.
     * @return The converted quantity.
     */
    @AuraEnabled
    public static Decimal convertQuantity(Decimal quantity, Id fromUOMId, Id toUOMId, Id productId) {
        if (quantity == null || quantity == 0) {
            return 0;
        }
        if (fromUOMId == toUOMId) {
            return quantity;
        }

        // Try product-specific conversion first (direct match)
        UOM_Conversion__c conversion = findConversion(fromUOMId, toUOMId, productId);

        if (conversion != null) {
            return quantity * conversion.Conversion_Factor__c;
        }

        // Try reverse conversion (To -> From with inverse factor)
        UOM_Conversion__c reverseConversion = findConversion(toUOMId, fromUOMId, productId);
        if (reverseConversion != null && reverseConversion.Conversion_Factor__c != 0) {
            return quantity / reverseConversion.Conversion_Factor__c;
        }

        throw new AuraHandledException(
            'No conversion rule found between the selected units of measure.'
        );
    }

    /**
     * @description Finds a conversion record, preferring product-specific over global.
     */
    private static UOM_Conversion__c findConversion(Id fromUOMId, Id toUOMId, Id productId) {
        List<UOM_Conversion__c> conversions;

        if (productId != null) {
            conversions = [
                SELECT Id, Conversion_Factor__c
                FROM UOM_Conversion__c
                WHERE From_UOM__c = :fromUOMId
                AND To_UOM__c = :toUOMId
                AND Is_Active__c = true
                AND (Product__c = :productId OR Product__c = null)
                ORDER BY Product__c NULLS LAST
                LIMIT 1
            ];
        } else {
            conversions = [
                SELECT Id, Conversion_Factor__c
                FROM UOM_Conversion__c
                WHERE From_UOM__c = :fromUOMId
                AND To_UOM__c = :toUOMId
                AND Is_Active__c = true
                AND Product__c = null
                LIMIT 1
            ];
        }

        return conversions.isEmpty() ? null : conversions[0];
    }

    /**
     * @description Saves a UOM record (insert or update).
     * @param uom The UOM__c record to save.
     * @return The saved UOM__c record.
     */
    @AuraEnabled
    public static UOM__c saveUOM(UOM__c uom) {
        try {
            upsert uom;
            return [
                SELECT Id, Name, UOM_Code__c, UOM_Type__c, Is_Base_Unit__c,
                       Is_Active__c, Description__c
                FROM UOM__c
                WHERE Id = :uom.Id
            ];
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    /**
     * @description Saves a UOM Conversion record (insert or update).
     *              Auto-calculates the inverse conversion factor.
     * @param conversion The UOM_Conversion__c record to save.
     * @return The saved UOM_Conversion__c record.
     */
    @AuraEnabled
    public static UOM_Conversion__c saveConversion(String conversionJson) {
        // Received as JSON (not a typed SObject) so the LWC's unqualified field
        // keys survive — in the ftretailmake namespace an SObject param drops any
        // value whose key lacks the prefix. Rebuild server-side with real names.
        if (String.isBlank(conversionJson)) throw new AuraHandledException('Conversion is required.');
        UOM_Conversion__c conversion = (UOM_Conversion__c) buildSObject(
            UOM_Conversion__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(conversionJson));
        return saveConversionInternal(conversion);
    }

    public static UOM_Conversion__c saveConversionInternal(UOM_Conversion__c conversion) {
        try {
            // Validate not converting to the same UOM
            if (conversion.From_UOM__c == conversion.To_UOM__c) {
                throw new AuraHandledException('From UOM and To UOM must be different.');
            }

            // Validate conversion factor is positive
            if (conversion.Conversion_Factor__c == null || conversion.Conversion_Factor__c <= 0) {
                throw new AuraHandledException('Conversion factor must be a positive number.');
            }

            // Auto-calculate inverse factor (rounded to 6 decimals to match field precision)
            conversion.Inverse_Conversion_Factor__c = (1 / conversion.Conversion_Factor__c).setScale(6, RoundingMode.HALF_UP);

            upsert conversion;
            return [
                SELECT Id, Name, From_UOM__c, From_UOM__r.Name, From_UOM__r.UOM_Code__c,
                       To_UOM__c, To_UOM__r.Name, To_UOM__r.UOM_Code__c,
                       Conversion_Factor__c, Inverse_Conversion_Factor__c,
                       Product__c, Product__r.Name, Is_Active__c
                FROM UOM_Conversion__c
                WHERE Id = :conversion.Id
            ];
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    /**
     * @description Deletes a UOM Conversion record.
     * @param conversionId The Id of the UOM_Conversion__c to delete.
     */
    @AuraEnabled
    public static void deleteConversion(Id conversionId) {
        try {
            delete [SELECT Id FROM UOM_Conversion__c WHERE Id = :conversionId];
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    /**
     * @description Gets UOM conversions for a specific product, including globals.
     *              Returns a map structure suitable for LWC consumption.
     * @param productId The Product_Extension__c Id.
     * @return List of conversion maps with from/to UOM details and factors.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getProductConversions(Id productId) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        List<UOM_Conversion__c> conversions = [
            SELECT Id, Name, From_UOM__c, From_UOM__r.Name, From_UOM__r.UOM_Code__c,
                   To_UOM__c, To_UOM__r.Name, To_UOM__r.UOM_Code__c,
                   Conversion_Factor__c, Inverse_Conversion_Factor__c,
                   Product__c, Product__r.Name, Is_Active__c
            FROM UOM_Conversion__c
            WHERE Is_Active__c = true
            AND (Product__c = :productId OR Product__c = null)
            ORDER BY Product__c NULLS LAST, From_UOM__r.Name
        ];

        for (UOM_Conversion__c conv : conversions) {
            Map<String, Object> convMap = new Map<String, Object>();
            convMap.put('id', conv.Id);
            convMap.put('name', conv.Name);
            convMap.put('fromUOMId', conv.From_UOM__c);
            convMap.put('fromUOMName', conv.From_UOM__r.Name);
            convMap.put('fromUOMCode', conv.From_UOM__r.UOM_Code__c);
            convMap.put('toUOMId', conv.To_UOM__c);
            convMap.put('toUOMName', conv.To_UOM__r.Name);
            convMap.put('toUOMCode', conv.To_UOM__r.UOM_Code__c);
            convMap.put('factor', conv.Conversion_Factor__c);
            convMap.put('inverseFactor', conv.Inverse_Conversion_Factor__c);
            convMap.put('isProductSpecific', conv.Product__c != null);
            results.add(convMap);
        }

        return results;
    }

    // ── Namespace-tolerant SObject building (see saveConversion) ─────────
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