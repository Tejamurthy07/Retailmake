import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getCatalog from '@salesforce/apex/VisitActivityConfigController.getCatalog';
import getRules from '@salesforce/apex/VisitActivityConfigController.getRules';
import getScopeOptions from '@salesforce/apex/VisitActivityConfigController.getScopeOptions';
import setActivityForScope from '@salesforce/apex/VisitActivityConfigController.setActivityForScope';
import deleteRule from '@salesforce/apex/VisitActivityConfigController.deleteRule';
import preview from '@salesforce/apex/VisitActivityConfigController.preview';

const ALL = '';

export default class VisitActivitySettings extends LightningElement {
    @track catalog = [];
    @track rules = [];
    @track profileOptions = [];
    @track outletTypeOptions = [];

    // The scope currently being edited. Blank means "applies to everything",
    // which is the broadest rule and the one most admins want first.
    @track scopeProfile = ALL;
    @track scopeOutletType = ALL;

    @track previewRows = [];
    @track previewOpen = false;
    @track isBusy = false;

    _wiredRules;

    @wire(getCatalog)
    wiredCatalog({ data, error }) {
        if (data) this.catalog = data;
        if (error) this.toast('Error', this.msg(error), 'error');
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. Recurses into arrays
    // and child relationships. No-op on camelCase maps and wrapper DTOs.
    _stripNs(value) {
        if (Array.isArray(value)) return value.map((v) => this._stripNs(v));
        if (value && typeof value === 'object') {
            const out = {};
            Object.keys(value).forEach((k) => {
                const nk = k.startsWith('ftretailmake__') ? k.slice('ftretailmake__'.length) : k;
                out[nk] = this._stripNs(value[k]);
            });
            return out;
        }
        return value;
    }

    @wire(getRules)
    wiredRules(result) {
        this._wiredRules = result;
        if (result.data) this.rules = this._stripNs(result.data);
        if (result.error) this.toast('Error', this.msg(result.error), 'error');
    }

    @wire(getScopeOptions)
    wiredScope({ data, error }) {
        if (data) {
            this.profileOptions = [{ label: 'All Profiles', value: ALL }, ...(data.profiles || [])];
            this.outletTypeOptions = [
                { label: 'All Outlet Types', value: ALL },
                ...(data.outletTypes || [])
            ];
        }
        if (error) this.toast('Error', this.msg(error), 'error');
    }

    // ── The matrix ──

    /**
     * One row per activity, showing what THIS scope does with it: an explicit
     * rule, or the inherited default. Keeping "inherited" visually distinct
     * from an explicit Show/Hide is the whole point — otherwise an admin can't
     * tell what they've actually configured from what merely happens to be true.
     */
    get rows() {
        const scopeRules = new Map();
        (this.rules || []).forEach((r) => {
            const p = r.Profile_Name__c || ALL;
            const o = r.Outlet_Type__c || ALL;
            if (p === this.scopeProfile && o === this.scopeOutletType) {
                scopeRules.set(r.Activity_Key__c, r);
            }
        });

        return (this.catalog || []).map((a) => {
            const rule = scopeRules.get(a.key);
            const hasRule = !!rule;
            const enabled = hasRule ? rule.Is_Enabled__c : true;
            const locked = !a.featureAvailable;

            let state = 'inherit';
            if (locked) state = 'locked';
            else if (hasRule) state = enabled ? 'show' : 'hide';

            return {
                ...a,
                ruleId: hasRule ? rule.Id : null,
                hasRule,
                enabled,
                locked,
                state,
                stateLabel: locked
                    ? `Unavailable — ${a.toggleCode} off`
                    : hasRule
                        ? (enabled ? 'Shown (explicit)' : 'Hidden (explicit)')
                        : 'Default (shown)',
                badgeClass:
                    'vas-badge ' +
                    (locked ? 'vas-badge_locked'
                        : hasRule ? (enabled ? 'vas-badge_show' : 'vas-badge_hide')
                        : 'vas-badge_inherit'),
                rowClass: 'vas-row' + (locked ? ' vas-row_locked' : ''),
                showDisabled: locked || (hasRule && enabled),
                hideDisabled: locked || (hasRule && !enabled),
                resetDisabled: locked || !hasRule
            };
        });
    }

    get scopeLabel() {
        const p = this.scopeProfile || 'All Profiles';
        const o = this.scopeOutletType || 'All Outlet Types';
        return `${p} · ${o}`;
    }

    get isGlobalScope() {
        return !this.scopeProfile && !this.scopeOutletType;
    }

    get ruleCount() {
        return (this.rules || []).length;
    }

    // ── Scope selection ──

    handleProfileChange(e) {
        this.scopeProfile = e.detail.value;
        this.previewOpen = false;
    }

    handleOutletTypeChange(e) {
        this.scopeOutletType = e.detail.value;
        this.previewOpen = false;
    }

    // ── Matrix actions ──

    handleShow(e) {
        this._apply(e.currentTarget.dataset.key, true, false);
    }

    handleHide(e) {
        this._apply(e.currentTarget.dataset.key, false, false);
    }

    handleReset(e) {
        this._apply(e.currentTarget.dataset.key, true, true);
    }

    async _apply(activityKey, enabled, useDefault) {
        if (!activityKey || this.isBusy) return;
        this.isBusy = true;
        try {
            await setActivityForScope({
                activityKey,
                profileName: this.scopeProfile,
                outletType: this.scopeOutletType,
                enabled,
                useDefault
            });
            await refreshApex(this._wiredRules);
            if (this.previewOpen) await this._runPreview();
        } catch (err) {
            this.toast('Could not save', this.msg(err), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    async handleDeleteRule(e) {
        const id = e.currentTarget.dataset.id;
        if (!id) return;
        this.isBusy = true;
        try {
            await deleteRule({ ruleId: id });
            await refreshApex(this._wiredRules);
        } catch (err) {
            this.toast('Could not delete', this.msg(err), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    // ── Preview ──

    async handlePreview() {
        this.previewOpen = !this.previewOpen;
        if (this.previewOpen) await this._runPreview();
    }

    async _runPreview() {
        try {
            const res = await preview({
                profileName: this.scopeProfile,
                outletType: this.scopeOutletType
            });
            this.previewRows = (res || []).map((r) => ({
                ...r,
                cls: 'vas-prev-row' + (r.visible ? '' : ' vas-prev-row_off'),
                mark: r.visible ? '✓' : '—'
            }));
        } catch (err) {
            this.previewRows = [];
            this.toast('Preview failed', this.msg(err), 'error');
        }
    }

    get visibleCount() {
        return this.previewRows.filter((r) => r.visible).length;
    }

    // ── Existing rules list ──

    get ruleList() {
        return (this.rules || []).map((r) => ({
            ...r,
            scopeText:
                (r.Profile_Name__c || 'All Profiles') +
                ' · ' +
                (r.Outlet_Type__c || 'All Outlet Types'),
            effectText: r.Is_Enabled__c ? 'Show' : 'Hide',
            effectClass: 'vas-badge ' + (r.Is_Enabled__c ? 'vas-badge_show' : 'vas-badge_hide'),
            inactive: !r.Is_Active__c
        }));
    }

    get hasRules() {
        return this.ruleList.length > 0;
    }

    // ── Helpers ──

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error.';
    }
}