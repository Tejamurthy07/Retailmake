import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAdminData from '@salesforce/apex/EXP_EligibilityAdmin_Controller.getAdminData';
import saveEligibilityRule from '@salesforce/apex/EXP_EligibilityAdmin_Controller.saveEligibilityRule';
import saveRateSlabs from '@salesforce/apex/EXP_EligibilityAdmin_Controller.saveRateSlabs';
import deleteEligibilityRule from '@salesforce/apex/EXP_EligibilityAdmin_Controller.deleteEligibilityRule';
import cloneEligibilityRule from '@salesforce/apex/EXP_EligibilityAdmin_Controller.cloneEligibilityRule';
import saveCityTier from '@salesforce/apex/EXP_EligibilityAdmin_Controller.saveCityTier';
import deleteCityTier from '@salesforce/apex/EXP_EligibilityAdmin_Controller.deleteCityTier';
import refreshAdminData from '@salesforce/apex/EXP_EligibilityAdmin_Controller.refreshAdminData';

const BAND_OPTIONS = [
    { label: 'All Bands', value: '' },
    { label: 'Band 1', value: 'Band 1' },
    { label: 'Band 2', value: 'Band 2' },
    { label: 'Band 3', value: 'Band 3' },
    { label: 'Band 4', value: 'Band 4' },
    { label: 'Band 5', value: 'Band 5' },
    { label: 'Band 6', value: 'Band 6' }
];

const EXPENSE_TYPE_OPTIONS = [
    { label: 'All Types', value: '' },
    { label: 'Daily Allowance', value: 'Daily Allowance' },
    { label: 'Travelling Allowance', value: 'Travelling Allowance' },
    { label: 'Fuel', value: 'Fuel' },
    { label: 'Lodging', value: 'Lodging' },
    { label: 'Food', value: 'Food' },
    { label: 'Toll', value: 'Toll' },
    { label: 'Mobile', value: 'Mobile' },
    { label: 'Stationery', value: 'Stationery' },
    { label: 'Printing', value: 'Printing' },
    { label: 'Miscellaneous', value: 'Miscellaneous' }
];

const DUTY_TYPE_OPTIONS = [
    { label: 'All', value: 'All' },
    { label: 'HQ', value: 'HQ' },
    { label: 'EX-HQ', value: 'EX-HQ' },
    { label: 'OS', value: 'OS' }
];

const RATE_TYPE_OPTIONS = [
    { label: 'Per Day', value: 'Per Day' },
    { label: 'Per KM', value: 'Per KM' },
    { label: 'Flat Monthly', value: 'Flat Monthly' },
    { label: 'Actual', value: 'Actual' }
];

const CATEGORY_OPTIONS = [
    { label: 'Travel', value: 'Travel' },
    { label: 'Miscellaneous', value: 'Miscellaneous' }
];

const TRAVEL_MODE_GROUPS = [
    { group: 'Distance-based', groupKey: 'distance', modes: [
        { label: 'Bike', value: 'Bike' },
        { label: 'Car', value: 'Car' },
        { label: 'Auto', value: 'Auto' },
        { label: 'Own Bike', value: 'Own Bike' },
        { label: 'Own Car', value: 'Own Car' },
        { label: 'Public Transport', value: 'Public Transport' }
    ]},
    { group: 'Bus', groupKey: 'bus', modes: [
        { label: 'Bus: AC', value: 'Bus: AC' },
        { label: 'Bus: Non-AC', value: 'Bus: Non-AC' }
    ]},
    { group: 'Train', groupKey: 'train', modes: [
        { label: 'Train: 1AC', value: 'Train: 1AC' },
        { label: 'Train: 2AC', value: 'Train: 2AC' },
        { label: 'Train: 3AC', value: 'Train: 3AC' },
        { label: 'Train: Sleeper', value: 'Train: Sleeper' },
        { label: 'Train: General', value: 'Train: General' }
    ]},
    { group: 'Flight', groupKey: 'flight', modes: [
        { label: 'Flight: Business', value: 'Flight: Business' },
        { label: 'Flight: Economy', value: 'Flight: Economy' },
        { label: 'Flight: Premium Economy', value: 'Flight: Premium Economy' }
    ]}
];

const SLAB_RATE_TYPE_OPTIONS = [
    { label: 'Per KM', value: 'Per KM' },
    { label: 'Actual', value: 'Actual' }
];

const DUTY_TYPE_FILTER_OPTIONS = [
    { label: 'All Duty Types', value: '' },
    { label: 'All', value: 'All' },
    { label: 'HQ', value: 'HQ' },
    { label: 'EX-HQ', value: 'EX-HQ' },
    { label: 'OS', value: 'OS' }
];

const BAND_FORM_OPTIONS = BAND_OPTIONS.filter(o => o.value !== '');
const EXPENSE_TYPE_FORM_OPTIONS = EXPENSE_TYPE_OPTIONS.filter(o => o.value !== '');

export default class ExpenseEligibilityAdmin extends LightningElement {
    @track rules = [];
    @track filteredRules = [];
    @track selectedRule = null;
    @track isEditing = false;
    @track isNewRule = false;
    @track rateSlabs = [];
    @track deletedSlabIds = [];
    @track cityTiers = [];
    @track selectedCityTier = null;
    @track activeTab = 'rules';
    @track bandFilter = '';
    @track typeFilter = '';
    @track dutyTypeFilter = '';
    @track isLoading = false;
    @track errorMessage = '';
    @track successMessage = '';
    @track showSlabModal = false;
    @track slabEditMode = '';
    @track showCloneModal = false;
    @track cloneBand = '';
    @track cloneDutyType = 'All';
    @track showDeleteConfirm = false;

    // Options getters
    get bandOptions() { return BAND_OPTIONS; }
    get expenseTypeOptions() { return EXPENSE_TYPE_OPTIONS; }
    get dutyTypeOptions() { return DUTY_TYPE_OPTIONS; }
    get dutyTypeFilterOptions() { return DUTY_TYPE_FILTER_OPTIONS; }
    get rateTypeOptions() { return RATE_TYPE_OPTIONS; }
    get categoryOptions() { return CATEGORY_OPTIONS; }
    get slabRateTypeOptions() { return SLAB_RATE_TYPE_OPTIONS; }
    get bandFormOptions() { return BAND_FORM_OPTIONS; }
    get expenseTypeFormOptions() { return EXPENSE_TYPE_FORM_OPTIONS; }
    get tierOptions() {
        return [
            { label: 'Tier 1', value: 'Tier 1' },
            { label: 'Tier 2', value: 'Tier 2' },
            { label: 'Tier 3', value: 'Tier 3' }
        ];
    }

    // Computed properties
    get showTravelModes() {
        return this.selectedRule?.Expense_Type__c === 'Travelling Allowance';
    }

    get showCityTierLimits() {
        return ['Lodging'].includes(this.selectedRule?.Expense_Type__c);
    }

    get showDistanceSettings() {
        return this.selectedRule?.Expense_Type__c === 'Travelling Allowance';
    }

    get showMaxPerDay() {
        return false;
    }

    get showMaxPerMonth() {
        return false;
    }

    get showDutyType() {
        return ['Daily Allowance', 'Travelling Allowance', 'Fuel', 'Lodging', 'Food'].includes(this.selectedRule?.Expense_Type__c);
    }

    get showRateAmount() {
        return this.selectedRule?.Rate_Type__c === 'Per Day' ||
               this.selectedRule?.Rate_Type__c === 'Per KM' ||
               this.selectedRule?.Rate_Type__c === 'Flat Monthly';
    }

    get showReceiptFields() {
        return !!this.selectedRule?.Expense_Type__c;
    }

    get isRulesTab() { return this.activeTab === 'rules'; }
    get isCityTiersTab() { return this.activeTab === 'cityTiers'; }

    get rulesTabClass() {
        return 'tab-btn' + (this.activeTab === 'rules' ? ' active' : '');
    }

    get cityTiersTabClass() {
        return 'tab-btn' + (this.activeTab === 'cityTiers' ? ' active' : '');
    }

    get hasSelectedRule() {
        return this.selectedRule != null;
    }

    get canSave() {
        return this.selectedRule?.Band__c && this.selectedRule?.Expense_Type__c;
    }

    get travelModeCheckboxes() {
        const selected = (this.selectedRule?.Allowed_Travel_Modes__c || '').split(';').map(s => s.trim()).filter(s => s);
        return TRAVEL_MODE_GROUPS.map(g => ({
            ...g,
            modes: g.modes.map(m => ({
                ...m,
                checked: selected.includes(m.value),
                key: m.value
            }))
        }));
    }

    get modeRateConfigs() {
        const selected = (this.selectedRule?.Allowed_Travel_Modes__c || '').split(';').map(s => s.trim()).filter(s => s);
        if (selected.includes('All') || selected.length === 0) return [];

        return selected.map(mode => {
            const config = this.rateSlabs.find(s => s.Travel_Mode__c === mode && !s.Distance_From__c && s.Distance_From__c !== 0);
            const slabCount = this.rateSlabs.filter(s => s.Travel_Mode__c === mode && (s.Distance_From__c || s.Distance_From__c === 0)).length;
            const isDistanceBased = ['Bike', 'Car', 'Auto', 'Own Bike', 'Own Car', 'Public Transport'].includes(mode);
            return {
                mode,
                key: mode,
                rateType: config ? config.Rate_Type__c : (isDistanceBased ? 'Per KM' : 'Actual'),
                rateAmount: config ? config.Rate_Amount__c : null,
                maxAmount: config ? config.Max_Amount__c : null,
                slabCount,
                isDistanceBased,
                isPerKm: (config ? config.Rate_Type__c : (isDistanceBased ? 'Per KM' : 'Actual')) === 'Per KM',
                hasConfig: !!config,
                configId: config ? config.Id : null
            };
        });
    }

    get currentModeSlabs() {
        if (!this.slabEditMode) return [];
        return this.rateSlabs
            .filter(s => s.Travel_Mode__c === this.slabEditMode && (s.Distance_From__c || s.Distance_From__c === 0))
            .sort((a, b) => (a.Distance_From__c || 0) - (b.Distance_From__c || 0))
            .map((s, idx) => ({ ...s, index: idx }));
    }

    get slabModalTitle() {
        return `Rate Slabs - ${this.slabEditMode}`;
    }

    get slabPreview() {
        const slabs = this.currentModeSlabs;
        if (slabs.length === 0) return null;
        const sampleDistance = 150;
        let totalCost = 0;
        let breakdown = [];

        for (const slab of slabs) {
            const from = slab.Distance_From__c || 0;
            const to = slab.Distance_To__c || Infinity;
            const rate = slab.Rate_Amount__c || 0;

            if (sampleDistance > from) {
                const applicableKm = Math.min(sampleDistance, to) - from;
                if (applicableKm > 0) {
                    const cost = applicableKm * rate;
                    totalCost += cost;
                    breakdown.push({
                        key: `${from}-${to}`,
                        range: `${from} - ${to === Infinity ? '...' : to} km`,
                        km: applicableKm,
                        rate,
                        cost: cost.toFixed(2)
                    });
                }
            }
        }

        return {
            distance: sampleDistance,
            total: totalCost.toFixed(2),
            breakdown
        };
    }

    get filteredCityTiers() {
        return this.cityTiers;
    }

    get hasRules() {
        return this.filteredRules && this.filteredRules.length > 0;
    }

    get hasCityTiers() {
        return this.cityTiers && this.cityTiers.length > 0;
    }

    get hasModeRateConfigs() {
        return this.modeRateConfigs && this.modeRateConfigs.length > 0;
    }

    get hasSlabPreview() {
        return this.slabPreview != null;
    }

    // Lifecycle
    _pullToRefreshHandler;
    _touchStartY = 0;

    connectedCallback() {
        this._disablePullToRefresh();
        this.loadData();
    }

    disconnectedCallback() {
        this._enablePullToRefresh();
    }

    _disablePullToRefresh() {
        document.body.style.overscrollBehaviorY = 'contain';
        document.documentElement.style.overscrollBehaviorY = 'contain';
        this._touchStartY = 0;
        this._pullToRefreshHandler = (e) => {
            if (window.scrollY === 0 && e.touches[0].clientY > this._touchStartY) {
                e.preventDefault();
            }
        };
        document.addEventListener('touchstart', (e) => {
            this._touchStartY = e.touches[0].clientY;
        }, { passive: true });
        document.addEventListener('touchmove', this._pullToRefreshHandler, { passive: false });
    }

    _enablePullToRefresh() {
        document.body.style.overscrollBehaviorY = '';
        document.documentElement.style.overscrollBehaviorY = '';
        if (this._pullToRefreshHandler) {
            document.removeEventListener('touchmove', this._pullToRefreshHandler);
        }
    }

    // Data Loading
    async loadData(skipCache = false) {
        this.isLoading = true;
        this.errorMessage = '';
        try {
            const data = skipCache ? await refreshAdminData() : await getAdminData();
            this.rules = data.rules || [];
            this.cityTiers = (data.cityTiers || []).map(ct => ({ ...ct, isEditing: false, _key: ct.Id }));
            this.applyFilters();
        } catch (error) {
            this.handleError(error, 'Error loading admin data');
        } finally {
            this.isLoading = false;
        }
    }

    // Tab handling
    handleTabChange(event) {
        this.activeTab = event.target.dataset.tab;
        this.selectedRule = null;
        this.isEditing = false;
        this.isNewRule = false;
    }

    // Filter handling
    handleBandFilter(event) {
        this.bandFilter = event.detail.value;
        this.applyFilters();
    }

    handleTypeFilter(event) {
        this.typeFilter = event.detail.value;
        this.applyFilters();
    }

    handleDutyTypeFilter(event) {
        this.dutyTypeFilter = event.detail.value;
        this.applyFilters();
    }

    applyFilters() {
        let filtered = [...this.rules];

        if (this.bandFilter) {
            filtered = filtered.filter(r => r.Band__c === this.bandFilter);
        }
        if (this.typeFilter) {
            filtered = filtered.filter(r => r.Expense_Type__c === this.typeFilter);
        }
        if (this.dutyTypeFilter) {
            filtered = filtered.filter(r => r.Travel_Type__c === this.dutyTypeFilter);
        }

        this.filteredRules = filtered.map(r => ({
            ...r,
            isSelected: this.selectedRule?.Id === r.Id,
            rowClass: 'rule-row' + (this.selectedRule?.Id === r.Id ? ' selected' : ''),
            dutyBadgeClass: 'duty-badge duty-' + (r.Travel_Type__c || 'all').toLowerCase().replace('-', ''),
            modeCount: r.Allowed_Travel_Modes__c
                ? r.Allowed_Travel_Modes__c.split(';').filter(s => s.trim()).length
                : 0,
            activeLabel: r.Is_Active__c ? 'Active' : 'Inactive',
            activeClass: 'status-badge ' + (r.Is_Active__c ? 'active' : 'inactive')
        }));
    }

    // Rule Selection
    handleSelectRule(event) {
        const ruleId = event.currentTarget.dataset.id;
        const rule = this.rules.find(r => r.Id === ruleId);
        if (rule) {
            this.selectedRule = { ...rule };
            this.isEditing = true;
            this.isNewRule = false;
            this.rateSlabs = [];
            this.deletedSlabIds = [];
            this.loadRuleSlabs(ruleId);
            this.applyFilters();
        }
    }

    loadRuleSlabs(ruleId) {
        const rule = this.rules.find(r => r.Id === ruleId);
        if (rule && rule.Expense_Rate_Slabs__r) {
            this.rateSlabs = [...rule.Expense_Rate_Slabs__r];
        } else {
            this.rateSlabs = [];
        }
    }

    // New Rule
    handleNewRule() {
        this.selectedRule = {
            Band__c: '',
            Expense_Type__c: '',
            Travel_Type__c: 'All',
            Expense_Category__c: 'Travel',
            Rate_Type__c: 'Per Day',
            Rate_Amount__c: null,
            Max_Per_Day__c: null,
            Max_Per_Month__c: null,
            Min_Distance_KM__c: null,
            Daily_KM_Limit__c: null,
            Allowed_Travel_Modes__c: '',
            Receipt_Required__c: false,
            Receipt_Threshold__c: null,
            Effective_From__c: null,
            Effective_To__c: null,
            Is_Active__c: true,
            Auto_Create__c: false,
            Mandatory_Remarks__c: false,
            Sort_Order__c: null,
            City_Tier_1_Limit__c: null,
            City_Tier_2_Limit__c: null,
            City_Tier_3_Limit__c: null
        };
        this.isEditing = true;
        this.isNewRule = true;
        this.rateSlabs = [];
        this.deletedSlabIds = [];
        this.applyFilters();
    }

    // Field Changes
    handleFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox'
            ? event.target.checked
            : event.detail?.value !== undefined
                ? event.detail.value
                : event.target.value;
        this.selectedRule = { ...this.selectedRule, [field]: value };
    }

    handleExpenseTypeChange(event) {
        const expenseType = event.detail.value;
        let rateType = 'Per Day';
        let category = 'Miscellaneous';

        if (expenseType === 'Travelling Allowance') {
            rateType = 'Per KM';
            category = 'Travel';
        } else if (expenseType === 'Fuel') {
            rateType = 'Actual';
            category = 'Travel';
        } else if (expenseType === 'Daily Allowance' || expenseType === 'Food') {
            rateType = 'Per Day';
            category = 'Travel';
        } else if (expenseType === 'Lodging') {
            rateType = 'Per Day';
            category = 'Travel';
        } else if (expenseType === 'Toll') {
            rateType = 'Actual';
            category = 'Travel';
        } else if (expenseType === 'Mobile' || expenseType === 'Stationery' || expenseType === 'Printing') {
            rateType = 'Flat Monthly';
            category = 'Miscellaneous';
        } else if (expenseType === 'Miscellaneous') {
            rateType = 'Actual';
            category = 'Miscellaneous';
        }

        this.selectedRule = {
            ...this.selectedRule,
            Expense_Type__c: expenseType,
            Rate_Type__c: rateType,
            Expense_Category__c: category,
            Allowed_Travel_Modes__c: ''
        };
    }

    // Travel Mode Toggle
    handleTravelModeToggle(event) {
        const mode = event.target.dataset.mode;
        const checked = event.target.checked;
        const current = (this.selectedRule?.Allowed_Travel_Modes__c || '')
            .split(';').map(s => s.trim()).filter(s => s);

        let updated;
        if (checked) {
            updated = [...current, mode];
        } else {
            updated = current.filter(m => m !== mode);
        }

        this.selectedRule = {
            ...this.selectedRule,
            Allowed_Travel_Modes__c: updated.join(';')
        };
    }

    // Save Rule
    async handleSaveRule() {
        if (!this.canSave) {
            this.showToast('Validation Error', 'Band and Expense Type are required.', 'error');
            return;
        }

        this.isLoading = true;
        try {
            const ruleToSave = { ...this.selectedRule };
            // Remove UI-only fields
            delete ruleToSave.isSelected;
            delete ruleToSave.rowClass;
            delete ruleToSave.dutyBadgeClass;
            delete ruleToSave.modeCount;
            delete ruleToSave.activeLabel;
            delete ruleToSave.activeClass;

            const savedRule = await saveEligibilityRule({ rule: ruleToSave });

            // Save rate slabs if any
            if (this.rateSlabs.length > 0 || this.deletedSlabIds.length > 0) {
                const slabsToSave = this.rateSlabs.map(s => ({
                    ...s,
                    Expense_Eligibility__c: savedRule.Id
                }));
                await saveRateSlabs({
                    eligibilityId: savedRule.Id,
                    slabs: slabsToSave,
                    deletedSlabIds: this.deletedSlabIds
                });
            }

            this.showToast('Success', 'Eligibility rule saved successfully.', 'success');
            this.isNewRule = false;
            await this.loadData(true);
            this.selectedRule = { ...savedRule };
            this.isEditing = true;
            this.loadRuleSlabs(savedRule.Id);
            this.applyFilters();
        } catch (error) {
            this.handleError(error, 'Error saving rule');
        } finally {
            this.isLoading = false;
        }
    }

    // Delete Rule
    handleDeleteRule() {
        this.showDeleteConfirm = true;
    }

    handleCancelDelete() {
        this.showDeleteConfirm = false;
    }

    async handleConfirmDelete() {
        this.showDeleteConfirm = false;
        if (!this.selectedRule?.Id) {
            this.handleCancel();
            return;
        }

        this.isLoading = true;
        try {
            await deleteEligibilityRule({ ruleId: this.selectedRule.Id });
            this.showToast('Success', 'Eligibility rule deleted.', 'success');
            this.selectedRule = null;
            this.isEditing = false;
            this.isNewRule = false;
            await this.loadData(true);
        } catch (error) {
            this.handleError(error, 'Error deleting rule');
        } finally {
            this.isLoading = false;
        }
    }

    // Clone Rule
    handleCloneRule() {
        this.cloneBand = this.selectedRule?.Band__c || '';
        this.cloneDutyType = this.selectedRule?.Travel_Type__c || 'All';
        this.showCloneModal = true;
    }

    handleCloneBandChange(event) {
        this.cloneBand = event.detail.value;
    }

    handleCloneDutyTypeChange(event) {
        this.cloneDutyType = event.detail.value;
    }

    handleCloneCancel() {
        this.showCloneModal = false;
    }

    async handleCloneConfirm() {
        if (!this.cloneBand) {
            this.showToast('Validation Error', 'Please select a target band.', 'error');
            return;
        }

        this.showCloneModal = false;
        this.isLoading = true;
        try {
            const clonedRule = await cloneEligibilityRule({
                sourceRuleId: this.selectedRule.Id,
                newBand: this.cloneBand,
                newDutyType: this.cloneDutyType
            });
            this.showToast('Success', 'Rule cloned successfully.', 'success');
            await this.loadData(true);
            this.selectedRule = { ...clonedRule };
            this.isEditing = true;
            this.isNewRule = false;
            this.loadRuleSlabs(clonedRule.Id);
            this.applyFilters();
        } catch (error) {
            this.handleError(error, 'Error cloning rule');
        } finally {
            this.isLoading = false;
        }
    }

    // Cancel
    handleCancel() {
        this.selectedRule = null;
        this.isEditing = false;
        this.isNewRule = false;
        this.rateSlabs = [];
        this.deletedSlabIds = [];
        this.applyFilters();
    }

    // Mode Rate Config
    handleSaveModeConfig(event) {
        const mode = event.currentTarget.dataset.mode;
        const field = event.currentTarget.dataset.field;
        const value = event.currentTarget.type === 'number'
            ? parseFloat(event.currentTarget.value)
            : event.detail?.value !== undefined
                ? event.detail.value
                : event.currentTarget.value;

        const existingIdx = this.rateSlabs.findIndex(
            s => s.Travel_Mode__c === mode && !s.Distance_From__c && s.Distance_From__c !== 0
        );

        let updatedSlabs = [...this.rateSlabs];

        if (existingIdx >= 0) {
            updatedSlabs[existingIdx] = {
                ...updatedSlabs[existingIdx],
                [field]: value
            };
        } else {
            updatedSlabs.push({
                Travel_Mode__c: mode,
                [field]: value,
                Rate_Type__c: field === 'Rate_Type__c' ? value : 'Per KM',
                Rate_Amount__c: field === 'Rate_Amount__c' ? value : null,
                Max_Amount__c: field === 'Max_Amount__c' ? value : null
            });
        }

        this.rateSlabs = updatedSlabs;
    }

    // Slab Modal
    handleEditSlabs(event) {
        const mode = event.currentTarget.dataset.mode;
        this.slabEditMode = mode;
        this.showSlabModal = true;
    }

    handleCloseSlabModal() {
        this.showSlabModal = false;
        this.slabEditMode = '';
    }

    handleAddSlab() {
        const currentSlabs = this.currentModeSlabs;
        const lastTo = currentSlabs.length > 0
            ? (currentSlabs[currentSlabs.length - 1].Distance_To__c || 0)
            : 0;

        const newSlab = {
            Travel_Mode__c: this.slabEditMode,
            Distance_From__c: lastTo,
            Distance_To__c: lastTo + 50,
            Rate_Amount__c: 0,
            Rate_Type__c: 'Per KM',
            _tempId: Date.now()
        };

        this.rateSlabs = [...this.rateSlabs, newSlab];
    }

    handleRemoveSlab(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const slabs = this.currentModeSlabs;
        const slabToRemove = slabs[index];

        if (slabToRemove?.Id) {
            this.deletedSlabIds = [...this.deletedSlabIds, slabToRemove.Id];
        }

        this.rateSlabs = this.rateSlabs.filter(s => {
            if (slabToRemove.Id) return s.Id !== slabToRemove.Id;
            if (slabToRemove._tempId) return s._tempId !== slabToRemove._tempId;
            return !(s.Travel_Mode__c === slabToRemove.Travel_Mode__c &&
                     s.Distance_From__c === slabToRemove.Distance_From__c &&
                     s.Distance_To__c === slabToRemove.Distance_To__c);
        });
    }

    handleSlabFieldChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const field = event.currentTarget.dataset.field;
        const value = parseFloat(event.currentTarget.value);
        const slabs = this.currentModeSlabs;
        const targetSlab = slabs[index];

        this.rateSlabs = this.rateSlabs.map(s => {
            const isMatch = targetSlab.Id
                ? s.Id === targetSlab.Id
                : (targetSlab._tempId
                    ? s._tempId === targetSlab._tempId
                    : s.Travel_Mode__c === targetSlab.Travel_Mode__c &&
                      s.Distance_From__c === targetSlab.Distance_From__c &&
                      s.Distance_To__c === targetSlab.Distance_To__c);
            if (isMatch) {
                return { ...s, [field]: value };
            }
            return s;
        });
    }

    // City Tier methods
    handleNewCityTier() {
        const newTier = {
            Name: '',
            Tier__c: 'Tier 1',
            State__c: '',
            Is_Active__c: true,
            isEditing: true,
            isNew: true,
            _tempId: Date.now(),
            _key: 'new-' + Date.now()
        };
        this.cityTiers = [newTier, ...this.cityTiers];
    }

    handleEditCityTier(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        this.cityTiers = this.cityTiers.map((ct, i) => ({
            ...ct,
            isEditing: i === index ? true : ct.isEditing
        }));
    }

    handleCityTierFieldChange(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const field = event.currentTarget.dataset.field;
        const value = event.currentTarget.type === 'checkbox'
            ? event.currentTarget.checked
            : event.detail?.value !== undefined
                ? event.detail.value
                : event.currentTarget.value;

        this.cityTiers = this.cityTiers.map((ct, i) => {
            if (i === index) {
                return { ...ct, [field]: value };
            }
            return ct;
        });
    }

    async handleSaveCityTier(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const tier = this.cityTiers[index];

        if (!tier.Name || !tier.Tier__c) {
            this.showToast('Validation Error', 'City Name and Tier are required.', 'error');
            return;
        }

        this.isLoading = true;
        try {
            const tierToSave = { ...tier };
            delete tierToSave.isEditing;
            delete tierToSave.isNew;
            delete tierToSave._tempId;
            delete tierToSave._key;

            const savedTier = await saveCityTier({ cityTier: tierToSave });
            this.cityTiers = this.cityTiers.map((ct, i) => {
                if (i === index) {
                    return { ...savedTier, isEditing: false, _key: savedTier.Id };
                }
                return ct;
            });
            this.showToast('Success', 'City tier saved.', 'success');
        } catch (error) {
            this.handleError(error, 'Error saving city tier');
        } finally {
            this.isLoading = false;
        }
    }

    handleCancelCityTierEdit(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const tier = this.cityTiers[index];

        if (tier.isNew) {
            this.cityTiers = this.cityTiers.filter((_, i) => i !== index);
        } else {
            this.cityTiers = this.cityTiers.map((ct, i) => ({
                ...ct,
                isEditing: i === index ? false : ct.isEditing
            }));
            this.loadData();
        }
    }

    async handleDeleteCityTier(event) {
        const index = parseInt(event.currentTarget.dataset.index, 10);
        const tier = this.cityTiers[index];

        if (!tier.Id) {
            this.cityTiers = this.cityTiers.filter((_, i) => i !== index);
            return;
        }

        this.isLoading = true;
        try {
            await deleteCityTier({ cityTierId: tier.Id });
            this.cityTiers = this.cityTiers.filter((_, i) => i !== index);
            this.showToast('Success', 'City tier deleted.', 'success');
        } catch (error) {
            this.handleError(error, 'Error deleting city tier');
        } finally {
            this.isLoading = false;
        }
    }

    // Utility methods
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    handleError(error, context) {
        const message = error?.body?.message || error?.message || 'An unexpected error occurred.';
        this.errorMessage = `${context}: ${message}`;
        this.showToast('Error', this.errorMessage, 'error');
        console.error(context, error);
    }

    clearMessages() {
        this.errorMessage = '';
        this.successMessage = '';
    }

    getRuleRowClass(rule) {
        return 'rule-row' + (this.selectedRule?.Id === rule.Id ? ' selected' : '');
    }
}