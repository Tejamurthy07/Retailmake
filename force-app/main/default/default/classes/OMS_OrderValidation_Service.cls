/**
 * @description Service class providing bulk-safe validation methods for Sales Orders.
 *              All methods add errors directly to the SObject records, following the
 *              Salesforce trigger-pattern convention.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class OMS_OrderValidation_Service {

    /**
     * @description Validates that each sales order's total amount does not exceed
     *              the associated account's available credit limit. Available credit
     *              is calculated as Credit_Limit__c minus Credit_Utilized__c.
     *
     * @param orders The list of Sales_Order__c records to validate.
     */
    public static void validateCreditLimit(List<Sales_Order__c> orders) {
        // Collect account IDs
        Set<Id> accountIds = new Set<Id>();
        for (Sales_Order__c order : orders) {
            if (order.Account__c != null) {
                accountIds.add(order.Account__c);
            }
        }

        if (accountIds.isEmpty()) {
            return;
        }

        // Query account credit details
        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Name, Credit_Limit__c, Credit_Utilized__c
            FROM Account
            WHERE Id IN :accountIds
        ]);

        for (Sales_Order__c order : orders) {
            if (order.Account__c == null || order.Total_Amount__c == null) {
                continue;
            }

            Account acct = accountMap.get(order.Account__c);
            if (acct == null) {
                continue;
            }

            Decimal creditLimit = acct.Credit_Limit__c != null ? acct.Credit_Limit__c : 0;
            Decimal creditUtilized = acct.Credit_Utilized__c != null ? acct.Credit_Utilized__c : 0;
            Decimal availableCredit = creditLimit - creditUtilized;

            if (order.Total_Amount__c > availableCredit) {
                order.addError(
                    'Order amount (' + order.Total_Amount__c.setScale(2) +
                    ') exceeds available credit limit (' + availableCredit.setScale(2) +
                    ') for account ' + acct.Name + '. ' +
                    'Credit Limit: ' + creditLimit.setScale(2) +
                    ', Credit Utilized: ' + creditUtilized.setScale(2) + '.'
                );
            }
        }
    }

    /**
     * @description Validates that each sales order meets the minimum order value
     *              threshold. The threshold is sourced from the SFA_Settings__c
     *              custom setting or defaults to a sensible value.
     *
     * @param orders The list of Sales_Order__c records to validate.
     */
    public static void validateMinOrderValue(List<Sales_Order__c> orders) {
        // Retrieve the configurable minimum order value
        Decimal minOrderValue = getMinOrderValue();

        for (Sales_Order__c order : orders) {
            if (order.Total_Amount__c != null && order.Total_Amount__c < minOrderValue &&
                order.Total_Amount__c > 0) {
                order.addError(
                    'Order total amount (' + order.Total_Amount__c.setScale(2) +
                    ') is below the minimum order value of ' +
                    minOrderValue.setScale(2) + '.'
                );
            }
        }
    }

    /**
     * @description Checks for duplicate orders based on the same account, order date,
     *              and similar total amount within a configurable time window. Prevents
     *              accidental double-entry by field sales reps.
     *
     * @param orders The list of Sales_Order__c records to check.
     */
    public static void checkDuplicateOrders(List<Sales_Order__c> orders) {
        Set<Id> accountIds = new Set<Id>();
        Set<Date> orderDates = new Set<Date>();

        for (Sales_Order__c order : orders) {
            if (order.Account__c != null) {
                accountIds.add(order.Account__c);
            }
            if (order.Order_Date__c != null) {
                orderDates.add(order.Order_Date__c);
            }
        }

        if (accountIds.isEmpty() || orderDates.isEmpty()) {
            return;
        }

        // Query recent orders for the same accounts on the same dates
        Map<String, Sales_Order__c> existingOrders = new Map<String, Sales_Order__c>();
        for (Sales_Order__c existing : [
            SELECT Id, Account__c, Order_Date__c, Total_Amount__c, Sales_Rep__c
            FROM Sales_Order__c
            WHERE Account__c IN :accountIds
              AND Order_Date__c IN :orderDates
              AND Status__c NOT IN ('Cancelled', 'Rejected')
            ORDER BY CreatedDate DESC
        ]) {
            String key = buildDuplicateKey(
                existing.Account__c,
                existing.Order_Date__c,
                existing.Sales_Rep__c
            );
            existingOrders.put(key, existing);
        }

        // Check within the incoming batch as well
        Map<String, Sales_Order__c> batchKeys = new Map<String, Sales_Order__c>();

        for (Sales_Order__c order : orders) {
            if (order.Account__c == null || order.Order_Date__c == null) {
                continue;
            }

            String key = buildDuplicateKey(
                order.Account__c,
                order.Order_Date__c,
                order.Sales_Rep__c
            );

            // Check against existing orders in the database
            if (existingOrders.containsKey(key)) {
                Sales_Order__c existing = existingOrders.get(key);
                // Only flag if amounts are similar (within 1% tolerance)
                if (order.Total_Amount__c != null && existing.Total_Amount__c != null) {
                    Decimal difference = Math.abs(order.Total_Amount__c - existing.Total_Amount__c);
                    Decimal tolerance = existing.Total_Amount__c * 0.01;
                    if (difference <= tolerance) {
                        order.addError(
                            'Potential duplicate order detected. An order with similar ' +
                            'details already exists (Order ID: ' + existing.Id +
                            ') for the same account, date, and sales rep.'
                        );
                        continue;
                    }
                }
            }

            // Check within the batch
            if (batchKeys.containsKey(key)) {
                order.addError(
                    'Duplicate order found within the same batch for account ' +
                    order.Account__c + ' on ' + String.valueOf(order.Order_Date__c) + '.'
                );
            } else {
                batchKeys.put(key, order);
            }
        }
    }

    /**
     * @description Validates that each sales order includes all mandatory must-sell
     *              products configured for the order's territory, channel, and
     *              customer type. Adds a warning-level error to orders missing
     *              required products when the order transitions to 'Submitted'.
     *
     * @param orders The list of Sales_Order__c records to validate.
     */
    public static void validateMustSellCompliance(List<Sales_Order__c> orders) {
        // Collect account/territory/channel info from orders
        Set<Id> orderIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        Set<Id> territoryIds = new Set<Id>();
        Set<String> channels = new Set<String>();

        for (Sales_Order__c order : orders) {
            orderIds.add(order.Id);
            if (order.Account__c != null) accountIds.add(order.Account__c);
            if (order.Territory__c != null) territoryIds.add(order.Territory__c);
            // MDM-003: Use Trade_Channel__c for must-sell channel matching
            String tradeChannel = (BPM_FeatureToggle_Util.isEnabled('MDM-003') && String.isNotBlank(order.Trade_Channel__c))
                ? order.Trade_Channel__c : order.Channel__c;
            if (String.isNotBlank(tradeChannel)) channels.add(tradeChannel);
        }

        if (orderIds.isEmpty()) return;

        // Query account details for customer type (outlet type)
        Map<Id, Account> accountMap = new Map<Id, Account>();
        if (!accountIds.isEmpty()) {
            accountMap = new Map<Id, Account>([
                SELECT Id, Outlet_Type__c
                FROM Account
                WHERE Id IN :accountIds
            ]);
        }

        // Query active must-sell configurations matching the order dimensions
        Date today = Date.today();
        List<Must_Sell_Config__c> configs = [
            SELECT Id, Product_Ext__c, Product_Ext__r.Name, Territory__c,
                   Channel__c, Customer_Type__c, Classification__c
            FROM Must_Sell_Config__c
            WHERE Is_Active__c = true
              AND Classification__c = 'Must Sell'
              AND (Start_Date__c = null OR Start_Date__c <= :today)
              AND (End_Date__c = null OR End_Date__c >= :today)
              AND (Territory__c IN :territoryIds OR Territory__c = null)
              AND (Channel__c IN :channels OR Channel__c = null)
        ];

        if (configs.isEmpty()) return;

        // Query order line items to see which products are already in each order
        Map<Id, Set<Id>> productsByOrder = new Map<Id, Set<Id>>();
        for (Order_Line_Item__c li : [
            SELECT Sales_Order__c, Product_Ext__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :orderIds
              AND Product_Ext__c != null
        ]) {
            if (!productsByOrder.containsKey(li.Sales_Order__c)) {
                productsByOrder.put(li.Sales_Order__c, new Set<Id>());
            }
            productsByOrder.get(li.Sales_Order__c).add(li.Product_Ext__c);
        }

        // Validate each order against applicable must-sell configs
        for (Sales_Order__c order : orders) {
            Set<Id> orderedProducts = productsByOrder.containsKey(order.Id)
                ? productsByOrder.get(order.Id) : new Set<Id>();

            Account acct = accountMap.get(order.Account__c);
            String customerType = (acct != null && acct.Outlet_Type__c != null) ? acct.Outlet_Type__c : '';

            List<String> missingProducts = new List<String>();

            for (Must_Sell_Config__c config : configs) {
                // Match territory
                if (config.Territory__c != null && config.Territory__c != order.Territory__c) {
                    continue;
                }
                // Match channel — use Trade_Channel__c when MDM-003 enabled
                String orderTradeChannel = (BPM_FeatureToggle_Util.isEnabled('MDM-003') && String.isNotBlank(order.Trade_Channel__c))
                    ? order.Trade_Channel__c : order.Channel__c;
                if (String.isNotBlank(config.Channel__c) && config.Channel__c != orderTradeChannel) {
                    continue;
                }
                // Match customer type
                if (String.isNotBlank(config.Customer_Type__c)
                    && config.Customer_Type__c != customerType) {
                    continue;
                }

                // Check if product is in the order
                if (!orderedProducts.contains(config.Product_Ext__c)) {
                    missingProducts.add(config.Product_Ext__r.Name);
                }
            }

            if (!missingProducts.isEmpty()) {
                order.addError(
                    'Must-sell products missing from order: ' +
                    String.join(missingProducts, ', ') +
                    '. Please add these products before submitting.'
                );
            }
        }
    }

    // ── Channel Compliance (MDM-003) ────────────────────────────────────────

    public static void validateChannelCompliance(List<Sales_Order__c> orders) {
        if (!BPM_FeatureToggle_Util.isEnabled('MDM-003')) return;

        Set<Id> orderIds = new Set<Id>();
        Map<Id, String> orderTradeChannelMap = new Map<Id, String>();

        for (Sales_Order__c order : orders) {
            if (String.isNotBlank(order.Trade_Channel__c)) {
                orderIds.add(order.Id);
                orderTradeChannelMap.put(order.Id, order.Trade_Channel__c);
            }
        }

        if (orderIds.isEmpty()) return;

        Map<Id, List<Product_Extension__c>> productsByOrder = new Map<Id, List<Product_Extension__c>>();
        for (Order_Line_Item__c li : [
            SELECT Sales_Order__c, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.Channels__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :orderIds AND Product_Ext__c != null
        ]) {
            if (!productsByOrder.containsKey(li.Sales_Order__c)) {
                productsByOrder.put(li.Sales_Order__c, new List<Product_Extension__c>());
            }
            productsByOrder.get(li.Sales_Order__c).add(
                new Product_Extension__c(
                    Id = li.Product_Ext__c,
                    Name = li.Product_Ext__r.Name,
                    Channels__c = li.Product_Ext__r.Channels__c
                )
            );
        }

        for (Sales_Order__c order : orders) {
            String tradeChannel = orderTradeChannelMap.get(order.Id);
            List<Product_Extension__c> prods = productsByOrder.get(order.Id);
            if (prods == null || String.isBlank(tradeChannel)) continue;

            List<String> blocked = new List<String>();
            for (Product_Extension__c p : prods) {
                if (!MDM_ChannelMapping_Service.isProductInChannel(p, tradeChannel)) {
                    blocked.add(p.Name);
                }
            }
            if (!blocked.isEmpty()) {
                order.addError('Products not available in channel ' + tradeChannel + ': ' + String.join(blocked, ', '));
            }
        }
    }

    // ── Category Compliance (MDM-004) ────────────────────────────────────────

    public static void validateCategoryCompliance(List<Sales_Order__c> orders) {
        if (!BPM_FeatureToggle_Util.isEnabled('MDM-004')) return;

        Set<Id> orderIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        Map<Id, Id> orderAccountMap = new Map<Id, Id>();

        for (Sales_Order__c order : orders) {
            if (order.Account__c != null) {
                orderIds.add(order.Id);
                accountIds.add(order.Account__c);
                orderAccountMap.put(order.Id, order.Account__c);
            }
        }

        if (orderIds.isEmpty()) return;

        Map<Id, Set<Id>> acctCatMap = MDM_CategoryMapping_Service.getAccountCategoryIdsMap(accountIds);

        Map<Id, List<Product_Extension__c>> productsByOrder = new Map<Id, List<Product_Extension__c>>();
        for (Order_Line_Item__c li : [
            SELECT Sales_Order__c, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.Product_Category__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :orderIds AND Product_Ext__c != null
        ]) {
            if (!productsByOrder.containsKey(li.Sales_Order__c)) {
                productsByOrder.put(li.Sales_Order__c, new List<Product_Extension__c>());
            }
            productsByOrder.get(li.Sales_Order__c).add(
                new Product_Extension__c(
                    Id = li.Product_Ext__c,
                    Name = li.Product_Ext__r.Name,
                    Product_Category__c = li.Product_Ext__r.Product_Category__c
                )
            );
        }

        for (Sales_Order__c order : orders) {
            Id acctId = orderAccountMap.get(order.Id);
            Set<Id> catIds = acctCatMap.get(acctId);
            if (catIds == null || catIds.isEmpty()) continue;

            Set<Id> expandedIds = MDM_CategoryMapping_Service.expandCategoryHierarchy(catIds);
            List<Product_Extension__c> prods = productsByOrder.get(order.Id);
            if (prods == null) continue;

            List<String> blocked = new List<String>();
            for (Product_Extension__c p : prods) {
                if (p.Product_Category__c != null && !expandedIds.contains(p.Product_Category__c)) {
                    blocked.add(p.Name);
                }
            }
            if (!blocked.isEmpty()) {
                order.addError('Products not in customer\'s assigned categories: ' + String.join(blocked, ', '));
            }
        }
    }

    // ── Scheme per-customer usage cap (hard enforcement) ──────────────────────

    /**
     * @description Hard-enforces the per-customer scheme usage cap. Blocks any
     *              order line that applies a scheme the customer has already
     *              availed Max_Usage_Per_Customer__c times. This backstops the
     *              soft filtering done when schemes are OFFERED
     *              (SPM_SchemeEngine_Service / OrderEntryController) so a
     *              maxed-out scheme can never actually be saved onto an order via
     *              a stale UI cache, a re-edited draft, the REST API, a Flow, or
     *              the data loader.
     *
     *              Usage counts DISTINCT non-cancelled orders the scheme was
     *              applied to, EXCLUDING the orders currently being saved — so
     *              re-editing an order that already carries the scheme does not
     *              self-block, and several lines of the same scheme within one
     *              order count as a single use. When one customer places multiple
     *              NEW orders in the same DML, each distinct new order consumes one
     *              use and only as many as the remaining headroom are allowed.
     *
     * @param lineItems The Order_Line_Item__c records being inserted/updated.
     */
    public static void validateSchemeUsageCap(List<Order_Line_Item__c> lineItems) {
        if (lineItems == null || lineItems.isEmpty()) {
            return;
        }

        // Collect candidate schemes and the in-flight orders that reference them.
        Set<Id> schemeIds = new Set<Id>();
        Set<Id> orderIds = new Set<Id>();
        for (Order_Line_Item__c li : lineItems) {
            Id schemeId = appliedSchemeId(li);
            if (schemeId != null && li.Sales_Order__c != null) {
                schemeIds.add(schemeId);
                orderIds.add(li.Sales_Order__c);
            }
        }
        if (schemeIds.isEmpty()) {
            return;
        }

        // Only schemes that actually have a per-customer cap can block anything.
        Map<Id, Scheme__c> cappedSchemes = new Map<Id, Scheme__c>([
            SELECT Id, Name, Max_Usage_Per_Customer__c
            FROM Scheme__c
            WHERE Id IN :schemeIds
              AND Max_Usage_Per_Customer__c != null
              AND Max_Usage_Per_Customer__c > 0
        ]);
        if (cappedSchemes.isEmpty()) {
            return;
        }

        // Resolve each in-flight order's customer (Account). In before-insert the
        // line carries Sales_Order__c but not the account, so we query it.
        Map<Id, Id> accountByOrder = new Map<Id, Id>();
        for (Sales_Order__c so : [
            SELECT Id, Account__c FROM Sales_Order__c WHERE Id IN :orderIds
        ]) {
            accountByOrder.put(so.Id, so.Account__c);
        }

        Set<Id> accountIds = new Set<Id>(accountByOrder.values());
        accountIds.remove(null);
        if (accountIds.isEmpty()) {
            return;
        }

        // Prior usage per (account, scheme), read from the authoritative
        // Scheme_Usage__c ledger, EXCLUDING the orders being saved now (so an
        // order does not count against its own cap). Counted per account.
        Map<String, Integer> priorUsage = new Map<String, Integer>();
        for (Id acctId : accountIds) {
            Map<Id, Integer> perScheme = SPM_SchemeUsage_Service.getUsageCounts(
                acctId, cappedSchemes.keySet(), orderIds
            );
            for (Id sid : perScheme.keySet()) {
                priorUsage.put(usageKey(acctId, sid), perScheme.get(sid));
            }
        }

        // Group the NEW orders in this DML by (account, scheme). Each distinct new
        // order consumes one prospective use of the scheme.
        Map<String, Id> schemeByPair = new Map<String, Id>();
        Map<String, Set<Id>> newOrdersByPair = new Map<String, Set<Id>>();
        for (Order_Line_Item__c li : lineItems) {
            Id schemeId = appliedSchemeId(li);
            if (schemeId == null || li.Sales_Order__c == null
                || !cappedSchemes.containsKey(schemeId)) {
                continue;
            }
            Id acctId = accountByOrder.get(li.Sales_Order__c);
            if (acctId == null) {
                continue;
            }
            String pairKey = usageKey(acctId, schemeId);
            schemeByPair.put(pairKey, schemeId);
            if (!newOrdersByPair.containsKey(pairKey)) {
                newOrdersByPair.put(pairKey, new Set<Id>());
            }
            newOrdersByPair.get(pairKey).add(li.Sales_Order__c);
        }

        // For each pair decide which new orders exceed the cap. The first
        // `headroom` orders (sorted for determinism) are allowed; the rest are
        // blocked.
        Map<String, Set<Id>> blockedOrdersByPair = new Map<String, Set<Id>>();
        for (String pairKey : newOrdersByPair.keySet()) {
            Scheme__c scheme = cappedSchemes.get(schemeByPair.get(pairKey));
            Integer cap = scheme.Max_Usage_Per_Customer__c.intValue();
            Integer prior = priorUsage.containsKey(pairKey) ? priorUsage.get(pairKey) : 0;
            Integer headroom = cap - prior;

            List<Id> newOrders = new List<Id>(newOrdersByPair.get(pairKey));
            newOrders.sort();

            Set<Id> blocked = new Set<Id>();
            for (Integer i = 0; i < newOrders.size(); i++) {
                if (i >= headroom) {
                    blocked.add(newOrders[i]);
                }
            }
            if (!blocked.isEmpty()) {
                blockedOrdersByPair.put(pairKey, blocked);
            }
        }
        if (blockedOrdersByPair.isEmpty()) {
            return;
        }

        // Add the error to every offending line.
        for (Order_Line_Item__c li : lineItems) {
            Id schemeId = appliedSchemeId(li);
            if (schemeId == null || li.Sales_Order__c == null
                || !cappedSchemes.containsKey(schemeId)) {
                continue;
            }
            Id acctId = accountByOrder.get(li.Sales_Order__c);
            if (acctId == null) {
                continue;
            }
            String pairKey = usageKey(acctId, schemeId);
            Set<Id> blocked = blockedOrdersByPair.get(pairKey);
            if (blocked != null && blocked.contains(li.Sales_Order__c)) {
                Scheme__c scheme = cappedSchemes.get(schemeId);
                li.addError(
                    'Scheme "' + scheme.Name + '" cannot be applied: this customer ' +
                    'has already reached the maximum usage limit of ' +
                    scheme.Max_Usage_Per_Customer__c.setScale(0) +
                    ' time(s) for this scheme.'
                );
            }
        }
    }

    /**
     * @description Returns the scheme Id an order line is applying — prefers the
     *              usage-tracking field Scheme_Applied__c, falling back to the
     *              Scheme__c lookup.
     */
    private static Id appliedSchemeId(Order_Line_Item__c li) {
        return li.Scheme_Applied__c != null ? li.Scheme_Applied__c : li.Scheme__c;
    }

    private static String usageKey(Id accountId, Id schemeId) {
        return String.valueOf(accountId) + '|' + String.valueOf(schemeId);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Builds a composite key for duplicate detection.
     * @param accountId The Account ID.
     * @param orderDate The order date.
     * @param salesRepId The Sales Rep user ID.
     * @return A pipe-delimited key string.
     */
    private static String buildDuplicateKey(Id accountId, Date orderDate, Id salesRepId) {
        return String.valueOf(accountId) + '|' +
               String.valueOf(orderDate) + '|' +
               String.valueOf(salesRepId);
    }

    /**
     * @description Retrieves the configurable minimum order value from custom settings.
     *              Falls back to a default if the setting does not exist.
     * @return The minimum order value.
     */
    private static Decimal getMinOrderValue() {
        try {
            List<App_Config__mdt> configs = [
                SELECT Config_Value__c FROM App_Config__mdt
                WHERE DeveloperName = 'Min_Order_Value' LIMIT 1
            ];
            if (!configs.isEmpty() && configs[0].Config_Value__c != null) {
                return Decimal.valueOf(configs[0].Config_Value__c);
            }
        } catch (Exception e) {
            // Custom metadata may not exist; fall back to default
        }
        return 0; // Default: no minimum
    }

}