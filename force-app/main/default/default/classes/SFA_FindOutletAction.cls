/**
 * @description Agentforce action: resolve an outlet by name to its Account Id.
 *
 * The other SFA Copilot actions take an accountId, but a rep speaks in names
 * ("brief me on City Supermarket"). This action bridges that gap: the agent
 * calls Find Outlet first, then passes the returned accountId into Get Outlet
 * Briefing / What To Sell / Outstanding.
 *
 * Read-only and `with sharing`, so a rep only ever finds outlets they can see.
 */
public with sharing class SFA_FindOutletAction {

    public class FindRequest {
        @InvocableVariable(required=true label='Outlet Name'
            description='Full or partial outlet / store name to search for.')
        public String searchText;
    }

    public class FindResult {
        @InvocableVariable(label='Match Count' description='How many outlets matched.')
        public Integer matchCount;
        @InvocableVariable(label='Account Id'
            description='Id of the best (first) matching outlet. Pass this to the other outlet actions.')
        public Id accountId;
        @InvocableVariable(label='Outlet Name' description='Name of the best matching outlet.')
        public String outletName;
        @InvocableVariable(label='Matches'
            description='All matching outlets as readable text (one per line), for when more than one matched and the rep must choose.')
        public String matches;
        @InvocableVariable(label='Summary'
            description='A ready-to-read result. Prefer this for the reply.')
        public String summary;
    }

    @InvocableMethod(label='Find Outlet'
        description='Finds outlets by name and returns the matching Account so the outlet actions can be called with its Id. Read-only.'
        category='SFA Field Copilot')
    public static List<FindResult> run(List<FindRequest> requests) {
        List<FindResult> out = new List<FindResult>();
        if (requests == null) return out;
        for (FindRequest req : requests) {
            out.add(find(req == null ? null : req.searchText));
        }
        return out;
    }

    private static FindResult find(String searchText) {
        FindResult r = new FindResult();
        r.matches = '';
        r.matchCount = 0;

        if (String.isBlank(searchText)) {
            r.summary = 'Tell me the outlet name to search for.';
            return r;
        }

        String term = '%' + String.escapeSingleQuotes(searchText.trim()) + '%';
        List<Account> accts = [
            SELECT Id, Name, Outlet_Type__c
            FROM Account
            WHERE Name LIKE :term
            WITH SECURITY_ENFORCED
            ORDER BY Name
            LIMIT 10
        ];

        r.matchCount = accts.size();
        if (accts.isEmpty()) {
            r.summary = 'No outlet found matching "' + searchText + '".';
            return r;
        }

        r.accountId = accts[0].Id;
        r.outletName = accts[0].Name;
        List<String> lines = new List<String>();
        for (Account a : accts) {
            lines.add(a.Name
                + (String.isBlank(a.Outlet_Type__c) ? '' : ' — ' + a.Outlet_Type__c));
        }
        r.matches = String.join(lines, '\n');

        r.summary = (r.matchCount == 1)
            ? 'Found ' + r.outletName + '.'
            : 'Found ' + r.matchCount + ' outlets: ' + String.join(lines, '; ')
                + '. Which one did you mean?';
        return r;
    }
}