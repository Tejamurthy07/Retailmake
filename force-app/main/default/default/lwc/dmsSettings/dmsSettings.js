import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAppConfigs from '@salesforce/apex/AdminConfigController.getAppConfigs';
import updateAppConfig from '@salesforce/apex/AdminConfigController.updateAppConfig';
import getFeatureToggles from '@salesforce/apex/AdminConfigController.getFeatureToggles';
import updateFeatureToggle from '@salesforce/apex/AdminConfigController.updateFeatureToggle';

const TIER_OPTIONS = [
    { label: 'Three-tier (Company → Super Stockist → Distributor → Retailer)', value: 'THREE_TIER' },
    { label: 'Two-tier (Company → Distributor → Retailer)', value: 'TWO_TIER' }
];

export default class DmsSettings extends LightningElement {
    settings = [];
    toggles = [];
    _wiredCfg;
    _wiredTog;
    edits = {};         // configId -> new value
    toggleEdits = {};   // developerName -> new bool
    saving = false;
    error;

    @wire(getAppConfigs)
    wiredConfigs(result) {
        this._wiredCfg = result;
        if (result.data) {
            this.settings = result.data
                .filter((c) => c.Module__c === 'DMS')
                .map((c) => this.decorate(c));
            this.error = undefined;
        } else if (result.error) {
            this.error = this.msg(result.error);
        }
    }

    @wire(getFeatureToggles)
    wiredToggles(result) {
        this._wiredTog = result;
        if (result.data) {
            this.toggles = result.data
                .filter((t) => (t.Feature_Code__c || '').startsWith('DMS-'))
                .map((t) => ({
                    devName: t.DeveloperName,
                    label: t.MasterLabel,
                    code: t.Feature_Code__c,
                    checked: !!t.Is_Enabled__c
                }));
        }
    }

    decorate(c) {
        const dt = (c.Data_Type__c || 'Text').toLowerCase();
        const isTier = c.Config_Key__c === 'TIER_MODEL';
        return {
            id: c.Id,
            key: c.Config_Key__c,
            label: c.MasterLabel,
            description: c.Description__c,
            value: c.Config_Value__c,
            dataType: c.Data_Type__c,
            isNumber: dt === 'number',
            isBoolean: dt === 'boolean',
            isTier,
            isText: !isTier && dt !== 'number' && dt !== 'boolean',
            boolChecked: String(c.Config_Value__c).toLowerCase() === 'true',
            tierOptions: TIER_OPTIONS
        };
    }

    handleText(e) { this.edits[e.target.dataset.id] = e.target.value; }
    handleNumber(e) { this.edits[e.target.dataset.id] = String(e.target.value); }
    handleTier(e) { this.edits[e.target.dataset.id] = e.detail.value; }
    handleBool(e) { this.edits[e.target.dataset.id] = e.target.checked ? 'true' : 'false'; }
    handleToggle(e) { this.toggleEdits[e.target.dataset.name] = e.target.checked; }

    get hasChanges() {
        return Object.keys(this.edits).length > 0 || Object.keys(this.toggleEdits).length > 0;
    }
    get saveDisabled() { return this.saving || !this.hasChanges; }

    async save() {
        this.saving = true;
        try {
            const tasks = [];
            for (const id of Object.keys(this.edits)) {
                tasks.push(updateAppConfig({ configId: id, value: this.edits[id] }));
            }
            for (const dev of Object.keys(this.toggleEdits)) {
                tasks.push(updateFeatureToggle({ developerName: dev, isEnabled: this.toggleEdits[dev] }));
            }
            await Promise.all(tasks);
            this.edits = {};
            this.toggleEdits = {};
            this.dispatchEvent(new ShowToastEvent({
                title: 'Settings queued',
                message: 'Changes are deploying and will take effect in a few seconds.',
                variant: 'success'
            }));
            await Promise.all([refreshApex(this._wiredCfg), refreshApex(this._wiredTog)]);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not save settings', message: this.msg(e), variant: 'error'
            }));
        } finally {
            this.saving = false;
        }
    }

    msg(e) { return (e && e.body && e.body.message) || 'Unexpected error.'; }
}