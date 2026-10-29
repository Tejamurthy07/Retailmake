/**
 * @description Unified controller for the Scheme Manager LWC component.
 *              Provides full scheme lifecycle management: list, create, edit,
 *              clone, delete, status changes, dashboard statistics,
 *              product search, and scheme code generation.
 */
public with sharing class SchemeManagerController {

    // ── Dashboard Statistics ─────────────────────────────────────────────

    @AuraEnabled
    public static Map<String, Object> getSchemeStats() {
        Date today = Date.today();
        Map<String, Object> stats = new Map<String, Object>();

        stats.put('totalSchemes', [SELECT COUNT() FROM Scheme__c]);
        stats.put('activeSchemes', [SELECT COUNT() FROM Scheme__c WHERE Status__c = 'Active' AND Is_Active__c = true AND Start_Date__c <= :today AND (End_Date__c >= :today OR End_Date__c = null)]);
        stats.put('draftSchemes', [SELECT COUNT() FROM Scheme__c WHERE Status__c = 'Draft']);
        stats.put('pendingApproval', [SELECT COUNT() FROM Scheme__c WHERE Status__c = 'Pending Approval']);
        stats.put('expiredSchemes', [SELECT COUNT() FROM Scheme__c WHERE Status__c = 'Expired']);
        stats.put('cancelledSchemes', [SELECT COUNT() FROM Scheme__c WHERE Status__c = 'Cancelled']);

        AggregateResult[] budgetAgg = [
            SELECT SUM(Budget_Amount__c) totalBudget, SUM(Budget_Used__c) totalUsed
            FROM Scheme__c
            WHERE Status__c = 'Active' AND Is_Active__c = true
        ];
        if (!budgetAgg.isEmpty()) {
            stats.put('totalBudget', budgetAgg[0].get('totalBudget'));
            stats.put('totalBudgetUsed', budgetAgg[0].get('totalUsed'));
        }

        List<AggregateResult> catBreakdown = [
            SELECT Scheme_Category__c cat, COUNT(Id) cnt
            FROM Scheme__c
            WHERE Status__c = 'Active' AND Is_Active__c = true
            GROUP BY Scheme_Category__c
        ];
        List<Map<String, Object>> categories = new List<Map<String, Object>>();
        for (AggregateResult ar : catBreakdown) {
            categories.add(new Map<String, Object>{
                'category' => ar.get('cat'),
                'count' => ar.get('cnt')
            });
        }
        stats.put('categoryBreakdown', categories);

        return stats;
    }

    // ── List Schemes (with filters & pagination) ─────────────────────────

    @AuraEnabled
    public static Map<String, Object> getSchemes(
        String status, String category, String schemeType,
        String channel, String searchTerm,
        Integer pageSize, Integer pageNumber,
        String sortField, String sortDirection
    ) {
        Map<String, Object> result = new Map<String, Object>();

        String countQuery = 'SELECT COUNT() FROM Scheme__c';
        String query = 'SELECT Id, Name, Scheme_Code__c, Scheme_Category__c, Scheme_Type__c, ' +
                       'Description__c, Start_Date__c, End_Date__c, Status__c, ' +
                       'Applicable_Channel__c, Priority__c, Is_Stackable__c, ' +
                       'Discount_Percent__c, Discount_Amount__c, Price_Discount__c, ' +
                       'Reward_Points__c, MOV__c, Free_Quantity__c, ' +
                       'Free_Product_Ext__c, Free_Product_Ext__r.Name, ' +
                       'Budget_Amount__c, Budget_Used__c, Budget_Remaining__c, ' +
                       'Min_Quantity__c, Max_Quantity__c, ' +
                       'Invoice_Qty_Threshold__c, Invoice_Val_Threshold__c, ' +
                       'Max_Usage_Per_Customer__c, ' +
                       'CreatedDate, LastModifiedDate, ' +
                       '(SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, ' +
                       '        Is_Buy_Product__c, Is_Get_Product__c, Min_Quantity__c, Product_Classification__c ' +
                       ' FROM Scheme_Products__r ORDER BY Product_Ext__r.Name LIMIT 10), ' +
                       '(SELECT Id FROM Scheme_Slabs__r LIMIT 1), ' +
                       '(SELECT Id FROM Scheme_Mappings__r LIMIT 1) ' +
                       'FROM Scheme__c';

        List<String> conditions = new List<String>();

        if (String.isNotBlank(status)) {
            conditions.add('Status__c = :status');
        }
        if (String.isNotBlank(category)) {
            conditions.add('Scheme_Category__c = :category');
        }
        if (String.isNotBlank(schemeType)) {
            conditions.add('Scheme_Type__c = :schemeType');
        }
        if (String.isNotBlank(channel)) {
            String safeChannel = String.escapeSingleQuotes(channel);
            conditions.add('(Applicable_Channel__c INCLUDES (\'' + safeChannel + '\') OR Applicable_Channel__c = null)');
        }
        if (String.isNotBlank(searchTerm)) {
            String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            conditions.add('(Name LIKE :term OR Scheme_Code__c LIKE :term OR Description__c LIKE :term)');
        }

        String whereClause = '';
        if (!conditions.isEmpty()) {
            whereClause = ' WHERE ' + String.join(conditions, ' AND ');
        }

        countQuery += whereClause;
        query += whereClause;

        String validSort = 'CreatedDate';
        Set<String> allowedSorts = new Set<String>{
            'Name', 'Scheme_Code__c', 'Status__c', 'Scheme_Category__c',
            'Start_Date__c', 'End_Date__c', 'Priority__c', 'CreatedDate', 'LastModifiedDate'
        };
        if (String.isNotBlank(sortField) && allowedSorts.contains(sortField)) {
            validSort = sortField;
        }
        String dir = (sortDirection == 'ASC') ? 'ASC' : 'DESC';
        query += ' ORDER BY ' + validSort + ' ' + dir + ' NULLS LAST';

        if (pageSize == null || pageSize < 1) pageSize = 25;
        if (pageSize > 100) pageSize = 100;
        if (pageNumber == null || pageNumber < 1) pageNumber = 1;
        Integer offset = (pageNumber - 1) * pageSize;

        query += ' LIMIT :pageSize OFFSET :offset';

        Integer totalCount = Database.countQuery(countQuery);
        List<Scheme__c> schemes = Database.query(query);

        result.put('schemes', schemes);
        result.put('totalCount', totalCount);
        result.put('pageSize', pageSize);
        result.put('pageNumber', pageNumber);
        result.put('totalPages', Math.ceil((Decimal)totalCount / pageSize).intValue());

        return result;
    }

    // ── Get Scheme for Edit ──────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Scheme__c getScheme(Id schemeId) {
        List<Scheme__c> schemes = [
            SELECT Id, Name, Scheme_Code__c, Scheme_Category__c, Scheme_Type__c,
                   Description__c, Start_Date__c, End_Date__c, Status__c,
                   Applicable_Channel__c, Applicable_Outlet_Type__c, Applicable_Region__c,
                   Discount_Percent__c, Discount_Amount__c, Price_Discount__c,
                   Reward_Points__c, MOV__c,
                   Free_Product_Ext__c, Free_Product_Ext__r.Name, Free_Quantity__c,
                   Min_Quantity__c, Max_Quantity__c, Min_Value__c, Max_Value__c,
                   Invoice_Qty_Threshold__c, Invoice_Qty_UOM__c, Invoice_Val_Threshold__c,
                   Base_UOM__c, Base_UOM__r.Name, Base_UOM__r.UOM_Code__c,
                   Max_Discount_Cap__c, Priority__c, Is_Stackable__c, Tier__c,
                   Budget_Amount__c, Max_Usage_Per_Customer__c,
                   Product_Ext__c, Product_Category__c,
                   (SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                           Is_Buy_Product__c, Is_Get_Product__c, Min_Quantity__c, Product_Category__c,
                           Product_Classification__c
                    FROM Scheme_Products__r ORDER BY Product_Ext__r.Name),
                   (SELECT Id, Slab_Type__c, Min_Value__c, Max_Value__c,
                           Min_Quantity__c, Max_Quantity__c,
                           Discount_Type__c, Discount_Value__c, Discount_Percent__c,
                           Discount_Amount__c, Price_Discount__c, Reward_Points__c,
                           Free_Product_Ext__c, Free_Quantity__c, Is_Active__c
                    FROM Scheme_Slabs__r ORDER BY Min_Value__c),
                   (SELECT Id, Territory__c, Territory__r.Name, Territory__r.Territory_Code__c,
                           Territory__r.Region__r.Name, Territory__r.State__c, Territory__r.City__c,
                           Zone__c, Sub_Zone__c, District__c, Area__c,
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

    // ── Save Scheme (Create or Update) ───────────────────────────────────

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
            upsert scheme;
            Id schemeId = scheme.Id;

            if (deletedProductIds != null && !deletedProductIds.isEmpty()) {
                delete [SELECT Id FROM Scheme_Product__c WHERE Id IN :deletedProductIds];
            }
            if (deletedSlabIds != null && !deletedSlabIds.isEmpty()) {
                delete [SELECT Id FROM Scheme_Slab__c WHERE Id IN :deletedSlabIds];
            }
            if (deletedMappingIds != null && !deletedMappingIds.isEmpty()) {
                delete [SELECT Id FROM Scheme_Mapping__c WHERE Id IN :deletedMappingIds];
            }

            if (products != null && !products.isEmpty()) {
                List<Scheme_Product__c> newProducts = new List<Scheme_Product__c>();
                List<Scheme_Product__c> existingProducts = new List<Scheme_Product__c>();
                for (Scheme_Product__c p : products) {
                    if (p.Id == null) {
                        p.Scheme__c = schemeId;
                        newProducts.add(p);
                    } else {
                        existingProducts.add(p);
                    }
                }
                if (!newProducts.isEmpty()) insert newProducts;
                if (!existingProducts.isEmpty()) update existingProducts;
            }

            if (slabs != null && !slabs.isEmpty()) {
                List<Scheme_Slab__c> newSlabs = new List<Scheme_Slab__c>();
                List<Scheme_Slab__c> existingSlabs = new List<Scheme_Slab__c>();
                for (Scheme_Slab__c s : slabs) {
                    if (s.Id == null) {
                        s.Scheme__c = schemeId;
                        newSlabs.add(s);
                    } else {
                        existingSlabs.add(s);
                    }
                }
                if (!newSlabs.isEmpty()) insert newSlabs;
                if (!existingSlabs.isEmpty()) update existingSlabs;
            }

            if (mappings != null && !mappings.isEmpty()) {
                List<Scheme_Mapping__c> newMappings = new List<Scheme_Mapping__c>();
                List<Scheme_Mapping__c> existingMappings = new List<Scheme_Mapping__c>();
                for (Scheme_Mapping__c m : mappings) {
                    if (m.Id == null) {
                        m.Scheme__c = schemeId;
                        newMappings.add(m);
                    } else {
                        existingMappings.add(m);
                    }
                }
                if (!newMappings.isEmpty()) insert newMappings;
                if (!existingMappings.isEmpty()) update existingMappings;
            }

            return schemeId;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Namespace-tolerant SObject building (see saveScheme) ─────────────
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

    // ── Search Products ──────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Product_Extension__c> searchProducts(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [
            SELECT Id, Name, SKU_Code__c, Brand__c, MRP__c, Product_Image_URL__c
            FROM Product_Extension__c
            WHERE Is_Active__c = true
            AND (Name LIKE :term OR SKU_Code__c LIKE :term)
            ORDER BY Name
            LIMIT 20
        ];
    }

    // ── Search Territories ──────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Territory_Master__c> searchTerritories(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        return [
            SELECT Id, Name, Territory_Code__c, Region__c, Region__r.Name,
                   State__c, City__c
            FROM Territory_Master__c
            WHERE Is_Active__c = true
            AND (Name LIKE :term OR Territory_Code__c LIKE :term OR City__c LIKE :term)
            ORDER BY Name
            LIMIT 20
        ];
    }

    // ── Generate Scheme Code ─────────────────────────────────────────────

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

    // ── Clone Scheme ─────────────────────────────────────────────────────

    @AuraEnabled
    public static Id cloneScheme(Id schemeId) {
        Savepoint sp = Database.setSavepoint();
        try {
            Scheme__c original = [
                SELECT Id, Name, Scheme_Code__c, Scheme_Category__c, Scheme_Type__c,
                       Description__c, Start_Date__c, End_Date__c,
                       Applicable_Channel__c, Applicable_Outlet_Type__c, Applicable_Region__c,
                       Discount_Percent__c, Discount_Amount__c, Price_Discount__c,
                       Reward_Points__c, MOV__c,
                       Free_Product_Ext__c, Free_Quantity__c,
                       Min_Quantity__c, Max_Quantity__c, Min_Value__c, Max_Value__c,
                       Invoice_Qty_Threshold__c, Invoice_Qty_UOM__c, Invoice_Val_Threshold__c,
                       Max_Discount_Cap__c, Priority__c, Is_Stackable__c, Tier__c,
                       Budget_Amount__c, Max_Usage_Per_Customer__c,
                       Product_Ext__c, Product_Category__c,
                       (SELECT Product_Ext__c, Is_Buy_Product__c, Is_Get_Product__c,
                               Min_Quantity__c, Product_Category__c, Product_Classification__c
                        FROM Scheme_Products__r),
                       (SELECT Slab_Type__c, Min_Value__c, Max_Value__c,
                               Min_Quantity__c, Max_Quantity__c,
                               Discount_Type__c, Discount_Value__c, Discount_Percent__c,
                               Discount_Amount__c, Price_Discount__c, Reward_Points__c,
                               Free_Product_Ext__c, Free_Quantity__c, Is_Active__c
                        FROM Scheme_Slabs__r),
                       (SELECT Territory__c, Zone__c, Sub_Zone__c, District__c, Area__c,
                               Customer_Type__c, Is_Active__c
                        FROM Scheme_Mappings__r)
                FROM Scheme__c WHERE Id = :schemeId LIMIT 1
            ];

            String newCode = generateSchemeCode();

            Scheme__c cloned = original.clone(false, true, false, false);
            cloned.Name = original.Name + ' (Copy)';
            cloned.Scheme_Code__c = newCode;
            cloned.Status__c = 'Draft';
            insert cloned;

            List<Scheme_Product__c> clonedProducts = new List<Scheme_Product__c>();
            for (Scheme_Product__c p : original.Scheme_Products__r) {
                Scheme_Product__c cp = p.clone(false, true, false, false);
                cp.Scheme__c = cloned.Id;
                clonedProducts.add(cp);
            }
            if (!clonedProducts.isEmpty()) insert clonedProducts;

            List<Scheme_Slab__c> clonedSlabs = new List<Scheme_Slab__c>();
            for (Scheme_Slab__c s : original.Scheme_Slabs__r) {
                Scheme_Slab__c cs = s.clone(false, true, false, false);
                cs.Scheme__c = cloned.Id;
                clonedSlabs.add(cs);
            }
            if (!clonedSlabs.isEmpty()) insert clonedSlabs;

            List<Scheme_Mapping__c> clonedMappings = new List<Scheme_Mapping__c>();
            for (Scheme_Mapping__c m : original.Scheme_Mappings__r) {
                Scheme_Mapping__c cm = m.clone(false, true, false, false);
                cm.Scheme__c = cloned.Id;
                clonedMappings.add(cm);
            }
            if (!clonedMappings.isEmpty()) insert clonedMappings;

            return cloned.Id;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Update Status ────────────────────────────────────────────────────

    @AuraEnabled
    public static void updateSchemeStatus(Id schemeId, String newStatus) {
        try {
            Scheme__c scheme = [SELECT Id, Status__c FROM Scheme__c WHERE Id = :schemeId LIMIT 1];

            Set<String> validStatuses = new Set<String>{'Draft', 'Pending Approval', 'Active', 'Expired', 'Cancelled'};
            if (!validStatuses.contains(newStatus)) {
                throw new AuraHandledException('Invalid status: ' + newStatus);
            }

            scheme.Status__c = newStatus;
            update scheme;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Delete Scheme ────────────────────────────────────────────────────

    @AuraEnabled
    public static void deleteScheme(Id schemeId) {
        try {
            Scheme__c scheme = [SELECT Id, Status__c FROM Scheme__c WHERE Id = :schemeId LIMIT 1];
            if (scheme.Status__c == 'Active') {
                throw new AuraHandledException('Cannot delete an active scheme. Deactivate it first.');
            }
            delete scheme;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}