/**
 * @description Trigger handler for Sales_Order__c. Manages the complete sales order
 *              lifecycle including default population, credit validation, duplicate
 *              detection, status transition enforcement, and downstream actions
 *              (invoice creation, credit release).
 *
 * Status Flow:
 *   Draft -> Submitted -> Approved -> Processing -> Dispatched -> Delivered
 *                      -> Rejected
 *   (Any non-terminal) -> Cancelled
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class OMS_SalesOrder_TriggerHandler extends TriggerHandler {

    /** Valid status transitions. Key = current status, Value = set of allowed next statuses. */
    private static final Map<String, Set<String>> VALID_TRANSITIONS = new Map<String, Set<String>>{
        'Draft'      => new Set<String>{ 'Submitted', 'Cancelled' },
        'Submitted'  => new Set<String>{ 'Approved', 'Rejected', 'Cancelled' },
        'Approved'   => new Set<String>{ 'Processing', 'Cancelled' },
        'Processing' => new Set<String>{ 'Dispatched', 'Cancelled' },
        'Dispatched' => new Set<String>{ 'Delivered', 'Cancelled' },
        'Rejected'   => new Set<String>{ 'Draft' },
        'Delivered'  => new Set<String>(),
        'Cancelled'  => new Set<String>()
    };

    // ── Before Insert ─────────────────────────────────────────────────────────

    /**
     * @description Sets default field values, validates credit limits, and
     *              checks for duplicate orders on new sales orders.
     */
    protected override void beforeInsert() {
        List<Sales_Order__c> newRecords = (List<Sales_Order__c>) Trigger.new;
        setDefaults(newRecords);
        stampServicingDistributor(newRecords);
        OMS_OrderValidation_Service.validateCreditLimit(newRecords);
        OMS_OrderValidation_Service.validateMinOrderValue(newRecords);
        OMS_OrderValidation_Service.checkDuplicateOrders(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    /**
     * @description Validates status transitions follow the defined state machine.
     *              Re-validates credit on value increases.
     */
    protected override void beforeUpdate() {
        List<Sales_Order__c> newRecords = (List<Sales_Order__c>) Trigger.new;
        Map<Id, Sales_Order__c> oldMap = (Map<Id, Sales_Order__c>) Trigger.oldMap;
        validateStatusTransitions(newRecords, oldMap);

        // Keep the servicing distributor in step if the order is re-pointed at another account.
        List<Sales_Order__c> accountChanged = new List<Sales_Order__c>();
        for (Sales_Order__c rec : newRecords) {
            if (rec.Account__c != oldMap.get(rec.Id).Account__c) { accountChanged.add(rec); }
        }
        if (!accountChanged.isEmpty()) { stampServicingDistributor(accountChanged); }

        // Validate must-sell compliance when submitting orders
        List<Sales_Order__c> submittedOrders = new List<Sales_Order__c>();
        for (Sales_Order__c rec : newRecords) {
            Sales_Order__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c == 'Submitted' && oldRec.Status__c != 'Submitted') {
                submittedOrders.add(rec);
            }
        }
        if (!submittedOrders.isEmpty()) {
            OMS_OrderValidation_Service.validateMustSellCompliance(submittedOrders);
            OMS_OrderValidation_Service.validateChannelCompliance(submittedOrders);
            OMS_OrderValidation_Service.validateCategoryCompliance(submittedOrders);
            reserveStockOnSubmit(submittedOrders);
        }

        // Re-validate credit limit if order value increased
        List<Sales_Order__c> valueIncreased = new List<Sales_Order__c>();
        for (Sales_Order__c rec : newRecords) {
            Sales_Order__c oldRec = oldMap.get(rec.Id);
            if (rec.Total_Amount__c != null && oldRec.Total_Amount__c != null &&
                rec.Total_Amount__c > oldRec.Total_Amount__c &&
                rec.Status__c != 'Cancelled' &&
                rec.Status__c != 'Rejected') {
                valueIncreased.add(rec);
            }
        }
        if (!valueIncreased.isEmpty()) {
            OMS_OrderValidation_Service.validateCreditLimit(valueIncreased);
        }
    }

    // ── After Update ──────────────────────────────────────────────────────────

    /**
     * @description Triggers downstream processes on status changes:
     *              - Approved: Generate invoices
     *              - Cancelled: Release held credit
     */
    protected override void afterUpdate() {
        List<Sales_Order__c> newRecords = (List<Sales_Order__c>) Trigger.new;
        Map<Id, Sales_Order__c> oldMap = (Map<Id, Sales_Order__c>) Trigger.oldMap;

        Set<Id> approvedOrderIds = new Set<Id>();
        Set<Id> cancelledOrderIds = new Set<Id>();
        Set<Id> deliveredOrderIds = new Set<Id>();

        for (Sales_Order__c rec : newRecords) {
            Sales_Order__c oldRec = oldMap.get(rec.Id);

            if (rec.Status__c != oldRec.Status__c) {
                if (rec.Status__c == 'Approved') {
                    approvedOrderIds.add(rec.Id);
                } else if (rec.Status__c == 'Cancelled') {
                    cancelledOrderIds.add(rec.Id);
                } else if (rec.Status__c == 'Delivered') {
                    deliveredOrderIds.add(rec.Id);
                }
            }
        }

        if (!approvedOrderIds.isEmpty()) {
            // SFA -> DMS bridge: an order for a retailer served by a distributor is supplied
            // from THAT DISTRIBUTOR's stock, not the company warehouse. Such orders are left
            // un-invoiced here; the distributor bills them from the DMS portal, which is what
            // moves their stock and posts the receivable. Warehouse-supplied orders (no
            // servicing distributor, or SECONDARY_STOCK_SOURCE=WAREHOUSE) keep today's path.
            Set<Id> warehouseOrderIds = new Set<Id>();
            for (Sales_Order__c so : [
                SELECT Id, Sold_From_Distributor__c FROM Sales_Order__c WHERE Id IN :approvedOrderIds
            ]) {
                if (so.Sold_From_Distributor__c == null) { warehouseOrderIds.add(so.Id); }
            }

            if (!warehouseOrderIds.isEmpty()) {
                // Validate stock availability before generating invoices
                Map<Id, List<String>> stockShortages = OMS_StockAvailability_Service.validateStockAvailability(warehouseOrderIds);
                Set<Id> stockAvailableOrders = new Set<Id>();
                for (Id orderId : warehouseOrderIds) {
                    if (stockShortages.get(orderId).isEmpty()) {
                        stockAvailableOrders.add(orderId);
                    }
                }
                if (!stockAvailableOrders.isEmpty()) {
                    OMS_InvoiceGeneration_Service.generateInvoices(stockAvailableOrders);
                }
            }

            // Update scheme budget usage for approved orders
            updateSchemeBudgetUsage(approvedOrderIds);
        }

        if (!cancelledOrderIds.isEmpty()) {
            releaseCreditHold(cancelledOrderIds);
            reverseSchemeBudgetUsage(cancelledOrderIds);
        }

        if (!deliveredOrderIds.isEmpty()) {
            releaseCreditHold(deliveredOrderIds);
        }

        // Update Last_Order_Date__c and Last_Order_Value__c on Account
        Set<Id> accountIdsToUpdate = new Set<Id>();
        for (Sales_Order__c rec : newRecords) {
            Sales_Order__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c != oldRec.Status__c && rec.Account__c != null
                && (rec.Status__c == 'Approved' || rec.Status__c == 'Delivered')) {
                accountIdsToUpdate.add(rec.Account__c);
            }
        }
        if (!accountIdsToUpdate.isEmpty()) {
            MDM_Account_TriggerHandler.updateLastOrderInfo(accountIdsToUpdate);
        }
    }

    /**
     * @description Reserves supply at submission by blocking any order that cannot be covered once
     *              other open orders' demand is set aside. Without this, orders only checked
     *              availability in isolation and secondary invoices stay Draft (never reserving or
     *              deducting), so the same units could be promised to unlimited orders. Release is
     *              implicit: a Cancelled/Rejected/Delivered order stops counting as open, and a
     *              billed order stops holding distributor stock, so holds free themselves.
     *
     *              Covers both supply sources — the company warehouse and, for orders stamped with
     *              a servicing distributor, that distributor's own stock. The shortage text names
     *              which source came up short.
     */
    private void reserveStockOnSubmit(List<Sales_Order__c> submittedOrders) {
        Set<Id> orderIds = new Set<Id>();
        for (Sales_Order__c so : submittedOrders) { orderIds.add(so.Id); }

        Map<Id, List<String>> shortages = OMS_StockAvailability_Service.validateForReservation(orderIds);
        for (Sales_Order__c so : submittedOrders) {
            List<String> sh = shortages.get(so.Id);
            if (sh == null || sh.isEmpty()) { continue; }

            // Only warehouse-supplied orders are blocked. A distributor-supplied order is
            // deliberately allowed through on shortfall — the agreed model is "approve the
            // order, leave it unbilled", so the rep can still book and the distributor
            // replenishes before billing. Hard-blocking here would stop field sales every
            // time a distributor happened to be out of stock. The demand is not lost: it
            // now counts against that distributor's available-to-promise, and their portal
            // inventory shows the committed quantity so they can see what to replenish.
            if (so.Sold_From_Distributor__c != null) {
                System.debug(LoggingLevel.WARN, 'Order ' + so.Id
                    + ' exceeds the servicing distributor\'s uncommitted stock: '
                    + String.join(sh, '; ') + ' — allowed through, awaiting billing.');
                continue;
            }

            so.addError('Cannot submit — available stock cannot cover this order after stock '
                + 'already committed to other open orders: ' + String.join(sh, '; '));
        }
    }

    // ── Private helper methods ────────────────────────────────────────────────

    /**
     * @description SFA -> DMS bridge. Resolves the distributor that services this order's
     *              retailer and stamps it on Sold_From_Distributor__c, which is what tells
     *              the rest of the system the sale is supplied from distributor stock rather
     *              than the company warehouse.
     *
     *              The link is the account's Parent Account (the single authoritative
     *              retailer -> servicing-distributor link), and the parent must actually be a
     *              Distributor / Super Stockist — a parent that is a chain HQ or a corporate
     *              rollup is not a supplier. Leaves the field null for direct distribution,
     *              which preserves the existing warehouse behaviour.
     */
    private void stampServicingDistributor(List<Sales_Order__c> records) {
        if (!DMS_Config.isDistributorSourced()) { return; }

        Set<Id> accountIds = new Set<Id>();
        for (Sales_Order__c rec : records) {
            if (rec.Account__c != null) { accountIds.add(rec.Account__c); }
        }
        if (accountIds.isEmpty()) { return; }

        // Retailer -> parent, then keep only parents that are genuine supplying accounts.
        Map<Id, Id> parentByAccount = new Map<Id, Id>();
        Set<Id> parentIds = new Set<Id>();
        for (Account a : [SELECT Id, ParentId FROM Account WHERE Id IN :accountIds AND ParentId != null]) {
            parentByAccount.put(a.Id, a.ParentId);
            parentIds.add(a.ParentId);
        }
        if (parentIds.isEmpty()) { return; }

        Set<Id> supplierIds = new Set<Id>();
        for (Account p : [
            SELECT Id FROM Account
            WHERE Id IN :parentIds
              AND RecordType.DeveloperName IN ('Distributor', 'Super_Stockist')
        ]) {
            supplierIds.add(p.Id);
        }

        for (Sales_Order__c rec : records) {
            Id parentId = parentByAccount.get(rec.Account__c);
            rec.Sold_From_Distributor__c =
                (parentId != null && supplierIds.contains(parentId)) ? parentId : null;
        }
    }

    /**
     * @description Populates default values on new sales order records.
     * @param records The new records to initialise.
     */
    private void setDefaults(List<Sales_Order__c> records) {
        for (Sales_Order__c rec : records) {
            // Default status
            if (String.isBlank(rec.Status__c)) {
                rec.Status__c = 'Draft';
            }

            // Default order date
            if (rec.Order_Date__c == null) {
                rec.Order_Date__c = Date.today();
            }

            // Default sales rep and salesperson to current user
            if (rec.Sales_Rep__c == null) {
                rec.Sales_Rep__c = UserInfo.getUserId();
            }
            if (rec.Salesperson__c == null) {
                rec.Salesperson__c = UserInfo.getUserId();
            }

            // Initialise amounts
            if (rec.Total_Amount__c == null) {
                rec.Total_Amount__c = 0;
            }
            if (rec.Total_Tax__c == null) {
                rec.Total_Tax__c = 0;
            }
            if (rec.Discount_Amount__c == null) {
                rec.Discount_Amount__c = 0;
            }
        }
    }

    /**
     * @description Enforces the sales order status state machine. Only transitions
     *              defined in VALID_TRANSITIONS are permitted.
     * @param newRecords The updated records.
     * @param oldMap     Map of previous record values.
     */
    private void validateStatusTransitions(
        List<Sales_Order__c> newRecords,
        Map<Id, Sales_Order__c> oldMap
    ) {
        for (Sales_Order__c rec : newRecords) {
            Sales_Order__c oldRec = oldMap.get(rec.Id);

            if (rec.Status__c == oldRec.Status__c) {
                continue;
            }

            String currentStatus = oldRec.Status__c;
            String newStatus = rec.Status__c;

            if (!VALID_TRANSITIONS.containsKey(currentStatus)) {
                rec.Status__c.addError(
                    'Unknown current status: ' + currentStatus + '. Cannot determine valid transitions.'
                );
                continue;
            }

            Set<String> allowedNext = VALID_TRANSITIONS.get(currentStatus);
            if (!allowedNext.contains(newStatus)) {
                rec.Status__c.addError(
                    'Invalid status transition from \'' + currentStatus +
                    '\' to \'' + newStatus + '\'. Allowed transitions: ' +
                    String.join(new List<String>(allowedNext), ', ') + '.'
                );
            }
        }
    }

    /**
     * @description Releases credit hold for cancelled orders by updating the
     *              Account's credit utilisation.
     * @param cancelledOrderIds Set of cancelled Sales_Order__c IDs.
     */
    private void releaseCreditHold(Set<Id> cancelledOrderIds) {
        List<Sales_Order__c> cancelledOrders = [
            SELECT Id, Account__c, Total_Amount__c
            FROM Sales_Order__c
            WHERE Id IN :cancelledOrderIds
              AND Account__c != null
              AND Total_Amount__c != null
        ];

        // Aggregate released amounts per account
        Map<Id, Decimal> releaseByAccount = new Map<Id, Decimal>();
        for (Sales_Order__c order : cancelledOrders) {
            Decimal current = releaseByAccount.containsKey(order.Account__c)
                ? releaseByAccount.get(order.Account__c) : 0;
            releaseByAccount.put(order.Account__c, current + order.Total_Amount__c);
        }

        if (releaseByAccount.isEmpty()) {
            return;
        }

        // Update account credit utilisation
        List<Account> accountsToUpdate = [
            SELECT Id, Credit_Utilized__c
            FROM Account
            WHERE Id IN :releaseByAccount.keySet()
        ];

        for (Account acct : accountsToUpdate) {
            Decimal releaseAmount = releaseByAccount.get(acct.Id);
            Decimal currentUtilised = acct.Credit_Utilized__c != null
                ? acct.Credit_Utilized__c : 0;
            acct.Credit_Utilized__c = Math.max(0, currentUtilised - releaseAmount);
        }

        if (!accountsToUpdate.isEmpty()) {
            update accountsToUpdate;
        }
    }

    /**
     * @description Updates scheme budget usage when orders are approved.
     *              Aggregates scheme discounts from line items and increments
     *              the Budget_Used__c on each referenced Scheme__c.
     * @param approvedOrderIds Set of approved Sales_Order__c IDs.
     */
    private void updateSchemeBudgetUsage(Set<Id> approvedOrderIds) {
        // Aggregate scheme discounts by scheme ID
        Map<Id, Decimal> budgetByScheme = new Map<Id, Decimal>();
        for (Order_Line_Item__c li : [
            SELECT Id, Scheme__c, Scheme_Discount__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :approvedOrderIds
              AND Scheme__c != null
              AND Scheme_Discount__c != null
              AND Scheme_Discount__c > 0
        ]) {
            Decimal current = budgetByScheme.containsKey(li.Scheme__c)
                ? budgetByScheme.get(li.Scheme__c) : 0;
            budgetByScheme.put(li.Scheme__c, current + li.Scheme_Discount__c);
        }

        if (budgetByScheme.isEmpty()) {
            return;
        }

        List<Scheme__c> schemesToUpdate = [
            SELECT Id, Budget_Used__c
            FROM Scheme__c
            WHERE Id IN :budgetByScheme.keySet()
        ];

        for (Scheme__c scheme : schemesToUpdate) {
            Decimal currentUsed = scheme.Budget_Used__c != null ? scheme.Budget_Used__c : 0;
            scheme.Budget_Used__c = currentUsed + budgetByScheme.get(scheme.Id);
        }

        if (!schemesToUpdate.isEmpty()) {
            update schemesToUpdate;
        }
    }

    /**
     * @description Reverses scheme budget usage when orders are cancelled.
     *              Decrements Budget_Used__c on referenced schemes.
     * @param cancelledOrderIds Set of cancelled Sales_Order__c IDs.
     */
    private void reverseSchemeBudgetUsage(Set<Id> cancelledOrderIds) {
        Map<Id, Decimal> budgetByScheme = new Map<Id, Decimal>();
        for (Order_Line_Item__c li : [
            SELECT Id, Scheme__c, Scheme_Discount__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :cancelledOrderIds
              AND Scheme__c != null
              AND Scheme_Discount__c != null
              AND Scheme_Discount__c > 0
        ]) {
            Decimal current = budgetByScheme.containsKey(li.Scheme__c)
                ? budgetByScheme.get(li.Scheme__c) : 0;
            budgetByScheme.put(li.Scheme__c, current + li.Scheme_Discount__c);
        }

        if (budgetByScheme.isEmpty()) {
            return;
        }

        List<Scheme__c> schemesToUpdate = [
            SELECT Id, Budget_Used__c
            FROM Scheme__c
            WHERE Id IN :budgetByScheme.keySet()
        ];

        for (Scheme__c scheme : schemesToUpdate) {
            Decimal currentUsed = scheme.Budget_Used__c != null ? scheme.Budget_Used__c : 0;
            scheme.Budget_Used__c = Math.max(0, currentUsed - budgetByScheme.get(scheme.Id));
        }

        if (!schemesToUpdate.isEmpty()) {
            update schemesToUpdate;
        }
    }
}