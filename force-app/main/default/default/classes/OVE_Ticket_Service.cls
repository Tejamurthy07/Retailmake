/**
 * @description Service class for Ticket / Complaint management during outlet visits.
 *              Handles creation and retrieval of tickets raised during visits.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class OVE_Ticket_Service {

    // ── Feature Codes ───────────────────────────────────────────────────────
    public static final String FEATURE_TICKET = 'OVE-012';

    // ── Inner DTO Classes ───────────────────────────────────────────────────

    /**
     * @description Input DTO for ticket creation.
     */
    public class TicketInput {
        public Id     visitId;
        public Id     accountId;
        public String category;
        public String priority;
        public String subject;
        public String description;
        public String photoURL;
    }

    // ── Query Methods ───────────────────────────────────────────────────────

    /**
     * @description Gets all tickets associated with a visit.
     * @param visitId The Visit__c Id.
     * @return List of Ticket__c records for the visit.
     */
    public static List<Ticket__c> getTicketsForVisit(Id visitId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_TICKET)) {
            throw new AuraHandledException('Ticket feature is currently disabled.');
        }

        return [
            SELECT Id, Name, Visit__c, Account__c, Reported_By__c,
                   Ticket_Date__c, Category__c, Priority__c,
                   Subject__c, Description__c, Photo_URL__c, Status__c,
                   CreatedDate
            FROM Ticket__c
            WHERE Visit__c = :visitId
            ORDER BY CreatedDate DESC
        ];
    }

    // ── Ticket Creation ─────────────────────────────────────────────────────

    /**
     * @description Creates a new ticket and marks the visit's Ticket_Logged__c flag.
     * @param ticketJson JSON string matching TicketInput structure.
     * @return The created Ticket__c record.
     */
    public static Ticket__c createTicket(String ticketJson) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_TICKET)) {
            throw new AuraHandledException('Ticket feature is currently disabled.');
        }

        TicketInput input = (TicketInput)
            JSON.deserialize(ticketJson, TicketInput.class);

        if (input.visitId == null) {
            throw new AuraHandledException('Visit Id is required to create a ticket.');
        }
        if (String.isBlank(input.subject)) {
            throw new AuraHandledException('Ticket subject is required.');
        }

        Savepoint sp = Database.setSavepoint();
        try {
            Ticket__c ticket = new Ticket__c();
            ticket.Visit__c        = input.visitId;
            ticket.Account__c      = input.accountId;
            ticket.Reported_By__c  = UserInfo.getUserId();
            ticket.Ticket_Date__c  = Date.today();
            ticket.Category__c     = input.category;
            ticket.Priority__c     = input.priority;
            ticket.Subject__c      = input.subject;
            ticket.Description__c  = input.description;
            ticket.Photo_URL__c    = input.photoURL;
            ticket.Status__c       = 'Open';
            insert ticket;

            // Mark visit as having a ticket logged
            Visit__c visit = new Visit__c(Id = input.visitId);
            visit.Ticket_Logged__c = true;
            update visit;

            return ticket;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Failed to create ticket: ' + e.getMessage());
        }
    }
}