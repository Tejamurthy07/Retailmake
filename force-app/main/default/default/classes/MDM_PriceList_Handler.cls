/**
 * @description Trigger handler for Price_List__c. Ensures price list date ranges
 *              do not overlap for the same dimension combination, auto-calculates
 *              priority based on populated dimensions, and maintains an audit
 *              trail of price changes.
 *
 *              Priority logic (configurable via Pricebook_Priority__mdt):
 *              1 = Customer-wise (highest)
 *              2 = Category + Territory + Channel
 *              3 = Territory + Channel
 *              4 = Category + Territory
 *              5 = Territory-wise
 *              6 = Channel-wise
 *              7 = Category-wise
 *              8 = Base price (no dimensions)
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class MDM_PriceList_Handler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    /**
     * @description Auto-calculates priority and validates that new price list
     *              entries do not have overlapping date ranges.
     */
    protected override void beforeInsert() {
        List<Price_List__c> newRecords = (List<Price_List__c>) Trigger.new;
        calculatePriority(newRecords);
        validateDateRangeOverlap(newRecords, null);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    /**
     * @description Re-calculates priority and re-validates date ranges when
     *              effective dates or key dimensions change.
     */
    protected override void beforeUpdate() {
        List<Price_List__c> newRecords = (List<Price_List__c>) Trigger.new;
        Map<Id, Price_List__c> oldMap = (Map<Id, Price_List__c>) Trigger.oldMap;

        List<Price_List__c> changedRecords = new List<Price_List__c>();
        List<Price_List__c> dimensionChangedRecords = new List<Price_List__c>();

        for (Price_List__c rec : newRecords) {
            Price_List__c oldRec = oldMap.get(rec.Id);

            // Check if any dimension field changed or priority is missing (need priority recalc)
            if (rec.Priority__c == null ||
                rec.Customer__c != oldRec.Customer__c ||
                rec.Category__c != oldRec.Category__c ||
                rec.Territory__c != oldRec.Territory__c ||
                rec.Channel__c != oldRec.Channel__c) {
                dimensionChangedRecords.add(rec);
            }

            // Check if date or dimension fields changed (need overlap validation)
            if (rec.Effective_From__c != oldRec.Effective_From__c ||
                rec.Effective_To__c != oldRec.Effective_To__c ||
                rec.Product_Ext__c != oldRec.Product_Ext__c ||
                rec.Region__c != oldRec.Region__c ||
                rec.Channel__c != oldRec.Channel__c ||
                rec.Customer__c != oldRec.Customer__c ||
                rec.Category__c != oldRec.Category__c ||
                rec.Territory__c != oldRec.Territory__c) {
                changedRecords.add(rec);
            }
        }

        // Recalculate priority for records where dimensions changed
        if (!dimensionChangedRecords.isEmpty()) {
            calculatePriority(dimensionChangedRecords);
        }

        if (!changedRecords.isEmpty()) {
            Set<Id> currentIds = new Set<Id>();
            for (Price_List__c rec : changedRecords) {
                currentIds.add(rec.Id);
            }
            validateDateRangeOverlap(changedRecords, currentIds);
        }
    }

    // ── After Update ──────────────────────────────────────────────────────────

    /**
     * @description Logs price changes into the Price_Change_Log__c object for
     *              audit and compliance tracking.
     */
    protected override void afterUpdate() {
        List<Price_List__c> newRecords = (List<Price_List__c>) Trigger.new;
        Map<Id, Price_List__c> oldMap = (Map<Id, Price_List__c>) Trigger.oldMap;
        logPriceChanges(newRecords, oldMap);
    }

    // ── Private helper methods ────────────────────────────────────────────────

    /**
     * @description Calculates the priority for price list records based on which
     *              dimension fields (Customer, Category, Territory, Channel) are
     *              populated. Uses Pricebook_Priority__mdt for configurable priority
     *              ordering.
     *
     *              Matching strategy:
     *              1. Customer populated  -> Priority 1 (customer-wise), regardless of
     *                 whatever else is also populated. Customer-specific pricing is the
     *                 most specific dimension by design and always wins. This short-circuit
     *                 fixes the case where picking Customer + Channel together used to
     *                 fall through to base price because no metadata config had
     *                 Has_Customer=true AND Has_Channel=true.
     *              2. Otherwise, look up the metadata row whose Has_* flags match the
     *                 record's populated dimensions exactly. The metadata ships rows for
     *                 every meaningful combination (Category+Territory+Channel,
     *                 Territory+Channel, Category+Territory, Territory, Channel,
     *                 Category, Base).
     *              3. Fallback = 8 (base price).
     *
     * @param records The records to calculate priority for.
     */
    private void calculatePriority(List<Price_List__c> records) {
        // Load priority configuration from custom metadata
        List<Pricebook_Priority__mdt> priorityConfigs = [
            SELECT Priority_Order__c, Has_Customer__c, Has_Category__c,
                   Has_Territory__c, Has_Channel__c
            FROM Pricebook_Priority__mdt
            WHERE Is_Active__c = true
            ORDER BY Priority_Order__c ASC
        ];

        // Resolve the customer-wise priority from the single Has_Customer=true
        // metadata row so it stays configurable (no hardcoded 1).
        Integer customerPriority = null;
        for (Pricebook_Priority__mdt config : priorityConfigs) {
            if (config.Has_Customer__c == true) {
                customerPriority = Integer.valueOf(config.Priority_Order__c);
                break;
            }
        }

        for (Price_List__c rec : records) {
            Boolean hasCustomer = rec.Customer__c != null;
            Boolean hasCategory = rec.Category__c != null;
            Boolean hasTerritory = rec.Territory__c != null;
            Boolean hasChannel = String.isNotBlank(rec.Channel__c);

            Integer priority = 8; // Default: base price (no dimensions)

            if (hasCustomer && customerPriority != null) {
                // Customer-specific pricing always wins — any combination
                // that includes a customer is treated as customer-wise.
                priority = customerPriority;
            } else {
                for (Pricebook_Priority__mdt config : priorityConfigs) {
                    if (config.Has_Customer__c == hasCustomer &&
                        config.Has_Category__c == hasCategory &&
                        config.Has_Territory__c == hasTerritory &&
                        config.Has_Channel__c == hasChannel) {
                        priority = Integer.valueOf(config.Priority_Order__c);
                        break;
                    }
                }
            }

            rec.Priority__c = priority;
        }
    }

    /**
     * @description Validates that no two price list entries overlap in their date
     *              ranges for the same product + customer + category + territory +
     *              channel combination.
     *              Checks both within the current batch and against existing DB records.
     * @param records   The records to validate.
     * @param excludeIds Set of Ids to exclude from the overlap query (for updates).
     */
    private void validateDateRangeOverlap(List<Price_List__c> records, Set<Id> excludeIds) {
        // Build composite keys and collect dimension values for query
        Set<Id> productIds = new Set<Id>();
        Set<Id> regionValues = new Set<Id>();
        Set<String> channelValues = new Set<String>();
        Set<Id> customerIds = new Set<Id>();
        Set<Id> categoryIds = new Set<Id>();
        Set<Id> territoryIds = new Set<Id>();

        for (Price_List__c rec : records) {
            if (rec.Product_Ext__c != null) {
                productIds.add(rec.Product_Ext__c);
            }
            if (rec.Region__c != null) {
                regionValues.add(rec.Region__c);
            }
            if (String.isNotBlank(rec.Channel__c)) {
                channelValues.add(rec.Channel__c);
            }
            if (rec.Customer__c != null) {
                customerIds.add(rec.Customer__c);
            }
            if (rec.Category__c != null) {
                categoryIds.add(rec.Category__c);
            }
            if (rec.Territory__c != null) {
                territoryIds.add(rec.Territory__c);
            }
        }

        if (productIds.isEmpty()) {
            return;
        }

        // Query existing price lists for the same dimension combinations
        String query = 'SELECT Id, Product_Ext__c, Region__c, Channel__c, ' +
                       'Customer__c, Category__c, Territory__c, ' +
                       'Effective_From__c, Effective_To__c ' +
                       'FROM Price_List__c ' +
                       'WHERE Product_Ext__c IN :productIds';

        if (excludeIds != null && !excludeIds.isEmpty()) {
            query += ' AND Id NOT IN :excludeIds';
        }

        // Build a map of composite key -> list of existing date ranges
        Map<String, List<Price_List__c>> existingByKey = new Map<String, List<Price_List__c>>();
        for (Price_List__c existing : Database.query(query)) {
            String key = buildCompositeKey(existing);
            if (!existingByKey.containsKey(key)) {
                existingByKey.put(key, new List<Price_List__c>());
            }
            existingByKey.get(key).add(existing);
        }

        // Also check within the incoming batch for intra-batch overlaps
        Map<String, List<Price_List__c>> batchByKey = new Map<String, List<Price_List__c>>();
        for (Price_List__c rec : records) {
            String key = buildCompositeKey(rec);
            if (!batchByKey.containsKey(key)) {
                batchByKey.put(key, new List<Price_List__c>());
            }
            batchByKey.get(key).add(rec);
        }

        // Validate each record
        for (Price_List__c rec : records) {
            if (rec.Effective_From__c == null) {
                rec.addError('Effective From date is required.');
                continue;
            }

            String key = buildCompositeKey(rec);

            // Check against existing database records
            if (existingByKey.containsKey(key)) {
                for (Price_List__c existing : existingByKey.get(key)) {
                    if (datesOverlap(
                        rec.Effective_From__c, rec.Effective_To__c,
                        existing.Effective_From__c, existing.Effective_To__c
                    )) {
                        rec.addError(
                            'This price list overlaps with an existing entry (ID: ' +
                            existing.Id + ') for the same Product, Customer, Category, ' +
                            'Territory, Region, and Channel combination. ' +
                            'Effective dates must not overlap.'
                        );
                        break;
                    }
                }
            }

            // Check within the batch (skip self-comparison by reference)
            if (batchByKey.containsKey(key)) {
                for (Price_List__c batchRec : batchByKey.get(key)) {
                    if (batchRec === rec) {
                        continue;
                    }
                    if (datesOverlap(
                        rec.Effective_From__c, rec.Effective_To__c,
                        batchRec.Effective_From__c, batchRec.Effective_To__c
                    )) {
                        rec.addError(
                            'Multiple price list entries in this batch overlap for the ' +
                            'same Product, Customer, Category, Territory, Region, ' +
                            'and Channel combination.'
                        );
                        break;
                    }
                }
            }
        }
    }

    /**
     * @description Builds a composite key from all dimension fields.
     * @param rec The Price_List__c record.
     * @return A pipe-delimited composite key string.
     */
    private String buildCompositeKey(Price_List__c rec) {
        return String.valueOf(rec.Product_Ext__c) + '|' +
               (rec.Customer__c != null ? String.valueOf(rec.Customer__c) : '') + '|' +
               (rec.Category__c != null ? String.valueOf(rec.Category__c) : '') + '|' +
               (rec.Territory__c != null ? String.valueOf(rec.Territory__c) : '') + '|' +
               (rec.Region__c != null ? String.valueOf(rec.Region__c) : '') + '|' +
               (String.isNotBlank(rec.Channel__c) ? rec.Channel__c : '');
    }

    /**
     * @description Determines whether two date ranges overlap. Handles open-ended
     *              ranges (null end dates treated as indefinite future).
     * @param start1 First range start date.
     * @param end1   First range end date (null = indefinite).
     * @param start2 Second range start date.
     * @param end2   Second range end date (null = indefinite).
     * @return True if the ranges overlap.
     */
    private Boolean datesOverlap(Date start1, Date end1, Date start2, Date end2) {
        Date effectiveEnd1 = end1 != null ? end1 : Date.newInstance(9999, 12, 31);
        Date effectiveEnd2 = end2 != null ? end2 : Date.newInstance(9999, 12, 31);
        return start1 <= effectiveEnd2 && start2 <= effectiveEnd1;
    }

    /**
     * @description Creates Price_Change_Log__c records for any price changes
     *              detected during update operations. Now includes Customer,
     *              Category, Territory, and Priority context.
     * @param newRecords The updated records.
     * @param oldMap     Map of old record values keyed by Id.
     */
    private void logPriceChanges(
        List<Price_List__c> newRecords,
        Map<Id, Price_List__c> oldMap
    ) {
        List<Price_Change_Log__c> logs = new List<Price_Change_Log__c>();

        for (Price_List__c rec : newRecords) {
            Price_List__c oldRec = oldMap.get(rec.Id);

            if (rec.Unit_Price__c != oldRec.Unit_Price__c) {
                logs.add(new Price_Change_Log__c(
                    Price_List__c   = rec.Id,
                    Product_Ext__c  = rec.Product_Ext__c,
                    Old_Price__c    = oldRec.Unit_Price__c,
                    New_Price__c    = rec.Unit_Price__c,
                    Changed_By__c   = UserInfo.getUserId(),
                    Change_Date__c  = Datetime.now(),
                    Region__c       = rec.Region__c,
                    Channel__c      = rec.Channel__c,
                    Customer__c     = rec.Customer__c,
                    Category__c     = rec.Category__c,
                    Territory__c    = rec.Territory__c,
                    Priority__c     = rec.Priority__c,
                    Change_Reason__c = 'Price updated via Price List modification'
                ));
            }
        }

        if (!logs.isEmpty()) {
            insert logs;
        }
    }
}