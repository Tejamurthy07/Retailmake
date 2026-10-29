import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getFeatureToggles from '@salesforce/apex/AdminConfigController.getFeatureToggles';
import updateFeatureToggle from '@salesforce/apex/AdminConfigController.updateFeatureToggle';
import getAppConfigs from '@salesforce/apex/AdminConfigController.getAppConfigs';
import updateAppConfig from '@salesforce/apex/AdminConfigController.updateAppConfig';
import getGeoConfigs from '@salesforce/apex/AdminConfigController.getGeoConfigs';
import updateGeoConfig from '@salesforce/apex/AdminConfigController.updateGeoConfig';
import exportConfig from '@salesforce/apex/AdminConfigController.exportConfig';
import importConfig from '@salesforce/apex/AdminConfigController.importConfig';

export default class AdminConfigConsole extends LightningElement {
    @track activeSection = 'featureToggles';
    @track featureToggles = [];
    @track appConfigs = [];
    @track geoConfigs = {
        geofenceRadius: 200,
        trackingInterval: 60,
        gpsAccuracy: 50,
        enableTracking: true,
        enforceGeofence: true,
        trackDistance: true
    };
    @track approvalMatrix = [];

    isLoading = false;
    isSaving = false;

    get showFeatureToggles() { return this.activeSection === 'featureToggles'; }
    get showAppConfig() { return this.activeSection === 'appConfig'; }
    get showGeoSettings() { return this.activeSection === 'geoSettings'; }
    get showApprovalMatrix() { return this.activeSection === 'approvalMatrix'; }

    get featureTogglesNavClass() {
        return 'sidebar-item' + (this.activeSection === 'featureToggles' ? ' active' : '');
    }
    get appConfigNavClass() {
        return 'sidebar-item' + (this.activeSection === 'appConfig' ? ' active' : '');
    }
    get geoSettingsNavClass() {
        return 'sidebar-item' + (this.activeSection === 'geoSettings' ? ' active' : '');
    }
    get approvalMatrixNavClass() {
        return 'sidebar-item' + (this.activeSection === 'approvalMatrix' ? ' active' : '');
    }

    connectedCallback() {
        this.loadSectionData('featureToggles');
        this.initializeDefaults();
    }

    initializeDefaults() {
        // Initialize with default approval matrix
        this.approvalMatrix = [
            { id: 'rule_1', process: 'Journey Plan', condition: 'All PJPs', approverL1: 'Area Manager', approverL2: 'Regional Manager', autoApprove: false },
            { id: 'rule_2', process: 'Sales Return', condition: 'Amount > 5000', approverL1: 'Area Manager', approverL2: 'Finance Head', autoApprove: false },
            { id: 'rule_3', process: 'Sales Return', condition: 'Amount <= 5000', approverL1: 'Area Manager', approverL2: '-', autoApprove: true },
            { id: 'rule_4', process: 'Credit Limit Override', condition: 'All requests', approverL1: 'Finance Head', approverL2: 'CFO', autoApprove: false },
            { id: 'rule_5', process: 'Discount Override', condition: 'Discount > 10%', approverL1: 'Sales Head', approverL2: 'VP Sales', autoApprove: false },
            { id: 'rule_6', process: 'New Outlet', condition: 'All requests', approverL1: 'Area Manager', approverL2: '-', autoApprove: true }
        ];
    }

    handleSectionChange(event) {
        const section = event.currentTarget.dataset.section;
        this.activeSection = section;
        this.loadSectionData(section);
    }

    async loadSectionData(section) {
        this.isLoading = true;
        try {
            switch (section) {
                case 'featureToggles':
                    await this.loadFeatureToggles();
                    break;
                case 'appConfig':
                    await this.loadAppConfigs();
                    break;
                case 'geoSettings':
                    await this.loadGeoConfigs();
                    break;
                case 'approvalMatrix':
                    // Already initialized with defaults
                    break;
                default:
                    break;
            }
        } catch (error) {
            console.error('Error loading section:', error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadFeatureToggles() {
        try {
            const result = await getFeatureToggles({});
            if (result && result.length > 0) {
                this.featureToggles = result.map(toggle => ({
                    id: toggle.Id || toggle.DeveloperName,
                    name: toggle.Label || toggle.Name,
                    description: toggle.Description__c || '',
                    module: toggle.Module__c || '',
                    isEnabled: toggle.Is_Enabled__c !== false,
                    tierBadge: toggle.Tier__c || null,
                    tierClass: this.getTierClass(toggle.Tier__c)
                }));
            } else {
                this.featureToggles = this.getDefaultToggles();
            }
        } catch (error) {
            console.error('Error loading toggles:', error);
            this.featureToggles = this.getDefaultToggles();
        }
    }

    getDefaultToggles() {
        return [
            { id: 't1', name: 'Order Management', description: 'Order booking and processing', module: 'Sales', isEnabled: true, tierBadge: 'Core', tierClass: 'tier-badge tier-core' },
            { id: 't2', name: 'Visit Management', description: 'Check-in/check-out and visit tracking', module: 'Field', isEnabled: true, tierBadge: 'Core', tierClass: 'tier-badge tier-core' },
            { id: 't3', name: 'Collection Management', description: 'Payment collection and reconciliation', module: 'Finance', isEnabled: true, tierBadge: 'Core', tierClass: 'tier-badge tier-core' },
            { id: 't4', name: 'Beat Planning', description: 'Journey plan and beat management', module: 'Planning', isEnabled: true, tierBadge: 'Standard', tierClass: 'tier-badge tier-standard' },
            { id: 't5', name: 'Scheme Management', description: 'Promotional schemes and discounts', module: 'Sales', isEnabled: true, tierBadge: 'Standard', tierClass: 'tier-badge tier-standard' },
            { id: 't6', name: 'Sales Returns', description: 'Return order processing', module: 'Sales', isEnabled: true, tierBadge: 'Standard', tierClass: 'tier-badge tier-standard' },
            { id: 't7', name: 'Geo Tracking', description: 'Real-time location tracking', module: 'Field', isEnabled: true, tierBadge: 'Premium', tierClass: 'tier-badge tier-premium' },
            { id: 't8', name: 'Selfie Attendance', description: 'Photo capture for attendance', module: 'Field', isEnabled: false, tierBadge: 'Premium', tierClass: 'tier-badge tier-premium' },
            { id: 't9', name: 'Dashboard & Analytics', description: 'Performance dashboards', module: 'Analytics', isEnabled: true, tierBadge: 'Standard', tierClass: 'tier-badge tier-standard' },
            { id: 't10', name: 'Offline Mode', description: 'Offline data sync capability', module: 'Platform', isEnabled: false, tierBadge: 'Premium', tierClass: 'tier-badge tier-premium' },
            { id: 't11', name: 'Merchandising', description: 'Shelf compliance and merchandising audit', module: 'Field', isEnabled: false, tierBadge: 'Premium', tierClass: 'tier-badge tier-premium' },
            { id: 't12', name: 'Survey Module', description: 'Custom survey creation and execution', module: 'Field', isEnabled: false, tierBadge: 'Premium', tierClass: 'tier-badge tier-premium' }
        ];
    }

    async loadAppConfigs() {
        try {
            const result = await getAppConfigs({});
            if (result && result.length > 0) {
                this.appConfigs = result.map(config => ({
                    id: config.Id || config.DeveloperName,
                    key: config.Key__c || config.DeveloperName,
                    value: config.Value__c || '',
                    displayValue: config.Value__c || '',
                    dataType: config.Data_Type__c || 'String',
                    description: config.Description__c || '',
                    inputType: this.getInputType(config.Data_Type__c),
                    isEditing: false,
                    originalValue: config.Value__c || ''
                }));
            } else {
                this.appConfigs = this.getDefaultAppConfigs();
            }
        } catch (error) {
            this.appConfigs = this.getDefaultAppConfigs();
        }
    }

    getDefaultAppConfigs() {
        return [
            { id: 'c1', key: 'MAX_ORDER_LINES', value: '50', displayValue: '50', dataType: 'Integer', description: 'Maximum line items per order', inputType: 'number', isEditing: false, originalValue: '50' },
            { id: 'c2', key: 'DEFAULT_TAX_RATE', value: '18', displayValue: '18', dataType: 'Decimal', description: 'Default GST rate (%)', inputType: 'number', isEditing: false, originalValue: '18' },
            { id: 'c3', key: 'ORDER_PREFIX', value: 'SO', displayValue: 'SO', dataType: 'String', description: 'Sales order number prefix', inputType: 'text', isEditing: false, originalValue: 'SO' },
            { id: 'c4', key: 'MAX_CREDIT_DAYS', value: '30', displayValue: '30', dataType: 'Integer', description: 'Default credit period in days', inputType: 'number', isEditing: false, originalValue: '30' },
            { id: 'c5', key: 'MIN_ORDER_VALUE', value: '500', displayValue: '500', dataType: 'Decimal', description: 'Minimum order value (INR)', inputType: 'number', isEditing: false, originalValue: '500' },
            { id: 'c6', key: 'AUTO_SAVE_INTERVAL', value: '30', displayValue: '30', dataType: 'Integer', description: 'Auto-save interval (seconds)', inputType: 'number', isEditing: false, originalValue: '30' },
            { id: 'c7', key: 'CURRENCY_CODE', value: 'INR', displayValue: 'INR', dataType: 'String', description: 'Default currency code', inputType: 'text', isEditing: false, originalValue: 'INR' },
            { id: 'c8', key: 'PHOTO_MAX_SIZE_MB', value: '5', displayValue: '5', dataType: 'Integer', description: 'Maximum photo upload size (MB)', inputType: 'number', isEditing: false, originalValue: '5' }
        ];
    }

    async loadGeoConfigs() {
        try {
            const result = await getGeoConfigs({});
            if (result) {
                this.geoConfigs = {
                    geofenceRadius: result.Geofence_Radius__c || 200,
                    trackingInterval: result.Tracking_Interval__c || 60,
                    gpsAccuracy: result.GPS_Accuracy__c || 50,
                    enableTracking: result.Enable_Tracking__c !== false,
                    enforceGeofence: result.Enforce_Geofence__c !== false,
                    trackDistance: result.Track_Distance__c !== false
                };
            }
        } catch (error) {
            console.error('Error loading geo configs:', error);
        }
    }

    handleToggle(event) {
        const toggleId = event.target.dataset.toggleId;
        const isEnabled = event.target.checked;
        this.featureToggles = this.featureToggles.map(toggle => {
            if (toggle.id === toggleId) {
                return { ...toggle, isEnabled: isEnabled };
            }
            return toggle;
        });
    }

    async handleSaveToggles() {
        this.isSaving = true;
        try {
            const toggleData = this.featureToggles.map(t => ({
                id: t.id,
                isEnabled: t.isEnabled
            }));
            await updateFeatureToggle({ togglesJson: JSON.stringify(toggleData) });
            this.showToast('Success', 'Feature toggles saved successfully', 'success');
        } catch (error) {
            this.showToast('Error', 'Failed to save: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleResetToggles() {
        this.featureToggles = this.getDefaultToggles();
        this.showToast('Info', 'Toggles reset to defaults', 'info');
    }

    handleEditConfig(event) {
        const configId = event.currentTarget.dataset.configId;
        this.appConfigs = this.appConfigs.map(config => {
            if (config.id === configId) {
                return { ...config, isEditing: true };
            }
            return config;
        });
    }

    handleConfigValueChange(event) {
        const configId = event.target.dataset.configId;
        const value = event.detail.value;
        this.appConfigs = this.appConfigs.map(config => {
            if (config.id === configId) {
                return { ...config, value: value };
            }
            return config;
        });
    }

    async handleSaveConfig(event) {
        const configId = event.currentTarget.dataset.configId;
        this.isSaving = true;
        try {
            const config = this.appConfigs.find(c => c.id === configId);
            if (config) {
                await updateAppConfig({
                    configId: configId,
                    value: String(config.value)
                });
                this.appConfigs = this.appConfigs.map(c => {
                    if (c.id === configId) {
                        return { ...c, isEditing: false, displayValue: c.value, originalValue: c.value };
                    }
                    return c;
                });
                this.showToast('Success', 'Configuration saved', 'success');
            }
        } catch (error) {
            this.showToast('Error', 'Failed to save: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleCancelEditConfig(event) {
        const configId = event.currentTarget.dataset.configId;
        this.appConfigs = this.appConfigs.map(config => {
            if (config.id === configId) {
                return { ...config, isEditing: false, value: config.originalValue };
            }
            return config;
        });
    }

    async handleSaveAllConfigs() {
        this.isSaving = true;
        try {
            const configData = this.appConfigs.map(c => ({
                id: c.id,
                key: c.key,
                value: String(c.value)
            }));
            await updateAppConfig({ configsJson: JSON.stringify(configData) });
            this.appConfigs = this.appConfigs.map(c => ({
                ...c, isEditing: false, displayValue: c.value, originalValue: c.value
            }));
            this.showToast('Success', 'All configurations saved', 'success');
        } catch (error) {
            this.showToast('Error', 'Failed to save: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleResetConfigs() {
        this.appConfigs = this.getDefaultAppConfigs();
        this.showToast('Info', 'Configurations reset to defaults', 'info');
    }

    handleGeofenceRadiusChange(event) {
        this.geoConfigs = { ...this.geoConfigs, geofenceRadius: event.detail.value };
    }

    handleTrackingIntervalChange(event) {
        this.geoConfigs = { ...this.geoConfigs, trackingInterval: event.detail.value };
    }

    handleGpsAccuracyChange(event) {
        this.geoConfigs = { ...this.geoConfigs, gpsAccuracy: event.detail.value };
    }

    handleEnableTrackingChange(event) {
        this.geoConfigs = { ...this.geoConfigs, enableTracking: event.target.checked };
    }

    handleEnforceGeofenceChange(event) {
        this.geoConfigs = { ...this.geoConfigs, enforceGeofence: event.target.checked };
    }

    handleTrackDistanceChange(event) {
        this.geoConfigs = { ...this.geoConfigs, trackDistance: event.target.checked };
    }

    async handleSaveGeoSettings() {
        this.isSaving = true;
        try {
            await updateGeoConfig({ geoJson: JSON.stringify(this.geoConfigs) });
            this.showToast('Success', 'Geo settings saved successfully', 'success');
        } catch (error) {
            this.showToast('Error', 'Failed to save: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    handleResetGeoSettings() {
        this.geoConfigs = {
            geofenceRadius: 200,
            trackingInterval: 60,
            gpsAccuracy: 50,
            enableTracking: true,
            enforceGeofence: true,
            trackDistance: true
        };
        this.showToast('Info', 'Geo settings reset to defaults', 'info');
    }

    handleAutoApproveChange(event) {
        const ruleId = event.target.dataset.ruleId;
        this.approvalMatrix = this.approvalMatrix.map(rule => {
            if (rule.id === ruleId) {
                return { ...rule, autoApprove: event.target.checked };
            }
            return rule;
        });
    }

    async handleExport() {
        try {
            const result = await exportConfig({});
            const configData = result || JSON.stringify({
                featureToggles: this.featureToggles,
                appConfigs: this.appConfigs,
                geoConfigs: this.geoConfigs,
                approvalMatrix: this.approvalMatrix
            }, null, 2);

            const blob = new Blob([configData], { type: 'application/json' });
            const url = URL.createObjectURL(blob);
            const link = document.createElement('a');
            link.href = url;
            link.download = 'sfa_config_' + new Date().toISOString().split('T')[0] + '.json';
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
            URL.revokeObjectURL(url);

            this.showToast('Success', 'Configuration exported successfully', 'success');
        } catch (error) {
            this.showToast('Error', 'Export failed: ' + this.reduceErrors(error), 'error');
        }
    }

    handleImportClick() {
        const fileInput = this.template.querySelector('input[type="file"]');
        if (fileInput) fileInput.click();
    }

    async handleImport(event) {
        const file = event.target.files[0];
        if (!file) return;

        const reader = new FileReader();
        reader.onload = async () => {
            try {
                const configData = reader.result;
                await importConfig({ configJson: configData });
                this.showToast('Success', 'Configuration imported successfully', 'success');
                this.loadSectionData(this.activeSection);
            } catch (error) {
                this.showToast('Error', 'Import failed: ' + this.reduceErrors(error), 'error');
            }
        };
        reader.readAsText(file);
    }

    getTierClass(tier) {
        const tierMap = {
            'Core': 'tier-badge tier-core',
            'Standard': 'tier-badge tier-standard',
            'Premium': 'tier-badge tier-premium',
            'Enterprise': 'tier-badge tier-enterprise'
        };
        return tierMap[tier] || 'tier-badge tier-standard';
    }

    getInputType(dataType) {
        const typeMap = {
            'Integer': 'number',
            'Decimal': 'number',
            'Boolean': 'toggle',
            'String': 'text',
            'Date': 'date'
        };
        return typeMap[dataType] || 'text';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return 'Unknown error';
    }
}