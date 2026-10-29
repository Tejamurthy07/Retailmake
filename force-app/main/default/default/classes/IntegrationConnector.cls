/**
 * @description Contract every integration connector implements. The stub ships now; a real
 *              connector (live callouts + a genuine connection test) is dropped in per provider
 *              in Phase 2 and wired via Integration_Definition__mdt.Connector_Class__c — the
 *              window and controller never change.
 */
public interface IntegrationConnector {
    IntegrationTypes.ConnectionResult testConnection(IntegrationTypes.Context ctx);
}