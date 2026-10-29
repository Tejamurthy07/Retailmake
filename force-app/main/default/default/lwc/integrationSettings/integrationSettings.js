import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getIntegrations from '@salesforce/apex/IntegrationConfigController.getIntegrations';
import saveIntegration from '@salesforce/apex/IntegrationConfigController.saveIntegration';
import saveCredentials from '@salesforce/apex/IntegrationConfigController.saveCredentials';
import testConnection from '@salesforce/apex/IntegrationConfigController.testConnection';

const STATUS_THEME = {
    Connected: 'ok',
    'Not Configured': 'muted',
    Disabled: 'muted',
    Error: 'err'
};
const MODE_OPTIONS = [
    { label: 'Sandbox', value: 'Sandbox' },
    { label: 'Live', value: 'Live' }
];

export default class IntegrationSettings extends LightningElement {
    integrations = [];
    _wired;
    error;
    selectedKey;

    // Draft state for the open integration
    @track draftSettings = {};
    @track draftSecrets = {};
    draftEnabled = false;
    draftProvider = '';
    draftMode = 'Sandbox';

    saving = false;
    testing = false;

    // ── Data ───────────────────────────────────────────────────────────────
    @wire(getIntegrations)
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.integrations = result.data;
            this.error = undefined;
            if (this.selectedKey && !result.data.some((i) => i.key === this.selectedKey)) {
                this.selectedKey = undefined;
            }
        } else if (result.error) {
            this.error = this.msg(result.error);
        }
    }

    // ── Master list (grouped by category) ──────────────────────────────────
    get groups() {
        const byCat = {};
        const order = [];
        this.integrations.forEach((i) => {
            if (!byCat[i.category]) {
                byCat[i.category] = [];
                order.push(i.category);
            }
            byCat[i.category].push({
                key: i.key,
                label: i.label,
                icon: i.icon || 'utility:apps',
                status: i.status,
                statusClass: 'pill pill_' + (STATUS_THEME[i.status] || 'muted'),
                cardClass: 'card' + (i.key === this.selectedKey ? ' card_active' : '')
            });
        });
        return order.map((cat) => ({ category: cat, key: cat, items: byCat[cat] }));
    }

    // ── Selected integration + detail ──────────────────────────────────────
    get selected() {
        return this.integrations.find((i) => i.key === this.selectedKey);
    }
    get hasSelection() {
        return !!this.selected;
    }
    get modeOptions() {
        return MODE_OPTIONS;
    }
    get providerList() {
        const s = this.selected;
        return s ? s.providers || [] : [];
    }
    get providerOptions() {
        return this.providerList.map((p) => ({ label: p.name, value: p.name }));
    }
    get hasProviders() {
        return this.providerOptions.length > 0;
    }
    get activeEndpoint() {
        const p = this.providerList.find((x) => x.name === this.draftProvider);
        if (!p) {
            return '';
        }
        return (this.draftMode === 'Live' ? p.liveUrl : p.sandboxUrl) || '';
    }
    get hasEndpoint() {
        return !!this.activeEndpoint;
    }

    get settingFields() {
        return this.fieldsFor(false, this.draftSettings);
    }
    get secretFields() {
        return this.fieldsFor(true, this.draftSecrets);
    }
    get hasSettingFields() {
        return this.settingFields.length > 0;
    }
    get hasSecretFields() {
        return this.secretFields.length > 0;
    }

    fieldsFor(secret, source) {
        const s = this.selected;
        if (!s) {
            return [];
        }
        return (s.schema || [])
            .filter((f) => !!f.secret === secret)
            .map((f) => {
                const type = f.type || 'text';
                const value = source[f.key];
                return {
                    key: f.key,
                    label: f.label,
                    required: !!f.required,
                    value: value == null ? '' : value,
                    options: (f.options || []).map((o) => ({ label: o, value: o })),
                    isSelect: type === 'select',
                    isNumber: type === 'number',
                    isText: !secret && type !== 'select' && type !== 'number',
                    placeholder: secret ? '••••••••' : ''
                };
            });
    }

    get statusPillClass() {
        const s = this.selected ? this.selected.status : '';
        return 'pill pill_' + (STATUS_THEME[s] || 'muted');
    }
    get credentialLabel() {
        const s = this.selected;
        if (!s || !s.requiresCredential) {
            return '';
        }
        return s.credentialSet ? 'Credential set' : 'No credential set';
    }
    get credentialPillClass() {
        const s = this.selected;
        return 'credpill ' + (s && s.credentialSet ? 'credpill_ok' : 'credpill_muted');
    }
    get lastTestedLabel() {
        const s = this.selected;
        if (!s || !s.lastTested) {
            return '';
        }
        return new Intl.DateTimeFormat('en-GB', {
            day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit'
        }).format(new Date(s.lastTested));
    }

    // ── Interaction ────────────────────────────────────────────────────────
    selectIntegration(e) {
        const key = e.currentTarget.dataset.key;
        const i = this.integrations.find((x) => x.key === key);
        if (!i) {
            return;
        }
        this.selectedKey = key;
        this.draftEnabled = !!i.enabled;
        this.draftProvider =
            i.provider || (i.providerOptions && i.providerOptions.length === 1 ? i.providerOptions[0] : '');
        this.draftMode = i.mode || 'Sandbox';
        this.draftSettings = { ...(i.settings || {}) };
        this.draftSecrets = {}; // secrets are never pre-filled
    }

    handleEnabled(e) {
        this.draftEnabled = e.target.checked;
    }
    handleProvider(e) {
        this.draftProvider = e.detail.value;
    }
    handleMode(e) {
        this.draftMode = e.detail.value;
    }
    handleSetting(e) {
        this.draftSettings = { ...this.draftSettings, [e.target.dataset.key]: e.detail.value };
    }
    handleSecret(e) {
        this.draftSecrets = { ...this.draftSecrets, [e.target.dataset.key]: e.detail.value };
    }

    async save() {
        const s = this.selected;
        if (!s) {
            return;
        }
        this.saving = true;
        try {
            await saveIntegration({
                key: s.key,
                enabled: this.draftEnabled,
                provider: this.draftProvider || null,
                mode: this.draftMode,
                settingsJson: JSON.stringify(this.draftSettings || {})
            });
            const secrets = this.nonEmptySecrets();
            if (Object.keys(secrets).length > 0) {
                await saveCredentials({ key: s.key, secretsJson: JSON.stringify(secrets) });
            }
            this.draftSecrets = {};
            this.toast('Saved', s.label + ' configuration saved.', 'success');
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Could not save', this.msg(e), 'error');
        } finally {
            this.saving = false;
        }
    }

    async test() {
        const s = this.selected;
        if (!s) {
            return;
        }
        this.testing = true;
        try {
            const res = await testConnection({ key: s.key });
            this.toast(
                res && res.ok ? 'Connection OK' : 'Not connected',
                res ? res.message : 'No result',
                res && res.ok ? 'success' : 'warning'
            );
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Test failed', this.msg(e), 'error');
        } finally {
            this.testing = false;
        }
    }

    // ── Utility ────────────────────────────────────────────────────────────
    nonEmptySecrets() {
        const out = {};
        Object.keys(this.draftSecrets || {}).forEach((k) => {
            const v = this.draftSecrets[k];
            if (v != null && String(v).trim() !== '') {
                out[k] = v;
            }
        });
        return out;
    }
    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error.';
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}