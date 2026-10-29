/**
 * @description Live e-invoice provider: a GENERIC REST adapter that runs when the GST e-Invoice
 *              integration is configured in the Integrations window. It calls the configured
 *              endpoint (the integration's Named Credential, which carries auth; else the provider's
 *              resolved base URL) and maps a common IRP/GSP JSON response onto EInvoice_Models.Result.
 *
 *              This is deliberately provider-agnostic: the request/response field mapping covers the
 *              usual IRP shapes (Irn / AckNo / SignedQRCode / EwbNo) and the request path is
 *              overridable via settings (registerPath / cancelPath). Wiring a specific provider
 *              (NIC's encryption handshake, or a particular GSP's schema) is a focused follow-up —
 *              nothing else in the e-invoice engine or the UI changes. An unrecognised response
 *              fails cleanly rather than fabricating an IRN.
 */
public with sharing class EInvoice_RestProvider implements EInvoice_Provider {

    private final IntegrationTypes.Context ctx;

    public EInvoice_RestProvider(IntegrationTypes.Context ctx) {
        this.ctx = ctx;
    }

    public EInvoice_Models.Result register(EInvoice_Models.Doc doc) {
        Map<String, Object> body = new Map<String, Object>{
            'docNo' => doc.docNo,
            'docDate' => doc.docDate == null ? null : String.valueOf(doc.docDate),
            'docType' => doc.docType,
            'sellerGstin' => doc.sellerGstin,
            'buyerGstin' => doc.buyerGstin,
            'financialYear' => doc.financialYear,
            'totalValue' => doc.totalValue,
            'itemCount' => doc.itemCount,
            'mainHsn' => doc.mainHsn,
            'ewayRequired' => doc.ewayRequired
        };
        try {
            HttpResponse res = call(pathOf('registerPath', '/einvoice/register'), JSON.serialize(body));
            return parseRegister(res);
        } catch (Exception e) {
            return failed('Could not reach the e-invoice provider: ' + e.getMessage());
        }
    }

    public EInvoice_Models.Result cancelInvoice(String irn, String reason) {
        Map<String, Object> body = new Map<String, Object>{ 'irn' => irn, 'reason' => reason };
        try {
            HttpResponse res = call(pathOf('cancelPath', '/einvoice/cancel'), JSON.serialize(body));
            EInvoice_Models.Result r = new EInvoice_Models.Result();
            if (ok(res)) {
                r.success = true; r.status = 'Cancelled'; r.irn = irn;
                r.message = 'Cancelled via ' + providerLabel() + '.';
            } else {
                r.success = false; r.status = 'Failed';
                r.message = 'Cancel failed: ' + describe(res);
            }
            return r;
        } catch (Exception e) {
            return failed('Could not reach the e-invoice provider: ' + e.getMessage());
        }
    }

    // ── HTTP ───────────────────────────────────────────────────────────────
    private HttpResponse call(String resourcePath, String body) {
        String base = baseEndpoint();
        if (String.isBlank(base)) {
            throw new CalloutException(
                'No endpoint configured. Set a provider with a base URL, or a Named Credential, for this integration.');
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(base + resourcePath);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);
        req.setBody(body);
        return new Http().send(req);
    }

    /** Prefer the Named Credential (it carries auth); fall back to the resolved provider base URL. */
    private String baseEndpoint() {
        if (ctx != null && String.isNotBlank(ctx.namedCredential)) {
            return 'callout:' + ctx.namedCredential;
        }
        return ctx == null ? null : ctx.baseUrl;
    }

    private String pathOf(String settingKey, String fallback) {
        if (ctx != null && ctx.settings != null && ctx.settings.get(settingKey) != null) {
            String p = String.valueOf(ctx.settings.get(settingKey));
            if (String.isNotBlank(p)) { return p; }
        }
        return fallback;
    }

    // ── Response mapping ───────────────────────────────────────────────────
    private EInvoice_Models.Result parseRegister(HttpResponse res) {
        if (!ok(res)) {
            return failed('IRP registration failed: ' + describe(res));
        }
        Map<String, Object> data;
        try {
            data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        } catch (Exception e) {
            return failed('Unreadable IRP response: ' + abbreviate(res.getBody(), 200));
        }
        // Some providers nest the artefacts under a "data" object.
        if (data.get('data') instanceof Map<String, Object>) {
            data = (Map<String, Object>) data.get('data');
        }

        EInvoice_Models.Result r = new EInvoice_Models.Result();
        r.irn = firstOf(data, new List<String>{ 'Irn', 'irn' });
        r.ackNo = firstOf(data, new List<String>{ 'AckNo', 'ackNo', 'ack_no' });
        r.signedQr = firstOf(data, new List<String>{ 'SignedQRCode', 'signedQRCode', 'signedQr', 'qrCode' });
        r.ewbNo = firstOf(data, new List<String>{ 'EwbNo', 'ewbNo' });

        if (String.isBlank(r.irn)) {
            return failed('IRP response contained no IRN. Body: ' + abbreviate(res.getBody(), 200));
        }
        r.success = true;
        r.status = 'Generated';
        r.ackDate = Datetime.now();
        if (String.isNotBlank(r.ewbNo)) {
            r.ewbDate = Datetime.now();
            r.ewbValidUntil = Datetime.now().addDays(1);
        }
        r.message = 'Registered via ' + providerLabel() + ' (' + (ctx == null ? '' : ctx.mode) + ').';
        return r;
    }

    // ── Helpers ────────────────────────────────────────────────────────────
    private Boolean ok(HttpResponse res) {
        return res != null && res.getStatusCode() >= 200 && res.getStatusCode() < 300;
    }
    private String firstOf(Map<String, Object> m, List<String> keys) {
        for (String k : keys) {
            if (m.get(k) != null) { return String.valueOf(m.get(k)); }
        }
        return null;
    }
    private String providerLabel() {
        return ctx != null && String.isNotBlank(ctx.provider) ? ctx.provider : 'provider';
    }
    private EInvoice_Models.Result failed(String msg) {
        EInvoice_Models.Result r = new EInvoice_Models.Result();
        r.success = false; r.status = 'Failed'; r.message = msg;
        return r;
    }
    private String describe(HttpResponse res) {
        return res == null ? 'no response' : 'HTTP ' + res.getStatusCode() + ' ' + abbreviate(res.getBody(), 200);
    }
    private String abbreviate(String v, Integer max) {
        if (v == null) { return ''; }
        return v.length() > max ? v.substring(0, max) : v;
    }
}