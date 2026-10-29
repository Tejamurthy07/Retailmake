public with sharing class ProductThreeSixtyController {

    @AuraEnabled(cacheable=true)
    public static Product_Extension__c getProductDetails(Id productId) {
        List<Product_Extension__c> products = [
            SELECT Id, Name, SKU_Code__c, Brand__c, MRP__c, Unit_Price__c,
                   GST_Rate__c, HSN_SAC_Code__c, Barcode_EAN__c, Barcode_UPC__c,
                   Unit_of_Measure__c, Case_Size__c, Weight__c, Weight_Unit__c,
                   Min_Order_Qty__c, Reorder_Level__c, Reorder_Quantity__c,
                   Shelf_Life_Days__c, Is_Active__c, Is_Returnable__c,
                   Product_Image_URL__c,
                   Product_Category__c, Product_Category__r.Name,
                   Sub_Category__c, Sub_Category__r.Name,
                   CreatedDate, LastModifiedDate
            FROM Product_Extension__c
            WHERE Id = :productId
            LIMIT 1
        ];
        if (products.isEmpty()) {
            throw new AuraHandledException('Product not found.');
        }
        return products[0];
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getProductKPIs(Id productId) {
        Map<String, Object> kpis = new Map<String, Object>();
        Date today = Date.today();
        Date mtdStart = today.toStartOfMonth();
        Date threeMonthsAgo = today.addMonths(-3);

        // MTD Order Quantity & Value
        AggregateResult[] orderAgg = [
            SELECT SUM(Quantity__c) totalQty, SUM(Line_Total__c) totalValue, COUNT(Id) lineCount
            FROM Order_Line_Item__c
            WHERE Product_Ext__c = :productId
            AND Sales_Order__r.Order_Date__c >= :mtdStart
            AND Sales_Order__r.Order_Date__c <= :today
            AND Sales_Order__r.Status__c NOT IN ('Cancelled', 'Rejected')
        ];
        if (!orderAgg.isEmpty()) {
            Decimal qty = (Decimal)orderAgg[0].get('totalQty');
            Decimal val = (Decimal)orderAgg[0].get('totalValue');
            kpis.put('mtdOrderQty', qty != null ? qty : 0);
            kpis.put('mtdOrderValue', val != null ? val : 0);
            kpis.put('mtdOrderLines', (Integer)orderAgg[0].get('lineCount'));
        } else {
            kpis.put('mtdOrderQty', 0);
            kpis.put('mtdOrderValue', 0);
            kpis.put('mtdOrderLines', 0);
        }

        // Total Warehouse Stock
        AggregateResult[] whStockAgg = [
            SELECT SUM(Qty_On_Hand__c) totalOnHand, SUM(Qty_Available__c) totalAvailable
            FROM Warehouse_Stock__c
            WHERE Product_Ext__c = :productId
        ];
        if (!whStockAgg.isEmpty()) {
            Decimal onHand = (Decimal)whStockAgg[0].get('totalOnHand');
            Decimal avail = (Decimal)whStockAgg[0].get('totalAvailable');
            kpis.put('totalStockOnHand', onHand != null ? onHand : 0);
            kpis.put('totalStockAvailable', avail != null ? avail : 0);
        } else {
            kpis.put('totalStockOnHand', 0);
            kpis.put('totalStockAvailable', 0);
        }

        // Total Distributor Stock
        AggregateResult[] distStockAgg = [
            SELECT SUM(Closing_Stock__c) totalClosing
            FROM Distributor_Stock__c
            WHERE Product_Ext__c = :productId
            AND Is_Current__c = true
        ];
        if (!distStockAgg.isEmpty()) {
            Decimal closing = (Decimal)distStockAgg[0].get('totalClosing');
            kpis.put('totalDistributorStock', closing != null ? closing : 0);
        } else {
            kpis.put('totalDistributorStock', 0);
        }

        // Active Batch Count
        AggregateResult[] batchAgg = [
            SELECT COUNT(Id) batchCount
            FROM Batch_Master__c
            WHERE Product_Ext__c = :productId
            AND Status__c = 'Active'
        ];
        kpis.put('activeBatches', batchAgg.isEmpty() ? 0 : (Integer)batchAgg[0].get('batchCount'));

        // 3-Month Order Trend
        AggregateResult[] trendAgg = [
            SELECT SUM(Quantity__c) totalQty, SUM(Line_Total__c) totalValue
            FROM Order_Line_Item__c
            WHERE Product_Ext__c = :productId
            AND Sales_Order__r.Order_Date__c >= :threeMonthsAgo
            AND Sales_Order__r.Order_Date__c <= :today
            AND Sales_Order__r.Status__c NOT IN ('Cancelled', 'Rejected')
        ];
        if (!trendAgg.isEmpty()) {
            Decimal tQty = (Decimal)trendAgg[0].get('totalQty');
            Decimal tVal = (Decimal)trendAgg[0].get('totalValue');
            kpis.put('threeMonthOrderQty', tQty != null ? tQty : 0);
            kpis.put('threeMonthOrderValue', tVal != null ? tVal : 0);
        } else {
            kpis.put('threeMonthOrderQty', 0);
            kpis.put('threeMonthOrderValue', 0);
        }

        // Return Count (MTD)
        AggregateResult[] returnAgg = [
            SELECT SUM(Return_Quantity__c) totalReturnQty
            FROM Return_Line__c
            WHERE Product_Ext__c = :productId
            AND Return_Order__r.Return_Date__c >= :mtdStart
            AND Return_Order__r.Return_Date__c <= :today
        ];
        if (!returnAgg.isEmpty()) {
            Decimal retQty = (Decimal)returnAgg[0].get('totalReturnQty');
            kpis.put('mtdReturnQty', retQty != null ? retQty : 0);
        } else {
            kpis.put('mtdReturnQty', 0);
        }

        return kpis;
    }

    @AuraEnabled(cacheable=true)
    public static List<Batch_Master__c> getBatches(Id productId) {
        return [
            SELECT Id, Name, Batch_Number__c, Manufacturing_Date__c, Expiry_Date__c,
                   Quantity_Manufactured__c, Status__c, CreatedDate
            FROM Batch_Master__c
            WHERE Product_Ext__c = :productId
            ORDER BY Expiry_Date__c ASC NULLS LAST
            LIMIT 50
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Warehouse_Stock__c> getWarehouseStock(Id productId) {
        return [
            SELECT Id, Name, Warehouse__c, Warehouse__r.Name,
                   Qty_On_Hand__c, Qty_Available__c, Qty_Reserved__c,
                   Last_Transaction_Date__c
            FROM Warehouse_Stock__c
            WHERE Product_Ext__c = :productId
            ORDER BY Warehouse__r.Name ASC
            LIMIT 50
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Distributor_Stock__c> getDistributorStock(Id productId) {
        return [
            SELECT Id, Name, Account__c, Account__r.Name,
                   Opening_Stock__c, Received_Qty__c, Sold_Qty__c,
                   Damaged_Qty__c, Closing_Stock__c,
                   Batch_No__c, Expiry_Date__c, Stock_Date__c, Is_Current__c
            FROM Distributor_Stock__c
            WHERE Product_Ext__c = :productId
            AND Is_Current__c = true
            ORDER BY Account__r.Name ASC
            LIMIT 100
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Price_List__c> getPricing(Id productId) {
        return [
            SELECT Id, Name, Unit_Price__c, Effective_From__c, Effective_To__c,
                   Is_Active__c, CreatedDate
            FROM Price_List__c
            WHERE Product_Ext__c = :productId
            ORDER BY Effective_From__c DESC NULLS LAST
            LIMIT 20
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Order_Line_Item__c> getRecentOrderLines(Id productId, Integer limitCount) {
        Integer queryLimit = (limitCount != null && limitCount > 0) ? limitCount : 20;
        if (queryLimit > 100) queryLimit = 100;

        return [
            SELECT Id, Sales_Order__c, Sales_Order__r.Name, Sales_Order__r.Order_Date__c,
                   Sales_Order__r.Account__r.Name, Sales_Order__r.Status__c,
                   Quantity__c, Unit_Price__c, Discount_Amount__c, Tax_Amount__c, Line_Total__c
            FROM Order_Line_Item__c
            WHERE Product_Ext__c = :productId
            AND Sales_Order__r.Status__c NOT IN ('Cancelled', 'Rejected')
            ORDER BY Sales_Order__r.Order_Date__c DESC
            LIMIT :queryLimit
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Scheme__c> getActiveSchemes(Id productId) {
        Date today = Date.today();
        return [
            SELECT Id, Name, Scheme_Code__c, Scheme_Type__c, Description__c,
                   Start_Date__c, End_Date__c, Status__c,
                   Max_Discount_Cap__c, Is_Stackable__c
            FROM Scheme__c
            WHERE Product_Ext__c = :productId
            AND Is_Active__c = true
            AND Status__c = 'Active'
            AND Start_Date__c <= :today
            AND End_Date__c >= :today
            ORDER BY Start_Date__c ASC
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Return_Line__c> getRecentReturns(Id productId) {
        return [
            SELECT Id, Return_Order__c, Return_Order__r.Name, Return_Order__r.Return_Date__c,
                   Return_Order__r.Account__r.Name, Return_Order__r.Status__c,
                   Return_Quantity__c, Return_Reason__c
            FROM Return_Line__c
            WHERE Product_Ext__c = :productId
            ORDER BY Return_Order__r.Return_Date__c DESC
            LIMIT 20
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Stock_Transaction__c> getStockTransactions(Id productId) {
        return [
            SELECT Id, Name, Transaction_Type__c, Quantity__c,
                   Transaction_Date__c, Reference_Id__c,
                   Warehouse__c, Warehouse__r.Name
            FROM Stock_Transaction__c
            WHERE Product_Ext__c = :productId
            ORDER BY Transaction_Date__c DESC
            LIMIT 30
        ];
    }
}