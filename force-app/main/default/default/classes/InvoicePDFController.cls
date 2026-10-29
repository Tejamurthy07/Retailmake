public without sharing class InvoicePDFController {
    public Invoice__c invoice { get; set; }
    public List<LineItemWrapper> lineItems { get; set; }
    public Decimal amountPaid { get; set; }
    public String amountInWords { get; set; }
    public Integer creditDays { get; set; }

    // Rendered values exposed as controller properties so the PDF does not depend on
    // the running (portal) user's field-level security — the class is `without sharing`.
    public Date invoiceDate { get; set; }
    public Date dueDate { get; set; }
    public String gstin { get; set; }
    public String eWayBillNo { get; set; }
    public String vehicleNo { get; set; }
    public String transporter { get; set; }
    public String orderRef { get; set; }
    public Boolean hasEInvoice { get; set; }
    public String irn { get; set; }
    public String ackNo { get; set; }
    public Datetime ackDate { get; set; }
    public String eInvStatus { get; set; }
    public Datetime eWayValidUntil { get; set; }
    public Decimal subtotalAmt { get; set; }
    public Decimal taxAmt { get; set; }
    public Decimal grandTotal { get; set; }
    public Decimal balanceDue { get; set; }

    public class PdfAccessException extends Exception {}

    // Custom-controller entry (Experience portal): id comes from the URL parameter.
    public InvoicePDFController() {
        load((Id) ApexPages.currentPage().getParameters().get('id'));
    }

    // Standard-controller extension entry (internal record button + tests).
    public InvoicePDFController(ApexPages.StandardController stdController) {
        load(stdController.getId());
    }

    private void load(Id invId) {
        invoice = [SELECT Id, Name, Invoice_Date__c, Due_Date__c, Status__c,
                          Total_Amount__c, Subtotal__c, Tax_Amount__c, Net_Amount__c, Balance_Due__c,
                          GSTIN__c, E_Invoice_IRN__c, E_Invoice_Ack_No__c, E_Invoice_Ack_Date__c,
                          E_Invoice_Status__c, E_Way_Bill_No__c, E_Way_Bill_Valid_Until__c,
                          Vehicle_No__c, Transporter__c,
                          Account__c, Sold_From_Distributor__c, Account__r.ParentId,
                          Sales_Order__r.Name,
                          Account__r.Name, Account__r.BillingStreet, Account__r.BillingCity,
                          Account__r.BillingState, Account__r.BillingPostalCode,
                          Account__r.ShippingStreet, Account__r.ShippingCity,
                          Account__r.ShippingState, Account__r.ShippingPostalCode
                   FROM Invoice__c WHERE Id = :invId];

        enforceScope();

        List<Invoice_Line__c> lines = [SELECT Id, Product_Ext__r.Name, HSN_SAC_Code__c,
                                              Quantity__c, Unit_Price__c, Discount__c,
                                              CGST__c, SGST__c, IGST__c, Tax_Amount__c, Line_Total__c,
                                              Total_Amount__c, Batch_No__c, Expiry_Date__c
                                       FROM Invoice_Line__c
                                       WHERE Invoice__c = :invId
                                       ORDER BY CreatedDate];

        lineItems = new List<LineItemWrapper>();
        Integer idx = 1;
        for (Invoice_Line__c line : lines) {
            lineItems.add(new LineItemWrapper(idx, line));
            idx++;
        }

        // Calculate amount paid
        AggregateResult[] payments = [SELECT SUM(Amount__c) totalPaid
                                      FROM Collection__c
                                      WHERE Invoice__c = :invId AND Status__c = 'Cleared'];
        amountPaid = payments.isEmpty() || payments[0].get('totalPaid') == null ? 0 : (Decimal)payments[0].get('totalPaid');

        // Amount in words — use the invoice grand total (Net_Amount is not populated).
        amountInWords = numberToWords(invoice.Total_Amount__c != null ? invoice.Total_Amount__c.intValue() : 0);

        creditDays = 30; // Default, could come from config

        // FLS-independent display values.
        invoiceDate = invoice.Invoice_Date__c;
        dueDate = invoice.Due_Date__c;
        gstin = invoice.GSTIN__c;
        eWayBillNo = invoice.E_Way_Bill_No__c;
        vehicleNo = invoice.Vehicle_No__c;
        transporter = invoice.Transporter__c;
        irn = invoice.E_Invoice_IRN__c;
        ackNo = invoice.E_Invoice_Ack_No__c;
        ackDate = invoice.E_Invoice_Ack_Date__c;
        eInvStatus = invoice.E_Invoice_Status__c;
        eWayValidUntil = invoice.E_Way_Bill_Valid_Until__c;
        hasEInvoice = String.isNotBlank(invoice.E_Invoice_IRN__c);
        orderRef = (invoice.Sales_Order__r != null) ? invoice.Sales_Order__r.Name : '';
        subtotalAmt = invoice.Subtotal__c;
        taxAmt = invoice.Tax_Amount__c;
        grandTotal = invoice.Total_Amount__c;
        balanceDue = invoice.Balance_Due__c;
    }

    // Portal (community) users may only render invoices in their own distributor
    // scope — the same scope the portal list uses. Internal users (no community
    // Account) are unaffected.
    private void enforceScope() {
        Id acctId = runningCommunityAccountId();
        if (acctId == null) { return; }
        Boolean inScope = invoice.Account__c == acctId
            || invoice.Sold_From_Distributor__c == acctId
            || (invoice.Account__r != null && invoice.Account__r.ParentId == acctId);
        if (!inScope) {
            throw new PdfAccessException('You do not have access to this invoice.');
        }
    }

    private Id runningCommunityAccountId() {
        User u = [SELECT ContactId, Contact.AccountId FROM User WHERE Id = :UserInfo.getUserId()];
        return (u.ContactId != null && u.Contact != null) ? u.Contact.AccountId : null;
    }

    public class LineItemWrapper {
        public Integer index { get; set; }
        public Invoice_Line__c line { get; set; }
        public String productName { get; set; }
        public String hsn { get; set; }
        public Decimal qty { get; set; }
        public Decimal unitPrice { get; set; }
        public Decimal discount { get; set; }
        public Decimal cgst { get; set; }
        public Decimal sgst { get; set; }
        public Decimal igst { get; set; }
        public Decimal lineTotal { get; set; }
        public LineItemWrapper(Integer idx, Invoice_Line__c l) {
            this.index = idx;
            this.line = l;
            this.productName = (l.Product_Ext__r != null) ? l.Product_Ext__r.Name : '';
            this.hsn = l.HSN_SAC_Code__c;
            this.qty = l.Quantity__c;
            this.unitPrice = l.Unit_Price__c;
            this.discount = l.Discount__c;
            this.cgst = l.CGST__c;
            this.sgst = l.SGST__c;
            this.igst = l.IGST__c;
            this.lineTotal = l.Total_Amount__c;   // Line_Total__c is not populated
        }
    }

    private static String numberToWords(Integer num) {
        if (num == 0) return 'Zero';
        String[] ones = new String[]{'', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
                                     'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
                                     'Seventeen', 'Eighteen', 'Nineteen'};
        String[] tens = new String[]{'', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'};

        if (num < 20) return ones[num];
        if (num < 100) return tens[num/10] + (Math.mod(num, 10) != 0 ? ' ' + ones[Math.mod(num, 10)] : '');
        if (num < 1000) return ones[num/100] + ' Hundred' + (Math.mod(num, 100) != 0 ? ' and ' + numberToWords(Math.mod(num, 100)) : '');
        if (num < 100000) return numberToWords(num/1000) + ' Thousand' + (Math.mod(num, 1000) != 0 ? ' ' + numberToWords(Math.mod(num, 1000)) : '');
        if (num < 10000000) return numberToWords(num/100000) + ' Lakh' + (Math.mod(num, 100000) != 0 ? ' ' + numberToWords(Math.mod(num, 100000)) : '');
        return numberToWords(num/10000000) + ' Crore' + (Math.mod(num, 10000000) != 0 ? ' ' + numberToWords(Math.mod(num, 10000000)) : '');
    }
}