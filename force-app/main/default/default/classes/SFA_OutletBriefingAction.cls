/**
 * @description Agentforce action: brief the rep on an outlet. One @InvocableMethod
 *              per class (Salesforce constraint), so this is a thin shell over
 *              SFA_AgentActions.buildBriefing.
 */
public with sharing class SFA_OutletBriefingAction {

    @InvocableMethod(label='Get Outlet Briefing'
        description='Summarises an outlet: type and channel, credit limit, outstanding balance and aging, last visit date, and the last order placed. Read-only.'
        category='SFA Field Copilot')
    public static List<SFA_AgentActions.OutletBriefing> run(List<SFA_AgentActions.OutletRequest> requests) {
        List<SFA_AgentActions.OutletBriefing> out = new List<SFA_AgentActions.OutletBriefing>();
        if (requests == null) return out;
        for (SFA_AgentActions.OutletRequest req : requests) {
            out.add(SFA_AgentActions.buildBriefing(req == null ? null : req.accountId));
        }
        return out;
    }
}