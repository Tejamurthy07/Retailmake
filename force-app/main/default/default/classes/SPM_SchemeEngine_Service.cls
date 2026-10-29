/**
 * @description Service class implementing the promotional scheme evaluation engine.
 *              Evaluates scheme eligibility based on the 4x6 scheme matrix:
 *
 * Scheme Categories (benefit type):
 *   - Free Products: Customer receives free goods
 *   - Discount in %: Percentage discount on qualifying items
 *   - Discount in Value: Flat amount discount (price discount)
 *   - Reward Points: Points credited to customer account
 *
 * Scheme Types (trigger condition):
 *   - Same Product (QTY): Meet min quantity on the SAME product
 *   - Same Product (VAL): Meet min order value (MOV) on the SAME product
 *   - Assorted Product (QTY): Meet min quantity across MULTIPLE scheme products
 *   - Assorted Product (VAL): Meet MOV across MULTIPLE scheme products
 *   - Invoice Qty Based: Meet total invoice quantity threshold
 *   - Invoice Val Based: Meet total invoice value threshold
 *
 * Supports scheme priority, stacking rules, budget checks, slab-based tiers,
 * and territory-based mapping for order management integration.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class SPM_SchemeEngine_Service {

    // ── Inner classes ────────────────────────────────────────────────────────

    /**
     * @description Encapsulates the result of evaluating a single scheme.
     */
    public class SchemeResult {
        @AuraEnabled public Id schemeId { get; set; }
        @AuraEnabled public String schemeName { get; set; }
        @AuraEnabled public String schemeCategory { get; set; }
        @AuraEnabled public String schemeType { get; set; }
        @AuraEnabled public Decimal discountPercent { get; set; }
        @AuraEnabled public Decimal discountAmount { get; set; }
        @AuraEnabled public Decimal priceDiscount { get; set; }
        @AuraEnabled public Id freeProductId { get; set; }
        @AuraEnabled public String freeProductName { get; set; }
        @AuraEnabled public Decimal freeQty { get; set; }
        @AuraEnabled public Decimal rewardPoints { get; set; }
        @AuraEnabled public Id appliedSlabId { get; set; }
        @AuraEnabled public Map<Id, Decimal> lineItemDiscounts { get; set; }

        public SchemeResult() {
            this.discountPercent = 0;
            this.discountAmount = 0;
            this.priceDiscount = 0;
            this.freeQty = 0;
            this.rewardPoints = 0;
            this.lineItemDiscounts = new Map<Id, Decimal>();
        }

        public Boolean hasAnyBenefit() {
            return discountAmount > 0 || priceDiscount > 0 || freeQty > 0 || rewardPoints > 0;
        }
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /**
     * @description Main entry point: evaluates all applicable schemes for a
     *              sales order and returns the qualifying benefits.
     * @param accountId  The outlet Account Id for channel/type/territory matching.
     * @param lineItems  Order line items with Product_Ext__c, Quantity__c, Net_Amount__c, UOM__c.
     * @param orderDate  The order date for date-range validation.
     * @return List of SchemeResult for all applicable schemes.
     */
    public static List<SchemeResult> getApplicableSchemes(
        Id accountId,
        List<Order_Line_Item__c> lineItems,
        Date orderDate
    ) {
        List<SchemeResult> results = new List<SchemeResult>();

        if (accountId == null || lineItems == null || lineItems.isEmpty()) {
            return results;
        }

        if (orderDate == null) {
            orderDate = Date.today();
        }

        Account outlet = getAccountDetails(accountId);
        if (outlet == null) {
            return results;
        }

        Set<Id> productIds = new Set<Id>();
        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c != null) {
                productIds.add(item.Product_Ext__c);
            }
        }

        List<Scheme__c> candidateSchemes = fetchCandidateSchemes(
            productIds, orderDate, outlet
        );

        if (candidateSchemes.isEmpty()) {
            return results;
        }

        // Pre-query per-customer usage counts for schemes with usage limits
        Map<Id, Integer> schemeUsageCounts = getCustomerSchemeUsageCounts(
            accountId, candidateSchemes
        );

        // Track stacking rules
        Boolean hasNonStackableScheme = false;

        for (Scheme__c scheme : candidateSchemes) {
            if (hasNonStackableScheme && scheme.Is_Stackable__c != true) {
                continue;
            }

            // Budget check
            if (!hasBudgetRemaining(scheme)) {
                continue;
            }

            // Per-customer usage limit check
            if (!hasUsageRemaining(scheme, schemeUsageCounts)) {
                continue;
            }

            SchemeResult result = evaluateScheme(scheme, lineItems, outlet);

            if (result != null && result.hasAnyBenefit()) {
                // Apply discount cap
                if (scheme.Max_Discount_Cap__c != null && result.discountAmount > scheme.Max_Discount_Cap__c) {
                    result.discountAmount = scheme.Max_Discount_Cap__c;
                }

                results.add(result);

                if (scheme.Is_Stackable__c != true) {
                    hasNonStackableScheme = true;
                }
            }
        }

        return results;
    }

    /**
     * @description Evaluates a specific slab within a scheme against qty and value.
     * @param scheme  The Scheme__c record with Scheme_Slabs__r loaded.
     * @param quantity The total quantity for slab evaluation.
     * @param value    The total value for slab evaluation.
     * @return A SchemeResult if a slab matches, null otherwise.
     */
    public static SchemeResult evaluateSlab(
        Scheme__c scheme,
        Decimal quantity,
        Decimal value
    ) {
        if (scheme == null) {
            return null;
        }

        List<Scheme_Slab__c> slabs;
        if (scheme.Scheme_Slabs__r != null) {
            slabs = scheme.Scheme_Slabs__r;
        } else {
            slabs = [
                SELECT Id, Min_Quantity__c, Max_Quantity__c,
                       Min_Value__c, Max_Value__c,
                       Discount_Percent__c, Discount_Amount__c,
                       Price_Discount__c, Reward_Points__c,
                       Free_Product_Ext__c, Free_Product_Ext__r.Name,
                       Free_Quantity__c, Discount_Type__c
                FROM Scheme_Slab__c
                WHERE Scheme__c = :scheme.Id
                  AND Is_Active__c = true
                ORDER BY Min_Quantity__c ASC, Min_Value__c ASC
            ];
        }

        if (slabs == null || slabs.isEmpty()) {
            return null;
        }

        SchemeResult result = new SchemeResult();
        result.schemeId = scheme.Id;
        result.schemeName = scheme.Name;
        result.schemeCategory = scheme.Scheme_Category__c;
        result.schemeType = scheme.Scheme_Type__c;

        for (Scheme_Slab__c slab : slabs) {
            Boolean quantityMatch = isInRange(quantity, slab.Min_Quantity__c, slab.Max_Quantity__c);
            Boolean valueMatch = isInRange(value, slab.Min_Value__c, slab.Max_Value__c);

            Boolean slabMatches = false;
            if (slab.Min_Quantity__c != null && slab.Min_Value__c != null) {
                slabMatches = quantityMatch && valueMatch;
            } else if (slab.Min_Quantity__c != null) {
                slabMatches = quantityMatch;
            } else if (slab.Min_Value__c != null) {
                slabMatches = valueMatch;
            }

            if (slabMatches) {
                result.appliedSlabId = slab.Id;
                applySlabBenefit(result, slab, value);
                return result;
            }
        }

        return null;
    }

    /**
     * @description Applies scheme benefits to sales order line items and returns
     *              updated totals for order-level integration.
     * @param orderId    The Sales_Order__c Id.
     * @param accountId  The outlet Account Id.
     * @param orderDate  The order date.
     * @return Map with keys: schemeDiscount, totalFreeQty, totalRewardPoints, lineResults.
     */
    public static Map<String, Object> applySchemeToOrder(
        Id orderId,
        Id accountId,
        Date orderDate
    ) {
        Map<String, Object> orderResult = new Map<String, Object>();
        orderResult.put('schemeDiscount', 0);
        orderResult.put('totalFreeQty', 0);
        orderResult.put('totalRewardPoints', 0);
        orderResult.put('lineResults', new List<SchemeResult>());

        List<Order_Line_Item__c> lineItems = [
            SELECT Id, Product_Ext__c, Quantity__c, UOM__c,
                   Unit_Price__c, Net_Amount__c, Line_Amount__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c = :orderId
        ];

        if (lineItems.isEmpty()) {
            return orderResult;
        }

        List<SchemeResult> schemeResults = getApplicableSchemes(accountId, lineItems, orderDate);

        Decimal totalDiscount = 0;
        Decimal totalFreeQty = 0;
        Decimal totalRewardPoints = 0;

        List<Order_Line_Item__c> itemsToUpdate = new List<Order_Line_Item__c>();

        for (SchemeResult sr : schemeResults) {
            totalDiscount += sr.discountAmount + sr.priceDiscount;
            totalFreeQty += sr.freeQty;
            totalRewardPoints += sr.rewardPoints;

            // Apply per-line-item discounts
            for (Id lineId : sr.lineItemDiscounts.keySet()) {
                itemsToUpdate.add(new Order_Line_Item__c(
                    Id = lineId,
                    Scheme__c = sr.schemeId,
                    Scheme_Applied__c = sr.schemeId,
                    Scheme_Discount__c = sr.lineItemDiscounts.get(lineId),
                    Scheme_Category__c = sr.schemeCategory,
                    Reward_Points__c = sr.rewardPoints > 0 ? sr.rewardPoints : 0,
                    Free_Quantity__c = sr.freeQty > 0 ? sr.freeQty : 0
                ));
            }
        }

        if (!itemsToUpdate.isEmpty()) {
            update itemsToUpdate;
        }

        // Update order-level totals
        update new Sales_Order__c(
            Id = orderId,
            Scheme_Discount__c = totalDiscount,
            Total_Free_Quantity__c = totalFreeQty,
            Total_Reward_Points__c = (Integer) totalRewardPoints
        );

        orderResult.put('schemeDiscount', totalDiscount);
        orderResult.put('totalFreeQty', totalFreeQty);
        orderResult.put('totalRewardPoints', totalRewardPoints);
        orderResult.put('lineResults', schemeResults);

        return orderResult;
    }

    // ── Per-customer usage limit (public API) ────────────────────────────────

    /**
     * @description Counts how many distinct orders the given customer has had a
     *              specific scheme applied to (its consumed usage).
     * @param accountId The customer Account Id.
     * @param schemeId  The Scheme__c Id.
     * @return The number of times the customer has used the scheme.
     */
    public static Integer getCustomerUsageCount(Id accountId, Id schemeId) {
        if (accountId == null || schemeId == null) {
            return 0;
        }
        Map<Id, Integer> counts = SPM_SchemeUsage_Service.getUsageCounts(
            accountId, new Set<Id>{ schemeId }
        );
        return counts.containsKey(schemeId) ? counts.get(schemeId) : 0;
    }

    /**
     * @description Determines whether a customer may still apply a scheme, i.e.
     *              they have NOT yet reached the scheme's Max_Usage_Per_Customer__c.
     *              A scheme with no usage limit set is always applicable.
     * @param accountId The customer Account Id.
     * @param schemeId  The Scheme__c Id.
     * @return true when the customer is below the per-customer usage cap.
     */
    public static Boolean canCustomerApplyScheme(Id accountId, Id schemeId) {
        if (schemeId == null) {
            return false;
        }
        List<Scheme__c> schemes = [
            SELECT Id, Max_Usage_Per_Customer__c
            FROM Scheme__c WHERE Id = :schemeId LIMIT 1
        ];
        if (schemes.isEmpty()) {
            return false;
        }
        Decimal maxUsage = schemes[0].Max_Usage_Per_Customer__c;
        if (maxUsage == null || maxUsage <= 0) {
            return true; // No per-customer limit configured.
        }
        return getCustomerUsageCount(accountId, schemeId) < maxUsage.intValue();
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private static Account getAccountDetails(Id accountId) {
        List<Account> accounts = [
            SELECT Id, Name, Channel__c, Outlet_Type__c, Region__c, Type,
                   RecordType.DeveloperName
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        return accounts.isEmpty() ? null : accounts[0];
    }

    /**
     * @description Fetches candidate schemes considering date range, product match,
     *              channel, outlet type, and territory mapping.
     */
    private static List<Scheme__c> fetchCandidateSchemes(
        Set<Id> productIds,
        Date orderDate,
        Account outlet
    ) {
        String channel = outlet.Channel__c;
        String outletType = outlet.Outlet_Type__c;

        // Get schemes mapped to this outlet (if any mappings exist)
        // Derives customer type from Account RecordType for mapping match
        String customerType = getCustomerTypeFromRecordType(outlet);
        Set<Id> mappedSchemeIds = getMappedSchemeIds(outlet.Id, customerType);

        // Pre-query scheme Ids linked via Scheme_Product__c for product match
        Set<Id> schemeIdsFromProducts = new Set<Id>();
        for (Scheme_Product__c sp : [
            SELECT Scheme__c FROM Scheme_Product__c
            WHERE Product_Ext__c IN :productIds AND Is_Buy_Product__c = true
        ]) {
            schemeIdsFromProducts.add(sp.Scheme__c);
        }

        // Pre-query scheme Ids that have active mappings (territory-restricted)
        Set<Id> territoryRestrictedSchemeIds = new Set<Id>();
        for (Scheme_Mapping__c sm : [
            SELECT Scheme__c FROM Scheme_Mapping__c WHERE Is_Active__c = true
        ]) {
            territoryRestrictedSchemeIds.add(sm.Scheme__c);
        }

        return [
            SELECT Id, Name, Scheme_Type__c, Scheme_Category__c, Priority__c,
                   Is_Stackable__c, Discount_Percent__c, Discount_Amount__c,
                   Price_Discount__c, Reward_Points__c,
                   Free_Product_Ext__c, Free_Product_Ext__r.Name, Free_Quantity__c,
                   Min_Quantity__c, Max_Quantity__c,
                   Min_Value__c, Max_Value__c, MOV__c,
                   Invoice_Qty_Threshold__c, Invoice_Qty_UOM__c, Invoice_Val_Threshold__c,
                   Base_UOM__c, Base_UOM__r.UOM_Code__c,
                   Channel__c, Outlet_Type__c, Max_Discount_Cap__c,
                   Product_Ext__c, Product_Category__c,
                   Budget_Amount__c, Budget_Used__c, Budget_Remaining__c,
                   Max_Usage_Per_Customer__c,
                   Start_Date__c, End_Date__c,
                   (SELECT Id, Product_Ext__c, Product_Ext__r.Name,
                           Is_Buy_Product__c, Is_Get_Product__c,
                           Min_Quantity__c, Product_Category__c
                    FROM Scheme_Products__r),
                   (SELECT Id, Min_Quantity__c, Max_Quantity__c,
                           Min_Value__c, Max_Value__c,
                           Discount_Percent__c, Discount_Amount__c,
                           Price_Discount__c, Reward_Points__c,
                           Free_Product_Ext__c, Free_Product_Ext__r.Name,
                           Free_Quantity__c, Discount_Type__c
                    FROM Scheme_Slabs__r
                    WHERE Is_Active__c = true
                    ORDER BY Min_Quantity__c ASC, Min_Value__c ASC)
            FROM Scheme__c
            WHERE Is_Active__c = true
              AND Start_Date__c <= :orderDate
              AND (End_Date__c >= :orderDate OR End_Date__c = null)
              AND (Channel__c = :channel OR Channel__c = null)
              AND (Outlet_Type__c = :outletType OR Outlet_Type__c = null)
              AND (
                  Product_Ext__c IN :productIds
                  OR Product_Ext__c = null
                  OR Id IN :schemeIdsFromProducts
              )
              AND (
                  Id NOT IN :territoryRestrictedSchemeIds
                  OR Id IN :mappedSchemeIds
              )
            ORDER BY Priority__c ASC NULLS LAST
        ];
    }

    /**
     * @description Maps Account RecordType DeveloperName to Scheme_Mapping Customer_Type__c value.
     */
    private static String getCustomerTypeFromRecordType(Account outlet) {
        if (outlet.RecordType == null || String.isBlank(outlet.RecordType.DeveloperName)) {
            return null;
        }
        Map<String, String> recordTypeToCustomerType = new Map<String, String>{
            'Retailer' => 'Retailer',
            'Distributor' => 'Distributor',
            'Super_Stockist' => 'Super Stockist',
            'Modern_Trade' => 'Modern Trade'
        };
        return recordTypeToCustomerType.get(outlet.RecordType.DeveloperName);
    }

    /**
     * @description Gets scheme Ids mapped to a specific outlet via Scheme_Mapping__c.
     *              Filters by Account match and Customer_Type__c match.
     */
    private static Set<Id> getMappedSchemeIds(Id accountId, String customerType) {
        Set<Id> schemeIds = new Set<Id>();
        for (Scheme_Mapping__c mapping : [
            SELECT Scheme__c, Customer_Type__c
            FROM Scheme_Mapping__c
            WHERE Is_Active__c = true
              AND (Account__c = :accountId OR Account__c = null)
              AND (Customer_Type__c = :customerType OR Customer_Type__c = null)
        ]) {
            schemeIds.add(mapping.Scheme__c);
        }
        return schemeIds;
    }

    /**
     * @description Checks if scheme has remaining budget.
     */
    private static Boolean hasBudgetRemaining(Scheme__c scheme) {
        if (scheme.Budget_Amount__c == null || scheme.Budget_Amount__c == 0) {
            return true;
        }
        Decimal used = scheme.Budget_Used__c != null ? scheme.Budget_Used__c : 0;
        return used < scheme.Budget_Amount__c;
    }

    /**
     * @description Checks if the customer has not exceeded the per-customer usage limit.
     */
    private static Boolean hasUsageRemaining(Scheme__c scheme, Map<Id, Integer> usageCounts) {
        if (scheme.Max_Usage_Per_Customer__c == null || scheme.Max_Usage_Per_Customer__c <= 0) {
            return true; // No usage limit
        }
        Integer used = usageCounts.containsKey(scheme.Id) ? usageCounts.get(scheme.Id) : 0;
        return used < scheme.Max_Usage_Per_Customer__c.intValue();
    }

    /**
     * @description Bulk-queries how many times each scheme has been used by a given account.
     *              Only queries schemes that have a Max_Usage_Per_Customer__c set.
     */
    private static Map<Id, Integer> getCustomerSchemeUsageCounts(
        Id accountId,
        List<Scheme__c> schemes
    ) {
        // Collect scheme Ids that have a usage limit
        Set<Id> limitedSchemeIds = new Set<Id>();
        for (Scheme__c s : schemes) {
            if (s.Max_Usage_Per_Customer__c != null && s.Max_Usage_Per_Customer__c > 0) {
                limitedSchemeIds.add(s.Id);
            }
        }

        if (limitedSchemeIds.isEmpty()) {
            return new Map<Id, Integer>();
        }

        // Read from the authoritative Scheme_Usage__c ledger so invoice/order-
        // level schemes (never stamped onto a line) are counted reliably.
        return SPM_SchemeUsage_Service.getUsageCounts(accountId, limitedSchemeIds);
    }

    /**
     * @description Core evaluation logic dispatching to the correct handler based
     *              on scheme type (trigger condition).
     */
    private static SchemeResult evaluateScheme(
        Scheme__c scheme,
        List<Order_Line_Item__c> lineItems,
        Account outlet
    ) {
        String schemeType = scheme.Scheme_Type__c;

        if (schemeType == 'Same Product (QTY)') {
            return evaluateSameProductQty(scheme, lineItems);
        } else if (schemeType == 'Same Product (VAL)') {
            return evaluateSameProductVal(scheme, lineItems);
        } else if (schemeType == 'Assorted Product (QTY)') {
            return evaluateAssortedProductQty(scheme, lineItems);
        } else if (schemeType == 'Assorted Product (VAL)') {
            return evaluateAssortedProductVal(scheme, lineItems);
        } else if (schemeType == 'Invoice Qty Based') {
            return evaluateInvoiceQty(scheme, lineItems);
        } else if (schemeType == 'Invoice Val Based') {
            return evaluateInvoiceVal(scheme, lineItems);
        }

        return null;
    }

    // ── Scheme Type Evaluators ───────────────────────────────────────────────

    /**
     * @description Same Product (QTY): Each scheme product must individually
     *              meet its min quantity to qualify.
     */
    private static SchemeResult evaluateSameProductQty(
        Scheme__c scheme,
        List<Order_Line_Item__c> lineItems
    ) {
        Set<Id> buyProductIds = getBuyProductIds(scheme);
        Map<Id, Decimal> minQtyMap = getSchemeProductMinQty(scheme);
        Decimal schemeMinQty = scheme.Min_Quantity__c != null ? scheme.Min_Quantity__c : 0;
        String schemeBaseUOMCode = getSchemeBaseUOMCode(scheme);

        Boolean anyQualifies = false;
        Decimal totalQualifyingQty = 0;
        Decimal totalQualifyingVal = 0;
        Map<Id, Decimal> qualifyingLineAmounts = new Map<Id, Decimal>();

        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c == null || !buyProductIds.contains(item.Product_Ext__c)) {
                continue;
            }

            Decimal itemQty = item.Quantity__c != null ? item.Quantity__c : 0;
            itemQty = convertToSchemeBaseUOM(itemQty, item.UOM__c, schemeBaseUOMCode, item.Product_Ext__c);
            Decimal requiredQty = minQtyMap.containsKey(item.Product_Ext__c)
                ? minQtyMap.get(item.Product_Ext__c) : schemeMinQty;

            if (itemQty >= requiredQty && requiredQty > 0) {
                anyQualifies = true;
                totalQualifyingQty += itemQty;
                Decimal lineVal = getLineValue(item);
                totalQualifyingVal += lineVal;
                qualifyingLineAmounts.put(item.Id, lineVal);
            }
        }

        if (!anyQualifies) {
            return null;
        }

        if (scheme.Scheme_Slabs__r != null && !scheme.Scheme_Slabs__r.isEmpty()) {
            SchemeResult slabResult = evaluateSlab(scheme, totalQualifyingQty, totalQualifyingVal);
            if (slabResult != null) {
                slabResult.lineItemDiscounts = distributeDiscountToLines(
                    slabResult.discountAmount + slabResult.priceDiscount,
                    qualifyingLineAmounts
                );
            }
            return slabResult;
        }

        return buildDirectResult(scheme, totalQualifyingQty, totalQualifyingVal, qualifyingLineAmounts);
    }

    /**
     * @description Same Product (VAL): Each scheme product must individually
     *              meet the MOV (minimum order value) to qualify.
     */
    private static SchemeResult evaluateSameProductVal(
        Scheme__c scheme,
        List<Order_Line_Item__c> lineItems
    ) {
        Set<Id> buyProductIds = getBuyProductIds(scheme);
        Decimal movThreshold = scheme.MOV__c != null ? scheme.MOV__c
            : (scheme.Min_Value__c != null ? scheme.Min_Value__c : 0);

        Boolean anyQualifies = false;
        Decimal totalQualifyingQty = 0;
        Decimal totalQualifyingVal = 0;
        Map<Id, Decimal> qualifyingLineAmounts = new Map<Id, Decimal>();

        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c == null || !buyProductIds.contains(item.Product_Ext__c)) {
                continue;
            }

            Decimal lineVal = getLineValue(item);
            if (lineVal >= movThreshold && movThreshold > 0) {
                anyQualifies = true;
                totalQualifyingQty += (item.Quantity__c != null ? item.Quantity__c : 0);
                totalQualifyingVal += lineVal;
                qualifyingLineAmounts.put(item.Id, lineVal);
            }
        }

        if (!anyQualifies) {
            return null;
        }

        if (scheme.Scheme_Slabs__r != null && !scheme.Scheme_Slabs__r.isEmpty()) {
            SchemeResult slabResult = evaluateSlab(scheme, totalQualifyingQty, totalQualifyingVal);
            if (slabResult != null) {
                slabResult.lineItemDiscounts = distributeDiscountToLines(
                    slabResult.discountAmount + slabResult.priceDiscount,
                    qualifyingLineAmounts
                );
            }
            return slabResult;
        }

        return buildDirectResult(scheme, totalQualifyingQty, totalQualifyingVal, qualifyingLineAmounts);
    }

    /**
     * @description Assorted Product (QTY): Aggregate quantity across ALL scheme
     *              buy-products and check against individual min thresholds.
     */
    private static SchemeResult evaluateAssortedProductQty(
        Scheme__c scheme,
        List<Order_Line_Item__c> lineItems
    ) {
        Set<Id> buyProductIds = getBuyProductIds(scheme);
        String schemeBaseUOMCode = getSchemeBaseUOMCode(scheme);

        Decimal totalQty = 0;
        Decimal totalVal = 0;
        Map<Id, Decimal> qualifyingLineAmounts = new Map<Id, Decimal>();

        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c == null || !buyProductIds.contains(item.Product_Ext__c)) {
                continue;
            }

            Decimal qty = item.Quantity__c != null ? item.Quantity__c : 0;
            qty = convertToSchemeBaseUOM(qty, item.UOM__c, schemeBaseUOMCode, item.Product_Ext__c);
            Decimal val = getLineValue(item);
            totalQty += qty;
            totalVal += val;
            qualifyingLineAmounts.put(item.Id, val);
        }

        // Check each product meets its individual min qty (quantities already converted to scheme base UOM)
        Map<Id, Decimal> minQtyMap = getSchemeProductMinQty(scheme);
        for (Id prodId : minQtyMap.keySet()) {
            Decimal prodQty = 0;
            for (Order_Line_Item__c item : lineItems) {
                if (item.Product_Ext__c == prodId) {
                    Decimal qty = item.Quantity__c != null ? item.Quantity__c : 0;
                    prodQty += convertToSchemeBaseUOM(qty, item.UOM__c, schemeBaseUOMCode, item.Product_Ext__c);
                }
            }
            if (prodQty < minQtyMap.get(prodId)) {
                return null;
            }
        }

        Decimal requiredQty = scheme.Min_Quantity__c != null ? scheme.Min_Quantity__c : 0;
        if (totalQty < requiredQty && requiredQty > 0) {
            return null;
        }

        if (scheme.Scheme_Slabs__r != null && !scheme.Scheme_Slabs__r.isEmpty()) {
            SchemeResult slabResult = evaluateSlab(scheme, totalQty, totalVal);
            if (slabResult != null) {
                slabResult.lineItemDiscounts = distributeDiscountToLines(
                    slabResult.discountAmount + slabResult.priceDiscount,
                    qualifyingLineAmounts
                );
            }
            return slabResult;
        }

        return buildDirectResult(scheme, totalQty, totalVal, qualifyingLineAmounts);
    }

    /**
     * @description Assorted Product (VAL): Aggregate value across ALL scheme
     *              buy-products and check against the MOV threshold.
     */
    private static SchemeResult evaluateAssortedProductVal(
        Scheme__c scheme,
        List<Order_Line_Item__c> lineItems
    ) {
        Set<Id> buyProductIds = getBuyProductIds(scheme);
        Decimal movThreshold = scheme.MOV__c != null ? scheme.MOV__c
            : (scheme.Min_Value__c != null ? scheme.Min_Value__c : 0);

        Decimal totalQty = 0;
        Decimal totalVal = 0;
        Map<Id, Decimal> qualifyingLineAmounts = new Map<Id, Decimal>();

        for (Order_Line_Item__c item : lineItems) {
            if (item.Product_Ext__c == null || !buyProductIds.contains(item.Product_Ext__c)) {
                continue;
            }

            totalQty += (item.Quantity__c != null ? item.Quantity__c : 0);
            Decimal val = getLineValue(item);
            totalVal += val;
            qualifyingLineAmounts.put(item.Id, val);
        }

        if (totalVal < movThreshold && movThreshold > 0) {
            return null;
        }

        if (scheme.Scheme_Slabs__r != null && !scheme.Scheme_Slabs__r.isEmpty()) {
            SchemeResult slabResult = evaluateSlab(scheme, totalQty, totalVal);
            if (slabResult != null) {
                slabResult.lineItemDiscounts = distributeDiscountToLines(
                    slabResult.discountAmount + slabResult.priceDiscount,
                    qualifyingLineAmounts
                );
            }
            return slabResult;
        }

        return buildDirectResult(scheme, totalQty, totalVal, qualifyingLineAmounts);
    }

    /**
     * @description Invoice Qty Based: Total invoice quantity (across scheme materials)
     *              must meet the invoice qty threshold. Converts line item UOMs to the
     *              scheme's Invoice_Qty_UOM__c before comparing against the threshold.
     */
    private static SchemeResult evaluateInvoiceQty(
        Scheme__c scheme,
        List<Order_Line_Item__c> lineItems
    ) {
        Set<Id> schemeProductIds = getBuyProductIds(scheme);

        // Prefer Base_UOM__c (Lookup), fall back to Invoice_Qty_UOM__c (picklist)
        String schemeBaseUOMCode = getSchemeBaseUOMCode(scheme);
        if (String.isBlank(schemeBaseUOMCode)) {
            schemeBaseUOMCode = scheme.Invoice_Qty_UOM__c;
        }
        Decimal totalQty = 0;
        Decimal totalVal = 0;
        Map<Id, Decimal> allLineAmounts = new Map<Id, Decimal>();

        for (Order_Line_Item__c item : lineItems) {
            if (!schemeProductIds.isEmpty() && item.Product_Ext__c != null
                && !schemeProductIds.contains(item.Product_Ext__c)) {
                continue;
            }

            Decimal itemQty = item.Quantity__c != null ? item.Quantity__c : 0;
            itemQty = convertToSchemeBaseUOM(itemQty, item.UOM__c, schemeBaseUOMCode, item.Product_Ext__c);

            totalQty += itemQty;
            Decimal val = getLineValue(item);
            totalVal += val;
            allLineAmounts.put(item.Id, val);
        }

        Decimal threshold = scheme.Invoice_Qty_Threshold__c != null
            ? scheme.Invoice_Qty_Threshold__c
            : (scheme.Min_Quantity__c != null ? scheme.Min_Quantity__c : 0);

        if (totalQty < threshold && threshold > 0) {
            return null;
        }

        if (scheme.Scheme_Slabs__r != null && !scheme.Scheme_Slabs__r.isEmpty()) {
            SchemeResult slabResult = evaluateSlab(scheme, totalQty, totalVal);
            if (slabResult != null) {
                slabResult.lineItemDiscounts = distributeDiscountToLines(
                    slabResult.discountAmount + slabResult.priceDiscount,
                    allLineAmounts
                );
            }
            return slabResult;
        }

        return buildDirectResult(scheme, totalQty, totalVal, allLineAmounts);
    }

    /**
     * @description Invoice Val Based: Total invoice value (across scheme materials)
     *              must meet the invoice value threshold.
     */
    private static SchemeResult evaluateInvoiceVal(
        Scheme__c scheme,
        List<Order_Line_Item__c> lineItems
    ) {
        Set<Id> schemeProductIds = getBuyProductIds(scheme);

        Decimal totalQty = 0;
        Decimal totalVal = 0;
        Map<Id, Decimal> allLineAmounts = new Map<Id, Decimal>();

        for (Order_Line_Item__c item : lineItems) {
            if (!schemeProductIds.isEmpty() && item.Product_Ext__c != null
                && !schemeProductIds.contains(item.Product_Ext__c)) {
                continue;
            }

            totalQty += (item.Quantity__c != null ? item.Quantity__c : 0);
            Decimal val = getLineValue(item);
            totalVal += val;
            allLineAmounts.put(item.Id, val);
        }

        Decimal threshold = scheme.Invoice_Val_Threshold__c != null
            ? scheme.Invoice_Val_Threshold__c
            : (scheme.Min_Value__c != null ? scheme.Min_Value__c : 0);

        if (totalVal < threshold && threshold > 0) {
            return null;
        }

        if (scheme.Scheme_Slabs__r != null && !scheme.Scheme_Slabs__r.isEmpty()) {
            SchemeResult slabResult = evaluateSlab(scheme, totalQty, totalVal);
            if (slabResult != null) {
                slabResult.lineItemDiscounts = distributeDiscountToLines(
                    slabResult.discountAmount + slabResult.priceDiscount,
                    allLineAmounts
                );
            }
            return slabResult;
        }

        return buildDirectResult(scheme, totalQty, totalVal, allLineAmounts);
    }

    // ── Benefit builders ─────────────────────────────────────────────────────

    /**
     * @description Builds a SchemeResult directly from scheme-level fields.
     */
    private static SchemeResult buildDirectResult(
        Scheme__c scheme,
        Decimal totalQty,
        Decimal totalVal,
        Map<Id, Decimal> lineAmounts
    ) {
        SchemeResult result = new SchemeResult();
        result.schemeId = scheme.Id;
        result.schemeName = scheme.Name;
        result.schemeCategory = scheme.Scheme_Category__c;
        result.schemeType = scheme.Scheme_Type__c;

        String category = scheme.Scheme_Category__c;

        if (category == 'Free Products') {
            result.freeProductId = scheme.Free_Product_Ext__c;
            result.freeProductName = scheme.Free_Product_Ext__r != null
                ? scheme.Free_Product_Ext__r.Name : null;
            result.freeQty = scheme.Free_Quantity__c != null ? scheme.Free_Quantity__c : 0;
        } else if (category == 'Discount in %') {
            Decimal pct = scheme.Discount_Percent__c != null ? scheme.Discount_Percent__c : 0;
            result.discountPercent = pct;
            result.discountAmount = (totalVal * pct / 100).setScale(2, RoundingMode.HALF_UP);
        } else if (category == 'Discount in Value') {
            result.priceDiscount = scheme.Price_Discount__c != null ? scheme.Price_Discount__c
                : (scheme.Discount_Amount__c != null ? scheme.Discount_Amount__c : 0);
            result.discountAmount = result.priceDiscount;
        } else if (category == 'Reward Points') {
            result.rewardPoints = scheme.Reward_Points__c != null ? scheme.Reward_Points__c : 0;
        }

        result.lineItemDiscounts = distributeDiscountToLines(
            result.discountAmount + result.priceDiscount,
            lineAmounts
        );

        return result;
    }

    /**
     * @description Applies slab benefit fields to a SchemeResult.
     */
    private static void applySlabBenefit(SchemeResult result, Scheme_Slab__c slab, Decimal value) {
        String discountType = slab.Discount_Type__c;

        if (discountType == 'Percent') {
            Decimal pct = slab.Discount_Percent__c != null ? slab.Discount_Percent__c : 0;
            result.discountPercent = pct;
            result.discountAmount = (value * pct / 100).setScale(2, RoundingMode.HALF_UP);
        } else if (discountType == 'Amount') {
            result.discountAmount = slab.Discount_Amount__c != null ? slab.Discount_Amount__c : 0;
        } else if (discountType == 'Free Product') {
            result.freeProductId = slab.Free_Product_Ext__c;
            result.freeProductName = slab.Free_Product_Ext__r != null
                ? slab.Free_Product_Ext__r.Name : null;
            result.freeQty = slab.Free_Quantity__c != null ? slab.Free_Quantity__c : 0;
        } else if (discountType == 'Price Discount') {
            result.priceDiscount = slab.Price_Discount__c != null ? slab.Price_Discount__c : 0;
            result.discountAmount = result.priceDiscount;
        } else if (discountType == 'Reward Points') {
            result.rewardPoints = slab.Reward_Points__c != null ? slab.Reward_Points__c : 0;
        }
    }

    // ── Utility helpers ──────────────────────────────────────────────────────

    private static Set<Id> getBuyProductIds(Scheme__c scheme) {
        Set<Id> productIds = new Set<Id>();
        if (scheme.Scheme_Products__r != null) {
            for (Scheme_Product__c sp : scheme.Scheme_Products__r) {
                if (sp.Is_Buy_Product__c && sp.Product_Ext__c != null) {
                    productIds.add(sp.Product_Ext__c);
                }
            }
        }
        if (productIds.isEmpty() && scheme.Product_Ext__c != null) {
            productIds.add(scheme.Product_Ext__c);
        }
        return productIds;
    }

    private static Map<Id, Decimal> getSchemeProductMinQty(Scheme__c scheme) {
        Map<Id, Decimal> minQtyMap = new Map<Id, Decimal>();
        if (scheme.Scheme_Products__r != null) {
            for (Scheme_Product__c sp : scheme.Scheme_Products__r) {
                if (sp.Is_Buy_Product__c && sp.Product_Ext__c != null && sp.Min_Quantity__c != null) {
                    minQtyMap.put(sp.Product_Ext__c, sp.Min_Quantity__c);
                }
            }
        }
        return minQtyMap;
    }

    private static Decimal getLineValue(Order_Line_Item__c item) {
        if (item.Net_Amount__c != null) {
            return item.Net_Amount__c;
        }
        if (item.Line_Amount__c != null) {
            return item.Line_Amount__c;
        }
        return 0;
    }

    private static Map<Id, Decimal> distributeDiscountToLines(
        Decimal totalDiscount,
        Map<Id, Decimal> lineAmounts
    ) {
        Map<Id, Decimal> distribution = new Map<Id, Decimal>();

        if (totalDiscount == null || totalDiscount <= 0 || lineAmounts.isEmpty()) {
            return distribution;
        }

        Decimal totalLineValue = 0;
        for (Decimal val : lineAmounts.values()) {
            totalLineValue += val;
        }

        if (totalLineValue <= 0) {
            return distribution;
        }

        for (Id lineId : lineAmounts.keySet()) {
            Decimal proportion = lineAmounts.get(lineId) / totalLineValue;
            Decimal lineDiscount = (totalDiscount * proportion).setScale(2, RoundingMode.HALF_UP);
            distribution.put(lineId, lineDiscount);
        }

        return distribution;
    }

    private static Boolean isInRange(Decimal value, Decimal minVal, Decimal maxVal) {
        if (value == null) {
            return false;
        }
        Boolean aboveMin = (minVal == null) || (value >= minVal);
        Boolean belowMax = (maxVal == null) || (value <= maxVal);
        return aboveMin && belowMax;
    }

    // ── UOM Conversion helpers for scheme evaluation ─────────────────────────

    /**
     * @description Extracts the UOM code from the scheme's Base_UOM__c lookup.
     *              Returns null if Base_UOM__c is not set.
     */
    private static String getSchemeBaseUOMCode(Scheme__c scheme) {
        if (scheme.Base_UOM__c != null && scheme.Base_UOM__r != null
            && String.isNotBlank(scheme.Base_UOM__r.UOM_Code__c)) {
            return scheme.Base_UOM__r.UOM_Code__c;
        }
        return null;
    }

    /**
     * @description Converts a line item quantity from the order's UOM to the
     *              scheme's base UOM code. Uses UOM_Conversion_Service for
     *              cached, governor-limit-safe conversion.
     */
    private static Decimal convertToSchemeBaseUOM(
        Decimal qty, String orderUOM, String schemeBaseUOMCode, Id productId
    ) {
        if (qty == null || qty == 0 || String.isBlank(schemeBaseUOMCode) || String.isBlank(orderUOM)) {
            return qty != null ? qty : 0;
        }
        String lineUOMCode = UOM_Conversion_Service.mapPicklistToCode(orderUOM);
        if (lineUOMCode == schemeBaseUOMCode) {
            return qty;
        }
        return UOM_Conversion_Service.convert(productId, lineUOMCode, schemeBaseUOMCode, qty);
    }
}