/**
 * @description Company-wide stock overview: the whole chain in one read —
 *              warehouse on-hand → in-transit transfers → distributor on-hand,
 *              plus near-expiry / low-stock alerts and the movement ledger.
 *
 *              This is deliberately an INTERNAL view, not a portal one: a distributor must
 *              never see the company warehouse or another distributor's position. The
 *              distributor's own stock is served, account-scoped, by DMS_PortalController.
 */
public with sharing class INV_StockManagementController {

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    public class LocationRow {
        @AuraEnabled public String name;
        @AuraEnabled public Integer skus = 0;
        @AuraEnabled public Decimal units = 0;
        @AuraEnabled public Decimal value = 0;
        @AuraEnabled public Integer lowStock = 0;
    }
    public class TransitRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String source;
        @AuraEnabled public String destination;
        @AuraEnabled public String status;
        @AuraEnabled public Date transferDate;
        @AuraEnabled public Decimal units = 0;
    }
    public class AlertRow {
        @AuraEnabled public String kind;        // Near Expiry | Low Stock
        @AuraEnabled public String location;
        @AuraEnabled public String product;
        @AuraEnabled public String batch;
        @AuraEnabled public Decimal quantity = 0;
        @AuraEnabled public Date expiryDate;
    }
    public class MovementRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Datetime txnDate;
        @AuraEnabled public String txnType;
        @AuraEnabled public String direction;
        @AuraEnabled public String product;
        @AuraEnabled public String batch;
        @AuraEnabled public Decimal quantity = 0;
        @AuraEnabled public String location;
        @AuraEnabled public String reference;
    }

    public class Overview {
        @AuraEnabled public Decimal warehouseUnits = 0;
        @AuraEnabled public Decimal warehouseValue = 0;
        @AuraEnabled public Integer warehouseSkus = 0;
        @AuraEnabled public Decimal distributorUnits = 0;
        @AuraEnabled public Decimal distributorValue = 0;
        @AuraEnabled public Integer distributorSkus = 0;
        @AuraEnabled public Decimal inTransitUnits = 0;
        @AuraEnabled public Integer nearExpiryCount = 0;
        @AuraEnabled public Integer lowStockCount = 0;
        @AuraEnabled public List<LocationRow> warehouses = new List<LocationRow>();
        @AuraEnabled public List<LocationRow> distributors = new List<LocationRow>();
        @AuraEnabled public List<TransitRow> inTransit = new List<TransitRow>();
        @AuraEnabled public List<AlertRow> alerts = new List<AlertRow>();
        @AuraEnabled public List<MovementRow> movements = new List<MovementRow>();
    }

    @AuraEnabled(cacheable=true)
    public static Overview getOverview() {
        Overview o = new Overview();
        Date nearCut = Date.today().addDays(DMS_Config.nearExpiryDays());

        // ── Warehouse on-hand ────────────────────────────────────────────────
        Map<String, LocationRow> whRows = new Map<String, LocationRow>();
        for (Warehouse_Stock__c ws : [
            SELECT Warehouse__r.Name, Product_Ext__r.Name, Product_Ext__r.Unit_Price__c,
                   Batch_Number__c, Expiry_Date__c, Qty_On_Hand__c, Is_Low_Stock__c
            FROM Warehouse_Stock__c
            WHERE Product_Ext__c != null AND Qty_On_Hand__c > 0
            LIMIT 5000
        ]) {
            String wh = ws.Warehouse__r != null ? ws.Warehouse__r.Name : 'Unassigned';
            if (!whRows.containsKey(wh)) {
                LocationRow r = new LocationRow();
                r.name = wh;
                whRows.put(wh, r);
            }
            LocationRow row = whRows.get(wh);
            Decimal qty = nz(ws.Qty_On_Hand__c);
            Decimal val = qty * (ws.Product_Ext__r != null ? nz(ws.Product_Ext__r.Unit_Price__c) : 0);
            row.skus++;
            row.units += qty;
            row.value += val;
            if (ws.Is_Low_Stock__c == true) { row.lowStock++; o.lowStockCount++; }

            o.warehouseSkus++;
            o.warehouseUnits += qty;
            o.warehouseValue += val;

            if (ws.Expiry_Date__c != null && ws.Expiry_Date__c <= nearCut) {
                o.nearExpiryCount++;
                if (o.alerts.size() < 50) {
                    AlertRow a = new AlertRow();
                    a.kind = 'Near Expiry';
                    a.location = wh;
                    a.product = ws.Product_Ext__r != null ? ws.Product_Ext__r.Name : '';
                    a.batch = ws.Batch_Number__c;
                    a.quantity = qty;
                    a.expiryDate = ws.Expiry_Date__c;
                    o.alerts.add(a);
                }
            }
        }
        o.warehouses = whRows.values();

        // ── Distributor on-hand (current snapshots only) ─────────────────────
        Map<String, LocationRow> distRows = new Map<String, LocationRow>();
        for (Distributor_Stock__c ds : [
            SELECT Account__r.Name, Product_Ext__r.Name, Product_Ext__r.Unit_Price__c,
                   Batch_No__c, Expiry_Date__c, Closing_Stock__c
            FROM Distributor_Stock__c
            WHERE Is_Current__c = true AND Closing_Stock__c > 0 AND Product_Ext__c != null
            LIMIT 5000
        ]) {
            String acct = ds.Account__r != null ? ds.Account__r.Name : 'Unassigned';
            if (!distRows.containsKey(acct)) {
                LocationRow r = new LocationRow();
                r.name = acct;
                distRows.put(acct, r);
            }
            LocationRow row = distRows.get(acct);
            Decimal qty = nz(ds.Closing_Stock__c);
            Decimal val = qty * (ds.Product_Ext__r != null ? nz(ds.Product_Ext__r.Unit_Price__c) : 0);
            row.skus++;
            row.units += qty;
            row.value += val;

            o.distributorSkus++;
            o.distributorUnits += qty;
            o.distributorValue += val;

            if (ds.Expiry_Date__c != null && ds.Expiry_Date__c <= nearCut) {
                o.nearExpiryCount++;
                if (o.alerts.size() < 50) {
                    AlertRow a = new AlertRow();
                    a.kind = 'Near Expiry';
                    a.location = acct;
                    a.product = ds.Product_Ext__r != null ? ds.Product_Ext__r.Name : '';
                    a.batch = ds.Batch_No__c;
                    a.quantity = qty;
                    a.expiryDate = ds.Expiry_Date__c;
                    o.alerts.add(a);
                }
            }
        }
        o.distributors = distRows.values();

        // ── In transit: dispatched from the source, not yet received ─────────
        Map<Id, TransitRow> transitById = new Map<Id, TransitRow>();
        for (Stock_Transfer__c t : [
            SELECT Id, Name, Status__c, Transfer_Date__c,
                   Source_Warehouse__r.Name, Destination_Warehouse__r.Name
            FROM Stock_Transfer__c
            WHERE Status__c IN ('Approved', 'In_Transit')
            ORDER BY Transfer_Date__c DESC
            LIMIT 100
        ]) {
            TransitRow r = new TransitRow();
            r.id = t.Id;
            r.name = t.Name;
            r.status = t.Status__c;
            r.transferDate = t.Transfer_Date__c;
            r.source = t.Source_Warehouse__r != null ? t.Source_Warehouse__r.Name : '';
            r.destination = t.Destination_Warehouse__r != null ? t.Destination_Warehouse__r.Name : '';
            transitById.put(t.Id, r);
        }
        if (!transitById.isEmpty()) {
            // Only count lines that reference a real product. Without this, transfer lines
            // orphaned from a retired product catalog were summed into the in-transit total,
            // reporting phantom units that corresponded to no actual goods.
            for (AggregateResult ar : [
                SELECT Stock_Transfer__c tid, SUM(Approved_Qty__c) q
                FROM Stock_Transfer_Line__c
                WHERE Stock_Transfer__c IN :transitById.keySet()
                  AND Product_Ext__c != null
                GROUP BY Stock_Transfer__c
            ]) {
                TransitRow r = transitById.get((Id) ar.get('tid'));
                if (r != null) {
                    r.units = ar.get('q') == null ? 0 : (Decimal) ar.get('q');
                    o.inTransitUnits += r.units;
                }
            }
        }
        o.inTransit = transitById.values();

        // ── Movement ledger (every stock movement leaves a row here) ─────────
        for (Stock_Transaction__c st : [
            SELECT Id, Transaction_Date__c, Transaction_Type__c, Direction__c, Quantity__c,
                   Batch_Number__c, Reference_Type__c,
                   Product_Ext__r.Name, Warehouse__r.Name, Account__r.Name
            FROM Stock_Transaction__c
            ORDER BY CreatedDate DESC
            LIMIT 25
        ]) {
            MovementRow m = new MovementRow();
            m.id = st.Id;
            m.txnDate = st.Transaction_Date__c;
            m.txnType = st.Transaction_Type__c;
            m.direction = st.Direction__c;
            m.quantity = nz(st.Quantity__c);
            m.batch = st.Batch_Number__c;
            m.reference = st.Reference_Type__c;
            m.product = st.Product_Ext__r != null ? st.Product_Ext__r.Name : '';
            m.location = st.Warehouse__r != null ? st.Warehouse__r.Name
                        : (st.Account__r != null ? st.Account__r.Name : '');
            o.movements.add(m);
        }

        return o;
    }
}