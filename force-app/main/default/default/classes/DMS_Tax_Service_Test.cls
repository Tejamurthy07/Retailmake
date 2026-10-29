/**
 * @description Tests for DMS_Tax_Service GST calculation: intra-state (CGST+SGST),
 *              inter-state (IGST), product-master GST fallback, and zero-rate.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_Tax_Service_Test {

    private static Id taxedProduct(Decimal gstRate) {
        Product_Extension__c p = new Product_Extension__c(
            Name = 'Taxed Product', SKU_Code__c = 'TAX-' + String.valueOf(Datetime.now().getTime()),
            Is_Active__c = true, GST_Rate__c = gstRate
        );
        insert p;
        return p.Id;
    }

    @isTest
    static void intraState_splitsCgstSgst() {
        Id pid = taxedProduct(18);
        Test.startTest();
        List<DMS_Tax_Service.LineTax> result = DMS_Tax_Service.calculate(
            new List<DMS_Tax_Service.LineTaxInput>{
                new DMS_Tax_Service.LineTaxInput(pid, 1000, 'Maharashtra', 'Maharashtra')
            });
        Test.stopTest();

        DMS_Tax_Service.LineTax t = result[0];
        System.assertEquals(false, t.isInterState, 'Intra-state');
        System.assertEquals(90, t.cgst, 'CGST = 9% of 1000');
        System.assertEquals(90, t.sgst, 'SGST = 9% of 1000');
        System.assertEquals(0, t.igst, 'No IGST intra-state');
        System.assertEquals(180, t.totalTax, 'Total GST = 18% of 1000');
    }

    @isTest
    static void interState_appliesIgst() {
        Id pid = taxedProduct(18);
        Test.startTest();
        List<DMS_Tax_Service.LineTax> result = DMS_Tax_Service.calculate(
            new List<DMS_Tax_Service.LineTaxInput>{
                new DMS_Tax_Service.LineTaxInput(pid, 1000, 'Maharashtra', 'Karnataka')
            });
        Test.stopTest();

        DMS_Tax_Service.LineTax t = result[0];
        System.assertEquals(true, t.isInterState, 'Inter-state');
        System.assertEquals(180, t.igst, 'IGST = 18% of 1000');
        System.assertEquals(0, t.cgst, 'No CGST inter-state');
        System.assertEquals(180, t.totalTax, 'Total GST = 18% of 1000');
    }

    @isTest
    static void zeroRate_noTax() {
        Id pid = taxedProduct(0);
        Test.startTest();
        List<DMS_Tax_Service.LineTax> result = DMS_Tax_Service.calculate(
            new List<DMS_Tax_Service.LineTaxInput>{
                new DMS_Tax_Service.LineTaxInput(pid, 1000, 'Maharashtra', 'Maharashtra')
            });
        Test.stopTest();
        System.assertEquals(0, result[0].totalTax, 'No tax when GST rate is zero');
    }

    @isTest
    static void mixedStatePairs_handledInOneCall() {
        Id pid = taxedProduct(12);
        Test.startTest();
        List<DMS_Tax_Service.LineTax> result = DMS_Tax_Service.calculate(
            new List<DMS_Tax_Service.LineTaxInput>{
                new DMS_Tax_Service.LineTaxInput(pid, 1000, 'Maharashtra', 'Maharashtra'),
                new DMS_Tax_Service.LineTaxInput(pid, 1000, 'Maharashtra', 'Karnataka')
            });
        Test.stopTest();
        System.assertEquals(60, result[0].cgst, 'Line 1 intra CGST 6%');
        System.assertEquals(120, result[1].igst, 'Line 2 inter IGST 12%');
    }
}