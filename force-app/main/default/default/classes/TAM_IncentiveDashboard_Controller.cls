public with sharing class TAM_IncentiveDashboard_Controller {

    public class DashboardData {
        @AuraEnabled public List<Incentive__c> incentives;
        @AuraEnabled public List<Target_Period__c> periods;
        @AuraEnabled public Map<String, Object> summary;
        @AuraEnabled public String currentPeriodId;
        @AuraEnabled public List<Map<String, String>> criteriaOptions;
        @AuraEnabled public List<Map<String, String>> profileOptions;
        @AuraEnabled public List<Map<String, String>> territoryOptions;
    }

    @AuraEnabled(cacheable=false)
    public static DashboardData getDashboardData() {
        DashboardData dx = new DashboardData();

        dx.periods = [
            SELECT Id, Name, Start_Date__c, End_Date__c
            FROM Target_Period__c
            WHERE Is_Active__c = true
            ORDER BY Start_Date__c DESC
            LIMIT 20
        ];

        List<Target_Period__c> currentPeriods = [
            SELECT Id FROM Target_Period__c
            WHERE Is_Default__c = true AND Is_Active__c = true
            LIMIT 1
        ];
        if (currentPeriods.isEmpty()) {
            currentPeriods = [
                SELECT Id FROM Target_Period__c
                WHERE Start_Date__c <= TODAY AND End_Date__c >= TODAY
                AND Is_Active__c = true ORDER BY Type__c ASC LIMIT 1
            ];
        }
        dx.currentPeriodId = currentPeriods.isEmpty() ? '' : currentPeriods[0].Id;

        // Filter options
        dx.criteriaOptions = getFilterOptions('criteria');
        dx.profileOptions = getFilterOptions('profile');
        dx.territoryOptions = getFilterOptions('territory');

        if (String.isNotBlank(dx.currentPeriodId)) {
            dx.incentives = queryIncentives(dx.currentPeriodId, null);
            dx.summary = buildSummary(dx.incentives);
        } else {
            dx.incentives = new List<Incentive__c>();
            dx.summary = buildSummary(dx.incentives);
        }

        return dx;
    }

    @AuraEnabled(cacheable=false)
    public static List<Incentive__c> getIncentives(String periodId, String status) {
        return queryIncentives(periodId, status);
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getIncentiveSummary(String periodId) {
        List<Incentive__c> incentives = queryIncentives(periodId, null);
        return buildSummary(incentives);
    }

    @AuraEnabled(cacheable=false)
    public static Incentive__c getIncentiveDetail(Id incentiveId) {
        return [
            SELECT Id, Name, Salesperson__c, Salesperson__r.Name,
                   Target_Actual__c, Target_Actual__r.Name,
                   Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Period__c, Target_Period__r.Name,
                   Incentive_Slab_Ref__c, Incentive_Slab_Ref__r.Name,
                   Incentive_Slab_Ref__r.Payout_Type__c, Incentive_Slab_Ref__r.Payout_Value__c,
                   Incentive_Slab_Ref__r.Min_Percent__c, Incentive_Slab_Ref__r.Max_Percent__c,
                   Achievement_Percent__c, Multiplier__c,
                   Base_Amount__c, Calculated_Amount__c, Final_Amount__c,
                   Status__c, Approved_By__c, Approved_By__r.Name,
                   Approval_Date__c, Payment_Date__c, Notes__c,
                   Period_Month__c, Period_Year__c,
                   Is_Annual_Bonus__c, Annual_Bonus__c,
                   CreatedDate, LastModifiedDate
            FROM Incentive__c
            WHERE Id = :incentiveId
        ];
    }

    private static final Integer SYNC_THRESHOLD = 200;

    @AuraEnabled
    public static String runCalculation(String periodId) {
        Target_Period__c period = [SELECT Id, Type__c FROM Target_Period__c WHERE Id = :periodId];

        Integer recordCount = [
            SELECT COUNT() FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND Target_Criteria__r.Active__c = true
            AND Target_Value__c > 0
        ];

        if (recordCount == 0) {
            return 'No target records found for this period.';
        }

        if (recordCount > SYNC_THRESHOLD) {
            Boolean calcBonus = (period.Type__c == 'Yearly');
            Database.executeBatch(new TAM_IncentiveCalculation_Batch(periodId, calcBonus), 50);
            return 'Large dataset (' + recordCount + ' targets). Calculation running in background — refresh in a few moments.';
        }

        List<Target_Actual__c> actuals = [
            SELECT Id, User__c, Target_Criteria__c, Target_Criteria__r.Name,
                   Target_Criteria__r.Incentive_Weight__c,
                   Target_Criteria__r.Prerequisite_Criteria__c,
                   Target_Criteria__r.Prerequisite_Min_Percent__c,
                   Target_Value__c, Achievement_Value__c,
                   Teams_Target__c, Teams_Achievement__c,
                   Target_Period__c, Target_Period__r.Start_Date__c,
                   Target_Period__r.End_Date__c, Target_Period__r.Type__c
            FROM Target_Actual__c
            WHERE Target_Period__c = :periodId
            AND Target_Criteria__r.Active__c = true
            AND Target_Value__c > 0
        ];

        List<Incentive__c> results = TAM_IncentiveCalculation_Service.calculateForTargetActuals(actuals, periodId);

        if (period.Type__c == 'Yearly') {
            TAM_IncentiveCalculation_Service.calculateAnnualBonus(periodId);
        }

        String msg = results.size() + ' incentive records calculated from ' + actuals.size() + ' targets.';
        return msg;
    }

    @AuraEnabled
    public static void runAnnualBonus(String periodId) {
        TAM_IncentiveCalculation_Service.calculateAnnualBonus(periodId);
    }

    @AuraEnabled
    public static void submitForApproval(List<Id> incentiveIds) {
        List<Incentive__c> toUpdate = [
            SELECT Id, Status__c FROM Incentive__c
            WHERE Id IN :incentiveIds AND Status__c = 'Calculated'
        ];
        for (Incentive__c inc : toUpdate) {
            inc.Status__c = 'Pending Approval';
        }
        update toUpdate;
    }

    @AuraEnabled
    public static void approveIncentives(List<Id> incentiveIds) {
        List<Incentive__c> toUpdate = [
            SELECT Id, Status__c, Calculated_Amount__c FROM Incentive__c
            WHERE Id IN :incentiveIds AND Status__c = 'Pending Approval'
        ];
        for (Incentive__c inc : toUpdate) {
            inc.Status__c = 'Approved';
            inc.Final_Amount__c = inc.Calculated_Amount__c;
            inc.Approved_By__c = UserInfo.getUserId();
            inc.Approval_Date__c = System.now();
        }
        update toUpdate;
    }

    @AuraEnabled
    public static void rejectIncentives(List<Id> incentiveIds) {
        List<Incentive__c> toUpdate = [
            SELECT Id, Status__c FROM Incentive__c
            WHERE Id IN :incentiveIds AND Status__c = 'Pending Approval'
        ];
        for (Incentive__c inc : toUpdate) {
            inc.Status__c = 'Rejected';
        }
        update toUpdate;
    }

    @AuraEnabled
    public static void markAsPaid(List<Id> incentiveIds, Date paymentDate) {
        List<Incentive__c> toUpdate = [
            SELECT Id, Status__c FROM Incentive__c
            WHERE Id IN :incentiveIds AND Status__c = 'Approved'
        ];
        for (Incentive__c inc : toUpdate) {
            inc.Status__c = 'Paid';
            inc.Payment_Date__c = paymentDate;
        }
        update toUpdate;
    }

    private static List<Incentive__c> queryIncentives(String periodId, String status) {
        String q = 'SELECT Id, Name, Salesperson__c, Salesperson__r.Name, ' +
            'Salesperson__r.Profile.Name, ' +
            'Target_Criteria__c, Target_Criteria__r.Name, ' +
            'Target_Period__c, Target_Period__r.Name, ' +
            'Incentive_Slab_Ref__c, Incentive_Slab_Ref__r.Name, ' +
            'Incentive_Slab_Ref__r.Profile_Name__c, ' +
            'Incentive_Slab_Ref__r.Territory__c, Incentive_Slab_Ref__r.Territory__r.Name, ' +
            'Achievement_Percent__c, Multiplier__c, ' +
            'Base_Amount__c, Calculated_Amount__c, Final_Amount__c, ' +
            'Status__c, Payment_Date__c, Approval_Date__c, Is_Annual_Bonus__c ' +
            'FROM Incentive__c WHERE Target_Period__c = :periodId';

        if (String.isNotBlank(status) && status != 'All') {
            q += ' AND Status__c = :status';
        }

        q += ' ORDER BY Salesperson__r.Name, Target_Criteria__r.Name';

        return Database.query(q);
    }

    private static Map<String, Object> buildSummary(List<Incentive__c> incentives) {
        Map<String, Object> summary = new Map<String, Object>();
        Integer total = 0, calculated = 0, pending = 0, approved = 0, rejected = 0, paid = 0;
        Decimal totalCalcAmt = 0, totalApprovedAmt = 0, totalPaidAmt = 0;

        for (Incentive__c inc : incentives) {
            total++;
            Decimal amt = inc.Calculated_Amount__c != null ? inc.Calculated_Amount__c : 0;

            if (inc.Status__c == 'Calculated') { calculated++; totalCalcAmt += amt; }
            else if (inc.Status__c == 'Pending Approval') { pending++; totalCalcAmt += amt; }
            else if (inc.Status__c == 'Approved') { approved++; totalApprovedAmt += (inc.Final_Amount__c != null ? inc.Final_Amount__c : amt); }
            else if (inc.Status__c == 'Rejected') { rejected++; }
            else if (inc.Status__c == 'Paid') { paid++; totalPaidAmt += (inc.Final_Amount__c != null ? inc.Final_Amount__c : amt); }
        }

        summary.put('total', total);
        summary.put('calculated', calculated);
        summary.put('pending', pending);
        summary.put('approved', approved);
        summary.put('rejected', rejected);
        summary.put('paid', paid);
        summary.put('totalCalcAmt', totalCalcAmt);
        summary.put('totalApprovedAmt', totalApprovedAmt);
        summary.put('totalPaidAmt', totalPaidAmt);

        return summary;
    }

    private static List<Map<String, String>> getFilterOptions(String filterType) {
        List<Map<String, String>> opts = new List<Map<String, String>>();
        opts.add(new Map<String, String>{ 'label' => '-- All --', 'value' => '' });

        if (filterType == 'criteria') {
            for (Target_Criteria__c tc : [
                SELECT Id, Name FROM Target_Criteria__c WHERE Active__c = true ORDER BY Name
            ]) {
                opts.add(new Map<String, String>{ 'label' => tc.Name, 'value' => tc.Id });
            }
        } else if (filterType == 'profile') {
            for (AggregateResult ar : [
                SELECT Salesperson__r.Profile.Name profileName
                FROM Incentive__c
                WHERE Salesperson__r.Profile.Name != null
                GROUP BY Salesperson__r.Profile.Name
                ORDER BY Salesperson__r.Profile.Name
            ]) {
                String pn = (String) ar.get('profileName');
                opts.add(new Map<String, String>{ 'label' => pn, 'value' => pn });
            }
        } else if (filterType == 'territory') {
            for (Territory_Master__c tm : [
                SELECT Id, Name FROM Territory_Master__c WHERE Is_Active__c = true ORDER BY Name
            ]) {
                opts.add(new Map<String, String>{ 'label' => tm.Name, 'value' => tm.Id });
            }
        }

        return opts;
    }
}