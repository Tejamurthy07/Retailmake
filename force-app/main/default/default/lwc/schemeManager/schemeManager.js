import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import getSchemeStats from '@salesforce/apex/SchemeManagerController.getSchemeStats';
import getSchemes from '@salesforce/apex/SchemeManagerController.getSchemes';
import cloneScheme from '@salesforce/apex/SchemeManagerController.cloneScheme';
import updateSchemeStatus from '@salesforce/apex/SchemeManagerController.updateSchemeStatus';
import deleteScheme from '@salesforce/apex/SchemeManagerController.deleteScheme';
import getSchemeDetails from '@salesforce/apex/SchemeViewController.getSchemeDetails';
import calculateSchemeDiscount from '@salesforce/apex/SchemeViewController.calculateSchemeDiscount';

// Wizard apex imports
import getScheme from '@salesforce/apex/SchemeManagerController.getScheme';
import saveScheme from '@salesforce/apex/SchemeManagerController.saveScheme';
import searchProducts from '@salesforce/apex/SchemeManagerController.searchProducts';
import generateSchemeCode from '@salesforce/apex/SchemeManagerController.generateSchemeCode';
import searchTerritories from '@salesforce/apex/SchemeManagerController.searchTerritories';
import getActiveUOMs from '@salesforce/apex/UOMConversionController.getActiveUOMs';

const STATUS_CONFIG = {
    'Draft':            { icon: 'utility:edit', class: 'status-draft', color: '#706e6b' },
    'Pending Approval': { icon: 'utility:clock', class: 'status-pending', color: '#dd7a01' },
    'Active':           { icon: 'utility:success', class: 'status-active', color: '#2e844a' },
    'Expired':          { icon: 'utility:warning', class: 'status-expired', color: '#ea001e' },
    'Cancelled':        { icon: 'utility:ban', class: 'status-cancelled', color: '#706e6b' }
};

const CATEGORY_COLORS = {
    'Free Products':      { bg: '#fff8e1', color: '#dd7a01', short: 'FP' },
    'Discount in %':      { bg: '#e8f4fd', color: '#0176d3', short: '%' },
    'Discount in Value':  { bg: '#e6f7e9', color: '#2e844a', short: 'Rs' },
    'Reward Points':      { bg: '#f3e8ff', color: '#9b59b6', short: 'RP' }
};

// List filter options (with 'All' prefixes)
const STATUS_OPTIONS = [
    { label: 'All Statuses', value: '' },
    { label: 'Draft', value: 'Draft' },
    { label: 'Pending Approval', value: 'Pending Approval' },
    { label: 'Active', value: 'Active' },
    { label: 'Expired', value: 'Expired' },
    { label: 'Cancelled', value: 'Cancelled' }
];

const CATEGORY_OPTIONS = [
    { label: 'All Categories', value: '' },
    { label: 'Free Products', value: 'Free Products' },
    { label: 'Discount in %', value: 'Discount in %' },
    { label: 'Discount in Value', value: 'Discount in Value' },
    { label: 'Reward Points', value: 'Reward Points' }
];

const TYPE_OPTIONS = [
    { label: 'All Types', value: '' },
    { label: 'Same Product (QTY)', value: 'Same Product (QTY)' },
    { label: 'Same Product (VAL)', value: 'Same Product (VAL)' },
    { label: 'Assorted Product (QTY)', value: 'Assorted Product (QTY)' },
    { label: 'Assorted Product (VAL)', value: 'Assorted Product (VAL)' },
    { label: 'Invoice Qty Based', value: 'Invoice Qty Based' },
    { label: 'Invoice Val Based', value: 'Invoice Val Based' }
];

const CHANNEL_OPTIONS = [
    { label: 'All Channels', value: '' },
    { label: 'GT', value: 'GT' },
    { label: 'MT', value: 'MT' },
    { label: 'E-Commerce', value: 'E-Commerce' }
];

// Wizard-specific options (without 'All' prefixes)
const WIZARD_CATEGORY_OPTIONS = [
    { label: 'Free Products', value: 'Free Products' },
    { label: 'Discount in %', value: 'Discount in %' },
    { label: 'Discount in Value', value: 'Discount in Value' },
    { label: 'Reward Points', value: 'Reward Points' }
];

const WIZARD_TYPE_OPTIONS = [
    { label: 'Same Product (QTY)', value: 'Same Product (QTY)' },
    { label: 'Same Product (VAL)', value: 'Same Product (VAL)' },
    { label: 'Assorted Product (QTY)', value: 'Assorted Product (QTY)' },
    { label: 'Assorted Product (VAL)', value: 'Assorted Product (VAL)' },
    { label: 'Invoice Qty Based', value: 'Invoice Qty Based' },
    { label: 'Invoice Val Based', value: 'Invoice Val Based' }
];

const WIZARD_STATUS_OPTIONS = [
    { label: 'Draft', value: 'Draft' },
    { label: 'Pending Approval', value: 'Pending Approval' },
    { label: 'Active', value: 'Active' },
    { label: 'Expired', value: 'Expired' },
    { label: 'Cancelled', value: 'Cancelled' }
];

const CHANNEL_FORM_OPTIONS = [
    { label: 'GT', value: 'GT' },
    { label: 'MT', value: 'MT' },
    { label: 'E-Commerce', value: 'E-Commerce' }
];

const OUTLET_TYPE_OPTIONS = [
    { label: 'Grocery', value: 'Grocery' },
    { label: 'Medical', value: 'Medical' },
    { label: 'Hardware', value: 'Hardware' },
    { label: 'General Store', value: 'General Store' }
];

const TIER_OPTIONS = [
    { label: '--None--', value: '' },
    { label: 'Base', value: 'Base' },
    { label: 'Pro', value: 'Pro' },
    { label: 'Enterprise', value: 'Enterprise' }
];

const INVOICE_UOM_OPTIONS = [
    { label: 'PC', value: 'PC' },
    { label: 'KG', value: 'KG' },
    { label: 'LTR', value: 'LTR' },
    { label: 'CS', value: 'CS' }
];

const SLAB_TYPE_OPTIONS = [
    { label: 'Quantity', value: 'Quantity' },
    { label: 'Value', value: 'Value' }
];

const DISCOUNT_TYPE_OPTIONS = [
    { label: 'Percent', value: 'Percent' },
    { label: 'Amount', value: 'Amount' },
    { label: 'Free Product', value: 'Free Product' },
    { label: 'Price Discount', value: 'Price Discount' },
    { label: 'Reward Points', value: 'Reward Points' }
];

const CUSTOMER_TYPE_OPTIONS = [
    { label: '--None--', value: '' },
    { label: 'Retailer', value: 'Retailer' },
    { label: 'Distributor', value: 'Distributor' },
    { label: 'Super Stockist', value: 'Super Stockist' },
    { label: 'Modern Trade', value: 'Modern Trade' }
];

const PRODUCT_CLASSIFICATION_OPTIONS = [
    { label: '--None--', value: '' },
    { label: 'Must Sell', value: 'Must Sell' },
    { label: 'Focused Sell', value: 'Focused Sell' }
];

let _wizTempIdCounter = 0;
function wizTempId() { return 'wiztmp_' + (++_wizTempIdCounter); }

export default class SchemeManager extends NavigationMixin(LightningElement) {
    // Filter options (list view)
    statusOptions = STATUS_OPTIONS;
    categoryOptions = CATEGORY_OPTIONS;
    typeOptions = TYPE_OPTIONS;
    channelOptions = CHANNEL_OPTIONS;

    // Stats
    @track stats = {};

    // List state
    @track schemes = [];
    totalCount = 0;
    totalPages = 0;
    pageNumber = 1;
    pageSize = 25;

    // Filters
    filterStatus = '';
    filterCategory = '';
    filterType = '';
    filterChannel = '';
    searchTerm = '';
    sortField = 'CreatedDate';
    sortDirection = 'DESC';

    // UI state
    isLoading = false;
    currentView = 'list'; // list, detail, wizard
    @track selectedScheme = null;
    showDeleteConfirm = false;
    deleteTargetId = null;
    showStatusModal = false;
    statusTargetId = null;
    statusTargetName = '';
    newStatusValue = '';

    // Calculator
    calculatorQty = 0;
    calculatorValue = 0;
    @track calculatorResult = null;

    // Search debounce
    _searchTimer;

    // ── Wizard State ─────────────────────────────────────────────────────
    @track wizScheme = {};
    @track wizProducts = [];
    @track wizSlabs = [];
    @track wizMappings = [];
    wizDeletedProductIds = [];
    wizDeletedSlabIds = [];
    wizDeletedMappingIds = [];
    wizActiveStep = '1';
    @track wizProductSearchResults = [];
    @track wizFreeProductSearchResults = [];
    @track wizGetProductSearchResults = [];
    wizProductSearchTerm = '';
    wizFreeProductSearchTerm = '';
    wizGetProductSearchTerm = '';
    wizEditId = null;
    @track wizTerritorySearchResults = [];
    wizTerritorySearchTerms = {};
    @track uomOptions = [];

    // ── Wizard Option Getters ────────────────────────────────────────────
    get wizCategoryOptions() { return WIZARD_CATEGORY_OPTIONS; }
    get wizTypeOptions() { return WIZARD_TYPE_OPTIONS; }
    get wizStatusOptions() { return WIZARD_STATUS_OPTIONS; }
    get wizChannelOptions() { return CHANNEL_FORM_OPTIONS; }
    get wizOutletTypeOptions() { return OUTLET_TYPE_OPTIONS; }
    get wizTierOptions() { return TIER_OPTIONS; }
    get wizInvoiceUomOptions() { return INVOICE_UOM_OPTIONS; }
    get wizSlabTypeOptions() { return SLAB_TYPE_OPTIONS; }
    get wizDiscountTypeOptions() { return DISCOUNT_TYPE_OPTIONS; }
    get wizCustomerTypeOptions() { return CUSTOMER_TYPE_OPTIONS; }
    get wizProductClassificationOptions() { return PRODUCT_CLASSIFICATION_OPTIONS; }

    // ── Lifecycle ────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadStats();
        this.loadSchemes();
        this.loadUOMOptions();
        this._handleDocClick = this.handleDocumentClick.bind(this);
        document.addEventListener('click', this._handleDocClick);
    }

    disconnectedCallback() {
        document.removeEventListener('click', this._handleDocClick);
    }

    handleDocumentClick(event) {
        const wrapper = this.template.querySelector('.wiz-product-search-wrapper');
        if (!wrapper) return;
        const wrappers = this.template.querySelectorAll('.wiz-product-search-wrapper');
        let insideAny = false;
        wrappers.forEach(w => {
            if (w.contains(event.target)) insideAny = true;
        });
        if (!insideAny) {
            this.clearAllSearchDropdowns();
        }
    }

    clearAllSearchDropdowns() {
        this.wizProductSearchResults = [];
        this.wizFreeProductSearchResults = [];
        this.wizGetProductSearchResults = [];
        this.wizTerritorySearchResults = [];
        this._activeTerritoryKey = null;
    }

    // Strip the managed-package (ftretailmake__) prefix from SObject field keys
    // so the component's unqualified reads work in the namespaced org.
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

    async loadUOMOptions() {
        try {
            const uoms = this._stripNs(await getActiveUOMs());
            this.uomOptions = [
                { label: '-- None --', value: '' },
                ...uoms.map(u => ({ label: u.Name + ' (' + u.UOM_Code__c + ')', value: u.Id }))
            ];
        } catch (e) {
            // UOM options are non-critical; silently fallback to empty
            this.uomOptions = [{ label: '-- None --', value: '' }];
        }
    }

    // ── Stats ────────────────────────────────────────────────────────────

    async loadStats() {
        try {
            this.stats = await getSchemeStats();
        } catch (e) {
            // non-blocking
        }
    }

    get statCards() {
        return [
            { key: 'active',  label: 'Active',           value: this.stats.activeSchemes || 0,   cls: 'stat-card stat-active' },
            { key: 'draft',   label: 'Draft',             value: this.stats.draftSchemes || 0,    cls: 'stat-card stat-draft' },
            { key: 'pending', label: 'Pending Approval',  value: this.stats.pendingApproval || 0, cls: 'stat-card stat-pending' },
            { key: 'expired', label: 'Expired',           value: this.stats.expiredSchemes || 0,  cls: 'stat-card stat-expired' },
            { key: 'total',   label: 'Total Schemes',     value: this.stats.totalSchemes || 0,    cls: 'stat-card stat-total' }
        ];
    }

    get totalBudgetFormatted() {
        return this.formatCurrency(this.stats.totalBudget || 0);
    }

    get totalBudgetUsedFormatted() {
        return this.formatCurrency(this.stats.totalBudgetUsed || 0);
    }

    get budgetUtilization() {
        const total = this.stats.totalBudget || 0;
        const used = this.stats.totalBudgetUsed || 0;
        if (total === 0) return 0;
        return Math.round((used / total) * 100);
    }

    get budgetBarStyle() {
        return 'width: ' + this.budgetUtilization + '%';
    }

    get detailBudgetBarStyle() {
        if (!this.selectedScheme) return 'width: 0%';
        return 'width: ' + this.selectedScheme.budgetPercent + '%';
    }

    // ── List Loading ─────────────────────────────────────────────────────

    async loadSchemes() {
        this.isLoading = true;
        try {
            const result = this._stripNs(await getSchemes({
                status: this.filterStatus || null,
                category: this.filterCategory || null,
                schemeType: this.filterType || null,
                channel: this.filterChannel || null,
                searchTerm: this.searchTerm || null,
                pageSize: this.pageSize,
                pageNumber: this.pageNumber,
                sortField: this.sortField,
                sortDirection: this.sortDirection
            }));

            this.schemes = (result.schemes || []).map(s => this.mapSchemeRow(s));
            this.totalCount = result.totalCount || 0;
            this.totalPages = result.totalPages || 0;
            this.pageNumber = result.pageNumber || 1;
        } catch (error) {
            this.showToast('Error', 'Failed to load schemes: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    mapSchemeRow(scheme) {
        const catConfig = CATEGORY_COLORS[scheme.Scheme_Category__c] || { bg: '#f3f3f3', color: '#706e6b', short: '?' };
        const statusConfig = STATUS_CONFIG[scheme.Status__c] || STATUS_CONFIG['Draft'];
        const isSelected = this.selectedScheme && this.selectedScheme.id === scheme.Id;

        const buyProducts = scheme.Scheme_Products__r
            ? scheme.Scheme_Products__r.filter(p => p.Is_Buy_Product__c)
            : [];
        const getProducts = scheme.Scheme_Products__r
            ? scheme.Scheme_Products__r.filter(p => p.Is_Get_Product__c)
            : [];

        return {
            id: scheme.Id,
            name: scheme.Name,
            code: scheme.Scheme_Code__c || '',
            category: scheme.Scheme_Category__c || '',
            schemeType: scheme.Scheme_Type__c || '',
            description: scheme.Description__c || '',
            status: scheme.Status__c || 'Draft',
            statusClass: 'status-badge ' + statusConfig.class,
            statusIcon: statusConfig.icon,
            categoryShort: catConfig.short,
            categoryBadgeStyle: 'background-color: ' + catConfig.bg + '; color: ' + catConfig.color,
            startDate: this.formatDate(scheme.Start_Date__c),
            endDate: this.formatDate(scheme.End_Date__c),
            startDateRaw: scheme.Start_Date__c,
            endDateRaw: scheme.End_Date__c,
            channel: scheme.Applicable_Channel__c || 'All',
            priority: scheme.Priority__c || '-',
            isStackable: scheme.Is_Stackable__c || false,
            budgetAmount: scheme.Budget_Amount__c,
            budgetUsed: scheme.Budget_Used__c,
            budgetRemaining: scheme.Budget_Remaining__c,
            budgetFormatted: this.formatCurrency(scheme.Budget_Amount__c || 0),
            benefitSummary: this.getBenefitSummary(scheme),
            triggerSummary: this.getTriggerSummary(scheme),
            buyProductCount: buyProducts.length,
            getProductCount: getProducts.length,
            productBadges: buyProducts.slice(0, 3).map(p => ({
                key: p.Id,
                name: p.Product_Ext__r ? p.Product_Ext__r.Name : 'Product',
                classification: p.Product_Classification__c || '',
                classificationClass: p.Product_Classification__c === 'Must Sell' ? 'badge-must-sell' :
                                     p.Product_Classification__c === 'Focused Sell' ? 'badge-focused-sell' : ''
            })),
            hasSlabs: scheme.Scheme_Slabs__r && scheme.Scheme_Slabs__r.length > 0,
            hasMappings: scheme.Scheme_Mappings__r && scheme.Scheme_Mappings__r.length > 0,
            cardClass: 'scheme-row' + (isSelected ? ' scheme-row-selected' : ''),
            createdDate: this.formatDate(scheme.CreatedDate),
            isDraft: scheme.Status__c === 'Draft',
            isActive: scheme.Status__c === 'Active',
            isPending: scheme.Status__c === 'Pending Approval',
            canEdit: scheme.Status__c === 'Draft' || scheme.Status__c === 'Active',
            canDelete: scheme.Status__c === 'Draft' || scheme.Status__c === 'Expired' || scheme.Status__c === 'Cancelled',
            canActivate: scheme.Status__c === 'Draft',
            canDeactivate: scheme.Status__c === 'Active',
            canSubmit: scheme.Status__c === 'Draft'
        };
    }

    getBenefitSummary(scheme) {
        const cat = scheme.Scheme_Category__c;
        if (cat === 'Free Products') {
            const name = scheme.Free_Product_Ext__r ? scheme.Free_Product_Ext__r.Name : 'product';
            return 'Get ' + (scheme.Free_Quantity__c || 0) + ' ' + name + ' free';
        } else if (cat === 'Discount in %') {
            return (scheme.Discount_Percent__c || 0) + '% discount';
        } else if (cat === 'Discount in Value') {
            return this.formatCurrency(scheme.Price_Discount__c || scheme.Discount_Amount__c || 0) + ' off';
        } else if (cat === 'Reward Points') {
            return (scheme.Reward_Points__c || 0) + ' reward points';
        }
        return '';
    }

    getTriggerSummary(scheme) {
        const type = scheme.Scheme_Type__c;
        if (type === 'Same Product (QTY)') return 'Min ' + (scheme.Min_Quantity__c || 0) + ' qty';
        if (type === 'Same Product (VAL)') return 'MOV ' + this.formatCurrency(scheme.MOV__c || 0);
        if (type === 'Assorted Product (QTY)') return 'Assorted (qty)';
        if (type === 'Assorted Product (VAL)') return 'Assorted (val)';
        if (type === 'Invoice Qty Based') return 'Inv qty ' + (scheme.Invoice_Qty_Threshold__c || 0);
        if (type === 'Invoice Val Based') return 'Inv val ' + this.formatCurrency(scheme.Invoice_Val_Threshold__c || 0);
        return type || '';
    }

    // ── View Management ──────────────────────────────────────────────────

    get isListView() { return this.currentView === 'list'; }
    get isDetailView() { return this.currentView === 'detail'; }
    get isWizardView() { return this.currentView === 'wizard'; }
    get hasSchemes() { return this.schemes.length > 0; }
    get showPagination() { return this.totalPages > 1; }
    get isFirstPage() { return this.pageNumber <= 1; }
    get isLastPage() { return this.pageNumber >= this.totalPages; }

    get paginationInfo() {
        const start = ((this.pageNumber - 1) * this.pageSize) + 1;
        const end = Math.min(this.pageNumber * this.pageSize, this.totalCount);
        return start + '-' + end + ' of ' + this.totalCount;
    }

    get sortIconName() {
        return this.sortDirection === 'ASC' ? 'utility:arrowup' : 'utility:arrowdown';
    }

    get sortLabel() {
        const labels = {
            'CreatedDate': 'Created Date',
            'Name': 'Name',
            'Status__c': 'Status',
            'Start_Date__c': 'Start Date',
            'End_Date__c': 'End Date',
            'Priority__c': 'Priority'
        };
        return labels[this.sortField] || this.sortField;
    }

    get sortOptions() {
        return [
            { label: 'Created Date', value: 'CreatedDate' },
            { label: 'Name', value: 'Name' },
            { label: 'Status', value: 'Status__c' },
            { label: 'Start Date', value: 'Start_Date__c' },
            { label: 'End Date', value: 'End_Date__c' },
            { label: 'Priority', value: 'Priority__c' }
        ];
    }

    // ── Filter Handlers ──────────────────────────────────────────────────

    handleSearchInput(event) {
        const term = event.detail.value;
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => {
            this.searchTerm = term;
            this.pageNumber = 1;
            this.loadSchemes();
        }, 400);
    }

    handleStatusFilter(event) {
        this.filterStatus = event.detail.value;
        this.pageNumber = 1;
        this.loadSchemes();
    }

    handleCategoryFilter(event) {
        this.filterCategory = event.detail.value;
        this.pageNumber = 1;
        this.loadSchemes();
    }

    handleTypeFilter(event) {
        this.filterType = event.detail.value;
        this.pageNumber = 1;
        this.loadSchemes();
    }

    handleChannelFilter(event) {
        this.filterChannel = event.detail.value;
        this.pageNumber = 1;
        this.loadSchemes();
    }

    handleClearFilters() {
        this.filterStatus = '';
        this.filterCategory = '';
        this.filterType = '';
        this.filterChannel = '';
        this.searchTerm = '';
        this.pageNumber = 1;
        this.loadSchemes();
    }

    handleSortChange(event) {
        this.sortField = event.detail.value;
        this.pageNumber = 1;
        this.loadSchemes();
    }

    handleToggleSortDir() {
        this.sortDirection = this.sortDirection === 'ASC' ? 'DESC' : 'ASC';
        this.loadSchemes();
    }

    handleStatCardClick(event) {
        const key = event.currentTarget.dataset.key;
        const statusMap = {
            'active': 'Active',
            'draft': 'Draft',
            'pending': 'Pending Approval',
            'expired': 'Expired',
            'total': ''
        };
        this.filterStatus = statusMap[key] || '';
        this.pageNumber = 1;
        this.loadSchemes();
    }

    // ── Pagination ───────────────────────────────────────────────────────

    handlePrevPage() {
        if (this.pageNumber > 1) {
            this.pageNumber--;
            this.loadSchemes();
        }
    }

    handleNextPage() {
        if (this.pageNumber < this.totalPages) {
            this.pageNumber++;
            this.loadSchemes();
        }
    }

    // ── Scheme Actions ───────────────────────────────────────────────────

    handleNewScheme() {
        this.resetWizard();
        this.currentView = 'wizard';
        this.wizGenCode();
    }

    handleSchemeClick(event) {
        const schemeId = event.currentTarget.dataset.id;
        this.openSchemeDetail(schemeId);
    }

    async openSchemeDetail(schemeId) {
        this.isLoading = true;
        try {
            const details = this._stripNs(await getSchemeDetails({ schemeId }));
            this.selectedScheme = this.mapSchemeDetail(details);
            this.currentView = 'detail';
            this.calculatorResult = null;
            this.calculatorQty = 0;
            this.calculatorValue = 0;
        } catch (error) {
            this.showToast('Error', 'Failed to load scheme: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    mapSchemeDetail(scheme) {
        const catConfig = CATEGORY_COLORS[scheme.Scheme_Category__c] || { bg: '#f3f3f3', color: '#706e6b', short: '?' };
        const statusConfig = STATUS_CONFIG[scheme.Status__c] || STATUS_CONFIG['Draft'];

        const buyProducts = (scheme.Scheme_Products__r || [])
            .filter(p => p.Is_Buy_Product__c)
            .map(p => ({
                id: p.Id,
                name: p.Product_Ext__r ? p.Product_Ext__r.Name : 'Product',
                sku: p.Product_Ext__r ? (p.Product_Ext__r.SKU_Code__c || '') : '',
                minQty: p.Min_Quantity__c || 0,
                classification: p.Product_Classification__c || '',
                classificationClass: p.Product_Classification__c === 'Must Sell' ? 'classification-must-sell' :
                                     p.Product_Classification__c === 'Focused Sell' ? 'classification-focused-sell' : '',
                isMustSell: p.Product_Classification__c === 'Must Sell',
                isFocusedSell: p.Product_Classification__c === 'Focused Sell'
            }));

        const getProducts = (scheme.Scheme_Products__r || [])
            .filter(p => p.Is_Get_Product__c)
            .map(p => ({
                id: p.Id,
                name: p.Product_Ext__r ? p.Product_Ext__r.Name : 'Product',
                sku: p.Product_Ext__r ? (p.Product_Ext__r.SKU_Code__c || '') : ''
            }));

        const slabs = (scheme.Scheme_Slabs__r || []).map((slab, idx) => ({
            id: slab.Id || 'slab_' + idx,
            slabType: slab.Slab_Type__c || 'Value',
            minValue: slab.Min_Value__c || 0,
            maxValue: slab.Max_Value__c != null ? slab.Max_Value__c : 'Unlimited',
            discountType: slab.Discount_Type__c || '',
            discountPercent: slab.Discount_Percent__c || slab.Discount_Value__c || 0,
            freeQty: slab.Free_Quantity__c || 0,
            freeProduct: slab.Free_Product_Ext__r ? slab.Free_Product_Ext__r.Name : '',
            priceDiscount: slab.Price_Discount__c || 0,
            rewardPoints: slab.Reward_Points__c || 0,
            benefitText: this.getSlabBenefitText(slab)
        }));

        const mappings = (scheme.Scheme_Mappings__r || []).map(m => ({
            id: m.Id,
            territory: m.Territory__r ? m.Territory__r.Name : '-',
            zone: m.Zone__c || '-',
            subZone: m.Sub_Zone__c || '-',
            district: m.District__c || '-',
            area: m.Area__c || '-',
            customerType: m.Customer_Type__c || '-',
            account: m.Account__r ? m.Account__r.Name : '-'
        }));

        return {
            id: scheme.Id,
            name: scheme.Name,
            code: scheme.Scheme_Code__c || '',
            category: scheme.Scheme_Category__c || '',
            schemeType: scheme.Scheme_Type__c || '',
            description: scheme.Description__c || '',
            status: scheme.Status__c || 'Draft',
            statusClass: 'status-badge-lg ' + statusConfig.class,
            statusIcon: statusConfig.icon,
            categoryShort: catConfig.short,
            categoryBadgeStyle: 'background-color: ' + catConfig.bg + '; color: ' + catConfig.color,
            startDate: this.formatDate(scheme.Start_Date__c),
            endDate: this.formatDate(scheme.End_Date__c),
            channel: scheme.Applicable_Channel__c || 'All',
            outletType: scheme.Applicable_Outlet_Type__c || 'All',
            region: scheme.Applicable_Region__c || 'All',
            priority: scheme.Priority__c || '-',
            isStackable: scheme.Is_Stackable__c || false,
            stackableLabel: scheme.Is_Stackable__c ? 'Yes' : 'No',
            maxUsagePerCustomer: scheme.Max_Usage_Per_Customer__c != null ? scheme.Max_Usage_Per_Customer__c : null,
            maxUsageLabel: scheme.Max_Usage_Per_Customer__c != null ? String(scheme.Max_Usage_Per_Customer__c) : 'Unlimited',
            hasUsageLimit: scheme.Max_Usage_Per_Customer__c != null && scheme.Max_Usage_Per_Customer__c > 0,
            budgetAmount: this.formatCurrency(scheme.Budget_Amount__c || 0),
            budgetUsed: this.formatCurrency(scheme.Budget_Used__c || 0),
            budgetRemaining: this.formatCurrency(scheme.Budget_Remaining__c || 0),
            hasBudget: (scheme.Budget_Amount__c || 0) > 0,
            budgetPercent: scheme.Budget_Amount__c > 0
                ? Math.round(((scheme.Budget_Used__c || 0) / scheme.Budget_Amount__c) * 100) : 0,
            benefitSummary: this.getBenefitSummary(scheme),
            triggerSummary: this.getTriggerSummary(scheme),
            discountPercent: scheme.Discount_Percent__c,
            discountAmount: scheme.Discount_Amount__c,
            priceDiscount: scheme.Price_Discount__c,
            rewardPoints: scheme.Reward_Points__c,
            mov: scheme.MOV__c,
            freeQty: scheme.Free_Quantity__c,
            freeProductName: scheme.Free_Product_Ext__r ? scheme.Free_Product_Ext__r.Name : '',
            minQty: scheme.Min_Quantity__c,
            maxQty: scheme.Max_Quantity__c,
            invoiceQtyThreshold: scheme.Invoice_Qty_Threshold__c,
            invoiceQtyUom: scheme.Invoice_Qty_UOM__c || '',
            invoiceValThreshold: scheme.Invoice_Val_Threshold__c,
            maxDiscountCap: scheme.Max_Discount_Cap__c,
            minValue: scheme.Min_Value__c,
            maxValue: scheme.Max_Value__c,
            tier: scheme.Tier__c || '-',
            baseUom: scheme.Base_UOM__r ? scheme.Base_UOM__r.Name : '-',
            isActive: scheme.Is_Active__c ? 'Yes' : 'No',
            buyProducts,
            getProducts,
            slabs,
            mappings,
            hasBuyProducts: buyProducts.length > 0,
            hasGetProducts: getProducts.length > 0,
            hasSlabs: slabs.length > 0,
            hasMappings: mappings.length > 0,
            hasMustSellProducts: buyProducts.some(p => p.isMustSell),
            hasFocusedSellProducts: buyProducts.some(p => p.isFocusedSell),
            isDraft: scheme.Status__c === 'Draft',
            isActive: scheme.Status__c === 'Active',
            canEdit: scheme.Status__c === 'Draft' || scheme.Status__c === 'Active',
            canDelete: scheme.Status__c !== 'Active',
            canActivate: scheme.Status__c === 'Draft',
            canDeactivate: scheme.Status__c === 'Active',
            canSubmit: scheme.Status__c === 'Draft'
        };
    }

    getSlabBenefitText(slab) {
        const dt = slab.Discount_Type__c;
        if (dt === 'Percent') return (slab.Discount_Value__c || slab.Discount_Percent__c || 0) + '%';
        if (dt === 'Amount') return this.formatCurrency(slab.Discount_Value__c || slab.Discount_Amount__c || 0);
        if (dt === 'Free Product') return (slab.Free_Quantity__c || 0) + ' free';
        if (dt === 'Price Discount') return this.formatCurrency(slab.Price_Discount__c || 0) + ' off';
        if (dt === 'Reward Points') return (slab.Reward_Points__c || 0) + ' pts';
        return '-';
    }

    handleBackToList() {
        this.currentView = 'list';
        this.selectedScheme = null;
        this.loadSchemes();
        this.loadStats();
    }

    // ── Edit Scheme ──────────────────────────────────────────────────────

    handleEditScheme(event) {
        const schemeId = event.currentTarget.dataset.id || (this.selectedScheme && this.selectedScheme.id);
        if (!schemeId) return;
        this.resetWizard();
        this.wizEditId = schemeId;
        this.currentView = 'wizard';
        this.loadWizScheme(schemeId);
    }

    handleViewRecord() {
        if (!this.selectedScheme) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.selectedScheme.id,
                objectApiName: 'Scheme__c',
                actionName: 'view'
            }
        });
    }

    // ── Clone Scheme ─────────────────────────────────────────────────────

    async handleCloneScheme(event) {
        const schemeId = event.currentTarget.dataset.id || (this.selectedScheme && this.selectedScheme.id);
        if (!schemeId) return;

        this.isLoading = true;
        try {
            const newId = await cloneScheme({ schemeId });
            this.showToast('Success', 'Scheme cloned successfully', 'success');
            this.openSchemeDetail(newId);
            this.loadStats();
        } catch (error) {
            this.showToast('Error', 'Clone failed: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Status Change ────────────────────────────────────────────────────

    handleStatusChange(event) {
        const schemeId = event.currentTarget.dataset.id || (this.selectedScheme && this.selectedScheme.id);
        const newStatus = event.currentTarget.dataset.status;
        if (!schemeId || !newStatus) return;

        this.statusTargetId = schemeId;
        this.newStatusValue = newStatus;
        const scheme = this.schemes.find(s => s.id === schemeId) || this.selectedScheme;
        this.statusTargetName = scheme ? scheme.name : '';
        this.showStatusModal = true;
    }

    async handleConfirmStatusChange() {
        this.showStatusModal = false;
        this.isLoading = true;
        try {
            await updateSchemeStatus({ schemeId: this.statusTargetId, newStatus: this.newStatusValue });
            this.showToast('Success', 'Status updated to ' + this.newStatusValue, 'success');

            if (this.isDetailView && this.selectedScheme) {
                await this.openSchemeDetail(this.statusTargetId);
            }
            this.loadSchemes();
            this.loadStats();
        } catch (error) {
            this.showToast('Error', 'Status change failed: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleCancelStatusChange() {
        this.showStatusModal = false;
    }

    get statusChangeMessage() {
        return 'Change status of "' + this.statusTargetName + '" to ' + this.newStatusValue + '?';
    }

    // ── Delete Scheme ────────────────────────────────────────────────────

    handleDeleteScheme(event) {
        const schemeId = event.currentTarget.dataset.id || (this.selectedScheme && this.selectedScheme.id);
        if (!schemeId) return;
        this.deleteTargetId = schemeId;
        this.showDeleteConfirm = true;
    }

    async handleConfirmDelete() {
        this.showDeleteConfirm = false;
        this.isLoading = true;
        try {
            await deleteScheme({ schemeId: this.deleteTargetId });
            this.showToast('Success', 'Scheme deleted', 'success');

            if (this.isDetailView) {
                this.currentView = 'list';
                this.selectedScheme = null;
            }
            this.loadSchemes();
            this.loadStats();
        } catch (error) {
            this.showToast('Error', 'Delete failed: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleCancelDelete() {
        this.showDeleteConfirm = false;
    }

    // ── Calculator ───────────────────────────────────────────────────────

    handleCalculatorQtyChange(event) {
        this.calculatorQty = parseInt(event.detail.value, 10) || 0;
    }

    handleCalculatorValueChange(event) {
        this.calculatorValue = parseFloat(event.detail.value) || 0;
    }

    async handleCalculate() {
        if (!this.selectedScheme) return;
        if (this.calculatorQty <= 0 && this.calculatorValue <= 0) {
            this.showToast('Warning', 'Enter quantity or value', 'warning');
            return;
        }

        try {
            const result = await calculateSchemeDiscount({
                schemeId: this.selectedScheme.id,
                quantity: this.calculatorQty,
                value: this.calculatorValue
            });

            if (result) {
                const grossAmount = this.calculatorValue || 0;
                const discountAmt = (result.discountAmount || 0) + (result.priceDiscount || 0);
                const netAmount = grossAmount - discountAmt;

                this.calculatorResult = {
                    grossAmountFormatted: this.formatCurrency(grossAmount),
                    discountFormatted: this.formatCurrency(discountAmt),
                    netAmountFormatted: this.formatCurrency(netAmount),
                    freeQty: result.freeQuantity || 0,
                    freeProductName: result.freeProductName || '',
                    rewardPoints: result.rewardPoints || 0,
                    effectiveDiscountPercent: grossAmount > 0
                        ? Math.round((discountAmt / grossAmount) * 100 * 100) / 100 : 0,
                    hasDiscount: discountAmt > 0,
                    hasFreeProduct: (result.freeQuantity || 0) > 0,
                    hasRewardPoints: (result.rewardPoints || 0) > 0
                };
            }
        } catch (error) {
            this.showToast('Error', 'Calculation failed: ' + this.reduceErrors(error), 'error');
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // ── WIZARD ───────────────────────────────────────────────────────────
    // ══════════════════════════════════════════════════════════════════════

    resetWizard() {
        this.wizScheme = {
            Name: '',
            Scheme_Code__c: '',
            Scheme_Category__c: 'Free Products',
            Scheme_Type__c: 'Same Product (QTY)',
            Description__c: '',
            Start_Date__c: null,
            End_Date__c: null,
            Status__c: 'Draft',
            Applicable_Channel__c: [],
            Applicable_Outlet_Type__c: [],
            Discount_Percent__c: null,
            Discount_Amount__c: null,
            Price_Discount__c: null,
            Reward_Points__c: null,
            MOV__c: null,
            Free_Product_Ext__c: null,
            Free_Quantity__c: null,
            Min_Quantity__c: null,
            Max_Quantity__c: null,
            Min_Value__c: null,
            Max_Value__c: null,
            Invoice_Qty_Threshold__c: null,
            Invoice_Qty_UOM__c: 'PC',
            Invoice_Val_Threshold__c: null,
            Base_UOM__c: null,
            Max_Discount_Cap__c: null,
            Priority__c: 1,
            Is_Stackable__c: false,
            Tier__c: '',
            Budget_Amount__c: null,
            Max_Usage_Per_Customer__c: null,
            Product_Ext__c: null,
            Product_Category__c: null
        };
        this.wizProducts = [];
        this.wizSlabs = [];
        this.wizMappings = [];
        this.wizDeletedProductIds = [];
        this.wizDeletedSlabIds = [];
        this.wizDeletedMappingIds = [];
        this.wizActiveStep = '1';
        this.wizProductSearchResults = [];
        this.wizFreeProductSearchResults = [];
        this.wizGetProductSearchResults = [];
        this.wizProductSearchTerm = '';
        this.wizFreeProductSearchTerm = '';
        this.wizGetProductSearchTerm = '';
        this.wizEditId = null;
    }

    async wizGenCode() {
        try {
            const code = await generateSchemeCode();
            this.wizScheme = { ...this.wizScheme, Scheme_Code__c: code };
        } catch (e) {
            // non-blocking
        }
    }

    async loadWizScheme(schemeId) {
        this.isLoading = true;
        try {
            const data = this._stripNs(await getScheme({ schemeId }));
            this.wizScheme = {
                ...data,
                Applicable_Channel__c: data.Applicable_Channel__c
                    ? data.Applicable_Channel__c.split(';') : [],
                Applicable_Outlet_Type__c: data.Applicable_Outlet_Type__c
                    ? data.Applicable_Outlet_Type__c.split(';') : []
            };

            if (data.Free_Product_Ext__c && data.Free_Product_Ext__r) {
                this.wizFreeProductSearchTerm = data.Free_Product_Ext__r.Name || '';
            }

            this.wizProducts = (data.Scheme_Products__r || []).map(p => ({
                ...p,
                _key: p.Id,
                productName: p.Product_Ext__r ? p.Product_Ext__r.Name : '',
                productSku: p.Product_Ext__r ? (p.Product_Ext__r.SKU_Code__c || '') : '',
                Product_Classification__c: p.Product_Classification__c || ''
            }));

            this.wizSlabs = (data.Scheme_Slabs__r || []).map(s => ({
                ...s,
                _key: s.Id
            }));

            this.wizMappings = (data.Scheme_Mappings__r || []).map(m => ({
                ...m,
                _key: m.Id,
                accountName: m.Account__r ? m.Account__r.Name : '',
                territoryName: m.Territory__r ? m.Territory__r.Name : '',
                territoryCode: m.Territory__r ? (m.Territory__r.Territory_Code__c || '') : ''
            }));
        } catch (error) {
            this.showToast('Error', 'Failed to load scheme: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Wizard Getters ───────────────────────────────────────────────────

    get wizIsEditMode() { return !!this.wizEditId; }
    get wizPageTitle() { return this.wizIsEditMode ? 'Edit Scheme' : 'New Scheme'; }

    get wizSteps() {
        const stepLabels = ['Basic Info', 'Geo Mapping', 'Applicable Products', 'Benefit Config', 'Slabs'];
        const completed = this._wizStepCompleted();
        return stepLabels.map((label, i) => {
            const value = String(i + 1);
            const active = this.wizActiveStep === value;
            const done = completed[i];
            let circleClass = 'step-circle';
            if (active) circleClass += ' step-active';
            else if (done) circleClass += ' step-completed';
            return {
                label,
                value,
                active,
                done,
                circleClass,
                labelClass: active ? 'step-label step-label-active' : (done ? 'step-label step-label-completed' : 'step-label'),
                displayValue: done && !active ? '\u2713' : value
            };
        });
    }

    _wizStepCompleted() {
        const s = this.wizScheme;
        return [
            !!(s.Name && s.Scheme_Code__c && s.Start_Date__c && s.End_Date__c),
            this.wizMappings.length > 0,
            this.wizProducts.length > 0,
            !!(s.Scheme_Category__c && s.Scheme_Type__c),
            this.wizSlabs.length > 0
        ];
    }

    get wizIsStep1() { return this.wizActiveStep === '1'; }
    get wizIsStep2() { return this.wizActiveStep === '4'; }
    get wizIsStep3() { return this.wizActiveStep === '3'; }
    get wizIsStep4() { return this.wizActiveStep === '5'; }
    get wizIsStep5() { return this.wizActiveStep === '2'; }
    get wizIsFirstStep() { return this.wizActiveStep === '1'; }
    get wizIsLastStep() { return this.wizActiveStep === '5'; }

    // Category/Type conditional getters
    get wizIsFreeProducts() { return this.wizScheme.Scheme_Category__c === 'Free Products'; }
    get wizIsSameProductType() {
        const t = this.wizScheme.Scheme_Type__c || '';
        return t.startsWith('Same Product');
    }
    get wizIsDiscountPercent() { return this.wizScheme.Scheme_Category__c === 'Discount in %'; }
    get wizIsDiscountValue() { return this.wizScheme.Scheme_Category__c === 'Discount in Value'; }
    get wizIsRewardPoints() { return this.wizScheme.Scheme_Category__c === 'Reward Points'; }

    get wizIsQtyBased() {
        const t = this.wizScheme.Scheme_Type__c;
        return t === 'Same Product (QTY)' || t === 'Assorted Product (QTY)';
    }
    get wizIsValBased() {
        const t = this.wizScheme.Scheme_Type__c;
        return t === 'Same Product (VAL)' || t === 'Assorted Product (VAL)';
    }
    get wizIsInvoiceQtyBased() { return this.wizScheme.Scheme_Type__c === 'Invoice Qty Based'; }
    get wizIsInvoiceValBased() { return this.wizScheme.Scheme_Type__c === 'Invoice Val Based'; }

    get wizShowMinMaxQty() { return this.wizIsQtyBased; }
    get wizShowMOV() { return this.wizIsValBased; }
    get wizShowInvoiceQtyFields() { return this.wizIsInvoiceQtyBased; }
    get wizShowInvoiceValFields() { return this.wizIsInvoiceValBased; }
    get wizShowBaseUOM() { return this.wizIsQtyBased || this.wizIsInvoiceQtyBased; }

    // Product/slab/mapping list getters
    get wizBuyProducts() { return this.wizProducts.filter(p => p.Is_Buy_Product__c); }
    get wizGetProducts() { return this.wizProducts.filter(p => p.Is_Get_Product__c); }
    get wizHasBuyProducts() { return this.wizBuyProducts.length > 0; }
    get wizHasGetProducts() { return this.wizGetProducts.length > 0; }
    get wizHasProducts() { return this.wizProducts.length > 0; }
    get wizHasSlabs() { return this.wizSlabs.length > 0; }

    get wizSlabsComputed() {
        return this.wizSlabs.map((s, index) => ({
            ...s,
            showDiscountValue: s.Discount_Type__c === 'Percent' || s.Discount_Type__c === 'Amount',
            showFreeQty: s.Discount_Type__c === 'Free Product',
            showPriceDiscount: s.Discount_Type__c === 'Price Discount',
            showRewardPoints: s.Discount_Type__c === 'Reward Points',
            // Used by the amount/percentage slab grid on the Basic Info step.
            _rowNo: index + 1,
            _fromFormatted: this.formatSlabAmount(s.Min_Value__c),
            _toFormatted: this.formatSlabAmount(s.Max_Value__c),
            _error: this.slabRowError(s, index),
            _hasError: !!this.slabRowError(s, index)
        }));
    }

    formatSlabAmount(value) {
        const n = Number(value);
        if (value === null || value === undefined || value === '' || isNaN(n)) {
            return '₹0';
        }
        return '₹' + new Intl.NumberFormat('en-IN', { maximumFractionDigits: 0 }).format(n);
    }

    /**
     * Validates one row of the slab grid: every field filled, the range going
     * upwards, a sane percentage, and no overlap with the row above.
     * Returns '' when the row is acceptable.
     */
    slabRowError(slab, index) {
        const from = slab.Min_Value__c;
        const to = slab.Max_Value__c;
        const pct = slab.Discount_Percent__c;

        const blank = v => v === null || v === undefined || v === '';
        if (blank(from) || blank(to) || blank(pct)) {
            return 'Complete all fields';
        }
        if (Number(to) <= Number(from)) {
            return 'To amount must be greater than from amount';
        }
        if (Number(pct) < 0 || Number(pct) > 100) {
            return 'Enter a percentage between 0 and 100';
        }
        if (index > 0) {
            const previous = this.wizSlabs[index - 1];
            if (!blank(previous.Max_Value__c) && Number(from) < Number(previous.Max_Value__c)) {
                return 'This range overlaps the previous slab';
            }
        }
        return '';
    }
    get wizHasMappings() { return this.wizMappings.length > 0; }

    // ── Wizard Step Navigation ───────────────────────────────────────────

    handleWizStepClick(event) {
        this.wizActiveStep = event.currentTarget.dataset.step;
    }

    handleWizNext() {
        this.clearAllSearchDropdowns();
        const num = parseInt(this.wizActiveStep, 10);
        if (num < 5) this.wizActiveStep = String(num + 1);
    }

    handleWizPrevious() {
        this.clearAllSearchDropdowns();
        const num = parseInt(this.wizActiveStep, 10);
        if (num > 1) this.wizActiveStep = String(num - 1);
    }

    // ── Wizard Field Handlers ────────────────────────────────────────────

    handleWizFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.detail.value;
        this.wizScheme = { ...this.wizScheme, [field]: value };
    }

    handleWizCheckboxChange(event) {
        const field = event.target.dataset.field;
        this.wizScheme = { ...this.wizScheme, [field]: event.target.checked };
    }

    // ── Wizard Product Search & Management ───────────────────────────────

    handleWizProductSearch(event) {
        this.wizProductSearchTerm = event.detail.value;
        if (this.wizProductSearchTerm.length >= 2) {
            this.doWizProductSearch(this.wizProductSearchTerm, 'buy');
        } else {
            this.wizProductSearchResults = [];
        }
    }

    handleWizFreeProductSearch(event) {
        this.wizFreeProductSearchTerm = event.detail.value;
        if (this.wizFreeProductSearchTerm.length >= 2) {
            this.doWizProductSearch(this.wizFreeProductSearchTerm, 'free');
        } else {
            this.wizFreeProductSearchResults = [];
        }
    }

    async doWizProductSearch(term, context) {
        try {
            const results = this._stripNs(await searchProducts({ searchTerm: term }));
            const mapped = results.map(p => ({
                id: p.Id,
                name: p.Name,
                sku: p.SKU_Code__c || '',
                brand: p.Brand__c || '',
                mrp: p.MRP__c || 0,
                imageUrl: p.Product_Image_URL__c || '',
                hasImage: !!p.Product_Image_URL__c,
                label: p.Name + (p.SKU_Code__c ? ' (' + p.SKU_Code__c + ')' : '')
            }));
            if (context === 'free') {
                this.wizFreeProductSearchResults = mapped;
            } else if (context === 'get') {
                this.wizGetProductSearchResults = mapped;
            } else {
                this.wizProductSearchResults = mapped;
            }
        } catch (e) {
            // silent
        }
    }

    handleWizSelectProduct(event) {
        const prodId = event.currentTarget.dataset.id;
        const prod = this.wizProductSearchResults.find(p => p.id === prodId);
        if (!prod) return;

        if (this.wizProducts.some(p => p.Product_Ext__c === prodId && p.Is_Buy_Product__c)) return;

        this.wizProducts = [...this.wizProducts, {
            _key: wizTempId(),
            Product_Ext__c: prodId,
            productName: prod.name,
            productSku: prod.sku,
            Is_Buy_Product__c: true,
            Is_Get_Product__c: false,
            Min_Quantity__c: 1,
            Product_Classification__c: ''
        }];
        this.wizProductSearchResults = [];
        this.wizProductSearchTerm = '';
    }

    handleWizSelectFreeProduct(event) {
        const prodId = event.currentTarget.dataset.id;
        const prod = this.wizFreeProductSearchResults.find(p => p.id === prodId);
        if (!prod) return;

        this.wizScheme = { ...this.wizScheme, Free_Product_Ext__c: prodId };
        this.wizFreeProductSearchResults = [];
        this.wizFreeProductSearchTerm = prod.name;
    }

    handleWizGetProductSearch(event) {
        this.wizGetProductSearchTerm = event.detail.value;
        if (this.wizGetProductSearchTerm.length >= 2) {
            this.doWizProductSearch(this.wizGetProductSearchTerm, 'get');
        } else {
            this.wizGetProductSearchResults = [];
        }
    }

    handleWizSelectGetProduct(event) {
        const prodId = event.currentTarget.dataset.id;
        const prod = this.wizGetProductSearchResults.find(p => p.id === prodId);
        if (!prod) return;

        if (this.wizProducts.some(p => p.Product_Ext__c === prodId && p.Is_Get_Product__c)) return;

        this.wizProducts = [...this.wizProducts, {
            _key: wizTempId(),
            Product_Ext__c: prodId,
            productName: prod.name,
            productSku: prod.sku,
            Is_Buy_Product__c: false,
            Is_Get_Product__c: true,
            Min_Quantity__c: 0
        }];
        this.wizGetProductSearchResults = [];
        this.wizGetProductSearchTerm = '';
    }

    handleWizProductMinQtyChange(event) {
        const key = event.target.dataset.key;
        const val = parseInt(event.detail.value, 10) || 0;
        this.wizProducts = this.wizProducts.map(p =>
            p._key === key ? { ...p, Min_Quantity__c: val } : p
        );
    }

    handleWizProductClassificationChange(event) {
        const key = event.target.dataset.key;
        const val = event.detail.value;
        this.wizProducts = this.wizProducts.map(p =>
            p._key === key ? { ...p, Product_Classification__c: val } : p
        );
    }

    handleWizRemoveProduct(event) {
        const key = event.currentTarget.dataset.key;
        const prod = this.wizProducts.find(p => p._key === key);
        if (prod && prod.Id) {
            this.wizDeletedProductIds.push(prod.Id);
        }
        this.wizProducts = this.wizProducts.filter(p => p._key !== key);
    }

    // ── Wizard Slab Management ───────────────────────────────────────────

    handleWizAddSlab() {
        // Auto-suggest min value from previous slab's max + 1
        let suggestedMin = 0;
        if (this.wizSlabs.length > 0) {
            const lastSlab = this.wizSlabs[this.wizSlabs.length - 1];
            const lastMax = Number(lastSlab.Max_Value__c || lastSlab.Max_Quantity__c || 0);
            if (lastMax > 0) suggestedMin = lastMax + 1;
        }
        this.wizSlabs = [...this.wizSlabs, {
            _key: wizTempId(),
            Slab_Type__c: 'Quantity',
            Min_Value__c: suggestedMin,
            Max_Value__c: null,
            Min_Quantity__c: null,
            Max_Quantity__c: null,
            Discount_Type__c: 'Percent',
            Discount_Value__c: 0,
            Discount_Percent__c: null,
            Discount_Amount__c: null,
            Price_Discount__c: null,
            Reward_Points__c: null,
            Free_Product_Ext__c: null,
            Free_Quantity__c: null,
            Is_Active__c: true
        }];
    }

    handleWizSlabFieldChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        const value = event.detail.value;
        this.wizSlabs = this.wizSlabs.map(s =>
            s._key === key ? { ...s, [field]: value } : s
        );
    }

    handleWizRemoveSlab(event) {
        const key = event.currentTarget.dataset.key;
        const slab = this.wizSlabs.find(s => s._key === key);
        if (slab && slab.Id) {
            this.wizDeletedSlabIds.push(slab.Id);
        }
        this.wizSlabs = this.wizSlabs.filter(s => s._key !== key);
    }

    // ── Wizard Mapping Management ────────────────────────────────────────

    handleWizAddMapping() {
        this.wizMappings = [...this.wizMappings, {
            _key: wizTempId(),
            Territory__c: null,
            territoryName: '',
            territoryCode: '',
            Zone__c: '',
            Sub_Zone__c: '',
            District__c: '',
            Area__c: '',
            Customer_Type__c: '',
            Is_Active__c: true
        }];
    }

    handleWizTerritorySearch(event) {
        const key = event.target.dataset.key;
        const term = event.detail.value;
        this.wizTerritorySearchTerms = { ...this.wizTerritorySearchTerms, [key]: term };
        if (term.length >= 2) {
            this.doWizTerritorySearch(term, key);
        } else {
            this.wizTerritorySearchResults = [];
            this._activeTerritoryKey = null;
        }
    }

    async doWizTerritorySearch(term, mappingKey) {
        try {
            const results = this._stripNs(await searchTerritories({ searchTerm: term }));
            this.wizTerritorySearchResults = results.map(t => ({
                id: t.Id,
                name: t.Name,
                code: t.Territory_Code__c || '',
                region: t.Region__r ? t.Region__r.Name : '',
                state: t.State__c || '',
                city: t.City__c || '',
                label: t.Name + (t.Territory_Code__c ? ' (' + t.Territory_Code__c + ')' : '')
            }));
            this._activeTerritoryKey = mappingKey;
        } catch (e) {
            // silent
        }
    }

    handleWizSelectTerritory(event) {
        const territoryId = event.currentTarget.dataset.id;
        const territory = this.wizTerritorySearchResults.find(t => t.id === territoryId);
        if (!territory || !this._activeTerritoryKey) return;

        const key = this._activeTerritoryKey;
        this.wizMappings = this.wizMappings.map(m => {
            if (m._key === key) {
                return {
                    ...m,
                    Territory__c: territoryId,
                    territoryName: territory.name,
                    territoryCode: territory.code,
                    Zone__c: territory.region || m.Zone__c,
                    Area__c: territory.state || m.Area__c,
                    District__c: territory.city || m.District__c
                };
            }
            return m;
        });
        this.wizTerritorySearchResults = [];
        this._activeTerritoryKey = null;
        this.wizTerritorySearchTerms = { ...this.wizTerritorySearchTerms, [key]: territory.name };
    }

    getTerritorySearchTerm(key) {
        return this.wizTerritorySearchTerms[key] || '';
    }

    handleWizMappingFieldChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        const value = event.detail.value;
        this.wizMappings = this.wizMappings.map(m =>
            m._key === key ? { ...m, [field]: value } : m
        );
    }

    handleWizRemoveMapping(event) {
        const key = event.currentTarget.dataset.key;
        const mapping = this.wizMappings.find(m => m._key === key);
        if (mapping && mapping.Id) {
            this.wizDeletedMappingIds.push(mapping.Id);
        }
        this.wizMappings = this.wizMappings.filter(m => m._key !== key);
    }

    // ── Wizard Save ──────────────────────────────────────────────────────

    async handleWizSave() {
        if (!this.wizValidateForm()) return;

        this.isLoading = true;
        try {
            const schemeToSave = this.wizBuildSchemeRecord();

            const productsToSave = this.wizProducts.map(p => {
                const rec = {
                    Product_Ext__c: p.Product_Ext__c,
                    Is_Buy_Product__c: p.Is_Buy_Product__c,
                    Is_Get_Product__c: p.Is_Get_Product__c,
                    Min_Quantity__c: p.Min_Quantity__c,
                    Product_Classification__c: p.Product_Classification__c || null
                };
                if (p.Id) rec.Id = p.Id;
                return rec;
            });

            const slabsToSave = this.wizSlabs.map(s => {
                const rec = {
                    Slab_Type__c: s.Slab_Type__c,
                    Min_Value__c: s.Min_Value__c,
                    Max_Value__c: s.Max_Value__c,
                    Min_Quantity__c: s.Min_Quantity__c,
                    Max_Quantity__c: s.Max_Quantity__c,
                    Discount_Type__c: s.Discount_Type__c,
                    Discount_Value__c: s.Discount_Value__c,
                    Discount_Percent__c: s.Discount_Percent__c,
                    Discount_Amount__c: s.Discount_Amount__c,
                    Price_Discount__c: s.Price_Discount__c,
                    Reward_Points__c: s.Reward_Points__c,
                    Free_Product_Ext__c: s.Free_Product_Ext__c,
                    Free_Quantity__c: s.Free_Quantity__c,
                    Is_Active__c: s.Is_Active__c
                };
                if (s.Id) rec.Id = s.Id;
                return rec;
            });

            const mappingsToSave = this.wizMappings.map(m => {
                const rec = {
                    Territory__c: m.Territory__c || null,
                    Zone__c: m.Zone__c,
                    Sub_Zone__c: m.Sub_Zone__c,
                    District__c: m.District__c,
                    Area__c: m.Area__c,
                    Customer_Type__c: m.Customer_Type__c,
                    Is_Active__c: m.Is_Active__c
                };
                if (m.Id) rec.Id = m.Id;
                return rec;
            });

            const schemeId = await saveScheme({
                schemeJson: JSON.stringify(schemeToSave),
                productsJson: JSON.stringify(productsToSave),
                slabsJson: JSON.stringify(slabsToSave),
                mappingsJson: JSON.stringify(mappingsToSave),
                deletedProductIds: this.wizDeletedProductIds,
                deletedSlabIds: this.wizDeletedSlabIds,
                deletedMappingIds: this.wizDeletedMappingIds
            });

            this.showToast('Success', 'Scheme saved successfully', 'success');
            this.openSchemeDetail(schemeId);
            this.loadStats();
        } catch (error) {
            this.showToast('Error', 'Failed to save: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    wizBuildSchemeRecord() {
        const s = this.wizScheme;
        const rec = {
            Name: s.Name,
            Scheme_Code__c: s.Scheme_Code__c,
            Scheme_Category__c: s.Scheme_Category__c,
            Scheme_Type__c: s.Scheme_Type__c,
            Description__c: s.Description__c || null,
            Start_Date__c: s.Start_Date__c,
            End_Date__c: s.End_Date__c,
            Status__c: s.Status__c,
            Applicable_Channel__c: Array.isArray(s.Applicable_Channel__c)
                ? (s.Applicable_Channel__c.length > 0 ? s.Applicable_Channel__c.join(';') : null)
                : (s.Applicable_Channel__c || null),
            Applicable_Outlet_Type__c: Array.isArray(s.Applicable_Outlet_Type__c)
                ? (s.Applicable_Outlet_Type__c.length > 0 ? s.Applicable_Outlet_Type__c.join(';') : null)
                : (s.Applicable_Outlet_Type__c || null),
            Discount_Percent__c: s.Discount_Percent__c,
            Discount_Amount__c: s.Discount_Amount__c,
            Price_Discount__c: s.Price_Discount__c,
            Reward_Points__c: s.Reward_Points__c,
            MOV__c: s.MOV__c,
            Free_Product_Ext__c: s.Free_Product_Ext__c || null,
            Free_Quantity__c: s.Free_Quantity__c,
            Min_Quantity__c: s.Min_Quantity__c,
            Max_Quantity__c: s.Max_Quantity__c,
            Min_Value__c: s.Min_Value__c,
            Max_Value__c: s.Max_Value__c,
            Invoice_Qty_Threshold__c: s.Invoice_Qty_Threshold__c,
            Invoice_Qty_UOM__c: s.Invoice_Qty_UOM__c || null,
            Invoice_Val_Threshold__c: s.Invoice_Val_Threshold__c,
            Base_UOM__c: s.Base_UOM__c || null,
            Max_Discount_Cap__c: s.Max_Discount_Cap__c,
            Priority__c: s.Priority__c,
            Is_Stackable__c: s.Is_Stackable__c || false,
            Tier__c: s.Tier__c || null,
            Budget_Amount__c: s.Budget_Amount__c,
            Max_Usage_Per_Customer__c: s.Max_Usage_Per_Customer__c,
            Product_Ext__c: s.Product_Ext__c || null,
            Product_Category__c: s.Product_Category__c || null
        };
        if (s.Id) rec.Id = s.Id;
        return rec;
    }

    wizValidateForm() {
        const s = this.wizScheme;
        if (!s.Name || !s.Name.trim()) {
            this.showToast('Validation', 'Scheme Name is required', 'error');
            this.wizActiveStep = '1';
            return false;
        }
        if (!s.Scheme_Code__c || !s.Scheme_Code__c.trim()) {
            this.showToast('Validation', 'Scheme Code is required', 'error');
            this.wizActiveStep = '1';
            return false;
        }
        if (!s.Start_Date__c || !s.End_Date__c) {
            this.showToast('Validation', 'Start Date and End Date are required', 'error');
            this.wizActiveStep = '1';
            return false;
        }
        if (s.Start_Date__c > s.End_Date__c) {
            this.showToast('Validation', 'End Date must be after Start Date', 'error');
            this.wizActiveStep = '1';
            return false;
        }
        // Validate slab overlaps
        if (this.wizSlabs.length > 1) {
            const sorted = [...this.wizSlabs].sort((a, b) => (a.Min_Value__c || 0) - (b.Min_Value__c || 0));
            for (let i = 1; i < sorted.length; i++) {
                const prevMax = sorted[i - 1].Max_Value__c;
                const curMin = sorted[i].Min_Value__c || 0;
                if (prevMax != null && curMin <= prevMax) {
                    this.showToast('Validation',
                        'Slab ranges overlap: Min ' + curMin + ' must be greater than previous Max ' + prevMax,
                        'error');
                    this.wizActiveStep = '5';
                    return false;
                }
            }
        }
        return true;
    }

    handleWizCancel() {
        if (this.wizEditId) {
            this.openSchemeDetail(this.wizEditId);
        } else {
            this.currentView = 'list';
            this.loadSchemes();
        }
        this.loadStats();
    }

    // ── Utilities ────────────────────────────────────────────────────────

    formatCurrency(value) {
        return new Intl.NumberFormat('en-IN', {
            style: 'currency', currency: 'INR', minimumFractionDigits: 0, maximumFractionDigits: 0
        }).format(value || 0);
    }

    formatDate(dateStr) {
        if (!dateStr) return '-';
        return new Date(dateStr).toLocaleDateString('en-IN', {
            day: '2-digit', month: 'short', year: 'numeric'
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return 'Unknown error';
    }
}