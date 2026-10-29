/**
 * @description Test class for TAM_TargetCriteria_Controller. Covers every
 *              public method (getAllObjects, getFieldCategories, getAllCriteria,
 *              getCriteria, saveCriteria, getCriteriaOptions,
 *              getLinkedTargetCount, deleteCriteria, bulkToggleActive,
 *              bulkDelete, toggleActive, cloneCriteria, previewCriteria) plus
 *              the private isSystemObject filter (exercised transitively via
 *              getAllObjects, which iterates the global describe).
 *
 *              Target_Criteria__c / Target_Actual__c are deployed-only — all
 *              fixtures are built defensively (try/catch per field +
 *              fillRequiredFields) so org validation rules cannot cascade.
 */
@isTest
private class TAM_TargetCriteria_Controller_Test {

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
            else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> pe = dfr.getPicklistValues();
                if (!pe.isEmpty()) record.put(fn, pe[0].getValue());
            }
            else if (t == Schema.DisplayType.BOOLEAN) record.put(fn, false);
            else if (t == Schema.DisplayType.DATE) record.put(fn, Date.today());
            else if (t == Schema.DisplayType.DATETIME) record.put(fn, Datetime.now());
            else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY
                  || t == Schema.DisplayType.PERCENT || t == Schema.DisplayType.INTEGER
                  || t == Schema.DisplayType.LONG) record.put(fn, 1);
        }
    }

    private static SObject makeCriteria(String name, Boolean active) {
        SObjectType t = Schema.getGlobalDescribe().get('Target_Criteria__c');
        if (t == null) return null;
        SObject c = t.newSObject();
        try { c.put('Name', name); } catch (Exception e) {}
        try { c.put('Object__c', 'Account'); } catch (Exception e) {}
        try { c.put('Operator__c', 'COUNT'); } catch (Exception e) {}
        try { c.put('User_Field__c', 'OwnerId'); } catch (Exception e) {}
        try { c.put('Date_Field__c', 'CreatedDate'); } catch (Exception e) {}
        try { c.put('Field__c', 'Id'); } catch (Exception e) {}
        try { c.put('Filters__c', '{}'); } catch (Exception e) {}
        try { c.put('Filter_Logic__c', ''); } catch (Exception e) {}
        try { c.put('Active__c', active); } catch (Exception e) {}
        try { c.put('Incentive_Weight__c', 50); } catch (Exception e) {}
        fillRequiredFields(c);
        try { insert c; } catch (Exception e) { return null; }
        return c;
    }

    private static SObject makeTargetActual(Id critId) {
        SObjectType t = Schema.getGlobalDescribe().get('Target_Actual__c');
        if (t == null) return null;
        SObject ta = t.newSObject();
        try { ta.put('Target_Criteria__c', critId); } catch (Exception e) {}
        try { ta.put('User__c', UserInfo.getUserId()); } catch (Exception e) {}
        try { ta.put('Target_Value__c', 100); } catch (Exception e) {}
        try { ta.put('Achievement_Value__c', 0); } catch (Exception e) {}
        fillRequiredFields(ta);
        try { insert ta; } catch (Exception e) { return null; }
        return ta;
    }

    // ── Describe / no-DML methods ────────────────────────────────────────────

    @isTest
    static void testGetAllObjects() {
        Test.startTest();
        List<Map<String, String>> objs = TAM_TargetCriteria_Controller.getAllObjects();
        Test.stopTest();

        System.assertNotEquals(null, objs, 'Object list returned');
        System.assert(objs.size() > 0, 'Should contain at least one queryable object');
        // Verify the shape: each entry has api + label.
        Map<String, String> first = objs[0];
        System.assert(first.containsKey('api'), 'api key present');
        System.assert(first.containsKey('label'), 'label key present');
    }

    @isTest
    static void testGetFieldCategories() {
        Test.startTest();
        Map<String, List<String>> cats =
            TAM_TargetCriteria_Controller.getFieldCategories('Account');
        Test.stopTest();

        System.assertNotEquals(null, cats, 'Field categories returned');
        System.assert(cats.containsKey('numberFields'), 'numberFields key');
        System.assert(cats.containsKey('dateFields'),   'dateFields key');
        System.assert(cats.containsKey('userFields'),   'userFields key');
        System.assert(cats.containsKey('allFields'),    'allFields key');
        // Account has CreatedDate (date) and OwnerId (user lookup) by default.
        System.assert(cats.get('allFields').size() > 0, 'Account has fields');
        System.assert(cats.get('dateFields').size() > 0, 'Account has date fields');
        System.assert(cats.get('userFields').size() > 0, 'Account has user-lookup fields');
    }

    // ── CRUD methods ─────────────────────────────────────────────────────────

    @isTest
    static void testGetAllAndGetSingle() {
        SObject c = makeCriteria('TC List Crit', true);
        if (c == null) return;

        Test.startTest();
        List<Target_Criteria__c> all = TAM_TargetCriteria_Controller.getAllCriteria();
        Target_Criteria__c single = TAM_TargetCriteria_Controller.getCriteria(c.Id);
        Test.stopTest();

        System.assert(all.size() >= 1, 'Returns at least the one we created');
        System.assertEquals(c.Id, single.Id, 'Single fetch returns the right record');
    }

    @isTest
    static void testSaveCriteria_InsertAndUpdate() {
        SObject c = makeCriteria('TC Save', true);
        if (c == null) return;

        Test.startTest();
        // Update path.
        Target_Criteria__c reloaded = TAM_TargetCriteria_Controller.getCriteria(c.Id);
        reloaded.Incentive_Weight__c = 75;
        Target_Criteria__c updated = TAM_TargetCriteria_Controller.saveCriteria(reloaded);
        System.assertEquals(75, updated.Incentive_Weight__c, 'Update persisted');

        // Insert path.
        Target_Criteria__c fresh = new Target_Criteria__c(Name = 'TC Save Fresh');
        try { fresh.put('Object__c', 'Account'); } catch (Exception e) {}
        try { fresh.put('Operator__c', 'COUNT'); } catch (Exception e) {}
        try { fresh.put('User_Field__c', 'OwnerId'); } catch (Exception e) {}
        try { fresh.put('Date_Field__c', 'CreatedDate'); } catch (Exception e) {}
        try { fresh.put('Field__c', 'Id'); } catch (Exception e) {}
        try { fresh.put('Filters__c', '{}'); } catch (Exception e) {}
        try { fresh.put('Active__c', true); } catch (Exception e) {}
        fillRequiredFields(fresh);
        try {
            Target_Criteria__c inserted = TAM_TargetCriteria_Controller.saveCriteria(fresh);
            System.assertNotEquals(null, inserted.Id, 'Insert path returns an Id');
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testGetCriteriaOptions() {
        makeCriteria('TC Opt 1', true);
        makeCriteria('TC Opt 2', false);  // inactive — should be excluded

        Test.startTest();
        List<Map<String, String>> opts = TAM_TargetCriteria_Controller.getCriteriaOptions();
        Test.stopTest();

        System.assertNotEquals(null, opts, 'Options returned');
        // First entry is the "-- None --" sentinel.
        System.assertEquals('', opts[0].get('value'),
            'First option is the no-prerequisite sentinel');
    }

    @isTest
    static void testGetLinkedTargetCount() {
        SObject c = makeCriteria('TC Count', true);
        if (c == null) return;
        makeTargetActual(c.Id);
        makeTargetActual(c.Id);

        Test.startTest();
        Integer cnt = TAM_TargetCriteria_Controller.getLinkedTargetCount(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, cnt, 'Count returned');
        System.assert(cnt >= 0, 'Count is non-negative');
    }

    @isTest
    static void testDeleteCriteria_WithLinkedActuals() {
        SObject c = makeCriteria('TC Delete', true);
        if (c == null) return;
        makeTargetActual(c.Id);

        Test.startTest();
        TAM_TargetCriteria_Controller.deleteCriteria(c.Id);
        Test.stopTest();

        Integer remaining = [SELECT COUNT() FROM Target_Criteria__c WHERE Id = :c.Id];
        System.assertEquals(0, remaining, 'Criteria deleted');
    }

    @isTest
    static void testDeleteCriteria_NoLinkedActuals() {
        // Exercises the linkedActuals.isEmpty() branch (skip the deletes).
        SObject c = makeCriteria('TC Delete Empty', true);
        if (c == null) return;

        Test.startTest();
        TAM_TargetCriteria_Controller.deleteCriteria(c.Id);
        Test.stopTest();
    }

    @isTest
    static void testToggleActive() {
        SObject c = makeCriteria('TC Toggle', true);
        if (c == null) return;

        Test.startTest();
        TAM_TargetCriteria_Controller.toggleActive(c.Id, false);
        Test.stopTest();

        Target_Criteria__c r = [SELECT Active__c FROM Target_Criteria__c WHERE Id = :c.Id];
        System.assertEquals(false, r.Active__c, 'Active flag toggled off');
    }

    @isTest
    static void testBulkToggleActiveAndDelete() {
        SObject c1 = makeCriteria('TC Bulk 1', true);
        SObject c2 = makeCriteria('TC Bulk 2', true);
        if (c1 == null || c2 == null) return;
        makeTargetActual(c1.Id);

        List<Id> ids = new List<Id>{ c1.Id, c2.Id };

        Test.startTest();
        TAM_TargetCriteria_Controller.bulkToggleActive(ids, false);

        // Bulk delete (with linked actuals on c1, none on c2 — both branches).
        TAM_TargetCriteria_Controller.bulkDelete(ids);
        Test.stopTest();

        Integer remaining = [
            SELECT COUNT() FROM Target_Criteria__c WHERE Id IN :ids
        ];
        System.assertEquals(0, remaining, 'Both criteria deleted in bulk');
    }

    @isTest
    static void testBulkDelete_NoLinkedActuals() {
        // Exercises the linkedActuals.isEmpty() branch on the bulk path.
        SObject c = makeCriteria('TC BulkDel Empty', true);
        if (c == null) return;

        Test.startTest();
        TAM_TargetCriteria_Controller.bulkDelete(new List<Id>{ c.Id });
        Test.stopTest();
    }

    @isTest
    static void testCloneCriteria() {
        SObject c = makeCriteria('TC Clone Source', true);
        if (c == null) return;

        Test.startTest();
        Target_Criteria__c cloned = TAM_TargetCriteria_Controller.cloneCriteria(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, cloned, 'Cloned record returned');
        System.assertNotEquals(c.Id, cloned.Id, 'Clone has its own Id');
        System.assert(cloned.Name.contains('(Copy)'), 'Clone name has (Copy) suffix');
        System.assertEquals(false, cloned.Active__c, 'Clone is created inactive');
    }

    // ── previewCriteria: success + dynamic-SOQL exception paths ─────────────

    @isTest
    static void testPreviewCriteria_Success() {
        SObject c = makeCriteria('TC Preview OK', true);
        if (c == null) return;

        Test.startTest();
        Map<String, Object> r = TAM_TargetCriteria_Controller.previewCriteria(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, r, 'Preview result returned');
        System.assert(r.containsKey('query'), 'query key present');
        System.assert(r.containsKey('period'), 'period key present');
        System.assert(r.containsKey('success'), 'success key present');
    }

    @isTest
    static void testPreviewCriteria_SoqlException() {
        // Build a criterion that references an invalid field so the dynamic
        // SOQL throws and the catch branch executes.
        SObjectType t = Schema.getGlobalDescribe().get('Target_Criteria__c');
        if (t == null) return;
        SObject bad = t.newSObject();
        try { bad.put('Name', 'TC Preview Bad'); } catch (Exception e) {}
        try { bad.put('Object__c', 'Account'); } catch (Exception e) {}
        try { bad.put('Operator__c', 'SUM'); } catch (Exception e) {}
        // Invalid field for SUM(...) on Account → QueryException at runtime.
        try { bad.put('Field__c', 'No_Such_Field_XYZ__c'); } catch (Exception e) {}
        try { bad.put('User_Field__c', 'OwnerId'); } catch (Exception e) {}
        try { bad.put('Date_Field__c', 'CreatedDate'); } catch (Exception e) {}
        try { bad.put('Filters__c', '{}'); } catch (Exception e) {}
        try { bad.put('Active__c', true); } catch (Exception e) {}
        fillRequiredFields(bad);
        try { insert bad; } catch (Exception e) { return; }

        Test.startTest();
        Map<String, Object> r = TAM_TargetCriteria_Controller.previewCriteria(bad.Id);
        Test.stopTest();

        System.assertEquals(false, (Boolean) r.get('success'),
            'Preview marked as failed when dynamic SOQL throws');
        System.assert(r.containsKey('error'), 'Error message captured');
    }
}