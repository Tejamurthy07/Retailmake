/**
 * @description Agentforce action: place an outlet's order from a confirmed
 *              draft. Thin shell over SFA_OrderSupport.placeOrder — the WRITE
 *              action, which refuses unless confirmed is true.
 */
public with sharing class SFA_OrderPlaceAction {

    @InvocableMethod(label='Place Order'
        description='Creates the sales order for an outlet from a confirmed draft. WRITE action — only call after the rep has seen the draft from Draft Order and explicitly said yes. Refuses unless confirmed is true.'
        category='SFA Field Copilot')
    public static List<SFA_OrderSupport.PlaceResult> run(List<SFA_OrderSupport.PlaceRequest> requests) {
        List<SFA_OrderSupport.PlaceResult> out = new List<SFA_OrderSupport.PlaceResult>();
        if (requests == null) return out;
        for (SFA_OrderSupport.PlaceRequest req : requests) {
            out.add(req == null
                ? new SFA_OrderSupport.PlaceResult()
                : SFA_OrderSupport.placeOrder(req.accountId, req.items, req.confirmed));
        }
        return out;
    }
}