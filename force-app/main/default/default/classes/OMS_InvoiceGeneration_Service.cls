/**
 * @description Service class responsible for generating Invoice__c and
 *              Invoice_Line__c records from approved Sales Orders. Copies all
 *              line items, tax components, and generates a sequential invoice number.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class OMS_InvoiceGeneration_Service {

    /** Prefix for generated invoice numbers. */
    private static final String INVOICE_PREFIX = 'INV';

    /**
     * @description Generates invoices for a set of approved sales order IDs.
     *              Creates one Invoice__c per Sales Order and copies all associated
     *              Order Line Items as Invoice Line Items with tax details.
     *
     * @param orderIds The set of Sales_Order__c IDs that have been approved.
     */
    public static void generateInvoices(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return;
        }

        // Fetch the approved orders with all required fields
        List<Sales_Order__c> orders = [
            SELECT Id, Name, Account__c, Order_Date__c, Total_Amount__c,
                   Total_Tax__c, Discount_Amount__c, Net_Amount__c,
                   Sales_Rep__c, Region__c, Channel__c,
                   Shipping_State__c, Warehouse_State__c, Warehouse__c,
                   Shipping_Address__c, Billing_Address__c,
                   Payment_Terms__c, Invoice__c,
                   (SELECT Id, Product_Ext__c, Quantity__c, Unit_Price__c,
                           Line_Amount__c, Discount_Amount__c, Discount_Percent__c,
                           Net_Amount__c, CGST__c, SGST__c, IGST__c,
                           Tax_Amount__c, Tax_Rate__c, Total_Amount__c,
                           Scheme__c, Scheme_Discount__c, UOM__c,
                           Batch_Master__c, Batch_Master__r.Batch_Number__c,
                           Batch_Master__r.Expiry_Date__c
                    FROM Order_Line_Items__r)
            FROM Sales_Order__c
            WHERE Id IN :orderIds
              AND Status__c = 'Approved'
        ];

        if (orders.isEmpty()) {
            return;
        }

        // Check for existing invoices to avoid duplicates
        Set<Id> alreadyInvoiced = new Set<Id>();
        for (Invoice__c existing : [
            SELECT Sales_Order__c
            FROM Invoice__c
            WHERE Sales_Order__c IN :orderIds
              AND Status__c != 'Cancelled'
        ]) {
            alreadyInvoiced.add(existing.Sales_Order__c);
        }

        // Generate invoice number base
        String invoiceNumberBase = generateInvoiceNumberBase();
        Integer counter = 1;

        // Create invoice records
        List<Invoice__c> invoicesToInsert = new List<Invoice__c>();
        Map<Id, Invoice__c> invoiceByOrderId = new Map<Id, Invoice__c>();

        for (Sales_Order__c order : orders) {
            if (alreadyInvoiced.contains(order.Id)) {
                continue;
            }

            Invoice__c invoice = new Invoice__c(
                Sales_Order__c       = order.Id,
                Account__c           = order.Account__c,
                Invoice_Date__c      = Date.today(),
                Invoice_Number__c    = invoiceNumberBase + '-' + String.valueOf(counter).leftPad(4, '0'),
                Status__c            = 'Draft',
                Subtotal__c          = order.Total_Amount__c,
                Tax_Amount__c        = order.Total_Tax__c,
                Discount_Amount__c   = order.Discount_Amount__c,
                Total_Amount__c      = order.Net_Amount__c,
                Balance_Due__c       = order.Net_Amount__c,
                Sales_Rep__c         = order.Sales_Rep__c,
                Region__c            = order.Region__c,
                Shipping_Address__c  = order.Shipping_Address__c,
                Billing_Address__c   = order.Billing_Address__c,
                Payment_Terms__c     = order.Payment_Terms__c,
                Due_Date__c          = calculateDueDate(order.Payment_Terms__c),
                Warehouse__c         = order.Warehouse__c
            );

            invoicesToInsert.add(invoice);
            invoiceByOrderId.put(order.Id, invoice);
            counter++;
        }

        if (invoicesToInsert.isEmpty()) {
            return;
        }

        insert invoicesToInsert;

        // Create invoice line items
        List<Invoice_Line__c> lineItemsToInsert = new List<Invoice_Line__c>();

        for (Sales_Order__c order : orders) {
            if (alreadyInvoiced.contains(order.Id)) {
                continue;
            }

            Invoice__c invoice = invoiceByOrderId.get(order.Id);
            if (invoice == null || invoice.Id == null) {
                continue;
            }

            Integer lineNumber = 1;
            for (Order_Line_Item__c orderLine : order.Order_Line_Items__r) {
                Invoice_Line__c invoiceLine = new Invoice_Line__c(
                    Invoice__c          = invoice.Id,
                    Product_Ext__c          = orderLine.Product_Ext__c,
                    Quantity__c         = orderLine.Quantity__c,
                    Unit_Price__c       = orderLine.Unit_Price__c,
                    Line_Amount__c      = orderLine.Line_Amount__c,
                    Discount_Amount__c  = orderLine.Discount_Amount__c,
                    Discount_Percent__c = orderLine.Discount_Percent__c,
                    Net_Amount__c       = orderLine.Net_Amount__c,
                    CGST__c             = orderLine.CGST__c,
                    SGST__c             = orderLine.SGST__c,
                    IGST__c             = orderLine.IGST__c,
                    Tax_Amount__c       = orderLine.Tax_Amount__c,
                    Tax_Rate__c         = orderLine.Tax_Rate__c,
                    Total_Amount__c     = orderLine.Total_Amount__c,
                    Line_Number__c      = lineNumber,
                    UOM__c              = orderLine.UOM__c,
                    Order_Line_Item__c  = orderLine.Id,
                    Batch_No__c         = orderLine.Batch_Master__r.Batch_Number__c,
                    Expiry_Date__c      = orderLine.Batch_Master__r.Expiry_Date__c
                );
                lineItemsToInsert.add(invoiceLine);
                lineNumber++;
            }
        }

        if (!lineItemsToInsert.isEmpty()) {
            insert lineItemsToInsert;
        }

        // Back-link the order to its invoice. Only Invoice__c.Sales_Order__c (child -> parent)
        // was being set, so an order invoiced here still matched the DMS portal's
        // "open orders" filter (Invoice__c = null) and could be billed a SECOND time by a
        // distributor. Writing the reverse link is what makes an order billed-once.
        List<Sales_Order__c> billed = new List<Sales_Order__c>();
        for (Sales_Order__c order : orders) {
            Invoice__c inv = invoiceByOrderId.get(order.Id);
            if (inv != null && inv.Id != null && order.Invoice__c != inv.Id) {
                billed.add(new Sales_Order__c(Id = order.Id, Invoice__c = inv.Id));
            }
        }
        if (!billed.isEmpty()) {
            update billed;
        }

        // Update invoice totals from line items (in case of rounding adjustments)
        updateInvoiceTotals(invoicesToInsert);
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /**
     * @description Generates a date-based invoice number base in the format
     *              INV-YYYYMMDD.
     * @return The invoice number prefix with date.
     */
    private static String generateInvoiceNumberBase() {
        DateTime now = DateTime.now();
        return INVOICE_PREFIX + '-' + now.format('yyyyMMdd');
    }

    /**
     * @description Calculates the payment due date based on the payment terms.
     * @param paymentTerms The payment terms string (e.g., 'Net 30', 'Net 60').
     * @return The calculated due date.
     */
    private static Date calculateDueDate(String paymentTerms) {
        Integer days = 30; // Default to Net 30

        if (String.isNotBlank(paymentTerms)) {
            if (paymentTerms.containsIgnoreCase('Net 7')) {
                days = 7;
            } else if (paymentTerms.containsIgnoreCase('Net 15')) {
                days = 15;
            } else if (paymentTerms.containsIgnoreCase('Net 30')) {
                days = 30;
            } else if (paymentTerms.containsIgnoreCase('Net 45')) {
                days = 45;
            } else if (paymentTerms.containsIgnoreCase('Net 60')) {
                days = 60;
            } else if (paymentTerms.containsIgnoreCase('Net 90')) {
                days = 90;
            } else if (paymentTerms.containsIgnoreCase('COD') ||
                       paymentTerms.containsIgnoreCase('Cash on Delivery')) {
                days = 0;
            } else if (paymentTerms.containsIgnoreCase('Advance')) {
                days = 0;
            }
        }

        return Date.today().addDays(days);
    }

    /**
     * @description Recalculates invoice header totals by aggregating line items.
     *              Ensures header values are consistent with line-level details.
     * @param invoices The list of invoices to update.
     */
    private static void updateInvoiceTotals(List<Invoice__c> invoices) {
        Set<Id> invoiceIds = new Set<Id>();
        for (Invoice__c inv : invoices) {
            invoiceIds.add(inv.Id);
        }

        Map<Id, AggregateResult> totals = new Map<Id, AggregateResult>();
        for (AggregateResult ar : [
            SELECT Invoice__c invoiceId,
                   SUM(Line_Amount__c) sumLineAmount,
                   SUM(Discount_Amount__c) sumDiscount,
                   SUM(Net_Amount__c) sumNetAmount,
                   SUM(Tax_Amount__c) sumTax,
                   SUM(Total_Amount__c) sumTotal
            FROM Invoice_Line__c
            WHERE Invoice__c IN :invoiceIds
            GROUP BY Invoice__c
        ]) {
            totals.put((Id) ar.get('invoiceId'), ar);
        }

        List<Invoice__c> invoicesToUpdate = new List<Invoice__c>();
        for (Invoice__c inv : invoices) {
            AggregateResult ar = totals.get(inv.Id);
            if (ar != null) {
                Invoice__c updateInv = new Invoice__c(
                    Id = inv.Id,
                    Subtotal__c        = (Decimal) ar.get('sumLineAmount'),
                    Discount_Amount__c = (Decimal) ar.get('sumDiscount'),
                    Tax_Amount__c      = (Decimal) ar.get('sumTax'),
                    Total_Amount__c    = (Decimal) ar.get('sumTotal'),
                    Balance_Due__c     = (Decimal) ar.get('sumTotal')
                );
                invoicesToUpdate.add(updateInv);
            }
        }

        if (!invoicesToUpdate.isEmpty()) {
            update invoicesToUpdate;
        }
    }
}