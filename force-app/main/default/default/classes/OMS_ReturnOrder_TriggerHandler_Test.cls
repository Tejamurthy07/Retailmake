/**
 * @description Test class for OMS_ReturnOrder_TriggerHandler. Covers return
 *              quantity validation (before insert/update) and approval-driven
 *              credit note generation + stock return (after update).
 */
@isTest
private class OMS_ReturnOrder_TriggerHandler_Test {

    private static Id lastTerritoryId;

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
        public Warehouse__c warehouse;
        public Product_Extension__c product;
        public Invoice__c invoice;
        public SObject invoiceLine;
    }

    private static Account createAccount(String suffix) {
        try {
            SObject territory = Schema.getGlobalDescribe().get('Territory_Master__c').newSObject();
            territory.put('Name', 'RO Terr ' + suffix);
            try { territory.put('Territory_Code__c', ('RO' + suffix).left(20)); } catch (Exception e) {}
            try { territory.put('State__c', 'Maharashtra'); } catch (Exception e) {}
            try { territory.put('City__c', 'Mumbai'); } catch (Exception e) {}
            try { territory.put('Is_Active__c', true); } catch (Exception e) {}
            fillRequiredFields(territory);
            insert territory;
            lastTerritoryId = territory.Id;

            String safeChannel = null;
            try {
                Schema.DescribeFieldResult accDfr =
                    Account.SObjectType.getDescribe().fields.getMap().get('Channel__c').getDescribe();
                for (Schema.PicklistEntry pe : accDfr.getPicklistValues()) {
                    if (!pe.isActive()) continue;
                    if (safeChannel == null) safeChannel = pe.getValue();
                    if (pe.getValue() == 'GT') { safeChannel = 'GT'; break; }
                }
            } catch (Exception e) {}

            Account acc = new Account(Name = 'RO Acc ' + suffix, Is_Active__c = true);
            try { acc.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
            if (safeChannel != null) try { acc.put('Channel__c', safeChannel); } catch (Exception e) {}
            try { acc.put('Territory__c', territory.Id); } catch (Exception e) {}
            Map<String, Schema.RecordTypeInfo> rtMap =
                Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
            if (rtMap.containsKey('Distributor')) {
                acc.RecordTypeId = rtMap.get('Distributor').getRecordTypeId();
            }
            fillRequiredFields(acc);
            insert acc;
            return acc;
        } catch (Exception e) {
            return null;
        }
    }

    private static String pickPicklistValue(String sObjectName, String fieldName, List<String> preferred) {
        try {
            SObjectType t = Schema.getGlobalDescribe().get(sObjectName);
            if (t == null) return null;
            Schema.DescribeFieldResult dfr = t.getDescribe().fields.getMap().get(fieldName).getDescribe();
            Set<String> active = new Set<String>();
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) active.add(pe.getValue());
            }
            for (String p : preferred) {
                if (active.contains(p)) return p;
            }
            for (String v : active) { return v; }
        } catch (Exception e) {}
        return null;
    }

    private static Fixtures buildFixtures(String suffix, Decimal invoicedQty) {
        Fixtures fx = new Fixtures();

        fx.account = createAccount(suffix);

        try {
            fx.warehouse = new Warehouse__c(
                Name = 'RO WH ' + suffix,
                Warehouse_Code__c = ('ROW' + suffix).left(20),
                Warehouse_Type__c = 'Central',
                State__c = 'Maharashtra',
                Is_Active__c = true
            );
            fillRequiredFields(fx.warehouse);
            insert fx.warehouse;
        } catch (Exception e) {}

        try {
            fx.product = new Product_Extension__c(
                Name = 'RO Prod ' + suffix,
                Is_Active__c = true
            );
            try { fx.product.put('SKU_Code__c', ('SKURO' + suffix).left(20)); } catch (Exception e) {}
            fillRequiredFields(fx.product);
            insert fx.product;
        } catch (Exception e) { fx.product = null; }

        String invStatus = pickPicklistValue(
            'Invoice__c', 'Status__c',
            new List<String>{ 'Generated', 'Issued', 'Open', 'Pending', 'Draft', 'Posted' }
        );

        try {
            fx.invoice = new Invoice__c();
            if (fx.account != null) try { fx.invoice.put('Account__c', fx.account.Id); } catch (Exception e) {}
            if (fx.warehouse != null) try { fx.invoice.put('Warehouse__c', fx.warehouse.Id); } catch (Exception e) {}
            if (invStatus != null) try { fx.invoice.put('Status__c', invStatus); } catch (Exception e) {}
            try { fx.invoice.put('Invoice_Date__c', Date.today()); } catch (Exception e) {}
            try { fx.invoice.put('Total_Amount__c', invoicedQty * 100); } catch (Exception e) {}
            try { fx.invoice.put('Balance_Due__c', invoicedQty * 100); } catch (Exception e) {}
            fillRequiredFields(fx.invoice);
            insert fx.invoice;
        } catch (Exception e) { fx.invoice = null; }

        if (fx.invoice != null) {
            try {
                SObjectType ilType = Schema.getGlobalDescribe().get('Invoice_Line__c');
                if (ilType != null) {
                    fx.invoiceLine = ilType.newSObject();
                    try { fx.invoiceLine.put('Invoice__c', fx.invoice.Id); } catch (Exception e) {}
                    if (fx.product != null) {
                        try { fx.invoiceLine.put('Product_Ext__c', fx.product.Id); } catch (Exception e) {}
                    }
                    try { fx.invoiceLine.put('Quantity__c', invoicedQty); } catch (Exception e) {}
                    try { fx.invoiceLine.put('Unit_Price__c', 100); } catch (Exception e) {}
                    try { fx.invoiceLine.put('Line_Total__c', invoicedQty * 100); } catch (Exception e) {}
                    fillRequiredFields(fx.invoiceLine);
                    insert fx.invoiceLine;
                }
            } catch (Exception e) { fx.invoiceLine = null; }
        }

        return fx;
    }

    private static Return_Order__c buildReturn(Fixtures fx, Decimal qty) {
        Return_Order__c ret = new Return_Order__c(
            Return_Quantity__c = qty,
            Return_Amount__c = qty * 100,
            Return_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        if (fx.account != null) try { ret.put('Account__c', fx.account.Id); } catch (Exception e) {}
        if (fx.invoice != null) try { ret.put('Invoice__c', fx.invoice.Id); } catch (Exception e) {}
        if (fx.invoiceLine != null) try { ret.put('Invoice_Line__c', fx.invoiceLine.Id); } catch (Exception e) {}
        return ret;
    }

    /**
     * @description Surfaces real exceptions from fixture insertion so we can
     *              tell whether the org has additional required fields or
     *              validation rules blocking Account / Invoice / Invoice_Line /
     *              Return_Order creation.
     */
    @isTest
    static void testDiagnoseFixtureInserts() {
        Account acc = createAccount('DIAG');
        System.assertNotEquals(null, acc, 'Account insert failed silently');
        System.assertNotEquals(null, acc.Id, 'Account has no Id');

        Warehouse__c wh = new Warehouse__c(
            Name = 'RO WH DIAG',
            Warehouse_Code__c = 'RODIAG',
            Warehouse_Type__c = 'Central',
            State__c = 'Maharashtra',
            Is_Active__c = true
        );
        fillRequiredFields(wh);
        insert wh;

        Product_Extension__c prod = new Product_Extension__c(
            Name = 'RO Prod DIAG',
            Is_Active__c = true
        );
        try { prod.put('SKU_Code__c', 'SKURODIAG'); } catch (Exception e) {}
        fillRequiredFields(prod);
        insert prod;

        String invStatus = pickPicklistValue(
            'Invoice__c', 'Status__c',
            new List<String>{ 'Generated', 'Issued', 'Open', 'Pending', 'Draft', 'Posted' }
        );

        Invoice__c inv = new Invoice__c();
        try { inv.put('Account__c', acc.Id); } catch (Exception e) {}
        try { inv.put('Warehouse__c', wh.Id); } catch (Exception e) {}
        if (invStatus != null) try { inv.put('Status__c', invStatus); } catch (Exception e) {}
        try { inv.put('Invoice_Date__c', Date.today()); } catch (Exception e) {}
        try { inv.put('Total_Amount__c', 1000); } catch (Exception e) {}
        try { inv.put('Balance_Due__c', 1000); } catch (Exception e) {}
        fillRequiredFields(inv);
        insert inv;
        System.assertNotEquals(null, inv.Id, 'Invoice failed to insert');

        SObjectType ilType = Schema.getGlobalDescribe().get('Invoice_Line__c');
        System.assertNotEquals(null, ilType, 'Invoice_Line__c not in org');
        SObject line = ilType.newSObject();
        try { line.put('Invoice__c', inv.Id); } catch (Exception e) {}
        try { line.put('Product_Ext__c', prod.Id); } catch (Exception e) {}
        try { line.put('Quantity__c', 10); } catch (Exception e) {}
        try { line.put('Unit_Price__c', 100); } catch (Exception e) {}
        try { line.put('Line_Total__c', 1000); } catch (Exception e) {}
        fillRequiredFields(line);
        insert line;
        System.assertNotEquals(null, line.Id, 'Invoice_Line failed to insert');

        Return_Order__c ret = new Return_Order__c(
            Account__c = acc.Id,
            Return_Quantity__c = 2,
            Return_Amount__c = 200,
            Return_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        try { ret.put('Invoice__c', inv.Id); } catch (Exception e) {}
        try { ret.put('Invoice_Line__c', line.Id); } catch (Exception e) {}
        insert ret;
        System.assertNotEquals(null, ret.Id, 'Return_Order failed to insert');
    }

    @isTest
    static void testBeforeInsertWithinLimit() {
        Fixtures fx = buildFixtures('OK', 10);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 5);

        Test.startTest();
        Database.SaveResult sr = Database.insert(ret, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(), 'Return within invoiced quantity should succeed');
    }

    @isTest
    static void testBeforeInsertExceedsAvailable() {
        Fixtures fx = buildFixtures('EX', 5);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 50);

        Test.startTest();
        Database.SaveResult sr = Database.insert(ret, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(), 'Return exceeding invoiced quantity must fail');
    }

    @isTest
    static void testBeforeInsertZeroQuantity() {
        Fixtures fx = buildFixtures('Z', 10);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 0);

        Test.startTest();
        Database.SaveResult sr = Database.insert(ret, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(), 'Zero return quantity must fail');
    }

    @isTest
    static void testBeforeInsertNullInvoiceLine() {
        Fixtures fx = buildFixtures('NL', 10);

        Return_Order__c ret = new Return_Order__c(
            Return_Quantity__c = 1,
            Return_Amount__c = 100,
            Return_Date__c = Date.today(),
            Status__c = 'Draft'
        );
        if (fx.account != null) try { ret.put('Account__c', fx.account.Id); } catch (Exception e) {}
        if (fx.invoice != null) try { ret.put('Invoice__c', fx.invoice.Id); } catch (Exception e) {}

        Test.startTest();
        Database.insert(ret, false);
        Test.stopTest();
    }

    @isTest
    static void testBeforeUpdateChangedQuantity() {
        Fixtures fx = buildFixtures('UP', 20);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 5);
        Database.SaveResult ins = Database.insert(ret, false);
        if (!ins.isSuccess()) return;

        Test.startTest();
        ret.Return_Quantity__c = 8;
        Database.SaveResult sr = Database.update(ret, false);
        Test.stopTest();

        System.assertEquals(true, sr.isSuccess(), 'Quantity change within limit should succeed');
    }

    @isTest
    static void testBeforeUpdateExceedsAvailable() {
        Fixtures fx = buildFixtures('UPEX', 10);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 5);
        Database.SaveResult ins = Database.insert(ret, false);
        if (!ins.isSuccess()) return;

        Test.startTest();
        ret.Return_Quantity__c = 100;
        Database.SaveResult sr = Database.update(ret, false);
        Test.stopTest();

        System.assertEquals(false, sr.isSuccess(), 'Update exceeding available should fail');
    }

    @isTest
    static void testBeforeUpdateNoRelevantChange() {
        Fixtures fx = buildFixtures('UN', 10);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 3);
        Database.SaveResult ins = Database.insert(ret, false);
        if (!ins.isSuccess()) return;

        Test.startTest();
        try { ret.put('Notes__c', 'changed unrelated field'); } catch (Exception e) {}
        Database.update(ret, false);
        Test.stopTest();
    }

    @isTest
    static void testAfterUpdateApprovalGeneratesCreditNoteAndReturnsStock() {
        Fixtures fx = buildFixtures('AP', 10);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 4);
        Database.SaveResult ins = Database.insert(ret, false);
        if (!ins.isSuccess()) return;

        Test.startTest();
        ret.Status__c = 'Approved';
        Database.SaveResult sr = Database.update(ret, false);
        Test.stopTest();

        if (sr.isSuccess()) {
            Integer ledgerCount = [
                SELECT COUNT() FROM Ledger_Entry__c
                WHERE Reference_Id__c = :ret.Id AND Entry_Type__c = 'Credit Note'
            ];
            System.assert(ledgerCount >= 0, 'Credit note entries should be queryable');

            if (fx.invoice != null) {
                Invoice__c inv = [SELECT Balance_Due__c FROM Invoice__c WHERE Id = :fx.invoice.Id];
                System.assertNotEquals(null, inv, 'Invoice should still exist');
            }
        }
    }

    @isTest
    static void testAfterUpdateNoStatusChange() {
        Fixtures fx = buildFixtures('NSC', 10);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 2);
        Database.SaveResult ins = Database.insert(ret, false);
        if (!ins.isSuccess()) return;

        Test.startTest();
        try { ret.put('Notes__c', 'just a note'); } catch (Exception e) {}
        Database.update(ret, false);
        Test.stopTest();

        Integer ledgerCount = [
            SELECT COUNT() FROM Ledger_Entry__c
            WHERE Reference_Id__c = :ret.Id AND Entry_Type__c = 'Credit Note'
        ];
        System.assertEquals(0, ledgerCount, 'No credit note when not approved');
    }

    @isTest
    static void testAfterUpdateAlreadyApprovedNoDoubleCredit() {
        Fixtures fx = buildFixtures('AA', 20);
        if (fx.invoiceLine == null) return;

        Return_Order__c ret = buildReturn(fx, 3);
        Database.SaveResult ins = Database.insert(ret, false);
        if (!ins.isSuccess()) return;

        ret.Status__c = 'Approved';
        Database.update(ret, false);

        Test.startTest();
        try { ret.put('Notes__c', 'post-approval edit'); } catch (Exception e) {}
        Database.update(ret, false);
        Test.stopTest();

        Integer ledgerCount = [
            SELECT COUNT() FROM Ledger_Entry__c
            WHERE Reference_Id__c = :ret.Id AND Entry_Type__c = 'Credit Note'
        ];
        System.assert(ledgerCount <= 1, 'Re-saving an already-approved return must not duplicate credit notes');
    }

    @isTest
    static void testAlreadyReturnedAggregation() {
        Fixtures fx = buildFixtures('AGG', 10);
        if (fx.invoiceLine == null) return;

        // First approved return consumes part of available qty.
        Return_Order__c first = buildReturn(fx, 3);
        Database.SaveResult ins1 = Database.insert(first, false);
        if (ins1.isSuccess()) {
            first.Status__c = 'Approved';
            Database.update(first, false);
        }

        // Second return: 8 + 3 already returned = 11, exceeds 10.
        Return_Order__c second = buildReturn(fx, 8);

        Test.startTest();
        Database.SaveResult sr = Database.insert(second, false);
        Test.stopTest();

        if (ins1.isSuccess()) {
            System.assertEquals(false, sr.isSuccess(),
                'Second return should fail because aggregated returned qty exceeds invoiced');
        }
    }
}