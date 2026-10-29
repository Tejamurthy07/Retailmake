import { LightningElement, track } from 'lwc';
import getDashboardData from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.getDashboardData';
import getSlabDetail from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.getSlabDetail';
import saveSlab from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.saveSlab';
import deleteSlab from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.deleteSlab';
import toggleActive from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.toggleActive';
import cloneSlab from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.cloneSlab';
import bulkToggleActive from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.bulkToggleActive';
import bulkDelete from '@salesforce/apex/TAM_IncentiveSlabManager_Controller.bulkDelete';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class TamIncentiveSlabManager extends LightningElement {

    currentView = 'list';
    @track isLoading = false;

    @track slabList = [];
    @track criteriaOptions = [];
    @track profileOptions = [];
    @track territoryOptions = [];
    @track selectedIds = new Set();

    // Filters
    @track filterCriteria = '';
    @track filterProfile = '';
    @track filterTerritory = '';
    @track filterPayoutType = '';

    payoutTypeFilterOptions = [
        { label: '-- All Types --', value: '' },
        { label: 'Percentage (of Target Value)', value: 'Percentage' },
        { label: 'Fixed Amount', value: 'Fixed Amount' },
        { label: 'Salary Percentage (of Gross Salary)', value: 'Salary Percentage' }
    ];

    @track detail = {};
    @track form = {};

    // Search state for form dropdowns
    @track searchCriteria = '';
    @track searchProfile = '';
    @track searchTerritory = '';
    @track showCriteriaDropdown = false;
    @track showProfileDropdown = false;
    @track showTerritoryDropdown = false;

    @track showDeleteConfirm = false;
    deleteTargetId = null;
    @track deleteTargetName = '';
    _bulkDeleteIds = null;

    payoutTypeOptions = [
        { label: 'Percentage (of Target Value)', value: 'Percentage' },
        { label: 'Fixed Amount', value: 'Fixed Amount' },
        { label: 'Salary Percentage (of Gross Salary)', value: 'Salary Percentage' }
    ];

    _closeDropdownsBound;
    _dropdownJustOpened = false;

    connectedCallback() {
        this.loadData();
        this._closeDropdownsBound = () => {
            if (this._dropdownJustOpened) {
                this._dropdownJustOpened = false;
                return;
            }
            this.showCriteriaDropdown = false;
            this.showProfileDropdown = false;
            this.showTerritoryDropdown = false;
        };
        // Use setTimeout to avoid catching the same click that opened the dropdown
        document.addEventListener('click', this._closeDropdownsBound);
    }

    disconnectedCallback() {
        document.removeEventListener('click', this._closeDropdownsBound);
    }

    loadData() {
        this.isLoading = true;
        getDashboardData()
            .then(result => {
                this.slabList = result.slabs || [];
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
    get isFormView() { return this.currentView === 'form'; }
    get hasSlabs() { return this.slabList.length > 0; }
    get totalCount() { return this.slabList.length; }
    get activeCount() { return this.slabList.filter(s => s.Is_Active__c).length; }
    get inactiveCount() { return this.totalCount - this.activeCount; }
    get formTitle() { return this.form.Id ? 'Edit Slab' : 'New Slab'; }

    get hasSelectedItems() { return this.selectedIds.size > 0; }
    get selectedCount() { return this.selectedIds.size; }
    get allSelected() {
        return this.slabList.length > 0 && this.slabList.every(s => this.selectedIds.has(s.Id));
    }

    get displaySlabs() {
        let list = this.slabList;

        // Apply filters
        if (this.filterCriteria) {
            list = list.filter(s => s.Target_Criteria__c === this.filterCriteria);
        }
        if (this.filterProfile) {
            list = list.filter(s => s.Profile_Name__c === this.filterProfile);
        }
        if (this.filterTerritory) {
            list = list.filter(s => s.Territory__c === this.filterTerritory);
        }
        if (this.filterPayoutType) {
            list = list.filter(s => s.Payout_Type__c === this.filterPayoutType);
        }

        return list.map(s => ({
            ...s,
            selected: this.selectedIds.has(s.Id),
            criteriaName: s.Target_Criteria__r?.Name || '',
            profileDisplay: s.Profile_Name__c || '',
            territoryDisplay: s.Territory__r?.Name || '',
            rangeDisplay: `${s.Min_Percent__c}% — ${s.Max_Percent__c}%`,
            payoutDisplay: s.Payout_Type__c === 'Percentage'
                ? `${s.Payout_Value__c}% of target`
                : s.Payout_Type__c === 'Salary Percentage'
                    ? `${s.Payout_Value__c}% of salary`
                    : `Fixed ${s.Payout_Value__c}`
        }));
    }

    get hasFilteredSlabs() { return this.displaySlabs.length > 0; }

    // ===== FILTER HANDLERS =====
    handleFilterCriteria(event) {
        this.filterCriteria = event.target.value;
        this.selectedIds = new Set();
    }

    handleFilterProfile(event) {
        this.filterProfile = event.target.value;
        this.selectedIds = new Set();
    }

    handleFilterTerritory(event) {
        this.filterTerritory = event.target.value;
        this.selectedIds = new Set();
    }

    handleFilterPayoutType(event) {
        this.filterPayoutType = event.target.value;
        this.selectedIds = new Set();
    }

    get isSaveDisabled() {
        return this.isLoading || !this.form.Name || this.form.Min_Percent__c == null
            || this.form.Max_Percent__c == null || !this.form.Payout_Type__c
            || this.form.Payout_Value__c == null;
    }

    // Detail getters
    get detailCriteriaName() { return this.detail.Target_Criteria__r?.Name || 'Universal (All Criteria)'; }
    get detailProfileName() { return this.detail.Profile_Name__c || 'Universal (All Profiles)'; }
    get detailTerritoryName() { return this.detail.Territory__r?.Name || 'Universal (All Territories)'; }
    get detailPayoutRule() {
        if (this.detail.Payout_Type__c === 'Percentage') return `${this.detail.Payout_Value__c}% of target value`;
        if (this.detail.Payout_Type__c === 'Salary Percentage') return `${this.detail.Payout_Value__c}% of gross salary`;
        return `Fixed ${this.detail.Payout_Value__c}`;
    }
    get detailExamplePayout() {
        const mult = this.detail.Multiplier__c != null ? this.detail.Multiplier__c : 1;
        const val = this.detail.Payout_Value__c || 0;
        if (this.detail.Payout_Type__c === 'Percentage') {
            return String(100000 * (val / 100) * mult);
        }
        if (this.detail.Payout_Type__c === 'Salary Percentage') {
            return String(30000 * (val / 100) * mult);
        }
        return String(val * mult);
    }
    get detailExampleBase() {
        if (this.detail.Payout_Type__c === 'Salary Percentage') return '30,000 (salary)';
        return '1,00,000 (target)';
    }

    // ===== LIST ACTIONS =====
    handleNewSlab() {
        this.form = {
            Id: null, Name: '', Target_Criteria__c: '', Profile_Name__c: '',
            Territory__c: '', Min_Percent__c: 0, Max_Percent__c: 100,
            Payout_Type__c: 'Percentage', Payout_Value__c: 0, Multiplier__c: 1,
            Sort_Order__c: 0, Effective_From__c: '', Effective_To__c: '', Description__c: ''
        };
        this.searchCriteria = '';
        this.searchProfile = '';
        this.searchTerritory = '';
        this.showCriteriaDropdown = false;
        this.showProfileDropdown = false;
        this.showTerritoryDropdown = false;
        this.currentView = 'form';
    }

    handleRowClick(event) {
        const id = event.currentTarget.dataset.id;
        this.openDetail(id);
    }

    handleEdit(event) {
        event.stopPropagation();
        this.openForm(event.currentTarget.dataset.id);
    }

    handleDelete(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const item = this.slabList.find(s => s.Id === id);
        this.deleteTargetId = id;
        this.deleteTargetName = item ? item.Name : '';
        this.showDeleteConfirm = true;
    }

    handleToggleActive(event) {
        event.stopPropagation();
        const id = event.currentTarget.dataset.id;
        const item = this.slabList.find(s => s.Id === id);
        toggleActive({ slabId: id, isActive: !item.Is_Active__c })
            .then(() => {
                this.showToast('Success', item.Is_Active__c ? 'Deactivated' : 'Activated', 'success');
                this.loadData();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'));
    }

    stopPropagation(event) { event.stopPropagation(); }

    // ===== SELECTION =====
    handleSelectAll(event) {
        this.selectedIds = event.target.checked ? new Set(this.slabList.map(s => s.Id)) : new Set();
        this.slabList = [...this.slabList];
    }
    handleSelectItem(event) {
        const newSet = new Set(this.selectedIds);
        if (event.target.checked) newSet.add(event.currentTarget.dataset.id);
        else newSet.delete(event.currentTarget.dataset.id);
        this.selectedIds = newSet;
        this.slabList = [...this.slabList];
    }
    handleClearSelection() { this.selectedIds = new Set(); this.slabList = [...this.slabList]; }

    handleBulkActivate() { this._bulkToggle(true); }
    handleBulkDeactivate() { this._bulkToggle(false); }
    _bulkToggle(isActive) {
        this.isLoading = true;
        bulkToggleActive({ slabIds: Array.from(this.selectedIds), isActive })
            .then(() => {
                this.showToast('Success', `${this.selectedIds.size} slabs updated`, 'success');
                this.selectedIds = new Set();
                this.loadData();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleBulkDelete() {
        this._bulkDeleteIds = Array.from(this.selectedIds);
        this.deleteTargetName = `${this._bulkDeleteIds.length} slabs`;
        this.showDeleteConfirm = true;
    }

    // ===== DETAIL =====
    openDetail(id) {
        this.isLoading = true;
        getSlabDetail({ slabId: id })
            .then(result => { this.detail = result; this.currentView = 'detail'; })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleEditFromDetail() { this.openForm(this.detail.Id); }

    handleDeleteFromDetail() {
        this.deleteTargetId = this.detail.Id;
        this.deleteTargetName = this.detail.Name;
        this.showDeleteConfirm = true;
    }

    handleClone() {
        this.isLoading = true;
        cloneSlab({ slabId: this.detail.Id })
            .then(result => {
                this.showToast('Success', `Cloned as "${result.Name}"`, 'success');
                this.detail = result;
                this.loadData();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleBackToList() { this.currentView = 'list'; this.loadData(); }

    // ===== DELETE =====
    handleCancelDelete() { this.showDeleteConfirm = false; this.deleteTargetId = null; this._bulkDeleteIds = null; }

    handleConfirmDelete() {
        this.isLoading = true;
        this.showDeleteConfirm = false;

        const promise = this._bulkDeleteIds
            ? bulkDelete({ slabIds: this._bulkDeleteIds })
            : deleteSlab({ slabId: this.deleteTargetId });

        promise
            .then(() => {
                this.showToast('Success', 'Deleted', 'success');
                this.currentView = 'list';
                this.selectedIds = new Set();
                this.loadData();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'))
            .finally(() => {
                this.isLoading = false;
                this.deleteTargetId = null;
                this._bulkDeleteIds = null;
            });
    }

    // ===== FORM =====
    openForm(id) {
        this.isLoading = true;
        getSlabDetail({ slabId: id })
            .then(result => {
                this.form = {
                    Id: result.Id,
                    Name: result.Name,
                    Target_Criteria__c: result.Target_Criteria__c || '',
                    Profile_Name__c: result.Profile_Name__c || '',
                    Territory__c: result.Territory__c || '',
                    Min_Percent__c: result.Min_Percent__c,
                    Max_Percent__c: result.Max_Percent__c,
                    Payout_Type__c: result.Payout_Type__c,
                    Payout_Value__c: result.Payout_Value__c,
                    Multiplier__c: result.Multiplier__c,
                    Sort_Order__c: result.Sort_Order__c,
                    Effective_From__c: result.Effective_From__c || '',
                    Effective_To__c: result.Effective_To__c || '',
                    Description__c: result.Description__c || ''
                };
                // Set search text from existing values
                this.searchCriteria = result.Target_Criteria__r?.Name || '';
                this.searchProfile = result.Profile_Name__c || '';
                const tOpt = (this.territoryOptions || []).find(o => o.value === (result.Territory__c || ''));
                this.searchTerritory = tOpt ? tOpt.label : '';
                this.showCriteriaDropdown = false;
                this.showProfileDropdown = false;
                this.showTerritoryDropdown = false;

                this.currentView = 'form';
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ===== SEARCHABLE DROPDOWNS =====
    get filteredCriteriaSearch() {
        const s = (this.searchCriteria || '').toLowerCase();
        return (this.criteriaOptions || []).filter(o =>
            o.value && o.label.toLowerCase().includes(s)
        );
    }

    get filteredProfileSearch() {
        const s = (this.searchProfile || '').toLowerCase();
        return (this.profileOptions || []).filter(o =>
            o.value && o.label.toLowerCase().includes(s)
        );
    }

    get filteredTerritorySearch() {
        const s = (this.searchTerritory || '').toLowerCase();
        return (this.territoryOptions || []).filter(o =>
            o.value && o.label.toLowerCase().includes(s)
        );
    }

    handleSearchCriteria(event) {
        this.searchCriteria = event.target.value;
        this.showCriteriaDropdown = true;
        this.showProfileDropdown = false;
        this.showTerritoryDropdown = false;
        this._dropdownJustOpened = true;
    }
    handleSearchCriteriaFocus() { this.showCriteriaDropdown = true; this.showProfileDropdown = false; this.showTerritoryDropdown = false; this._dropdownJustOpened = true; }
    handleSelectCriteria(event) {
        const val = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        this.form = { ...this.form, Target_Criteria__c: val || '' };
        this.searchCriteria = label || '';
        this.showCriteriaDropdown = false;
    }

    handleSearchProfile(event) {
        this.searchProfile = event.target.value;
        this.showProfileDropdown = true;
        this.showCriteriaDropdown = false;
        this.showTerritoryDropdown = false;
        this._dropdownJustOpened = true;
    }
    handleSearchProfileFocus() { this.showProfileDropdown = true; this.showCriteriaDropdown = false; this.showTerritoryDropdown = false; this._dropdownJustOpened = true; }
    handleSelectProfile(event) {
        const val = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        this.form = { ...this.form, Profile_Name__c: val || '' };
        this.searchProfile = label || '';
        this.showProfileDropdown = false;
    }

    handleSearchTerritory(event) {
        this.searchTerritory = event.target.value;
        this.showTerritoryDropdown = true;
        this.showCriteriaDropdown = false;
        this.showProfileDropdown = false;
        this._dropdownJustOpened = true;
    }
    handleSearchTerritoryFocus() { this.showTerritoryDropdown = true; this.showCriteriaDropdown = false; this.showProfileDropdown = false; this._dropdownJustOpened = true; }
    handleSelectTerritory(event) {
        const val = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        this.form = { ...this.form, Territory__c: val || '' };
        this.searchTerritory = label || '';
        this.showTerritoryDropdown = false;
    }

    handleFormInput(event) {
        const field = event.target.dataset.field;
        let val = event.target.value;
        if (['Min_Percent__c', 'Max_Percent__c', 'Payout_Value__c', 'Multiplier__c', 'Sort_Order__c'].includes(field)) {
            val = val !== '' ? Number(val) : null;
        }
        this.form = { ...this.form, [field]: val };
    }

    handleSave() {
        if (this.form.Min_Percent__c >= this.form.Max_Percent__c) {
            this.showToast('Validation Error', 'Max % must be greater than Min %', 'error');
            return;
        }

        this.isLoading = true;
        const payload = { ...this.form };
        if (!payload.Target_Criteria__c) payload.Target_Criteria__c = null;
        if (!payload.Profile_Name__c) payload.Profile_Name__c = null;
        if (!payload.Territory__c) payload.Territory__c = null;
        if (!payload.Effective_From__c) payload.Effective_From__c = null;
        if (!payload.Effective_To__c) payload.Effective_To__c = null;

        saveSlab({ slab: payload })
            .then(result => {
                this.showToast('Success', 'Slab saved', 'success');
                this.detail = result;
                this.currentView = 'detail';
                this.loadData();
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Failed to save', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}