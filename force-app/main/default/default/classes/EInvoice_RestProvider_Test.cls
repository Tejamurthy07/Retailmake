/**
 * @description Tests the config-driven e-invoice provider routing and the generic REST adapter:
 *              not configured -> mock, configured -> live REST; and the adapter's response mapping
 *              and error handling via HttpCalloutMock.
 */
@isTest
private class EInvoice_RestProvider_Test {

    private class Mock implements HttpCalloutMock {
        Integer code;
        String body;
        Mock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(body);
            return res;
        }
    }

    private static IntegrationTypes.Context ctx() {
        IntegrationTypes.Context c = new IntegrationTypes.Context();
        c.key = 'gst_einvoice';
        c.provider = 'NIC (IRP)';
        c.mode = 'Sandbox';
        c.enabled = true;
        c.requiresCredential = true;
        c.credentialSet = true;
        c.baseUrl = 'https://einv-apisandbox.nic.in';   // no Named Credential -> direct URL (mock intercepts)
        c.settings = new Map<String, Object>();
        return c;
    }

    private static EInvoice_Models.Doc doc() {
        EInvoice_Models.Doc d = new EInvoice_Models.Doc();
        d.docNo = 'INV-1'; d.docDate = Date.today(); d.docType = 'INV';
        d.sellerGstin = '27AAAAA0000A1Z5'; d.buyerGstin = '27BBBBB1111B1Z5';
        d.financialYear = '2025-26'; d.totalValue = 60000; d.itemCount = 1;
        d.mainHsn = '19053100'; d.ewayRequired = true;
        return d;
    }

    private static Integration_Setting__c configuredSetting() {
        return new Integration_Setting__c(
            Integration_Key__c = 'gst_einvoice', Name = 'GST e-Invoice',
            Is_Enabled__c = true, Credential_Set__c = true, Provider__c = 'NIC (IRP)', Mode__c = 'Sandbox');
    }

    // ── Routing ────────────────────────────────────────────────────────────
    @isTest
    static void factory_usesMock_whenNotConfigured() {
        System.assert(EInvoice_ProviderFactory.get() instanceof EInvoice_MockProvider,
            'No integration config -> the built-in mock runs');
    }

    @isTest
    static void factory_usesRest_whenConfigured() {
        insert configuredSetting();
        System.assert(EInvoice_ProviderFactory.get() instanceof EInvoice_RestProvider,
            'Enabled + credential set -> the live REST adapter runs');
    }

    @isTest
    static void factory_staysMock_whenEnabledButNoCredential() {
        insert new Integration_Setting__c(
            Integration_Key__c = 'gst_einvoice', Name = 'GST e-Invoice',
            Is_Enabled__c = true, Credential_Set__c = false, Provider__c = 'NIC (IRP)', Mode__c = 'Sandbox');
        System.assert(EInvoice_ProviderFactory.get() instanceof EInvoice_MockProvider,
            'Enabled but no credential -> still mock (not fully configured)');
    }

    // ── Runtime resolver ───────────────────────────────────────────────────
    @isTest
    static void runtime_resolvesEndpointAndConfigured() {
        insert configuredSetting();
        Test.startTest();
        IntegrationTypes.Context c = IntegrationRuntime.contextFor('gst_einvoice');
        Test.stopTest();
        System.assertEquals(true, c.enabled, 'Enabled reflected');
        System.assertEquals('https://einv-apisandbox.nic.in', c.baseUrl, 'Sandbox URL resolved for NIC (IRP)');
        System.assertEquals(true, IntegrationRuntime.isConfigured('gst_einvoice'), 'Configured');
        System.assertEquals(false, IntegrationRuntime.isConfigured('sms'), 'SMS not configured');
        System.assertEquals(null, IntegrationRuntime.contextFor('does_not_exist'), 'Unknown key -> null');
    }

    // ── Adapter callout ────────────────────────────────────────────────────
    @isTest
    static void rest_register_mapsResponse() {
        String irn = '0123456789012345678901234567890123456789012345678901234567890123';
        Test.setMock(HttpCalloutMock.class, new Mock(200,
            '{"Irn":"' + irn + '","AckNo":"112233445566","SignedQRCode":"a.b.c","EwbNo":"999888777"}'));
        Test.startTest();
        EInvoice_Models.Result r = new EInvoice_RestProvider(ctx()).register(doc());
        Test.stopTest();
        System.assertEquals(true, r.success, 'Live register succeeded');
        System.assertEquals('Generated', r.status, 'Status Generated');
        System.assertEquals(irn, r.irn, 'IRN mapped from response');
        System.assertEquals('112233445566', r.ackNo, 'Ack no mapped');
        System.assert(String.isNotBlank(r.ewbNo), 'E-way number mapped');
    }

    @isTest
    static void rest_register_httpError_fails() {
        Test.setMock(HttpCalloutMock.class, new Mock(500, 'Internal Server Error'));
        Test.startTest();
        EInvoice_Models.Result r = new EInvoice_RestProvider(ctx()).register(doc());
        Test.stopTest();
        System.assertEquals(false, r.success, 'HTTP 500 -> failure');
        System.assertEquals('Failed', r.status, 'Status Failed');
        System.assert(r.message.contains('failed'), 'Error surfaced in message');
    }

    @isTest
    static void rest_register_noIrn_fails() {
        Test.setMock(HttpCalloutMock.class, new Mock(200, '{"AckNo":"1"}'));
        Test.startTest();
        EInvoice_Models.Result r = new EInvoice_RestProvider(ctx()).register(doc());
        Test.stopTest();
        System.assertEquals(false, r.success, 'No IRN -> not success (never fabricated)');
        System.assert(r.message.contains('IRN'), 'Message explains the missing IRN');
    }

    @isTest
    static void rest_cancel_success() {
        Test.setMock(HttpCalloutMock.class, new Mock(200, '{"status":"Cancelled"}'));
        Test.startTest();
        EInvoice_Models.Result r = new EInvoice_RestProvider(ctx()).cancelInvoice('IRN123', 'Wrong buyer GSTIN');
        Test.stopTest();
        System.assertEquals(true, r.success, 'Cancel succeeded');
        System.assertEquals('Cancelled', r.status, 'Status Cancelled');
    }

    @isTest
    static void rest_noEndpoint_failsCleanly() {
        IntegrationTypes.Context c = ctx();
        c.baseUrl = null;           // and no Named Credential
        c.namedCredential = null;
        Test.startTest();
        EInvoice_Models.Result r = new EInvoice_RestProvider(c).register(doc());
        Test.stopTest();
        System.assertEquals(false, r.success, 'No endpoint -> clean failure, no crash');
        System.assertEquals('Failed', r.status, 'Status Failed');
    }
}