/**
 * @description DMS P2 (Super Stockist -> Distributor) fulfillment. The middle tier
 *              of the 3-level network: a Super Stockist sells onward to one of its
 *              downline Distributors, billed OUT OF the Super Stockist's own
 *              Distributor_Stock__c (FEFO), and the goods are RECEIVED into the
 *              buying Distributor's stock via an auto-created GRN.
 *
 *              It combines the secondary-billing pattern (FEFO deduction from the
 *              seller's stock + GST + credit check) with the primary GRN pattern
 *              (post received goods into the buyer's Distributor_Stock__c). Unlike a
 *              company primary, both seller and buyer are Accounts, so no warehouse
 *              is involved.
 *
 *              Gated by the DMS master + P2-fulfillment toggles. Reuses
 *              DMS_SecondaryBillingException for billing failures.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_P2Fulfillment_Service {

    /** A requested product line for a P2 sale. */
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
     * @description Creates a P2 invoice from the Super Stockist's stock (FEFO) and
     *              receives the goods into the buying Distributor's stock.
     * @param superStockistId The selling Super Stockist (stock source).
     * @param distributorId   The buying Distributor (stock destination + billed party).
     * @param lines           Requested product lines.
     * @return The created P2 Invoice__c id.
     * @throws DMS_SecondaryBillingException on disabled toggle, bad input,
     *         insufficient super-stockist stock, or distributor credit breach.
     */
    public static Id createP2Invoice(Id superStockistId, Id distributorId, List<LineRequest> lines) {
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_P2_FULFILLMENT)) {
            throw new DMS_SecondaryBillingException('P2 fulfillment is not enabled.');
        }
        if (superStockistId == null || distributorId == null || lines == null || lines.isEmpty()) {
            throw new DMS_SecondaryBillingException('Super stockist, distributor and at least one line are required.');
        }
        if (superStockistId == distributorId) {
            throw new DMS_SecondaryBillingException('Super stockist and distributor must be different accounts.');
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

        // Price-list pricing (qty-aware, distributor context) + GST origin/destination states.
        Map<Id, Decimal> qtyByProduct = new Map<Id, Decimal>();
        for (LineRequest lr : lines) {
            if (lr.productId != null && lr.quantity != null && lr.quantity > 0) {
                Decimal prev = qtyByProduct.containsKey(lr.productId) ? qtyByProduct.get(lr.productId) : 0;
                qtyByProduct.put(lr.productId, prev + lr.quantity);
            }
        }
        Map<Id, Decimal> productPrice = DMS_Pricing_Service.priceForLines(qtyByProduct, distributorId);
        Map<Id, String> stateByAccount = new Map<Id, String>();
        for (Account a : [SELECT Id, BillingState FROM Account WHERE Id IN :new Set<Id>{ superStockistId, distributorId }]) {
            stateByAccount.put(a.Id, a.BillingState);
        }
        String fromState = stateByAccount.get(superStockistId);
        String toState = stateByAccount.get(distributorId);

        // 1. FEFO-allocate from the super stockist's current stock snapshots.
        Map<Id, List<Distributor_Stock__c>> stockByProduct = DMS_Fefo_Service.stockByProduct(superStockistId, productIds);
        List<DMS_Fefo_Service.Allocation> allocations = new List<DMS_Fefo_Service.Allocation>();
        Decimal invoiceTotal = 0;
        for (LineRequest lr : lines) {
            if (lr.productId == null || lr.quantity == null || lr.quantity <= 0) {
                continue;
            }
            Decimal price = (lr.unitPrice != null && lr.unitPrice > 0)
                ? lr.unitPrice
                : (productPrice.get(lr.productId) != null ? productPrice.get(lr.productId) : 0);
            allocations.addAll(DMS_Fefo_Service.allocate(lr.productId, lr.quantity, stockByProduct.get(lr.productId), price, 'super-stockist stock'));
            invoiceTotal += lr.quantity * price;
        }

        // 2. GST per allocation line.
        List<DMS_Tax_Service.LineTaxInput> taxInputs = new List<DMS_Tax_Service.LineTaxInput>();
        for (DMS_Fefo_Service.Allocation a : allocations) {
            taxInputs.add(new DMS_Tax_Service.LineTaxInput(a.productId, a.quantity * a.unitPrice, fromState, toState));
        }
        List<DMS_Tax_Service.LineTax> taxes = DMS_Tax_Service.calculate(taxInputs);
        Decimal invoiceTax = 0;
        for (DMS_Tax_Service.LineTax t : taxes) {
            invoiceTax += t.totalTax;
        }

        // 3. Distributor credit check on the gross amount (base + GST).
        assertWithinCredit(distributorId, invoiceTotal + invoiceTax);

        // 4. Create the P2 invoice header (buyer = distributor, seller = super stockist).
        Invoice__c invoice = new Invoice__c(
            Account__c               = distributorId,
            Sold_From_Distributor__c = superStockistId,
            Order_Type__c            = DMS_Constants.ORDER_TYPE_P2,
            Invoice_Date__c          = Date.today(),
            Invoice_Number__c        = DMS_Config.p2Prefix() + String.valueOf(Datetime.now().getTime()),
            Status__c                = 'Draft',
            Subtotal__c              = invoiceTotal,
            Tax_Amount__c            = invoiceTax,
            Total_Amount__c          = invoiceTotal + invoiceTax,
            Balance_Due__c           = invoiceTotal + invoiceTax,
            Due_Date__c              = Date.today().addDays(DMS_Config.defaultCreditDays())
        );
        insert invoice;

        // 5. Invoice lines (batch-level) + super-stockist stock-out + out transactions.
        List<Invoice_Line__c> invoiceLines = new List<Invoice_Line__c>();
        List<Distributor_Stock__c> sellerStockOut = new List<Distributor_Stock__c>();
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

            sellerStockOut.add(new Distributor_Stock__c(
                Account__c       = superStockistId,
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
                Account__c          = superStockistId,
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
        if (!invoiceLines.isEmpty()) { insert invoiceLines; }
        if (!sellerStockOut.isEmpty()) { insert sellerStockOut; }

        // 6. Auto-GRN for the buyer (audit) + receive goods into distributor stock.
        receiveIntoDistributor(invoice.Id, distributorId, allocations, txns);

        if (!txns.isEmpty()) { insert txns; }
        return invoice.Id;
    }

    /**
     * @description Creates a Received GRN (audit) for the P2 invoice and posts the
     *              allocated quantities into the buying distributor's stock as new
     *              current snapshots. Out-transactions for the seller are appended to
     *              the supplied txns list; In-transactions for the buyer are added too.
     */
    private static void receiveIntoDistributor(
        Id invoiceId, Id distributorId, List<DMS_Fefo_Service.Allocation> allocations, List<Stock_Transaction__c> txns
    ) {
        // GRN header + lines (inserted as Received purely for audit; stock is posted
        // directly here, so the GRN trigger's afterUpdate path is intentionally not used).
        GRN__c grn = new GRN__c(
            Account__c = distributorId,
            Invoice__c = invoiceId,
            GRN_Date__c = Date.today(),
            Status__c = 'Received'
        );
        insert grn;

        // Current closing per product+batch for the buyer (opening balances).
        Set<Id> productIds = new Set<Id>();
        for (DMS_Fefo_Service.Allocation a : allocations) { productIds.add(a.productId); }
        Map<String, Decimal> currentClosing = new Map<String, Decimal>();
        for (Distributor_Stock__c ds : [
            SELECT Product_Ext__c, Batch_No__c, Closing_Stock__c
            FROM Distributor_Stock__c
            WHERE Account__c = :distributorId AND Product_Ext__c IN :productIds AND Is_Current__c = true
        ]) {
            currentClosing.put(stockKey(ds.Product_Ext__c, ds.Batch_No__c),
                ds.Closing_Stock__c != null ? ds.Closing_Stock__c : 0);
        }

        List<GRN_Line__c> grnLines = new List<GRN_Line__c>();
        List<Distributor_Stock__c> buyerStockIn = new List<Distributor_Stock__c>();
        for (DMS_Fefo_Service.Allocation a : allocations) {
            grnLines.add(new GRN_Line__c(
                GRN__c = grn.Id,
                Product_Ext__c = a.productId,
                Batch_No__c = a.batch,
                Dispatched_Qty__c = a.quantity,
                Received_Qty__c = a.quantity,
                Expiry_Date__c = a.expiryDate
            ));

            Decimal opening = currentClosing.containsKey(stockKey(a.productId, a.batch))
                ? currentClosing.get(stockKey(a.productId, a.batch)) : 0;
            buyerStockIn.add(new Distributor_Stock__c(
                Account__c       = distributorId,
                Product_Ext__c   = a.productId,
                Batch_No__c      = a.batch,
                Expiry_Date__c   = a.expiryDate,
                Opening_Stock__c = opening,
                Received_Qty__c  = a.quantity,
                Sold_Qty__c      = 0,
                Damaged_Qty__c   = 0,
                Stock_Date__c    = Date.today(),
                Is_Current__c    = true
            ));

            txns.add(new Stock_Transaction__c(
                Account__c          = distributorId,
                Product_Ext__c      = a.productId,
                Batch_Number__c     = a.batch,
                Direction__c        = DMS_Constants.DIRECTION_IN,
                Transaction_Type__c = DMS_Constants.TXN_INBOUND_GRN,
                Quantity__c         = a.quantity,
                Transaction_Date__c = Date.today(),
                Reference_Type__c   = 'GRN',
                Reference_Id__c     = grn.Id
            ));
        }
        if (!grnLines.isEmpty()) { insert grnLines; }
        if (!buyerStockIn.isEmpty()) { insert buyerStockIn; }
    }

    private static void assertWithinCredit(Id distributorId, Decimal invoiceTotal) {
        if (!DMS_Config.enforceCredit()) { return; }
        Account dist = [SELECT Credit_Limit__c, Outstanding_Balance__c FROM Account WHERE Id = :distributorId];
        Decimal creditLimit = dist.Credit_Limit__c != null ? dist.Credit_Limit__c : 0;
        if (creditLimit <= 0) { return; }
        Decimal outstanding = dist.Outstanding_Balance__c != null ? dist.Outstanding_Balance__c : 0;
        if (outstanding + invoiceTotal > creditLimit) {
            throw new DMS_SecondaryBillingException(
                'Credit limit exceeded for distributor. Limit: ' + creditLimit +
                ', Outstanding: ' + outstanding + ', This purchase: ' + invoiceTotal + '.');
        }
    }

    private static String stockKey(Id productId, String batch) {
        return String.valueOf(productId) + '|' + (String.isNotBlank(batch) ? batch : '');
    }
}