/**
 * @description Controller for the Product Catalog LWC component.
 *              Provides product search, category browsing, and pricing data.
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class MDM_ProductCatalogController {

    /**
     * @description Retrieves products with their extensions, filtered by search and category.
     * @param searchTerm Optional search string to filter by product name or code.
     * @param categoryId Optional Product_Category__c Id to filter by category.
     * @param isActiveOnly If true, only return active products.
     * @param limitCount Maximum number of records to return.
     * @param offset Offset for pagination.
     * @return List of ProductWrapper objects.
     */
    @AuraEnabled(cacheable=true)
    public static ProductCatalogResult getProducts(
        String searchTerm,
        Id categoryId,
        Boolean isActiveOnly,
        Integer limitCount,
        Integer offset
    ) {
        limitCount = limitCount != null ? Math.min(limitCount, 100) : 50;
        offset = offset != null ? offset : 0;

        // Build dynamic query
        String query = 'SELECT Id, Name, Is_Active__c, ' +
                       'Product_Category__c, Product_Category__r.Name, ' +
                       'Barcode_EAN__c, Barcode_UPC__c, HSN_SAC_Code__c, Weight__c, ' +
                       'Weight_Unit__c, Case_Size__c, Min_Order_Qty__c, Product_Image_URL__c ' +
                       'FROM Product_Extension__c';

        List<String> conditions = new List<String>();

        if (String.isNotBlank(searchTerm)) {
            String searchWild = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            conditions.add('(Name LIKE :searchWild OR SKU_Code__c LIKE :searchWild)');
        }

        if (isActiveOnly != null && isActiveOnly) {
            conditions.add('Is_Active__c = true');
        }

        if (categoryId != null) {
            // Get all category IDs in the hierarchy below this category
            Set<Id> categoryIds = getCategoryHierarchyIds(categoryId);
            conditions.add('Product_Category__c IN :categoryIds');
        }

        if (!conditions.isEmpty()) {
            query += ' WHERE ' + String.join(conditions, ' AND ');
        }

        // Count query for pagination
        String countQuery = query.replace(
            'SELECT Id, Name, Is_Active__c, ' +
            'Product_Category__c, Product_Category__r.Name, ' +
            'Barcode_EAN__c, Barcode_UPC__c, HSN_SAC_Code__c, Weight__c, ' +
            'Weight_Unit__c, Case_Size__c, Min_Order_Qty__c, Product_Image_URL__c',
            'SELECT COUNT()'
        );

        query += ' ORDER BY Name ASC LIMIT :limitCount OFFSET :offset';

        List<Product_Extension__c> products = Database.query(query);
        Integer totalCount = Database.countQuery(countQuery);

        // Build result
        ProductCatalogResult result = new ProductCatalogResult();
        result.totalCount = totalCount;
        result.products = new List<ProductWrapper>();

        for (Product_Extension__c p : products) {
            ProductWrapper pw = new ProductWrapper();
            pw.productId = p.Id;
            pw.name = p.Name;
            pw.isActive = p.Is_Active__c;
            pw.categoryName = p.Product_Category__r != null ? p.Product_Category__r.Name : null;
            pw.categoryId = p.Product_Category__c;
            pw.barcodeEAN = p.Barcode_EAN__c;
            pw.barcodeUPC = p.Barcode_UPC__c;
            pw.hsnCode = p.HSN_SAC_Code__c;
            pw.weight = p.Weight__c;
            pw.weightUnit = p.Weight_Unit__c;
            pw.caseSize = p.Case_Size__c;
            pw.minOrderQty = p.Min_Order_Qty__c;
            pw.extIsActive = p.Is_Active__c;
            pw.imageUrl = p.Product_Image_URL__c;

            result.products.add(pw);
        }

        return result;
    }

    /**
     * @description Retrieves the category hierarchy tree.
     * @return List of CategoryNode objects representing the tree structure.
     */
    @AuraEnabled(cacheable=true)
    public static List<CategoryNode> getCategoryTree() {
        List<Product_Category__c> allCategories = [
            SELECT Id, Name, Category_Code__c, Level__c, Parent_Category__c, Sort_Order__c, Is_Active__c
            FROM Product_Category__c
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c ASC, Name ASC
        ];

        // Build tree structure
        Map<Id, CategoryNode> nodeMap = new Map<Id, CategoryNode>();
        List<CategoryNode> rootNodes = new List<CategoryNode>();

        for (Product_Category__c cat : allCategories) {
            CategoryNode node = new CategoryNode();
            node.id = cat.Id;
            node.name = cat.Name;
            node.code = cat.Category_Code__c;
            node.level = cat.Level__c;
            node.parentId = cat.Parent_Category__c;
            node.sortOrder = cat.Sort_Order__c != null ? (Integer) cat.Sort_Order__c : 0;
            node.children = new List<CategoryNode>();
            nodeMap.put(cat.Id, node);
        }

        for (CategoryNode node : nodeMap.values()) {
            if (node.parentId != null && nodeMap.containsKey(node.parentId)) {
                nodeMap.get(node.parentId).children.add(node);
            } else {
                rootNodes.add(node);
            }
        }

        return rootNodes;
    }

    /**
     * @description Retrieves active price list entries for a given product.
     * @param productId The Product_Extension__c Id.
     * @return List of Price_List__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Price_List__c> getProductPricing(Id productId) {
        return [
            SELECT Id, Name, Unit_Price__c, Price_Type__c, Channel__c,
                   Region__c, Region__r.Name, Effective_From__c, Effective_To__c,
                   Min_Qty__c, Is_Active__c, Priority__c,
                   Customer__c, Customer__r.Name,
                   Territory__c, Territory__r.Name,
                   Category__c, Category__r.Name
            FROM Price_List__c
            WHERE Product_Ext__c = :productId
              AND Is_Active__c = true
              AND (Effective_To__c = null OR Effective_To__c >= TODAY)
              AND Effective_From__c <= TODAY
            ORDER BY Priority__c ASC, Price_Type__c ASC, Channel__c ASC
        ];
    }

    /**
     * @description Retrieves product details including extension, pricing, and stock counts.
     * @param productId The Product_Extension__c Id.
     * @return ProductDetailWrapper with full product info.
     */
    @AuraEnabled(cacheable=true)
    public static ProductDetailWrapper getProductDetail(Id productId) {
        Product_Extension__c product = [
            SELECT Id, Name, Product_Category__c, Product_Category__r.Name,
                   Barcode_EAN__c, Barcode_UPC__c, HSN_SAC_Code__c, Weight__c,
                   Weight_Unit__c, Case_Size__c, Min_Order_Qty__c, Is_Active__c,
                   Product_Image_URL__c, SKU_Code__c, MRP__c, Unit_Price__c, Brand__c
            FROM Product_Extension__c
            WHERE Id = :productId
        ];

        ProductDetailWrapper detail = new ProductDetailWrapper();
        detail.productId = product.Id;
        detail.name = product.Name;
        detail.isActive = product.Is_Active__c;
        detail.categoryName = product.Product_Category__r != null ? product.Product_Category__r.Name : null;
        detail.barcodeEAN = product.Barcode_EAN__c;
        detail.barcodeUPC = product.Barcode_UPC__c;
        detail.hsnCode = product.HSN_SAC_Code__c;
        detail.weight = product.Weight__c;
        detail.weightUnit = product.Weight_Unit__c;
        detail.caseSize = product.Case_Size__c;
        detail.minOrderQty = product.Min_Order_Qty__c;
        detail.imageUrl = product.Product_Image_URL__c;
        detail.skuCode = product.SKU_Code__c;
        detail.mrp = product.MRP__c;
        detail.unitPrice = product.Unit_Price__c;
        detail.brand = product.Brand__c;

        // Get pricing
        detail.priceLists = getProductPricing(productId);

        // Get active batch count
        detail.activeBatchCount = [
            SELECT COUNT() FROM Batch_Master__c
            WHERE Product_Ext__c = :productId AND Status__c = 'Active'
        ];

        // Get total distributor stock (current entries)
        AggregateResult[] stockAgg = [
            SELECT SUM(Closing_Stock__c) totalStock
            FROM Distributor_Stock__c
            WHERE Product_Ext__c = :productId AND Is_Current__c = true
        ];
        detail.totalDistributorStock = stockAgg[0].get('totalStock') != null ?
            (Decimal) stockAgg[0].get('totalStock') : 0;

        return detail;
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    /**
     * @description Collects all category IDs in the hierarchy below and including a given category.
     */
    private static Set<Id> getCategoryHierarchyIds(Id categoryId) {
        Set<Id> ids = new Set<Id>{ categoryId };
        Set<Id> parentIds = new Set<Id>{ categoryId };

        // Walk down the hierarchy (max 3 levels: Category -> Sub-Category -> Brand)
        for (Integer i = 0; i < 3; i++) {
            List<Product_Category__c> children = [
                SELECT Id FROM Product_Category__c
                WHERE Parent_Category__c IN :parentIds AND Is_Active__c = true
            ];
            if (children.isEmpty()) break;
            parentIds.clear();
            for (Product_Category__c child : children) {
                ids.add(child.Id);
                parentIds.add(child.Id);
            }
        }

        return ids;
    }

    // ── Wrapper Classes ───────────────────────────────────────────────────────

    public class ProductCatalogResult {
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public List<ProductWrapper> products;
    }

    public class ProductWrapper {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String productCode;
        @AuraEnabled public String family;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public String description;
        @AuraEnabled public String categoryName;
        @AuraEnabled public Id categoryId;
        @AuraEnabled public String barcodeEAN;
        @AuraEnabled public String barcodeUPC;
        @AuraEnabled public String hsnCode;
        @AuraEnabled public Decimal weight;
        @AuraEnabled public String weightUnit;
        @AuraEnabled public Decimal caseSize;
        @AuraEnabled public Decimal minOrderQty;
        @AuraEnabled public Boolean extIsActive;
        @AuraEnabled public String imageUrl;
    }

    public class ProductDetailWrapper {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String productCode;
        @AuraEnabled public String family;
        @AuraEnabled public Boolean isActive;
        @AuraEnabled public String description;
        @AuraEnabled public String categoryName;
        @AuraEnabled public String barcodeEAN;
        @AuraEnabled public String barcodeUPC;
        @AuraEnabled public String hsnCode;
        @AuraEnabled public Decimal weight;
        @AuraEnabled public String weightUnit;
        @AuraEnabled public Decimal caseSize;
        @AuraEnabled public Decimal minOrderQty;
        @AuraEnabled public String imageUrl;
        @AuraEnabled public String skuCode;
        @AuraEnabled public Decimal mrp;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public String brand;
        @AuraEnabled public List<Price_List__c> priceLists;
        @AuraEnabled public Integer activeBatchCount;
        @AuraEnabled public Decimal totalDistributorStock;
    }

    public class CategoryNode {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String code;
        @AuraEnabled public String level;
        @AuraEnabled public Id parentId;
        @AuraEnabled public Integer sortOrder;
        @AuraEnabled public List<CategoryNode> children;
    }
}