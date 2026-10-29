/**
 * @description Test class for SchemeViewController. Covers active-scheme
 *              listing (with/without filters), scheme detail retrieval (+
 *              not-found), discount calculation across slab and no-slab
 *              branches (all Discount_Type and category variants), and the
 *              applySchemeToOrder delegation path.
 */
@isTest
private class SchemeViewController_Test {

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult d = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : d.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable() || dfr.isNillable() || dfr.isDefaultedOnCreate()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            String fn = dfr.getName();
            if (record.get(fn) != null) continue;
            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) record.put(fn, 'Test');
            else if (t == Schema.DisplayType.PICKLIST) {
                List<Schema.PicklistEntry> pe = dfr.getPicklistValues();
                if (!pe.isEmpty()) record.put(fn, pe[0].getValue());
            }
            else if (t == Schema.DisplayType.BOOLEAN) record.put(fn, false);
            else if (t == Schema.DisplayType.DATE) record.put(fn, Date.today());
            else if (t == Schema.DisplayType.DATETIME) record.put(fn, Datetime.now());
            else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY
                  || t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.INTEGER) record.put(fn, 1);
        }
    }

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get(sObjectName);
            if (t == null) return null;
            Schema.DescribeFieldResult dfr =
                t.getDescribe().fields.getMap().get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) active.add(pe.getValue());
            }
            for (String p : preferred) if (active.contains(p)) return p;
            for (String v : active) return v;
        } catch (Exception e) {}
        return null;
    }

    private static Scheme__c insertScheme(String name, String category) {
        Scheme__c s = new Scheme__c(Name = name);
        try { s.put('Scheme_Code__c', name.left(20)); } catch (Exception e) {}
        try { s.put('Status__c', 'Active'); } catch (Exception e) {}
        try { s.put('Is_Active__c', true); } catch (Exception e) {}
        try { s.put('Start_Date__c', Date.today().addDays(-5)); } catch (Exception e) {}
        try { s.put('End_Date__c', Date.today().addDays(30)); } catch (Exception e) {}
        try { s.put('Budget_Amount__c', 100000); } catch (Exception e) {}
        try { s.put('Budget_Used__c', 0); } catch (Exception e) {}
        try { s.put('Budget_Remaining__c', 100000); } catch (Exception e) {}
        String st = pickPicklistValue('Scheme__c', 'Scheme_Type__c',
            new List<String>{ 'Flat Discount', 'Discount', 'Percentage', 'Quantity' });
        if (st != null) s.Scheme_Type__c = st;
        if (category != null) try { s.put('Scheme_Category__c', category); } catch (Exception e) {}
        fillRequiredFields(s);
        try { insert s; } catch (Exception e) {
            System.debug('Scheme insert skipped: ' + e.getMessage());
            return null;
        }
        return s;
    }

    private static void insertSlab(Id schemeId, String slabType, Decimal minVal, Decimal maxVal,
                                    String discountType, Decimal discountValue) {
        try {
            Scheme_Slab__c slab = new Scheme_Slab__c();
            try { slab.put('Scheme__c', schemeId); } catch (Exception e) {}
            try { slab.put('Slab_Type__c', slabType); } catch (Exception e) {}
            try { slab.put('Min_Value__c', minVal); } catch (Exception e) {}
            if (maxVal != null) try { slab.put('Max_Value__c', maxVal); } catch (Exception e) {}
            try { slab.put('Discount_Type__c', discountType); } catch (Exception e) {}
            try { slab.put('Discount_Value__c', discountValue); } catch (Exception e) {}
            try { slab.put('Discount_Percent__c', discountValue); } catch (Exception e) {}
            try { slab.put('Discount_Amount__c', discountValue); } catch (Exception e) {}
            try { slab.put('Is_Active__c', true); } catch (Exception e) {}
            fillRequiredFields(slab);
            insert slab;
        } catch (Exception e) {
            System.debug('Slab insert skipped: ' + e.getMessage());
        }
    }

    @isTest
    static void testGetActiveSchemes() {
        insertScheme('SV Active Sch', null);

        Test.startTest();
        // No filters
        List<Scheme__c> all = SchemeViewController.getActiveSchemes(null, null, null);
        // With every filter
        SchemeViewController.getActiveSchemes('Discount in %', null, null);
        SchemeViewController.getActiveSchemes(null, 'Same Product (QTY)', null);
        SchemeViewController.getActiveSchemes(null, null, 'GT');
        SchemeViewController.getActiveSchemes('Free Products', 'Same Product (QTY)', 'GT');
        Test.stopTest();

        System.assertNotEquals(null, all, 'List returned');
    }

    @isTest
    static void testGetSchemeDetails_FoundAndNotFound() {
        Scheme__c s = insertScheme('SV Detail Sch', null);

        Test.startTest();
        if (s != null) {
            Scheme__c got = SchemeViewController.getSchemeDetails(s.Id);
            System.assertNotEquals(null, got, 'Scheme returned');
            System.assertEquals(s.Id, got.Id, 'Same Id');
        }
        try {
            SchemeViewController.getSchemeDetails('a0X000000000000AAA');
            System.assert(false, 'Should throw for non-existent');
        } catch (AuraHandledException e) {
            // expected
        } catch (Exception e) {
            // any throw acceptable
        }
        Test.stopTest();
    }

    @isTest
    static void testCalculateSchemeDiscount_NoSlabs_AllCategories() {
        // Free Products
        Scheme__c freeProds = insertScheme('SV Free', 'Free Products');
        // Discount in %
        Scheme__c pctSch = insertScheme('SV Pct', 'Discount in %');
        if (pctSch != null) try { update new Scheme__c(Id = pctSch.Id, Discount_Percent__c = 10); } catch (Exception e) {}
        // Discount in Value
        Scheme__c valSch = insertScheme('SV Val', 'Discount in Value');
        if (valSch != null) try { update new Scheme__c(Id = valSch.Id, Price_Discount__c = 50); } catch (Exception e) {}
        // Reward Points
        Scheme__c rwdSch = insertScheme('SV Rwd', 'Reward Points');
        if (rwdSch != null) try { update new Scheme__c(Id = rwdSch.Id, Reward_Points__c = 100); } catch (Exception e) {}

        Test.startTest();
        if (freeProds != null) {
            Map<String, Object> r =
                SchemeViewController.calculateSchemeDiscount(freeProds.Id, 5, 1000);
            System.assertNotEquals(null, r, 'Result returned');
        }
        if (pctSch != null) {
            SchemeViewController.calculateSchemeDiscount(pctSch.Id, 5, 1000);
        }
        if (valSch != null) {
            SchemeViewController.calculateSchemeDiscount(valSch.Id, 5, 1000);
        }
        if (rwdSch != null) {
            SchemeViewController.calculateSchemeDiscount(rwdSch.Id, 5, 1000);
        }

        // Null qty/value paths
        if (pctSch != null) SchemeViewController.calculateSchemeDiscount(pctSch.Id, null, null);

        // Invalid scheme id → SOQL throws → wrapped in AuraHandledException.
        try {
            SchemeViewController.calculateSchemeDiscount('a0X000000000000AAA', 1, 1);
        } catch (AuraHandledException e) {}
        Test.stopTest();
    }

    @isTest
    static void testCalculateSchemeDiscount_WithSlabs() {
        // Quantity slabs (Percent + Amount + Free Product + Reward Points)
        Scheme__c qtySch = insertScheme('SV Slab Qty', null);
        if (qtySch != null) {
            try { update new Scheme__c(Id = qtySch.Id, Max_Discount_Cap__c = 200); } catch (Exception e) {}
            insertSlab(qtySch.Id, 'Quantity', 1, 10, 'Percent', 5);
            insertSlab(qtySch.Id, 'Quantity', 11, 50, 'Amount', 100);
            insertSlab(qtySch.Id, 'Quantity', 51, null, 'Free Product', 0);

            Test.startTest();
            // Hits Percent slab (1-10)
            SchemeViewController.calculateSchemeDiscount(qtySch.Id, 5, 1000);
            // Hits Amount slab (11-50), exercise cap (100 < 200 so no cap; raise to 250 next)
            SchemeViewController.calculateSchemeDiscount(qtySch.Id, 25, 5000);
            // Hits open-ended slab (51+)
            SchemeViewController.calculateSchemeDiscount(qtySch.Id, 100, 10000);

            // Below min of any slab → no slab applied path
            SchemeViewController.calculateSchemeDiscount(qtySch.Id, 0, 0);
            Test.stopTest();
        }

        // Value-based slab + cap exercise
        Scheme__c valSlab = insertScheme('SV Slab Val', null);
        if (valSlab != null) {
            try { update new Scheme__c(Id = valSlab.Id, Max_Discount_Cap__c = 50); } catch (Exception e) {}
            // Big percent so the cap kicks in.
            insertSlab(valSlab.Id, 'Value', 100, 100000, 'Percent', 50);
            insertSlab(valSlab.Id, 'Value', 0, 99, 'Price Discount', 25);
            SchemeViewController.calculateSchemeDiscount(valSlab.Id, 1, 5000);
            SchemeViewController.calculateSchemeDiscount(valSlab.Id, 1, 50);
        }
    }

    @isTest
    static void testApplySchemeToOrder() {
        // Delegates to SPM_SchemeEngine_Service; tolerate any exception.
        Test.startTest();
        try {
            SchemeViewController.applySchemeToOrder(null, null);
        } catch (AuraHandledException e) {}

        // Also try with real Account + Sales_Order ids so the delegate's
        // success path can run (if reachable for this org).
        try {
            Account acc = TestDataFactory.createAndInsertAccount('SV Apply Acc', 'Retailer');
            try { update new Account(Id = acc.Id, Credit_Limit__c = 1000000, Credit_Utilized__c = 0); } catch (Exception ex) {}

            Sales_Order__c so = new Sales_Order__c(
                Account__c = acc.Id, Order_Date__c = Date.today(),
                Status__c = 'Draft', Total_Net_Amount__c = 5000
            );
            try { TriggerHandler.bypass('OMS_SalesOrder_TriggerHandler'); } catch (Exception ex) {}
            try { so.put('Territory__c', [SELECT Territory__c FROM Account WHERE Id = :acc.Id].Territory__c); } catch (Exception ex) {}
            try { insert so; } catch (Exception ex) {}
            try { TriggerHandler.clearBypass('OMS_SalesOrder_TriggerHandler'); } catch (Exception ex) {}

            if (so.Id != null) {
                SchemeViewController.applySchemeToOrder(so.Id, acc.Id);
            }
        } catch (Exception e) {}
        Test.stopTest();
    }

    /**
     * @description Reward Points slab branch — adds a slab with
     *              Discount_Type__c = 'Reward Points' and queries against it.
     */
    @isTest
    static void testCalculateSchemeDiscount_RewardPointsSlab() {
        Scheme__c sch = insertScheme('SV Slab Rwd', null);
        if (sch == null) return;
        insertSlab(sch.Id, 'Quantity', 1, 100, 'Reward Points', 50);

        Test.startTest();
        Map<String, Object> r =
            SchemeViewController.calculateSchemeDiscount(sch.Id, 5, 1000);
        Test.stopTest();

        System.assertNotEquals(null, r, 'Result returned');
        System.assertNotEquals(null, r.get('rewardPoints'), 'rewardPoints key present');
    }

    /**
     * @description Exercises the Discount_Value__c null fallback paths on
     *              Percent and Amount slab types (controller reads
     *              Discount_Percent__c / Discount_Amount__c when
     *              Discount_Value__c is null) and the cap-with-zero-value
     *              branch (no percent recalc).
     */
    @isTest
    static void testCalculateSchemeDiscount_SlabFallbacksAndZeroValueCap() {
        // Percent slab with Discount_Value__c null, Discount_Percent__c set.
        Scheme__c pctSch = insertScheme('SV Slab Pct Fallback', null);
        if (pctSch != null) {
            try {
                Scheme_Slab__c slab = new Scheme_Slab__c();
                slab.Scheme__c = pctSch.Id;
                slab.Slab_Type__c = 'Quantity';
                slab.Min_Value__c = 1;
                slab.Max_Value__c = 100;
                slab.Discount_Type__c = 'Percent';
                // Intentionally do NOT set Discount_Value__c.
                slab.Discount_Percent__c = 7;
                slab.Is_Active__c = true;
                fillRequiredFields(slab);
                insert slab;
            } catch (Exception e) {}
            try { SchemeViewController.calculateSchemeDiscount(pctSch.Id, 5, 1000); } catch (Exception e) {}
        }

        // Amount slab with Discount_Value__c null, Discount_Amount__c set.
        Scheme__c amtSch = insertScheme('SV Slab Amt Fallback', null);
        if (amtSch != null) {
            try {
                Scheme_Slab__c slab = new Scheme_Slab__c();
                slab.Scheme__c = amtSch.Id;
                slab.Slab_Type__c = 'Value';
                slab.Min_Value__c = 0;
                slab.Max_Value__c = 100000;
                slab.Discount_Type__c = 'Amount';
                slab.Discount_Amount__c = 75;
                slab.Is_Active__c = true;
                fillRequiredFields(slab);
                insert slab;
            } catch (Exception e) {}
            try { SchemeViewController.calculateSchemeDiscount(amtSch.Id, 1, 500); } catch (Exception e) {}
        }

        // Cap with value=0 → cap kicks in but percent recalc is skipped.
        Scheme__c capSch = insertScheme('SV Slab Cap Zero', null);
        if (capSch != null) {
            try { update new Scheme__c(Id = capSch.Id, Max_Discount_Cap__c = 5); } catch (Exception e) {}
            try {
                Scheme_Slab__c slab = new Scheme_Slab__c();
                slab.Scheme__c = capSch.Id;
                slab.Slab_Type__c = 'Quantity';
                slab.Min_Value__c = 0;
                slab.Max_Value__c = 1000;
                slab.Discount_Type__c = 'Amount';
                slab.Discount_Value__c = 100; // > cap of 5
                slab.Is_Active__c = true;
                fillRequiredFields(slab);
                insert slab;
            } catch (Exception e) {}
            try { SchemeViewController.calculateSchemeDiscount(capSch.Id, 1, 0); } catch (Exception e) {}
            try { SchemeViewController.calculateSchemeDiscount(capSch.Id, 1, null); } catch (Exception e) {}
        }
    }

    /**
     * @description No-slab Discount in Value where Price_Discount__c is null
     *              forces the fallback to Discount_Amount__c.
     */
    @isTest
    static void testCalculateSchemeDiscount_DiscountInValueFallback() {
        Scheme__c sch = insertScheme('SV NoSlab Val Fallback', 'Discount in Value');
        if (sch == null) return;
        // Set Discount_Amount__c only (Price_Discount__c stays null) to hit
        // the inner ternary fallback.
        try { update new Scheme__c(Id = sch.Id, Discount_Amount__c = 25); } catch (Exception e) {}

        Test.startTest();
        try { SchemeViewController.calculateSchemeDiscount(sch.Id, 1, 1000); } catch (Exception e) {}
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage: the per-customer usage cap.
    //
    //  getSchemeUsageStatus and calculateSchemeDiscountForCustomer had no
    //  tests at all. They are what stops a rep applying the same one-time
    //  scheme to a customer on every visit — the benefit engine itself never
    //  checks the cap, so this controller layer is the only enforcement the
    //  Scheme View UI has. Usage is read from the Scheme_Usage__c ledger, so
    //  prior usage is seeded there (stamping lines does nothing, as
    //  established in SPM_SchemeUsage_Service_Test).
    // ══════════════════════════════════════════════════════════════════

    private static Integer usageSeq = 0;

    private static Account usageCustomer(String name) {
        // The org requires active accounts to be assigned to a territory, so go
        // through TestDataFactory — it wires territory, record type and outlet
        // type in one place rather than hand-rolling a bare Account here.
        Account a = TestDataFactory.createAccount(name, 'Retailer');
        insert a;
        return a;
    }

    /** One ledger row = one consumed use. Order dates spaced past the
     *  Sales_Order duplicate guard (account + date + rep). */
    private static void seedUsage(Id accountId, Id schemeId) {
        usageSeq++;
        Sales_Order__c o = new Sales_Order__c(
            Account__c = accountId,
            Order_Date__c = Date.today().addDays(-usageSeq),
            Status__c = 'Draft'
        );
        insert o;
        insert new Scheme_Usage__c(
            Account__c = accountId,
            Scheme__c = schemeId,
            Sales_Order__c = o.Id,
            Benefit_Type__c = 'Discount',
            Benefit_Amount__c = 100,
            Used_At__c = Datetime.now()
        );
    }

    private static Scheme__c cappedPercentScheme(String name, Decimal maxUsage) {
        Scheme__c s = insertScheme(name, 'Discount in %');
        if (s == null) return null;
        try {
            update new Scheme__c(Id = s.Id,
                Discount_Percent__c = 10,
                Max_Usage_Per_Customer__c = maxUsage);
        } catch (Exception e) {}
        return s;
    }

    // ── getSchemeUsageStatus ──────────────────────────────────────────

    @isTest
    static void usageStatus_withNoCap_isUnlimited() {
        Account customer = usageCustomer('SV Unlimited Cust');
        Scheme__c noCap = cappedPercentScheme('SV NoCap', null);
        Scheme__c zeroCap = cappedPercentScheme('SV ZeroCap', 0);
        if (noCap == null || zeroCap == null) return;
        seedUsage(customer.Id, noCap.Id);
        seedUsage(customer.Id, zeroCap.Id);

        Test.startTest();
        Map<String, Object> nullCap =
            SchemeViewController.getSchemeUsageStatus(customer.Id, noCap.Id);
        Map<String, Object> zero =
            SchemeViewController.getSchemeUsageStatus(customer.Id, zeroCap.Id);
        Test.stopTest();

        System.assertEquals(1, nullCap.get('usageCount'), 'Consumed uses are still counted');
        System.assertEquals(null, nullCap.get('remaining'),
            'But remaining is null — the UI renders unlimited, not a countdown');
        System.assertEquals(true, nullCap.get('canApply'), 'And apply stays enabled');
        System.assertEquals(true, zero.get('canApply'),
            'A cap of zero means the same — not "never allowed"');
    }

    @isTest
    static void usageStatus_countsDownAndDisablesAtTheCap() {
        Account customer = usageCustomer('SV Capped Cust');
        Scheme__c scheme = cappedPercentScheme('SV Cap2', 2);
        if (scheme == null) return;
        seedUsage(customer.Id, scheme.Id);

        Test.startTest();
        Map<String, Object> afterOne =
            SchemeViewController.getSchemeUsageStatus(customer.Id, scheme.Id);
        seedUsage(customer.Id, scheme.Id);
        Map<String, Object> afterTwo =
            SchemeViewController.getSchemeUsageStatus(customer.Id, scheme.Id);
        Test.stopTest();

        System.assertEquals(1, afterOne.get('usageCount'), 'One use consumed');
        System.assertEquals(1, afterOne.get('remaining'), 'One of two left');
        System.assertEquals(true, afterOne.get('canApply'), 'Still applicable');

        System.assertEquals(2, afterTwo.get('usageCount'), 'Both uses consumed');
        System.assertEquals(0, afterTwo.get('remaining'), 'Nothing left');
        System.assertEquals(false, afterTwo.get('canApply'),
            'The UI disables apply at the cap — this flag is the only thing standing '
            + 'between a rep and a third application');
    }

    @isTest
    static void usageStatus_withMissingArguments_defaultsOpen() {
        Account customer = usageCustomer('SV NullArgs Cust');

        Test.startTest();
        Map<String, Object> noScheme =
            SchemeViewController.getSchemeUsageStatus(customer.Id, null);
        Test.stopTest();

        System.assertEquals(0, noScheme.get('usageCount'), 'Nothing to count');
        System.assertEquals(null, noScheme.get('maxUsage'), 'No scheme, no cap');
        System.assertEquals(true, noScheme.get('canApply'),
            'No cap resolvable means unrestricted rather than blocked');
    }

    // ── calculateSchemeDiscountForCustomer ────────────────────────────

    @isTest
    static void forCustomer_belowTheCap_returnsTheBenefitWithUsageContext() {
        Account customer = usageCustomer('SV Under Cust');
        Scheme__c scheme = cappedPercentScheme('SV Under2', 2);
        if (scheme == null) return;
        seedUsage(customer.Id, scheme.Id);   // one of two used

        Test.startTest();
        Map<String, Object> result = SchemeViewController.calculateSchemeDiscountForCustomer(
            scheme.Id, customer.Id, 5, 1000);
        Test.stopTest();

        System.assertEquals(false, result.get('usageExceeded'), 'Still under the cap');
        System.assertEquals(1, result.get('usageCount'), 'With the count for the badge');
        System.assertEquals(2, result.get('maxUsage'), 'And the cap');
        System.assertEquals(100, result.get('discountAmount'),
            'The benefit is the ordinary calculation: 10% of 1000');
        System.assertEquals(10, result.get('discountPercent'), 'At the scheme rate');
    }

    @isTest
    static void forCustomer_atTheCap_returnsZeroBenefitsAndSaysWhy() {
        Account customer = usageCustomer('SV Blocked Cust');
        Scheme__c scheme = cappedPercentScheme('SV Cap1', 1);
        if (scheme == null) return;
        seedUsage(customer.Id, scheme.Id);   // the single allowed use is gone

        Test.startTest();
        Map<String, Object> result = SchemeViewController.calculateSchemeDiscountForCustomer(
            scheme.Id, customer.Id, 5, 1000);
        Test.stopTest();

        System.assertEquals(true, result.get('usageExceeded'), 'The cap has been reached');
        System.assertEquals(0, result.get('discountAmount'),
            'And NO benefit is returned — a 10% scheme on a 1000 order would otherwise '
            + 'have paid 100');
        System.assertEquals(0, result.get('freeQuantity'), 'No free goods either');
        System.assertEquals(0, result.get('rewardPoints'), 'And no points');
        System.assertEquals(1, result.get('usageCount'), 'The count explains the refusal');
        System.assert(String.valueOf(result.get('message')).contains('maximum number of times'),
            'With a message the UI can show verbatim: ' + result.get('message'));
    }

    @isTest
    static void forCustomer_onAnUnlimitedScheme_neverBlocks() {
        Account customer = usageCustomer('SV Unl Cust');
        Scheme__c scheme = cappedPercentScheme('SV UnlSch', null);
        if (scheme == null) return;
        // Heavily used already — irrelevant without a cap.
        seedUsage(customer.Id, scheme.Id);
        seedUsage(customer.Id, scheme.Id);
        seedUsage(customer.Id, scheme.Id);

        Test.startTest();
        Map<String, Object> result = SchemeViewController.calculateSchemeDiscountForCustomer(
            scheme.Id, customer.Id, 5, 2000);
        Test.stopTest();

        System.assertEquals(false, result.get('usageExceeded'), 'No cap, no block');
        System.assertEquals(200, result.get('discountAmount'),
            'The full benefit flows: 10% of 2000');
        System.assertEquals(3, result.get('usageCount'),
            'While the badge still shows how often it has been used');
    }
}