/**
 * @description Tests for FMCGWorkspaceConfigController — per-profile visibility
 * of FMCG Workspace components.
 *
 * The behaviour that carries the risk here is the default. A profile with no
 * config rows sees EVERYTHING, and a configured profile still sees any key that
 * has no row of its own. That is deliberate — it stops an admin's partial setup
 * from blanking the app for a team — but it means the failure mode of this class
 * is silent over-exposure rather than a visible error. So the tests lean on the
 * fallbacks: no rows at all, rows for a different profile, and a key the admin
 * never saved.
 *
 * Component counts are read from getComponentMaster() rather than hardcoded, so
 * these tests survive new components being added to the master list.
 */
@isTest
private class FMCGWorkspaceConfigControllerTest {

    // ── Fixtures ──────────────────────────────────────────────────────

    private static String runningProfileName() {
        return [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1].Profile.Name;
    }

    private static Integer masterSize() {
        return FMCGWorkspaceConfigController.getComponentMaster().size();
    }

    private static List<String> masterKeys() {
        List<String> keys = new List<String>();
        for (FMCGWorkspaceConfigController.Component c
                : FMCGWorkspaceConfigController.getComponentMaster()) {
            keys.add(c.key);
        }
        return keys;
    }

    private static FMCG_Workspace_Visibility__c row(String profileName, String key, Boolean visible) {
        return new FMCG_Workspace_Visibility__c(
            Profile_Name__c = profileName,
            Component_Key__c = key,
            Is_Visible__c = visible
        );
    }

    private static Integer rowCountFor(String profileName) {
        return [SELECT COUNT() FROM FMCG_Workspace_Visibility__c
                WHERE Profile_Name__c = :profileName];
    }

    // ── getComponentMaster ────────────────────────────────────────────

    @isTest
    static void componentMaster_isFullyPopulated() {
        Test.startTest();
        List<FMCGWorkspaceConfigController.Component> master =
            FMCGWorkspaceConfigController.getComponentMaster();
        Test.stopTest();

        System.assert(!master.isEmpty(), 'The admin screen needs a catalogue to render');
        for (FMCGWorkspaceConfigController.Component c : master) {
            System.assert(String.isNotBlank(c.key), 'Every component needs a key to save against');
            System.assert(String.isNotBlank(c.label), 'And a label: ' + c.key);
            System.assert(String.isNotBlank(c.tab), 'And a tab to group under: ' + c.key);
            System.assert(String.isNotBlank(c.section), 'And a section: ' + c.key);
            System.assert(String.isNotBlank(c.icon), 'And an icon: ' + c.key);
            System.assert(String.isNotBlank(c.color), 'And a colour: ' + c.key);
        }
    }

    @isTest
    static void componentKeysAreUnique() {
        Test.startTest();
        List<String> keys = masterKeys();
        Test.stopTest();

        Set<String> unique = new Set<String>(keys);
        System.assertEquals(keys.size(), unique.size(),
            'Two components sharing a key would collapse into one row, so toggling either one '
            + 'would silently move the other');
    }

    // ── getMyVisibleComponents ────────────────────────────────────────

    @isTest
    static void myComponents_withNoConfigAtAll_showsEverything() {
        Test.startTest();
        Map<String, Boolean> visible = FMCGWorkspaceConfigController.getMyVisibleComponents();
        Test.stopTest();

        System.assertEquals(masterSize(), visible.size(), 'Every component is accounted for');
        for (String key : visible.keySet()) {
            System.assertEquals(true, visible.get(key),
                'Until an admin opts in to restricting a profile, nothing is hidden: ' + key);
        }
    }

    @isTest
    static void myComponents_respectsTheRowsSavedForThatProfile() {
        String profileName = runningProfileName();
        List<String> keys = masterKeys();
        insert new List<FMCG_Workspace_Visibility__c>{
            row(profileName, keys[0], false),
            row(profileName, keys[1], true),
            row(profileName, keys[2], false)
        };

        Test.startTest();
        Map<String, Boolean> visible = FMCGWorkspaceConfigController.getMyVisibleComponents();
        Test.stopTest();

        System.assertEquals(false, visible.get(keys[0]), 'A hidden component stays hidden');
        System.assertEquals(true, visible.get(keys[1]), 'A visible one stays visible');
        System.assertEquals(false, visible.get(keys[2]), 'And the second hidden one too');
    }

    @isTest
    static void myComponents_defaultsAKeyWithNoRowToVisible() {
        String profileName = runningProfileName();
        List<String> keys = masterKeys();
        // Only one key configured — every other component has no row of its own.
        insert row(profileName, keys[0], false);

        Test.startTest();
        Map<String, Boolean> visible = FMCGWorkspaceConfigController.getMyVisibleComponents();
        Test.stopTest();

        System.assertEquals(masterSize(), visible.size(), 'Still one entry per component');
        System.assertEquals(false, visible.get(keys[0]), 'The configured key is honoured');
        for (Integer i = 1; i < keys.size(); i++) {
            System.assertEquals(true, visible.get(keys[i]),
                'A component added after the admin last saved must not vanish for them: ' + keys[i]);
        }
    }

    @isTest
    static void myComponents_ignoresConfigBelongingToAnotherProfile() {
        List<String> keys = masterKeys();
        List<FMCG_Workspace_Visibility__c> otherProfile = new List<FMCG_Workspace_Visibility__c>();
        for (String key : keys) {
            otherProfile.add(row('Some Other Profile', key, false));
        }
        insert otherProfile;

        Test.startTest();
        Map<String, Boolean> visible = FMCGWorkspaceConfigController.getMyVisibleComponents();
        Test.stopTest();

        for (String key : visible.keySet()) {
            System.assertEquals(true, visible.get(key),
                'Another profile being locked down must not affect this user: ' + key);
        }
    }

    // ── getConfigForProfile ───────────────────────────────────────────

    @isTest
    static void configForProfile_requiresAProfileName() {
        Test.startTest();
        Integer rejected = 0;
        try {
            FMCGWorkspaceConfigController.getConfigForProfile(null);
        } catch (AuraHandledException e) { rejected++; }
        try {
            FMCGWorkspaceConfigController.getConfigForProfile('');
        } catch (AuraHandledException e) { rejected++; }
        try {
            FMCGWorkspaceConfigController.getConfigForProfile('   ');
        } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(3, rejected,
            'Null, empty and whitespace are all refused rather than silently reading nothing');
    }

    @isTest
    static void configForProfile_withNoRows_showsEverything() {
        Test.startTest();
        Map<String, Boolean> visible =
            FMCGWorkspaceConfigController.getConfigForProfile('Never Configured Profile');
        Test.stopTest();

        System.assertEquals(masterSize(), visible.size(), 'Full catalogue returned');
        for (String key : visible.keySet()) {
            System.assertEquals(true, visible.get(key),
                'An unconfigured profile opens with everything ticked: ' + key);
        }
    }

    @isTest
    static void configForProfile_reflectsWhatWasSaved() {
        List<String> keys = masterKeys();
        insert new List<FMCG_Workspace_Visibility__c>{
            row('Field Rep', keys[0], true),
            row('Field Rep', keys[1], false)
        };

        Test.startTest();
        Map<String, Boolean> visible =
            FMCGWorkspaceConfigController.getConfigForProfile('Field Rep');
        Test.stopTest();

        System.assertEquals(true, visible.get(keys[0]), 'Saved visible key reads back visible');
        System.assertEquals(false, visible.get(keys[1]), 'Saved hidden key reads back hidden');
    }

    // ── getAllProfiles ────────────────────────────────────────────────

    @isTest
    static void allProfiles_returnsIdAndNameInNameOrder() {
        Test.startTest();
        List<Map<String, String>> profiles = FMCGWorkspaceConfigController.getAllProfiles();
        Test.stopTest();

        System.assert(!profiles.isEmpty(), 'Every org has profiles to pick from');
        System.assertEquals([SELECT COUNT() FROM Profile], profiles.size(),
            'Every profile is offered — the picker is not silently truncated');

        // Compared case-insensitively on purpose: SOQL's ORDER BY collation
        // ignores case, while Apex's String.compareTo is ordinal, so uppercase
        // sorts before lowercase. A case-sensitive check here would fail on a
        // correctly ordered list (e.g. FSCRM_Admin before FSCRM_ASM).
        String previous = null;
        for (Map<String, String> p : profiles) {
            System.assert(String.isNotBlank(p.get('id')), 'Each entry carries an id');
            System.assert(String.isNotBlank(p.get('name')), 'And a name for the picklist');
            String current = p.get('name').toLowerCase();
            if (previous != null) {
                System.assert(previous.compareTo(current) <= 0,
                    'Profiles are listed alphabetically — out of order at: ' + p.get('name'));
            }
            previous = current;
        }
    }

    // ── saveConfig ────────────────────────────────────────────────────

    @isTest
    static void saveConfig_requiresAProfileName() {
        Test.startTest();
        Integer rejected = 0;
        try {
            FMCGWorkspaceConfigController.saveConfig(null, new List<String>{ 'tab_dashboard' });
        } catch (AuraHandledException e) { rejected++; }
        try {
            FMCGWorkspaceConfigController.saveConfig('  ', new List<String>{ 'tab_dashboard' });
        } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        System.assertEquals(2, rejected, 'A save with no profile is refused');
        System.assertEquals(0, [SELECT COUNT() FROM FMCG_Workspace_Visibility__c],
            'And nothing is written');
    }

    @isTest
    static void saveConfig_writesOneRowPerComponent() {
        List<String> keys = masterKeys();
        List<String> chosen = new List<String>{ keys[0], keys[1], keys[2] };

        Test.startTest();
        FMCGWorkspaceConfigController.saveConfig('Field Rep', chosen);
        Test.stopTest();

        System.assertEquals(masterSize(), rowCountFor('Field Rep'),
            'Every component gets a row, so an unticked box is stored as false rather than '
            + 'falling back to the show-everything default');

        Map<String, Boolean> saved = FMCGWorkspaceConfigController.getConfigForProfile('Field Rep');
        for (String key : chosen) {
            System.assertEquals(true, saved.get(key), 'Chosen component is visible: ' + key);
        }
        Integer hidden = 0;
        for (String key : saved.keySet()) {
            if (!saved.get(key)) hidden++;
        }
        System.assertEquals(masterSize() - chosen.size(), hidden,
            'Everything the admin did not tick is hidden');
    }

    @isTest
    static void saveConfig_withNothingSelected_hidesEverything() {
        Test.startTest();
        FMCGWorkspaceConfigController.saveConfig('Locked Down', null);
        Test.stopTest();

        Map<String, Boolean> saved =
            FMCGWorkspaceConfigController.getConfigForProfile('Locked Down');
        System.assertEquals(masterSize(), saved.size(), 'Every component still has an entry');
        for (String key : saved.keySet()) {
            System.assertEquals(false, saved.get(key),
                'A null selection means nothing is visible, not everything: ' + key);
        }
    }

    @isTest
    static void saveConfig_updatesInPlaceRatherThanDuplicating() {
        List<String> keys = masterKeys();
        FMCGWorkspaceConfigController.saveConfig('Field Rep', new List<String>{ keys[0] });
        Integer afterFirstSave = rowCountFor('Field Rep');

        Test.startTest();
        FMCGWorkspaceConfigController.saveConfig('Field Rep', new List<String>{ keys[1] });
        Test.stopTest();

        System.assertEquals(afterFirstSave, rowCountFor('Field Rep'),
            'Re-saving reuses the existing rows — otherwise every save would multiply them');
        Map<String, Boolean> saved = FMCGWorkspaceConfigController.getConfigForProfile('Field Rep');
        System.assertEquals(false, saved.get(keys[0]), 'The first key was switched off');
        System.assertEquals(true, saved.get(keys[1]), 'And the second switched on');
    }

    @isTest
    static void saveConfig_ignoresKeysThatAreNotInTheMaster() {
        List<String> keys = masterKeys();

        Test.startTest();
        FMCGWorkspaceConfigController.saveConfig('Field Rep',
            new List<String>{ keys[0], 'not_a_real_component', 'card_from_a_future_release' });
        Test.stopTest();

        System.assertEquals(masterSize(), rowCountFor('Field Rep'),
            'Only real components get rows — a stale key from the client is dropped');
        System.assertEquals(0, [
            SELECT COUNT() FROM FMCG_Workspace_Visibility__c
            WHERE Component_Key__c = 'not_a_real_component'
        ], 'And no row is created for it');
    }

    @isTest
    static void saveConfig_touchesOnlyTheProfileBeingSaved() {
        List<String> keys = masterKeys();
        FMCGWorkspaceConfigController.saveConfig('Field Rep', new List<String>{ keys[0] });

        Test.startTest();
        FMCGWorkspaceConfigController.saveConfig('Supervisor', new List<String>{ keys[1] });
        Test.stopTest();

        Map<String, Boolean> fieldRep =
            FMCGWorkspaceConfigController.getConfigForProfile('Field Rep');
        Map<String, Boolean> supervisor =
            FMCGWorkspaceConfigController.getConfigForProfile('Supervisor');

        System.assertEquals(true, fieldRep.get(keys[0]), 'Field Rep keeps its own selection');
        System.assertEquals(false, fieldRep.get(keys[1]), 'And is unaffected by the other save');
        System.assertEquals(false, supervisor.get(keys[0]), 'Supervisor has its own selection');
        System.assertEquals(true, supervisor.get(keys[1]), 'Saved independently');
        System.assertEquals(masterSize() * 2, [SELECT COUNT() FROM FMCG_Workspace_Visibility__c],
            'Two profiles, two full sets of rows');
    }

    @isTest
    static void saveConfig_thenReadBackThroughTheEndUserMethod() {
        // The admin saves against the running user's own profile, so the end-user
        // method must reflect it immediately — the two surfaces share resolveVisibility.
        String profileName = runningProfileName();
        List<String> keys = masterKeys();

        Test.startTest();
        FMCGWorkspaceConfigController.saveConfig(profileName, new List<String>{ keys[0], keys[1] });
        Map<String, Boolean> visible = FMCGWorkspaceConfigController.getMyVisibleComponents();
        Test.stopTest();

        System.assertEquals(true, visible.get(keys[0]), 'What the admin ticked, the user sees');
        System.assertEquals(true, visible.get(keys[1]), 'Both of them');
        System.assertEquals(false, visible.get(keys[2]), 'And what they did not tick is gone');
    }
}