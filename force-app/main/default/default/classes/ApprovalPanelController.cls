/**
 * @description Backs the approvalPanel record-page LWC and the myApprovals
 * inbox LWC. Thin wrapper around ApprovalRouter — keeps the engine
 * decoupled from the UI.
 */
public with sharing class ApprovalPanelController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getRecordApprovalState(Id recordId) {
        Map<String, Object> result = new Map<String, Object>();
        if (recordId == null) {
            result.put('hasRequest', false);
            result.put('canSubmit', false);
            return result;
        }

        String objType = recordId.getSObjectType().getDescribe().getName();
        Integer activeRules = [
            SELECT COUNT() FROM Approval_Rule__c
            WHERE Object_Process__c = :objType AND Is_Active__c = true
        ];

        List<Approval_Request__c> reqs = [
            SELECT Id, Name, Status__c, Object_Type__c, Record_Id__c, Record_Name__c,
                   Current_Level__c, Total_Levels__c,
                   Current_Approver__c, Current_Approver__r.Name,
                   Submitted_By__c, Submitted_By__r.Name,
                   Submitted_Date__c, Completed_Date__c, Comments__c
            FROM Approval_Request__c
            WHERE Record_Id__c = :String.valueOf(recordId)
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (reqs.isEmpty()) {
            result.put('hasRequest', false);
            result.put('canSubmit', activeRules > 0);
            result.put('rulesAvailable', activeRules);
            return result;
        }

        Approval_Request__c req = reqs[0];
        result.put('hasRequest', true);
        // Return a plain map with UNqualified keys. In the managed-package
        // (ftretailmake) namespace a raw SObject serializes its fields with the
        // namespace prefix (ftretailmake__Total_Levels__c, ftretailmake__Approver__r),
        // so the LWC's unqualified reads would come back undefined.
        result.put('request', new Map<String, Object>{
            'Id' => req.Id,
            'Name' => req.Name,
            'Status__c' => req.Status__c,
            'Object_Type__c' => req.Object_Type__c,
            'Record_Id__c' => req.Record_Id__c,
            'Record_Name__c' => req.Record_Name__c,
            'Current_Level__c' => req.Current_Level__c,
            'Total_Levels__c' => req.Total_Levels__c,
            'Submitted_Date__c' => req.Submitted_Date__c,
            'Completed_Date__c' => req.Completed_Date__c,
            'Comments__c' => req.Comments__c,
            'Submitted_By__r' => (req.Submitted_By__c == null ? null
                : new Map<String, Object>{ 'Name' => req.Submitted_By__r.Name }),
            'Current_Approver__r' => (req.Current_Approver__c == null ? null
                : new Map<String, Object>{ 'Name' => req.Current_Approver__r.Name })
        });
        result.put('canRecall',
            req.Status__c == 'Pending' && req.Submitted_By__c == UserInfo.getUserId());
        result.put('canSubmitAgain',
            (req.Status__c == 'Rejected' || req.Status__c == 'Recalled') && activeRules > 0);

        List<Approval_Step__c> steps = [
            SELECT Id, Level__c, Status__c, Is_Current__c,
                   Approver__c, Approver__r.Name, Approver_Type__c, Approver_Reference__c,
                   Auto_Approve__c, Decision_Date__c, Comments__c
            FROM Approval_Step__c
            WHERE Approval_Request__c = :req.Id
            ORDER BY Level__c
        ];
        // Plain maps with unqualified keys (see note above) so the LWC reads
        // Approver__r.Name, Status__c, Level__c, etc. regardless of namespace.
        List<Map<String, Object>> stepMaps = new List<Map<String, Object>>();
        for (Approval_Step__c s : steps) {
            stepMaps.add(new Map<String, Object>{
                'Id' => s.Id,
                'Level__c' => s.Level__c,
                'Status__c' => s.Status__c,
                'Is_Current__c' => s.Is_Current__c,
                'Approver_Type__c' => s.Approver_Type__c,
                'Approver_Reference__c' => s.Approver_Reference__c,
                'Auto_Approve__c' => s.Auto_Approve__c,
                'Decision_Date__c' => s.Decision_Date__c,
                'Comments__c' => s.Comments__c,
                'Approver__r' => (s.Approver__c == null ? null
                    : new Map<String, Object>{ 'Name' => s.Approver__r.Name })
            });
        }
        result.put('steps', stepMaps);

        Boolean canAct = false;
        Id currentStepId = null;
        for (Approval_Step__c s : steps) {
            if (s.Is_Current__c && s.Approver__c == UserInfo.getUserId()) {
                canAct = true;
                currentStepId = s.Id;
                break;
            }
        }
        result.put('canAct', canAct);
        result.put('currentStepId', currentStepId);
        result.put('currentUserId', UserInfo.getUserId());

        return result;
    }

    @AuraEnabled
    public static Id submitRecord(Id recordId, String comments) {
        return ApprovalRouter.submit(recordId, comments);
    }

    @AuraEnabled
    public static void approveStep(Id stepId, String comments) {
        ApprovalRouter.approve(stepId, comments);
    }

    @AuraEnabled
    public static void rejectStep(Id stepId, String comments) {
        ApprovalRouter.reject(stepId, comments);
    }

    @AuraEnabled
    public static void recallRequest(Id requestId) {
        ApprovalRouter.recall(requestId);
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getMyPendingApprovals() {
        List<Approval_Step__c> steps = [
            SELECT Id, Level__c,
                   Approval_Request__c, Approval_Request__r.Name,
                   Approval_Request__r.Object_Type__c,
                   Approval_Request__r.Record_Id__c,
                   Approval_Request__r.Record_Name__c,
                   Approval_Request__r.Submitted_By__r.Name,
                   Approval_Request__r.Submitted_Date__c,
                   Approval_Request__r.Total_Levels__c
            FROM Approval_Step__c
            WHERE Approver__c = :UserInfo.getUserId()
              AND Status__c = 'Pending'
              AND Is_Current__c = true
              AND Approval_Request__r.Status__c = 'Pending'
            ORDER BY Approval_Request__r.Submitted_Date__c DESC
            LIMIT 200
        ];
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Approval_Step__c s : steps) {
            out.add(new Map<String, Object>{
                'stepId' => s.Id,
                'requestId' => s.Approval_Request__c,
                'requestName' => s.Approval_Request__r.Name,
                'objectType' => s.Approval_Request__r.Object_Type__c,
                'recordId' => s.Approval_Request__r.Record_Id__c,
                'recordName' => s.Approval_Request__r.Record_Name__c,
                'submittedBy' => s.Approval_Request__r.Submitted_By__r != null
                    ? s.Approval_Request__r.Submitted_By__r.Name : '',
                'submittedDate' => s.Approval_Request__r.Submitted_Date__c,
                'level' => s.Level__c,
                'totalLevels' => s.Approval_Request__r.Total_Levels__c
            });
        }
        return out;
    }
}