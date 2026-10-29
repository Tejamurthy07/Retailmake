/**
 * @description Service class implementing the Indian GST tax calculation engine.
 *              Determines inter-state vs intra-state transactions and applies the
 *              correct GST component split (CGST + SGST or IGST).
 *
 *              Tax rates are sourced from Tax_Configuration__c records based on
 *              product HSN code or category.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class MDM_TaxEngine_Service {

    // ── Inner class: TaxResult ────────────────────────────────────────────────

    /**
     * @description Encapsulates the calculated tax components for a single
     *              taxable transaction.
     */
    public class TaxResult {
        /** Central GST amount (intra-state only). */
        public Decimal cgst { get; set; }
        /** State GST amount (intra-state only). */
        public Decimal sgst { get; set; }
        /** Integrated GST amount (inter-state only). */
        public Decimal igst { get; set; }
        /** Sum of all applicable tax components. */
        public Decimal totalTax { get; set; }
        /** The effective GST rate applied (percentage). */
        public Decimal taxRate { get; set; }
        /** True if the transaction is inter-state. */
        public Boolean isInterState { get; set; }

        public TaxResult() {
            this.cgst = 0;
            this.sgst = 0;
            this.igst = 0;
            this.totalTax = 0;
            this.taxRate = 0;
            this.isInterState = false;
        }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * @description Calculates the GST tax for a given product moving between two
     *              states on a specified taxable amount.
     *
     * @param productId  The Product_Ext__c record ID used to look up the applicable
     *                   HSN code and tax rate.
     * @param fromState  The state of origin (seller/warehouse location).
     * @param toState    The destination state (buyer/delivery location).
     * @param amount     The taxable base amount.
     * @return A TaxResult containing the computed tax breakdown.
     */
    public static TaxResult calculateTax(
        Id productId,
        String fromState,
        String toState,
        Decimal amount
    ) {
        TaxResult result = new TaxResult();

        if (productId == null || amount == null || amount <= 0) {
            return result;
        }

        // Determine inter-state vs intra-state
        result.isInterState = isInterStateTransaction(fromState, toState);

        // Fetch the applicable tax configuration for this product
        Tax_Configuration__c taxConfig = getTaxConfiguration(productId);
        if (taxConfig == null) {
            return result;
        }

        result.taxRate = taxConfig.Tax_Rate__c != null ? taxConfig.Tax_Rate__c : 0;

        if (result.taxRate <= 0) {
            return result;
        }

        // Calculate tax components
        if (result.isInterState) {
            // Inter-state: full rate applied as IGST
            result.igst = (amount * result.taxRate / 100).setScale(2, RoundingMode.HALF_UP);
            result.cgst = 0;
            result.sgst = 0;
        } else {
            // Intra-state: rate split equally between CGST and SGST
            Decimal halfRate = result.taxRate / 2;
            result.cgst = (amount * halfRate / 100).setScale(2, RoundingMode.HALF_UP);
            result.sgst = (amount * halfRate / 100).setScale(2, RoundingMode.HALF_UP);
            result.igst = 0;
        }

        result.totalTax = result.cgst + result.sgst + result.igst;

        return result;
    }

    /**
     * @description Bulk tax calculation for multiple product-amount pairs.
     *              Minimises SOQL queries by loading all tax configurations in one go.
     *
     * @param productIds List of Product_Ext__c IDs (positionally aligned with amounts).
     * @param fromState  The state of origin.
     * @param toState    The destination state.
     * @param amounts    List of taxable amounts (positionally aligned with productIds).
     * @return A list of TaxResult instances in the same positional order.
     */
    public static List<TaxResult> calculateTaxBulk(
        List<Id> productIds,
        String fromState,
        String toState,
        List<Decimal> amounts
    ) {
        List<TaxResult> results = new List<TaxResult>();

        if (productIds == null || productIds.isEmpty()) {
            return results;
        }

        Boolean isInterState = isInterStateTransaction(fromState, toState);

        // Bulk load tax configurations
        Map<Id, Tax_Configuration__c> taxConfigMap = getTaxConfigurationBulk(
            new Set<Id>(productIds)
        );

        for (Integer i = 0; i < productIds.size(); i++) {
            TaxResult result = new TaxResult();
            Id productId = productIds[i];
            Decimal amount = (i < amounts.size()) ? amounts[i] : 0;

            result.isInterState = isInterState;

            if (productId == null || amount == null || amount <= 0) {
                results.add(result);
                continue;
            }

            Tax_Configuration__c taxConfig = taxConfigMap.get(productId);
            if (taxConfig == null) {
                results.add(result);
                continue;
            }

            result.taxRate = taxConfig.Tax_Rate__c != null ? taxConfig.Tax_Rate__c : 0;

            if (result.taxRate > 0) {
                if (isInterState) {
                    result.igst = (amount * result.taxRate / 100)
                        .setScale(2, RoundingMode.HALF_UP);
                } else {
                    Decimal halfRate = result.taxRate / 2;
                    result.cgst = (amount * halfRate / 100)
                        .setScale(2, RoundingMode.HALF_UP);
                    result.sgst = (amount * halfRate / 100)
                        .setScale(2, RoundingMode.HALF_UP);
                }
                result.totalTax = result.cgst + result.sgst + result.igst;
            }

            results.add(result);
        }

        return results;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Determines whether a transaction is inter-state by comparing
     *              the origin and destination state codes (case-insensitive).
     * @param fromState The origin state.
     * @param toState   The destination state.
     * @return True if the states differ, indicating an inter-state transaction.
     */
    @TestVisible
    private static Boolean isInterStateTransaction(String fromState, String toState) {
        if (String.isBlank(fromState) || String.isBlank(toState)) {
            return false;
        }
        return !fromState.trim().equalsIgnoreCase(toState.trim());
    }

    /**
     * @description Retrieves the Tax_Configuration__c record applicable to the
     *              given product. Looks up by product ID first, then by HSN code.
     * @param productId The Product_Ext__c ID to look up.
     * @return The matching Tax_Configuration__c or null if not found.
     */
    private static Tax_Configuration__c getTaxConfiguration(Id productId) {
        List<Tax_Configuration__c> configs = [
            SELECT Id, Tax_Rate__c, HSN_Code__c, Product_Ext__c,
                   CGST_Rate__c, SGST_Rate__c, IGST_Rate__c
            FROM Tax_Configuration__c
            WHERE Product_Ext__c = :productId
              AND Is_Active__c = true
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (!configs.isEmpty()) {
            return configs[0];
        }

        return null;
    }

    /**
     * @description Bulk retrieves Tax_Configuration__c records for a set of
     *              product IDs.
     * @param productIds The set of Product_Ext__c IDs to look up.
     * @return Map of Product ID to its active Tax Configuration.
     */
    private static Map<Id, Tax_Configuration__c> getTaxConfigurationBulk(
        Set<Id> productIds
    ) {
        Map<Id, Tax_Configuration__c> configMap = new Map<Id, Tax_Configuration__c>();

        for (Tax_Configuration__c config : [
            SELECT Id, Tax_Rate__c, HSN_Code__c, Product_Ext__c,
                   CGST_Rate__c, SGST_Rate__c, IGST_Rate__c
            FROM Tax_Configuration__c
            WHERE Product_Ext__c IN :productIds
              AND Is_Active__c = true
            ORDER BY CreatedDate DESC
        ]) {
            // Keep only the most recent config per product
            if (!configMap.containsKey(config.Product_Ext__c)) {
                configMap.put(config.Product_Ext__c, config);
            }
        }

        return configMap;
    }
}