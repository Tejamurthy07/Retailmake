@isTest
private class UOM_Trigger_Test {

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult sObjDesc = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : sObjDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable()) continue;
            if (dfr.isNillable()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            if (dfr.isDefaultedOnCreate()) continue;
            String fieldName = dfr.getName();
            if (record.get(fieldName) != null) continue;
            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) {
                record.put(fieldName, 'Test');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today());
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY ||
                       t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.INTEGER ||
                       t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private static UOM__c buildUOM(String name, String code) {
        UOM__c u = new UOM__c(
            Name = name,
            Is_Active__c = true
        );
        try { u.put('UOM_Code__c', code); } catch (Exception e) {}
        try { u.put('Code__c', code); } catch (Exception e) {}
        fillRequiredFields(u);
        return u;
    }

    @isTest
    static void testInsert_AfterCacheClear() {
        // after insert hits the Trigger.isAfter branch that calls
        // UOM_Conversion_Service.clearCache.
        UOM__c u = buildUOM('UOM Insert', 'UI-001');
        Test.startTest();
        try { insert u; } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testUpdate_NoDeactivation() {
        // Update an active UOM without deactivating -> deactivatingIds is
        // empty, the referenced-uoms SOQL is skipped.
        UOM__c u = buildUOM('UOM NoDeact', 'UND-001');
        try { insert u; } catch (Exception e) { return; }

        Test.startTest();
        try {
            u.Name = 'UOM NoDeact Renamed';
            update u;
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testDeactivate_NoReferences_Succeeds() {
        UOM__c u = buildUOM('UOM Loose', 'UL-001');
        try { insert u; } catch (Exception e) { return; }

        Test.startTest();
        try {
            u.Is_Active__c = false;
            update u;
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testDiag_ConversionInsert() {
        // Loud diagnostic - surfaces what's blocking the UOM_Conversion insert.
        UOM__c uFrom = buildUOM('UOM Diag From', 'UDF-001');
        UOM__c uTo = buildUOM('UOM Diag To', 'UDT-001');
        insert new List<UOM__c>{ uFrom, uTo };

        SObjectType convT = Schema.getGlobalDescribe().get('UOM_Conversion__c');
        System.assertNotEquals(null, convT, 'UOM_Conversion__c type must exist');

        SObject conv = convT.newSObject();
        try { conv.put('From_UOM__c', uFrom.Id); } catch (Exception e) {}
        try { conv.put('To_UOM__c', uTo.Id); } catch (Exception e) {}
        try { conv.put('Conversion_Factor__c', 1); } catch (Exception e) {}
        try { conv.put('Is_Active__c', true); } catch (Exception e) {}
        fillRequiredFields(conv);
        try {
            insert conv;
        } catch (DmlException e) {
            System.assert(false, 'UOM_Conversion insert error: ' + e.getMessage());
        }
    }

    @isTest
    static void testDeactivate_WithActiveConversion_Blocked() {
        UOM__c uFrom = buildUOM('UOM From', 'UF-001');
        UOM__c uTo = buildUOM('UOM To', 'UT-001');
        try {
            insert new List<UOM__c>{ uFrom, uTo };
        } catch (Exception e) { return; }

        try {
            SObjectType convT = Schema.getGlobalDescribe().get('UOM_Conversion__c');
            if (convT != null) {
                SObject conv = convT.newSObject();
                try { conv.put('From_UOM__c', uFrom.Id); } catch (Exception e) {}
                try { conv.put('To_UOM__c', uTo.Id); } catch (Exception e) {}
                try { conv.put('Conversion_Factor__c', 1); } catch (Exception e) {}
                try { conv.put('Is_Active__c', true); } catch (Exception e) {}
                fillRequiredFields(conv);
                insert conv;
            }
        } catch (Exception e) {}

        Test.startTest();
        Boolean threw = false;
        try {
            uFrom.Is_Active__c = false;
            update uFrom;
        } catch (DmlException e) { threw = true; }
        Test.stopTest();
    }

    @isTest
    static void testAfterDelete_CacheClear() {
        UOM__c u = buildUOM('UOM Delete', 'UDEL-001');
        try { insert u; } catch (Exception e) { return; }

        Test.startTest();
        try { delete u; } catch (Exception e) {}
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage, with HARD assertions.
    //
    //  The tests above swallow every exception — the blocked-deactivation test
    //  even computes `threw` and never asserts it — so the guard this trigger
    //  exists for was unpinned in both directions. The fixtures below also set
    //  UOM_Code__c explicitly (the buildUOM helper writes the non-existent
    //  Code__c inside a try/catch, so its UOMs carry no code at all), which is
    //  what makes the cache-refresh test possible.
    // ══════════════════════════════════════════════════════════════════

    private static UOM__c codedUom(String name, String code, Boolean isBase) {
        return new UOM__c(
            Name = name, UOM_Code__c = code, Is_Active__c = true, Is_Base_Unit__c = isBase);
    }

    private static UOM_Conversion__c activeConversion(Id fromUom, Id toUom, Decimal factor) {
        return new UOM_Conversion__c(
            From_UOM__c = fromUom, To_UOM__c = toUom,
            Conversion_Factor__c = factor, Is_Active__c = true);
    }

    private static String errorsOf(Database.SaveResult sr) {
        List<String> messages = new List<String>();
        for (Database.Error e : sr.getErrors()) messages.add(e.getMessage());
        return String.join(messages, ' | ');
    }

    // ── The deactivation guard, both directions ───────────────────────

    @isTest
    static void deactivate_referencedByAnActiveConversion_isBlockedOnBothEnds() {
        UOM__c uomCase = codedUom('Guard Case', 'GD-CS', false);
        UOM__c uomPiece = codedUom('Guard Piece', 'GD-PC', true);
        insert new List<UOM__c>{ uomCase, uomPiece };
        insert activeConversion(uomCase.Id, uomPiece.Id, 12);

        Test.startTest();
        uomCase.Is_Active__c = false;
        Database.SaveResult fromSide = Database.update(uomCase, false);
        uomPiece.Is_Active__c = false;
        Database.SaveResult toSide = Database.update(uomPiece, false);
        Test.stopTest();

        System.assertEquals(false, fromSide.isSuccess(),
            'The From side of a live conversion cannot be retired — every order line still '
            + 'converting through it would break');
        System.assert(errorsOf(fromSide).contains('Cannot deactivate'),
            'With the guard message: ' + errorsOf(fromSide));
        System.assertEquals(false, toSide.isSuccess(),
            'The To side is protected the same way');
        System.assertEquals(2, [SELECT COUNT() FROM UOM__c
            WHERE Id IN (:uomCase.Id, :uomPiece.Id) AND Is_Active__c = true],
            'Both UOMs remain active');
    }

    @isTest
    static void deactivate_referencedOnlyByAnInactiveConversion_succeeds() {
        UOM__c uomCase = codedUom('Dormant Case', 'DM-CS', false);
        UOM__c uomPiece = codedUom('Dormant Piece', 'DM-PC', true);
        insert new List<UOM__c>{ uomCase, uomPiece };
        UOM_Conversion__c retired = activeConversion(uomCase.Id, uomPiece.Id, 12);
        retired.Is_Active__c = false;
        insert retired;

        Test.startTest();
        uomCase.Is_Active__c = false;
        Database.SaveResult sr = Database.update(uomCase, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'A conversion that is itself retired holds no claim — only ACTIVE rules block '
            + 'deactivation: ' + errorsOf(sr));
    }

    @isTest
    static void reactivation_isNeverTreatedAsDeactivation() {
        UOM__c dormant = codedUom('Waking UOM', 'WK-01', false);
        dormant.Is_Active__c = false;
        insert dormant;

        Test.startTest();
        dormant.Is_Active__c = true;
        Database.SaveResult sr = Database.update(dormant, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(),
            'The guard watches true -> false only; waking a UOM back up needs no check: '
            + errorsOf(sr));
    }

    @isTest
    static void bulkDeactivation_blocksOnlyTheReferencedRow() {
        UOM__c referenced = codedUom('Bulk Referenced', 'BK-RF', false);
        UOM__c loose = codedUom('Bulk Loose', 'BK-LS', false);
        UOM__c target = codedUom('Bulk Target', 'BK-TG', true);
        insert new List<UOM__c>{ referenced, loose, target };
        insert activeConversion(referenced.Id, target.Id, 6);

        Test.startTest();
        referenced.Is_Active__c = false;
        loose.Is_Active__c = false;
        List<Database.SaveResult> results =
            Database.update(new List<UOM__c>{ referenced, loose }, false);
        Test.stopTest();

        System.assertEquals(false, results[0].isSuccess(),
            'The referenced UOM is refused');
        System.assertEquals(true, results[1].isSuccess(),
            'While the unreferenced one in the same batch retires cleanly — one blocked row '
            + 'must not take the whole admin cleanup down with it: ' + errorsOf(results[1]));
    }

    // ── The after-update cache clear, observably ──────────────────────

    @isTest
    static void renamingAUomCode_refreshesTheServiceCache() {
        UOM__c uomCase = codedUom('Cache Case', 'CC-OLD', false);
        UOM__c uomPiece = codedUom('Cache Piece', 'CC-PC', true);
        insert new List<UOM__c>{ uomCase, uomPiece };
        insert activeConversion(uomCase.Id, uomPiece.Id, 12);

        Test.startTest();
        // Warm the service cache under the ORIGINAL code…
        Decimal warm = UOM_Conversion_Service.getConversionFactor(null, 'CC-OLD', 'CC-PC');
        // …then rename the code. The after-update cache clear is what lets the
        // service see the new name.
        uomCase.UOM_Code__c = 'CC-NEW';
        update uomCase;
        Decimal byNewCode = UOM_Conversion_Service.getConversionFactor(null, 'CC-NEW', 'CC-PC');
        Decimal byOldCode = UOM_Conversion_Service.getConversionFactor(null, 'CC-OLD', 'CC-PC');
        Test.stopTest();

        System.assertEquals(12, warm, 'The rule resolved under the original code');
        System.assertEquals(12, byNewCode,
            'After the rename the NEW code resolves — only possible because the after-update '
            + 'clear rebuilt the code-to-id cache; a stale cache would return the default 1');
        System.assertEquals(1, byOldCode,
            'And the old code no longer exists, so it falls to the default');
    }
}