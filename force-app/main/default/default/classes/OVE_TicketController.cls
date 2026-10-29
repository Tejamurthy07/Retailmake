/**
 * @description Controller for the Ticket / Complaint LWC components.
 *              Thin @AuraEnabled wrapper that delegates all business logic
 *              to OVE_Ticket_Service.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class OVE_TicketController {

    /**
     * @description Gets all tickets for a visit.
     * @param visitId The Visit__c Id.
     * @return List of Ticket__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Ticket__c> getTicketsForVisit(Id visitId) {
        try {
            return OVE_Ticket_Service.getTicketsForVisit(visitId);
        
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Creates a new ticket for a visit.
     * @param ticketJson JSON string with ticket data.
     * @return The created Ticket__c record.
     */
    @AuraEnabled
    public static Ticket__c createTicket(String ticketJson) {
        try {
            return OVE_Ticket_Service.createTicket(ticketJson);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}