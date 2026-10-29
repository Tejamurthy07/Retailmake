/**
 * @description Shared value types for the integrations framework — passed between the
 *              controller and the per-integration connectors so those never depend on the
 *              controller directly.
 */
public class IntegrationTypes {

    /** Runtime context handed to a connector's testConnection (and live actions). */
    public class Context {
        public String key;
        public String provider;
        public String mode;                 // Sandbox | Live
        public Boolean enabled = false;
        public Boolean requiresCredential = false;
        public Boolean credentialSet = false;
        public String baseUrl;              // resolved for the selected provider + mode
        public String namedCredential;      // API name of the Named Credential (carries auth)
        public Map<String, Object> settings = new Map<String, Object>();  // non-secret only
    }

    /** Outcome of a connection test, surfaced to the window. */
    public class ConnectionResult {
        @AuraEnabled public Boolean ok;
        @AuraEnabled public String message;
        public ConnectionResult() {}
        public ConnectionResult(Boolean ok, String message) {
            this.ok = ok;
            this.message = message;
        }
    }
}