/**
 * @description Agentforce action: recommend what to sell at an outlet. Thin
 *              shell over SFA_AgentActions.buildSuggestions.
 */
public with sharing class SFA_WhatToSellAction {

    @InvocableMethod(label='Get What To Sell'
        description='Recommends what to sell at an outlet: must-sell products the outlet is missing, currently active schemes, and top-selling products for the outlet. Read-only.'
        category='SFA Field Copilot')
    public static List<SFA_AgentActions.SellSuggestions> run(List<SFA_AgentActions.OutletRequest> requests) {
        List<SFA_AgentActions.SellSuggestions> out = new List<SFA_AgentActions.SellSuggestions>();
        if (requests == null) return out;
        for (SFA_AgentActions.OutletRequest req : requests) {
            out.add(SFA_AgentActions.buildSuggestions(req == null ? null : req.accountId));
        }
        return out;
    }
}