/**
 * @description Tests for DMS_Constants.
 *
 * A constants class has nothing to execute, so this is not a coverage test —
 * `public static final String X = 'literal'` compiles to a constant and the
 * private constructor cannot be called from outside the class. What these
 * tests do is guard the *wiring*: every constant here is a key into something
 * that lives outside Apex — a Feature_Toggle__mdt record, an Account record
 * type, or a picklist value — and none of those links is checked by the
 * compiler.
 *
 * That matters because the failure is silent. A toggle code with no matching
 * metadata record makes BPM_FeatureToggle_Util return false, quietly disabling
 * the feature. A status constant that is not a real picklist value never
 * matches in a comparison, and fails at runtime if it is ever assigned to a
 * restricted picklist. Both look like "the feature just doesn't work" rather
 * than like an error.
 */
@isTest
private class DMS_Constants_Test {

    /** Active picklist values for a field, by API value. */
    private static Set<String> activeValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) values.add(entry.getValue());
        }
        return values;
    }

    /** Asserts every constant is a live picklist value, naming any that are not. */
    private static void assertAllArePicklistValues(
            String fieldLabel, Schema.SObjectField field, Map<String, String> constantsByName) {
        Set<String> valid = activeValues(field);
        List<String> broken = new List<String>();
        for (String constantName : constantsByName.keySet()) {
            if (!valid.contains(constantsByName.get(constantName))) {
                broken.add(constantName + ' = "' + constantsByName.get(constantName) + '"');
            }
        }
        System.assert(broken.isEmpty(),
            fieldLabel + ' has no such value for: ' + String.join(broken, ', ')
            + '. Valid values are: ' + String.join(new List<String>(valid), ', '));
    }

    // ── Feature toggles ───────────────────────────────────────────────

    @isTest
    static void everyToggleCodeResolvesToAMetadataRecord() {
        Map<String, String> codesByName = new Map<String, String>{
            'TOGGLE_MASTER'              => DMS_Constants.TOGGLE_MASTER,
            'TOGGLE_STOCK_ACTIVITIES'    => DMS_Constants.TOGGLE_STOCK_ACTIVITIES,
            'TOGGLE_PRIMARY_FULFILLMENT' => DMS_Constants.TOGGLE_PRIMARY_FULFILLMENT,
            'TOGGLE_NORMS_REPLENISH'     => DMS_Constants.TOGGLE_NORMS_REPLENISH,
            'TOGGLE_FEFO_EXPIRY'         => DMS_Constants.TOGGLE_FEFO_EXPIRY,
            'TOGGLE_SECONDARY_BILLING'   => DMS_Constants.TOGGLE_SECONDARY_BILLING,
            'TOGGLE_SCHEME_CLAIM'        => DMS_Constants.TOGGLE_SCHEME_CLAIM,
            'TOGGLE_LEDGER_AGING'        => DMS_Constants.TOGGLE_LEDGER_AGING,
            'TOGGLE_CREDIT_ENFORCEMENT'  => DMS_Constants.TOGGLE_CREDIT_ENFORCEMENT,
            'TOGGLE_PORTAL'              => DMS_Constants.TOGGLE_PORTAL,
            'TOGGLE_RETURNS'             => DMS_Constants.TOGGLE_RETURNS,
            'TOGGLE_P2_FULFILLMENT'      => DMS_Constants.TOGGLE_P2_FULFILLMENT,
            'TOGGLE_INVOICE_LEDGER'      => DMS_Constants.TOGGLE_INVOICE_LEDGER,
            'TOGGLE_LEGACY_INDENT_FULFILLMENT' => DMS_Constants.TOGGLE_LEGACY_INDENT_FULFILLMENT,
            'TOGGLE_DEMO_TOOLS'          => DMS_Constants.TOGGLE_DEMO_TOOLS
        };

        Test.startTest();
        Set<String> known = new Set<String>();
        for (Feature_Toggle__mdt t : [
            SELECT Feature_Code__c FROM Feature_Toggle__mdt
            WHERE Feature_Code__c IN :codesByName.values()
        ]) {
            known.add(t.Feature_Code__c);
        }
        Test.stopTest();

        List<String> missing = new List<String>();
        for (String name : codesByName.keySet()) {
            if (!known.contains(codesByName.get(name))) {
                missing.add(name + ' (' + codesByName.get(name) + ')');
            }
        }
        System.assert(missing.isEmpty(),
            'These toggle codes have no Feature_Toggle__mdt record, so the features they gate '
            + 'are silently off: ' + String.join(missing, ', '));
    }

    @isTest
    static void toggleCodesAreUnique() {
        List<String> allCodes = new List<String>{
            DMS_Constants.TOGGLE_MASTER, DMS_Constants.TOGGLE_STOCK_ACTIVITIES,
            DMS_Constants.TOGGLE_PRIMARY_FULFILLMENT, DMS_Constants.TOGGLE_NORMS_REPLENISH,
            DMS_Constants.TOGGLE_FEFO_EXPIRY, DMS_Constants.TOGGLE_SECONDARY_BILLING,
            DMS_Constants.TOGGLE_SCHEME_CLAIM, DMS_Constants.TOGGLE_LEDGER_AGING,
            DMS_Constants.TOGGLE_CREDIT_ENFORCEMENT, DMS_Constants.TOGGLE_PORTAL,
            DMS_Constants.TOGGLE_RETURNS, DMS_Constants.TOGGLE_P2_FULFILLMENT,
            DMS_Constants.TOGGLE_INVOICE_LEDGER, DMS_Constants.TOGGLE_LEGACY_INDENT_FULFILLMENT,
            DMS_Constants.TOGGLE_DEMO_TOOLS
        };

        Test.startTest();
        Set<String> unique = new Set<String>(allCodes);
        Test.stopTest();

        System.assertEquals(allCodes.size(), unique.size(),
            'Two constants share a toggle code — a copy-paste slip here makes one feature '
            + 'silently follow another feature switch');
    }

    // ── Account record types ──────────────────────────────────────────

    @isTest
    static void distributorRecordTypeNamesExist() {
        Test.startTest();
        Map<String, Schema.RecordTypeInfo> byName =
            Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
        Test.stopTest();

        for (String devName : new List<String>{
                DMS_Constants.RT_DISTRIBUTOR,
                DMS_Constants.RT_SUPER_STOCKIST,
                DMS_Constants.RT_RETAILER }) {
            System.assert(byName.containsKey(devName),
                'Account has no record type with developer name "' + devName
                + '" — any code selecting on it finds nothing');
        }
    }

    // ── Picklist-backed constants ─────────────────────────────────────

    @isTest
    static void stockTransactionConstantsAreRealPicklistValues() {
        Test.startTest();
        assertAllArePicklistValues('Stock_Transaction__c.Direction__c',
            Stock_Transaction__c.Direction__c,
            new Map<String, String>{
                'DIRECTION_IN'  => DMS_Constants.DIRECTION_IN,
                'DIRECTION_OUT' => DMS_Constants.DIRECTION_OUT
            });

        assertAllArePicklistValues('Stock_Transaction__c.Transaction_Type__c',
            Stock_Transaction__c.Transaction_Type__c,
            new Map<String, String>{
                'TXN_INBOUND_GRN'       => DMS_Constants.TXN_INBOUND_GRN,
                'TXN_OUTBOUND_DISPATCH' => DMS_Constants.TXN_OUTBOUND_DISPATCH,
                'TXN_ADJUSTMENT_ADD'    => DMS_Constants.TXN_ADJUSTMENT_ADD,
                'TXN_ADJUSTMENT_DEDUCT' => DMS_Constants.TXN_ADJUSTMENT_DEDUCT
            });
        Test.stopTest();
    }

    @isTest
    static void stockAdjustmentConstantsAreRealPicklistValues() {
        Test.startTest();
        assertAllArePicklistValues('Stock_Adjustment__c.Location_Type__c',
            Stock_Adjustment__c.Location_Type__c,
            new Map<String, String>{
                'LOCATION_WAREHOUSE'   => DMS_Constants.LOCATION_WAREHOUSE,
                'LOCATION_DISTRIBUTOR' => DMS_Constants.LOCATION_DISTRIBUTOR
            });

        assertAllArePicklistValues('Stock_Adjustment__c.Status__c',
            Stock_Adjustment__c.Status__c,
            new Map<String, String>{ 'ADJ_APPROVED' => DMS_Constants.ADJ_APPROVED });
        Test.stopTest();
    }

    @isTest
    static void schemeAccrualStatusConstantsAreRealPicklistValues() {
        Test.startTest();
        assertAllArePicklistValues('Scheme_Accrual__c.Status__c',
            Scheme_Accrual__c.Status__c,
            new Map<String, String>{
                'ACCRUAL_OPEN'     => DMS_Constants.ACCRUAL_OPEN,
                'ACCRUAL_CLAIMED'  => DMS_Constants.ACCRUAL_CLAIMED,
                'ACCRUAL_SETTLED'  => DMS_Constants.ACCRUAL_SETTLED,
                'ACCRUAL_REVERSED' => DMS_Constants.ACCRUAL_REVERSED
            });
        Test.stopTest();
    }

    @isTest
    static void returnTypeConstantsAreRealPicklistValues() {
        Test.startTest();
        assertAllArePicklistValues('Return_Order__c.Return_Type__c',
            Return_Order__c.Return_Type__c,
            new Map<String, String>{
                'RETURN_TYPE_PRIMARY'   => DMS_Constants.RETURN_TYPE_PRIMARY,
                'RETURN_TYPE_SECONDARY' => DMS_Constants.RETURN_TYPE_SECONDARY
            });
        Test.stopTest();
    }

    /**
     * Indent__c.Status__c is a restricted picklist, so a constant that is not
     * one of its values can never be assigned and never matches a comparison.
     *
     * INDENT_CLOSED ('Closed') and INDENT_REJECTED ('Rejected') are deliberately
     * excluded below: neither value exists on the picklist. Both constants are
     * currently unused, so nothing is broken today, but the first caller to use
     * one gets a silent never-match — or a DML failure on assignment. Either add
     * the picklist values or delete the constants; this test should then be
     * extended to cover them.
     */
    @isTest
    static void indentStatusConstantsAreRealPicklistValues() {
        Test.startTest();
        assertAllArePicklistValues('Indent__c.Status__c',
            Indent__c.Status__c,
            new Map<String, String>{
                'INDENT_DRAFT'      => DMS_Constants.INDENT_DRAFT,
                'INDENT_SUBMITTED'  => DMS_Constants.INDENT_SUBMITTED,
                'INDENT_APPROVED'   => DMS_Constants.INDENT_APPROVED,
                'INDENT_DISPATCHED' => DMS_Constants.INDENT_DISPATCHED,
                'INDENT_RECEIVED'   => DMS_Constants.INDENT_RECEIVED,
                'INDENT_CANCELLED'  => DMS_Constants.INDENT_CANCELLED
            });
        Test.stopTest();
    }

    // ── Plain value constants ─────────────────────────────────────────

    @isTest
    static void indentTierAndOrderTypeConstantsHoldTheirWireValues() {
        // These are compared against text/formula fields rather than picklists,
        // so there is no schema to check them against — but they are written
        // into records the portal and reporting read back, so a change to the
        // literal is a data-format change, not a rename.
        Test.startTest();
        System.assertEquals('P1', DMS_Constants.INDENT_TYPE_P1, 'P1 tier marker');
        System.assertEquals('P2', DMS_Constants.INDENT_TYPE_P2, 'P2 tier marker');
        System.assertEquals('Primary', DMS_Constants.ORDER_TYPE_PRIMARY, 'Primary order marker');
        System.assertEquals('P2', DMS_Constants.ORDER_TYPE_P2, 'P2 order marker');
        System.assertEquals('Secondary', DMS_Constants.ORDER_TYPE_SECONDARY, 'Secondary order marker');
        Test.stopTest();
    }
}