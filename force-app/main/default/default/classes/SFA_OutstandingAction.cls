/**
 * @description Agentforce action: report an outlet's outstanding receivables.
 *              Thin shell over SFA_AgentActions.buildOutstanding.
 */
public with sharing class SFA_OutstandingAction {

    @InvocableMethod(label='Get Outlet Outstanding'
        description='Reports outstanding receivables for an outlet: total due, an aging breakdown, and the open invoices ordered by due date. Read-only.'
        category='SFA Field Copilot')
    public static List<SFA_AgentActions.OutstandingSummary> run(List<SFA_AgentActions.OutletRequest> requests) {
        List<SFA_AgentActions.OutstandingSummary> out = new List<SFA_AgentActions.OutstandingSummary>();
        if (requests == null) return out;
        for (SFA_AgentActions.OutletRequest req : requests) {
            out.add(SFA_AgentActions.buildOutstanding(req == null ? null : req.accountId));
        }
        return out;
    }
}