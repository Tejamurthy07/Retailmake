/**
 * @description Provider seam for e-invoicing. The mock provider ships today; a real
 *              IRP/GSP adapter (ClearTax, Masters India, NIC sandbox, etc.) implements
 *              the same interface and is swapped in via EInvoice_ProviderFactory once a
 *              Named Credential + config are in place — no change to the service or UI.
 */
public interface EInvoice_Provider {
    /** Register an invoice with the IRP and return the IRN / signed-QR / e-way artefacts. */
    EInvoice_Models.Result register(EInvoice_Models.Doc doc);

    /** Cancel a previously registered e-invoice by IRN. */
    EInvoice_Models.Result cancelInvoice(String irn, String reason);
}