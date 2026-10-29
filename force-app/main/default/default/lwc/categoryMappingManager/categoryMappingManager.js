import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// ── Apex Imports ──────────────────────────────────────────────────────────
import getCategoryMappingStats from '@salesforce/apex/CategoryMappingController.getCategoryMappingStats';
import getAccountCategories from '@salesforce/apex/CategoryMappingController.getAccountCategories';
import getCategoryAccounts from '@salesforce/apex/CategoryMappingController.getCategoryAccounts';
import saveAccountCategory from '@salesforce/apex/CategoryMappingController.saveAccountCategory';
import deleteAccountCategory from '@salesforce/apex/CategoryMappingController.deleteAccountCategory';
import bulkAssignAccountCategories from '@salesforce/apex/CategoryMappingController.bulkAssignAccountCategories';
import getEmployeeCategories from '@salesforce/apex/CategoryMappingController.getEmployeeCategories';
import getCategoryEmployees from '@salesforce/apex/CategoryMappingController.getCategoryEmployees';
import saveEmployeeCategory from '@salesforce/apex/CategoryMappingController.saveEmployeeCategory';
import deleteEmployeeCategory from '@salesforce/apex/CategoryMappingController.deleteEmployeeCategory';
import bulkAssignEmployeeCategories from '@salesforce/apex/CategoryMappingController.bulkAssignEmployeeCategories';
import getCategoryProducts from '@salesforce/apex/CategoryMappingController.getCategoryProducts';
import searchAccountsForLookup from '@salesforce/apex/CategoryMappingController.searchAccountsForLookup';
import searchEmployeesForLookup from '@salesforce/apex/CategoryMappingController.searchEmployeesForLookup';
import getCategoryTree from '@salesforce/apex/CategoryMappingController.getCategoryTree';

export default class CategoryMappingManager extends LightningElement {

    @api section = null; // When set, locks the component to a single section view (no sidebar/tabs)

    // ── Navigation State ───────────────────────────────────────────────
    @track currentSection = 'dashboard';
    isLoading = false;
    isSaving = false;

    // ── Dashboard ──────────────────────────────────────────────────────
    @track stats = {};

    // ── Category Tree (shared across sections) ─────────────────────────
    @track categoryTree = [];

    // ── Account Categories ─────────────────────────────────────────────
    @track accountCategoryMappings = [];
    @track accountSearchTerm = '';
    @track accountCategoryFilter = '';
    @track accountActiveOnly = true;
    @track showAccountCategoryModal = false;
    @track editAccountCategory = {};
    @track isNewAccountCategory = false;
    @track selectedAccountCategoryIds = [];

    // Account Lookup
    @track accountLookupResults = [];
    @track showAccountLookup = false;
    @track selectedAccountName = '';
    @track accountLookupSearchTerm = '';
    _accountLookupTimeout;

    // Bulk Assign (Account)
    @track showBulkAccountModal = false;
    @track bulkAccountIds = '';
    @track bulkAccountCategoryIds = [];
    @track bulkAccountEffectiveFrom = '';
    @track bulkAccountEffectiveTo = '';

    // ── Employee Categories ────────────────────────────────────────────
    @track employeeCategoryMappings = [];
    @track employeeSearchTerm = '';
    @track employeeCategoryFilter = '';
    @track employeeActiveOnly = true;
    @track showEmployeeCategoryModal = false;
    @track editEmployeeCategory = {};
    @track isNewEmployeeCategory = false;
    @track selectedEmployeeCategoryIds = [];

    // Employee Lookup
    @track employeeLookupResults = [];
    @track showEmployeeLookup = false;
    @track selectedEmployeeName = '';
    @track employeeLookupSearchTerm = '';
    _employeeLookupTimeout;

    // Bulk Assign (Employee)
    @track showBulkEmployeeModal = false;
    @track bulkEmployeeIds = '';
    @track bulkEmployeeCategoryIds = [];
    @track bulkEmployeeResponsibilityType = '';
    @track bulkEmployeeEffectiveFrom = '';
    @track bulkEmployeeEffectiveTo = '';

    // ── Category Products ──────────────────────────────────────────────
    @track categoryProductFilter = '';
    @track includeSubCategories = false;
    @track categoryProducts = [];

    // ── Search timeout ─────────────────────────────────────────────────
    _searchTimeout;

    // ── Computed Getters: Section Visibility ───────────────────────────

    get showDashboard() { return this.currentSection === 'dashboard'; }
    get showAccountCategories() { return this.currentSection === 'accountCategories'; }
    get showEmployeeCategories() { return this.currentSection === 'employeeCategories'; }
    get showCategoryProducts() { return this.currentSection === 'categoryProducts'; }

    // ── Computed Getters: Layout Classes ────────────────────────────────

    get isLocked() { return this.section != null; }
    get containerClass() { return this.isLocked ? 'embedded-container' : 'hub-container'; }
    get contentClass() { return this.isLocked ? 'embedded-content' : 'main-content'; }

    // ── Computed Getters: Nav Classes ──────────────────────────────────

    get dashboardNavClass() { return 'sidebar-item' + (this.currentSection === 'dashboard' ? ' active' : ''); }
    get accountCategoriesNavClass() { return 'sidebar-item' + (this.currentSection === 'accountCategories' ? ' active' : ''); }
    get employeeCategoriesNavClass() { return 'sidebar-item' + (this.currentSection === 'employeeCategories' ? ' active' : ''); }
    get categoryProductsNavClass() { return 'sidebar-item' + (this.currentSection === 'categoryProducts' ? ' active' : ''); }

    // ── Computed Getters: Section Title ────────────────────────────────

    get sectionTitle() {
        const titles = {
            dashboard: 'Dashboard',
            accountCategories: 'Customer Categories',
            employeeCategories: 'User Categories',
            categoryProducts: 'Category Products'
        };
        return titles[this.currentSection] || 'Category Mapping Manager';
    }

    // ── Computed Getters: Modal Titles ─────────────────────────────────

    get accountCategoryModalTitle() { return this.isNewAccountCategory ? 'New Customer Category Mapping' : 'Edit Customer Category Mapping'; }
    get employeeCategoryModalTitle() { return this.isNewEmployeeCategory ? 'New User Category Mapping' : 'Edit User Category Mapping'; }

    // ── Computed Getters: Has Data ─────────────────────────────────────

    get hasAccountCategoryMappings() { return this.accountCategoryMappings.length > 0; }
    get hasEmployeeCategoryMappings() { return this.employeeCategoryMappings.length > 0; }
    get hasCategoryProducts() { return this.categoryProducts.length > 0; }
    get hasSelectedAccount() { return !!this.selectedAccountName; }
    get hasSelectedEmployee() { return !!this.selectedEmployeeName; }

    // ── Computed Getters: Options ──────────────────────────────────────

    get categoryFilterOptions() {
        const opts = [{ label: 'All Categories', value: '' }];
        if (!this.categoryTree || this.categoryTree.length === 0) return opts;
        [...this.categoryTree]
            .sort((a, b) => (a.Name || '').localeCompare(b.Name || ''))
            .forEach(c => {
                const prefix = c.Parent_Category__r ? c.Parent_Category__r.Name + ' / ' : '';
                opts.push({ label: prefix + c.Name, value: c.Id });
            });
        return opts;
    }

    get categorySelectOptions() {
        const opts = [{ label: '-- Select Category --', value: '' }];
        if (!this.categoryTree || this.categoryTree.length === 0) return opts;
        [...this.categoryTree]
            .sort((a, b) => (a.Name || '').localeCompare(b.Name || ''))
            .forEach(c => {
                const prefix = c.Parent_Category__r ? c.Parent_Category__r.Name + ' / ' : '';
                const code = c.Category_Code__c ? ' (' + c.Category_Code__c + ')' : '';
                opts.push({ label: prefix + c.Name + code, value: c.Id });
            });
        return opts;
    }

    get categoryMultiOptions() {
        if (!this.categoryTree || this.categoryTree.length === 0) return [];
        return [...this.categoryTree]
            .sort((a, b) => (a.Name || '').localeCompare(b.Name || ''))
            .map(c => {
                const prefix = c.Parent_Category__r ? c.Parent_Category__r.Name + ' / ' : '';
                return { label: prefix + c.Name, value: c.Id };
            });
    }

    get responsibilityTypeOptions() {
        return [
            { label: '-- None --', value: '' },
            { label: 'Primary', value: 'Primary' },
            { label: 'Secondary', value: 'Secondary' },
            { label: 'Backup', value: 'Backup' },
            { label: 'Supervisory', value: 'Supervisory' }
        ];
    }

    // ── Lifecycle ──────────────────────────────────────────────────────

    connectedCallback() {
        if (this.section) {
            this.currentSection = this.section;
        }
        this.loadInitialData();
    }

    async loadInitialData() {
        await this.loadCategoryTree();
        if (this.isLocked) {
            // In locked mode, go straight to the section's data
            this.loadSectionData(this.currentSection);
        } else {
            this.loadDashboard();
        }
    }

    // ── Navigation ─────────────────────────────────────────────────────

    handleSectionChange(event) {
        const section = event.currentTarget.dataset.section;
        this.currentSection = section;
        this.loadSectionData(section);
    }

    async loadSectionData(section) {
        this.isLoading = true;
        try {
            switch (section) {
                case 'dashboard': await this.loadDashboard(); break;
                case 'accountCategories': await this.loadAccountCategories(); break;
                case 'employeeCategories': await this.loadEmployeeCategories(); break;
                case 'categoryProducts': break; // loaded on demand when category is selected
                default: break;
            }
        } catch (error) {
            this.showError('Error loading data', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. Recurses into arrays
    // and child relationships. No-op on camelCase maps (getCategoryMappingStats).
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

    // ── Category Tree ──────────────────────────────────────────────────

    async loadCategoryTree() {
        try {
            this.categoryTree = this._stripNs(await getCategoryTree());
        } catch (error) {
            console.error('Failed to load category tree:', error);
        }
    }

    // ── Dashboard ──────────────────────────────────────────────────────

    async loadDashboard() {
        this.isLoading = true;
        try {
            this.stats = await getCategoryMappingStats();
        } catch (error) {
            this.showError('Error loading dashboard', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    handleStatClick(event) {
        const section = event.currentTarget.dataset.section;
        if (section) {
            this.currentSection = section;
            this.loadSectionData(section);
        }
    }

    // ── Account Categories ─────────────────────────────────────────────

    async loadAccountCategories() {
        try {
            let rawMappings = [];
            if (this.accountCategoryFilter) {
                rawMappings = this._stripNs(await getCategoryAccounts({ categoryId: this.accountCategoryFilter }));
            } else {
                rawMappings = this._stripNs(await getAccountCategories({ accountId: null }));
            }
            this.accountCategoryMappings = rawMappings
                .filter(m => {
                    // Search filter
                    if (this.accountSearchTerm) {
                        const term = this.accountSearchTerm.toLowerCase();
                        const accName = (m.Account__r ? m.Account__r.Name : '').toLowerCase();
                        const catName = (m.Category__r ? m.Category__r.Name : '').toLowerCase();
                        if (!accName.includes(term) && !catName.includes(term)) return false;
                    }
                    // Active-only filter
                    if (this.accountActiveOnly) {
                        const now = new Date().toISOString().split('T')[0];
                        if (m.Effective_To__c && m.Effective_To__c < now) return false;
                    }
                    return true;
                })
                .map(m => ({
                    ...m,
                    accountName: m.Account__r ? m.Account__r.Name : '',
                    categoryName: m.Category__r ? m.Category__r.Name : '',
                    categoryLevel: m.Category__r ? m.Category__r.Level__c : '',
                    isActive: this.isMappingActive(m),
                    assignedBy: m.Assigned_By__r ? m.Assigned_By__r.Name : ''
                }));
        } catch (error) {
            this.showError('Error loading customer categories', this.reduceErrors(error));
        }
    }

    isMappingActive(mapping) {
        const now = new Date().toISOString().split('T')[0];
        if (mapping.Effective_From__c && mapping.Effective_From__c > now) return false;
        if (mapping.Effective_To__c && mapping.Effective_To__c < now) return false;
        return true;
    }

    handleAccountSearch(event) {
        this.accountSearchTerm = event.target.value;
        clearTimeout(this._searchTimeout);
        this._searchTimeout = setTimeout(() => {
            this.loadAccountCategories();
        }, 300);
    }

    handleAccountCategoryFilter(event) {
        this.accountCategoryFilter = event.detail.value;
        this.loadAccountCategories();
    }

    handleAccountActiveFilter(event) {
        this.accountActiveOnly = event.target.checked;
        this.loadAccountCategories();
    }

    handleNewAccountCategory() {
        this.isNewAccountCategory = true;
        this.editAccountCategory = {};
        this.selectedAccountCategoryIds = [];
        this.resetAccountLookup();
        this.showAccountCategoryModal = true;
    }

    handleAccountCategoryMultiChange(event) {
        this.selectedAccountCategoryIds = event.detail.value;
    }

    handleEditAccountCategory(event) {
        const mappingId = event.currentTarget.dataset.id;
        const mapping = this.accountCategoryMappings.find(m => m.Id === mappingId);
        if (mapping) {
            this.isNewAccountCategory = false;
            this.editAccountCategory = JSON.parse(JSON.stringify(mapping));
            this.selectedAccountName = mapping.accountName || '';
            this.showAccountCategoryModal = true;
        }
    }

    handleAccountCategoryFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.editAccountCategory = { ...this.editAccountCategory, [field]: value };
    }

    async handleSaveAccountCategory() {
        if (!this.editAccountCategory.Account__c) {
            this.showError('Validation Error', 'Please select a customer (account).');
            return;
        }
        // Multi-select for new, single for edit
        if (this.isNewAccountCategory) {
            if (!this.selectedAccountCategoryIds || this.selectedAccountCategoryIds.length === 0) {
                this.showError('Validation Error', 'Please select at least one category.');
                return;
            }
        } else if (!this.editAccountCategory.Category__c) {
            this.showError('Validation Error', 'Please select a category.');
            return;
        }
        this.isSaving = true;
        try {
            if (this.isNewAccountCategory && this.selectedAccountCategoryIds.length > 0) {
                // Filter out categories already mapped to this account
                const existingCatIds = new Set(
                    this.accountCategoryMappings
                        .filter(m => m.Account__c === this.editAccountCategory.Account__c && m.Is_Active__c !== false)
                        .map(m => m.Category__c)
                );
                const newCatIds = this.selectedAccountCategoryIds.filter(id => !existingCatIds.has(id));
                if (newCatIds.length === 0) {
                    this.showError('Duplicate', 'All selected categories are already mapped to this customer.');
                    this.isSaving = false;
                    return;
                }
                for (const catId of newCatIds) {
                    const toSave = { ...this.editAccountCategory, Category__c: catId };
                    delete toSave.Account__r; delete toSave.Category__r; delete toSave.Assigned_By__r;
                    delete toSave.accountName; delete toSave.categoryName; delete toSave.categoryLevel;
                    delete toSave.isActive; delete toSave.assignedBy;
                    await saveAccountCategory({ mappingJson: JSON.stringify(toSave) });
                }
                this.showAccountCategoryModal = false;
                const skipped = this.selectedAccountCategoryIds.length - newCatIds.length;
                let msg = newCatIds.length + ' category mapping(s) created';
                if (skipped > 0) msg += ' (' + skipped + ' duplicate(s) skipped)';
                this.showSuccess(msg);
            } else {
                const toSave = { ...this.editAccountCategory };
                delete toSave.Account__r; delete toSave.Category__r; delete toSave.Assigned_By__r;
                delete toSave.accountName; delete toSave.categoryName; delete toSave.categoryLevel;
                delete toSave.isActive; delete toSave.assignedBy;
                await saveAccountCategory({ mappingJson: JSON.stringify(toSave) });
                this.showAccountCategoryModal = false;
                this.showSuccess('Customer category mapping updated');
            }
            await this.loadAccountCategories();
        } catch (error) {
            this.showError('Error saving mapping', this.reduceErrors(error));
        } finally {
            this.isSaving = false;
        }
    }

    async handleDeleteAccountCategory(event) {
        const mappingId = event.currentTarget.dataset.id;
        const mapping = this.accountCategoryMappings.find(m => m.Id === mappingId);
        if (!confirm(`Delete category mapping for "${mapping.accountName}"?`)) return;
        try {
            await deleteAccountCategory({ mappingId });
            this.showSuccess('Customer category mapping deleted');
            await this.loadAccountCategories();
        } catch (error) {
            this.showError('Error deleting mapping', this.reduceErrors(error));
        }
    }

    handleCloseAccountCategoryModal() {
        this.showAccountCategoryModal = false;
    }

    // ── Account Bulk Assign ────────────────────────────────────────────

    handleOpenBulkAccountAssign() {
        this.bulkAccountIds = '';
        this.bulkAccountCategoryIds = [];
        this.bulkAccountEffectiveFrom = '';
        this.bulkAccountEffectiveTo = '';
        this.showBulkAccountModal = true;
    }

    handleBulkAccountFieldChange(event) {
        const field = event.target.dataset.field;
        if (field === 'accountIds') {
            this.bulkAccountIds = event.target.value;
        } else if (field === 'categoryIds') {
            this.bulkAccountCategoryIds = event.detail.value;
        } else if (field === 'effectiveFrom') {
            this.bulkAccountEffectiveFrom = event.target.value;
        } else if (field === 'effectiveTo') {
            this.bulkAccountEffectiveTo = event.target.value;
        }
    }

    async handleBulkAssignAccounts() {
        const accountIds = this.bulkAccountIds.split(/[\n,;]+/).map(id => id.trim()).filter(Boolean);
        if (accountIds.length === 0) {
            this.showError('Validation Error', 'Please enter at least one Account ID.');
            return;
        }
        if (!this.bulkAccountCategoryIds || this.bulkAccountCategoryIds.length === 0) {
            this.showError('Validation Error', 'Please select at least one category.');
            return;
        }
        this.isSaving = true;
        try {
            await bulkAssignAccountCategories({
                accountIds: accountIds,
                categoryIds: this.bulkAccountCategoryIds,
                effectiveFrom: this.bulkAccountEffectiveFrom || null,
                effectiveTo: this.bulkAccountEffectiveTo || null
            });
            this.showBulkAccountModal = false;
            this.showSuccess(`Bulk assigned ${accountIds.length} account(s) to ${this.bulkAccountCategoryIds.length} category(ies)`);
            await this.loadAccountCategories();
        } catch (error) {
            this.showError('Bulk assign failed', this.reduceErrors(error));
        } finally {
            this.isSaving = false;
        }
    }

    handleCloseBulkAccountModal() {
        this.showBulkAccountModal = false;
    }

    // ── Account Lookup ─────────────────────────────────────────────────

    resetAccountLookup() {
        this.selectedAccountName = '';
        this.accountLookupSearchTerm = '';
        this.accountLookupResults = [];
        this.showAccountLookup = false;
    }

    handleAccountLookupSearch(event) {
        const searchTerm = event.target.value;
        this.accountLookupSearchTerm = searchTerm;
        clearTimeout(this._accountLookupTimeout);
        if (searchTerm.length < 2) {
            this.accountLookupResults = [];
            this.showAccountLookup = false;
            return;
        }
        this._accountLookupTimeout = setTimeout(async () => {
            try {
                this.accountLookupResults = this._stripNs(await searchAccountsForLookup({ searchTerm }));
                this.showAccountLookup = this.accountLookupResults.length > 0;
            } catch (error) {
                this.accountLookupResults = [];
                this.showAccountLookup = false;
            }
        }, 300);
    }

    handleSelectLookupAccount(event) {
        const accountId = event.currentTarget.dataset.id;
        const accountName = event.currentTarget.dataset.name;
        this.editAccountCategory = { ...this.editAccountCategory, Account__c: accountId };
        this.selectedAccountName = accountName;
        this.accountLookupSearchTerm = '';
        this.showAccountLookup = false;
        this.accountLookupResults = [];
    }

    handleClearAccountSelection() {
        this.editAccountCategory = { ...this.editAccountCategory, Account__c: null };
        this.resetAccountLookup();
    }

    // ── Employee Categories ────────────────────────────────────────────

    async loadEmployeeCategories() {
        try {
            let rawMappings = [];
            if (this.employeeCategoryFilter) {
                rawMappings = this._stripNs(await getCategoryEmployees({ categoryId: this.employeeCategoryFilter }));
            } else {
                rawMappings = this._stripNs(await getEmployeeCategories({ employeeId: null }));
            }
            this.employeeCategoryMappings = rawMappings
                .filter(m => {
                    if (this.employeeSearchTerm) {
                        const term = this.employeeSearchTerm.toLowerCase();
                        const empName = (m.Employee__r ? ((m.Employee__r.First_Name__c || '') + ' ' + (m.Employee__r.Last_Name__c || '')).trim() : '').toLowerCase();
                        const catName = (m.Category__r ? m.Category__r.Name : '').toLowerCase();
                        if (!empName.includes(term) && !catName.includes(term)) return false;
                    }
                    if (this.employeeActiveOnly) {
                        const now = new Date().toISOString().split('T')[0];
                        if (m.Effective_To__c && m.Effective_To__c < now) return false;
                    }
                    return true;
                })
                .map(m => ({
                    ...m,
                    employeeName: m.Employee__r ? ((m.Employee__r.First_Name__c || '') + ' ' + (m.Employee__r.Last_Name__c || '')).trim() : '',
                    categoryName: m.Category__r ? m.Category__r.Name : '',
                    categoryLevel: m.Category__r ? m.Category__r.Level__c : '',
                    responsibilityType: m.Responsibility_Type__c || '',
                    isActive: this.isMappingActive(m),
                    assignedBy: m.Assigned_By__r ? m.Assigned_By__r.Name : ''
                }));
        } catch (error) {
            this.showError('Error loading user categories', this.reduceErrors(error));
        }
    }

    handleEmployeeSearch(event) {
        this.employeeSearchTerm = event.target.value;
        clearTimeout(this._searchTimeout);
        this._searchTimeout = setTimeout(() => {
            this.loadEmployeeCategories();
        }, 300);
    }

    handleEmployeeCategoryFilter(event) {
        this.employeeCategoryFilter = event.detail.value;
        this.loadEmployeeCategories();
    }

    handleEmployeeActiveFilter(event) {
        this.employeeActiveOnly = event.target.checked;
        this.loadEmployeeCategories();
    }

    handleNewEmployeeCategory() {
        this.isNewEmployeeCategory = true;
        this.editEmployeeCategory = {};
        this.selectedEmployeeCategoryIds = [];
        this.resetEmployeeLookup();
        this.showEmployeeCategoryModal = true;
    }

    handleEmployeeCategoryMultiChange(event) {
        this.selectedEmployeeCategoryIds = event.detail.value;
    }

    handleEditEmployeeCategory(event) {
        const mappingId = event.currentTarget.dataset.id;
        const mapping = this.employeeCategoryMappings.find(m => m.Id === mappingId);
        if (mapping) {
            this.isNewEmployeeCategory = false;
            this.editEmployeeCategory = JSON.parse(JSON.stringify(mapping));
            this.selectedEmployeeName = mapping.employeeName || '';
            this.showEmployeeCategoryModal = true;
        }
    }

    handleEmployeeCategoryFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.editEmployeeCategory = { ...this.editEmployeeCategory, [field]: value };
    }

    async handleSaveEmployeeCategory() {
        if (!this.editEmployeeCategory.Employee__c) {
            this.showError('Validation Error', 'Please select an employee (user).');
            return;
        }
        if (this.isNewEmployeeCategory) {
            if (!this.selectedEmployeeCategoryIds || this.selectedEmployeeCategoryIds.length === 0) {
                this.showError('Validation Error', 'Please select at least one category.');
                return;
            }
        } else if (!this.editEmployeeCategory.Category__c) {
            this.showError('Validation Error', 'Please select a category.');
            return;
        }
        this.isSaving = true;
        try {
            const cleanFields = (obj) => {
                delete obj.Employee__r; delete obj.Category__r; delete obj.Assigned_By__r;
                delete obj.employeeName; delete obj.categoryName; delete obj.categoryLevel;
                delete obj.responsibilityType; delete obj.isActive; delete obj.assignedBy;
                if (obj.Responsibility_Type__c === '') obj.Responsibility_Type__c = null;
                return obj;
            };
            if (this.isNewEmployeeCategory && this.selectedEmployeeCategoryIds.length > 0) {
                const existingEmpCatIds = new Set(
                    this.employeeCategoryMappings
                        .filter(m => m.Employee__c === this.editEmployeeCategory.Employee__c && m.Is_Active__c !== false)
                        .map(m => m.Category__c)
                );
                const newEmpCatIds = this.selectedEmployeeCategoryIds.filter(id => !existingEmpCatIds.has(id));
                if (newEmpCatIds.length === 0) {
                    this.showError('Duplicate', 'All selected categories are already mapped to this user.');
                    this.isSaving = false;
                    return;
                }
                for (const catId of newEmpCatIds) {
                    const toSave = cleanFields({ ...this.editEmployeeCategory, Category__c: catId });
                    await saveEmployeeCategory({ mappingJson: JSON.stringify(toSave) });
                }
                this.showEmployeeCategoryModal = false;
                const skippedEmp = this.selectedEmployeeCategoryIds.length - newEmpCatIds.length;
                let empMsg = newEmpCatIds.length + ' category mapping(s) created';
                if (skippedEmp > 0) empMsg += ' (' + skippedEmp + ' duplicate(s) skipped)';
                this.showSuccess(empMsg);
            } else {
                const toSave = cleanFields({ ...this.editEmployeeCategory });
                await saveEmployeeCategory({ mappingJson: JSON.stringify(toSave) });
                this.showEmployeeCategoryModal = false;
                this.showSuccess('User category mapping updated');
            }
            await this.loadEmployeeCategories();
        } catch (error) {
            this.showError('Error saving mapping', this.reduceErrors(error));
        } finally {
            this.isSaving = false;
        }
    }

    async handleDeleteEmployeeCategory(event) {
        const mappingId = event.currentTarget.dataset.id;
        const mapping = this.employeeCategoryMappings.find(m => m.Id === mappingId);
        if (!confirm(`Delete category mapping for "${mapping.employeeName}"?`)) return;
        try {
            await deleteEmployeeCategory({ mappingId });
            this.showSuccess('User category mapping deleted');
            await this.loadEmployeeCategories();
        } catch (error) {
            this.showError('Error deleting mapping', this.reduceErrors(error));
        }
    }

    handleCloseEmployeeCategoryModal() {
        this.showEmployeeCategoryModal = false;
    }

    // ── Employee Bulk Assign ───────────────────────────────────────────

    handleOpenBulkEmployeeAssign() {
        this.bulkEmployeeIds = '';
        this.bulkEmployeeCategoryIds = [];
        this.bulkEmployeeResponsibilityType = '';
        this.bulkEmployeeEffectiveFrom = '';
        this.bulkEmployeeEffectiveTo = '';
        this.showBulkEmployeeModal = true;
    }

    handleBulkEmployeeFieldChange(event) {
        const field = event.target.dataset.field;
        if (field === 'employeeIds') {
            this.bulkEmployeeIds = event.target.value;
        } else if (field === 'categoryIds') {
            this.bulkEmployeeCategoryIds = event.detail.value;
        } else if (field === 'responsibilityType') {
            this.bulkEmployeeResponsibilityType = event.detail.value;
        } else if (field === 'effectiveFrom') {
            this.bulkEmployeeEffectiveFrom = event.target.value;
        } else if (field === 'effectiveTo') {
            this.bulkEmployeeEffectiveTo = event.target.value;
        }
    }

    async handleBulkAssignEmployees() {
        const employeeIds = this.bulkEmployeeIds.split(/[\n,;]+/).map(id => id.trim()).filter(Boolean);
        if (employeeIds.length === 0) {
            this.showError('Validation Error', 'Please enter at least one Employee ID.');
            return;
        }
        if (!this.bulkEmployeeCategoryIds || this.bulkEmployeeCategoryIds.length === 0) {
            this.showError('Validation Error', 'Please select at least one category.');
            return;
        }
        this.isSaving = true;
        try {
            await bulkAssignEmployeeCategories({
                employeeIds: employeeIds,
                categoryIds: this.bulkEmployeeCategoryIds,
                responsibilityType: this.bulkEmployeeResponsibilityType || null,
                effectiveFrom: this.bulkEmployeeEffectiveFrom || null,
                effectiveTo: this.bulkEmployeeEffectiveTo || null
            });
            this.showBulkEmployeeModal = false;
            this.showSuccess(`Bulk assigned ${employeeIds.length} employee(s) to ${this.bulkEmployeeCategoryIds.length} category(ies)`);
            await this.loadEmployeeCategories();
        } catch (error) {
            this.showError('Bulk assign failed', this.reduceErrors(error));
        } finally {
            this.isSaving = false;
        }
    }

    handleCloseBulkEmployeeModal() {
        this.showBulkEmployeeModal = false;
    }

    // ── Employee Lookup ────────────────────────────────────────────────

    resetEmployeeLookup() {
        this.selectedEmployeeName = '';
        this.employeeLookupSearchTerm = '';
        this.employeeLookupResults = [];
        this.showEmployeeLookup = false;
    }

    handleEmployeeLookupSearch(event) {
        const searchTerm = event.target.value;
        this.employeeLookupSearchTerm = searchTerm;
        clearTimeout(this._employeeLookupTimeout);
        if (searchTerm.length < 2) {
            this.employeeLookupResults = [];
            this.showEmployeeLookup = false;
            return;
        }
        this._employeeLookupTimeout = setTimeout(async () => {
            try {
                const results = this._stripNs(await searchEmployeesForLookup({ searchTerm }));
                this.employeeLookupResults = results.map(e => ({
                    ...e,
                    employeeFullName: ((e.First_Name__c || '') + ' ' + (e.Last_Name__c || '')).trim()
                }));
                this.showEmployeeLookup = this.employeeLookupResults.length > 0;
            } catch (error) {
                this.employeeLookupResults = [];
                this.showEmployeeLookup = false;
            }
        }, 300);
    }

    handleSelectLookupEmployee(event) {
        const employeeId = event.currentTarget.dataset.id;
        const employeeName = event.currentTarget.dataset.name;
        this.editEmployeeCategory = { ...this.editEmployeeCategory, Employee__c: employeeId };
        this.selectedEmployeeName = employeeName;
        this.employeeLookupSearchTerm = '';
        this.showEmployeeLookup = false;
        this.employeeLookupResults = [];
    }

    handleClearEmployeeSelection() {
        this.editEmployeeCategory = { ...this.editEmployeeCategory, Employee__c: null };
        this.resetEmployeeLookup();
    }

    // ── Category Products ──────────────────────────────────────────────

    handleCategoryProductFilter(event) {
        this.categoryProductFilter = event.detail.value;
        if (this.categoryProductFilter) {
            this.loadCategoryProducts();
        } else {
            this.categoryProducts = [];
        }
    }

    handleIncludeSubCategories(event) {
        this.includeSubCategories = event.target.checked;
        if (this.categoryProductFilter) {
            this.loadCategoryProducts();
        }
    }

    async loadCategoryProducts() {
        this.isLoading = true;
        try {
            const rawProducts = this._stripNs(await getCategoryProducts({
                categoryId: this.categoryProductFilter,
                includeSubCategories: this.includeSubCategories
            }));
            this.categoryProducts = rawProducts.map(p => ({
                ...p,
                brandName: p.Brand__c || '',
                isActiveLabel: p.Is_Active__c ? 'Yes' : 'No'
            }));
        } catch (error) {
            this.showError('Error loading category products', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    // ── Utility ────────────────────────────────────────────────────────

    showSuccess(message) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Success',
            message,
            variant: 'success'
        }));
    }

    showError(title, message) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message: message || 'An unexpected error occurred',
            variant: 'error'
        }));
    }

    reduceErrors(error) {
        if (!error) return 'Unknown error';
        if (typeof error === 'string') return error;
        if (Array.isArray(error)) {
            return error.map(e => this.reduceErrors(e)).filter(Boolean).join(', ');
        }
        if (error.body && typeof error.body.message === 'string' && error.body.message.trim()) {
            return error.body.message;
        }
        if (error.body && Array.isArray(error.body)) {
            const messages = [];
            error.body.forEach(entry => {
                if (entry && Array.isArray(entry.errors)) {
                    entry.errors.forEach(e => { if (e && e.message) messages.push(e.message); });
                }
                if (entry && Array.isArray(entry.pageErrors)) {
                    entry.pageErrors.forEach(e => { if (e && e.message) messages.push(e.message); });
                }
                if (entry && typeof entry.message === 'string') {
                    messages.push(entry.message);
                }
            });
            if (messages.length) return messages.join(', ');
        }
        if (error.body && Array.isArray(error.body.pageErrors) && error.body.pageErrors.length) {
            return error.body.pageErrors.map(e => e.message).filter(Boolean).join(', ');
        }
        if (error.body && error.body.fieldErrors) {
            const fieldMessages = [];
            Object.keys(error.body.fieldErrors).forEach(field => {
                const entries = error.body.fieldErrors[field] || [];
                entries.forEach(e => { if (e && e.message) fieldMessages.push(e.message); });
            });
            if (fieldMessages.length) return fieldMessages.join(', ');
        }
        if (error.body && error.body.output && Array.isArray(error.body.output.errors)
            && error.body.output.errors.length) {
            return error.body.output.errors.map(e => e.message).filter(Boolean).join(', ');
        }
        if (typeof error.message === 'string' && error.message.trim()) return error.message;
        if (typeof error.statusText === 'string' && error.statusText.trim()) return error.statusText;
        return 'Save failed. Please review the form and try again.';
    }
}