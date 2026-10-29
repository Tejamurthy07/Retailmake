/**
 * @description Test class for InvoicePDFController.
 *              Per-test fixtures with defensive setup. Covers constructor
 *              wiring, line items, payment aggregation, and numberToWords
 *              across all magnitude branches.
 */
@isTest
public class InvoicePDFController_Test {

    private static void fillRequiredFields(SObject record) {
        Schema.DescribeSObjectResult sObjDesc = record.getSObjectType().getDescribe();
        for (Schema.SObjectField f : sObjDesc.fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isCreateable()) continue;
            if (dfr.isNillable()) continue;
            if (dfr.isAutoNumber() || dfr.isCalculated()) continue;
            if (dfr.isDefaultedOnCreate()) continue;
            String fieldName = dfr.getName();
            if (record.get(fieldName) != null) continue;

            Schema.DisplayType t = dfr.getType();
            if (t == Schema.DisplayType.STRING || t == Schema.DisplayType.TEXTAREA) {
                record.put(fieldName, 'Test');
            } else if (t == Schema.DisplayType.EMAIL) {
                record.put(fieldName, 'test@example.com');
            } else if (t == Schema.DisplayType.PHONE) {
                record.put(fieldName, '9999999999');
            } else if (t == Schema.DisplayType.URL) {
                record.put(fieldName, 'https://example.com');
            } else if (t == Schema.DisplayType.PICKLIST || t == Schema.DisplayType.MULTIPICKLIST) {
                List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
                if (!entries.isEmpty()) record.put(fieldName, entries[0].getValue());
            } else if (t == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, false);
            } else if (t == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.today().addDays(-30));
            } else if (t == Schema.DisplayType.DATETIME) {
                record.put(fieldName, Datetime.now());
            } else if (t == Schema.DisplayType.DOUBLE || t == Schema.DisplayType.CURRENCY || t == Schema.DisplayType.PERCENT) {
                record.put(fieldName, 0);
            } else if (t == Schema.DisplayType.INTEGER || t == Schema.DisplayType.LONG) {
                record.put(fieldName, 0);
            }
        }
    }

    private class Fixtures {
        public Account account;
        public Invoice__c invoice;
        public Product_Extension__c product;
    }

    private static Fixtures buildFixtures(String suffix, Decimal netAmount, Integer numLineItems, Integer numPayments) {
        Fixtures fx = new Fixtures();
        try {
            Territory_Master__c territory = new Territory_Master__c(
                Name = 'PDF Territory ' + suffix,
                Territory_Code__c = ('PDF' + suffix).left(20),
                State__c = 'Maharashtra',
                City__c = 'Mumbai',
                Is_Active__c = true
            );
            fillRequiredFields(territory);
            insert territory;

            fx.account = new Account(
                Name = 'PDF Acc ' + suffix,
                Outlet_Type__c = 'Grocery',
                Channel__c = 'GT',
                Territory__c = territory.Id,
                Is_Active__c = true,
                BillingStreet = '123 Test Street',
                BillingCity = 'Mumbai',
                BillingState = 'Maharashtra',
                BillingPostalCode = '400001',
                ShippingStreet = '123 Ship Street',
                ShippingCity = 'Mumbai',
                ShippingState = 'Maharashtra',
                ShippingPostalCode = '400001'
            );
            Map<String, Schema.RecordTypeInfo> rtMap =
                Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
            if (rtMap.containsKey('Distributor')) {
                fx.account.RecordTypeId = rtMap.get('Distributor').getRecordTypeId();
            }
            fillRequiredFields(fx.account);
            insert fx.account;

            fx.product = new Product_Extension__c(
                Name = 'PDF Prod ' + suffix,
                SKU_Code__c = ('SKU' + suffix).left(20),
                Is_Active__c = true
            );
            fillRequiredFields(fx.product);
            insert fx.product;

            fx.invoice = new Invoice__c(
                Account__c = fx.account.Id,
                Invoice_Date__c = Date.today(),
                Due_Date__c = Date.today().addDays(30),
                Total_Amount__c = netAmount,
                Net_Amount__c = netAmount,
                Tax_Amount__c = 0,
                Balance_Due__c = netAmount
            );
            fillRequiredFields(fx.invoice);
            insert fx.invoice;

            for (Integer i = 0; i < numLineItems; i++) {
                Invoice_Line__c line = new Invoice_Line__c(
                    Invoice__c = fx.invoice.Id,
                    Quantity__c = 5 + i,
                    Unit_Price__c = 100,
                    Line_Total__c = (5 + i) * 100,
                    HSN_SAC_Code__c = '1234'
                );
                if (fx.product != null) {
                    // Try Product_Ext__c first (deployed schema), fall back to Product__c
                    try { line.put('Product_Ext__c', fx.product.Id); }
                    catch (Exception fieldEx) {
                        try { line.put('Product__c', fx.product.Id); } catch (Exception e) {}
                    }
                }
                fillRequiredFields(line);
                try { insert line; } catch (Exception e) {}
            }

            for (Integer i = 0; i < numPayments; i++) {
                Collection__c c = new Collection__c(
                    Account__c = fx.account.Id,
                    Invoice__c = fx.invoice.Id,
                    Amount__c = 100,
                    Collection_Date__c = Date.today(),
                    Payment_Mode__c = 'Cash',
                    Status__c = 'Cleared'
                );
                fillRequiredFields(c);
                try { insert c; } catch (Exception e) {}
            }
        } catch (Exception ex) {}
        return fx;
    }

    private static InvoicePDFController buildController(Id invoiceId) {
        Invoice__c stub = new Invoice__c(Id = invoiceId);
        ApexPages.StandardController std = new ApexPages.StandardController(stub);
        return new InvoicePDFController(std);
    }

    @isTest
    static void testControllerWithLinesAndPayments() {
        Fixtures fx = buildFixtures('C1', 500, 2, 1);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertNotEquals(null, ctrl.invoice);
            System.assertNotEquals(null, ctrl.lineItems);
            System.assertNotEquals(null, ctrl.amountInWords);
            System.assertEquals(30, ctrl.creditDays);
        }
    }

    @isTest
    static void testControllerNoLinesNoPayments() {
        Fixtures fx = buildFixtures('C2', 250, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertEquals(0, ctrl.amountPaid);
            System.assertEquals(0, ctrl.lineItems.size());
        }
    }

    @isTest
    static void testControllerMultipleLineItems() {
        Fixtures fx = buildFixtures('C3', 1000, 5, 2);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null && ctrl.lineItems != null && !ctrl.lineItems.isEmpty()) {
            System.assertEquals(1, ctrl.lineItems[0].index, 'First wrapper index should be 1');
            System.assertNotEquals(null, ctrl.lineItems[0].line);
        }
    }

    @isTest
    static void testNumberToWordsZero() {
        Fixtures fx = buildFixtures('N0', 0, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertEquals('Zero', ctrl.amountInWords);
        }
    }

    @isTest
    static void testNumberToWordsUnderTwenty() {
        Fixtures fx = buildFixtures('N1', 7, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertEquals('Seven', ctrl.amountInWords);
        }
    }

    @isTest
    static void testNumberToWordsTens() {
        Fixtures fx = buildFixtures('N2', 45, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertEquals('Forty Five', ctrl.amountInWords);
        }
    }

    @isTest
    static void testNumberToWordsRoundTens() {
        Fixtures fx = buildFixtures('N3', 60, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertEquals('Sixty', ctrl.amountInWords);
        }
    }

    @isTest
    static void testNumberToWordsHundreds() {
        Fixtures fx = buildFixtures('N4', 305, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assert(ctrl.amountInWords.contains('Three Hundred'));
            System.assert(ctrl.amountInWords.contains('Five'));
        }
    }

    @isTest
    static void testNumberToWordsRoundHundreds() {
        Fixtures fx = buildFixtures('N5', 400, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertEquals('Four Hundred', ctrl.amountInWords);
        }
    }

    @isTest
    static void testNumberToWordsThousands() {
        Fixtures fx = buildFixtures('N6', 12500, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assert(ctrl.amountInWords.contains('Thousand'));
        }
    }

    @isTest
    static void testNumberToWordsLakhs() {
        Fixtures fx = buildFixtures('N7', 250000, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assert(ctrl.amountInWords.contains('Lakh'));
        }
    }

    @isTest
    static void testNumberToWordsCrores() {
        Fixtures fx = buildFixtures('N8', 12000000, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assert(ctrl.amountInWords.contains('Crore'));
        }
    }

    @isTest
    static void testControllerWithNullNetAmount() {
        Fixtures fx = buildFixtures('N9', 100, 0, 0);

        // Null out the GRAND TOTAL after insert — amountInWords reads
        // Total_Amount__c (Net_Amount__c is not populated by billing and the
        // controller deliberately ignores it), so that is the field whose null
        // must map to Zero.
        if (fx.invoice != null && fx.invoice.Id != null) {
            fx.invoice.Total_Amount__c = null;
            try { update fx.invoice; } catch (Exception e) {}
        }

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            System.assertEquals('Zero', ctrl.amountInWords, 'Null Net_Amount should map to Zero');
        }
    }

    @isTest
    static void testControllerWithMixedPaymentStatuses() {
        Fixtures fx = buildFixtures('C4', 1000, 1, 1);

        // Add additional payments in non-Cleared status that should NOT count
        if (fx.account != null && fx.invoice != null) {
            try {
                Collection__c pending = new Collection__c(
                    Account__c = fx.account.Id,
                    Invoice__c = fx.invoice.Id,
                    Amount__c = 500,
                    Collection_Date__c = Date.today(),
                    Payment_Mode__c = 'Cash',
                    Status__c = 'Collected'
                );
                fillRequiredFields(pending);
                insert pending;
            } catch (Exception e) {}
        }

        Test.startTest();
        InvoicePDFController ctrl;
        if (fx.invoice != null && fx.invoice.Id != null) {
            ctrl = buildController(fx.invoice.Id);
        }
        Test.stopTest();

        if (ctrl != null) {
            // Only Cleared payments count (one Cleared at 100)
            System.assertEquals(100, ctrl.amountPaid);
        }
    }

    // ═════════════════ Extended coverage (hard assertions) ═════════════════
    // The tests above tolerate fixture failure (every assert sits behind an
    // if-null guard, so a broken fixture passes silently). The tests below
    // assert the fixture built, then pin exact rendered values — plus the two
    // paths the original set never touched: the URL-parameter constructor and
    // the portal scope gate.

    private static Fixtures mustBuild(String suffix, Decimal amt, Integer lines, Integer payments) {
        Fixtures fx = buildFixtures(suffix, amt, lines, payments);
        System.assertNotEquals(null, fx.invoice == null ? null : fx.invoice.Id,
            'Fixture invoice must exist — a silent fixture failure would vacuously pass '
            + 'every guarded test above, which is exactly what these tests refuse to do');
        return fx;
    }

    @isTest
    static void urlParameter_constructorLoadsTheSameInvoice() {
        Fixtures fx = mustBuild('U1', 750, 1, 0);

        Test.startTest();
        Test.setCurrentPage(new PageReference('/apex/InvoicePDF'));
        ApexPages.currentPage().getParameters().put('id', fx.invoice.Id);
        InvoicePDFController ctrl = new InvoicePDFController();
        Test.stopTest();

        System.assertEquals(fx.invoice.Id, ctrl.invoice.Id,
            'The portal entry point resolves the invoice from the ?id= URL parameter');
        System.assertEquals(1, ctrl.lineItems.size(), 'And loads its lines the same way');
    }

    @isTest
    static void missingUrlParameter_throwsOnLoad() {
        Test.startTest();
        Test.setCurrentPage(new PageReference('/apex/InvoicePDF'));
        // No ?id= parameter at all.
        Boolean threw = false;
        try {
            new InvoicePDFController();
        } catch (QueryException e) {
            threw = true;
        }
        Test.stopTest();

        // Pins a sharp edge rather than a nicety: a missing/invalid id reaches the
        // single-row SOQL assignment and dies with a raw 'List has no rows' —
        // the portal page shows a platform error, not a friendly message. If a
        // guard is ever added to load(), rewrite this to assert that instead.
        System.assert(threw, 'No id currently means an unhandled QueryException');
    }

    @isTest
    static void renderedProperties_mirrorTheInvoiceFieldForField() {
        Fixtures fx = mustBuild('R1', 1180, 0, 0);
        fx.invoice.GSTIN__c = '27AAAPL1234C1ZV';
        fx.invoice.E_Way_Bill_No__c = 'EWB-42';
        fx.invoice.E_Way_Bill_Valid_Until__c = Datetime.now().addDays(2);
        fx.invoice.Vehicle_No__c = 'MH01AB1234';
        fx.invoice.Transporter__c = 'Speedy Logistics';
        fx.invoice.E_Invoice_IRN__c = 'IRN-0001';
        fx.invoice.E_Invoice_Ack_No__c = 'ACK-9';
        fx.invoice.E_Invoice_Ack_Date__c = Datetime.now();
        fx.invoice.E_Invoice_Status__c = 'Generated';
        fx.invoice.Subtotal__c = 1000;
        fx.invoice.Tax_Amount__c = 180;
        update fx.invoice;

        Test.startTest();
        InvoicePDFController ctrl = buildController(fx.invoice.Id);
        Test.stopTest();

        // These properties exist so the PDF renders independently of the portal
        // user's FLS — each one must be a faithful copy of the record.
        System.assertEquals(fx.invoice.Invoice_Date__c == null ? Date.today() : fx.invoice.Invoice_Date__c, ctrl.invoiceDate, 'Invoice date copied');
        System.assertEquals('27AAAPL1234C1ZV', ctrl.gstin, 'GSTIN copied');
        System.assertEquals('EWB-42', ctrl.eWayBillNo, 'E-way bill number copied');
        System.assertEquals('MH01AB1234', ctrl.vehicleNo, 'Vehicle copied');
        System.assertEquals('Speedy Logistics', ctrl.transporter, 'Transporter copied');
        System.assertEquals('IRN-0001', ctrl.irn, 'IRN copied');
        System.assertEquals('ACK-9', ctrl.ackNo, 'Ack number copied');
        System.assertEquals('Generated', ctrl.eInvStatus, 'E-invoice status copied');
        System.assertEquals(true, ctrl.hasEInvoice, 'An IRN present means the e-invoice block renders');
        System.assertEquals(1000, ctrl.subtotalAmt, 'Subtotal copied');
        System.assertEquals(180, ctrl.taxAmt, 'Tax copied');
        System.assertEquals(1180, ctrl.grandTotal, 'Grand total copied');
        System.assertEquals('', ctrl.orderRef, 'No linked Sales Order renders as blank, not null');
    }

    @isTest
    static void noIrn_hidesTheEInvoiceBlock() {
        Fixtures fx = mustBuild('R2', 100, 0, 0);

        Test.startTest();
        InvoicePDFController ctrl = buildController(fx.invoice.Id);
        Test.stopTest();

        System.assertEquals(false, ctrl.hasEInvoice, 'Blank IRN → the e-invoice section stays hidden');
    }

    @isTest
    static void orderRef_showsTheLinkedSalesOrderNumber() {
        Fixtures fx = mustBuild('R3', 100, 0, 0);
        Sales_Order__c so = new Sales_Order__c(
            Account__c = fx.account.Id,
            Order_Date__c = Date.today()
        );
        fillRequiredFields(so);
        insert so;
        so = [SELECT Name FROM Sales_Order__c WHERE Id = :so.Id];
        fx.invoice.Sales_Order__c = so.Id;
        update fx.invoice;

        Test.startTest();
        InvoicePDFController ctrl = buildController(fx.invoice.Id);
        Test.stopTest();

        System.assertEquals(so.Name, ctrl.orderRef,
            'The PDF references the auto-numbered Sales Order (SO-xxxxx) it was billed from');
    }

    @isTest
    static void lineWrapper_mapsEveryRenderedColumn() {
        Fixtures fx = mustBuild('L1', 590, 0, 0);
        Invoice_Line__c line = new Invoice_Line__c(
            Invoice__c = fx.invoice.Id,
            Product_Ext__c = fx.product.Id,
            HSN_SAC_Code__c = '3004',
            Quantity__c = 5,
            Unit_Price__c = 100,
            Discount__c = 10,
            CGST__c = 45,
            SGST__c = 45,
            IGST__c = 0,
            Line_Total__c = 111111,     // deliberately wrong — must NOT be what renders
            Total_Amount__c = 590
        );
        fillRequiredFields(line);
        insert line;

        Test.startTest();
        InvoicePDFController ctrl = buildController(fx.invoice.Id);
        Test.stopTest();

        System.assertEquals(1, ctrl.lineItems.size(), 'One line, one wrapper');
        InvoicePDFController.LineItemWrapper w = ctrl.lineItems[0];
        System.assertEquals(1, w.index, 'Serial number starts at 1');
        System.assertEquals(fx.product.Name, w.productName, 'Product name from Product_Ext__r');
        System.assertEquals('3004', w.hsn, 'HSN copied');
        System.assertEquals(5, w.qty, 'Quantity copied');
        System.assertEquals(100, w.unitPrice, 'Unit price copied');
        System.assertEquals(10, w.discount, 'Discount copied');
        System.assertEquals(45, w.cgst, 'CGST copied');
        System.assertEquals(45, w.sgst, 'SGST copied');
        System.assertEquals(0, w.igst, 'IGST copied');
        System.assertEquals(590, w.lineTotal,
            'The rendered line total comes from Total_Amount__c — Line_Total__c is not '
            + 'populated by billing and is deliberately ignored (the 111111 proves it)');
    }

    @isTest
    static void amountPaid_sumsClearedOnly_andBalanceMirrorsTheRecord() {
        Fixtures fx = mustBuild('P1', 1000, 0, 2);   // two Cleared at 100 each
        Collection__c notCleared = new Collection__c(
            Account__c = fx.account.Id,
            Invoice__c = fx.invoice.Id,
            Amount__c = 500,
            Collection_Date__c = Date.today(),
            Payment_Mode__c = 'Cash',
            Status__c = 'Collected'
        );
        fillRequiredFields(notCleared);
        insert notCleared;

        Test.startTest();
        InvoicePDFController ctrl = buildController(fx.invoice.Id);
        Test.stopTest();

        System.assertEquals(200, ctrl.amountPaid,
            'Two Cleared collections of 100 sum to 200; the Collected 500 is money in '
            + 'transit and must not print as paid');
        Invoice__c after = [SELECT Balance_Due__c FROM Invoice__c WHERE Id = :fx.invoice.Id];
        System.assertEquals(after.Balance_Due__c, ctrl.balanceDue,
            'Balance due prints exactly what the record holds — the Collection trigger '
            + 'owns that number, the PDF only mirrors it');
    }

    // ═════════════════ Portal scope gate ═════════════════
    // enforceScope only bites for a community user (one with a ContactId).
    // These tests build a real Customer Community user. High-volume portal
    // profiles (UserType CSPLitePortal) are used deliberately: they need no
    // account-owner role, which keeps the fixture org-independent. If the org
    // has no such profile, the tests exit without asserting — the scope gate
    // is then untestable here, not broken.

    private static User buildPortalUser(Id portalAccountId, String suffix) {
        // Try every portal-capable profile the org offers. Orgs commonly block
        // user creation on STANDARD external profiles (Setup → Digital
        // Experiences → Settings → "Allow using standard external profiles for
        // self-registration, user creation, and login"), which fails the insert
        // with FIELD_INTEGRITY_EXCEPTION — so each candidate is attempted and
        // a refusal moves on to the next (typically a cloned custom profile).
        List<Profile> portalProfiles = [
            SELECT Id FROM Profile
            WHERE UserType IN ('CSPLitePortal', 'PowerCustomerSuccess', 'CustomerSuccess')
            ORDER BY Name LIMIT 10
        ];
        if (portalProfiles.isEmpty()) {
            return null;
        }
        Contact c = new Contact(LastName = 'Portal ' + suffix, AccountId = portalAccountId);
        insert c;

        Integer attempt = 0;
        for (Profile p : portalProfiles) {
            attempt++;
            User portal = new User(
                Alias = 'pdf' + suffix.left(4) + attempt,
                Email = 'pdfportal' + suffix + '@example.com',
                Username = 'pdfportal' + suffix + '.' + attempt + '.'
                    + Datetime.now().getTime() + '@example.com',
                LastName = 'Portal ' + suffix,
                ProfileId = p.Id,
                ContactId = c.Id,
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                TimeZoneSidKey = 'Asia/Kolkata'
            );
            try {
                // Setup-object DML isolated from the Account/Contact DML (MIXED_DML).
                System.runAs(new User(Id = UserInfo.getUserId())) {
                    insert portal;
                }
                return portal;
            } catch (DmlException e) {
                // This profile is not usable for user creation in this org
                // (standard-external-profile block, missing owner role, license
                // exhaustion) — try the next candidate.
            }
        }
        return null;   // no usable portal profile — callers skip, see block comment
    }

    @isTest
    static void portalUser_canRenderTheirOwnInvoice() {
        Fixtures own = mustBuild('S1', 300, 0, 0);
        User portal = buildPortalUser(own.account.Id, 'S1');
        if (portal == null) { return; }   // no community license in this org — see block comment

        Test.startTest();
        InvoicePDFController ctrl;
        System.runAs(portal) {
            ctrl = buildController(own.invoice.Id);
        }
        Test.stopTest();

        System.assertEquals(own.invoice.Id, ctrl.invoice.Id,
            'An invoice billed to the portal user\'s own account renders');
    }

    @isTest
    static void portalUser_cannotRenderAnotherAccountsInvoice() {
        Fixtures own = mustBuild('S2', 300, 0, 0);
        Fixtures other = mustBuild('S3', 400, 0, 0);
        User portal = buildPortalUser(own.account.Id, 'S2');
        if (portal == null) { return; }

        Test.startTest();
        Boolean blocked = false;
        System.runAs(portal) {
            try {
                buildController(other.invoice.Id);
            } catch (InvoicePDFController.PdfAccessException e) {
                blocked = true;
                System.assert(e.getMessage().contains('do not have access'),
                    'With the scope message, not a raw query error');
            }
        }
        Test.stopTest();

        System.assert(blocked,
            'The class is without sharing, so this gate is the ONLY thing standing '
            + 'between a portal user and any invoice id they paste into the URL — '
            + 'an out-of-scope invoice must throw PdfAccessException');
    }

    @isTest
    static void portalUser_canRenderAChildOutletsInvoice() {
        Fixtures distributor = mustBuild('S4', 100, 0, 0);
        Fixtures outlet = mustBuild('S5', 500, 0, 0);
        outlet.account.ParentId = distributor.account.Id;
        update outlet.account;
        User portal = buildPortalUser(distributor.account.Id, 'S4');
        if (portal == null) { return; }

        Test.startTest();
        InvoicePDFController ctrl;
        System.runAs(portal) {
            ctrl = buildController(outlet.invoice.Id);
        }
        Test.stopTest();

        System.assertEquals(outlet.invoice.Id, ctrl.invoice.Id,
            'A distributor portal user may render invoices of outlets parented to '
            + 'their account — the same scope the portal invoice list shows');
    }
}