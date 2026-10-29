public with sharing class SalesOrderPDFController {
    public Sales_Order__c salesOrder { get; set; }
    public List<LineItemWrapper> lineItems { get; set; }
    public String amountInWords { get; set; }
    public String formattedOrderDate { get; set; }
    public String formattedDeliveryDate { get; set; }

    public SalesOrderPDFController(ApexPages.StandardController stdController) {
        salesOrder = (Sales_Order__c)stdController.getRecord();
        salesOrder = [SELECT Id, Name, Status__c, Order_Date__c, Delivery_Date__c, Notes__c,
                             Total_Gross_Amount__c, Total_Discount__c, Total_Tax__c, Total_Net_Amount__c,
                             Channel__c, Trade_Channel__c, Payment_Terms__c,
                             Territory__r.Name, Warehouse__r.Name,
                             Account__r.Name, Account__r.BillingStreet, Account__r.BillingCity,
                             Account__r.BillingState, Account__r.BillingPostalCode,
                             Account__r.GSTIN__c, Account__r.Channel__c, Account__r.Phone,
                             Account__r.ShippingStreet, Account__r.ShippingCity,
                             Account__r.ShippingState, Account__r.ShippingPostalCode
                      FROM Sales_Order__c WHERE Id = :salesOrder.Id];

        List<Order_Line_Item__c> lines = [SELECT Id, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c,
                                                 HSN_SAC_Code__c, Quantity__c, Free_Quantity__c, UOM__c,
                                                 Unit_Price__c, Line_Total__c, Discount_Amount__c,
                                                 Tax_Rate__c, Tax_Amount__c, CGST__c, SGST__c, IGST__c,
                                                 Total_Amount__c
                                          FROM Order_Line_Item__c
                                          WHERE Sales_Order__c = :salesOrder.Id
                                          ORDER BY CreatedDate];

        lineItems = new List<LineItemWrapper>();
        Integer idx = 1;
        for (Order_Line_Item__c line : lines) {
            lineItems.add(new LineItemWrapper(idx, line));
            idx++;
        }

        // Amount in words
        amountInWords = numberToWords(salesOrder.Total_Net_Amount__c != null ? salesOrder.Total_Net_Amount__c.intValue() : 0);
    }

    public class LineItemWrapper {
        public Integer index { get; set; }
        public Order_Line_Item__c line { get; set; }
        public LineItemWrapper(Integer idx, Order_Line_Item__c l) {
            this.index = idx;
            this.line = l;
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