import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getEmployees from '@salesforce/apex/EmployeeController.getEmployees';
import getEmployee from '@salesforce/apex/EmployeeController.getEmployee';
import saveEmployee from '@salesforce/apex/EmployeeController.saveEmployee';
import deactivateEmployee from '@salesforce/apex/EmployeeController.deactivateEmployee';
import getDepartmentOptions from '@salesforce/apex/EmployeeController.getDepartmentOptions';
import getDesignationOptions from '@salesforce/apex/EmployeeController.getDesignationOptions';
import getDirectReports from '@salesforce/apex/EmployeeController.getDirectReports';
import getEmployeeLeaveBalances from '@salesforce/apex/EmployeeController.getEmployeeLeaveBalances';
import getOrgHierarchy from '@salesforce/apex/EmployeeController.getOrgHierarchy';

const PAGE_SIZE = 15;

const WEEK_DAY_OPTIONS = [
    { label: 'Monday', value: 'Monday' },
    { label: 'Tuesday', value: 'Tuesday' },
    { label: 'Wednesday', value: 'Wednesday' },
    { label: 'Thursday', value: 'Thursday' },
    { label: 'Friday', value: 'Friday' },
    { label: 'Saturday', value: 'Saturday' },
    { label: 'Sunday', value: 'Sunday' }
];

const EMPTY_EMPLOYEE_FORM = {
    Id: null,
    First_Name__c: '',
    Last_Name__c: '',
    Employee_Code__c: '',
    Email__c: '',
    Phone__c: '',
    Department__c: '',
    Designation__c: '',
    Reporting_Manager__c: null,
    User__c: null,
    Date_of_Joining__c: null,
    Zone__c: '',
    Region__c: '',
    Band__c: '',
    Territory__c: null,
    Is_Active__c: true,
    Profile_Photo_URL__c: '',
    Address__c: '',
    Week_Off_Days__c: 'Sunday'
};

export default class EmployeeManager extends NavigationMixin(LightningElement) {
    // ── State ───────────────────────────────────────────────────
    @track employees = [];
    @track selectedEmployee = null;
    @track directReports = [];
    @track hierarchyTree = [];
    @track departmentOptions = [];
    @track designationOptions = [];
    isLoading = false;
    showEmployeeForm = false;
    isEditMode = false;

    // Search & Filter
    searchTerm = '';
    filterDepartment = '';
    filterDesignation = '';
    filterActiveOnly = true;

    // Pagination
    pageNumber = 1;
    totalPages = 1;
    totalCount = 0;

    // Active tab
    activeTab = 'details';

    // Employee form fields
    @track employeeForm = { ...EMPTY_EMPLOYEE_FORM };

    // Debounce timer
    _searchTimer;

    // ── Getters ─────────────────────────────────────────────────

    get formTitle() {
        return this.employeeForm.Id ? 'Edit Employee' : 'New Employee';
    }

    get hasEmployees() {
        return this.employees.length > 0;
    }

    get hasSelectedEmployee() {
        return this.selectedEmployee != null;
    }

    get hasDirectReports() {
        return this.directReports.length > 0;
    }

    get selectedEmployeeName() {
        if (!this.selectedEmployee) return '';
        return (this.selectedEmployee.First_Name__c || '') + ' ' + (this.selectedEmployee.Last_Name__c || '');
    }

    get selectedEmployeeInitials() {
        if (!this.selectedEmployee) return '';
        const first = this.selectedEmployee.First_Name__c ? this.selectedEmployee.First_Name__c.charAt(0) : '';
        const last = this.selectedEmployee.Last_Name__c ? this.selectedEmployee.Last_Name__c.charAt(0) : '';
        return (first + last).toUpperCase();
    }

    get selectedEmployeeDepartment() {
        return this.selectedEmployee ? this.selectedEmployee.Department__c || '-' : '-';
    }

    get selectedEmployeeDesignation() {
        return this.selectedEmployee ? this.selectedEmployee.Designation__c || '-' : '-';
    }

    get selectedEmployeeBand() {
        return this.selectedEmployee ? this.selectedEmployee.Band__c || '-' : '-';
    }

    get selectedEmployeeCode() {
        return this.selectedEmployee ? this.selectedEmployee.Employee_Code__c || '-' : '-';
    }

    get selectedEmployeeEmail() {
        return this.selectedEmployee ? this.selectedEmployee.Email__c || '-' : '-';
    }

    get selectedEmployeePhone() {
        return this.selectedEmployee ? this.selectedEmployee.Phone__c || '-' : '-';
    }

    get selectedEmployeeJoinDate() {
        return this.selectedEmployee ? this.selectedEmployee.Date_of_Joining__c || '-' : '-';
    }

    get selectedEmployeeZone() {
        return this.selectedEmployee ? this.selectedEmployee.Zone__c || '-' : '-';
    }

    get selectedEmployeeRegion() {
        return this.selectedEmployee ? this.selectedEmployee.Region__c || '-' : '-';
    }

    get selectedEmployeeTerritoryName() {
        if (!this.selectedEmployee) return '-';
        return this.selectedEmployee.Territory__r ? this.selectedEmployee.Territory__r.Name : '-';
    }

    get selectedEmployeeChannels() {
        if (!this.selectedEmployee || !this.selectedEmployee.Channels__c) return '-';
        return this.selectedEmployee.Channels__c.replace(/;/g, ', ');
    }

    get selectedEmployeeManagerName() {
        if (!this.selectedEmployee) return '-';
        if (this.selectedEmployee.Reporting_Manager__r) {
            const mgr = this.selectedEmployee.Reporting_Manager__r;
            return (mgr.First_Name__c || '') + ' ' + (mgr.Last_Name__c || '');
        }
        return '-';
    }

    get selectedEmployeeAddress() {
        return this.selectedEmployee ? this.selectedEmployee.Address__c || '-' : '-';
    }

    get selectedEmployeeL1Approver() {
        if (!this.selectedEmployee || !this.selectedEmployee.L1_Approver__r) return '-';
        return this.selectedEmployee.L1_Approver__r.Name;
    }

    get selectedEmployeeL2Approver() {
        if (!this.selectedEmployee || !this.selectedEmployee.L2_Approver__r) return '-';
        return this.selectedEmployee.L2_Approver__r.Name;
    }

    get selectedEmployeeWeekOffDays() {
        if (!this.selectedEmployee || !this.selectedEmployee.Week_Off_Days__c) return '-';
        return this.selectedEmployee.Week_Off_Days__c.replace(/;/g, ', ');
    }

    get weekDayOptions() {
        return WEEK_DAY_OPTIONS;
    }

    get bandOptions() {
        // Mirrors the Band__c picklist on Employee__c (Band 1 through Band 6).
        // Drives expense eligibility rules.
        return [
            { label: 'Band 1', value: 'Band 1' },
            { label: 'Band 2', value: 'Band 2' },
            { label: 'Band 3', value: 'Band 3' },
            { label: 'Band 4', value: 'Band 4' },
            { label: 'Band 5', value: 'Band 5' },
            { label: 'Band 6', value: 'Band 6' }
        ];
    }

    get weekOffDaysFormValue() {
        if (!this.employeeForm.Week_Off_Days__c) return [];
        return this.employeeForm.Week_Off_Days__c.split(';');
    }

    get employeeChannelOptions() {
        return [
            { label: 'GT', value: 'GT' },
            { label: 'MT', value: 'MT' },
            { label: 'E-Commerce', value: 'E-Commerce' }
        ];
    }

    get employeeFormChannels() {
        const val = this.employeeForm?.Channels__c;
        if (!val) return [];
        return val.split(';').map(s => s.trim()).filter(s => s);
    }

    get selectedEmployeeIsActive() {
        return this.selectedEmployee ? this.selectedEmployee.Is_Active__c : false;
    }

    get selectedEmployeeStatusLabel() {
        if (!this.selectedEmployee) return '';
        return this.selectedEmployee.Is_Active__c ? 'Active' : 'Inactive';
    }

    get selectedEmployeeStatusClass() {
        if (!this.selectedEmployee) return 'status-badge';
        return this.selectedEmployee.Is_Active__c
            ? 'status-badge status-active'
            : 'status-badge status-inactive';
    }

    get selectedEmployeeSalary() {
        if (!this.selectedEmployee || !this.selectedEmployee.Gross_Salary__c) return '—';
        const val = this.selectedEmployee.Gross_Salary__c;
        if (val >= 100000) return '₹' + (val / 100000).toFixed(1) + 'L';
        if (val >= 1000) return '₹' + (val / 1000).toFixed(1) + 'K';
        return '₹' + val;
    }

    get selectedEmployeeUserName() {
        if (!this.selectedEmployee) return '-';
        return this.selectedEmployee.User__r ? this.selectedEmployee.User__r.Name : '-';
    }

    // Leave balances — from Leave_Balance__c
    @track leaveBalances = [];

    async loadLeaveBalances() {
        if (!this.selectedEmployee) return;
        try {
            this.leaveBalances = await getEmployeeLeaveBalances({ employeeId: this.selectedEmployee.Id }) || [];
        } catch (e) {
            this.leaveBalances = [];
        }
    }

    get leaveBalanceCards() {
        const colorMap = {
            'Casual Leave': '#0176d3', 'Sick Leave': '#2e844a',
            'Earned Leave': '#7b61ff', 'Compensatory Off': '#dd7a01'
        };
        return this.leaveBalances.map(lb => {
            const accrued = lb.Accrued__c || 0;
            const carry = lb.Carry_Forward__c || 0;
            const pool = accrued + carry;
            const available = ((lb.Accrued__c || 0) + (lb.Carry_Forward__c || 0) - (lb.Used__c || 0) - (lb.Pending__c || 0)) || 0;
            const used = lb.Used__c || 0;
            const pending = lb.Pending__c || 0;
            const pct = pool > 0 ? Math.min(Math.round((available / pool) * 100), 100) : 0;
            return {
                key: lb.Leave_Type__c,
                label: lb.Leave_Type__c,
                available: available,
                accrued: accrued,
                carryForward: carry,
                used: used,
                pending: pending,
                entitled: lb.Entitled__c || 0,
                pool: pool,
                percent: pct,
                color: colorMap[lb.Leave_Type__c] || '#54698d',
                progressStyle: 'width: ' + pct + '%; background: ' + (colorMap[lb.Leave_Type__c] || '#54698d')
            };
        });
    }

    // Legacy getters for backward compat (still used in some places)
    get clBalance() { return this._getBalanceForType('Casual Leave'); }
    get slBalance() { return this._getBalanceForType('Sick Leave'); }
    get elBalance() { return this._getBalanceForType('Earned Leave'); }
    get coBalance() { return this._getBalanceForType('Compensatory Off'); }
    get clProgressStyle() { return this._getProgressForType('Casual Leave'); }
    get slProgressStyle() { return this._getProgressForType('Sick Leave'); }
    get elProgressStyle() { return this._getProgressForType('Earned Leave'); }
    get coProgressStyle() { return this._getProgressForType('Compensatory Off'); }

    _getBalanceForType(type) {
        const lb = this.leaveBalances.find(b => b.Leave_Type__c === type);
        return lb ? (((lb.Accrued__c || 0) + (lb.Carry_Forward__c || 0) - (lb.Used__c || 0) - (lb.Pending__c || 0)) || 0) : 0;
    }
    _getProgressForType(type) {
        const lb = this.leaveBalances.find(b => b.Leave_Type__c === type);
        if (!lb) return 'width: 0%';
        const pool = (lb.Accrued__c || 0) + (lb.Carry_Forward__c || 0);
        const pct = pool > 0 ? Math.min(Math.round(((((lb.Accrued__c || 0) + (lb.Carry_Forward__c || 0) - (lb.Used__c || 0) - (lb.Pending__c || 0)) || 0) / pool) * 100), 100) : 0;
        return 'width: ' + pct + '%';
    }

    get directReportsCount() {
        return this.directReports.length;
    }

    // Pagination
    get isPrevDisabled() {
        return this.pageNumber <= 1;
    }

    get isNextDisabled() {
        return this.pageNumber >= this.totalPages;
    }

    get paginationLabel() {
        return 'Page ' + this.pageNumber + ' of ' + this.totalPages;
    }

    get showPagination() {
        return this.totalPages > 1;
    }

    get employeeCountLabel() {
        return this.totalCount + ' Employee' + (this.totalCount !== 1 ? 's' : '');
    }

    // Filter options with blank default
    get departmentFilterOptions() {
        const opts = [{ label: 'All Departments', value: '' }];
        this.departmentOptions.forEach(dep => {
            opts.push({ label: dep, value: dep });
        });
        return opts;
    }

    get designationFilterOptions() {
        const opts = [{ label: 'All Designations', value: '' }];
        this.designationOptions.forEach(des => {
            opts.push({ label: des, value: des });
        });
        return opts;
    }

    // Tab state
    get isDetailsTab() {
        return this.activeTab === 'details';
    }

    get isTeamTab() {
        return this.activeTab === 'team';
    }

    get isLeaveTab() {
        return this.activeTab === 'leave';
    }

    get isHierarchyTab() {
        return this.activeTab === 'hierarchy';
    }

    get hasHierarchyData() {
        return this.hierarchyTree.length > 0;
    }

    get detailsTabClass() {
        return this.activeTab === 'details' ? 'tab-btn tab-btn-active' : 'tab-btn';
    }

    get teamTabClass() {
        return this.activeTab === 'team' ? 'tab-btn tab-btn-active' : 'tab-btn';
    }

    get hierarchyTabClass() {
        return this.activeTab === 'hierarchy' ? 'tab-btn tab-btn-active' : 'tab-btn';
    }

    get leaveTabClass() {
        return this.activeTab === 'leave' ? 'tab-btn tab-btn-active' : 'tab-btn';
    }

    get isDeactivateDisabled() {
        return !this.selectedEmployee || !this.selectedEmployee.Is_Active__c;
    }

    // ── Lifecycle ───────────────────────────────────────────────

    connectedCallback() {
        this.loadEmployees();
        this.loadFilterOptions();
    }

    // ── Data Loading ────────────────────────────────────────────

    async loadFilterOptions() {
        try {
            const [departments, designations] = await Promise.all([
                getDepartmentOptions(),
                getDesignationOptions()
            ]);
            this.departmentOptions = departments || [];
            this.designationOptions = designations || [];
        } catch (error) {
            console.error('Error loading filter options:', error);
        }
    }

    async loadEmployees() {
        this.isLoading = true;
        try {
            const result = await getEmployees({
                searchTerm: this.searchTerm || '',
                department: this.filterDepartment || '',
                designation: this.filterDesignation || '',
                activeOnly: this.filterActiveOnly
            });
            const allEmployees = result || [];
            this.totalCount = allEmployees.length;
            this.totalPages = Math.max(1, Math.ceil(this.totalCount / PAGE_SIZE));
            if (this.pageNumber > this.totalPages) {
                this.pageNumber = this.totalPages;
            }

            const startIdx = (this.pageNumber - 1) * PAGE_SIZE;
            const pageEmployees = allEmployees.slice(startIdx, startIdx + PAGE_SIZE);

            this.employees = pageEmployees.map(emp => ({
                ...emp,
                fullName: (emp.First_Name__c || '') + ' ' + (emp.Last_Name__c || ''),
                initials: this.getInitials(emp.First_Name__c, emp.Last_Name__c),
                departmentDisplay: emp.Department__c || '-',
                designationDisplay: emp.Designation__c || '-',
                statusLabel: emp.Is_Active__c ? 'Active' : 'Inactive',
                statusClass: emp.Is_Active__c ? 'status-badge status-active' : 'status-badge status-inactive',
                rowClass: this.selectedEmployee && this.selectedEmployee.Id === emp.Id
                    ? 'employee-row employee-row-selected' : 'employee-row',
                avatarClass: 'avatar-circle avatar-gradient-' + this.getAvatarGradient(emp.First_Name__c)
            }));
        } catch (error) {
            this.showToast('Error', 'Failed to load employees: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async loadEmployeeDetail(employeeId) {
        try {
            const emp = await getEmployee({ employeeId: employeeId });
            this.selectedEmployee = emp;
            this.loadLeaveBalances();
        } catch (error) {
            this.showToast('Error', 'Failed to load employee details: ' + this.reduceErrors(error), 'error');
        }
    }

    async loadDirectReports(employeeId) {
        try {
            const reports = await getDirectReports({ employeeId: employeeId });
            this.directReports = (reports || []).map(emp => ({
                ...emp,
                fullName: (emp.First_Name__c || '') + ' ' + (emp.Last_Name__c || ''),
                initials: this.getInitials(emp.First_Name__c, emp.Last_Name__c),
                designationDisplay: emp.Designation__c || '-',
                departmentDisplay: emp.Department__c || '-',
                avatarClass: 'avatar-circle avatar-circle-sm avatar-gradient-' + this.getAvatarGradient(emp.First_Name__c)
            }));
        } catch (error) {
            console.error('Error loading direct reports:', error);
            this.directReports = [];
        }
    }

    // ── Event Handlers ──────────────────────────────────────────

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => {
            this.pageNumber = 1;
            this.loadEmployees();
        }, 300);
    }

    handleDepartmentFilter(event) {
        this.filterDepartment = event.detail.value;
        this.pageNumber = 1;
        this.loadEmployees();
    }

    handleDesignationFilter(event) {
        this.filterDesignation = event.detail.value;
        this.pageNumber = 1;
        this.loadEmployees();
    }

    handleActiveToggle(event) {
        this.filterActiveOnly = event.target.checked;
        this.pageNumber = 1;
        this.loadEmployees();
    }

    handleSelectEmployee(event) {
        const employeeId = event.currentTarget.dataset.id;
        const emp = this.employees.find(e => e.Id === employeeId);
        if (emp) {
            this.selectedEmployee = emp;
            this.activeTab = 'details';
            this.employees = this.employees.map(e => ({
                ...e,
                rowClass: e.Id === employeeId ? 'employee-row employee-row-selected' : 'employee-row'
            }));
            this.loadEmployeeDetail(employeeId);
            this.loadDirectReports(employeeId);
        }
    }

    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.tab;
        if (this.activeTab === 'hierarchy' && this.hierarchyTree.length === 0) {
            this.loadHierarchy();
        }
    }

    async loadHierarchy() {
        try {
            const tree = await getOrgHierarchy();
            this.hierarchyTree = tree || [];
        } catch (error) {
            console.error('Error loading hierarchy:', error);
            this.hierarchyTree = [];
        }
    }

    handleRefreshHierarchy() {
        this.hierarchyTree = [];
        this.loadHierarchy();
    }

    handleHierarchyNodeClick(event) {
        const employeeId = event.detail.employeeId;
        if (employeeId) {
            this.loadEmployeeDetail(employeeId);
            this.loadDirectReports(employeeId);
            this.employees = this.employees.map(e => ({
                ...e,
                rowClass: e.Id === employeeId ? 'employee-row employee-row-selected' : 'employee-row'
            }));
        }
    }

    // ── Pagination ──────────────────────────────────────────────

    handlePrevPage() {
        if (this.pageNumber > 1) {
            this.pageNumber--;
            this.loadEmployees();
        }
    }

    handleNextPage() {
        if (this.pageNumber < this.totalPages) {
            this.pageNumber++;
            this.loadEmployees();
        }
    }

    // ── Employee CRUD ───────────────────────────────────────────

    handleNewEmployee() {
        this.employeeForm = { ...EMPTY_EMPLOYEE_FORM };
        this.isEditMode = false;
        this.showEmployeeForm = true;
    }

    handleEditEmployee() {
        if (!this.selectedEmployee) return;
        this.employeeForm = {
            Id: this.selectedEmployee.Id,
            First_Name__c: this.selectedEmployee.First_Name__c || '',
            Last_Name__c: this.selectedEmployee.Last_Name__c || '',
            Employee_Code__c: this.selectedEmployee.Employee_Code__c || '',
            Email__c: this.selectedEmployee.Email__c || '',
            Phone__c: this.selectedEmployee.Phone__c || '',
            Department__c: this.selectedEmployee.Department__c || '',
            Designation__c: this.selectedEmployee.Designation__c || '',
            Reporting_Manager__c: this.selectedEmployee.Reporting_Manager__c || null,
            User__c: this.selectedEmployee.User__c || null,
            Date_of_Joining__c: this.selectedEmployee.Date_of_Joining__c || null,
            Zone__c: this.selectedEmployee.Zone__c || '',
            Region__c: this.selectedEmployee.Region__c || '',
            Band__c: this.selectedEmployee.Band__c || '',
            Territory__c: this.selectedEmployee.Territory__c || null,
            Is_Active__c: this.selectedEmployee.Is_Active__c !== false,
            Profile_Photo_URL__c: this.selectedEmployee.Profile_Photo_URL__c || '',
            Address__c: this.selectedEmployee.Address__c || '',
            Week_Off_Days__c: this.selectedEmployee.Week_Off_Days__c || 'Sunday',
            Channels__c: this.selectedEmployee.Channels__c || '',
            Gross_Salary__c: this.selectedEmployee.Gross_Salary__c || null,
            L1_Approver__c: this.selectedEmployee.L1_Approver__c || null,
            L2_Approver__c: this.selectedEmployee.L2_Approver__c || null
        };
        this.isEditMode = true;
        this.showEmployeeForm = true;
    }

    handleFormChange(event) {
        const field = event.target.dataset.field;
        if (field === 'Territory__c' || field === 'Reporting_Manager__c' || field === 'User__c' || field === 'L1_Approver__c' || field === 'L2_Approver__c') {
            const val = event.detail.value;
            this.employeeForm = { ...this.employeeForm, [field]: Array.isArray(val) ? (val[0] || null) : val };
        } else if (field === 'Is_Active__c') {
            this.employeeForm = { ...this.employeeForm, [field]: event.target.checked };
        } else if (field === 'Department__c' || field === 'Designation__c') {
            this.employeeForm = { ...this.employeeForm, [field]: event.detail.value };
        } else if (field === 'Week_Off_Days__c') {
            const selectedValues = event.detail.value;
            this.employeeForm = { ...this.employeeForm, [field]: Array.isArray(selectedValues) ? selectedValues.join(';') : selectedValues };
        } else {
            this.employeeForm = { ...this.employeeForm, [field]: event.target.value };
        }
    }

    handleEmployeeChannelsChange(event) {
        const selected = event.detail.value;
        this.employeeForm = { ...this.employeeForm, Channels__c: selected.join(';') };
    }

    handleCancelForm() {
        this.showEmployeeForm = false;
    }

    async handleSaveEmployee() {
        if (!this.employeeForm.First_Name__c || !this.employeeForm.Last_Name__c) {
            this.showToast('Error', 'First Name and Last Name are required.', 'error');
            return;
        }
        if (!this.employeeForm.Email__c) {
            this.showToast('Error', 'Email is required.', 'error');
            return;
        }
        // Matches the Employee__c.Territory_Required_When_Active validation
        // rule. Catching it here avoids a DML round-trip and shows a clean
        // message instead of the FIELD_CUSTOM_VALIDATION_EXCEPTION text.
        if (!this.employeeForm.Territory__c) {
            this.showToast('Error', 'Territory is required.', 'error');
            return;
        }
        if (!this.employeeForm.Channels__c) {
            this.showToast('Error', 'At least one Channel must be assigned.', 'error');
            return;
        }

        this.isLoading = true;
        try {
            const employeeRecord = {
                First_Name__c: this.employeeForm.First_Name__c,
                Last_Name__c: this.employeeForm.Last_Name__c,
                Employee_Code__c: this.employeeForm.Employee_Code__c,
                Email__c: this.employeeForm.Email__c,
                Phone__c: this.employeeForm.Phone__c,
                Department__c: this.employeeForm.Department__c,
                Designation__c: this.employeeForm.Designation__c,
                Reporting_Manager__c: this.employeeForm.Reporting_Manager__c,
                User__c: this.employeeForm.User__c,
                Date_of_Joining__c: this.employeeForm.Date_of_Joining__c,
                Zone__c: this.employeeForm.Zone__c,
                Region__c: this.employeeForm.Region__c,
                Band__c: this.employeeForm.Band__c,
                Territory__c: this.employeeForm.Territory__c,
                Is_Active__c: this.employeeForm.Is_Active__c,
                Profile_Photo_URL__c: this.employeeForm.Profile_Photo_URL__c,
                Address__c: this.employeeForm.Address__c,
                Week_Off_Days__c: this.employeeForm.Week_Off_Days__c,
                Channels__c: this.employeeForm.Channels__c,
                Gross_Salary__c: this.employeeForm.Gross_Salary__c,
                L1_Approver__c: this.employeeForm.L1_Approver__c,
                L2_Approver__c: this.employeeForm.L2_Approver__c
            };
            if (this.employeeForm.Id) {
                employeeRecord.Id = this.employeeForm.Id;
            }

            const savedEmployee = await saveEmployee({ employee: employeeRecord });
            this.showEmployeeForm = false;
            this.showToast('Success', 'Employee saved successfully.', 'success');
            await this.loadEmployees();

            // Select the saved employee
            this.selectedEmployee = this.employees.find(e => e.Id === savedEmployee.Id) || null;
            if (this.selectedEmployee) {
                this.employees = this.employees.map(e => ({
                    ...e,
                    rowClass: e.Id === savedEmployee.Id ? 'employee-row employee-row-selected' : 'employee-row'
                }));
                this.loadEmployeeDetail(savedEmployee.Id);
                this.loadDirectReports(savedEmployee.Id);
            }
        } catch (error) {
            this.showToast('Error', 'Failed to save employee: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleDeactivate() {
        if (!this.selectedEmployee) return;
        this.isLoading = true;
        try {
            await deactivateEmployee({ employeeId: this.selectedEmployee.Id });
            this.showToast('Success', 'Employee deactivated.', 'success');
            await this.loadEmployees();
            this.loadEmployeeDetail(this.selectedEmployee.Id);
        } catch (error) {
            this.showToast('Error', 'Failed to deactivate employee: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleView360() {
        if (!this.selectedEmployee) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.selectedEmployee.Id,
                objectApiName: 'Employee__c',
                actionName: 'view'
            }
        });
    }

    // ── Helpers ─────────────────────────────────────────────────

    getInitials(firstName, lastName) {
        const first = firstName ? firstName.charAt(0) : '';
        const last = lastName ? lastName.charAt(0) : '';
        return (first + last).toUpperCase();
    }

    getAvatarGradient(name) {
        if (!name) return '1';
        const code = name.charCodeAt(0) % 5;
        return String(code + 1);
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