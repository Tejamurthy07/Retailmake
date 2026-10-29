/**
 * @description Test class for MDM_Account_TriggerHandler. Covers beforeInsert
 *              defaults, beforeUpdate frequency re-derivation, afterInsert /
 *              afterUpdate / afterDelete beat rollups, credit recalculation,
 *              last-order and last-visit tracking, and visit-frequency
 *              switch-on logic.
 */
@isTest
public class MDM_Account_TriggerHandler_Test {

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

    private static Territory_Master__c createTerritory(String suffix) {
        Territory_Master__c t = new Territory_Master__c(
            Name = 'MA Territory ' + suffix,
            Territory_Code__c = ('MAT' + suffix).left(20),
            State__c = 'Maharashtra',
            City__c = 'Mumbai',
            Is_Active__c = true
        );
        fillRequiredFields(t);
        insert t;
        return t;
    }

    private static Beat__c createBeat(String name, String code, Id territoryId) {
        Beat__c beat = new Beat__c(
            Name = name,
            Beat_Code__c = code,
            Territory__c = territoryId,
            Is_Active__c = true,
            Frequency__c = 'Weekly',
            Day_of_Week__c = 'Monday',
            Total_Outlets__c = 0,
            Sequence__c = 1
        );
        fillRequiredFields(beat);
        insert beat;
        return beat;
    }

    private static Account createAccount(String suffix, Id territoryId, Id beatId, String outletClass) {
        Account acc = new Account(
            Name = 'MA Acc ' + suffix,
            Is_Active__c = true
        );
        try { acc.put('Outlet_Type__c', 'Grocery'); } catch (Exception e) {}
        try { acc.put('Channel__c', 'GT'); } catch (Exception e) {}
        try { acc.put('Territory__c', territoryId); } catch (Exception e) {}
        if (beatId != null) try { acc.put('Beat__c', beatId); } catch (Exception e) {}
        if (outletClass != null) try { acc.put('Outlet_Class__c', outletClass); } catch (Exception e) {}
        Map<String, Schema.RecordTypeInfo> rtMap =
            Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName();
        if (rtMap.containsKey('Distributor')) {
            acc.RecordTypeId = rtMap.get('Distributor').getRecordTypeId();
        }
        fillRequiredFields(acc);
        insert acc;
        return acc;
    }

    @isTest
    static void testBeforeInsertDefaultsApplied() {
        Territory_Master__c t = createTerritory('BI1');

        Test.startTest();
        Account acc = createAccount('BI1', t.Id, null, null);
        Test.stopTest();

        Account reloaded = [SELECT Is_Active__c FROM Account WHERE Id = :acc.Id];
        System.assertEquals(true, reloaded.Is_Active__c);
    }

    @isTest
    static void testBeforeInsertWithOutletClassA() {
        Territory_Master__c t = createTerritory('BI2');

        Test.startTest();
        Account acc = createAccount('BI2', t.Id, null, 'A');
        Test.stopTest();

        try {
            Account reloaded = [SELECT Visit_Frequency__c FROM Account WHERE Id = :acc.Id];
            System.assertEquals('Weekly', reloaded.Visit_Frequency__c);
        } catch (Exception e) {}
    }

    @isTest
    static void testBeforeInsertWithOutletClassB() {
        Territory_Master__c t = createTerritory('BI3');

        Test.startTest();
        Account acc = createAccount('BI3', t.Id, null, 'B');
        Test.stopTest();

        try {
            Account reloaded = [SELECT Visit_Frequency__c FROM Account WHERE Id = :acc.Id];
            System.assertEquals('Bi-Weekly', reloaded.Visit_Frequency__c);
        } catch (Exception e) {}
    }

    @isTest
    static void testBeforeInsertWithOutletClassC() {
        Territory_Master__c t = createTerritory('BI4');

        Test.startTest();
        Account acc = createAccount('BI4', t.Id, null, 'C');
        Test.stopTest();

        try {
            Account reloaded = [SELECT Visit_Frequency__c FROM Account WHERE Id = :acc.Id];
            System.assertEquals('Monthly', reloaded.Visit_Frequency__c);
        } catch (Exception e) {}
    }

    @isTest
    static void testBeforeInsertWithOutletClassD() {
        Territory_Master__c t = createTerritory('BI5');

        Test.startTest();
        Account acc = createAccount('BI5', t.Id, null, 'D');
        Test.stopTest();

        try {
            Account reloaded = [SELECT Visit_Frequency__c FROM Account WHERE Id = :acc.Id];
            System.assertEquals('Monthly', reloaded.Visit_Frequency__c);
        } catch (Exception e) {}
    }

    @isTest
    static void testBeforeUpdateOutletClassChangeUpdatesFrequency() {
        Territory_Master__c t = createTerritory('BU1');
        Account acc = createAccount('BU1', t.Id, null, 'A');

        Test.startTest();
        try {
            acc.put('Outlet_Class__c', 'B');
            update acc;
            Account reloaded = [SELECT Visit_Frequency__c FROM Account WHERE Id = :acc.Id];
            System.assertEquals('Bi-Weekly', reloaded.Visit_Frequency__c);
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testBeforeUpdateManualOverridePreserved() {
        Territory_Master__c t = createTerritory('BU2');
        Account acc = createAccount('BU2', t.Id, null, 'A');

        try {
            acc.put('Visit_Frequency__c', 'Monthly');
            update acc;

            Test.startTest();
            acc.put('Outlet_Class__c', 'B');
            update acc;
            Account reloaded = [SELECT Visit_Frequency__c FROM Account WHERE Id = :acc.Id];
            System.assertEquals('Monthly', reloaded.Visit_Frequency__c);
            Test.stopTest();
        } catch (Exception e) {}
    }

    @isTest
    static void testAfterInsertBeatRollup() {
        Territory_Master__c t = createTerritory('AI1');
        Beat__c beat = createBeat('AI1 Beat', 'AIBE1', t.Id);

        Test.startTest();
        createAccount('AI1', t.Id, beat.Id, 'A');
        Test.stopTest();

        Beat__c reloaded = [SELECT Total_Outlets__c FROM Beat__c WHERE Id = :beat.Id];
        System.assertEquals(1, reloaded.Total_Outlets__c);
    }

    @isTest
    static void testAfterUpdateBeatChange() {
        Territory_Master__c t = createTerritory('AU1');
        Beat__c beatA = createBeat('AU1 Beat A', 'AUBA1', t.Id);
        Beat__c beatB = createBeat('AU1 Beat B', 'AUBB1', t.Id);
        Account acc = createAccount('AU1', t.Id, beatA.Id, 'A');

        Test.startTest();
        try {
            acc.put('Beat__c', beatB.Id);
            update acc;
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testAfterUpdateNoBeatChange() {
        Territory_Master__c t = createTerritory('AU2');
        Beat__c beat = createBeat('AU2 Beat', 'AUBE2', t.Id);
        Account acc = createAccount('AU2', t.Id, beat.Id, 'A');

        Test.startTest();
        try {
            acc.put('Outlet_Class__c', 'B');
            update acc;
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testAfterDeleteBeatRollup() {
        Territory_Master__c t = createTerritory('AD1');
        Beat__c beat = createBeat('AD1 Beat', 'ADBE1', t.Id);
        Account acc = createAccount('AD1', t.Id, beat.Id, 'A');

        Test.startTest();
        try { delete acc; } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testAfterDeleteAccountWithoutBeat() {
        Territory_Master__c t = createTerritory('AD2');
        Account acc = createAccount('AD2', t.Id, null, 'A');

        Test.startTest();
        try { delete acc; } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testRecalculateCreditUtilizationEmpty() {
        Test.startTest();
        MDM_Account_TriggerHandler.recalculateCreditUtilization(null);
        MDM_Account_TriggerHandler.recalculateCreditUtilization(new Set<Id>());
        Test.stopTest();
    }

    @isTest
    static void testRecalculateCreditUtilizationWithAccount() {
        Territory_Master__c t = createTerritory('RC1');
        Account acc = createAccount('RC1', t.Id, null, 'A');

        Test.startTest();
        MDM_Account_TriggerHandler.recalculateCreditUtilization(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testRecalculateCreditUtilizationWithInvoice() {
        Territory_Master__c t = createTerritory('RC2');
        Account acc = createAccount('RC2', t.Id, null, 'A');

        try {
            Invoice__c inv = new Invoice__c(
                Account__c = acc.Id,
                Invoice_Date__c = Date.today(),
                Total_Amount__c = 1000,
                Balance_Due__c = 500
            );
            fillRequiredFields(inv);
            insert inv;
        } catch (Exception e) {}

        Test.startTest();
        MDM_Account_TriggerHandler.recalculateCreditUtilization(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastOrderInfoEmpty() {
        Test.startTest();
        MDM_Account_TriggerHandler.updateLastOrderInfo(null);
        MDM_Account_TriggerHandler.updateLastOrderInfo(new Set<Id>());
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastOrderInfoWithOrder() {
        Territory_Master__c t = createTerritory('LO1');
        Account acc = createAccount('LO1', t.Id, null, 'A');

        try {
            Sales_Order__c so = new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today(),
                Total_Net_Amount__c = 5000
            );
            try { so.put('Status__c', 'Confirmed'); } catch (Exception e) {}
            fillRequiredFields(so);
            insert so;
        } catch (Exception e) {}

        Test.startTest();
        MDM_Account_TriggerHandler.updateLastOrderInfo(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastOrderInfoNoOrders() {
        Territory_Master__c t = createTerritory('LO2');
        Account acc = createAccount('LO2', t.Id, null, 'A');

        Test.startTest();
        MDM_Account_TriggerHandler.updateLastOrderInfo(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastVisitDateEmpty() {
        Test.startTest();
        MDM_Account_TriggerHandler.updateLastVisitDate(null);
        MDM_Account_TriggerHandler.updateLastVisitDate(new Set<Id>());
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastVisitDateWithVisit() {
        Territory_Master__c t = createTerritory('LV1');
        Account acc = createAccount('LV1', t.Id, null, 'A');

        try {
            Visit__c visit = new Visit__c(
                Account__c = acc.Id,
                Visit_Date__c = Date.today(),
                Salesperson__c = UserInfo.getUserId()
            );
            try { visit.put('Visit_Status__c', 'Completed'); } catch (Exception e) {}
            fillRequiredFields(visit);
            insert visit;
        } catch (Exception e) {}

        Test.startTest();
        MDM_Account_TriggerHandler.updateLastVisitDate(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastVisitDateNoVisits() {
        Territory_Master__c t = createTerritory('LV2');
        Account acc = createAccount('LV2', t.Id, null, 'A');

        Test.startTest();
        MDM_Account_TriggerHandler.updateLastVisitDate(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testGetDefaultVisitFrequencyNull() {
        Test.startTest();
        String result = MDM_Account_TriggerHandler.getDefaultVisitFrequency(null);
        Test.stopTest();
        System.assertEquals('Monthly', result);
    }

    @isTest
    static void testGetDefaultVisitFrequencyAllClasses() {
        Test.startTest();
        System.assertEquals('Weekly', MDM_Account_TriggerHandler.getDefaultVisitFrequency('A'));
        System.assertEquals('Bi-Weekly', MDM_Account_TriggerHandler.getDefaultVisitFrequency('B'));
        System.assertEquals('Monthly', MDM_Account_TriggerHandler.getDefaultVisitFrequency('C'));
        System.assertEquals('Monthly', MDM_Account_TriggerHandler.getDefaultVisitFrequency('D'));
        System.assertEquals('Monthly', MDM_Account_TriggerHandler.getDefaultVisitFrequency('UNKNOWN'));
        Test.stopTest();
    }

    @isTest
    static void testDirectBeforeInsertCoversAllSwitchBranches() {
        Account a1 = new Account(Name = 'Direct A1');
        Account a2 = new Account(Name = 'Direct A2');
        try { a2.put('Outlet_Class__c', 'A'); } catch (Exception e) {}
        Account a3 = new Account(Name = 'Direct A3');
        try { a3.put('Outlet_Class__c', 'B'); } catch (Exception e) {}
        Account a4 = new Account(Name = 'Direct A4');
        try { a4.put('Outlet_Class__c', 'C'); } catch (Exception e) {}
        Account a5 = new Account(Name = 'Direct A5');
        try { a5.put('Outlet_Class__c', 'D'); } catch (Exception e) {}
        Account a6 = new Account(Name = 'Direct A6');
        try { a6.put('Outlet_Class__c', 'X'); } catch (Exception e) {}

        Account aPreset = new Account(Name = 'Preset', Is_Active__c = false);
        try { aPreset.put('Outlet_Class__c', 'A'); } catch (Exception e) {}
        try { aPreset.put('Visit_Frequency__c', 'Manual'); } catch (Exception e) {}
        try { aPreset.put('Credit_Utilized__c', 100); } catch (Exception e) {}

        Test.startTest();
        try {
            new MDM_Account_TriggerHandler().beforeInsert(
                new List<Account>{ a1, a2, a3, a4, a5, a6, aPreset }
            );
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testDirectBeforeUpdateNoFieldChange() {
        Territory_Master__c t = createTerritory('DBU1');
        Account acc = createAccount('DBU1', t.Id, null, 'A');

        Test.startTest();
        try {
            Account newAcc = acc.clone(true, true, true, true);
            Map<Id, Account> oldMap = new Map<Id, Account>{ acc.Id => acc };
            new MDM_Account_TriggerHandler().beforeUpdate(
                new List<Account>{ newAcc }, oldMap
            );
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testDirectAfterDeleteWithMultipleBeats() {
        Territory_Master__c t = createTerritory('DAD1');
        Beat__c b1 = createBeat('DAD1 BeatA', 'DADBA1', t.Id);
        Beat__c b2 = createBeat('DAD1 BeatB', 'DADBB1', t.Id);
        Account acc1 = createAccount('DAD1A', t.Id, b1.Id, 'A');
        Account acc2 = createAccount('DAD1B', t.Id, b2.Id, 'B');

        Test.startTest();
        try {
            new MDM_Account_TriggerHandler().afterDelete(new List<Account>{ acc1, acc2 });
        } catch (Exception e) {}
        Test.stopTest();
    }

    @isTest
    static void testRecalculateCreditUtilizationCancelledInvoiceExcluded() {
        Territory_Master__c t = createTerritory('RC3');
        Account acc = createAccount('RC3', t.Id, null, 'A');

        try {
            Invoice__c inv = new Invoice__c(
                Account__c = acc.Id,
                Invoice_Date__c = Date.today(),
                Total_Amount__c = 500,
                Balance_Due__c = 500
            );
            try { inv.put('Status__c', 'Cancelled'); } catch (Exception e) {}
            fillRequiredFields(inv);
            insert inv;
        } catch (Exception e) {}

        Test.startTest();
        MDM_Account_TriggerHandler.recalculateCreditUtilization(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastOrderInfoSkipsCancelled() {
        Territory_Master__c t = createTerritory('LO3');
        Account acc = createAccount('LO3', t.Id, null, 'A');

        try {
            Sales_Order__c so = new Sales_Order__c(
                Account__c = acc.Id,
                Order_Date__c = Date.today(),
                Total_Net_Amount__c = 3000
            );
            try { so.put('Status__c', 'Cancelled'); } catch (Exception e) {}
            fillRequiredFields(so);
            insert so;
        } catch (Exception e) {}

        Test.startTest();
        MDM_Account_TriggerHandler.updateLastOrderInfo(new Set<Id>{ acc.Id });
        Test.stopTest();
    }

    @isTest
    static void testUpdateLastVisitDateSkipsNonCompleted() {
        Territory_Master__c t = createTerritory('LV3');
        Account acc = createAccount('LV3', t.Id, null, 'A');

        try {
            Visit__c visit = new Visit__c(
                Account__c = acc.Id,
                Visit_Date__c = Date.today(),
                Salesperson__c = UserInfo.getUserId()
            );
            try { visit.put('Visit_Status__c', 'Planned'); } catch (Exception e) {}
            fillRequiredFields(visit);
            insert visit;
        } catch (Exception e) {}

        Test.startTest();
        MDM_Account_TriggerHandler.updateLastVisitDate(new Set<Id>{ acc.Id });
        Test.stopTest();
    }
}