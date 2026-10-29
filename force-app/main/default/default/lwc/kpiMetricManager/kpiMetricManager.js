import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllMetrics from '@salesforce/apex/DKD_MetricManager_Controller.getAllMetrics';
import getQueryableObjects from '@salesforce/apex/DKD_MetricManager_Controller.getQueryableObjects';
import getObjectFields from '@salesforce/apex/DKD_MetricManager_Controller.getObjectFields';
import saveMetric from '@salesforce/apex/DKD_MetricManager_Controller.saveMetric';
import deleteMetric from '@salesforce/apex/DKD_MetricManager_Controller.deleteMetric';
import getFieldMetadata from '@salesforce/apex/TAM_FieldMetadata_Service.getFields';

const EMPTY_FORM = {
    Id: null,
    Name: '',
    Metric_Key__c: '',
    Label__c: '',
    Description__c: '',
    Source_Object__c: '',
    Aggregation__c: 'COUNT',
    Aggregate_Field__c: '',
    Date_Field__c: '',
    User_Field__c: '',
    Default_Filter__c: '',
    Filters_JSON__c: '',
    Filter_Logic__c: '',
    Format__c: 'Number',
    Icon__c: '',
    Color__c: '',
    Category__c: 'Sales',
    Allow_Forecast__c: false,
    Is_Active__c: true,
    Sort_Order__c: null
};

export default class KpiMetricManager extends LightningElement {

    @track isLoading = true;
    @track metrics = [];
    @track showForm = false;
    @track isSaving = false;
    @track form = { ...EMPTY_FORM };

    @track objectOptions = [];
    @track dateFieldOptions = [];
    @track numberFieldOptions = [];
    @track userFieldOptions = [];
    @track fieldsMetadata = [];
    @track filters = [];
    @track autoFilterLogic = true;

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            const [metricsList, objects] = await Promise.all([
                getAllMetrics(),
                getQueryableObjects()
            ]);
            this.metrics = (metricsList || []).map(m => ({
                ...m,
                rowClass: m.Is_Active__c ? 'kmm-row' : 'kmm-row kmm-row-inactive',
                statusClass: m.Is_Active__c ? 'kmm-dot kmm-dot-active' : 'kmm-dot kmm-dot-inactive',
                statusLabel: m.Is_Active__c ? 'Active' : 'Inactive'
            }));
            this.objectOptions = objects.map(o => ({ label: o.label + ' (' + o.api + ')', value: o.api }));
        } catch (e) {
            this.toast('Error', this.err(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ===== GETTERS =====
    get hasMetrics() { return this.metrics.length > 0; }
    get formTitle() { return this.form.Id ? 'Edit Metric' : 'New Metric'; }
    get saveButtonLabel() { return this.isSaving ? 'Saving...' : 'Save'; }
    get noObjectSelected() { return !this.form.Source_Object__c; }
    get hasObjectSelected() { return !!this.form.Source_Object__c; }
    get aggregateFieldDisabled() { return !this.form.Source_Object__c || this.form.Aggregation__c === 'COUNT'; }

    get categoryOptions() {
        return [
            { label: 'Sales', value: 'Sales' },
            { label: 'Visits', value: 'Visits' },
            { label: 'Collections', value: 'Collections' },
            { label: 'Outlets', value: 'Outlets' },
            { label: 'Schemes', value: 'Schemes' },
            { label: 'Inventory', value: 'Inventory' },
            { label: 'Custom', value: 'Custom' }
        ];
    }

    get aggregationOptions() {
        return [
            { label: 'COUNT — count records', value: 'COUNT' },
            { label: 'SUM — total of a field', value: 'SUM' },
            { label: 'AVG — average of a field', value: 'AVG' },
            { label: 'MIN — minimum value', value: 'MIN' },
            { label: 'MAX — maximum value', value: 'MAX' }
        ];
    }

    get formatOptions() {
        return [
            { label: 'Number (1,234)', value: 'Number' },
            { label: 'Currency (₹1,234)', value: 'Currency' },
            { label: 'Percent (56.7%)', value: 'Percent' },
            { label: 'Duration (45 min)', value: 'Duration (minutes)' }
        ];
    }

    // ===== HANDLERS =====
    handleNew() {
        this.form = { ...EMPTY_FORM };
        this.dateFieldOptions = [];
        this.numberFieldOptions = [];
        this.userFieldOptions = [];
        this.fieldsMetadata = [];
        this.filters = [];
        this.autoFilterLogic = true;
        this.showForm = true;
    }

    handleEdit(event) {
        const id = event.currentTarget.dataset.id;
        const m = this.metrics.find(x => x.Id === id);
        if (!m) return;
        this.form = {
            Id: m.Id,
            Name: m.Name || '',
            Metric_Key__c: m.Metric_Key__c || '',
            Label__c: m.Label__c || '',
            Description__c: m.Description__c || '',
            Source_Object__c: m.Source_Object__c || '',
            Aggregation__c: m.Aggregation__c || 'COUNT',
            Aggregate_Field__c: m.Aggregate_Field__c || '',
            Date_Field__c: m.Date_Field__c || '',
            User_Field__c: m.User_Field__c || '',
            Default_Filter__c: m.Default_Filter__c || '',
            Filters_JSON__c: m.Filters_JSON__c || '',
            Filter_Logic__c: m.Filter_Logic__c || '',
            Format__c: m.Format__c || 'Number',
            Icon__c: m.Icon__c || '',
            Color__c: m.Color__c || '',
            Category__c: m.Category__c || 'Sales',
            Allow_Forecast__c: !!m.Allow_Forecast__c,
            Is_Active__c: m.Is_Active__c !== false,
            Sort_Order__c: m.Sort_Order__c
        };
        this.autoFilterLogic = !this.form.Filter_Logic__c;
        this.showForm = true;
        if (this.form.Source_Object__c) {
            this.loadFieldsForObject(this.form.Source_Object__c)
                .then(() => {
                    if (this.form.Filters_JSON__c) {
                        try {
                            const parsed = JSON.parse(this.form.Filters_JSON__c);
                            this.filters = parsed.filters || [];
                        } catch (e) {
                            this.filters = [];
                        }
                    } else {
                        this.filters = [];
                    }
                })
                .catch(e => {
                    this.filters = [];
                    this.toast('Error', 'Failed to load filter metadata: ' + this.err(e), 'error');
                });
        } else {
            this.filters = [];
        }
    }

    handleCloseForm() {
        this.showForm = false;
    }

    handleFormChange(event) {
        const field = event.target.dataset.field || event.currentTarget.dataset.field;
        this.form = { ...this.form, [field]: event.detail.value !== undefined ? event.detail.value : event.target.value };

        if (field === 'Name' && !this.form.Id && !this._keyManuallyEdited) {
            this.form = { ...this.form, Metric_Key__c: this.slugify(event.target.value || event.detail.value || '') };
        }
        if (field === 'Metric_Key__c') {
            this._keyManuallyEdited = true;
        }
        if (field === 'Name' && !this.form.Label__c) {
            this.form = { ...this.form, Label__c: event.target.value || event.detail.value || '' };
        }
    }

    handleCheckboxChange(event) {
        const field = event.target.dataset.field || event.currentTarget.dataset.field;
        this.form = { ...this.form, [field]: event.target.checked };
    }

    handleObjectChange(event) {
        const objApi = event.detail.value;
        this.form = { ...this.form, Source_Object__c: objApi, Date_Field__c: '', Aggregate_Field__c: '', User_Field__c: '', Filter_Logic__c: '' };
        this.filters = [];
        this.autoFilterLogic = true;
        if (objApi) {
            this.loadFieldsForObject(objApi);
        } else {
            this.dateFieldOptions = [];
            this.numberFieldOptions = [];
            this.userFieldOptions = [];
            this.fieldsMetadata = [];
        }
    }

    async loadFieldsForObject(objectApi) {
        try {
            const [result, metadata] = await Promise.all([
                getObjectFields({ objectApiName: objectApi }),
                getFieldMetadata({ objectName: objectApi })
            ]);
            const noSelection = [{ label: '-- None --', value: '' }];
            this.dateFieldOptions = noSelection.concat(
                (result.dateFields || []).map(f => ({ label: f.label, value: f.api }))
            );
            this.numberFieldOptions = noSelection.concat(
                (result.numberFields || []).map(f => ({ label: f.label, value: f.api }))
            );
            this.userFieldOptions = noSelection.concat(
                (result.userFields || []).map(f => ({ label: f.label, value: f.api }))
            );
            this.fieldsMetadata = metadata || [];
        } catch (e) {
            this.toast('Error', 'Failed to load fields: ' + this.err(e), 'error');
        }
    }

    async handleSave() {
        if (!this.form.Name || !this.form.Metric_Key__c || !this.form.Label__c
            || !this.form.Source_Object__c || !this.form.Date_Field__c) {
            this.toast('Validation', 'Please fill all required fields.', 'warning');
            return;
        }
        if (this.form.Aggregation__c !== 'COUNT' && !this.form.Aggregate_Field__c) {
            this.toast('Validation', 'Aggregate Field is required for ' + this.form.Aggregation__c + '.', 'warning');
            return;
        }

        this.isSaving = true;
        try {
            const payload = { ...this.form };
            if (!payload.Id) delete payload.Id;
            if (!payload.Sort_Order__c && payload.Sort_Order__c !== 0) payload.Sort_Order__c = null;
            if (this.filters.length > 0) {
                const cleanFilters = this.filters.map(f => ({
                    id: f.id, field: f.field, operator: f.operator, value: f.value, type: f.type
                }));
                payload.Filters_JSON__c = JSON.stringify({ filters: cleanFilters });
            } else {
                payload.Filters_JSON__c = '';
            }
            await saveMetric({ metric: payload });
            this.toast('Success', 'Metric "' + this.form.Label__c + '" saved.', 'success');
            this.showForm = false;
            this._keyManuallyEdited = false;
            await this.loadData();
        } catch (e) {
            this.toast('Save Failed', this.err(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        const m = this.metrics.find(x => x.Id === id);
        if (!m) return;
        // eslint-disable-next-line no-alert
        if (!confirm('Delete metric "' + m.Label__c + '"? This cannot be undone.')) return;
        try {
            await deleteMetric({ metricId: id });
            this.toast('Deleted', m.Label__c + ' has been removed.', 'success');
            await this.loadData();
        } catch (e) {
            this.toast('Delete Failed', this.err(e), 'error');
        }
    }

    // ===== FILTER HANDLERS =====
    handleFilterChange(event) {
        this.filters = event.detail || [];
        if (this.autoFilterLogic) {
            this.form = {
                ...this.form,
                Filter_Logic__c: this.filters.map(f => f.id).join(' AND ')
            };
        }
    }

    handleFilterLogicChange(event) {
        this.autoFilterLogic = false;
        this.form = { ...this.form, Filter_Logic__c: event.target.value };
    }

    get hasFilters() { return this.filters.length > 0; }
    get filterCount() { return this.filters.length; }

    // ===== HELPERS =====
    slugify(str) {
        return str.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    err(e) {
        if (!e) return 'Unknown error';
        if (typeof e === 'string') return e;
        if (e.body && e.body.message) return e.body.message;
        if (e.message) return e.message;
        return JSON.stringify(e);
    }
}