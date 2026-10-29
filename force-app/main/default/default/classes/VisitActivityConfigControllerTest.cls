/**
 * @description Tests for VisitActivityConfigController — the admin surface over
 * the visit activity catalogue and its Profile / Outlet Type scoping rules.
 *
 * Two things here carry more weight than the rest.
 *
 * The blank-to-null normalisation in saveRule and setActivityForScope is load
 * bearing. A blank Profile or Outlet Type means "applies to everyone", and the
 * resolver expresses that as NULL. If an empty string reached the database
 * instead, the rule would match nothing and simply never fire — no error, no
 * clue, just an activity that quietly refuses to appear for anybody.
 *
 * And preview() exists to guarantee the admin is shown the same answer the rep
 * gets, by calling the same VisitActivityConfig.resolve(). So one test asserts
 * the two agree rather than just that preview returns something.
 *
 * Toggles are pinned through BPM_FeatureToggle_Util's @TestVisible cache, since
 * several catalogue entries are gated by OVE/SPM feature codes whose org state
 * would otherwise decide the result.
 */
@isTest
private class VisitActivityConfigControllerTest {

    // ── Fixtures ──────────────────────────────────────────────────────

    private static void setFeature(String featureCode, Boolean enabled) {
        BPM_FeatureToggle_Util.toggleCache.put(featureCode, enabled);
    }

    /** An activity with no feature toggle, so rules alone decide it. */
    private static final String UNGATED_KEY = 'order';
    /** An activity gated by a feature toggle. */
    private static final String GATED_KEY = 'stock_check';
    private static final String GATED_TOGGLE = 'OVE-010';

    private static Visit_Activity_Rule__c rule(
            String activityKey, String profileName, String outletType, Boolean enabled) {
        return new Visit_Activity_Rule__c(
            Activity_Key__c = activityKey,
            Profile_Name__c = profileName,
            Outlet_Type__c = outletType,
            Is_Enabled__c = enabled,
            Is_Active__c = true
        );
    }

    private static Visit_Activity_Rule__c reload(Id ruleId) {
        return [
            SELECT Id, Activity_Key__c, Profile_Name__c, Outlet_Type__c,
                   Is_Enabled__c, Is_Active__c
            FROM Visit_Activity_Rule__c WHERE Id = :ruleId
        ];
    }

    private static Map<String, VisitActivityConfig.Resolution> byKey(
            List<VisitActivityConfig.Resolution> resolutions) {
        Map<String, VisitActivityConfig.Resolution> m =
            new Map<String, VisitActivityConfig.Resolution>();
        for (VisitActivityConfig.Resolution r : resolutions) m.put(r.key, r);
        return m;
    }

    private static String anOutletType() {
        for (Schema.PicklistEntry e : Account.Outlet_Type__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) return e.getValue();
        }
        return null;
    }

    // ── getCatalog ────────────────────────────────────────────────────

    @isTest
    static void catalog_returnsEveryActivityFullyPopulated() {
        Test.startTest();
        List<VisitActivityConfigController.ActivityRow> rows =
            VisitActivityConfigController.getCatalog();
        Test.stopTest();

        System.assertEquals(VisitActivityConfig.CATALOG.size(), rows.size(),
            'The admin screen lists the whole catalogue, gated or not');
        for (VisitActivityConfigController.ActivityRow r : rows) {
            System.assert(String.isNotBlank(r.key), 'Every row needs the key rules point at');
            System.assert(String.isNotBlank(r.label), 'And a label: ' + r.key);
            System.assert(String.isNotBlank(r.icon), 'And an icon: ' + r.key);
            System.assertNotEquals(null, r.sortOrder, 'And a sort order: ' + r.key);
            System.assertNotEquals(null, r.featureAvailable,
                'Availability is always decided, never left unknown: ' + r.key);
        }
    }

    @isTest
    static void catalog_marksUngatedActivitiesAsAlwaysAvailable() {
        Test.startTest();
        List<VisitActivityConfigController.ActivityRow> rows =
            VisitActivityConfigController.getCatalog();
        Test.stopTest();

        for (VisitActivityConfigController.ActivityRow r : rows) {
            if (String.isBlank(r.toggleCode)) {
                System.assertEquals(true, r.featureAvailable,
                    'An activity with no toggle is licensed for every org: ' + r.key);
            }
        }
    }

    @isTest
    static void catalog_reflectsTheFeatureToggleForGatedActivities() {
        setFeature(GATED_TOGGLE, false);

        Test.startTest();
        Map<String, VisitActivityConfigController.ActivityRow> whenDisabled =
            new Map<String, VisitActivityConfigController.ActivityRow>();
        for (VisitActivityConfigController.ActivityRow r : VisitActivityConfigController.getCatalog()) {
            whenDisabled.put(r.key, r);
        }

        setFeature(GATED_TOGGLE, true);
        Map<String, VisitActivityConfigController.ActivityRow> whenEnabled =
            new Map<String, VisitActivityConfigController.ActivityRow>();
        for (VisitActivityConfigController.ActivityRow r : VisitActivityConfigController.getCatalog()) {
            whenEnabled.put(r.key, r);
        }
        Test.stopTest();

        System.assertEquals(false, whenDisabled.get(GATED_KEY).featureAvailable,
            'With its toggle off the activity is greyed out — no rule could ever surface it');
        System.assertEquals(true, whenEnabled.get(GATED_KEY).featureAvailable,
            'And configurable once the toggle is on');
    }

    // ── getRules ──────────────────────────────────────────────────────

    @isTest
    static void rules_withNoneConfigured_returnsEmpty() {
        Test.startTest();
        List<Visit_Activity_Rule__c> rules = VisitActivityConfigController.getRules();
        Test.stopTest();

        System.assertEquals(0, rules.size(), 'A fresh org has no overrides');
    }

    @isTest
    static void rules_areOrderedWithBroadestScopeFirst() {
        String outlet = anOutletType();
        insert new List<Visit_Activity_Rule__c>{
            rule(UNGATED_KEY, 'System Administrator', outlet, false),
            rule(UNGATED_KEY, null, null, true),
            rule(UNGATED_KEY, 'System Administrator', null, false)
        };

        Test.startTest();
        List<Visit_Activity_Rule__c> rules = VisitActivityConfigController.getRules();
        Test.stopTest();

        System.assertEquals(3, rules.size(), 'All three listed');
        System.assertEquals(null, rules[0].Profile_Name__c,
            'The org-wide rule sorts first, so the admin reads general-to-specific');
        System.assertEquals(null, rules[1].Outlet_Type__c,
            'Then the profile-wide rule');
        System.assertEquals(outlet, rules[2].Outlet_Type__c,
            'And the most specific rule last');
    }

    // ── getScopeOptions ───────────────────────────────────────────────

    @isTest
    static void scopeOptions_offerProfilesAndLiveOutletTypes() {
        Test.startTest();
        Map<String, List<Map<String, String>>> options =
            VisitActivityConfigController.getScopeOptions();
        Test.stopTest();

        System.assert(options.containsKey('profiles'), 'Profiles are scopeable');
        System.assert(options.containsKey('outletTypes'), 'And outlet types');
        System.assert(!options.get('profiles').isEmpty(), 'Every org has profiles');

        for (Map<String, String> p : options.get('profiles')) {
            System.assert(String.isNotBlank(p.get('label')), 'Each profile has a label');
            System.assertEquals(p.get('label'), p.get('value'),
                'Rules store the profile NAME, so label and value must be the same string');
        }

        Set<String> offered = new Set<String>();
        for (Map<String, String> o : options.get('outletTypes')) offered.add(o.get('value'));
        for (Schema.PicklistEntry e : Account.Outlet_Type__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                System.assert(offered.contains(e.getValue()),
                    'Outlet types come from the live picklist so a new one is immediately '
                    + 'scopeable — missing: ' + e.getValue());
            }
        }
    }

    // ── saveRule ──────────────────────────────────────────────────────

    @isTest
    static void saveRule_withoutAnActivity_isRejected() {
        Test.startTest();
        Integer rejected = 0;
        try {
            VisitActivityConfigController.saveRule(null);
        } catch (AuraHandledException e) { rejected++; }
        try {
            VisitActivityConfigController.saveRule(new Visit_Activity_Rule__c());
        } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(2, rejected, 'A rule with no activity has nothing to govern');
        System.assertEquals(0, [SELECT COUNT() FROM Visit_Activity_Rule__c], 'Nothing saved');
    }

    @isTest
    static void saveRule_withAnUnknownActivityKey_isRejected() {
        Test.startTest();
        Boolean threw = false;
        try {
            VisitActivityConfigController.saveRule(
                rule('not_a_real_activity', null, null, true));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'A key outside the catalogue would create a rule the resolver never reads');
        System.assertEquals(0, [SELECT COUNT() FROM Visit_Activity_Rule__c], 'Nothing saved');
    }

    @isTest
    static void saveRule_normalisesBlankScopeToNull() {
        Visit_Activity_Rule__c blankScoped = rule(UNGATED_KEY, '', '   ', false);

        Test.startTest();
        Visit_Activity_Rule__c saved = VisitActivityConfigController.saveRule(blankScoped);
        Test.stopTest();

        System.assertEquals(null, saved.Profile_Name__c,
            'A blank profile means "all profiles" and must be stored as null — an empty '
            + 'string matches no profile, so the rule would silently never fire');
        System.assertEquals(null, saved.Outlet_Type__c, 'Same for a blank outlet type');
        System.assertEquals(UNGATED_KEY, saved.Activity_Key__c, 'And the activity is kept');
    }

    @isTest
    static void saveRule_refusesASecondRuleAtTheSameScope() {
        insert rule(UNGATED_KEY, 'System Administrator', null, true);

        Test.startTest();
        Boolean threw = false;
        try {
            VisitActivityConfigController.saveRule(
                rule(UNGATED_KEY, 'System Administrator', null, false));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw,
            'Two rules at the same specificity would contradict each other with no tie-break');
        System.assertEquals(1, [SELECT COUNT() FROM Visit_Activity_Rule__c],
            'The original rule stands alone');
    }

    @isTest
    static void saveRule_allowsTheSameScopeForADifferentActivity() {
        insert rule(UNGATED_KEY, 'System Administrator', null, true);

        Test.startTest();
        Visit_Activity_Rule__c saved = VisitActivityConfigController.saveRule(
            rule('collection', 'System Administrator', null, false));
        Test.stopTest();

        System.assertNotEquals(null, saved.Id,
            'The clash check is per activity — one profile can govern several activities');
        System.assertEquals(2, [SELECT COUNT() FROM Visit_Activity_Rule__c], 'Both rules exist');
    }

    @isTest
    static void saveRule_canEditAnExistingRuleWithoutClashingWithItself() {
        Visit_Activity_Rule__c existing = rule(UNGATED_KEY, 'System Administrator', null, true);
        insert existing;

        Test.startTest();
        existing.Is_Enabled__c = false;
        existing.Description__c = 'Switched off for admins';
        Visit_Activity_Rule__c saved = VisitActivityConfigController.saveRule(existing);
        Test.stopTest();

        System.assertEquals(existing.Id, saved.Id, 'The same record was updated');
        System.assertEquals(false, saved.Is_Enabled__c,
            'Re-saving a rule must not trip the duplicate guard against itself');
        System.assertEquals(1, [SELECT COUNT() FROM Visit_Activity_Rule__c], 'Still one rule');
    }

    // ── deleteRule ────────────────────────────────────────────────────

    @isTest
    static void deleteRule_removesTheRule() {
        Visit_Activity_Rule__c existing = rule(UNGATED_KEY, null, null, false);
        insert existing;

        Test.startTest();
        VisitActivityConfigController.deleteRule(existing.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Visit_Activity_Rule__c],
            'The override is gone and the activity returns to its default');
    }

    @isTest
    static void deleteRule_withNoId_isANoOp() {
        insert rule(UNGATED_KEY, null, null, false);

        Test.startTest();
        VisitActivityConfigController.deleteRule(null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Visit_Activity_Rule__c],
            'A null id is ignored, never read as "delete something"');
    }

    // ── setActivityForScope ───────────────────────────────────────────

    @isTest
    static void setActivityForScope_withoutAnActivity_isRejected() {
        Test.startTest();
        Boolean threw = false;
        try {
            VisitActivityConfigController.setActivityForScope(
                '  ', 'System Administrator', null, true, false);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, 'The matrix cell must name the activity it is toggling');
    }

    @isTest
    static void setActivityForScope_createsARuleWhenNoneExists() {
        String outlet = anOutletType();

        Test.startTest();
        VisitActivityConfigController.setActivityForScope(
            UNGATED_KEY, 'System Administrator', outlet, false, false);
        Test.stopTest();

        List<Visit_Activity_Rule__c> saved = [
            SELECT Activity_Key__c, Profile_Name__c, Outlet_Type__c, Is_Enabled__c, Is_Active__c
            FROM Visit_Activity_Rule__c
        ];
        System.assertEquals(1, saved.size(), 'Toggling a cell creates the rule behind it');
        System.assertEquals(UNGATED_KEY, saved[0].Activity_Key__c, 'For the right activity');
        System.assertEquals('System Administrator', saved[0].Profile_Name__c, 'And scope');
        System.assertEquals(outlet, saved[0].Outlet_Type__c, 'And outlet type');
        System.assertEquals(false, saved[0].Is_Enabled__c, 'Switched off as asked');
        System.assertEquals(true, saved[0].Is_Active__c, 'And the rule itself is live');
    }

    @isTest
    static void setActivityForScope_updatesInPlaceRatherThanDuplicating() {
        insert rule(UNGATED_KEY, 'System Administrator', null, false);

        Test.startTest();
        VisitActivityConfigController.setActivityForScope(
            UNGATED_KEY, 'System Administrator', null, true, false);
        Test.stopTest();

        List<Visit_Activity_Rule__c> saved = [
            SELECT Is_Enabled__c FROM Visit_Activity_Rule__c
        ];
        System.assertEquals(1, saved.size(),
            'Flipping a cell back and forth must not accumulate rules');
        System.assertEquals(true, saved[0].Is_Enabled__c, 'The existing rule was flipped');
    }

    @isTest
    static void setActivityForScope_normalisesBlankScopeToNull() {
        Test.startTest();
        VisitActivityConfigController.setActivityForScope(UNGATED_KEY, '', '', false, false);
        Test.stopTest();

        Visit_Activity_Rule__c saved = [
            SELECT Profile_Name__c, Outlet_Type__c FROM Visit_Activity_Rule__c
        ];
        System.assertEquals(null, saved.Profile_Name__c,
            'An org-wide cell stores null, which is what the resolver treats as "all"');
        System.assertEquals(null, saved.Outlet_Type__c, 'Same for the outlet type');
    }

    @isTest
    static void setActivityForScope_returningToDefaultDeletesTheRule() {
        insert rule(UNGATED_KEY, 'System Administrator', null, false);

        Test.startTest();
        VisitActivityConfigController.setActivityForScope(
            UNGATED_KEY, 'System Administrator', null, false, true);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Visit_Activity_Rule__c],
            'Returning a cell to default removes the override entirely, so the object does '
            + 'not fill up with rules that only say "behave normally"');
    }

    @isTest
    static void setActivityForScope_returningToDefaultWithNoRule_isANoOp() {
        Test.startTest();
        VisitActivityConfigController.setActivityForScope(
            UNGATED_KEY, 'System Administrator', null, false, true);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Visit_Activity_Rule__c],
            'Clearing a cell that was never overridden does nothing and throws nothing');
    }

    @isTest
    static void setActivityForScope_keepsScopesIndependent() {
        String outlet = anOutletType();

        Test.startTest();
        VisitActivityConfigController.setActivityForScope(UNGATED_KEY, null, null, false, false);
        VisitActivityConfigController.setActivityForScope(
            UNGATED_KEY, 'System Administrator', outlet, true, false);
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Visit_Activity_Rule__c],
            'An org-wide rule and a specific override are different cells, not the same one');
    }

    // ── preview ───────────────────────────────────────────────────────

    @isTest
    static void preview_withNoRules_showsEveryLicensedActivity() {
        setFeature(GATED_TOGGLE, false);

        Test.startTest();
        List<VisitActivityConfig.Resolution> shown =
            VisitActivityConfigController.preview('System Administrator', anOutletType());
        Test.stopTest();

        Map<String, VisitActivityConfig.Resolution> byActivity = byKey(shown);
        System.assertEquals(VisitActivityConfig.CATALOG.size(), shown.size(),
            'Every activity is accounted for, visible or not, so the admin sees the full picture');
        System.assertEquals(true, byActivity.get(UNGATED_KEY).visible,
            'With no rule an ungated activity is visible by default');
        System.assertEquals(false, byActivity.get(GATED_KEY).visible,
            'A feature toggle is an absolute gate — no rule is needed to hide it');
        System.assert(byActivity.get(GATED_KEY).reason.contains(GATED_TOGGLE),
            'And the preview explains why: ' + byActivity.get(GATED_KEY).reason);
    }

    @isTest
    static void preview_appliesTheMostSpecificRule() {
        String outlet = anOutletType();
        // Org-wide says on; this profile + outlet says off. The narrower rule wins.
        insert new List<Visit_Activity_Rule__c>{
            rule(UNGATED_KEY, null, null, true),
            rule(UNGATED_KEY, 'System Administrator', outlet, false)
        };

        Test.startTest();
        List<VisitActivityConfig.Resolution> forThisScope =
            VisitActivityConfigController.preview('System Administrator', outlet);
        List<VisitActivityConfig.Resolution> forAnotherProfile =
            VisitActivityConfigController.preview('Some Other Profile', outlet);
        Test.stopTest();

        System.assertEquals(false, byKey(forThisScope).get(UNGATED_KEY).visible,
            'The narrow rule beats the org-wide one for the scope it names');
        System.assertEquals(true, byKey(forAnotherProfile).get(UNGATED_KEY).visible,
            'And leaves every other profile on the org-wide setting');
    }

    @isTest
    static void preview_treatsBlankScopeAsUnspecified() {
        insert rule(UNGATED_KEY, 'System Administrator', null, false);

        Test.startTest();
        List<VisitActivityConfig.Resolution> blanks =
            VisitActivityConfigController.preview('', '   ');
        Test.stopTest();

        System.assertEquals(true, byKey(blanks).get(UNGATED_KEY).visible,
            'Previewing with no profile chosen must not accidentally match a profile-scoped '
            + 'rule — blank is normalised to null, not to an empty profile name');
    }

    @isTest
    static void preview_agreesWithTheRuntimeResolver() {
        String outlet = anOutletType();
        insert new List<Visit_Activity_Rule__c>{
            rule(UNGATED_KEY, 'System Administrator', outlet, false),
            rule('collection', null, null, false)
        };

        Test.startTest();
        Map<String, VisitActivityConfig.Resolution> fromPreview =
            byKey(VisitActivityConfigController.preview('System Administrator', outlet));
        Map<String, VisitActivityConfig.Resolution> fromRuntime =
            byKey(VisitActivityConfig.resolve('System Administrator', outlet));
        Test.stopTest();

        System.assertEquals(fromRuntime.size(), fromPreview.size(),
            'The preview covers exactly what the runtime resolves');
        for (String key : fromRuntime.keySet()) {
            System.assertEquals(fromRuntime.get(key).visible, fromPreview.get(key).visible,
                'An admin must never be shown a preview that disagrees with what the rep '
                + 'gets — mismatch on: ' + key);
        }
    }
}