/**
 * @description REST API for Product Extension master data (Mobile App).
 *              Covers:
 *                - Product List (active products with discount info)
 *
 * @author  SFA Development Team
 * @date    2026
 */
@RestResource(urlMapping='/mobile/product/*')
global with sharing class API_Product_Rest {

    @HttpGet
    global static void handleGet() {
        RestRequest req = RestContext.request;
        String path = req.requestURI;

        try {
            if (path.endsWith('/list')) {
                doProductList();
            } else {
                API_ResponseWrapper.sendError('Invalid endpoint.');
            }
        } catch (Exception e) {
            API_ResponseWrapper.sendServerError(e.getMessage());
        }
    }

    // ── Product List ──────────────────────────────────────────────────────

    private static void doProductList() {
        List<Product_Extension__c> products = [
            SELECT Id, Name, Is_Active__c, Weight__c, Weight_Unit__c,
                   HSN_SAC_Code__c, Barcode_EAN__c, Case_Size__c, Min_Order_Qty__c,
                    Product_Category__r.Name
            FROM Product_Extension__c
            WHERE Is_Active__c = true
            ORDER BY Name ASC
        ];

        // Collect Product Ids for discount lookup
        Set<Id> productIds = new Set<Id>();
        for (Product_Extension__c pe : products) {
            if (pe.Id != null) {
                productIds.add(pe.Id);
            }
        }

        // Fetch active schemes/discounts for these products
        Map<Id, Scheme__c> discountByProduct = new Map<Id, Scheme__c>();
        if (!productIds.isEmpty()) {
            for (Scheme__c scheme : [
                SELECT Product_Ext__c, Discount_Percent__c, Start_Date__c, End_Date__c
                FROM Scheme__c
                WHERE Product_Ext__c IN :productIds
                  AND Status__c = 'Active'
                  AND Start_Date__c <= TODAY
                  AND End_Date__c >= TODAY
                ORDER BY Priority__c ASC
            ]) {
                // Keep the highest priority (first) scheme per product
                if (!discountByProduct.containsKey(scheme.Product_Ext__c)) {
                    discountByProduct.put(scheme.Product_Ext__c, scheme);
                }
            }
        }

        List<Map<String, Object>> dataList = new List<Map<String, Object>>();
        for (Product_Extension__c pe : products) {
            Scheme__c discount = pe.Id != null ? discountByProduct.get(pe.Id) : null;
            dataList.add(buildProductResponse(pe, discount));
        }

        API_ResponseWrapper.sendSuccess('Products fetched successfully', dataList);
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static Map<String, Object> buildProductResponse(Product_Extension__c pe, Scheme__c discount) {
        Map<String, Object> item = new Map<String, Object>();
       // item.put('_object_name', 'Product_sfa__c (Master Object)');
        item.put('Product_Code__c', pe.HSN_SAC_Code__c != null ? pe.HSN_SAC_Code__c : '');
        item.put('Name', pe.Name);
        item.put('Category__c', pe.Product_Category__r != null ? pe.Product_Category__r.Name : '');
        item.put('Unit_Price__c', 0);
        item.put('Stock_Quantity__c', 0);
        item.put('Unit__c', pe.Weight_Unit__c != null ? pe.Weight_Unit__c : '');
        item.put('Brand__c', '');
        item.put('Description__c', '');
        item.put('Is_Active__c', pe.Is_Active__c);

        if (discount != null) {
            item.put('Discount_Percentage__c', discount.Discount_Percent__c != null ? discount.Discount_Percent__c : 0);
            item.put('Discount_Valid_From__c', discount.Start_Date__c != null ? String.valueOf(discount.Start_Date__c) : '');
            item.put('Discount_Valid_To__c', discount.End_Date__c != null ? String.valueOf(discount.End_Date__c) : '');
        } else {
            item.put('Discount_Percentage__c', 0);
            item.put('Discount_Valid_From__c', '');
            item.put('Discount_Valid_To__c', '');
        }

        return item;
    }
}