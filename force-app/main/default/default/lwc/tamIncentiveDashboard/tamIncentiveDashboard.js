import { LightningElement, track } from 'lwc';
import getDashboardData from '@salesforce/apex/TAM_IncentiveDashboard_Controller.getDashboardData';
import getIncentives from '@salesforce/apex/TAM_IncentiveDashboard_Controller.getIncentives';
import getIncentiveDetail from '@salesforce/apex/TAM_IncentiveDashboard_Controller.getIncentiveDetail';
import getIncentiveSummary from '@salesforce/apex/TAM_IncentiveDashboard_Controller.getIncentiveSummary';
import runCalculation from '@salesforce/apex/TAM_IncentiveDashboard_Controller.runCalculation';
import submitForApproval from '@salesforce/apex/TAM_IncentiveDashboard_Controller.submitForApproval';
import approveIncentives from '@salesforce/apex/TAM_IncentiveDashboard_Controller.approveIncentives';
import rejectIncentives from '@salesforce/apex/TAM_IncentiveDashboard_Controller.rejectIncentives';
import markAsPaid from '@salesforce/apex/TAM_IncentiveDashboard_Controller.markAsPaid';
import runAnnualBonus from '@salesforce/apex/TAM_IncentiveDashboard_Controller.runAnnualBonus';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class TamIncentiveDashboard extends LightningElement {

    currentView = 'list';
    @track isLoading = false;

    // List state
    @track incentiveList = [];
    @track periodOptions = [];
    selectedPeriod = '';
    @track selectedStatus = 'All';
    @track selectedIds = new Set();
    @track summary = {};

    // Filter state
    @track criteriaOptions = [];
    @track profileOptions = [];
    @track territoryOptions = [];
    @track selectedCriteria = '';
    @track selectedProfile = '';
    @track selectedTerritory = '';

    // Detail state
    @track detail = {};

    // Payment modal
    @track showPaymentModal = false;
    paymentDate = '';
    _paymentIds = [];

    connectedCallback() {
        this.loadDashboard();
    }

    loadDashboard() {
        this.isLoading = true;
        getDashboardData()
            .then(result => {
                this.periodOptions = (result.periods || []).map(p => ({ label: p.Name, value: p.Id }));
                this.selectedPeriod = result.currentPeriodId || '';
                this.incentiveList = result.incentives || [];
                this.summary = result.summary || {};
                this.criteriaOptions = result.criteriaOptions || [];
                this.profileOptions = result.profileOptions || [];
                this.territoryOptions = result.territoryOptions || [];
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed to load', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ===== VIEW GETTERS =====
    get isListView() { return this.currentView === 'list'; }
    get isDetailView() { return this.currentView === 'detail'; }

    get hasIncentives() { return this.filteredIncentives.length > 0; }
    get hasSelectedItems() { return this.selectedIds.size > 0; }
    get selectedCount() { return this.selectedIds.size; }

    get allSelected() {
        const f = this.filteredIncentives;
        return f.length > 0 && f.every(i => this.selectedIds.has(i.Id));
    }

    // ===== SUMMARY GETTERS =====
    get summaryCalculated() { return this.summary.calculated || 0; }
    get summaryPendingCount() { return this.summary.pending || 0; }
    get summaryApproved() { return this.summary.approved || 0; }
    get summaryPaid() { return this.summary.paid || 0; }
    get summaryCalcAmt() { return this._formatCurrency(this.summary.totalCalcAmt || 0); }
    get summaryApprovedAmt() { return this._formatCurrency(this.summary.totalApprovedAmt || 0); }
    get summaryPaidAmt() { return this._formatCurrency(this.summary.totalPaidAmt || 0); }

    // ===== STATUS FILTERS =====
    get statusFilters() {
        const statuses = ['All', 'Calculated', 'Pending Approval', 'Approved', 'Rejected', 'Paid'];
        return statuses.map(s => {
            let count = 0;
            if (s === 'All') count = this.incentiveList.length;
            else count = this.incentiveList.filter(i => i.Status__c === s).length;
            return {
                value: s, label: s,
                count: count > 0 ? count : null,
                pillClass: 'idb-pill' + (this.selectedStatus === s ? ' idb-pill-active' : '')
            };
        });
    }

    get filteredIncentives() {
        let list = this.incentiveList;
        if (this.selectedStatus && this.selectedStatus !== 'All') {
            list = list.filter(i => i.Status__c === this.selectedStatus);
        }
        if (this.selectedCriteria) {
            list = list.filter(i => i.Target_Criteria__c === this.selectedCriteria);
        }
        if (this.selectedProfile) {
            list = list.filter(i => i.Salesperson__r?.Profile?.Name === this.selectedProfile);
        }
        if (this.selectedTerritory) {
            list = list.filter(i =>
                i.Incentive_Slab_Ref__r?.Territory__c === this.selectedTerritory
            );
        }
        return list.map(inc => ({
            ...inc,
            selected: this.selectedIds.has(inc.Id),
            salespersonName: inc.Salesperson__r?.Name || '—',
            criteriaName: inc.Target_Criteria__r?.Name || '—',
            slabName: inc.Incentive_Slab_Ref__r?.Name || '—',
            achievementPercent: inc.Achievement_Percent__c != null ? Math.round(inc.Achievement_Percent__c) : 0,
            calculatedAmount: inc.Calculated_Amount__c || 0,
            finalAmount: inc.Final_Amount__c || inc.Calculated_Amount__c || 0,
            percentClass: this._getPercentClass(inc.Achievement_Percent__c),
            statusClass: this._getStatusClass(inc.Status__c)
        }));
    }

    // ===== EVENT HANDLERS =====
    handlePeriodChange(event) {
        this.selectedPeriod = event.target.value;
        this.selectedIds = new Set();
        this._reloadIncentives();
    }

    handleCriteriaFilter(event) {
        this.selectedCriteria = event.target.value;
        this.selectedIds = new Set();
    }

    handleProfileFilter(event) {
        this.selectedProfile = event.target.value;
        this.selectedIds = new Set();
    }

    handleTerritoryFilter(event) {
        this.selectedTerritory = event.target.value;
        this.selectedIds = new Set();
    }

    handleStatusFilter(event) {
        this.selectedStatus = event.currentTarget.dataset.value;
        this.selectedIds = new Set();
    }

    handleRunAnnualBonus() {
        if (!this.selectedPeriod) {
            this.showToast('Warning', 'Select a yearly period first', 'warning');
            return;
        }
        this.isLoading = true;
        runAnnualBonus({ periodId: this.selectedPeriod })
            .then(() => {
                this.showToast('Success', 'Annual bonus calculated', 'success');
                this._reloadIncentives();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Bonus calculation failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleRunCalculation() {
        if (!this.selectedPeriod) {
            this.showToast('Warning', 'Select a period first', 'warning');
            return;
        }
        this.isLoading = true;
        runCalculation({ periodId: this.selectedPeriod })
            .then(result => {
                this.showToast('Success', result || 'Calculation complete', 'success');
                if (result && result.includes('background')) {
                    // Batch mode — auto-refresh after delay
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => { this._reloadIncentives(); }, 5000);
                } else {
                    this._reloadIncentives();
                }
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Calculation failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ===== SELECTION =====
    handleSelectAll(event) {
        if (event.target.checked) {
            this.selectedIds = new Set(this.filteredIncentives.map(i => i.Id));
        } else {
            this.selectedIds = new Set();
        }
        this.incentiveList = [...this.incentiveList];
    }

    handleSelectItem(event) {
        const id = event.currentTarget.dataset.id;
        const newSet = new Set(this.selectedIds);
        if (event.target.checked) newSet.add(id); else newSet.delete(id);
        this.selectedIds = newSet;
        this.incentiveList = [...this.incentiveList];
    }

    handleClearSelection() {
        this.selectedIds = new Set();
        this.incentiveList = [...this.incentiveList];
    }

    stopPropagation(event) { event.stopPropagation(); }

    // ===== BULK ACTIONS =====
    handleBulkSubmit() { this._bulkAction(submitForApproval, 'Submitted for approval'); }
    handleBulkApprove() { this._bulkAction(approveIncentives, 'Approved'); }
    handleBulkReject() { this._bulkAction(rejectIncentives, 'Rejected'); }

    handleBulkPaid() {
        this._paymentIds = Array.from(this.selectedIds);
        this.paymentDate = new Date().toISOString().split('T')[0];
        this.showPaymentModal = true;
    }

    _bulkAction(apexMethod, successMsg) {
        const ids = Array.from(this.selectedIds);
        this.isLoading = true;
        apexMethod({ incentiveIds: ids })
            .then(() => {
                this.showToast('Success', `${ids.length} incentives ${successMsg}`, 'success');
                this.selectedIds = new Set();
                this._reloadIncentives();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Action failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ===== DETAIL VIEW =====
    handleRowClick(event) {
        const id = event.currentTarget.dataset.id;
        this.isLoading = true;
        getIncentiveDetail({ incentiveId: id })
            .then(result => {
                this.detail = result;
                this.currentView = 'detail';
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed to load', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleBackToList() {
        this.currentView = 'list';
        this._reloadIncentives();
    }

    get canSubmit() { return this.detail.Status__c === 'Calculated'; }
    get canApprove() { return this.detail.Status__c === 'Pending Approval'; }
    get canMarkPaid() { return this.detail.Status__c === 'Approved'; }

    get detailStatusClass() { return this._getStatusClass(this.detail.Status__c); }
    get detailSlabName() { return this.detail.Incentive_Slab_Ref__r?.Name || '—'; }
    get detailApprovedBy() { return this.detail.Approved_By__r?.Name || '—'; }

    get detailSlabRange() {
        const slab = this.detail.Incentive_Slab_Ref__r;
        if (!slab) return '—';
        return `${slab.Min_Percent__c}% – ${slab.Max_Percent__c}%`;
    }

    get detailPayoutRule() {
        const slab = this.detail.Incentive_Slab_Ref__r;
        if (!slab) return '—';
        return slab.Payout_Type__c === 'Percentage'
            ? `${slab.Payout_Value__c}% of target`
            : `Fixed ${slab.Payout_Value__c}`;
    }

    get detailHasApproval() {
        return this.detail.Approved_By__c || this.detail.Payment_Date__c;
    }

    handleDetailSubmit() { this._detailAction(submitForApproval, 'Submitted'); }
    handleDetailApprove() { this._detailAction(approveIncentives, 'Approved'); }
    handleDetailReject() { this._detailAction(rejectIncentives, 'Rejected'); }

    handleDetailPaid() {
        this._paymentIds = [this.detail.Id];
        this.paymentDate = new Date().toISOString().split('T')[0];
        this.showPaymentModal = true;
    }

    _detailAction(apexMethod, msg) {
        this.isLoading = true;
        apexMethod({ incentiveIds: [this.detail.Id] })
            .then(() => {
                this.showToast('Success', `Incentive ${msg}`, 'success');
                return getIncentiveDetail({ incentiveId: this.detail.Id });
            })
            .then(result => { this.detail = result; })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ===== PAYMENT MODAL =====
    handlePaymentDateChange(event) { this.paymentDate = event.target.value; }
    closePaymentModal() { this.showPaymentModal = false; this._paymentIds = []; }

    confirmPayment() {
        if (!this.paymentDate) {
            this.showToast('Warning', 'Select a payment date', 'warning');
            return;
        }
        this.isLoading = true;
        this.showPaymentModal = false;

        markAsPaid({ incentiveIds: this._paymentIds, paymentDate: this.paymentDate })
            .then(() => {
                this.showToast('Success', `${this._paymentIds.length} incentive(s) marked as paid`, 'success');
                this.selectedIds = new Set();
                this._paymentIds = [];
                if (this.currentView === 'detail') {
                    return getIncentiveDetail({ incentiveId: this.detail.Id }).then(r => { this.detail = r; });
                }
                return this._reloadIncentives();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ===== HELPERS =====
    _reloadIncentives() {
        this.isLoading = true;
        return Promise.all([
            getIncentives({ periodId: this.selectedPeriod, status: 'All' }),
            getIncentiveSummary({ periodId: this.selectedPeriod })
        ]).then(([incentives, summary]) => {
            this.incentiveList = incentives || [];
            this.summary = summary || {};
        })
        .catch(e => this.showToast('Error', e?.body?.message || 'Failed to reload', 'error'))
        .finally(() => { this.isLoading = false; });
    }

    _getPercentClass(pct) {
        if (pct >= 100) return 'idb-percent-green';
        if (pct >= 70) return 'idb-percent-amber';
        return 'idb-percent-red';
    }

    _getStatusClass(status) {
        switch (status) {
            case 'Calculated': return 'idb-status idb-status-calc';
            case 'Pending Approval': return 'idb-status idb-status-pending';
            case 'Approved': return 'idb-status idb-status-approved';
            case 'Rejected': return 'idb-status idb-status-rejected';
            case 'Paid': return 'idb-status idb-status-paid';
            default: return 'idb-status';
        }
    }

    _formatCurrency(val) {
        if (val >= 100000) return (val / 100000).toFixed(1) + 'L';
        if (val >= 1000) return (val / 1000).toFixed(1) + 'K';
        return String(val);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}