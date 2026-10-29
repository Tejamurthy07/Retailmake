/**
 * @description Trigger handler for Scheme_Mapping__c. Validates territory
 *              references and prevents duplicate mappings per scheme.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public class SPM_SchemeMapping_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        List<Scheme_Mapping__c> newRecords = (List<Scheme_Mapping__c>) Trigger.new;
        checkDuplicateMappings(newRecords);
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private void checkDuplicateMappings(List<Scheme_Mapping__c> records) {
        Set<Id> schemeIds = new Set<Id>();
        for (Scheme_Mapping__c rec : records) {
            if (rec.Scheme__c != null) schemeIds.add(rec.Scheme__c);
        }

        if (schemeIds.isEmpty()) return;

        Set<String> existingKeys = new Set<String>();
        for (Scheme_Mapping__c existing : [
            SELECT Id, Scheme__c, Territory__c, Account__c, Customer_Type__c
            FROM Scheme_Mapping__c
            WHERE Scheme__c IN :schemeIds
        ]) {
            String key = existing.Scheme__c + '|' + existing.Territory__c + '|' +
                         existing.Account__c + '|' + existing.Customer_Type__c;
            existingKeys.add(key);
        }

        Set<String> batchKeys = new Set<String>();
        for (Scheme_Mapping__c rec : records) {
            String key = rec.Scheme__c + '|' + rec.Territory__c + '|' +
                         rec.Account__c + '|' + rec.Customer_Type__c;
            if (existingKeys.contains(key) || batchKeys.contains(key)) {
                rec.addError('A mapping with the same territory, account, and customer type already exists for this scheme.');
            }
            batchKeys.add(key);
        }
    }
}