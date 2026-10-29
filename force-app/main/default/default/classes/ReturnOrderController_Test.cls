/**
 * @description Test class for ReturnOrderController.
 *              Validates getAccountInvoices, getInvoiceLines,
 *              createReturnOrder (JSON), and createReturnOrderFromRecords
 *              including validation paths (empty lines, zero qty,
 *              exceeds available, missing reason, invalid JSON).
 * @author  SFA Development Team
 * @date    2024
 */
@IsTest
private class ReturnOrderController_Test {

    private static final String SKU = 'RET-001';
    private static final Decimal INVOICED_QTY = 10;
    private static final Decimal UNIT_PRICE = 100;

    @TestSetup
    static void setupTestData() {
        // Bypass the Return_Order__c trigger handler: its header-level
        // Return_Quantity__c validation is incompatible with the line-based
        // model used by ReturnOrderController.
        TriggerHandler.bypass('OMS_ReturnOrder_TriggerHandler');

        // Product
        Product_Extension__c prod = TestDataFactory.createProduct('Return Product', SKU);
        prod.MRP__c = 120;
        prod.Unit_Price__c = UNIT_PRICE;
        prod.GST_Rate__c = 18;
        prod.Is_Returnable__c = true;
        prod.Min_Order_Qty__c = 1;
        insert prod;

        // Account
        Account acc = TestDataFactory.createAndInsertAccount('Return Outlet', 'Retailer');

        // Sales Order (Draft to avoid downstream auto-invoice flow)
        Sales_Order__c so = TestDataFactory.createSalesOrder(acc.Id, UserInfo.getUserId(), null);
        insert so;

        // Invoice in 'Delivered' status so it is returned by getAccountInvoices
        Invoice__c inv = TestDataFactory.createInvoice(so.Id, acc.Id);
        inv.Status__c = 'Delivered';
        inv.Delivery_Date__c = Date.today().addDays(-1);
        insert inv;

        // Invoice Line
        Invoice_Line__c invLine = new Invoice_Line__c(
            Invoice__c = inv.Id,
            Product_Ext__c = prod.Id,
            Quantity__c = INVOICED_QTY,
            Unit_Price__c = UNIT_PRICE,
            Line_Total__c = INVOICED_QTY * UNIT_PRICE
        );
        insert invLine;
    }

    // ── Helper accessors ────────────────────────────────────────────────────

    /**
     * Bypass the Return_Order__c trigger handler. Static bypass state doesn't
     * carry across transactions, so each test method must call this.
     */
    private static void bypassReturnOrderTrigger() {
        TriggerHandler.bypass('OMS_ReturnOrder_TriggerHandler');
    }

    private static Account getAccount() {
        return [SELECT Id FROM Account WHERE Name = 'Return Outlet' LIMIT 1];
    }

    private static Invoice__c getInvoice() {
        return [SELECT Id FROM Invoice__c WHERE Status__c = 'Delivered' LIMIT 1];
    }

    private static Invoice_Line__c getInvoiceLine() {
        return [SELECT Id, Product_Ext__c FROM Invoice_Line__c LIMIT 1];
    }

    private static Product_Extension__c getProduct() {
        return [SELECT Id FROM Product_Extension__c WHERE SKU_Code__c = :SKU LIMIT 1];
    }

    // ── getAccountInvoices ──────────────────────────────────────────────────

    @IsTest
    static void testGetAccountInvoices() {
        Account acc = getAccount();

        Test.startTest();
        List<Invoice__c> invoices = ReturnOrderController.getAccountInvoices(acc.Id);
        Test.stopTest();

        System.assertEquals(1, invoices.size(), 'Should return 1 delivered invoice');
        System.assertEquals('Delivered', invoices[0].Status__c, 'Status should be Delivered');
    }

    @IsTest
    static void testGetAccountInvoicesNoneForOtherAccount() {
        Account other = TestDataFactory.createAndInsertAccount('Other Outlet', 'Retailer');

        Test.startTest();
        List<Invoice__c> invoices = ReturnOrderController.getAccountInvoices(other.Id);
        Test.stopTest();

        System.assertEquals(0, invoices.size(), 'Should return no invoices for unrelated account');
    }

    // ── getInvoiceLines ─────────────────────────────────────────────────────

    @IsTest
    static void testGetInvoiceLines() {
        Invoice__c inv = getInvoice();

        Test.startTest();
        List<Map<String, Object>> lines = ReturnOrderController.getInvoiceLines(inv.Id);
        Test.stopTest();

        System.assertEquals(1, lines.size(), 'Should return 1 invoice line');
        Map<String, Object> line = lines[0];
        System.assertEquals(INVOICED_QTY, (Decimal) line.get('invoicedQty'), 'Invoiced qty should match');
        System.assertEquals(0, (Decimal) line.get('alreadyReturned'), 'Already returned should be 0');
        System.assertEquals(INVOICED_QTY, (Decimal) line.get('availableForReturn'),
            'Available for return should equal invoiced qty');
    }

    @IsTest
    static void testGetInvoiceLinesWithExistingReturn() {
        bypassReturnOrderTrigger();
        Invoice__c inv = getInvoice();
        Invoice_Line__c invLine = getInvoiceLine();
        Account acc = getAccount();

        // Create an existing return for 3 units
        Return_Order__c existing = new Return_Order__c(
            Account__c = acc.Id,
            Invoice__c = inv.Id,
            Return_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        insert existing;

        Return_Line__c rl = new Return_Line__c(
            Return_Order__c = existing.Id,
            Invoice_Line__c = invLine.Id,
            Product_Ext__c = invLine.Product_Ext__c,
            Return_Quantity__c = 3,
            Return_Reason__c = 'Damaged',
            Unit_Price__c = UNIT_PRICE
        );
        insert rl;

        Test.startTest();
        List<Map<String, Object>> lines = ReturnOrderController.getInvoiceLines(inv.Id);
        Test.stopTest();

        Map<String, Object> line = lines[0];
        System.assertEquals(3, (Decimal) line.get('alreadyReturned'), 'Already returned should be 3');
        System.assertEquals(INVOICED_QTY - 3, (Decimal) line.get('availableForReturn'),
            'Available for return should be invoiced minus already returned');
    }

    @IsTest
     static void testGetInvoiceLinesEmpty() {
        // Use a separate account so the duplicate-order validation doesn't
        // trigger against the Sales Order created in @TestSetup.
        Account otherAcc = TestDataFactory.createAndInsertAccount('Empty Inv Outlet', 'Retailer');
        Sales_Order__c so = TestDataFactory.createSalesOrder(otherAcc.Id, UserInfo.getUserId(), null);
        insert so;
        Invoice__c emptyInv = TestDataFactory.createInvoice(so.Id, otherAcc.Id);
        emptyInv.Status__c = 'Delivered';
        insert emptyInv;

        Test.startTest();
        List<Map<String, Object>> lines = ReturnOrderController.getInvoiceLines(emptyInv.Id);
        Test.stopTest();

        System.assertEquals(0, lines.size(), 'Should return empty list when no lines');
    }

    // ── createReturnOrder (JSON) happy path ─────────────────────────────────

    @IsTest
    static void testCreateReturnOrderJson() {
        bypassReturnOrderTrigger();
        Account acc = getAccount();
        Invoice__c inv = getInvoice();
        Invoice_Line__c invLine = getInvoiceLine();
        Product_Extension__c prod = getProduct();

        Map<String, Object> payload = new Map<String, Object>{
            'accountId' => acc.Id,
            'invoiceId' => inv.Id,
            'remarks'   => 'Customer complaint',
            'returnLines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => invLine.Id,
                    'productId'     => prod.Id,
                    'returnQty'     => 2,
                    'returnAmount'  => 200,
                    'reason'        => 'Damaged'
                }
            }
        };

        Test.startTest();
        Return_Order__c result = ReturnOrderController.createReturnOrder(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Return order should be created');
        System.assertEquals(1, result.Total_Items__c, 'Total items should be 1');

        List<Return_Line__c> lines = [SELECT Id, Return_Quantity__c, Unit_Price__c, Line_Total__c
                                      FROM Return_Line__c WHERE Return_Order__c = :result.Id];
        System.assertEquals(1, lines.size(), 'Should have 1 return line');
        System.assertEquals(2, lines[0].Return_Quantity__c, 'Return qty should be 2');
        System.assertEquals(100, lines[0].Unit_Price__c, 'Unit price should be derived from amount/qty');
    }

    // ── createReturnOrderFromRecords happy path ─────────────────────────────

    @IsTest
    static void testCreateReturnOrderFromRecords() {
        bypassReturnOrderTrigger();
        Account acc = getAccount();
        Invoice__c inv = getInvoice();
        Invoice_Line__c invLine = getInvoiceLine();
        Product_Extension__c prod = getProduct();

        Return_Order__c ro = new Return_Order__c(
            Account__c = acc.Id,
            Invoice__c = inv.Id
        );

        List<Return_Line__c> rls = new List<Return_Line__c>{
            new Return_Line__c(
                Invoice_Line__c    = invLine.Id,
                Product_Ext__c     = prod.Id,
                Return_Quantity__c = 4,
                Return_Reason__c   = 'Damaged',
                Unit_Price__c      = UNIT_PRICE
            )
        };

        Test.startTest();
        Return_Order__c result = ReturnOrderController.createReturnOrderFromRecords(ro, rls);
        Test.stopTest();

        System.assertNotEquals(null, result.Id, 'Return order should be inserted');
        System.assertEquals('Draft', result.Status__c, 'Status should default to Draft');
        System.assertEquals(4 * UNIT_PRICE, result.Total_Return_Value__c,
            'Total return value should equal qty * unit price');
        System.assertEquals(1, result.Total_Items__c, 'Total items should be 1');
    }

    // ── Validation: empty lines list ────────────────────────────────────────

    @IsTest
    static void testCreateReturnOrderEmptyLines() {
        Account acc = getAccount();
        Return_Order__c ro = new Return_Order__c(Account__c = acc.Id);

        Test.startTest();
        Boolean caught = false;
        try {
            ReturnOrderController.createReturnOrderFromRecords(ro, new List<Return_Line__c>());
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw AuraHandledException for empty lines');
    }

    // ── Validation: zero / negative quantity ────────────────────────────────

    @IsTest
    static void testCreateReturnOrderZeroQty() {
        Account acc = getAccount();
        Invoice_Line__c invLine = getInvoiceLine();
        Product_Extension__c prod = getProduct();

        Return_Order__c ro = new Return_Order__c(Account__c = acc.Id);
        List<Return_Line__c> rls = new List<Return_Line__c>{
            new Return_Line__c(
                Invoice_Line__c    = invLine.Id,
                Product_Ext__c     = prod.Id,
                Return_Quantity__c = 0,
                Return_Reason__c   = 'Damaged'
            )
        };

        Test.startTest();
        Boolean caught = false;
        try {
            ReturnOrderController.createReturnOrderFromRecords(ro, rls);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw AuraHandledException for zero quantity');
    }

    // ── Validation: quantity exceeds available ──────────────────────────────

    @IsTest
    static void testCreateReturnOrderExceedsAvailable() {
        Account acc = getAccount();
        Invoice_Line__c invLine = getInvoiceLine();
        Product_Extension__c prod = getProduct();

        Return_Order__c ro = new Return_Order__c(Account__c = acc.Id);
        List<Return_Line__c> rls = new List<Return_Line__c>{
            new Return_Line__c(
                Invoice_Line__c    = invLine.Id,
                Product_Ext__c     = prod.Id,
                Return_Quantity__c = INVOICED_QTY + 5,
                Return_Reason__c   = 'Damaged',
                Unit_Price__c      = UNIT_PRICE
            )
        };

        Test.startTest();
        Boolean caught = false;
        try {
            ReturnOrderController.createReturnOrderFromRecords(ro, rls);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw AuraHandledException when qty exceeds available');
        System.assertEquals(0, [SELECT COUNT() FROM Return_Order__c],
            'Savepoint rollback should leave no Return_Order__c records');
    }

    // ── Validation: missing reason ──────────────────────────────────────────

    @IsTest
    static void testCreateReturnOrderMissingReason() {
        Account acc = getAccount();
        Invoice_Line__c invLine = getInvoiceLine();
        Product_Extension__c prod = getProduct();

        Return_Order__c ro = new Return_Order__c(Account__c = acc.Id);
        List<Return_Line__c> rls = new List<Return_Line__c>{
            new Return_Line__c(
                Invoice_Line__c    = invLine.Id,
                Product_Ext__c     = prod.Id,
                Return_Quantity__c = 2,
                Return_Reason__c   = null,
                Unit_Price__c      = UNIT_PRICE
            )
        };

        Test.startTest();
        Boolean caught = false;
        try {
            ReturnOrderController.createReturnOrderFromRecords(ro, rls);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw AuraHandledException when reason is blank');
    }

    // ── Validation: invalid JSON payload ────────────────────────────────────

    @IsTest
    static void testCreateReturnOrderInvalidJson() {
        Test.startTest();
        Boolean caught = false;
        try {
            ReturnOrderController.createReturnOrder('{not-json}');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw AuraHandledException for invalid JSON');
    }

    // ── Secondary return (visit / returns screen): restock distributor + credit retailer ──
    // These run with the Return_Order trigger LIVE (no bypass) to exercise the full engine.

    private static void enableReturns() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_RETURNS, true);
    }

    @IsTest
    static void secondaryReturn_restocksDistributor_andCreditsRetailer() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist RET', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer RET', 'Retailer');
        retailer.ParentId = dist.Id;
        update retailer;

        List<Product_Extension__c> products = TestDataFactory.createAndInsertProducts(1);
        Id productId = products[0].Id;

        // Distributor currently holds the batch that will be returned.
        insert new Distributor_Stock__c(
            Account__c = dist.Id, Product_Ext__c = productId, Batch_No__c = 'B1',
            Expiry_Date__c = Date.today().addDays(120), Opening_Stock__c = 100,
            Stock_Date__c = Date.today(), Is_Current__c = true);

        // Secondary invoice (retailer billed, sold from the distributor) + a line for the batch.
        Invoice__c inv = new Invoice__c(
            Account__c = retailer.Id, Order_Type__c = 'Secondary', Sold_From_Distributor__c = dist.Id,
            Invoice_Number__c = 'SINV-RET-' + String.valueOf(Datetime.now().getTime()),
            Invoice_Date__c = Date.today(), Status__c = 'Draft',
            Subtotal__c = 1000, Total_Amount__c = 1000, Balance_Due__c = 1000);
        TriggerHandler.bypass('OMS_Invoice_TriggerHandler');
        insert inv;
        TriggerHandler.clearBypass('OMS_Invoice_TriggerHandler');
        Invoice_Line__c line = new Invoice_Line__c(
            Invoice__c = inv.Id, Product_Ext__c = productId, Quantity__c = 10, Unit_Price__c = 100,
            Batch_No__c = 'B1', Line_Total__c = 1000);
        insert line;

        String returnJson = JSON.serialize(new Map<String, Object>{
            'accountId' => retailer.Id,
            'invoiceId' => inv.Id,
            'remarks' => 'Damaged in transit',
            'returnLines' => new List<Object>{
                new Map<String, Object>{
                    'invoiceLineId' => line.Id, 'productId' => productId,
                    'returnQty' => 3, 'reason' => 'Damaged',
                    'returnAmount' => 300, 'batchNo' => 'B1'
                }
            }
        });

        enableReturns();
        Test.startTest();
        Return_Order__c created = ReturnOrderController.createReturnOrder(returnJson);
        Test.stopTest();

        Return_Order__c ro = [
            SELECT Status__c, Return_Type__c, Returned_To_Distributor__c, Return_Amount__c, Return_Quantity__c
            FROM Return_Order__c WHERE Id = :created.Id];
        System.assertEquals('Secondary', ro.Return_Type__c, 'Booked as a secondary return');
        System.assertEquals(dist.Id, ro.Returned_To_Distributor__c, 'Routed to the servicing distributor');
        System.assertEquals('Approved', ro.Status__c, 'Auto-approved');
        System.assertEquals(300, ro.Return_Amount__c, 'Header amount = credit-note amount');
        System.assertEquals(3, ro.Return_Quantity__c, 'Header qty aggregated from lines');

        Distributor_Stock__c ds = [
            SELECT Closing_Stock__c, Expiry_Date__c FROM Distributor_Stock__c
            WHERE Account__c = :dist.Id AND Product_Ext__c = :productId AND Batch_No__c = 'B1' AND Is_Current__c = true
            ORDER BY CreatedDate DESC LIMIT 1];
        System.assertEquals(103, ds.Closing_Stock__c, 'Returned 3 added back to distributor stock');
        System.assertNotEquals(null, ds.Expiry_Date__c, 'Batch expiry preserved on the restocked snapshot');

        System.assertEquals(1, [
            SELECT COUNT() FROM Stock_Transaction__c
            WHERE Reference_Type__c = 'Return_Order' AND Account__c = :dist.Id AND Direction__c = 'In'],
            'One inbound stock transaction for the return');

        System.assertEquals(1, [
            SELECT COUNT() FROM Ledger_Entry__c
            WHERE Account__c = :retailer.Id AND Entry_Type__c = 'Credit Note'],
            'Credit note posted to the retailer');
        System.assertEquals(700, [SELECT Balance_Due__c FROM Invoice__c WHERE Id = :inv.Id].Balance_Due__c,
            'Invoice balance reduced by the credit');
    }

    @IsTest
    static void getAccountInvoices_includesSecondaryDraft() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist RET2', 'Distributor');
        Account retailer = TestDataFactory.createAndInsertAccount('Retailer RET2', 'Retailer');
        Invoice__c inv = new Invoice__c(
            Account__c = retailer.Id, Order_Type__c = 'Secondary', Sold_From_Distributor__c = dist.Id,
            Invoice_Number__c = 'SINV-RET2-' + String.valueOf(Datetime.now().getTime()),
            Invoice_Date__c = Date.today(), Status__c = 'Draft',
            Subtotal__c = 500, Total_Amount__c = 500, Balance_Due__c = 500);
        TriggerHandler.bypass('OMS_Invoice_TriggerHandler');
        insert inv;
        TriggerHandler.clearBypass('OMS_Invoice_TriggerHandler');

        Test.startTest();
        List<Invoice__c> eligible = ReturnOrderController.getAccountInvoices(retailer.Id);
        Test.stopTest();
        System.assertEquals(1, eligible.size(), 'A secondary Draft invoice is returnable');
        System.assertEquals(inv.Id, eligible[0].Id, 'Returns the secondary invoice');
    }
}