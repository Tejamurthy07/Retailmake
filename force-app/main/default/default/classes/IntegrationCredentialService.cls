/**
 * @description The single, isolated place where an integration's secret is written into its
 *              encrypted External Credential (Option A). The secret is never persisted on our
 *              Integration_Setting__c record, nor read back — it goes straight into the platform's
 *              encrypted credential store via ConnectApi.NamedCredentials.
 *
 *              The External Credential named by the integration's Named_Credential_Name__c must be
 *              provisioned (with a Named Principal called "Default") and the running user granted
 *              access to it. Each schema secret key becomes an encrypted credential parameter of the
 *              same name, referenceable from a Named Credential header as
 *              {!$Credential.<ExternalCredential>.<key>}.
 */
public with sharing class IntegrationCredentialService {

    /** Test/seam hook: ConnectApi credential writes aren't available in test context. */
    @TestVisible private static Boolean skipExternalWrite = false;

    private static final String PRINCIPAL = 'Default';

    public static void storeSecret(String externalCredentialName, String integrationKey, Map<String, String> secrets) {
        if (String.isBlank(externalCredentialName)) {
            throw new AuraHandledException('This integration has no credential store configured to hold its secret.');
        }
        if (secrets == null || secrets.isEmpty()) {
            throw new AuraHandledException('No secret values were provided.');
        }
        if (skipExternalWrite || Test.isRunningTest()) {
            return;
        }

        ConnectApi.CredentialInput input = new ConnectApi.CredentialInput();
        input.externalCredential = externalCredentialName;
        input.principalName = PRINCIPAL;
        input.principalType = ConnectApi.CredentialPrincipalType.NamedPrincipal;
        input.authenticationProtocol = ConnectApi.CredentialAuthenticationProtocol.Custom;

        Map<String, ConnectApi.CredentialValueInput> creds = new Map<String, ConnectApi.CredentialValueInput>();
        for (String key : secrets.keySet()) {
            ConnectApi.CredentialValueInput v = new ConnectApi.CredentialValueInput();
            v.value = secrets.get(key);
            v.encrypted = true;
            creds.put(key, v);
        }
        input.credentials = creds;

        // Create for a new principal; if credentials already exist, overwrite them (PUT/update).
        try {
            ConnectApi.NamedCredentials.createCredential(input);
        } catch (Exception createEx) {
            try {
                ConnectApi.NamedCredentials.updateCredential(input);
            } catch (Exception updateEx) {
                throw new AuraHandledException(
                    'Could not store the credential for "' + externalCredentialName + '". '
                    + 'Make sure its External Credential is provisioned and you have access to it. '
                    + updateEx.getMessage());
            }
        }
    }
}