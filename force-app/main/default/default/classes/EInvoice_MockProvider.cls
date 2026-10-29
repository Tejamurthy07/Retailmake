/**
 * @description Local, credential-free e-invoice provider for development, demo and
 *              tenants not yet connected to a live IRP. It reproduces the *shape* of a
 *              real government response deterministically:
 *                - IRN  = SHA-256 hex of "SellerGSTIN|DocType|DocNo|FY" (the real IRP hash)
 *                - QR   = the government QR JSON payload wrapped as a mock signed JWT
 *                - AckNo/EWB numbers derived from the same digest
 *              Nothing here contacts an external system; the JWT signature is a mock.
 */
public without sharing class EInvoice_MockProvider implements EInvoice_Provider {

    public EInvoice_Models.Result register(EInvoice_Models.Doc doc) {
        EInvoice_Models.Result r = new EInvoice_Models.Result();

        String seed = doc.sellerGstin + '|' + doc.docType + '|' + doc.docNo + '|' + doc.financialYear;
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(seed));

        r.irn = EncodingUtil.convertToHex(digest);        // 64 lowercase hex chars, like a real IRN
        r.ackNo = digitsFromBlob(digest, 15);
        r.ackDate = Datetime.now();
        r.status = 'Generated';
        r.signedQr = buildSignedQr(doc, r.irn);
        r.success = true;
        r.message = 'Registered by the built-in mock IRP provider.';

        if (doc.ewayRequired == true) {
            r.ewbNo = digitsFromBlob(Crypto.generateDigest('SHA-256', Blob.valueOf('EWB|' + seed)), 12);
            r.ewbDate = r.ackDate;
            r.ewbValidUntil = r.ackDate.addDays(1);        // mock validity (real: ~1 day per 200 km)
        }
        return r;
    }

    public EInvoice_Models.Result cancelInvoice(String irn, String reason) {
        EInvoice_Models.Result r = new EInvoice_Models.Result();
        r.irn = irn;
        r.status = 'Cancelled';
        r.success = true;
        r.message = String.isBlank(reason) ? 'E-invoice cancelled.' : reason;
        return r;
    }

    /** Government QR payload (SellerGstin, BuyerGstin, DocNo, ... , Irn) as a mock signed JWT. */
    private String buildSignedQr(EInvoice_Models.Doc doc, String irn) {
        Map<String, Object> payload = new Map<String, Object>{
            'SellerGstin' => doc.sellerGstin,
            'BuyerGstin'  => doc.buyerGstin,
            'DocNo'       => doc.docNo,
            'DocTyp'      => doc.docType,
            'DocDt'       => (doc.docDate == null ? '' : formatDdMmYyyy(doc.docDate)),
            'TotInvVal'   => doc.totalValue,
            'ItemCnt'     => doc.itemCount,
            'MainHsnCode' => doc.mainHsn,
            'Irn'         => irn,
            'IrnDt'       => Datetime.now().format('yyyy-MM-dd HH:mm:ss')
        };
        String header = base64Url(Blob.valueOf('{"alg":"RS256","typ":"JWT"}'));
        String body = base64Url(Blob.valueOf(JSON.serialize(payload)));
        String sig = base64Url(Crypto.generateDigest('SHA-256', Blob.valueOf(header + '.' + body)));
        return header + '.' + body + '.' + sig;
    }

    private String base64Url(Blob b) {
        return EncodingUtil.base64Encode(b).replace('+', '-').replace('/', '_').replace('=', '');
    }

    private String formatDdMmYyyy(Date d) {
        return padLeft(String.valueOf(d.day()), 2) + '/' + padLeft(String.valueOf(d.month()), 2) + '/' + String.valueOf(d.year());
    }

    /** Deterministic N-digit numeric string derived from a digest (leading digit non-zero). */
    private String digitsFromBlob(Blob b, Integer n) {
        String hex = EncodingUtil.convertToHex(b);
        String digits = '';
        for (Integer i = 0; i < hex.length() && digits.length() < n; i++) {
            Integer v = '0123456789abcdef'.indexOf(hex.substring(i, i + 1));
            digits += String.valueOf(Math.mod(v, 10));
        }
        while (digits.length() < n) { digits += '1'; }
        if (digits.startsWith('0')) { digits = '1' + digits.substring(1); }
        return digits.substring(0, n);
    }

    private String padLeft(String s, Integer n) {
        while (s.length() < n) { s = '0' + s; }
        return s;
    }
}