/**
 * @description Shared logic and request/response types for the SFA (field
 *              sales) "Field Rep Copilot" Agentforce actions.
 *
 * Agentforce invokes Apex through @InvocableMethod, and Salesforce allows only
 * ONE @InvocableMethod per class — so each action lives in its own thin class
 * (SFA_OutletBriefingAction, SFA_WhatToSellAction, SFA_OutstandingAction) that
 * delegates to the build* methods here. The existing SFA business logic is
 * exposed to LWCs as @AuraEnabled methods; nothing is duplicated — each build*
 * method just delegates to those and reshapes the result into flat, primitive
 * fields an LLM can narrate reliably.
 *
 * Design choices that matter for an agent:
 *  - Every response carries a ready-made `summary` string. The model can read
 *    that verbatim, which keeps it from inventing numbers the action didn't
 *    return — the single biggest grounding risk.
 *  - Record access is enforced HERE, with sharing, even though the delegated
 *    services (OVE_Visit_Service, OrderEntryController) run `without sharing`.
 *    An account the running rep cannot see returns an explicit "no access"
 *    result rather than leaking another rep's outlet.
 *
 * Pilot scope: three read-only actions for the "Outlet Insights" topic. Write
 * actions (draft an order, log a collection) are a deliberate later phase.
 */
public with sharing class SFA_AgentActions {

    // ─────────────────────────────────────────────────────────────────────
    // 1. Outlet briefing — "brief me on this store"
    // ─────────────────────────────────────────────────────────────────────

    public class OutletRequest {
        @InvocableVariable(required=true label='Account Id'
            description='The outlet / store Account to report on.')
        public Id accountId;
    }

    public class OutletBriefing {
        @InvocableVariable(label='Outlet Name' description='The outlet name.')
        public String outletName;
        @InvocableVariable(label='Outlet Type' description='The outlet type, e.g. Retailer or General Store.')
        public String outletType;
        @InvocableVariable(label='Channel' description='The sales channel the outlet belongs to.')
        public String channel;
        @InvocableVariable(label='City' description='The outlet city.')
        public String city;
        @InvocableVariable(label='Credit Limit' description='The outlet credit limit, in rupees.')
        public Decimal creditLimit;
        @InvocableVariable(label='Outstanding Balance' description='Total amount the outlet currently owes, in rupees.')
        public Decimal outstandingBalance;
        @InvocableVariable(label='Last Visit Date' description='The date the outlet was last visited.')
        public String lastVisitDate;
        @InvocableVariable(label='Pending Orders' description='Number of pending, unfulfilled orders for the outlet.')
        public Decimal pendingOrders;
        @InvocableVariable(label='Last Order Summary' description='One sentence describing the most recent order: date, amount and status.')
        public String lastOrderSummary;
        @InvocableVariable(label='Aging Summary' description='Outstanding balance split by age bucket: current, 31-60, 61-90 and 90+ days.')
        public String agingSummary;
        @InvocableVariable(label='Has Access' description='True if the running user can see this outlet. False means it was not found or access is denied.')
        public Boolean hasAccess;
        @InvocableVariable(label='Summary' description='A ready-to-read one-paragraph outlet summary. Prefer this for the reply.')
        public String summary;
    }

    public static OutletBriefing buildBriefing(Id accountId) {
        OutletBriefing b = new OutletBriefing();

        Account acct = visibleAccount(accountId);
        if (acct == null) {
            b.hasAccess = false;
            b.summary = 'That outlet was not found, or you do not have access to it.';
            return b;
        }
        b.hasAccess = true;
        b.outletName = acct.Name;

        Map<String, Object> s = OVE_Visit_Service.getOutletSummary(accountId);
        b.outletType = str(s.get('outletType'));
        b.channel = str(s.get('channel'));
        b.city = str(s.get('city'));
        b.creditLimit = dec(s.get('creditLimit'));
        b.outstandingBalance = dec(s.get('outstandingBalance'));
        b.lastVisitDate = str(s.get('lastVisitDate'));
        b.pendingOrders = dec(s.get('pendingOrders'));

        Sales_Order__c last = OrderEntryController.getLastOrder(accountId);
        if (last != null) {
            Decimal amt = last.Total_Net_Amount__c != null ? last.Total_Net_Amount__c : last.Net_Amount__c;
            b.lastOrderSummary = 'Last order ' + (last.Order_Date__c == null ? '' : last.Order_Date__c.format())
                + ' for ' + inr(amt) + ' (' + str(last.Status__c) + ')';
        } else {
            b.lastOrderSummary = 'No previous orders on record.';
        }

        Map<String, Decimal> aging = CollectionController.getAgingSummary(accountId);
        b.agingSummary = formatAging(aging);

        b.summary = b.outletName
            + (String.isBlank(b.outletType) ? '' : ' (' + b.outletType + ')')
            + '. Credit limit ' + inr(b.creditLimit)
            + ', outstanding ' + inr(b.outstandingBalance) + '. '
            + (b.pendingOrders != null && b.pendingOrders > 0
                ? b.pendingOrders.setScale(0) + ' pending order(s). ' : '')
            + b.lastOrderSummary + '. '
            + 'Aging: ' + b.agingSummary + '.'
            + (String.isBlank(b.lastVisitDate) ? '' : ' Last visited ' + b.lastVisitDate + '.');
        return b;
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. What to sell — "what should I push here?"
    // ─────────────────────────────────────────────────────────────────────

    public class SellSuggestions {
        @InvocableVariable(label='Must-Sell Products' description='Products the outlet should stock but is missing, with minimum quantities. One per line.')
        public String mustSellProducts;
        @InvocableVariable(label='Active Schemes' description='Currently active promotional schemes the outlet can use. One per line.')
        public String activeSchemes;
        @InvocableVariable(label='Top Products' description='The products this outlet buys most often. One per line.')
        public String topProducts;
        @InvocableVariable(label='Has Access' description='True if the running user can see this outlet. False means not found or access denied.')
        public Boolean hasAccess;
        @InvocableVariable(label='Summary' description='A ready-to-read recommendation of what to sell here. Prefer this for the reply.')
        public String summary;
    }

    public static SellSuggestions buildSuggestions(Id accountId) {
        SellSuggestions s = new SellSuggestions();
        s.mustSellProducts = '';
        s.activeSchemes = '';
        s.topProducts = '';

        Account acct = visibleAccount(accountId);
        if (acct == null) {
            s.hasAccess = false;
            s.summary = 'That outlet was not found, or you do not have access to it.';
            return s;
        }
        s.hasAccess = true;

        List<String> mustSell = new List<String>();
        for (Map<String, Object> m : OrderEntryController.getMustSellProducts(accountId, Date.today())) {
            String nm = str(m.get('productName'));
            if (String.isNotBlank(nm)) {
                Object minQ = m.get('minQuantity');
                mustSell.add(nm + (minQ == null ? '' : ' (min ' + minQ + ')'));
            }
        }

        List<String> schemes = new List<String>();
        for (Scheme__c sc : OrderEntryController.getApplicableSchemes(accountId, Date.today())) {
            schemes.add(sc.Name
                + (String.isBlank(sc.Scheme_Type__c) ? '' : ' — ' + sc.Scheme_Type__c));
        }

        List<String> top = new List<String>();
        for (OrderEntryController.ProductSearchResult p : OrderEntryController.getTopSellingProducts(accountId)) {
            if (top.size() >= 5) break;
            top.add(p.Name);
        }

        s.mustSellProducts = String.join(mustSell, '\n');
        s.activeSchemes = String.join(schemes, '\n');
        s.topProducts = String.join(top, '\n');

        List<String> parts = new List<String>();
        if (!mustSell.isEmpty()) { parts.add('Must-sell to push: ' + String.join(mustSell, ', ')); }
        if (!schemes.isEmpty())  { parts.add('Live schemes: ' + String.join(schemes, '; ')); }
        if (!top.isEmpty())      { parts.add('Usually buys: ' + String.join(top, ', ')); }
        s.summary = parts.isEmpty()
            ? 'No must-sell gaps, active schemes or order history to suggest from for this outlet.'
            : String.join(parts, '. ') + '.';
        return s;
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Outstanding — "what does this outlet owe?"
    // ─────────────────────────────────────────────────────────────────────

    public class OutstandingSummary {
        @InvocableVariable(label='Total Outstanding' description='Total outstanding amount for the outlet, in rupees.')
        public Decimal totalOutstanding;
        @InvocableVariable(label='Aging Breakdown' description='Outstanding balance split by age bucket: current, 31-60, 61-90 and 90+ days.')
        public String agingBreakdown;
        @InvocableVariable(label='Open Invoices' description='Open invoices, each with amount due and due date, oldest first. One per line.')
        public String openInvoices;
        @InvocableVariable(label='Has Access' description='True if the running user can see this outlet. False means not found or access denied.')
        public Boolean hasAccess;
        @InvocableVariable(label='Summary' description='A ready-to-read summary of outstanding receivables. Prefer this for the reply.')
        public String summary;
    }

    public static OutstandingSummary buildOutstanding(Id accountId) {
        OutstandingSummary o = new OutstandingSummary();
        o.openInvoices = '';

        Account acct = visibleAccount(accountId);
        if (acct == null) {
            o.hasAccess = false;
            o.summary = 'That outlet was not found, or you do not have access to it.';
            return o;
        }
        o.hasAccess = true;

        Map<String, Decimal> aging = CollectionController.getAgingSummary(accountId);
        o.totalOutstanding = aging != null && aging.containsKey('total') ? aging.get('total') : 0;
        o.agingBreakdown = formatAging(aging);

        List<String> invoices = new List<String>();
        for (Invoice__c inv : CollectionController.getOutstandingInvoices(accountId)) {
            if (invoices.size() >= 10) break;
            invoices.add(inv.Name + ': ' + inr(inv.Balance_Due__c) + ' due'
                + (inv.Due_Date__c == null ? '' : ' by ' + inv.Due_Date__c.format()));
        }
        o.openInvoices = String.join(invoices, '\n');

        o.summary = invoices.isEmpty()
            ? 'This outlet has no outstanding balance.'
            : 'Total outstanding ' + inr(o.totalOutstanding) + ' across ' + invoices.size()
                + ' open invoice(s). Aging: ' + o.agingBreakdown + '.';
        return o;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Shared helpers
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Enforces record access at the wrapper boundary. This class is `with
     * sharing`, so a rep who cannot see the account gets no row back and the
     * action returns an explicit "no access" result — the delegated services
     * are `without sharing` and would otherwise happily return it.
     */
    private static Account visibleAccount(Id accountId) {
        if (accountId == null) return null;
        List<Account> accts = [
            SELECT Id, Name FROM Account WHERE Id = :accountId WITH SECURITY_ENFORCED LIMIT 1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    private static String formatAging(Map<String, Decimal> aging) {
        if (aging == null) return 'unavailable';
        return 'current ' + inr(aging.get('current'))
            + ', 31–60d ' + inr(aging.get('days31_60'))
            + ', 61–90d ' + inr(aging.get('days61_90'))
            + ', 90d+ ' + inr(aging.get('days90Plus'));
    }

    private static String inr(Object amount) {
        Decimal d = dec(amount);
        return '₹' + (d == null ? '0' : d.setScale(2).format());
    }

    private static String str(Object o) {
        return o == null ? '' : String.valueOf(o);
    }

    private static Decimal dec(Object o) {
        if (o == null) return null;
        if (o instanceof Decimal) return (Decimal) o;
        try { return Decimal.valueOf(String.valueOf(o)); } catch (Exception e) { return null; }
    }
}