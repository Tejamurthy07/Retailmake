/**
 * @description Controller for the Admin Configuration LWC component.
 *              Provides read/write access to custom metadata configuration records
 *              including Feature Toggles, App Configs, and Geo Configs.
 *              Uses the Metadata.DeployContainer approach for custom metadata updates.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public with sharing class AdminConfigController {

    // ── Get Feature Toggles ─────────────────────────────────────────────────────

    /**
     * @description Retrieves all Feature_Toggle__mdt custom metadata records.
     * @return List of Feature_Toggle__mdt records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Feature_Toggle__mdt> getFeatureToggles() {
        return [
            SELECT Id, DeveloperName, MasterLabel, Feature_Code__c, Is_Enabled__c,
                   Module__c, Description__c, Package_Tier__c
            FROM Feature_Toggle__mdt
            ORDER BY Module__c, MasterLabel
        ];
    }

    // ── Update Feature Toggle ───────────────────────────────────────────────────

    /**
     * @description Updates the Is_Enabled__c field on a Feature_Toggle__mdt record
     *              using the Metadata.DeployContainer approach (the only way to
     *              update custom metadata from Apex at runtime).
     * @param developerName The DeveloperName of the Feature Toggle to update.
     * @param isEnabled     The new enabled/disabled state.
     * @return Success message string.
     */
    @AuraEnabled
    public static String updateFeatureToggle(String developerName, Boolean isEnabled) {
        try {
            if (String.isBlank(developerName)) {
                throw new AuraHandledException('Developer name is required.');
            }

            // Verify the record exists
            List<Feature_Toggle__mdt> existing = [
                SELECT Id, DeveloperName, MasterLabel
                FROM Feature_Toggle__mdt
                WHERE DeveloperName = :developerName
                LIMIT 1
            ];
            if (existing.isEmpty()) {
                throw new AuraHandledException(
                    'Feature toggle with developer name "' + developerName + '" not found.'
                );
            }

            // Build the custom metadata record for deployment
            Metadata.CustomMetadata customMetadata = new Metadata.CustomMetadata();
            customMetadata.fullName = 'Feature_Toggle__mdt.' + developerName;
            customMetadata.label = existing[0].MasterLabel;

            Metadata.CustomMetadataValue isEnabledField = new Metadata.CustomMetadataValue();
            isEnabledField.field = 'Is_Enabled__c';
            isEnabledField.value = isEnabled;
            customMetadata.values.add(isEnabledField);

            // Deploy using container
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(customMetadata);

            // Enqueue the deployment
            Id deployJobId = Metadata.Operations.enqueueDeployment(
                container,
                new AdminConfigDeployCallback()
            );

            return 'Feature toggle update queued. Deployment Job Id: ' + deployJobId;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to update feature toggle: ' + e.getMessage());
        }
    }

    // ── Get App Configs ─────────────────────────────────────────────────────────

    /**
     * @description Retrieves all App_Config__mdt custom metadata records.
     * @return List of App_Config__mdt records.
     */
    @AuraEnabled(cacheable=true)
    public static List<App_Config__mdt> getAppConfigs() {
        return [
            SELECT Id, DeveloperName, MasterLabel, Config_Key__c, Config_Value__c,
                   Data_Type__c, Description__c, Module__c
            FROM App_Config__mdt
            ORDER BY Module__c, Config_Key__c
        ];
    }

    // ── Get Geo Configs ─────────────────────────────────────────────────────────

    /**
     * @description Retrieves all Geo_Config__mdt custom metadata records.
     * @return List of Geo_Config__mdt records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Geo_Config__mdt> getGeoConfigs() {
        return [
            SELECT Id, DeveloperName, MasterLabel, Config_Type__c, Value__c
            FROM Geo_Config__mdt
            ORDER BY Config_Type__c
        ];
    }

    // ── Update App Config ──────────────────────────────────────────────────

    /**
     * @description Updates a single App_Config__mdt record's value using the
     *              Metadata.DeployContainer approach.
     * @param configId The Id of the App_Config__mdt record to update.
     * @param value    The new Config_Value__c string.
     * @return Success message string.
     */
    @AuraEnabled
    public static String updateAppConfig(String configId, String value) {
        try {
            List<App_Config__mdt> existing = [
                SELECT Id, DeveloperName, MasterLabel
                FROM App_Config__mdt
                WHERE Id = :configId
                LIMIT 1
            ];
            if (existing.isEmpty()) {
                throw new AuraHandledException('App config record not found.');
            }

            Metadata.CustomMetadata customMetadata = new Metadata.CustomMetadata();
            customMetadata.fullName = 'App_Config__mdt.' + existing[0].DeveloperName;
            customMetadata.label = existing[0].MasterLabel;

            Metadata.CustomMetadataValue valueField = new Metadata.CustomMetadataValue();
            valueField.field = 'Config_Value__c';
            valueField.value = value;
            customMetadata.values.add(valueField);

            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(customMetadata);
            Id deployJobId = Metadata.Operations.enqueueDeployment(
                container, new AdminConfigDeployCallback()
            );

            return 'App config update queued. Deployment Job Id: ' + deployJobId;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to update app config: ' + e.getMessage());
        }
    }

    // ── Update Geo Config ────────────────────────────────────────────────────

    /**
     * @description Updates Geo_Config__mdt records from a JSON payload.
     * @param geoJson JSON string with geo configuration values.
     * @return Success message string.
     */
    @AuraEnabled
    public static String updateGeoConfig(String geoJson) {
        try {
            Map<String, Object> geoData = (Map<String, Object>) JSON.deserializeUntyped(geoJson);
            Metadata.DeployContainer container = new Metadata.DeployContainer();

            // Map JSON keys to Geo_Config__mdt Config_Type__c values
            Map<String, String> keyToConfigType = new Map<String, String>{
                'geofenceRadius' => 'Geofence_Radius_Meters',
                'trackingInterval' => 'Tracking_Interval_Seconds',
                'gpsAccuracy' => 'GPS_Accuracy_Meters',
                'enableTracking' => 'Enable_Tracking',
                'enforceGeofence' => 'Enforce_Geofence',
                'trackDistance' => 'Track_Distance'
            };

            List<Geo_Config__mdt> allConfigs = [
                SELECT Id, DeveloperName, MasterLabel, Config_Type__c
                FROM Geo_Config__mdt
            ];
            Map<String, Geo_Config__mdt> configByType = new Map<String, Geo_Config__mdt>();
            for (Geo_Config__mdt gc : allConfigs) {
                configByType.put(gc.Config_Type__c, gc);
            }

            for (String jsonKey : keyToConfigType.keySet()) {
                if (!geoData.containsKey(jsonKey)) {
                    continue;
                }
                String configType = keyToConfigType.get(jsonKey);
                Geo_Config__mdt existing = configByType.get(configType);
                if (existing == null) {
                    continue;
                }

                Metadata.CustomMetadata customMetadata = new Metadata.CustomMetadata();
                customMetadata.fullName = 'Geo_Config__mdt.' + existing.DeveloperName;
                customMetadata.label = existing.MasterLabel;

                Metadata.CustomMetadataValue valueField = new Metadata.CustomMetadataValue();
                valueField.field = 'Value__c';
                valueField.value = String.valueOf(geoData.get(jsonKey));
                customMetadata.values.add(valueField);

                container.addMetadata(customMetadata);
            }

            Id deployJobId = Metadata.Operations.enqueueDeployment(
                container, new AdminConfigDeployCallback()
            );

            return 'Geo config update queued. Deployment Job Id: ' + deployJobId;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to update geo config: ' + e.getMessage());
        }
    }

    // ── Import Config ────────────────────────────────────────────────────────

    /**
     * @description Imports configuration from a JSON string (matching exportConfig format)
     *              and deploys updates to custom metadata records.
     * @param configJson JSON string with configuration data.
     * @return Success message string.
     */
    @AuraEnabled
    public static String importConfig(String configJson) {
        try {
            Map<String, Object> configData = (Map<String, Object>) JSON.deserializeUntyped(configJson);
            Metadata.DeployContainer container = new Metadata.DeployContainer();

            // Import Feature Toggles
            if (configData.containsKey('featureToggles')) {
                List<Object> toggles = (List<Object>) configData.get('featureToggles');
                for (Object toggleObj : toggles) {
                    Map<String, Object> toggle = (Map<String, Object>) toggleObj;
                    String devName = (String) toggle.get('developerName');

                    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
                    cm.fullName = 'Feature_Toggle__mdt.' + devName;
                    cm.label = (String) toggle.get('label');

                    Metadata.CustomMetadataValue isEnabledField = new Metadata.CustomMetadataValue();
                    isEnabledField.field = 'Is_Enabled__c';
                    isEnabledField.value = toggle.get('isEnabled');
                    cm.values.add(isEnabledField);

                    container.addMetadata(cm);
                }
            }

            // Import App Configs
            if (configData.containsKey('appConfigs')) {
                List<Object> appConfigs = (List<Object>) configData.get('appConfigs');
                for (Object configObj : appConfigs) {
                    Map<String, Object> config = (Map<String, Object>) configObj;
                    String devName = (String) config.get('developerName');

                    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
                    cm.fullName = 'App_Config__mdt.' + devName;
                    cm.label = (String) config.get('label');

                    Metadata.CustomMetadataValue valueField = new Metadata.CustomMetadataValue();
                    valueField.field = 'Config_Value__c';
                    valueField.value = (String) config.get('configValue');
                    cm.values.add(valueField);

                    container.addMetadata(cm);
                }
            }

            // Import Geo Configs
            if (configData.containsKey('geoConfigs')) {
                List<Object> geoConfigs = (List<Object>) configData.get('geoConfigs');
                for (Object configObj : geoConfigs) {
                    Map<String, Object> config = (Map<String, Object>) configObj;
                    String devName = (String) config.get('developerName');

                    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
                    cm.fullName = 'Geo_Config__mdt.' + devName;
                    cm.label = (String) config.get('label');

                    Metadata.CustomMetadataValue valueField = new Metadata.CustomMetadataValue();
                    valueField.field = 'Value__c';
                    valueField.value = (String) config.get('value');
                    cm.values.add(valueField);

                    container.addMetadata(cm);
                }
            }

            Id deployJobId = Metadata.Operations.enqueueDeployment(
                container, new AdminConfigDeployCallback()
            );

            return 'Configuration import queued. Deployment Job Id: ' + deployJobId;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to import configuration: ' + e.getMessage());
        }
    }

    // ── Export Config ───────────────────────────────────────────────────────────

    /**
     * @description Exports all custom metadata configuration as a JSON string.
     *              Useful for backup, migration, or environment comparison.
     * @return JSON string containing all configuration records.
     */
    @AuraEnabled
    public static String exportConfig() {
        try {
            Map<String, Object> configExport = new Map<String, Object>();

            // Feature Toggles
            List<Feature_Toggle__mdt> toggles = [
                SELECT DeveloperName, MasterLabel, Feature_Code__c, Is_Enabled__c,
                       Module__c, Description__c, Package_Tier__c
                FROM Feature_Toggle__mdt
                ORDER BY DeveloperName
            ];
            List<Map<String, Object>> toggleList = new List<Map<String, Object>>();
            for (Feature_Toggle__mdt ft : toggles) {
                Map<String, Object> m = new Map<String, Object>();
                m.put('developerName', ft.DeveloperName);
                m.put('label', ft.MasterLabel);
                m.put('featureCode', ft.Feature_Code__c);
                m.put('isEnabled', ft.Is_Enabled__c);
                m.put('module', ft.Module__c);
                m.put('description', ft.Description__c);
                m.put('packageTier', ft.Package_Tier__c);
                toggleList.add(m);
            }
            configExport.put('featureToggles', toggleList);

            // App Configs
            List<App_Config__mdt> appConfigs = [
                SELECT DeveloperName, MasterLabel, Config_Key__c, Config_Value__c,
                       Data_Type__c, Description__c, Module__c
                FROM App_Config__mdt
                ORDER BY DeveloperName
            ];
            List<Map<String, Object>> appConfigList = new List<Map<String, Object>>();
            for (App_Config__mdt ac : appConfigs) {
                Map<String, Object> m = new Map<String, Object>();
                m.put('developerName', ac.DeveloperName);
                m.put('label', ac.MasterLabel);
                m.put('configKey', ac.Config_Key__c);
                m.put('configValue', ac.Config_Value__c);
                m.put('dataType', ac.Data_Type__c);
                m.put('description', ac.Description__c);
                m.put('module', ac.Module__c);
                appConfigList.add(m);
            }
            configExport.put('appConfigs', appConfigList);

            // Geo Configs
            List<Geo_Config__mdt> geoConfigs = [
                SELECT DeveloperName, MasterLabel, Config_Type__c, Value__c
                FROM Geo_Config__mdt
                ORDER BY DeveloperName
            ];
            List<Map<String, Object>> geoConfigList = new List<Map<String, Object>>();
            for (Geo_Config__mdt gc : geoConfigs) {
                Map<String, Object> m = new Map<String, Object>();
                m.put('developerName', gc.DeveloperName);
                m.put('label', gc.MasterLabel);
                m.put('configType', gc.Config_Type__c);
                m.put('value', gc.Value__c);
                geoConfigList.add(m);
            }
            configExport.put('geoConfigs', geoConfigList);

            // Add metadata
            Map<String, Object> metadata = new Map<String, Object>();
            metadata.put('exportDate', Datetime.now().format('yyyy-MM-dd\'T\'HH:mm:ss.SSSZ'));
            metadata.put('exportedBy', UserInfo.getUserName());
            metadata.put('orgId', UserInfo.getOrganizationId());
            metadata.put('orgName', UserInfo.getOrganizationName());
            configExport.put('metadata', metadata);

            return JSON.serializePretty(configExport);
        } catch (Exception e) {
            throw new AuraHandledException('Failed to export configuration: ' + e.getMessage());
        }
    }

    // ── Deploy Callback Inner Class ─────────────────────────────────────────────

    /**
     * @description Callback handler for Metadata API deployments. Logs results
     *              for admin visibility.
     */
    public class AdminConfigDeployCallback implements Metadata.DeployCallback {
        public void handleResult(Metadata.DeployResult result,
                                 Metadata.DeployCallbackContext context) {
            if (result.status == Metadata.DeployStatus.Succeeded) {
                System.debug(LoggingLevel.INFO,
                    'AdminConfig metadata deployment succeeded. Id: ' + result.id);
            } else {
                System.debug(LoggingLevel.ERROR,
                    'AdminConfig metadata deployment failed. Id: ' + result.id +
                    ' Status: ' + result.status);
                if (result.details != null && result.details.componentFailures != null) {
                    for (Metadata.DeployMessage msg : result.details.componentFailures) {
                        System.debug(LoggingLevel.ERROR,
                            'Component failure: ' + msg.fullName + ' - ' + msg.problem);
                    }
                }
            }
        }
    }
}