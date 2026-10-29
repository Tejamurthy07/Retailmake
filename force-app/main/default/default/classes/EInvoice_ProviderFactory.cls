/**
 * @description Resolves the active e-invoice provider from the Integrations window (the source of
 *              truth). When the GST e-Invoice integration is enabled AND its credential is set, the
 *              live REST adapter runs against the configured endpoint; otherwise the built-in mock
 *              runs so the flow stays fully exercisable for demo / not-yet-connected tenants.
 *              Tests inject via setOverride.
 */
public without sharing class EInvoice_ProviderFactory {

    @TestVisible private static EInvoice_Provider providerOverride;

    private static final String INTEGRATION_KEY = 'gst_einvoice';

    public static EInvoice_Provider get() {
        if (providerOverride != null) { return providerOverride; }
        IntegrationTypes.Context ctx = IntegrationRuntime.contextFor(INTEGRATION_KEY);
        if (ctx != null && ctx.enabled && ctx.credentialSet) {
            return new EInvoice_RestProvider(ctx);   // configured -> real IRP/GSP callout
        }
        return new EInvoice_MockProvider();          // not configured -> local mock
    }

    @TestVisible
    private static void setOverride(EInvoice_Provider p) {
        providerOverride = p;
    }
}