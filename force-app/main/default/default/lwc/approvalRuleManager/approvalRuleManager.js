import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getAllRules from '@salesforce/apex/ApprovalRuleController.getAllRules';
import getPicklistOptions from '@salesforce/apex/ApprovalRuleController.getPicklistOptions';
import getOperatorOptions from '@salesforce/apex/ApprovalRuleController.getOperatorOptions';
import saveRule from '@salesforce/apex/ApprovalRuleController.saveRule';
import deleteRule from '@salesforce/apex/ApprovalRuleController.deleteRule';
import searchUsers from '@salesforce/apex/ApprovalRuleController.searchUsers';
import migrateFromMetadata from '@salesforce/apex/ApprovalRuleController.migrateFromMetadata';
import getObjectFields from '@salesforce/apex/ApprovalRuleController.getObjectFields';
import getPicklistValues from '@salesforce/apex/ApprovalRuleController.getPicklistValues';
import simulate from '@salesforce/apex/ApprovalRouter.simulate';

const EMPTY_FORM = {
    Id: null,
    Object_Process__c: '',
    Approval_Level__c: 1,
    Approver_Type__c: '',
    User__c: null,
    Approver_Role_Queue__c: '',
    Auto_Approve__c: false,
    Approval_Mode__c: 'Sequential',
    Criteria_Logic__c: 'AND',
    Escalation_Hours__c: null,
    Escalation_Approver__c: null,
    Effective_From__c: null,
    Effective_To__c: null,
    Condition_Field__c: '',
    Min_Value__c: null,
    Max_Value__c: null,
    Status_Field_API_Name__c: 'Status__c',
    Status_Value_On_Submit__c: 'Submitted',
    Status_Value_On_Approve__c: 'Approved',
    Status_Value_On_Reject__c: 'Rejected',
    Is_Active__c: true,
    Description__c: ''
};

export default class ApprovalRuleManager extends LightningElement {
    @track rules = [];
    @track picklists = { Object_Process__c: [], Approver_Type__c: [] };
    @track form = { ...EMPTY_FORM };
    @track showModal = false;
    @track isEditing = false;
    @track isSaving = false;
    @track searchTerm = '';
    @track filterObject = 'all';
    @track userSearch = '';
    @track userResults = [];
    @track userSelectedName = '';

    // Dynamic field pickers — populated when Object/Process changes so the
    // admin picks fields from the actual schema instead of typing API names.
    @track allFieldOptions = [];
    @track statusFieldOptions = [];
    @track statusPicklistValues = [];

    // Multi-condition (Field/Operator/Value) rows
    @track conditionRows = [];
    @track operatorOptions = [];

    // Simulation — "who would approve this record, and why?"
    @track showSimulator = false;
    @track simulateRecordId = '';
    @track simulateResult = null;
    @track isSimulating = false;

    _wiredRules;
    _userSearchTimer;
    _condKeySeq = 0;

    @wire(getAllRules)
    wiredAll(result) {
        this._wiredRules = result;
        // Strip the managed-package (ftretailmake__) prefix from field keys so the
        // component's unqualified reads (r.Is_Active__c, r.Object_Process__c, …) work.
        if (result.data) this.rules = this._stripNs(result.data);
        if (result.error) this.toast('Error', this.errMsg(result.error), 'error');
    }

    // Recursively remove the org's managed-package namespace prefix from object
    // keys, so SObject data returned from Apex reads with unqualified field names.
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

    @wire(getPicklistOptions)
    wiredPicklists({ data, error }) {
        if (data) this.picklists = data;
        if (error) this.toast('Error', this.errMsg(error), 'error');
    }

    @wire(getOperatorOptions)
    wiredOps({ data, error }) {
        if (data) this.operatorOptions = data.map(o => ({ label: o.label, value: o.value }));
        if (error) this.toast('Error', this.errMsg(error), 'error');
    }

    get filterPills() {
        // Pills are built from the objects that actually HAVE rules, not from
        // the selectable object list — that list is now the whole org schema,
        // which would render hundreds of pills.
        const seen = [];
        this.rules.forEach(r => {
            if (r.Object_Process__c && !seen.includes(r.Object_Process__c)) {
                seen.push(r.Object_Process__c);
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
            cssClass: 'ar-filter-pill' + (p.key === this.filterObject ? ' ar-filter-active' : ''),
            dotClass: 'ar-filter-dot ar-filter-dot-' + p.dotColor
        }));
    }

    get filteredRules() {
        const term = this.searchTerm.toLowerCase();
        return this.rules
            .filter(r => this.filterObject === 'all' || r.Object_Process__c === this.filterObject)
            .filter(r => !term ||
                (r.Name || '').toLowerCase().includes(term) ||
                (r.Description__c || '').toLowerCase().includes(term) ||
                (r.Approver_Role_Queue__c || '').toLowerCase().includes(term))
            .map(r => ({
                ...r,
                levelBadge: 'L' + (r.Approval_Level__c || 1),
                statusClass: r.Is_Active__c ? 'ar-status ar-status-active' : 'ar-status ar-status-inactive',
                statusText: r.Is_Active__c ? 'Active' : 'Inactive',
                approverDisplay: this._approverDisplay(r),
                conditionDisplay: this._conditionDisplay(r),
                autoApproveClass: r.Auto_Approve__c ? 'ar-auto-badge ar-auto-on' : 'ar-auto-badge ar-auto-off',
                autoApproveText: r.Auto_Approve__c ? 'Auto-Approve' : 'Manual',
                modeText: r.Approval_Mode__c || 'Sequential',
                escalationText: r.Escalation_Hours__c
                    ? `Escalates after ${r.Escalation_Hours__c}h`
                    : 'No escalation',
                windowText: this._windowDisplay(r),
                isExpired: this._isExpired(r)
            }));
    }

    _windowDisplay(r) {
        const from = r.Effective_From__c;
        const to = r.Effective_To__c;
        if (!from && !to) return 'Always';
        if (from && to) return `${from} → ${to}`;
        if (from) return `From ${from}`;
        return `Until ${to}`;
    }

    _isExpired(r) {
        if (!r.Effective_To__c) return false;
        // Compare as plain ISO dates — both sides are yyyy-mm-dd.
        return r.Effective_To__c < new Date().toISOString().slice(0, 10);
    }

    _approverDisplay(r) {
        if (r.Approver_Type__c === 'User') {
            return (r.User__r && r.User__r.Name) || 'Specific User';
        }
        if (r.Approver_Role_Queue__c) {
            return `${r.Approver_Type__c}: ${r.Approver_Role_Queue__c}`;
        }
        return r.Approver_Type__c || '—';
    }

    _conditionDisplay(r) {
        // Prefer multi-condition list if any rows exist
        const conds = (r.Conditions__r && r.Conditions__r.length) ? r.Conditions__r : null;
        if (conds) {
            return conds
                .map(c => `${c.Field_API_Name__c} ${c.Operator__c} ${c.Value__c || ''}`.trim())
                .join('  AND  ');
        }
        // Fallback: legacy single-field range
        if (!r.Condition_Field__c) return 'Always';
        const min = r.Min_Value__c != null ? r.Min_Value__c : '';
        const max = r.Max_Value__c != null ? r.Max_Value__c : '';
        if (min !== '' && max !== '') return `${r.Condition_Field__c}: ${min} – ${max}`;
        if (min !== '') return `${r.Condition_Field__c} ≥ ${min}`;
        if (max !== '') return `${r.Condition_Field__c} ≤ ${max}`;
        return r.Condition_Field__c;
    }

    _newCondRow(c) {
        this._condKeySeq++;
        return {
            key: 'c' + this._condKeySeq,
            field: c ? (c.Field_API_Name__c || '') : '',
            operator: c ? (c.Operator__c || '') : '',
            value: c ? (c.Value__c || '') : ''
        };
    }

    get hasRules() { return this.filteredRules.length > 0; }
    get totalCount() { return this.rules.length; }
    get activeCount() { return this.rules.filter(r => r.Is_Active__c).length; }

    get objectProcessOptions() {
        return (this.picklists.Object_Process__c || []).map(p => ({ label: p.label, value: p.value }));
    }
    get approverTypeOptions() {
        return (this.picklists.Approver_Type__c || []).map(p => ({ label: p.label, value: p.value }));
    }
    get approvalModeOptions() {
        return (this.picklists.Approval_Mode__c || []).map(p => ({ label: p.label, value: p.value }));
    }
    get criteriaLogicOptions() {
        return (this.picklists.Criteria_Logic__c || []).map(p => ({ label: p.label, value: p.value }));
    }
    get hasMultipleConditions() {
        return this.conditionRows.length > 1;
    }

    get isApproverUser() { return this.form.Approver_Type__c === 'User'; }
    get isApproverRoleQueue() {
        return ['Role', 'Queue', 'Manager'].includes(this.form.Approver_Type__c);
    }
    get approverRoleQueueLabel() {
        const type = this.form.Approver_Type__c;
        if (type === 'Role') return 'Role Developer Name';
        if (type === 'Queue') return 'Queue Developer Name';
        if (type === 'Manager') return 'Reference (leave blank — resolves to owner\'s manager)';
        return 'Reference';
    }
    get saveDisabled() {
        if (this.isSaving) return true;
        if (!this.form.Object_Process__c) return true;
        if (!this.form.Approval_Level__c) return true;
        if (!this.form.Approver_Type__c) return true;
        if (this.form.Status_Field_API_Name__c) {
            const submit = (this.form.Status_Value_On_Submit__c || '').trim();
            const approve = (this.form.Status_Value_On_Approve__c || '').trim();
            const reject = (this.form.Status_Value_On_Reject__c || '').trim();
            if (!submit || !approve || !reject) return true;
        }
        return false;
    }
    get hasIncompleteStatusMapping() {
        if (!this.form.Status_Field_API_Name__c) return false;
        return !this.form.Status_Value_On_Submit__c
            || !this.form.Status_Value_On_Approve__c
            || !this.form.Status_Value_On_Reject__c;
    }
    get modalTitle() { return this.isEditing ? 'Edit Approval Rule' : 'New Approval Rule'; }

    handleAutoFillStatusValues() {
        if (!this.statusPicklistValues || !this.statusPicklistValues.length) return;
        const values = this.statusPicklistValues.map(v => v.value);
        const pick = candidates => candidates.find(c => values.includes(c)) || '';
        this.form = {
            ...this.form,
            Status_Value_On_Submit__c: pick(['Submitted', 'Pending', 'In_Review']),
            Status_Value_On_Approve__c: pick(['Approved']),
            Status_Value_On_Reject__c: pick(['Rejected', 'Cancelled'])
        };
    }

    handleFilter(event) { this.filterObject = event.currentTarget.dataset.key; }
    handleSearch(event) { this.searchTerm = event.target.value || ''; }

    handleNewClick() {
        this.form = { ...EMPTY_FORM };
        this.isEditing = false;
        this.userSelectedName = '';
        this.userSearch = '';
        this.userResults = [];
        this.allFieldOptions = [];
        this.statusFieldOptions = [];
        this.statusPicklistValues = [];
        this.conditionRows = [];
        this.showModal = true;
    }

    handleEditClick(event) {
        const id = event.currentTarget.dataset.id;
        const r = this.rules.find(x => x.Id === id);
        if (!r) return;
        this.form = {
            Id: r.Id,
            Object_Process__c: r.Object_Process__c || '',
            Approval_Level__c: r.Approval_Level__c || 1,
            Approver_Type__c: r.Approver_Type__c || '',
            User__c: r.User__c || null,
            Approver_Role_Queue__c: r.Approver_Role_Queue__c || '',
            Auto_Approve__c: !!r.Auto_Approve__c,
            Approval_Mode__c: r.Approval_Mode__c || 'Sequential',
            Criteria_Logic__c: r.Criteria_Logic__c || 'AND',
            Escalation_Hours__c: r.Escalation_Hours__c,
            Escalation_Approver__c: r.Escalation_Approver__c || null,
            Effective_From__c: r.Effective_From__c || null,
            Effective_To__c: r.Effective_To__c || null,
            Condition_Field__c: r.Condition_Field__c || '',
            Min_Value__c: r.Min_Value__c,
            Max_Value__c: r.Max_Value__c,
            Status_Field_API_Name__c: r.Status_Field_API_Name__c || '',
            Status_Value_On_Submit__c: r.Status_Value_On_Submit__c || '',
            Status_Value_On_Approve__c: r.Status_Value_On_Approve__c || '',
            Status_Value_On_Reject__c: r.Status_Value_On_Reject__c || '',
            Is_Active__c: !!r.Is_Active__c,
            Description__c: r.Description__c || ''
        };
        this.userSelectedName = (r.User__r && r.User__r.Name) || '';
        this.userSearch = this.userSelectedName;
        this.userResults = [];
        // Hydrate condition rows from the rule's child Conditions__r
        const conds = (r.Conditions__r && r.Conditions__r.length) ? r.Conditions__r : [];
        this.conditionRows = conds.map(c => this._newCondRow(c));
        this.isEditing = true;
        this._loadFieldsForObject(r.Object_Process__c);
        this.showModal = true;
    }

    handleCloseModal() { this.showModal = false; }

    // ── Dynamic field pickers ──
    async _loadFieldsForObject(objectName) {
        if (!objectName) {
            this.allFieldOptions = [];
            this.statusFieldOptions = [];
            this.statusPicklistValues = [];
            return;
        }
        try {
            const [allFields, statusFields] = await Promise.all([
                // Empty filter = all readable fields, for the multi-condition rows
                getObjectFields({ objectName, fieldTypeFilter: '' }),
                getObjectFields({ objectName, fieldTypeFilter: 'status' })
            ]);
            this.allFieldOptions = (allFields || []).map(f => ({
                label: f.label + ' (' + f.value + ')',
                value: f.value
            }));
            this.statusFieldOptions = (statusFields || []).map(f => ({
                label: f.label + ' (' + f.value + ')',
                value: f.value,
                type: f.type
            }));
            if (this.form.Status_Field_API_Name__c) {
                await this._loadPicklistValues(objectName, this.form.Status_Field_API_Name__c);
            }
        } catch (e) {
            this.allFieldOptions = [];
            this.statusFieldOptions = [];
            this.statusPicklistValues = [];
        }
    }

    async _loadPicklistValues(objectName, fieldName) {
        if (!objectName || !fieldName) {
            this.statusPicklistValues = [];
            return;
        }
        try {
            const values = await getPicklistValues({ objectName, fieldName });
            this.statusPicklistValues = (values || []).map(v => ({
                label: v.label, value: v.value
            }));
        } catch (e) {
            this.statusPicklistValues = [];
        }
    }

    handleObjectProcessChange(event) {
        const objectName = event.detail.value;
        this.form = {
            ...this.form,
            Object_Process__c: objectName,
            Condition_Field__c: '',
            Status_Field_API_Name__c: '',
            Status_Value_On_Submit__c: '',
            Status_Value_On_Approve__c: '',
            Status_Value_On_Reject__c: ''
        };
        this.statusPicklistValues = [];
        // Clear conditions — they reference fields that may not exist on the new object
        this.conditionRows = [];
        this._loadFieldsForObject(objectName);
    }

    handleStatusFieldChange(event) {
        const fieldName = event.detail.value;
        this.form = {
            ...this.form,
            Status_Field_API_Name__c: fieldName,
            Status_Value_On_Submit__c: '',
            Status_Value_On_Approve__c: '',
            Status_Value_On_Reject__c: ''
        };
        this._loadPicklistValues(this.form.Object_Process__c, fieldName);
    }

    handleStatusValueChange(event) {
        const field = event.target.dataset.field;
        this.form = { ...this.form, [field]: event.detail.value };
    }

    get statusValueOptions() {
        return this.statusPicklistValues;
    }
    get hasStatusPicklistValues() {
        return this.statusPicklistValues && this.statusPicklistValues.length > 0;
    }

    // ── Condition rows ──
    handleAddCondition() {
        this.conditionRows = [...this.conditionRows, this._newCondRow(null)];
    }

    handleRemoveCondition(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        this.conditionRows = this.conditionRows.filter((_, i) => i !== idx);
    }

    handleConditionChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const key = event.currentTarget.dataset.key;
        const value = event.detail ? event.detail.value : event.target.value;
        this.conditionRows = this.conditionRows.map((row, i) =>
            i === idx ? { ...row, [key]: value } : row
        );
    }

    handleFormChange(event) {
        const field = event.target.dataset.field;
        const type = event.target.type;
        let value = event.target.value;
        if (type === 'checkbox') value = event.target.checked;
        if (type === 'number') value = value === '' ? null : Number(value);
        this.form = { ...this.form, [field]: value };
    }

    handleApproverTypeChange(event) {
        this.form = {
            ...this.form,
            Approver_Type__c: event.detail.value,
            User__c: null,
            Approver_Role_Queue__c: ''
        };
        this.userSelectedName = '';
        this.userSearch = '';
        this.userResults = [];
    }

    handleUserSearch(event) {
        const term = event.target.value || '';
        this.userSearch = term;
        if (this._userSearchTimer) clearTimeout(this._userSearchTimer);
        if (term.length < 2) { this.userResults = []; return; }
        this._userSearchTimer = setTimeout(() => this._doUserSearch(term), 250);
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
        this.form = { ...this.form, User__c: user.value };
        this.userSelectedName = user.label;
        this.userSearch = user.label;
        this.userResults = [];
    }

    handleUserClear() {
        this.form = { ...this.form, User__c: null };
        this.userSelectedName = '';
        this.userSearch = '';
        this.userResults = [];
    }

    async handleSave() {
        if (this.saveDisabled) return;
        this.isSaving = true;
        try {
            const conditions = this.conditionRows
                .filter(c => c.field && c.operator)
                .map(c => ({
                    sobjectType: 'Approval_Rule_Condition__c',
                    Field_API_Name__c: c.field,
                    Operator__c: c.operator,
                    Value__c: c.value || ''
                }));
            await saveRule({
                ruleJson: JSON.stringify(this.form),
                conditionsJson: JSON.stringify(conditions)
            });
            this.toast('Saved', this.isEditing ? 'Approval rule updated.' : 'Approval rule created.', 'success');
            this.showModal = false;
            await refreshApex(this._wiredRules);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isSaving = false;
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        if (!confirm('Delete this approval rule?')) return;
        try {
            await deleteRule({ ruleId: id });
            this.toast('Deleted', 'Approval rule removed.', 'success');
            await refreshApex(this._wiredRules);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    async handleToggleActive(event) {
        const id = event.currentTarget.dataset.id;
        const r = this.rules.find(x => x.Id === id);
        if (!r) return;
        try {
            // Pass existing conditions through unchanged so the toggle doesn't wipe them.
            const conditions = (r.Conditions__r || []).map(c => ({
                sobjectType: 'Approval_Rule_Condition__c',
                Field_API_Name__c: c.Field_API_Name__c,
                Operator__c: c.Operator__c,
                Value__c: c.Value__c
            }));
            await saveRule({
                ruleJson: JSON.stringify({ Id: r.Id, Is_Active__c: !r.Is_Active__c }),
                conditionsJson: JSON.stringify(conditions)
            });
            await refreshApex(this._wiredRules);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    async handleMigrate() {
        if (!confirm('Import all existing Approval_Matrix__mdt records into this tab? Rules already in place for the same object + level will be skipped.')) return;
        try {
            const count = await migrateFromMetadata();
            this.toast('Imported', `${count} legacy record(s) imported.`, 'success');
            await refreshApex(this._wiredRules);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    // ── Simulation ──
    // The gap between "I configured a matrix" and "I trust the matrix" is
    // answered by showing exactly who would approve a real record and which
    // rules were skipped, without creating an approval request.

    handleOpenSimulator() {
        this.simulateRecordId = '';
        this.simulateResult = null;
        this.showSimulator = true;
    }

    handleCloseSimulator() { this.showSimulator = false; }

    handleSimulateIdChange(event) {
        this.simulateRecordId = (event.target.value || '').trim();
    }

    get simulateDisabled() {
        return this.isSimulating || this.simulateRecordId.length < 15;
    }

    async handleRunSimulation() {
        if (this.simulateDisabled) return;
        this.isSimulating = true;
        this.simulateResult = null;
        try {
            const res = await simulate({ recordId: this.simulateRecordId });
            this.simulateResult = {
                ...res,
                matched: (res.matched || []).map((m, i) => ({
                    ...m,
                    key: 'm' + i,
                    approverLabel: m.approverName
                        || (m.autoApprove ? 'Auto-approved — no approver needed' : 'Unresolved'),
                    rowClass: m.warning ? 'ar-sim-row ar-sim-warn' : 'ar-sim-row'
                })),
                skipped: (res.skipped || []).map((s, i) => ({ ...s, key: 's' + i })),
                hasMatched: (res.matched || []).length > 0,
                hasSkipped: (res.skipped || []).length > 0
            };
        } catch (e) {
            this.toast('Simulation failed', this.errMsg(e), 'error');
        }
        this.isSimulating = false;
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