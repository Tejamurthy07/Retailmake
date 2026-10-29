/**
 * @description LWC Controller for Goods Receipt Note (GRN) operations.
 *              Provides list, detail, create, status update, and lookup functionality.
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class INV_GRNController {

    /**
     * @description Lists GRNs with optional filters for status, date range, and warehouse.
     * @param status   Optional status filter (e.g. 'Pending', 'Received'). Pass 'all' or blank for no filter.
     * @param startDate Optional start of date range (GRN_Date__c >=).
     * @param endDate   Optional end of date range (GRN_Date__c <=).
     * @param warehouseId Optional warehouse filter (matched via Invoice__r.Warehouse__c).
     * @return List of GRN__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<GRN__c> getGRNs(String status, Date startDate, Date endDate, Id warehouseId) {
        String query = 'SELECT Id, Name, Status__c, GRN_Date__c, Invoice__c, Invoice__r.Name, ' +
                       'Invoice__r.Warehouse__c, Invoice__r.Warehouse__r.Name, ' +
                       'Account__c, Account__r.Name, Received_By__c, Notes__c, ' +
                       'Short_Qty__c, Damaged_Qty__c, Excess_Qty__c, ' +
                       'CreatedDate, LastModifiedDate ' +
                       'FROM GRN__c';

        List<String> conditions = new List<String>();

        if (String.isNotBlank(status) && status != 'all') {
            conditions.add('Status__c = :status');
        }
        if (startDate != null) {
            conditions.add('GRN_Date__c >= :startDate');
        }
        if (endDate != null) {
            conditions.add('GRN_Date__c <= :endDate');
        }
        if (warehouseId != null) {
            conditions.add('Invoice__r.Warehouse__c = :warehouseId');
        }

        if (!conditions.isEmpty()) {
            query += ' WHERE ' + String.join(conditions, ' AND ');
        }

        query += ' ORDER BY CreatedDate DESC LIMIT 50';
        return Database.query(query);
    }

    /**
     * @description Gets a single GRN with its line items.
     * @param grnId The GRN record Id.
     * @return GRNDetail wrapper containing header and line items.
     */
    @AuraEnabled
    public static GRNDetail getGRNById(Id grnId) {
        GRNDetail detail = new GRNDetail();

        detail.grn = [
            SELECT Id, Name, Status__c, GRN_Date__c, Invoice__c, Invoice__r.Name,
                   Invoice__r.Warehouse__c, Invoice__r.Warehouse__r.Name,
                   Account__c, Account__r.Name, Received_By__c, Notes__c,
                   Short_Qty__c, Damaged_Qty__c, Excess_Qty__c,
                   CreatedDate, LastModifiedDate
            FROM GRN__c
            WHERE Id = :grnId
            LIMIT 1
        ];

        if (detail.grn == null) {
            throw new AuraHandledException('GRN not found with Id: ' + grnId);
        }

        detail.lineItems = [
            SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Batch_No__c, Dispatched_Qty__c, Received_Qty__c, Short_Qty__c,
                   Damaged_Qty__c, Expiry_Date__c, Notes__c
            FROM GRN_Line__c
            WHERE GRN__c = :grnId
            ORDER BY Name ASC
        ];

        return detail;
    }

    /**
     * @description Creates a GRN header with line items from a JSON payload.
     * @param grnJson JSON string representing a GRNInput wrapper.
     * @return The created GRN__c record Id.
     */
    @AuraEnabled
    public static Id createGRN(String grnJson) {
        Savepoint sp = Database.setSavepoint();
        try {
            GRNInput input = (GRNInput) JSON.deserialize(grnJson, GRNInput.class);

            GRN__c grn = new GRN__c(
                Invoice__c = input.invoiceId,
                Account__c = input.accountId,
                GRN_Date__c = input.grnDate != null ? input.grnDate : Date.today(),
                Status__c = 'Pending',
                Received_By__c = input.receivedBy,
                Notes__c = input.notes
            );
            insert grn;

            if (input.lineItems != null && !input.lineItems.isEmpty()) {
                List<GRN_Line__c> grnLines = new List<GRN_Line__c>();
                for (GRNLineInput line : input.lineItems) {
                    grnLines.add(new GRN_Line__c(
                        GRN__c = grn.Id,
                        Product_Ext__c = line.productId,
                        Batch_No__c = line.batchNo,
                        Dispatched_Qty__c = line.dispatchedQty,
                        Received_Qty__c = line.receivedQty,
                        Short_Qty__c = line.shortQty,
                        Damaged_Qty__c = line.damagedQty,
                        Expiry_Date__c = line.expiryDate,
                        Notes__c = line.notes
                    ));
                }
                insert grnLines;
            }

            return grn.Id;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Updates the status of a GRN with valid transition checks.
     * @param grnId     The GRN record Id.
     * @param newStatus The target status value.
     */
    @AuraEnabled
    public static void updateGRNStatus(Id grnId, String newStatus) {
        GRN__c grn = [SELECT Id, Status__c FROM GRN__c WHERE Id = :grnId LIMIT 1];

        // Validate status transitions
        String currentStatus = grn.Status__c;
        if (!isValidTransition(currentStatus, newStatus)) {
            throw new AuraHandledException(
                'Invalid status transition from "' + currentStatus + '" to "' + newStatus + '".'
            );
        }

        grn.Status__c = newStatus;
        try {
            update grn;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets line items for a GRN.
     * @param grnId The GRN record Id.
     * @return List of GRN_Line__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<GRN_Line__c> getGRNLineItems(Id grnId) {
        return [
            SELECT Id, Name, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                   Batch_No__c, Dispatched_Qty__c, Received_Qty__c, Short_Qty__c,
                   Damaged_Qty__c, Expiry_Date__c, Notes__c
            FROM GRN_Line__c
            WHERE GRN__c = :grnId
            ORDER BY Name ASC
        ];
    }

    /**
     * @description Searches active products by name or SKU code for adding to a GRN.
     * @param searchTerm The search keyword (matched with LIKE).
     * @return List of matching Product_Extension__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Product_Extension__c> searchProducts(String searchTerm) {
        String query = 'SELECT Id, Name, SKU_Code__c FROM Product_Extension__c ' +
                       'WHERE Is_Active__c = true';

        if (String.isNotBlank(searchTerm)) {
            String searchWild = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' AND (Name LIKE :searchWild OR SKU_Code__c LIKE :searchWild)';
        }

        query += ' ORDER BY Name ASC LIMIT 50';
        return Database.query(query);
    }

    /**
     * @description Returns active warehouses for dropdown/picklist usage.
     * @return List of Warehouse__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Warehouse__c> getWarehouseOptions() {
        return [
            SELECT Id, Name, Warehouse_Code__c, Warehouse_Type__c
            FROM Warehouse__c
            WHERE Is_Active__c = true
            ORDER BY Name ASC
        ];
    }

    // ── Status Transition Validation ──────────────────────────────────────────

    private static Boolean isValidTransition(String fromStatus, String toStatus) {
        // Allowed transitions:
        // Pending  -> Received, Partial, Disputed
        // Partial  -> Received, Disputed
        // Disputed -> Pending (allow re-processing)
        Map<String, Set<String>> allowed = new Map<String, Set<String>>{
            'Pending'  => new Set<String>{ 'Received', 'Partial', 'Disputed' },
            'Partial'  => new Set<String>{ 'Received', 'Disputed' },
            'Disputed' => new Set<String>{ 'Pending' }
        };

        Set<String> validTargets = allowed.get(fromStatus);
        return validTargets != null && validTargets.contains(toStatus);
    }

    // ── Inner Classes ─────────────────────────────────────────────────────────

    public class GRNInput {
        public Id invoiceId;
        public Id accountId;
        public Date grnDate;
        public String receivedBy;
        public String notes;
        public List<GRNLineInput> lineItems;
    }

    public class GRNLineInput {
        public Id productId;
        public String batchNo;
        public Decimal dispatchedQty;
        public Decimal receivedQty;
        public Decimal shortQty;
        public Decimal damagedQty;
        public Date expiryDate;
        public String notes;
    }

    public class GRNDetail {
        @AuraEnabled public GRN__c grn;
        @AuraEnabled public List<GRN_Line__c> lineItems;
    }
}