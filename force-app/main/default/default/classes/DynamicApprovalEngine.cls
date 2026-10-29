/**
 * @description DEPRECATED — retained only as a compatibility shim.
 *
 * This class used to be a second, parallel approval engine alongside
 * ApprovalRouter. Two engines reading the same Approval_Rule__c rows with
 * subtly different semantics (band matching, approver resolution, notification
 * routing) is a correctness hazard: which one ran decided the outcome.
 *
 * ApprovalRouter is now the single engine. Every method here forwards to it so
 * that any Flow, process, or org-side customisation still bound to
 * DynamicApprovalEngine keeps working unchanged.
 *
 * New code should call ApprovalRouter directly.
 */
public with sharing class DynamicApprovalEngine {

    public class ApprovalException extends Exception {}

    // ============================================================== Submit

    public class SubmitRequest {
        @InvocableVariable(required=true label='Record Id') public Id recordId;
    }

    @InvocableMethod(label='Submit For Dynamic Approval (Deprecated)'
        description='Deprecated. Use "Submit For Approval". Forwards to ApprovalRouter.')
    public static void submitForApprovalFlow(List<SubmitRequest> requests) {
        if (requests == null) return;
        List<ApprovalRouter.SubmitRequest> forwarded = new List<ApprovalRouter.SubmitRequest>();
        for (SubmitRequest r : requests) {
            if (r.recordId == null) continue;
            ApprovalRouter.SubmitRequest sr = new ApprovalRouter.SubmitRequest();
            sr.recordId = r.recordId;
            forwarded.add(sr);
        }
        if (!forwarded.isEmpty()) ApprovalRouter.submitForApprovalFlow(forwarded);
    }

    @AuraEnabled
    public static Id submitForApproval(Id recordId) {
        return ApprovalRouter.submit(recordId, null);
    }

    /**
     * @description The submittedBy argument is no longer honoured — the
     *              submitter is always the running user, which is what the
     *              audit trail on Approval_Request__c has to reflect anyway.
     */
    public static Id submit(Id recordId, Id submittedBy) {
        return ApprovalRouter.submit(recordId, null);
    }

    // ============================================================== Decisions

    @AuraEnabled
    public static void approve(Id stepId, String comments) {
        ApprovalRouter.approve(stepId, comments);
    }

    @AuraEnabled
    public static void reject(Id stepId, String comments) {
        ApprovalRouter.reject(stepId, comments);
    }

    @AuraEnabled
    public static void recall(Id requestId) {
        ApprovalRouter.recall(requestId);
    }

    // ============================================================== My Approvals

    @AuraEnabled(cacheable=true)
    public static List<Approval_Step__c> getMyApprovals() {
        return ApprovalRouter.getMyApprovals();
    }
}