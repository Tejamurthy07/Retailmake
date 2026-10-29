/**
 * @description Controller for the Expense Manager LWC components.
 *              Thin @AuraEnabled wrapper that delegates all business logic
 *              to EXP_Expense_Service. Includes single bulk API pattern
 *              for optimal data loading.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class ExpenseController {

    // ═══════════════════════════════════════════════════════════════════════
    // SINGLE BULK API — One call returns everything the LWC needs
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Map<String, Object> getExpenseData(String month, Integer year) {
        try {
            return EXP_Expense_Service.getExpenseData(UserInfo.getUserId(), month, year);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REPORT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Expense__c getOrCreateReport(String month, Integer year) {
        try {
            return EXP_Expense_Service.getOrCreateReport(UserInfo.getUserId(), month, year);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getEligibleDates(String month, Integer year) {
        try {
            return EXP_Expense_Service.getEligibleDates(UserInfo.getUserId(), month, year);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Expense_Eligibility__c> getEligibilityRules() {
        try {
            String band = EXP_Expense_Service.getEmployeeBand(UserInfo.getUserId());
            if (String.isBlank(band)) {
                throw new AuraHandledException('No band configured for current employee.');
            }
            return EXP_Expense_Service.getEligibilityRules(band);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXPENSE ITEM CRUD
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static List<Expense_Item__c> getExpenseItemsForDate(Id expenseId, Date expenseDate) {
        try {
            return EXP_Expense_Service.getExpenseItemsForDate(expenseId, expenseDate);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Expense_Item__c> getAllExpenseItemsForReport(Id expenseId) {
        try {
            return EXP_Expense_Service.getAllExpenseItemsForReport(expenseId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Expense_Item__c> saveExpenseItems(Id expenseId, String itemsJson) {
        try {
            List<Expense_Item__c> items = (List<Expense_Item__c>)
                JSON.deserialize(itemsJson, List<Expense_Item__c>.class);
            return EXP_Expense_Service.saveExpenseItems(expenseId, items);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteExpenseItems(List<Id> itemIds) {
        try {
            EXP_Expense_Service.deleteExpenseItems(itemIds);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // APPROVAL WORKFLOW
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Expense__c submitReport(Id expenseId) {
        try {
            return EXP_Expense_Service.submitReport(expenseId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Expense__c approveReport(Id expenseId, String remarks, String level) {
        try {
            return EXP_Expense_Service.approveReport(expenseId, remarks, level);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Expense__c rejectReport(Id expenseId, String reason, String level) {
        try {
            return EXP_Expense_Service.rejectReport(expenseId, reason, level);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> approveExpenseItems(List<Id> itemIds, String remarks, String level) {
        try {
            return EXP_Expense_Service.approveExpenseItems(itemIds, remarks, level);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> rejectExpenseItems(List<Id> itemIds, String reason, String level) {
        try {
            return EXP_Expense_Service.rejectExpenseItems(itemIds, reason, level);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> updateApprovedAmounts(String itemAmountsJson) {
        try {
            Map<Id, Decimal> itemAmounts = new Map<Id, Decimal>();
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(itemAmountsJson);
            for (String key : parsed.keySet()) {
                itemAmounts.put(Id.valueOf(key), (Decimal) parsed.get(key));
            }
            return EXP_Expense_Service.updateApprovedAmounts(itemAmounts);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Expense__c markAsPaid(Id expenseId) {
        try {
            return EXP_Expense_Service.markAsPaid(expenseId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REPORTING
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getReportSummary(Id expenseId) {
        try {
            return EXP_Expense_Service.getReportSummary(expenseId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getMonthlyOverview(Integer year) {
        try {
            return EXP_Expense_Service.getMonthlyOverview(UserInfo.getUserId(), year);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getExpenseConfig() {
        try {
            Map<String, Object> config = new Map<String, Object>();
            config.put('expenseEnabled', BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_EXPENSE));
            config.put('autoCalcEnabled', BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_AUTO_CALC));
            config.put('financeApprovalEnabled', BPM_FeatureToggle_Util.isEnabled(EXP_Expense_Service.FEATURE_FINANCE_APPROVAL));
            config.put('maxOverridePercent', EXP_Expense_Service.getConfigInteger('MAX_OVERRIDE_PERCENT', 150));
            config.put('reportLockDay', EXP_Expense_Service.getConfigInteger('REPORT_LOCK_DAY', 5));
            config.put('allowFutureDates', EXP_Expense_Service.getConfigBoolean('ALLOW_FUTURE_DATES', false));
            config.put('backDateLimitDays', EXP_Expense_Service.getConfigInteger('BACK_DATE_LIMIT_DAYS', 60));
            return config;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Expense__c> getTeamExpenseReports(String month, Integer year) {
        try {
            return EXP_Expense_Service.getTeamExpenseReports(UserInfo.getUserId(), month, year);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // APPROVAL DATA
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Map<String, Object> getExpenseForApproval(Id expenseId) {
        try {
            return EXP_Expense_Service.getExpenseForApproval(expenseId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SUBMIT SUMMARY
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Map<String, Object> getSubmitSummary(Id expenseId) {
        try {
            return EXP_Expense_Service.getSubmitSummary(expenseId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // FILES
    // ═══════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static List<Map<String, Object>> getExpenseItemFiles(List<Id> itemIds) {
        try {
            return EXP_Expense_Service.getExpenseItemFiles(itemIds);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> uploadReceiptBase64(Id expenseItemId, String fileName, String base64Data) {
        try {
            return EXP_Expense_Service.uploadReceiptBase64(expenseItemId, fileName, base64Data);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteExpenseItemFile(Id contentDocumentId) {
        try {
            EXP_Expense_Service.deleteExpenseItemFile(contentDocumentId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}