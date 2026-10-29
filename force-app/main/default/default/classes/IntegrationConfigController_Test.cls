/**
 * @description Tests for the integrations config controller: catalog⨝state merge, secret-safe
 *              save, credential marking, and the stub Test-Connection gating. Relies on the shipped
 *              Integration_Definition__mdt catalog (whatsapp / sms) deployed alongside.
 */
@isTest
private class IntegrationConfigController_Test {

    @isTest
    static void getIntegrations_mergesCatalogAndState() {
        insert new Integration_Setting__c(
            Integration_Key__c = 'whatsapp', Name = 'WhatsApp', Is_Enabled__c = true,
            Provider__c = 'Gupshup', Mode__c = 'Live', Settings_JSON__c = '{"senderId":"9000012345"}',
            Credential_Set__c = true, Status__c = 'Connected');

        Test.startTest();
        List<IntegrationConfigController.IntegrationView> views = IntegrationConfigController.getIntegrations();
        Test.stopTest();

        System.assert(!views.isEmpty(), 'Catalog should return the seeded definitions');
        IntegrationConfigController.IntegrationView wa;
        IntegrationConfigController.IntegrationView sms;
        for (IntegrationConfigController.IntegrationView v : views) {
            if (v.key == 'whatsapp') { wa = v; }
            if (v.key == 'sms') { sms = v; }
        }
        System.assertNotEquals(null, wa, 'WhatsApp definition present');
        System.assertEquals(true, wa.enabled, 'State merged: enabled');
        System.assertEquals('Gupshup', wa.provider, 'State merged: provider');
        System.assertEquals('Connected', wa.status, 'State merged: status');
        System.assertEquals('9000012345', String.valueOf(wa.settings.get('senderId')), 'Non-secret setting merged');
        System.assert(wa.requiresCredential, 'WhatsApp requires a credential');
        System.assert(!wa.schema.isEmpty(), 'Schema parsed from the definition');
        Boolean hasSecret = false;
        for (IntegrationConfigController.SettingField f : wa.schema) { if (f.secret == true) { hasSecret = true; } }
        System.assert(hasSecret, 'Schema includes a secret field');
        System.assert(!wa.providerOptions.isEmpty(), 'Provider options parsed');

        System.assertNotEquals(null, sms, 'SMS definition present');
        System.assertEquals(false, sms.enabled, 'Unconfigured integration defaults to disabled');
        System.assertEquals('Not Configured', sms.status, 'Unconfigured integration status');
    }

    @isTest
    static void saveIntegration_upsertsAndStripsSecrets() {
        Test.startTest();
        // Client mistakenly includes the secret apiKey alongside the non-secret senderId.
        IntegrationConfigController.saveIntegration(
            'sms', true, 'MSG91', 'Live', '{"senderId":"FTMART","apiKey":"SHOULD_NOT_PERSIST"}');
        Test.stopTest();

        Integration_Setting__c s = [
            SELECT Is_Enabled__c, Provider__c, Mode__c, Settings_JSON__c, Status__c
            FROM Integration_Setting__c WHERE Integration_Key__c = 'sms' LIMIT 1];
        System.assertEquals(true, s.Is_Enabled__c, 'Enabled saved');
        System.assertEquals('MSG91', s.Provider__c, 'Provider saved');
        System.assertEquals('Live', s.Mode__c, 'Mode saved');
        System.assert(s.Settings_JSON__c.contains('senderId'), 'Non-secret setting persisted');
        System.assert(!s.Settings_JSON__c.contains('SHOULD_NOT_PERSIST'), 'Secret value stripped from settings');
        System.assert(!s.Settings_JSON__c.contains('apiKey'), 'Secret key stripped from settings');
        System.assertEquals('Not Configured', s.Status__c, 'Enabled but no credential yet -> Not Configured');
    }

    @isTest
    static void saveCredentials_marksSetWithoutStoringSecret() {
        Test.startTest();
        IntegrationConfigController.saveCredentials('sms', '{"apiKey":"super-secret"}');
        Test.stopTest();

        Integration_Setting__c s = [
            SELECT Credential_Set__c, Settings_JSON__c FROM Integration_Setting__c WHERE Integration_Key__c = 'sms' LIMIT 1];
        System.assertEquals(true, s.Credential_Set__c, 'Credential marked set');
        System.assertEquals(null, s.Settings_JSON__c, 'Secret never written to settings');
    }

    @isTest
    static void saveCredentials_blankSecretThrows() {
        Boolean thrown = false;
        Test.startTest();
        try {
            IntegrationConfigController.saveCredentials('sms', '{"apiKey":"   "}');
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Blank secret rejected');
    }

    @isTest
    static void testConnection_stubGatesOnCredential() {
        IntegrationConfigController.saveIntegration('whatsapp', true, 'Gupshup', 'Sandbox', '{"senderId":"900001"}');

        Test.startTest();
        IntegrationTypes.ConnectionResult before = IntegrationConfigController.testConnection('whatsapp');
        IntegrationConfigController.saveCredentials('whatsapp', '{"apiKey":"k"}');
        IntegrationTypes.ConnectionResult after = IntegrationConfigController.testConnection('whatsapp');
        Test.stopTest();

        System.assertEquals(false, before.ok, 'No credential -> stub reports not ready');
        System.assertEquals(true, after.ok, 'With credential -> stub reports ready');
        Integration_Setting__c s = [
            SELECT Status__c, Last_Tested__c FROM Integration_Setting__c WHERE Integration_Key__c = 'whatsapp' LIMIT 1];
        System.assertEquals('Connected', s.Status__c, 'Enabled + passing test -> Connected');
        System.assertNotEquals(null, s.Last_Tested__c, 'Last tested stamped');
    }

    @isTest
    static void providers_carryUrls_andRecordOnlyProviderAppears() {
        Test.startTest();
        List<IntegrationConfigController.IntegrationView> views = IntegrationConfigController.getIntegrations();
        Test.stopTest();

        IntegrationConfigController.IntegrationView gst;
        IntegrationConfigController.IntegrationView maps;
        for (IntegrationConfigController.IntegrationView v : views) {
            if (v.key == 'gst_einvoice') { gst = v; }
            if (v.key == 'google_maps') { maps = v; }
        }

        // An existing dropdown provider is enriched with its sandbox/live URLs.
        System.assertNotEquals(null, gst, 'GST e-Invoice present');
        IntegrationConfigController.ProviderOption nic;
        for (IntegrationConfigController.ProviderOption p : gst.providers) {
            if (p.name == 'NIC (IRP)') { nic = p; }
        }
        System.assertNotEquals(null, nic, 'NIC (IRP) provider present');
        System.assertEquals('https://api.einvoice1.gst.gov.in', nic.liveUrl, 'Live URL overlaid');
        System.assertEquals('https://einv-apisandbox.nic.in', nic.sandboxUrl, 'Sandbox URL overlaid');

        // Google Maps had no Provider Options — the provider appears purely from its record.
        System.assertNotEquals(null, maps, 'Google Maps present');
        System.assertEquals(1, maps.providers.size(), 'Record-only provider surfaces in the dropdown');
        System.assertEquals('Google', maps.providers[0].name, 'Provider name from record');
        System.assertEquals('https://maps.googleapis.com', maps.providers[0].liveUrl, 'Maps endpoint set');
    }

    @isTest
    static void unknownKey_throws() {
        Boolean thrown = false;
        Test.startTest();
        try {
            IntegrationConfigController.saveIntegration('does_not_exist', true, null, 'Sandbox', '{}');
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();
        System.assertEquals(true, thrown, 'Unknown integration key rejected');
    }
}