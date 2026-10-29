/**
 * @description Phase 4 tests for claim settlement (credit-note ledger posting)
 *              and the AR aging statement.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class DMS_ClaimAndLedger_Test {

    private static void enableClaim() {
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, true);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SCHEME_CLAIM, true);
    }

    private static Claim__c newClaim(Id accountId, Decimal total) {
        Claim__c claim = new Claim__c(
            Account__c = accountId,
            Claim_Type__c = 'Scheme Claim',
            Claim_Date__c = Date.today(),
            Total_Amount__c = total,
            Status__c = 'Submitted'
        );
        insert claim;
        return claim;
    }

    @isTest
    static void claimApproval_postsCreditNoteLedger() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist CL', 'Distributor');
        Claim__c claim = newClaim(dist.Id, 500);

        enableClaim();
        Test.startTest();
        update new Claim__c(Id = claim.Id, Status__c = 'Approved', Approved_Amount__c = 500);
        Test.stopTest();

        Claim__c after = [SELECT Credit_Note_Number__c, Approval_Date__c FROM Claim__c WHERE Id = :claim.Id];
        System.assertNotEquals(null, after.Credit_Note_Number__c, 'Credit note number stamped');
        System.assertEquals(Date.today(), after.Approval_Date__c, 'Approval date stamped');

        List<Ledger_Entry__c> ledger = [
            SELECT Account__c, Entry_Type__c, Amount__c, Reference_Type__c
            FROM Ledger_Entry__c WHERE Reference_Id__c = :claim.Id
        ];
        System.assertEquals(1, ledger.size(), 'One credit-note ledger entry posted');
        System.assertEquals('Credit Note', ledger[0].Entry_Type__c, 'Entry type is Credit Note');
        System.assertEquals(500, ledger[0].Amount__c, 'Amount is the approved amount');
        System.assertEquals(dist.Id, ledger[0].Account__c, 'Posted to distributor');
        System.assertEquals('Claim', ledger[0].Reference_Type__c, 'Reference type is Claim');
    }

    @isTest
    static void claimApproval_withTogglesOff_postsNothing() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist CL2', 'Distributor');
        Claim__c claim = newClaim(dist.Id, 300);

        // Explicitly disable in the cache (the org enables the DMS toggles as real
        // Feature_Toggle__mdt, which are visible in tests).
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_MASTER, false);
        BPM_FeatureToggle_Util.toggleCache.put(DMS_Constants.TOGGLE_SCHEME_CLAIM, false);
        Test.startTest();
        update new Claim__c(Id = claim.Id, Status__c = 'Approved', Approved_Amount__c = 300);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Ledger_Entry__c WHERE Reference_Id__c = :claim.Id],
            'No ledger entry when DMS disabled');
    }

    @isTest
    static void aging_bucketsOpenInvoicesByOverdueDays() {
        Account dist = TestDataFactory.createAndInsertAccount('Dist AG', 'Distributor');

        // Current (due in future) and 31-60 (due 45 days ago).
        insert new List<Invoice__c>{
            new Invoice__c(Account__c = dist.Id, Invoice_Date__c = Date.today(),
                Invoice_Number__c = 'AG-1', Status__c = 'Draft',
                Due_Date__c = Date.today().addDays(15), Balance_Due__c = 100,
                Total_Amount__c = 100),
            new Invoice__c(Account__c = dist.Id, Invoice_Date__c = Date.today().addDays(-60),
                Invoice_Number__c = 'AG-2', Status__c = 'Draft',
                Due_Date__c = Date.today().addDays(-45), Balance_Due__c = 250,
                Total_Amount__c = 250)
        };

        Test.startTest();
        Map<String, Decimal> aging = DMS_Ledger_Service.getAging(dist.Id);
        Test.stopTest();

        System.assertEquals(100, aging.get(DMS_Ledger_Service.BUCKET_CURRENT), 'Current bucket');
        System.assertEquals(250, aging.get(DMS_Ledger_Service.BUCKET_31_60), '31-60 bucket');
        System.assertEquals(0, aging.get(DMS_Ledger_Service.BUCKET_90_PLUS), '90+ empty');
    }
}