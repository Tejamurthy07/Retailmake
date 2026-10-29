/**
 * @description Default connector used until an integration is wired for live callouts. It runs
 *              no callout; it just reports readiness — required credential present, config saved —
 *              so an admin gets a meaningful check before the real connector exists.
 */
public with sharing class StubConnector implements IntegrationConnector {
    public IntegrationTypes.ConnectionResult testConnection(IntegrationTypes.Context ctx) {
        if (ctx.requiresCredential == true && ctx.credentialSet != true) {
            return new IntegrationTypes.ConnectionResult(false,
                'Credential not set — enter and save the API key/secret before testing.');
        }
        return new IntegrationTypes.ConnectionResult(true,
            'Configuration looks complete. A live connection test becomes available once this integration is wired.');
    }
}