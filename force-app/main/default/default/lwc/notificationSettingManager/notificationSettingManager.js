import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getAllSettings from '@salesforce/apex/NotificationSettingController.getAllSettings';
import getPicklistOptions from '@salesforce/apex/NotificationSettingController.getPicklistOptions';
import saveSetting from '@salesforce/apex/NotificationSettingController.saveSetting';
import deleteSetting from '@salesforce/apex/NotificationSettingController.deleteSetting';
import searchUsers from '@salesforce/apex/NotificationSettingController.searchUsers';
import testFireRule from '@salesforce/apex/NotificationSettingController.testFireRule';
import getObjectFields from '@salesforce/apex/NotificationSettingController.getObjectFields';
import getRecentLogs from '@salesforce/apex/NotificationSettingController.getRecentLogs';

const EMPTY_FORM = {
    Id: null,
    Event_Object__c: '',
    Event_Type__c: '',
    Recipient_Type__c: '',
    Recipient_User__c: null,
    Recipient_Reference__c: '',
    Recipient_Field__c: '',
    Additional_Emails__c: '',
    Criteria_Field__c: '',
    Criteria_Operator__c: '',
    Criteria_Value__c: '',
    Channel_Email__c: false,
    Channel_InApp__c: true,
    Channel_WhatsApp__c: false,
    Channel_SMS__c: false,
    Subject_Template__c: '',
    Body_Template__c: '',
    Is_Active__c: true,
    Description__c: ''
};

export default class NotificationSettingManager extends LightningElement {
    @track settings = [];
    @track picklists = { Event_Object__c: [], Event_Type__c: [], Recipient_Type__c: [] };
    @track form = { ...EMPTY_FORM };
    @track showModal = false;
    @track isEditing = false;
    @track isLoading = false;
    @track isSaving = false;
    @track searchTerm = '';
    @track filterObject = 'all';
    @track userSearch = '';
    @track userResults = [];
    @track userSelectedName = '';

    // Field pickers populated from the selected Event Object's schema, so the
    // admin chooses real fields instead of typing API names from memory.
    @track allFieldOptions = [];
    @track userLookupFieldOptions = [];

    // Delivery log — the answer to "why didn't my alert arrive?"
    @track showLogs = false;
    @track logs = [];
    @track isLoadingLogs = false;

    _wiredSettings;
    _userSearchTimer;

    @wire(getAllSettings)
    wiredAll(result) {
        this._wiredSettings = result;
        if (result.data) this.settings = result.data;
        if (result.error) this.toast('Error', this.errMsg(result.error), 'error');
    }

    @wire(getPicklistOptions)
    wiredPicklists({ data, error }) {
        if (data) this.picklists = data;
        if (error) this.toast('Error', this.errMsg(error), 'error');
    }

    // ── Filters ──
    get filterPills() {
        // Built from the objects that actually have settings, not the
        // selectable object list — that list is now the whole org schema.
        const seen = [];
        this.settings.forEach(s => {
            if (s.Event_Object__c && !seen.includes(s.Event_Object__c)) {
                seen.push(s.Event_Object__c);
            }
        });
        seen.sort();
        const all = [{ key: 'all', label: 'All', dotColor: 'gray' }];
        const dots = ['blue', 'green', 'orange', 'purple', 'teal', 'red'];
        seen.forEach((api, i) => {
            all.push({ key: api, label: api, dotColor: dots[i % dots.length] });
        });
        return all.map(p => ({
            key: p.key,
            label: p.label,
            cssClass: 'ns-filter-pill' + (p.key === this.filterObject ? ' ns-filter-active' : ''),
            dotClass: 'ns-filter-dot ns-filter-dot-' + p.dotColor
        }));
    }

    get filteredSettings() {
        const term = this.searchTerm.toLowerCase();
        return this.settings
            .filter(s => this.filterObject === 'all' || s.Event_Object__c === this.filterObject)
            .filter(s => !term ||
                (s.Name || '').toLowerCase().includes(term) ||
                (s.Subject_Template__c || '').toLowerCase().includes(term) ||
                (s.Description__c || '').toLowerCase().includes(term))
            .map(s => ({
                ...s,
                channels: this._channelBadges(s),
                statusClass: s.Is_Active__c ? 'ns-status ns-status-active' : 'ns-status ns-status-inactive',
                statusText: s.Is_Active__c ? 'Active' : 'Inactive',
                recipientDisplay: this._recipientDisplay(s),
                criteriaDisplay: this._criteriaDisplay(s)
            }));
    }

    _criteriaDisplay(s) {
        if (!s.Criteria_Field__c || !s.Criteria_Operator__c) return 'Every record';
        const needsValue = !['is null', 'is not null'].includes(s.Criteria_Operator__c);
        return needsValue
            ? `${s.Criteria_Field__c} ${s.Criteria_Operator__c} ${s.Criteria_Value__c || ''}`.trim()
            : `${s.Criteria_Field__c} ${s.Criteria_Operator__c}`;
    }

    _channelBadges(s) {
        const out = [];
        if (s.Channel_Email__c) out.push({ key: 'email', label: 'Email', cls: 'ns-channel ns-channel-email' });
        if (s.Channel_InApp__c) out.push({ key: 'inapp', label: 'In-App', cls: 'ns-channel ns-channel-inapp' });
        if (s.Channel_WhatsApp__c) out.push({ key: 'wa', label: 'WhatsApp', cls: 'ns-channel ns-channel-wa' });
        if (s.Channel_SMS__c) out.push({ key: 'sms', label: 'SMS', cls: 'ns-channel ns-channel-sms' });
        return out;
    }

    _recipientDisplay(s) {
        if (s.Recipient_Type__c === 'Specific User') {
            return (s.Recipient_User__r && s.Recipient_User__r.Name) || 'Specific User';
        }
        if (s.Recipient_Reference__c) {
            return `${s.Recipient_Type__c}: ${s.Recipient_Reference__c}`;
        }
        return s.Recipient_Type__c || '—';
    }

    get hasSettings() { return this.filteredSettings.length > 0; }
    get totalCount() { return this.settings.length; }
    get activeCount() { return this.settings.filter(s => s.Is_Active__c).length; }

    // ── Picklist options for combobox ──
    get eventObjectOptions() {
        return (this.picklists.Event_Object__c || []).map(p => ({ label: p.label, value: p.value }));
    }
    get eventTypeOptions() {
        return (this.picklists.Event_Type__c || []).map(p => ({ label: p.label, value: p.value }));
    }
    get recipientTypeOptions() {
        return (this.picklists.Recipient_Type__c || []).map(p => ({ label: p.label, value: p.value }));
    }

    get criteriaOperatorOptions() {
        return (this.picklists.Criteria_Operator__c || []).map(p => ({ label: p.label, value: p.value }));
    }

    get isRecipientUser() { return this.form.Recipient_Type__c === 'Specific User'; }
    get isRecipientReference() {
        return ['Role', 'Profile', 'Public Group', 'Queue'].includes(this.form.Recipient_Type__c);
    }
    get isRecipientField() { return this.form.Recipient_Type__c === 'Field on Record'; }
    get recipientReferenceLabel() {
        const type = this.form.Recipient_Type__c;
        if (type === 'Role') return 'Role Developer Name';
        if (type === 'Profile') return 'Profile Name';
        if (type === 'Public Group') return 'Public Group Developer Name';
        if (type === 'Queue') return 'Queue Developer Name';
        return 'Reference';
    }
    get criteriaNeedsValue() {
        return !!this.form.Criteria_Operator__c
            && !['is null', 'is not null'].includes(this.form.Criteria_Operator__c);
    }
    get hasNoObjectSelected() { return !this.form.Event_Object__c; }
    get saveDisabled() {
        return this.isSaving ||
            !this.form.Event_Object__c ||
            !this.form.Event_Type__c ||
            !this.form.Recipient_Type__c ||
            !this.form.Subject_Template__c ||
            !this.form.Subject_Template__c.trim() ||
            !(this.form.Channel_Email__c || this.form.Channel_InApp__c ||
              this.form.Channel_WhatsApp__c || this.form.Channel_SMS__c);
    }
    get modalTitle() { return this.isEditing ? 'Edit Notification Rule' : 'New Notification Rule'; }

    // ── Event handlers ──
    handleFilter(event) { this.filterObject = event.currentTarget.dataset.key; }
    handleSearch(event) { this.searchTerm = event.target.value || ''; }

    handleNewClick() {
        this.form = { ...EMPTY_FORM };
        this.isEditing = false;
        this.userSelectedName = '';
        this.userSearch = '';
        this.userResults = [];
        this.allFieldOptions = [];
        this.userLookupFieldOptions = [];
        this.showModal = true;
    }

    // ── Dynamic field pickers ──
    async _loadFieldsForObject(objectName) {
        if (!objectName) {
            this.allFieldOptions = [];
            this.userLookupFieldOptions = [];
            return;
        }
        try {
            const [allFields, refFields] = await Promise.all([
                getObjectFields({ objectName, fieldTypeFilter: '' }),
                getObjectFields({ objectName, fieldTypeFilter: 'reference' })
            ]);
            this.allFieldOptions = (allFields || []).map(f => ({
                label: `${f.label} (${f.value})`, value: f.value
            }));
            this.userLookupFieldOptions = (refFields || []).map(f => ({
                label: `${f.label} (${f.value})`, value: f.value
            }));
        } catch (e) {
            this.allFieldOptions = [];
            this.userLookupFieldOptions = [];
        }
    }

    handleEventObjectChange(event) {
        const objectName = event.detail.value;
        // Criteria and recipient fields reference the old object's schema, so
        // clear them rather than leave a rule that can never match.
        this.form = {
            ...this.form,
            Event_Object__c: objectName,
            Criteria_Field__c: '',
            Criteria_Operator__c: '',
            Criteria_Value__c: '',
            Recipient_Field__c: ''
        };
        this._loadFieldsForObject(objectName);
    }

    handleComboChange(event) {
        const field = event.target.dataset.field;
        this.form = { ...this.form, [field]: event.detail.value };
    }

    handleEditClick(event) {
        const id = event.currentTarget.dataset.id;
        const setting = this.settings.find(s => s.Id === id);
        if (!setting) return;
        this.form = {
            Id: setting.Id,
            Event_Object__c: setting.Event_Object__c || '',
            Event_Type__c: setting.Event_Type__c || '',
            Recipient_Type__c: setting.Recipient_Type__c || '',
            Recipient_User__c: setting.Recipient_User__c || null,
            Recipient_Reference__c: setting.Recipient_Reference__c || '',
            Recipient_Field__c: setting.Recipient_Field__c || '',
            Additional_Emails__c: setting.Additional_Emails__c || '',
            Criteria_Field__c: setting.Criteria_Field__c || '',
            Criteria_Operator__c: setting.Criteria_Operator__c || '',
            Criteria_Value__c: setting.Criteria_Value__c || '',
            Channel_Email__c: !!setting.Channel_Email__c,
            Channel_InApp__c: !!setting.Channel_InApp__c,
            Channel_WhatsApp__c: !!setting.Channel_WhatsApp__c,
            Channel_SMS__c: !!setting.Channel_SMS__c,
            Subject_Template__c: setting.Subject_Template__c || '',
            Body_Template__c: setting.Body_Template__c || '',
            Is_Active__c: !!setting.Is_Active__c,
            Description__c: setting.Description__c || ''
        };
        this.userSelectedName = (setting.Recipient_User__r && setting.Recipient_User__r.Name) || '';
        this.userSearch = this.userSelectedName;
        this.userResults = [];
        this.isEditing = true;
        this._loadFieldsForObject(setting.Event_Object__c);
        this.showModal = true;
    }

    handleCloseModal() { this.showModal = false; }

    // ── Delivery log ──
    async handleOpenLogs() {
        this.showLogs = true;
        this.isLoadingLogs = true;
        try {
            const rows = await getRecentLogs({ rowLimit: 50 });
            this.logs = (rows || []).map(l => ({
                id: l.Id,
                channel: l.Channel__c,
                status: l.Status__c,
                eventType: l.Event_Type__c,
                subject: l.Subject__c,
                error: l.Error_Message__c,
                sentAt: l.Sent_At__c,
                recipient: (l.Recipient_User__r && l.Recipient_User__r.Name) || '—',
                ruleName: (l.Notification_Setting__r && l.Notification_Setting__r.Name) || '—',
                statusClass: l.Status__c === 'Sent'
                    ? 'ns-status ns-status-active'
                    : 'ns-status ns-status-inactive'
            }));
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
            this.logs = [];
        }
        this.isLoadingLogs = false;
    }

    handleCloseLogs() { this.showLogs = false; }

    get hasLogs() { return this.logs.length > 0; }

    handleFormChange(event) {
        const field = event.target.dataset.field;
        const type = event.target.type;
        let value = event.target.value;
        if (type === 'checkbox') value = event.target.checked;
        this.form = { ...this.form, [field]: value };
    }

    handleRecipientTypeChange(event) {
        this.form = {
            ...this.form,
            Recipient_Type__c: event.detail.value,
            Recipient_User__c: null,
            Recipient_Reference__c: ''
        };
        this.userSelectedName = '';
        this.userSearch = '';
        this.userResults = [];
    }

    handleUserSearch(event) {
        const term = event.target.value || '';
        this.userSearch = term;
        if (this._userSearchTimer) clearTimeout(this._userSearchTimer);
        this._userSearchTimer = setTimeout(() => this._doUserSearch(term), 250);
    }

    handleUserFocus() {
        if (this._userBlurTimer) clearTimeout(this._userBlurTimer);
        if (!this.userResults || this.userResults.length === 0) {
            this._doUserSearch(this.userSearch || '');
        }
    }

    handleUserBlur() {
        if (this._userBlurTimer) clearTimeout(this._userBlurTimer);
        this._userBlurTimer = setTimeout(() => {
            this.userResults = [];
        }, 200);
    }

    async _doUserSearch(term) {
        try {
            this.userResults = await searchUsers({ searchTerm: term });
        } catch (e) {
            this.userResults = [];
        }
    }

    handleUserSelect(event) {
        const id = event.currentTarget.dataset.id;
        const user = this.userResults.find(u => u.value === id);
        if (!user) return;
        this.form = { ...this.form, Recipient_User__c: user.value };
        this.userSelectedName = user.label;
        this.userSearch = user.label;
        this.userResults = [];
    }

    handleUserClear() {
        this.form = { ...this.form, Recipient_User__c: null };
        this.userSelectedName = '';
        this.userSearch = '';
        this.userResults = [];
    }

    async handleSave() {
        if (this.saveDisabled) return;
        this.isSaving = true;
        try {
            await saveSetting({ setting: { sobjectType: 'Notification_Setting__c', ...this.form } });
            this.toast('Saved', this.isEditing ? 'Rule updated.' : 'Rule created.', 'success');
            this.showModal = false;
            await refreshApex(this._wiredSettings);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isSaving = false;
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        if (!confirm('Delete this notification rule?')) return;
        try {
            await deleteSetting({ settingId: id });
            this.toast('Deleted', 'Rule removed.', 'success');
            await refreshApex(this._wiredSettings);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    async handleTestFire(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        try {
            const msg = await testFireRule({ settingId: id });
            this.toast('Test fired', msg, 'success');
            await refreshApex(this._wiredSettings);
        } catch (e) {
            this.toast('Test failed', this.errMsg(e), 'error');
        }
    }

    async handleToggleActive(event) {
        const id = event.currentTarget.dataset.id;
        const setting = this.settings.find(s => s.Id === id);
        if (!setting) return;
        try {
            await saveSetting({
                setting: {
                    sobjectType: 'Notification_Setting__c',
                    Id: setting.Id,
                    Is_Active__c: !setting.Is_Active__c
                }
            });
            await refreshApex(this._wiredSettings);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    errMsg(e) {
        if (!e) return 'Unknown error';
        if (e.body && e.body.message) return e.body.message;
        if (Array.isArray(e.body)) return e.body.map(x => x.message).join(', ');
        if (e.message) return e.message;
        return JSON.stringify(e);
    }
}