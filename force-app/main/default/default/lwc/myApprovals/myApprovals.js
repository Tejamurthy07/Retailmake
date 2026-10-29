import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getMyPendingApprovals from '@salesforce/apex/ApprovalPanelController.getMyPendingApprovals';
import approveStep from '@salesforce/apex/ApprovalPanelController.approveStep';
import rejectStep from '@salesforce/apex/ApprovalPanelController.rejectStep';

export default class MyApprovals extends NavigationMixin(LightningElement) {
    @track items = [];
    @track filterObject = 'all';
    @track searchTerm = '';
    @track showModal = false;
    @track modalAction = '';
    @track modalComments = '';
    @track modalStepId = null;
    @track modalRecordName = '';
    @track isProcessing = false;
    _wired;

    @wire(getMyPendingApprovals)
    wired(result) {
        this._wired = result;
        if (result.data) this.items = result.data;
        if (result.error) this.toast('Error', this.errMsg(result.error), 'error');
    }

    get objectFilters() {
        const seen = new Set();
        const dots = ['blue', 'green', 'orange', 'purple', 'teal', 'red'];
        const pills = [{ key: 'all', label: 'All', count: this.items.length, dotColor: 'gray' }];
        this.items.forEach(i => {
            if (!seen.has(i.objectType)) {
                seen.add(i.objectType);
                const count = this.items.filter(x => x.objectType === i.objectType).length;
                pills.push({
                    key: i.objectType,
                    label: i.objectType,
                    count,
                    dotColor: dots[seen.size % dots.length]
                });
            }
        });
        return pills.map(p => ({
            ...p,
            cssClass: 'ma-pill' + (p.key === this.filterObject ? ' ma-pill-active' : ''),
            dotClass: 'ma-pill-dot ma-pill-dot-' + p.dotColor
        }));
    }

    get filteredItems() {
        const term = this.searchTerm.toLowerCase();
        return this.items
            .filter(i => this.filterObject === 'all' || i.objectType === this.filterObject)
            .filter(i => !term ||
                (i.recordName || '').toLowerCase().includes(term) ||
                (i.submittedBy || '').toLowerCase().includes(term) ||
                (i.objectType || '').toLowerCase().includes(term))
            .map(i => ({
                ...i,
                levelBadge: `L${i.level} / L${i.totalLevels}`
            }));
    }

    get hasItems() { return this.filteredItems.length > 0; }
    get totalCount() { return this.items.length; }

    handleFilter(event) { this.filterObject = event.currentTarget.dataset.key; }
    handleSearch(event) { this.searchTerm = event.target.value || ''; }

    handleOpenRecord(event) {
        event.stopPropagation();
        const recordId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, actionName: 'view' }
        });
    }

    handleApproveClick(event) {
        const item = this._findItem(event.currentTarget.dataset.id);
        if (!item) return;
        this.modalAction = 'approve';
        this.modalStepId = item.stepId;
        this.modalRecordName = item.recordName;
        this.modalComments = '';
        this.showModal = true;
    }

    handleRejectClick(event) {
        const item = this._findItem(event.currentTarget.dataset.id);
        if (!item) return;
        this.modalAction = 'reject';
        this.modalStepId = item.stepId;
        this.modalRecordName = item.recordName;
        this.modalComments = '';
        this.showModal = true;
    }

    _findItem(stepId) { return this.items.find(x => x.stepId === stepId); }

    handleCloseModal() { this.showModal = false; }
    handleCommentsChange(event) { this.modalComments = event.target.value; }

    get isRejectMode() { return this.modalAction === 'reject'; }
    get modalTitle() {
        return (this.modalAction === 'approve' ? 'Approve' : 'Reject') + ' — ' + this.modalRecordName;
    }
    get confirmDisabled() {
        return this.isProcessing ||
            (this.isRejectMode && (this.modalComments || '').trim().length === 0);
    }

    async handleModalConfirm() {
        if (this.confirmDisabled) return;
        this.isProcessing = true;
        try {
            if (this.modalAction === 'approve') {
                await approveStep({ stepId: this.modalStepId, comments: this.modalComments });
                this.toast('Approved', 'Step approved.', 'success');
            } else {
                await rejectStep({ stepId: this.modalStepId, comments: this.modalComments });
                this.toast('Rejected', 'Step rejected.', 'success');
            }
            this.showModal = false;
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isProcessing = false;
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