/**
 * @description Agentforce action: preview an order for an outlet without
 *              creating it. Thin shell over SFA_OrderSupport.buildDraft.
 */
public with sharing class SFA_OrderDraftAction {

    @InvocableMethod(label='Draft Order'
        description='Prices a proposed order for an outlet without creating anything: resolves each product, estimates the value, and checks credit and must-sell compliance. Returns the draft for the rep to review. Read-only.'
        category='SFA Field Copilot')
    public static List<SFA_OrderSupport.DraftResult> run(List<SFA_OrderSupport.DraftRequest> requests) {
        List<SFA_OrderSupport.DraftResult> out = new List<SFA_OrderSupport.DraftResult>();
        if (requests == null) return out;
        for (SFA_OrderSupport.DraftRequest req : requests) {
            out.add(req == null
                ? new SFA_OrderSupport.DraftResult()
                : SFA_OrderSupport.buildDraft(req.accountId, req.items));
        }
        return out;
    }
}