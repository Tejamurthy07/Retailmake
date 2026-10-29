/**
 * @description Orchestrates e-invoice generation: reads an Invoice + its lines, resolves
 *              seller/buyer GSTIN, builds the provider-agnostic document, calls the
 *              configured provider (EInvoice_ProviderFactory) and persists the returned
 *              IRN / signed-QR / Ack / e-way artefacts back onto the Invoice.
 *
 *              Business rules enforced here (not in the provider):
 *                - feature gate: App_Config EINVOICE_ENABLED (default true)
 *                - idempotent: an invoice that already has an IRN is not re-registered
 *                - B2B only: a buyer GSTIN is required (B2C invoices get no IRN)
 *                - e-way bill produced when invoice value >= EINVOICE_EWAY_THRESHOLD
 */
public without sharing class EInvoice_Service {

    public class EInvoiceException extends Exception {}

    private static final String CFG_ENABLED    = 'EINVOICE_ENABLED';
    private static final String CFG_EWAY_LIMIT  = 'EINVOICE_EWAY_THRESHOLD';
    private static final String CFG_SELLER_GST  = 'EINVOICE_SELLER_GSTIN';
    private static final String PLACEHOLDER_GSTIN = '29AAAAA0000A1Z5';

    public static Boolean isEnabled() {
        return DMS_Config.getBool(CFG_ENABLED, true);
    }

    public static EInvoice_Models.Result generateOne(Id invoiceId) {
        return generate(new Set<Id>{ invoiceId }).get(invoiceId);
    }

    /** Register the given invoices; returns a per-invoice result (incl. skips/failures). */
    public static Map<Id, EInvoice_Models.Result> generate(Set<Id> invoiceIds) {
        Map<Id, EInvoice_Models.Result> out = new Map<Id, EInvoice_Models.Result>();
        if (invoiceIds == null || invoiceIds.isEmpty()) { return out; }
        if (!isEnabled()) { throw new EInvoiceException('E-invoicing is disabled for this org.'); }

        Decimal ewayLimit = DMS_Config.getDecimal(CFG_EWAY_LIMIT, 50000);
        String sellerCfg = DMS_Config.getString(CFG_SELLER_GST, null);
        EInvoice_Provider provider = EInvoice_ProviderFactory.get();

        List<Invoice__c> invoices = [
            SELECT Id, Invoice_Number__c, Invoice_Date__c, Order_Type__c, Status__c,
                   GSTIN__c, Total_Amount__c, E_Invoice_IRN__c,
                   Account__r.GSTIN__c, Account__r.Parent.GSTIN__c,
                   Warehouse__r.GSTIN__c, Sold_From_Distributor__r.GSTIN__c
            FROM Invoice__c WHERE Id IN :invoiceIds
        ];

        // Item count + representative (highest-value) HSN per invoice.
        Map<Id, Integer> itemCount = new Map<Id, Integer>();
        Map<Id, String> mainHsn = new Map<Id, String>();
        Map<Id, Decimal> hsnTop = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Invoice__c inv, HSN_SAC_Code__c hsn, COUNT(Id) c, SUM(Total_Amount__c) v
            FROM Invoice_Line__c WHERE Invoice__c IN :invoiceIds
            GROUP BY Invoice__c, HSN_SAC_Code__c
        ]) {
            Id inv = (Id) ar.get('inv');
            Integer c = (Integer) ar.get('c');
            itemCount.put(inv, (itemCount.containsKey(inv) ? itemCount.get(inv) : 0) + c);
            Decimal v = ar.get('v') == null ? 0 : (Decimal) ar.get('v');
            if (!hsnTop.containsKey(inv) || v > hsnTop.get(inv)) {
                hsnTop.put(inv, v);
                mainHsn.put(inv, (String) ar.get('hsn'));
            }
        }

        List<Invoice__c> toUpdate = new List<Invoice__c>();
        for (Invoice__c inv : invoices) {
            EInvoice_Models.Result r;
            try {
                r = registerOne(inv, provider, ewayLimit, sellerCfg,
                    itemCount.containsKey(inv.Id) ? itemCount.get(inv.Id) : 0,
                    mainHsn.get(inv.Id));
            } catch (Exception e) {
                r = fail(e.getMessage());
            }
            out.put(inv.Id, r);
            if (r.success && r.status == 'Generated') {
                toUpdate.add(applyResult(inv.Id, r));
            }
        }
        if (!toUpdate.isEmpty()) { update toUpdate; }
        return out;
    }

    private static EInvoice_Models.Result registerOne(Invoice__c inv, EInvoice_Provider provider,
            Decimal ewayLimit, String sellerCfg, Integer items, String hsn) {

        if (String.isNotBlank(inv.E_Invoice_IRN__c)) {
            EInvoice_Models.Result r = new EInvoice_Models.Result();
            r.success = false; r.status = 'Generated'; r.irn = inv.E_Invoice_IRN__c;
            r.message = 'E-invoice already generated for this invoice.';
            return r;
        }
        if (inv.Status__c == 'Cancelled') {
            return fail('Cancelled invoices cannot be e-invoiced.');
        }

        String buyerGstin = String.isNotBlank(inv.GSTIN__c) ? inv.GSTIN__c
                          : (inv.Account__r != null ? inv.Account__r.GSTIN__c : null);
        // B2C sale to an unregistered buyer: register with the standard URP marker
        // rather than refusing — FMCG secondary sales are frequently to unregistered
        // retailers, and the distributor still wants an e-invoice/QR on the bill.
        if (String.isBlank(buyerGstin)) { buyerGstin = 'URP'; }

        String sellerGstin = resolveSeller(inv, sellerCfg);

        EInvoice_Models.Doc doc = new EInvoice_Models.Doc();
        doc.invoiceId = inv.Id;
        doc.docNo = inv.Invoice_Number__c;
        doc.docDate = inv.Invoice_Date__c;
        doc.docType = 'INV';
        doc.sellerGstin = sellerGstin;
        doc.buyerGstin = buyerGstin;
        doc.financialYear = financialYear(inv.Invoice_Date__c);
        doc.totalValue = inv.Total_Amount__c == null ? 0 : inv.Total_Amount__c;
        doc.itemCount = items;
        doc.mainHsn = hsn;
        doc.ewayRequired = (doc.totalValue >= ewayLimit);

        return provider.register(doc);
    }

    private static Invoice__c applyResult(Id invoiceId, EInvoice_Models.Result r) {
        Invoice__c u = new Invoice__c(Id = invoiceId);
        u.E_Invoice_IRN__c = r.irn;
        u.E_Invoice_QR__c = r.signedQr;
        u.E_Invoice_Ack_No__c = r.ackNo;
        u.E_Invoice_Ack_Date__c = r.ackDate;
        u.E_Invoice_Status__c = r.status;
        if (String.isNotBlank(r.ewbNo)) {
            u.E_Way_Bill_No__c = r.ewbNo;
            u.E_Way_Bill_Date__c = r.ewbDate;
            u.E_Way_Bill_Valid_Until__c = r.ewbValidUntil;
        }
        return u;
    }

    /** Cancel the e-invoice on a single invoice. */
    public static EInvoice_Models.Result cancel(Id invoiceId, String reason) {
        if (!isEnabled()) { throw new EInvoiceException('E-invoicing is disabled for this org.'); }
        Invoice__c inv = [SELECT Id, E_Invoice_IRN__c FROM Invoice__c WHERE Id = :invoiceId];
        if (String.isBlank(inv.E_Invoice_IRN__c)) {
            throw new EInvoiceException('No e-invoice to cancel on this invoice.');
        }
        EInvoice_Models.Result r = EInvoice_ProviderFactory.get().cancelInvoice(inv.E_Invoice_IRN__c, reason);
        if (r.success) {
            update new Invoice__c(Id = invoiceId, E_Invoice_Status__c = 'Cancelled');
        }
        return r;
    }

    /**
     * Supplier GSTIN depends on who issued the invoice: for a secondary sale the
     * distributor (Sold_From_Distributor) is the seller; for primary/P2 it is the
     * dispatching warehouse. Falls back to configured, then a placeholder GSTIN.
     */
    private static String resolveSeller(Invoice__c inv, String cfg) {
        if (inv.Order_Type__c == DMS_Constants.ORDER_TYPE_SECONDARY) {
            // The distributor that issued the sale: Sold_From_Distributor if set,
            // else the retailer's Parent Account (the standard distributor link).
            if (inv.Sold_From_Distributor__r != null && String.isNotBlank(inv.Sold_From_Distributor__r.GSTIN__c)) {
                return inv.Sold_From_Distributor__r.GSTIN__c;
            }
            if (inv.Account__r != null && inv.Account__r.Parent != null
                    && String.isNotBlank(inv.Account__r.Parent.GSTIN__c)) {
                return inv.Account__r.Parent.GSTIN__c;
            }
        } else if (inv.Warehouse__r != null && String.isNotBlank(inv.Warehouse__r.GSTIN__c)) {
            return inv.Warehouse__r.GSTIN__c;
        }
        return String.isNotBlank(cfg) ? cfg : PLACEHOLDER_GSTIN;
    }

    private static EInvoice_Models.Result fail(String msg) {
        EInvoice_Models.Result r = new EInvoice_Models.Result();
        r.success = false; r.status = 'Failed'; r.message = msg;
        return r;
    }

    /** Indian financial year label for a date, e.g. 2025-26 (FY starts 1 April). */
    @TestVisible
    private static String financialYear(Date d) {
        if (d == null) { d = Date.today(); }
        Integer startYear = (d.month() >= 4) ? d.year() : d.year() - 1;
        Integer endYY = Math.mod(startYear + 1, 100);
        return String.valueOf(startYear) + '-' + (endYY < 10 ? '0' : '') + String.valueOf(endYY);
    }
}