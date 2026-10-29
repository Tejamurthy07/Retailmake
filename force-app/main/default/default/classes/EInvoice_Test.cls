/**
 * @description Tests for the pluggable e-invoicing engine (mock provider): IRN + signed
 *              QR + Ack + e-way generation from real invoice data, idempotency, the
 *              B2C (no buyer GSTIN) guard, cancellation, and the financial-year helper.
 */
@isTest
private class EInvoice_Test {

    private static Warehouse__c makeWarehouse() {
        Warehouse__c wh = new Warehouse__c(
            Name = 'WH EInvoice', Warehouse_Code__c = 'WHEI1',
            State__c = 'Maharashtra', GSTIN__c = '27AAAAA0000A1Z5'
        );
        insert wh;
        return wh;
    }

    private static Invoice__c makeInvoice(Id acctId, Id whId, Id productId, String buyerGstin, Decimal total) {
        Invoice__c inv = new Invoice__c(
            Account__c = acctId, Order_Type__c = 'Primary', Warehouse__c = whId,
            Invoice_Number__c = 'PINV-EI-' + String.valueOf(Datetime.now().getTime()) + '-' + String.valueOf(total.intValue()),
            Invoice_Date__c = Date.today(), Status__c = 'Draft', GSTIN__c = buyerGstin,
            Subtotal__c = total, Total_Amount__c = total, Balance_Due__c = total
        );
        TriggerHandler.bypass('OMS_Invoice_TriggerHandler');
        insert inv;
        TriggerHandler.clearBypass('OMS_Invoice_TriggerHandler');
        insert new Invoice_Line__c(
            Invoice__c = inv.Id, Product_Ext__c = productId, HSN_SAC_Code__c = '19053100',
            Quantity__c = 10, Unit_Price__c = total / 10, Total_Amount__c = total,
            Line_Number__c = 1, Batch_No__c = 'B1'
        );
        return inv;
    }

    @isTest
    static void generate_producesIrnQrAckAndEway() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist EI', 'Distributor');
        Warehouse__c wh = makeWarehouse();
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = makeInvoice(dist.Id, wh.Id, products[0].Id, '27BBBBB1111B1Z5', 60000); // >= e-way threshold

        Test.startTest();
        EInvoice_Models.Result r = EInvoice_Service.generateOne(inv.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Generation succeeded');
        System.assertEquals('Generated', r.status, 'Status Generated');
        System.assertEquals(64, r.irn.length(), 'IRN is a 64-char hash');
        System.assert(String.isNotBlank(r.ackNo), 'Ack No populated');
        System.assert(r.signedQr != null && r.signedQr.contains('.'), 'Signed QR is a JWT-shaped string');
        System.assert(String.isNotBlank(r.ewbNo), 'E-way bill generated above threshold');

        Invoice__c saved = [
            SELECT E_Invoice_IRN__c, E_Invoice_QR__c, E_Invoice_Ack_No__c, E_Invoice_Ack_Date__c,
                   E_Invoice_Status__c, E_Way_Bill_No__c, E_Way_Bill_Valid_Until__c
            FROM Invoice__c WHERE Id = :inv.Id
        ];
        System.assertEquals(r.irn, saved.E_Invoice_IRN__c, 'IRN persisted');
        System.assertEquals('Generated', saved.E_Invoice_Status__c, 'Status persisted');
        System.assertNotEquals(null, saved.E_Invoice_Ack_Date__c, 'Ack date persisted');
        System.assertNotEquals(null, saved.E_Way_Bill_Valid_Until__c, 'E-way validity persisted');
    }

    @isTest
    static void generate_isIdempotent() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist EI2', 'Distributor');
        Warehouse__c wh = makeWarehouse();
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = makeInvoice(dist.Id, wh.Id, products[0].Id, '27BBBBB1111B1Z5', 5000);

        Test.startTest();
        EInvoice_Models.Result first = EInvoice_Service.generateOne(inv.Id);
        EInvoice_Models.Result second = EInvoice_Service.generateOne(inv.Id);
        Test.stopTest();

        System.assertEquals(true, first.success, 'First generation succeeds');
        System.assert(String.isBlank(first.ewbNo), 'No e-way bill below threshold');
        System.assertEquals(false, second.success, 'Second call is a no-op');
        System.assert(second.message.contains('already'), 'Idempotent message returned');
    }

    @isTest
    static void generate_b2cWithoutGstinRegistersAsUrp() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist EI3', 'Distributor');
        Warehouse__c wh = makeWarehouse();
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = makeInvoice(dist.Id, wh.Id, products[0].Id, null, 3000); // no buyer GSTIN

        Test.startTest();
        EInvoice_Models.Result r = EInvoice_Service.generateOne(inv.Id);
        Test.stopTest();

        // B2C sales still register (unregistered buyer -> URP), rather than being refused.
        System.assertEquals(true, r.success, 'B2C invoice registers with URP');
        System.assertEquals('Generated', r.status, 'Status Generated');
        System.assertEquals(64, r.irn.length(), 'IRN present for the B2C sale');
    }

    @isTest
    static void cancel_marksInvoiceCancelled() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist EI4', 'Distributor');
        Warehouse__c wh = makeWarehouse();
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = makeInvoice(dist.Id, wh.Id, products[0].Id, '27BBBBB1111B1Z5', 8000);

        Test.startTest();
        EInvoice_Service.generateOne(inv.Id);
        EInvoice_Models.Result c = EInvoice_Service.cancel(inv.Id, 'Wrong buyer GSTIN');
        Test.stopTest();

        System.assertEquals(true, c.success, 'Cancellation succeeded');
        System.assertEquals('Cancelled', [SELECT E_Invoice_Status__c FROM Invoice__c WHERE Id = :inv.Id].E_Invoice_Status__c,
            'Invoice marked Cancelled');
    }

    @isTest
    static void controller_generateReadCancel() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist EI5', 'Distributor');
        Warehouse__c wh = makeWarehouse();
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Invoice__c inv = makeInvoice(dist.Id, wh.Id, products[0].Id, '27BBBBB1111B1Z5', 70000);

        Test.startTest();
        EInvoiceController.EInvoiceView before = EInvoiceController.getEInvoice(inv.Id);
        System.assertEquals(false, before.generated, 'Not generated yet');
        System.assertEquals(true, before.enabled, 'Feature enabled by default');

        EInvoice_Models.Result r = EInvoiceController.generate(inv.Id);
        System.assertEquals(true, r.success, 'Controller generate succeeds');

        EInvoiceController.EInvoiceView afterGen = EInvoiceController.getEInvoice(inv.Id);
        System.assertEquals(true, afterGen.generated, 'Now generated');
        System.assert(String.isNotBlank(afterGen.irn), 'IRN present in view');
        System.assert(String.isNotBlank(afterGen.ewbNo), 'E-way present in view above threshold');

        EInvoice_Models.Result c = EInvoiceController.cancel(inv.Id, null);
        System.assertEquals(true, c.success, 'Controller cancel succeeds');
        Test.stopTest();
    }

    @isTest
    static void controller_generateOnMissingInvoiceThrows() {
        Boolean thrown = false;
        Test.startTest();
        try {
            EInvoiceController.cancel(null, 'x');
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Cancel with no e-invoice surfaces an error');
    }

    @isTest
    static void factory_resolvesAndAcceptsOverride() {
        System.assert(EInvoice_ProviderFactory.get() instanceof EInvoice_MockProvider, 'Default provider is the mock');
        EInvoice_ProviderFactory.setOverride(new EInvoice_MockProvider());
        System.assert(EInvoice_ProviderFactory.get() instanceof EInvoice_MockProvider, 'Injected provider is returned');
    }

    @isTest
    static void generate_secondaryUsesDistributorAsSeller() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist EIsec', 'Distributor');
        dist.GSTIN__c = '27DDDDD2222D1Z5';
        update dist;
        Account retailer = TestDataFactory.createAndInsertAccount('Ret EIsec', 'Retailer');
        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);

        // Secondary invoice: billed to the retailer, sold from the distributor (the seller).
        Invoice__c inv = new Invoice__c(
            Account__c = retailer.Id, Order_Type__c = 'Secondary', Sold_From_Distributor__c = dist.Id,
            Invoice_Number__c = 'SINV-EI-' + String.valueOf(Datetime.now().getTime()),
            Invoice_Date__c = Date.today(), Status__c = 'Draft', GSTIN__c = '27RRRRR3333R1Z5',
            Subtotal__c = 4000, Total_Amount__c = 4000, Balance_Due__c = 4000
        );
        TriggerHandler.bypass('OMS_Invoice_TriggerHandler');
        insert inv;
        TriggerHandler.clearBypass('OMS_Invoice_TriggerHandler');
        insert new Invoice_Line__c(
            Invoice__c = inv.Id, Product_Ext__c = products[0].Id, HSN_SAC_Code__c = '19053100',
            Quantity__c = 8, Unit_Price__c = 500, Total_Amount__c = 4000, Line_Number__c = 1
        );

        Test.startTest();
        EInvoice_Models.Result r = EInvoice_Service.generateOne(inv.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Secondary e-invoice generated (distributor is the seller)');
        System.assertEquals(64, r.irn.length(), 'IRN present for the secondary sale');
    }

    @isTest
    static void financialYear_indianFyBoundary() {
        System.assertEquals('2025-26', EInvoice_Service.financialYear(Date.newInstance(2025, 5, 1)), 'May 2025 -> FY 2025-26');
        System.assertEquals('2024-25', EInvoice_Service.financialYear(Date.newInstance(2025, 2, 1)), 'Feb 2025 -> FY 2024-25');
        System.assertEquals('2009-10', EInvoice_Service.financialYear(Date.newInstance(2009, 4, 1)), 'Apr 2009 -> FY 2009-10');
    }
}