/**
 * @description Tests for IntegrationCredentialService, the single write path
 * into the encrypted External Credential store.
 *
 * COVERAGE CEILING (~35-40%) — storeSecret short-circuits on
 * Test.isRunningTest() before any ConnectApi work, so the CredentialInput
 * assembly and the create-then-update fallback (roughly two thirds of the
 * method) are unreachable from Apex tests, full stop. That is a deliberate
 * trade: ConnectApi.NamedCredentials is not mockable and would throw in test
 * context anyway. If more coverage is ever required, the seam has to move —
 * gate only the two ConnectApi.NamedCredentials.*Credential calls behind
 * skipExternalWrite (not the whole assembly), so tests can drive the input
 * building and the fallback branching while stubbing the platform calls.
 * Until then, what CAN be verified is everything that matters to callers:
 * the guards that stop a secret from being silently dropped.
 */
@isTest
private class IntegrationCredentialServiceTest {

    private static Boolean storeThrows(String credName, Map<String, String> secrets) {
        try {
            IntegrationCredentialService.storeSecret(credName, 'Test_Integration', secrets);
            return false;
        } catch (AuraHandledException e) {
            // Constructor-built AHE messages read 'Script-thrown exception' in
            // test context, so the type is the only assertable signal.
            return true;
        }
    }

    private static Map<String, String> oneSecret() {
        return new Map<String, String>{ 'API_Key' => 'shh-not-really' };
    }

    // ── The guards ────────────────────────────────────────────────────

    @isTest
    static void store_withNoCredentialStoreConfigured_isRefused() {
        Test.startTest();
        System.assert(storeThrows(null, oneSecret()),
            'A null External Credential name means there is nowhere safe to put the '
            + 'secret — accepting it would silently drop the value');
        System.assert(storeThrows('   ', oneSecret()),
            'Blank is the same as null');
        Test.stopTest();
    }

    @isTest
    static void store_withNoSecrets_isRefused() {
        Test.startTest();
        System.assert(storeThrows('My_External_Cred', null),
            'A null secrets map has nothing to store');
        System.assert(storeThrows('My_External_Cred', new Map<String, String>()),
            'And an empty one is the same — the caller thought it sent a secret, so '
            + 'succeeding here would hide a wiring bug upstream');
        Test.stopTest();
    }

    // ── The test-context seam ─────────────────────────────────────────

    @isTest
    static void store_pastTheGuards_returnsQuietlyInTestContext() {
        Test.startTest();
        IntegrationCredentialService.storeSecret(
            'My_External_Cred', 'Test_Integration',
            new Map<String, String>{ 'API_Key' => 'k', 'Client_Secret' => 's' });
        Test.stopTest();

        // No exception is the whole assertion: valid input clears every guard
        // and the Test.isRunningTest() seam stops short of ConnectApi, which
        // would otherwise throw in test context. Nothing is persisted anywhere
        // observable — by design, the secret never touches our own objects.
        System.assert(true, 'Guards passed and the seam returned before ConnectApi');
    }

    @isTest
    static void store_seamFlagFalse_stillShortCircuitsInTests() {
        IntegrationCredentialService.skipExternalWrite = false;

        Test.startTest();
        IntegrationCredentialService.storeSecret('My_External_Cred', 'Test_Integration', oneSecret());
        Test.stopTest();

        // Pins the seam's shape: the check is (skipExternalWrite || isRunningTest),
        // so even with the flag forced off, tests can never reach ConnectApi.
        // This is what caps coverage — see the class comment for where the seam
        // would need to move if that ever changes.
        System.assert(true, 'The OR with Test.isRunningTest() makes the flag moot in tests');
    }

    @isTest
    static void store_guardsFireBeforeTheSeam() {
        IntegrationCredentialService.skipExternalWrite = true;

        Test.startTest();
        System.assert(storeThrows('', oneSecret()),
            'Validation runs before the skip — a bad call is rejected identically in '
            + 'production and in tests, so the seam never masks a caller bug');
        System.assert(storeThrows('My_External_Cred', null),
            'Same for the missing-secret guard');
        Test.stopTest();
    }
}