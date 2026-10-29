/**
 * @description Service class for validating warehouse stock availability
 *              before order approval. Checks that sufficient stock exists
 *              for all line items in an order.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class OMS_StockAvailability_Service {

    /**
     * @description Validates that warehouse stock is available for the given orders.
     *              Adds errors to orders where stock is insufficient.
     * @param orderIds Set of Sales_Order__c Ids to validate.
     * @return Map of orderId to list of shortage messages (empty list = sufficient stock).
     */
    public static Map<Id, List<String>> validateStockAvailability(Set<Id> orderIds) {
        Map<Id, List<String>> shortages = new Map<Id, List<String>>();
        for (Id orderId : orderIds) {
            shortages.put(orderId, new List<String>());
        }

        // Get all line items for the orders
        List<Order_Line_Item__c> lineItems = [
            SELECT Id, Sales_Order__c, Product_Ext__c, Product_Ext__r.Name,
                   Quantity__c, Base_Quantity__c, Sales_Order__r.Warehouse__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :orderIds
        ];

        if (lineItems.isEmpty()) return shortages;

        // Collect required products and warehouses
        Set<Id> productIds = new Set<Id>();
        Set<Id> warehouseIds = new Set<Id>();
        for (Order_Line_Item__c li : lineItems) {
            if (li.Product_Ext__c != null) productIds.add(li.Product_Ext__c);
            if (li.Sales_Order__r.Warehouse__c != null) warehouseIds.add(li.Sales_Order__r.Warehouse__c);
        }

        if (productIds.isEmpty() || warehouseIds.isEmpty()) return shortages;

        // Get current stock levels (exclude expired batches)
        Map<String, Decimal> stockMap = new Map<String, Decimal>();
        for (Warehouse_Stock__c ws : [
            SELECT Product_Ext__c, Warehouse__c, Qty_On_Hand__c, Qty_Reserved__c
            FROM Warehouse_Stock__c
            WHERE Product_Ext__c IN :productIds
              AND Warehouse__c IN :warehouseIds
              AND (Expiry_Date__c = null OR Expiry_Date__c > TODAY)
        ]) {
            String key = ws.Warehouse__c + '|' + ws.Product_Ext__c;
            Decimal available = (ws.Qty_On_Hand__c != null ? ws.Qty_On_Hand__c : 0)
                              - (ws.Qty_Reserved__c != null ? ws.Qty_Reserved__c : 0);
            stockMap.put(key, available);
        }

        // Aggregate demand per order per product per warehouse
        Map<String, Decimal> demandMap = new Map<String, Decimal>();
        Map<String, Id> demandToOrder = new Map<String, Id>();
        Map<String, String> demandToProduct = new Map<String, String>();

        for (Order_Line_Item__c li : lineItems) {
            if (li.Product_Ext__c == null || li.Sales_Order__r.Warehouse__c == null) continue;

            String key = li.Sales_Order__r.Warehouse__c + '|' + li.Product_Ext__c;
            Decimal current = demandMap.containsKey(key) ? demandMap.get(key) : 0;
            Decimal qty = (li.Base_Quantity__c != null && li.Base_Quantity__c > 0)
                ? li.Base_Quantity__c : (li.Quantity__c != null ? li.Quantity__c : 0);
            demandMap.put(key, current + qty);
            demandToOrder.put(key, li.Sales_Order__c);
            demandToProduct.put(key, li.Product_Ext__r.Name);
        }

        // Check availability
        for (String key : demandMap.keySet()) {
            Decimal demanded = demandMap.get(key);
            Decimal available = stockMap.containsKey(key) ? stockMap.get(key) : 0;

            if (demanded > available) {
                Id orderId = demandToOrder.get(key);
                String productName = demandToProduct.get(key);
                shortages.get(orderId).add(
                    productName + ': required ' + demanded + ', available ' + available
                );
            }
        }

        return shortages;
    }

    /** Open (committed but unfulfilled) order statuses that hold an implicit reservation. */
    private static final Set<String> OPEN_STATUSES = new Set<String>{ 'Submitted', 'Approved' };

    /**
     * @description Reservation guard for order submission. validateStockAvailability checks each
     *              order against (on-hand − reserved) in ISOLATION, so two orders can each pass
     *              while together overselling the same units — and secondary invoices stay Draft,
     *              so nothing ever actually reserves or deducts the stock. This sets aside the
     *              demand already committed by OTHER open orders (an implicit reservation) before
     *              deciding whether the submitting orders fit. Cancelled / Rejected / Delivered
     *              orders release automatically because they are not counted as open.
     *
     *              Handles BOTH supply sources, because an order is served either from the company
     *              warehouse or from a distributor's own stock depending on
     *              Sold_From_Distributor__c:
     *
     *                warehouse    supply = Warehouse_Stock__c (on-hand − reserved), keyed by
     *                             warehouse; released implicitly by order status.
     *                distributor  supply = the current Distributor_Stock__c snapshots, keyed by
     *                             distributor; released when the order is billed, because billing
     *                             is what actually moves distributor stock.
     *
     *              Distributor-supplied orders previously fell straight through this guard: it
     *              bailed out whenever Warehouse__c was null and only ever read warehouse supply.
     *              Two reps could therefore each book the same units from one distributor, both
     *              orders would approve, and the second invoice would fail at FEFO allocation —
     *              after the retailer had been promised the goods.
     *
     * @param submittingOrderIds Sales_Order Ids transitioning to Submitted.
     * @return Map of orderId → shortage messages (empty list = fits).
     */
    public static Map<Id, List<String>> validateForReservation(Set<Id> submittingOrderIds) {
        Map<Id, List<String>> shortages = new Map<Id, List<String>>();
        if (submittingOrderIds == null || submittingOrderIds.isEmpty()) { return shortages; }
        for (Id id : submittingOrderIds) { shortages.put(id, new List<String>()); }

        List<Order_Line_Item__c> subLines = [
            SELECT Sales_Order__c, Product_Ext__c, Product_Ext__r.Name,
                   Quantity__c, Base_Quantity__c,
                   Sales_Order__r.Warehouse__c, Sales_Order__r.Sold_From_Distributor__c
            FROM Order_Line_Item__c WHERE Sales_Order__c IN :submittingOrderIds
            ORDER BY Sales_Order__c
        ];
        if (subLines.isEmpty()) { return shortages; }

        Set<Id> productIds = new Set<Id>();
        Set<Id> warehouseIds = new Set<Id>();
        Set<Id> distributorIds = new Set<Id>();
        for (Order_Line_Item__c li : subLines) {
            if (li.Product_Ext__c == null) { continue; }
            productIds.add(li.Product_Ext__c);
            if (li.Sales_Order__r.Sold_From_Distributor__c != null) {
                distributorIds.add(li.Sales_Order__r.Sold_From_Distributor__c);
            } else if (li.Sales_Order__r.Warehouse__c != null) {
                warehouseIds.add(li.Sales_Order__r.Warehouse__c);
            }
        }
        if (productIds.isEmpty()) { return shortages; }

        // Supply, keyed "<supplierId>|<productId>" so both sources share one ledger.
        Map<String, Decimal> available = new Map<String, Decimal>();

        if (!warehouseIds.isEmpty()) {
            // Warehouse supply, net of any explicit reservation, non-expired.
            for (Warehouse_Stock__c ws : [
                SELECT Product_Ext__c, Warehouse__c, Qty_On_Hand__c, Qty_Reserved__c
                FROM Warehouse_Stock__c
                WHERE Product_Ext__c IN :productIds AND Warehouse__c IN :warehouseIds
                  AND (Expiry_Date__c = null OR Expiry_Date__c > TODAY)
            ]) {
                String key = ws.Warehouse__c + '|' + ws.Product_Ext__c;
                Decimal a = (ws.Qty_On_Hand__c == null ? 0 : ws.Qty_On_Hand__c)
                          - (ws.Qty_Reserved__c == null ? 0 : ws.Qty_Reserved__c);
                available.put(key, (available.containsKey(key) ? available.get(key) : 0) + a);
            }

            // Demand already committed by OTHER open warehouse orders.
            for (Order_Line_Item__c li : [
                SELECT Product_Ext__c, Quantity__c, Base_Quantity__c, Sales_Order__r.Warehouse__c
                FROM Order_Line_Item__c
                WHERE Product_Ext__c IN :productIds
                  AND Sales_Order__r.Warehouse__c IN :warehouseIds
                  AND Sales_Order__r.Sold_From_Distributor__c = null
                  AND Sales_Order__r.Status__c IN :OPEN_STATUSES
                  AND Sales_Order__c NOT IN :submittingOrderIds
            ]) {
                if (li.Product_Ext__c == null || li.Sales_Order__r.Warehouse__c == null) { continue; }
                String key = li.Sales_Order__r.Warehouse__c + '|' + li.Product_Ext__c;
                available.put(key, (available.containsKey(key) ? available.get(key) : 0) - qtyOf(li));
            }
        }

        if (!distributorIds.isEmpty()) {
            // Distributor supply: the current snapshot per Account|Product|Batch. Expired batches
            // cannot be sold, so they are not supply — this mirrors the FEFO allocator, which
            // would refuse them at billing time anyway.
            for (Distributor_Stock__c ds : [
                SELECT Account__c, Product_Ext__c, Closing_Stock__c
                FROM Distributor_Stock__c
                WHERE Account__c IN :distributorIds AND Product_Ext__c IN :productIds
                  AND Is_Current__c = true
                  AND (Expiry_Date__c = null OR Expiry_Date__c > TODAY)
            ]) {
                String key = ds.Account__c + '|' + ds.Product_Ext__c;
                Decimal a = (ds.Closing_Stock__c == null ? 0 : ds.Closing_Stock__c);
                available.put(key, (available.containsKey(key) ? available.get(key) : 0) + a);
            }

            // Demand already committed by OTHER open, UNBILLED orders on the same distributor.
            // Invoice__c != null means the goods were already billed out, which physically moved
            // the stock — counting those again would reserve the same units twice.
            for (Order_Line_Item__c li : [
                SELECT Product_Ext__c, Quantity__c, Base_Quantity__c,
                       Sales_Order__r.Sold_From_Distributor__c
                FROM Order_Line_Item__c
                WHERE Product_Ext__c IN :productIds
                  AND Sales_Order__r.Sold_From_Distributor__c IN :distributorIds
                  AND Sales_Order__r.Invoice__c = null
                  AND Sales_Order__r.Status__c IN :OPEN_STATUSES
                  AND Sales_Order__c NOT IN :submittingOrderIds
            ]) {
                if (li.Product_Ext__c == null
                    || li.Sales_Order__r.Sold_From_Distributor__c == null) { continue; }
                String key = li.Sales_Order__r.Sold_From_Distributor__c + '|' + li.Product_Ext__c;
                available.put(key, (available.containsKey(key) ? available.get(key) : 0) - qtyOf(li));
            }
        }

        // Allocate the submitting orders' demand against what's left, consuming as we go so two
        // submitting orders (or two lines) can't both claim the same remaining units.
        for (Order_Line_Item__c li : subLines) {
            if (li.Product_Ext__c == null) { continue; }
            Boolean fromDistributor = li.Sales_Order__r.Sold_From_Distributor__c != null;
            Id supplierId = fromDistributor
                ? li.Sales_Order__r.Sold_From_Distributor__c
                : li.Sales_Order__r.Warehouse__c;
            if (supplierId == null) { continue; }

            String key = supplierId + '|' + li.Product_Ext__c;
            Decimal avail = available.containsKey(key) ? available.get(key) : 0;
            Decimal need = qtyOf(li);
            if (need > avail) {
                shortages.get(li.Sales_Order__c).add(
                    li.Product_Ext__r.Name + ': need ' + need + ', uncommitted '
                    + (fromDistributor ? 'distributor' : 'warehouse') + ' stock '
                    + (avail < 0 ? 0 : avail)
                );
            }
            available.put(key, avail - need);
        }
        return shortages;
    }

    private static Decimal qtyOf(Order_Line_Item__c li) {
        return (li.Base_Quantity__c != null && li.Base_Quantity__c > 0)
            ? li.Base_Quantity__c : (li.Quantity__c != null ? li.Quantity__c : 0);
    }
}