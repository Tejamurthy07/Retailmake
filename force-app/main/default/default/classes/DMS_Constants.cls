/**
 * @description Central constants for the Distributor Management System (DMS).
 *              Single source of truth for feature-toggle codes, picklist API
 *              values, status values, and Account record-type developer names
 *              shared across DMS services, trigger handlers, and controllers.
 * @author  SFA Development Team
 * @date    2024
 */
public class DMS_Constants {

    // ---------------------------------------------------------------------
    // Feature toggle codes (Feature_Toggle__mdt.Feature_Code__c)
    // ---------------------------------------------------------------------
    public static final String TOGGLE_MASTER              = 'DMS-001';
    public static final String TOGGLE_STOCK_ACTIVITIES    = 'DMS-002';
    public static final String TOGGLE_PRIMARY_FULFILLMENT = 'DMS-003';
    public static final String TOGGLE_NORMS_REPLENISH     = 'DMS-004';
    public static final String TOGGLE_FEFO_EXPIRY         = 'DMS-005';
    public static final String TOGGLE_SECONDARY_BILLING   = 'DMS-006';
    public static final String TOGGLE_SCHEME_CLAIM        = 'DMS-007';
    public static final String TOGGLE_LEDGER_AGING        = 'DMS-008';
    public static final String TOGGLE_CREDIT_ENFORCEMENT  = 'DMS-009';
    public static final String TOGGLE_PORTAL              = 'DMS-010';
    public static final String TOGGLE_RETURNS            = 'DMS-011';
    public static final String TOGGLE_P2_FULFILLMENT     = 'DMS-012';
    public static final String TOGGLE_INVOICE_LEDGER     = 'DMS-013';
    // Legacy Indent__c fulfilment. OFF by default: the primary order is now
    // Primary_Order__c (see DMS_PrimaryOrderFulfillment_Service). Only enable for
    // an org still transacting on the deprecated Indent__c object, to avoid
    // double-fulfilment. Indent history/read/GRN paths remain unaffected.
    public static final String TOGGLE_LEGACY_INDENT_FULFILLMENT = 'DMS-014';

    /**
     * Demo/sandbox helpers that fabricate transactional data (e.g. a mock primary
     * dispatch so a GRN can be practised). Ships OFF and must stay off in
     * production: a distributor who can conjure their own inbound dispatch can
     * create stock out of nothing.
     */
    public static final String TOGGLE_DEMO_TOOLS = 'DMS-015';

    // ---------------------------------------------------------------------
    // Account record type developer names (distributor entity)
    // ---------------------------------------------------------------------
    public static final String RT_DISTRIBUTOR    = 'Distributor';
    public static final String RT_SUPER_STOCKIST = 'Super_Stockist';
    public static final String RT_RETAILER       = 'Retailer';

    // ---------------------------------------------------------------------
    // Indent__c.Indent_Type__c (distribution tier of an indent)
    // ---------------------------------------------------------------------
    public static final String INDENT_TYPE_P1 = 'P1';
    public static final String INDENT_TYPE_P2 = 'P2';

    // ---------------------------------------------------------------------
    // Stock_Adjustment__c.Location_Type__c
    // ---------------------------------------------------------------------
    public static final String LOCATION_WAREHOUSE   = 'Warehouse';
    public static final String LOCATION_DISTRIBUTOR = 'Distributor';

    // ---------------------------------------------------------------------
    // Stock_Transaction__c.Direction__c (restricted picklist: In / Out)
    // ---------------------------------------------------------------------
    public static final String DIRECTION_IN  = 'In';
    public static final String DIRECTION_OUT = 'Out';

    // ---------------------------------------------------------------------
    // Stock_Transaction__c.Transaction_Type__c
    // ---------------------------------------------------------------------
    public static final String TXN_INBOUND_GRN        = 'Inbound_GRN';
    public static final String TXN_OUTBOUND_DISPATCH  = 'Outbound_Dispatch';
    public static final String TXN_ADJUSTMENT_ADD     = 'Adjustment_Add';
    public static final String TXN_ADJUSTMENT_DEDUCT  = 'Adjustment_Deduct';

    // ---------------------------------------------------------------------
    // Stock_Adjustment__c.Status__c
    // ---------------------------------------------------------------------
    public static final String ADJ_APPROVED = 'Approved';

    // ---------------------------------------------------------------------
    // Scheme_Accrual__c.Status__c
    // ---------------------------------------------------------------------
    public static final String ACCRUAL_OPEN     = 'Open';
    public static final String ACCRUAL_CLAIMED  = 'Claimed';
    public static final String ACCRUAL_SETTLED  = 'Settled';
    public static final String ACCRUAL_REVERSED = 'Reversed';

    // ---------------------------------------------------------------------
    // Invoice__c.Order_Type__c / Return_Order__c.Return_Type__c
    // ---------------------------------------------------------------------
    public static final String ORDER_TYPE_PRIMARY   = 'Primary';
    public static final String ORDER_TYPE_P2        = 'P2';
    public static final String ORDER_TYPE_SECONDARY = 'Secondary';
    public static final String RETURN_TYPE_PRIMARY   = 'Primary';
    public static final String RETURN_TYPE_SECONDARY = 'Secondary';

    // ---------------------------------------------------------------------
    // Indent__c.Status__c state machine
    // ---------------------------------------------------------------------
    public static final String INDENT_DRAFT      = 'Draft';
    public static final String INDENT_SUBMITTED  = 'Submitted';
    public static final String INDENT_APPROVED   = 'Approved';
    public static final String INDENT_DISPATCHED = 'Dispatched';
    public static final String INDENT_RECEIVED   = 'Received';
    public static final String INDENT_CLOSED     = 'Closed';
    public static final String INDENT_REJECTED   = 'Rejected';
    public static final String INDENT_CANCELLED  = 'Cancelled';

    // Utility classes should not be instantiated.
    private DMS_Constants() {}
}