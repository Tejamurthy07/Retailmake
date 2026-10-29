/**
 * @description DMS secondary billing: a distributor sells onward to a retailer,
 *              billed OUT OF the distributor's own stock (not a company warehouse).
 *              Performs FEFO batch allocation across the distributor's current
 *              Distributor_Stock__c snapshots, a retailer credit check, creates a
 *              secondary Invoice (+ batch-level lines), decrements distributor
 *              stock, and writes distributor Stock_Transaction (Out) rows.
 *
 *              Gated by the DMS master + secondary-billing toggles.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_SecondaryBilling_Service {

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    /** A requested product line for a secondary sale. */
    public class LineRequest {
        public Id productId;
        public Decimal quantity;
        public Decimal unitPrice;

        public LineRequest(Id productId, Decimal quantity, Decimal unitPrice) {
            this.productId = productId;
            this.quantity = quantity;
            this.unitPrice = unitPrice;
        }
    }

    /**
     * @description Creates a secondary invoice from distributor stock (FEFO).
     * @param distributorId The distributor billing the sale (stock source).
     * @param retailerId    The retailer being billed.
     * @param lines         Requested product lines.
     * @return The created Invoice__c id.
     * @throws DMS_SecondaryBillingException on insufficient stock or credit breach.
     */
    public static Id createSecondaryInvoice(Id distributorId, Id retailerId, List<LineRequest> lines) {
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_SECONDARY_BILLING)) {
            throw new DMS_SecondaryBillingException('Secondary billing is not enabled.');
        }
        if (distributorId == null || retailerId == null || lines == null || lines.isEmpty()) {
            throw new DMS_SecondaryBillingException('Distributor, retailer and at least one line are required.');
        }

        Set<Id> productIds = new Set<Id>();
        for (LineRequest lr : lines) {
            if (lr.productId != null && lr.quantity != null && lr.quantity > 0) {
                productIds.add(lr.productId);
            }
        }
        if (productIds.isEmpty()) {
            throw new DMS_SecondaryBillingException('No valid order lines.');
        }

        // Price-list pricing (qty-aware, retailer context) + GST origin/destination states.
        Map<Id, Decimal> qtyByProduct = new Map<Id, Decimal>();
        for (LineRequest lr : lines) {
            if (lr.productId != null && lr.quantity != null && lr.quantity > 0) {
                Decimal prev = qtyByProduct.containsKey(lr.productId) ? qtyByProduct.get(lr.productId) : 0;
                qtyByProduct.put(lr.productId, prev + lr.quantity);
            }
        }
        Map<Id, Decimal> productPrice = DMS_Pricing_Service.priceForLines(qtyByProduct, retailerId);
        Map<Id, String> stateByAccount = new Map<Id, String>();
        for (Account a : [SELECT Id, BillingState FROM Account WHERE Id IN :new Set<Id>{ distributorId, retailerId }]) {
            stateByAccount.put(a.Id, a.BillingState);
        }
        String fromState = stateByAccount.get(distributorId);
        String toState = stateByAccount.get(retailerId);

        // Resolve one price per product (line override else price-list/master fallback).
        Map<Id, Decimal> priceByProduct = new Map<Id, Decimal>();
        for (LineRequest lr : lines) {
            if (lr.productId == null || lr.quantity == null || lr.quantity <= 0) { continue; }
            Decimal price = (lr.unitPrice != null && lr.unitPrice > 0)
                ? lr.unitPrice
                : (productPrice.get(lr.productId) != null ? productPrice.get(lr.productId) : 0);
            priceByProduct.put(lr.productId, price);
        }

        // 1. FEFO-allocate each product's TOTAL quantity ONCE. Aggregating by
        //    product (like createInvoiceFromQuote) prevents a double-decrement when
        //    the same product appears on more than one request line.
        Map<Id, List<Distributor_Stock__c>> stockByProduct = DMS_Fefo_Service.stockByProduct(distributorId, productIds);
        List<DMS_Fefo_Service.Allocation> allocations = new List<DMS_Fefo_Service.Allocation>();
        Decimal invoiceTotal = 0;
        for (Id pid : qtyByProduct.keySet()) {
            Decimal price = priceByProduct.containsKey(pid) ? priceByProduct.get(pid) : 0;
            allocations.addAll(DMS_Fefo_Service.allocate(pid, qtyByProduct.get(pid), stockByProduct.get(pid), price, 'distributor stock'));
            invoiceTotal += qtyByProduct.get(pid) * price;
        }

        // 2. GST per allocation line.
        List<DMS_Tax_Service.LineTaxInput> taxInputs = new List<DMS_Tax_Service.LineTaxInput>();
        for (DMS_Fefo_Service.Allocation a : allocations) {
            taxInputs.add(new DMS_Tax_Service.LineTaxInput(
                a.productId, a.quantity * a.unitPrice, fromState, toState));
        }
        List<DMS_Tax_Service.LineTax> taxes = DMS_Tax_Service.calculate(taxInputs);
        Decimal invoiceTax = 0;
        for (DMS_Tax_Service.LineTax t : taxes) {
            invoiceTax += t.totalTax;
        }

        // 3. Retailer credit check on the gross amount (base + GST).
        assertWithinCredit(retailerId, invoiceTotal + invoiceTax);

        // 4. Create the secondary invoice header.
        Invoice__c invoice = new Invoice__c(
            Account__c               = retailerId,
            Sold_From_Distributor__c = distributorId,
            Order_Type__c            = DMS_Constants.ORDER_TYPE_SECONDARY,
            Invoice_Date__c          = Date.today(),
            Invoice_Number__c        = DMS_Config.secondaryPrefix() + String.valueOf(Datetime.now().getTime()),
            Status__c                = 'Draft',
            Subtotal__c              = invoiceTotal,
            Tax_Amount__c            = invoiceTax,
            Total_Amount__c          = invoiceTotal + invoiceTax,
            Balance_Due__c           = invoiceTotal + invoiceTax
        );
        insert invoice;

        // 4. Invoice lines (batch-level), stock-out snapshots, and transactions.
        List<Invoice_Line__c> invoiceLines = new List<Invoice_Line__c>();
        List<Distributor_Stock__c> stockOut = new List<Distributor_Stock__c>();
        List<Stock_Transaction__c> txns = new List<Stock_Transaction__c>();
        Integer lineNo = 1;

        for (Integer i = 0; i < allocations.size(); i++) {
            DMS_Fefo_Service.Allocation a = allocations[i];
            DMS_Tax_Service.LineTax t = taxes[i];
            invoiceLines.add(new Invoice_Line__c(
                Invoice__c     = invoice.Id,
                Product_Ext__c = a.productId,
                Batch_No__c    = a.batch,
                Quantity__c    = a.quantity,
                Unit_Price__c  = a.unitPrice,
                Line_Number__c = lineNo,
                Total_Amount__c = a.quantity * a.unitPrice,
                Tax_Rate__c    = t.taxRate,
                CGST__c        = t.cgst,
                SGST__c        = t.sgst,
                IGST__c        = t.igst,
                Tax_Amount__c  = t.totalTax
            ));
            lineNo++;

            stockOut.add(new Distributor_Stock__c(
                Account__c       = distributorId,
                Product_Ext__c   = a.productId,
                Batch_No__c      = a.batch,
                Expiry_Date__c   = a.expiryDate,
                Opening_Stock__c = a.currentClosing,
                Received_Qty__c  = 0,
                Sold_Qty__c      = a.quantity,
                Damaged_Qty__c   = 0,
                Stock_Date__c    = Date.today(),
                Is_Current__c    = true
            ));

            txns.add(new Stock_Transaction__c(
                Account__c          = distributorId,
                Product_Ext__c      = a.productId,
                Batch_Number__c     = a.batch,
                Direction__c        = DMS_Constants.DIRECTION_OUT,
                Transaction_Type__c = DMS_Constants.TXN_OUTBOUND_DISPATCH,
                Quantity__c         = a.quantity,
                Transaction_Date__c = Date.today(),
                Reference_Type__c   = 'Invoice',
                Reference_Id__c     = invoice.Id
            ));
        }

        if (!invoiceLines.isEmpty()) {
            insert invoiceLines;
        }
        if (!stockOut.isEmpty()) {
            insert stockOut;
        }
        if (!txns.isEmpty()) {
            insert txns;
        }

        return invoice.Id;
    }

    // ── Invoice from a pre-computed quote (sales-order faithful) ───────────
    // Commercial terms (price, discount, scheme discount, tax split, free qty)
    // come from the source sales-order lines; this method allocates physical
    // stock (FEFO) and writes the invoice + lines + stock movements.
    public class QuoteLine {
        public Id productId;
        public Id orderLineId;
        public String productName;
        public String hsn;
        public Decimal qty;             // base units billed
        public Decimal unitPrice;
        public Decimal discount;        // discount + scheme discount, already prorated
        public Decimal schemeDiscount;
        public Decimal taxRate;
        public Decimal tax;
        public Decimal cgst;
        public Decimal sgst;
        public Decimal igst;
        public Decimal freeQty;
        public Decimal gross;           // qty * unitPrice
        public Decimal net;             // gross - discount + tax
    }

    public static Id createInvoiceFromQuote(Id distributorId, Id retailerId, List<QuoteLine> qlines) {
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_SECONDARY_BILLING)) {
            throw new DMS_SecondaryBillingException('Secondary billing is not enabled.');
        }
        if (distributorId == null || retailerId == null || qlines == null || qlines.isEmpty()) {
            throw new DMS_SecondaryBillingException('Distributor, retailer and at least one line are required.');
        }

        // Physical stock to move per product (base units).
        Set<Id> productIds = new Set<Id>();
        Map<Id, Decimal> qtyByProduct = new Map<Id, Decimal>();
        Decimal subtotal = 0, totalDiscount = 0, totalTax = 0, netTotal = 0;
        for (QuoteLine q : qlines) {
            if (q.productId == null || q.qty == null || q.qty <= 0) { continue; }
            productIds.add(q.productId);
            qtyByProduct.put(q.productId, (qtyByProduct.containsKey(q.productId) ? qtyByProduct.get(q.productId) : 0) + q.qty);
            subtotal += nz(q.gross);
            totalDiscount += nz(q.discount);
            totalTax += nz(q.tax);
            netTotal += nz(q.net);
        }
        if (productIds.isEmpty()) {
            throw new DMS_SecondaryBillingException('No valid order lines.');
        }

        // FEFO-allocate each product's billed quantity across current batches.
        Map<Id, List<Distributor_Stock__c>> stockByProduct = DMS_Fefo_Service.stockByProduct(distributorId, productIds);
        List<DMS_Fefo_Service.Allocation> allocations = new List<DMS_Fefo_Service.Allocation>();
        for (Id pid : qtyByProduct.keySet()) {
            allocations.addAll(DMS_Fefo_Service.allocate(pid, qtyByProduct.get(pid), stockByProduct.get(pid), 0, 'distributor stock'));
        }

        // Retailer credit check on the net (post-tax) amount.
        assertWithinCredit(retailerId, netTotal);

        Invoice__c invoice = new Invoice__c(
            Account__c               = retailerId,
            Sold_From_Distributor__c = distributorId,
            Order_Type__c            = DMS_Constants.ORDER_TYPE_SECONDARY,
            Invoice_Date__c          = Date.today(),
            Invoice_Number__c        = DMS_Config.secondaryPrefix() + String.valueOf(Datetime.now().getTime()),
            Status__c                = 'Draft',
            Subtotal__c              = subtotal,
            Discount_Amount__c       = totalDiscount,
            Tax_Amount__c            = totalTax,
            Net_Amount__c            = netTotal,
            Total_Amount__c          = netTotal,
            Balance_Due__c           = netTotal,
            Total_Items__c           = qlines.size()
        );
        insert invoice;

        // One invoice line per source order line, carrying its (prorated) terms.
        List<Invoice_Line__c> invoiceLines = new List<Invoice_Line__c>();
        Integer lineNo = 1;
        for (QuoteLine q : qlines) {
            if (q.productId == null || q.qty == null || q.qty <= 0) { continue; }
            invoiceLines.add(new Invoice_Line__c(
                Invoice__c        = invoice.Id,
                Product_Ext__c    = q.productId,
                Order_Line_Item__c = q.orderLineId,
                Line_Number__c    = lineNo++,
                Quantity__c       = q.qty,
                Free_Quantity__c  = nz(q.freeQty),
                Unit_Price__c     = q.unitPrice,
                Discount_Amount__c = nz(q.discount),
                Scheme_Discount__c = nz(q.schemeDiscount),
                Tax_Rate__c       = q.taxRate,
                Tax_Amount__c     = nz(q.tax),
                CGST__c           = nz(q.cgst),
                SGST__c           = nz(q.sgst),
                IGST__c           = nz(q.igst),
                Line_Amount__c    = nz(q.gross),
                Net_Amount__c     = nz(q.net),
                Total_Amount__c   = nz(q.net),
                HSN_SAC_Code__c   = q.hsn
            ));
        }

        // Stock-out snapshots + transactions from the FEFO allocation (physical).
        List<Distributor_Stock__c> stockOut = new List<Distributor_Stock__c>();
        List<Stock_Transaction__c> txns = new List<Stock_Transaction__c>();
        for (DMS_Fefo_Service.Allocation a : allocations) {
            stockOut.add(new Distributor_Stock__c(
                Account__c = distributorId, Product_Ext__c = a.productId, Batch_No__c = a.batch,
                Expiry_Date__c = a.expiryDate, Opening_Stock__c = a.currentClosing, Received_Qty__c = 0,
                Sold_Qty__c = a.quantity, Damaged_Qty__c = 0, Stock_Date__c = Date.today(), Is_Current__c = true
            ));
            txns.add(new Stock_Transaction__c(
                Account__c = distributorId, Product_Ext__c = a.productId, Batch_Number__c = a.batch,
                Direction__c = DMS_Constants.DIRECTION_OUT, Transaction_Type__c = DMS_Constants.TXN_OUTBOUND_DISPATCH,
                Quantity__c = a.quantity, Transaction_Date__c = Date.today(),
                Reference_Type__c = 'Invoice', Reference_Id__c = invoice.Id
            ));
        }
        if (!invoiceLines.isEmpty()) { insert invoiceLines; }
        if (!stockOut.isEmpty()) { insert stockOut; }
        if (!txns.isEmpty()) { insert txns; }

        return invoice.Id;
    }

    // ── Credit check ──────────────────────────────────────────────────────

    private static void assertWithinCredit(Id retailerId, Decimal invoiceTotal) {
        Account retailer = [
            SELECT Credit_Limit__c, Outstanding_Balance__c FROM Account WHERE Id = :retailerId
        ];
        if (!DMS_Config.enforceCredit()) {
            return; // credit enforcement disabled by config.
        }
        Decimal creditLimit = retailer.Credit_Limit__c != null ? retailer.Credit_Limit__c : 0;
        if (creditLimit <= 0) {
            return; // 0/blank limit = no credit ceiling enforced.
        }
        Decimal outstanding = retailer.Outstanding_Balance__c != null ? retailer.Outstanding_Balance__c : 0;
        if (outstanding + invoiceTotal > creditLimit) {
            throw new DMS_SecondaryBillingException(
                'Credit limit exceeded for retailer. Limit: ' + creditLimit +
                ', Outstanding: ' + outstanding + ', This sale: ' + invoiceTotal + '.');
        }
    }
}