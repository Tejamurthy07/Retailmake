import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getAllAdjustments from '@salesforce/apex/StockAdjustmentController.getAllAdjustments';
import getPicklistOptions from '@salesforce/apex/StockAdjustmentController.getPicklistOptions';
import saveDraft from '@salesforce/apex/StockAdjustmentController.saveDraft';
import deleteAdjustment from '@salesforce/apex/StockAdjustmentController.deleteAdjustment';
import submitForApproval from '@salesforce/apex/StockAdjustmentController.submitForApproval';
import searchWarehouses from '@salesforce/apex/StockAdjustmentController.searchWarehouses';
import searchProducts from '@salesforce/apex/StockAdjustmentController.searchProducts';
import getStockInfo from '@salesforce/apex/StockAdjustmentController.getStockInfo';

const EMPTY_FORM = {
    Id: null,
    Warehouse__c: null,
    Product__c: null,
    Batch_Number__c: '',
    System_Qty__c: 0,
    Actual_Qty__c: null,
    Adjustment_Qty__c: 0,
    Adjustment_Type__c: '',
    Reason__c: '',
    Adjustment_Date__c: null,
    Status__c: 'Draft'
};

export default class StockAdjustmentManager extends NavigationMixin(LightningElement) {
    @track adjustments = [];
    @track picklists = { Adjustment_Type__c: [] };
    @track filterStatus = 'all';
    @track searchTerm = '';

    @track showModal = false;
    @track isEditing = false;
    @track isSaving = false;
    @track form = { ...EMPTY_FORM };

    // Warehouse / Product picker state
    @track warehouseSearch = '';
    @track warehouseResults = [];
    @track warehouseSelectedName = '';
    @track productSearch = '';
    @track productResults = [];
    @track productSelectedName = '';
    @track stockInfo = null;

    @track showSubmitModal = false;
    @track submitTargetId = null;
    @track submitTargetName = '';
    @track submitComments = '';
    @track isSubmitting = false;

    _wiredAdjustments;
    _whSearchTimer;
    _prodSearchTimer;

    @wire(getAllAdjustments)
    wiredAll(result) {
        this._wiredAdjustments = result;
        if (result.data) this.adjustments = result.data;
        if (result.error) this.toast('Error', this.errMsg(result.error), 'error');
    }

    @wire(getPicklistOptions)
    wiredPicklists({ data, error }) {
        if (data) this.picklists = data;
        if (error) this.toast('Error', this.errMsg(error), 'error');
    }

    get totalCount() { return this.adjustments.length; }
    get draftCount() { return this.adjustments.filter(a => a.Status__c === 'Draft').length; }
    get submittedCount() { return this.adjustments.filter(a => a.Status__c === 'Submitted').length; }
    get approvedCount() { return this.adjustments.filter(a => a.Status__c === 'Approved').length; }

    get statusPills() {
        const map = [
            { key: 'all', label: 'All', count: this.totalCount, dot: 'gray' },
            { key: 'Draft', label: 'Draft', count: this.draftCount, dot: 'blue' },
            { key: 'Submitted', label: 'Submitted', count: this.submittedCount, dot: 'orange' },
            { key: 'Approved', label: 'Approved', count: this.approvedCount, dot: 'green' },
            { key: 'Rejected', label: 'Rejected',
              count: this.adjustments.filter(a => a.Status__c === 'Rejected').length, dot: 'red' }
        ];
        return map.map(p => ({
            ...p,
            cssClass: 'sa-pill' + (p.key === this.filterStatus ? ' sa-pill-active' : ''),
            dotClass: 'sa-pill-dot sa-pill-dot-' + p.dot
        }));
    }

    get filteredAdjustments() {
        const term = this.searchTerm.toLowerCase();
        return this.adjustments
            .filter(a => this.filterStatus === 'all' || a.Status__c === this.filterStatus)
            .filter(a => !term ||
                (a.Name || '').toLowerCase().includes(term) ||
                ((a.Product__r && a.Product__r.Name) || '').toLowerCase().includes(term) ||
                ((a.Warehouse__r && a.Warehouse__r.Name) || '').toLowerCase().includes(term) ||
                (a.Batch_Number__c || '').toLowerCase().includes(term))
            .map(a => this._decorate(a));
    }

    _decorate(a) {
        const adj = a.Adjustment_Qty__c == null ? 0 : a.Adjustment_Qty__c;
        const sign = adj > 0 ? '+' : '';
        let statusClass = 'sa-status sa-status-draft';
        if (a.Status__c === 'Submitted') statusClass = 'sa-status sa-status-submitted';
        else if (a.Status__c === 'Approved') statusClass = 'sa-status sa-status-approved';
        else if (a.Status__c === 'Rejected') statusClass = 'sa-status sa-status-rejected';
        return {
            ...a,
            adjustmentDisplay: sign + adj,
            adjustmentClass: adj > 0 ? 'sa-adj sa-adj-pos' :
                              adj < 0 ? 'sa-adj sa-adj-neg' : 'sa-adj',
            statusClass,
            warehouseName: (a.Warehouse__r && a.Warehouse__r.Name) || '—',
            productName: (a.Product__r && a.Product__r.Name) || '—',
            productCode: (a.Product__r && a.Product__r.ProductCode) || '',
            typeLabel: this._typeLabel(a.Adjustment_Type__c),
            canEdit: a.Status__c === 'Draft',
            canDelete: a.Status__c === 'Draft',
            canSubmit: a.Status__c === 'Draft'
        };
    }

    _typeLabel(value) {
        const opt = (this.picklists.Adjustment_Type__c || []).find(o => o.value === value);
        return opt ? opt.label : (value || '—');
    }

    get hasItems() { return this.filteredAdjustments.length > 0; }
    get adjustmentTypeOptions() {
        return (this.picklists.Adjustment_Type__c || []).map(p => ({ label: p.label, value: p.value }));
    }
    get modalTitle() { return this.isEditing ? 'Edit Adjustment' : 'New Stock Adjustment'; }

    get computedAdjustmentQty() {
        const actual = Number(this.form.Actual_Qty__c);
        const system = Number(this.form.System_Qty__c);
        if (isNaN(actual) || isNaN(system)) return 0;
        return actual - system;
    }
    get adjustmentDisplay() {
        const q = this.computedAdjustmentQty;
        return (q > 0 ? '+' : '') + q;
    }
    get adjustmentRowClass() {
        const q = this.computedAdjustmentQty;
        return q > 0 ? 'sa-form-adj sa-adj-pos' :
               q < 0 ? 'sa-form-adj sa-adj-neg' : 'sa-form-adj';
    }
    get hasStockInfo() { return this.stockInfo && this.stockInfo.exists; }
    get saveDisabled() {
        return this.isSaving ||
            !this.form.Warehouse__c ||
            !this.form.Product__c ||
            !this.form.Adjustment_Type__c ||
            !this.form.Reason__c ||
            this.form.Actual_Qty__c == null || this.form.Actual_Qty__c === '';
    }

    // ── Filter / search ─────────────────────────────────────────────
    handleFilter(event) { this.filterStatus = event.currentTarget.dataset.key; }
    handleSearch(event) { this.searchTerm = event.target.value || ''; }

    // ── New / Edit ──────────────────────────────────────────────────
    handleNewClick() {
        this.form = { ...EMPTY_FORM, Adjustment_Date__c: this._today() };
        this.isEditing = false;
        this._resetPickers();
        this.showModal = true;
    }

    handleEditClick(event) {
        const id = event.currentTarget.dataset.id;
        const a = this.adjustments.find(x => x.Id === id);
        if (!a) return;
        this.form = {
            Id: a.Id,
            Warehouse__c: a.Warehouse__c,
            Product__c: a.Product__c,
            Batch_Number__c: a.Batch_Number__c || '',
            System_Qty__c: a.System_Qty__c == null ? 0 : a.System_Qty__c,
            Actual_Qty__c: a.Actual_Qty__c,
            Adjustment_Qty__c: a.Adjustment_Qty__c == null ? 0 : a.Adjustment_Qty__c,
            Adjustment_Type__c: a.Adjustment_Type__c || '',
            Reason__c: a.Reason__c || '',
            Adjustment_Date__c: a.Adjustment_Date__c,
            Status__c: a.Status__c
        };
        this.warehouseSelectedName = (a.Warehouse__r && a.Warehouse__r.Name) || '';
        this.warehouseSearch = this.warehouseSelectedName;
        this.productSelectedName = (a.Product__r && a.Product__r.Name) || '';
        this.productSearch = this.productSelectedName;
        this.warehouseResults = [];
        this.productResults = [];
        this.stockInfo = null;
        this.isEditing = true;
        this.showModal = true;
    }

    handleCloseModal() { this.showModal = false; }

    _resetPickers() {
        this.warehouseSearch = '';
        this.warehouseSelectedName = '';
        this.warehouseResults = [];
        this.productSearch = '';
        this.productSelectedName = '';
        this.productResults = [];
        this.stockInfo = null;
    }

    handleFormChange(event) {
        const field = event.target.dataset.field;
        const type = event.target.type;
        let value = event.target.value;
        if (type === 'number') value = value === '' ? null : Number(value);
        this.form = { ...this.form, [field]: value };
    }

    handleAdjustmentTypeChange(event) {
        this.form = { ...this.form, Adjustment_Type__c: event.detail.value };
    }

    // ── Warehouse picker ────────────────────────────────────────────
    handleWarehouseSearch(event) {
        const term = event.target.value || '';
        this.warehouseSearch = term;
        if (this._whSearchTimer) clearTimeout(this._whSearchTimer);
        this._whSearchTimer = setTimeout(async () => {
            try {
                this.warehouseResults = await searchWarehouses({ term });
            } catch (e) {
                this.warehouseResults = [];
            }
        }, 250);
    }

    handleWarehouseSelect(event) {
        const id = event.currentTarget.dataset.id;
        const w = this.warehouseResults.find(x => x.value === id);
        if (!w) return;
        this.form = {
            ...this.form,
            Warehouse__c: w.value,
            Product__c: null,
            System_Qty__c: 0
        };
        this.warehouseSelectedName = w.label;
        this.warehouseSearch = w.label;
        this.warehouseResults = [];
        this.productSelectedName = '';
        this.productSearch = '';
        this.stockInfo = null;
    }

    handleWarehouseClear() {
        this.form = { ...this.form, Warehouse__c: null, Product__c: null, System_Qty__c: 0 };
        this.warehouseSelectedName = '';
        this.warehouseSearch = '';
        this.warehouseResults = [];
        this.productSelectedName = '';
        this.productSearch = '';
        this.stockInfo = null;
    }

    // ── Product picker ──────────────────────────────────────────────
    handleProductSearch(event) {
        const term = event.target.value || '';
        this.productSearch = term;
        if (this._prodSearchTimer) clearTimeout(this._prodSearchTimer);
        this._prodSearchTimer = setTimeout(async () => {
            try {
                this.productResults = await searchProducts({
                    term, warehouseId: this.form.Warehouse__c
                });
            } catch (e) {
                this.productResults = [];
            }
        }, 250);
    }

    async handleProductSelect(event) {
        const id = event.currentTarget.dataset.id;
        const p = this.productResults.find(x => x.value === id);
        if (!p) return;
        this.form = { ...this.form, Product__c: p.value };
        this.productSelectedName = p.label;
        this.productSearch = p.label;
        this.productResults = [];
        await this._refreshStockInfo();
    }

    handleProductClear() {
        this.form = { ...this.form, Product__c: null, System_Qty__c: 0 };
        this.productSelectedName = '';
        this.productSearch = '';
        this.productResults = [];
        this.stockInfo = null;
    }

    async handleBatchBlur() {
        await this._refreshStockInfo();
    }

    async _refreshStockInfo() {
        if (!this.form.Warehouse__c || !this.form.Product__c) {
            this.stockInfo = null;
            return;
        }
        try {
            const info = await getStockInfo({
                warehouseId: this.form.Warehouse__c,
                productId: this.form.Product__c,
                batchNumber: this.form.Batch_Number__c || ''
            });
            this.stockInfo = info;
            this.form = { ...this.form, System_Qty__c: info.qtyOnHand || 0 };
        } catch (e) {
            this.stockInfo = null;
        }
    }

    // ── Save ────────────────────────────────────────────────────────
    async handleSave() {
        if (this.saveDisabled) return;
        this.isSaving = true;
        try {
            const payload = {
                sobjectType: 'Stock_Adjustment__c',
                ...this.form,
                Adjustment_Qty__c: this.computedAdjustmentQty
            };
            await saveDraft({ adjustment: payload });
            this.toast('Saved', this.isEditing ? 'Adjustment updated.' : 'Draft created.', 'success');
            this.showModal = false;
            await refreshApex(this._wiredAdjustments);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isSaving = false;
    }

    async handleDelete(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        if (!confirm('Delete this draft adjustment?')) return;
        try {
            await deleteAdjustment({ adjustmentId: id });
            this.toast('Deleted', 'Adjustment removed.', 'success');
            await refreshApex(this._wiredAdjustments);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    // ── Submit for Approval ─────────────────────────────────────────
    handleSubmitClick(event) {
        const id = event.currentTarget.dataset.id;
        const a = this.adjustments.find(x => x.Id === id);
        if (!a) return;
        this.submitTargetId = id;
        this.submitTargetName = a.Name;
        this.submitComments = '';
        this.showSubmitModal = true;
    }

    handleSubmitCommentsChange(event) { this.submitComments = event.target.value; }
    handleCloseSubmitModal() { this.showSubmitModal = false; }

    async handleConfirmSubmit() {
        if (this.isSubmitting) return;
        this.isSubmitting = true;
        try {
            await submitForApproval({
                adjustmentId: this.submitTargetId,
                comments: this.submitComments
            });
            this.toast('Submitted', 'Sent for approval.', 'success');
            this.showSubmitModal = false;
            await refreshApex(this._wiredAdjustments);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isSubmitting = false;
    }

    // ── Open record ─────────────────────────────────────────────────
    handleOpenRecord(event) {
        const id = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: id, actionName: 'view' }
        });
    }

    // ── Helpers ─────────────────────────────────────────────────────
    _today() {
        const d = new Date();
        return d.toISOString().slice(0, 10);
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