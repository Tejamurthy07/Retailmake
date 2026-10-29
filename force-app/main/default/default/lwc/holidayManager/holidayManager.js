import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getHolidays from '@salesforce/apex/HolidayController.getHolidays';
import getAllHolidaysForYear from '@salesforce/apex/HolidayController.getAllHolidaysForYear';
import saveHoliday from '@salesforce/apex/HolidayController.saveHoliday';
import deleteHoliday from '@salesforce/apex/HolidayController.deleteHoliday';
import getUpcomingHolidays from '@salesforce/apex/HolidayController.getUpcomingHolidays';
import getHolidaysBetweenDates from '@salesforce/apex/HolidayController.getHolidaysBetweenDates';
import bulkCreateHolidays from '@salesforce/apex/HolidayController.bulkCreateHolidays';
import getHolidayTypeOptions from '@salesforce/apex/HolidayController.getHolidayTypeOptions';
import getTerritoryOptions from '@salesforce/apex/HolidayController.getTerritoryOptions';

const MONTH_NAMES = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
];

const MONTH_NAMES_SHORT = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

const DAY_HEADERS = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

const TYPE_COLOR_MAP = {
    'National Holiday': { dot: 'dot-national', badge: 'badge-national', color: '#ea001e' },
    'Regional Holiday': { dot: 'dot-regional', badge: 'badge-regional', color: '#0176d3' },
    'Optional Holiday': { dot: 'dot-optional', badge: 'badge-optional', color: '#dd7a01' },
    'Restricted Holiday': { dot: 'dot-restricted', badge: 'badge-restricted', color: '#7526c2' },
    'Company Holiday': { dot: 'dot-company', badge: 'badge-company', color: '#2e844a' }
};

const LEGEND_ITEMS = [
    { key: 'national', label: 'National Holiday', dotClass: 'legend-dot dot-national' },
    { key: 'regional', label: 'Regional Holiday', dotClass: 'legend-dot dot-regional' },
    { key: 'optional', label: 'Optional Holiday', dotClass: 'legend-dot dot-optional' },
    { key: 'restricted', label: 'Restricted Holiday', dotClass: 'legend-dot dot-restricted' },
    { key: 'company', label: 'Company Holiday', dotClass: 'legend-dot dot-company' }
];

export default class HolidayManager extends LightningElement {

    // ── State ────────────────────────────────────────────────────────────
    @track selectedYear = new Date().getFullYear();
    @track holidays = [];
    @track upcomingHolidays = [];
    @track calendarMonths = [];
    @track typeOptions = [];
    @track selectedTypeFilters = [];
    @track isCalendarView = true;
    @track isLoading = false;
    @track sortField = 'Holiday_Date__c';
    @track sortDirection = 'asc';

    // Territory filter
    @track territoryOptions = [];
    @track selectedTerritoryFilter = '';

    // Add/Edit modal
    @track showEditModal = false;
    @track editHoliday = {};
    @track isEditMode = false;

    // Bulk import modal
    @track showBulkModal = false;
    @track bulkRows = [];

    // Popover
    @track showPopover = false;
    @track popoverHoliday = null;
    @track popoverStyle = '';

    legendItems = LEGEND_ITEMS;
    dayHeaders = DAY_HEADERS.map((d, i) => ({ key: 'dh_' + i, label: d }));

    // ── Getters ──────────────────────────────────────────────────────────

    get yearDisplay() {
        return String(this.selectedYear);
    }

    get prevYear() {
        return this.selectedYear - 1;
    }

    get nextYear() {
        return this.selectedYear + 1;
    }

    get calendarViewButtonVariant() {
        return this.isCalendarView ? 'brand' : 'neutral';
    }

    get listViewButtonVariant() {
        return this.isCalendarView ? 'neutral' : 'brand';
    }

    get isCalendarViewActive() {
        return this.isCalendarView;
    }

    get isListViewActive() {
        return !this.isCalendarView;
    }

    get editModalTitle() {
        return this.isEditMode ? 'Edit Holiday' : 'Add Holiday';
    }

    get editModalSaveLabel() {
        return this.isEditMode ? 'Update' : 'Save';
    }

    get hasUpcomingHolidays() {
        return this.upcomingHolidays && this.upcomingHolidays.length > 0;
    }

    get hasBulkRows() {
        return this.bulkRows && this.bulkRows.length > 0;
    }

    get filteredHolidays() {
        let result = [...this.holidays];
        if (this.selectedTypeFilters.length > 0) {
            result = result.filter(h => this.selectedTypeFilters.includes(h.Type__c));
        }
        return result;
    }

    get sortedListHolidays() {
        const data = this.filteredHolidays.map(h => {
            const typeInfo = TYPE_COLOR_MAP[h.Type__c] || {};
            return {
                ...h,
                formattedDate: this.formatDisplayDate(h.Holiday_Date__c),
                typeBadgeClass: 'type-badge ' + (typeInfo.badge || ''),
                statusLabel: h.Is_Active__c ? 'Active' : 'Inactive',
                statusClass: h.Is_Active__c ? 'status-badge status-active' : 'status-badge status-inactive',
                territoryDisplay: (h.Territory__r && h.Territory__r.Name) ? h.Territory__r.Name : 'All Territories'
            };
        });

        const field = this.sortField;
        const dir = this.sortDirection === 'asc' ? 1 : -1;
        data.sort((a, b) => {
            const valA = a[field] || '';
            const valB = b[field] || '';
            if (valA < valB) return -1 * dir;
            if (valA > valB) return 1 * dir;
            return 0;
        });

        return data;
    }

    get typeFilterChips() {
        const allTypes = [
            'National Holiday', 'Regional Holiday', 'Optional Holiday',
            'Restricted Holiday', 'Company Holiday'
        ];
        return allTypes.map(t => {
            const isSelected = this.selectedTypeFilters.includes(t);
            const typeInfo = TYPE_COLOR_MAP[t] || {};
            return {
                key: t,
                label: t,
                chipClass: 'filter-chip' + (isSelected ? ' filter-chip-active' : ''),
                dotClass: 'chip-dot ' + (typeInfo.dot || '')
            };
        });
    }

    get typeComboboxOptions() {
        if (this.typeOptions && this.typeOptions.length > 0) {
            return this.typeOptions;
        }
        return [
            { label: 'National Holiday', value: 'National Holiday' },
            { label: 'Regional Holiday', value: 'Regional Holiday' },
            { label: 'Optional Holiday', value: 'Optional Holiday' },
            { label: 'Restricted Holiday', value: 'Restricted Holiday' },
            { label: 'Company Holiday', value: 'Company Holiday' }
        ];
    }

    get territoryComboboxOptions() {
        return this.territoryOptions.map(t => ({
            label: t.Name,
            value: t.Id
        }));
    }

    get territoryFilterOptions() {
        const options = [{ label: 'All Territories', value: '' }];
        if (this.territoryOptions && this.territoryOptions.length > 0) {
            this.territoryOptions.forEach(t => {
                options.push({ label: t.Name, value: t.Id });
            });
        }
        return options;
    }

    get sortDirectionIcon() {
        return this.sortDirection === 'asc' ? 'utility:arrowup' : 'utility:arrowdown';
    }

    get sortLabel() {
        return this.sortDirection === 'asc' ? 'Sorted ascending' : 'Sorted descending';
    }

    // ── Lifecycle ────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadTypeOptions();
        this.loadTerritoryOptions();
        this.loadAllData();
    }

    // ── Data Loading ─────────────────────────────────────────────────────

    async loadAllData() {
        this.isLoading = true;
        try {
            await Promise.all([
                this.loadHolidays(),
                this.loadUpcomingHolidays()
            ]);
            this.buildCalendarData();
        } catch (error) {
            this.showToast('Error', 'Failed to load holiday data: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async loadHolidays() {
        try {
            const territoryId = this.selectedTerritoryFilter || null;
            const result = await getAllHolidaysForYear({ year: this.selectedYear, territoryId: territoryId });
            this.holidays = result || [];
        } catch (error) {
            console.error('Error loading holidays:', error);
            this.holidays = [];
        }
    }

    async loadUpcomingHolidays() {
        try {
            const result = await getUpcomingHolidays({ limitCount: 10 });
            const today = new Date();
            today.setHours(0, 0, 0, 0);

            this.upcomingHolidays = (result || []).map(h => {
                const holidayDate = new Date(h.Holiday_Date__c + 'T00:00:00');
                const diffTime = holidayDate.getTime() - today.getTime();
                const diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24));
                const typeInfo = TYPE_COLOR_MAP[h.Type__c] || {};

                let daysUntilLabel;
                if (diffDays === 0) {
                    daysUntilLabel = 'Today';
                } else if (diffDays === 1) {
                    daysUntilLabel = 'Tomorrow';
                } else {
                    daysUntilLabel = diffDays + ' days';
                }

                return {
                    ...h,
                    formattedDate: this.formatDisplayDate(h.Holiday_Date__c),
                    typeBadgeClass: 'type-badge type-badge-sm ' + (typeInfo.badge || ''),
                    daysUntil: daysUntilLabel,
                    daysUntilClass: diffDays <= 7 ? 'days-until days-soon' : 'days-until'
                };
            });
        } catch (error) {
            console.error('Error loading upcoming holidays:', error);
            this.upcomingHolidays = [];
        }
    }

    async loadTypeOptions() {
        try {
            const result = await getHolidayTypeOptions();
            if (result && result.length > 0) {
                this.typeOptions = result.map(opt => ({
                    label: opt.label,
                    value: opt.value
                }));
            }
        } catch (error) {
            console.error('Error loading type options:', error);
        }
    }

    async loadTerritoryOptions() {
        try {
            const result = await getTerritoryOptions();
            this.territoryOptions = result || [];
        } catch (error) {
            console.error('Error loading territory options:', error);
            this.territoryOptions = [];
        }
    }

    // ── Calendar Building ────────────────────────────────────────────────

    buildCalendarData() {
        const holidaysByDate = {};

        this.filteredHolidays.forEach(h => {
            if (h.Holiday_Date__c) {
                const dateKey = h.Holiday_Date__c;
                if (!holidaysByDate[dateKey]) {
                    holidaysByDate[dateKey] = [];
                }
                holidaysByDate[dateKey].push(h);
            }
        });

        const todayStr = this.formatDateKey(new Date());
        const months = [];

        for (let m = 0; m < 12; m++) {
            const monthData = this.buildMonthCalendar(m, this.selectedYear, holidaysByDate, todayStr);
            months.push(monthData);
        }

        this.calendarMonths = months;
    }

    buildMonthCalendar(monthIndex, year, holidaysByDate, todayStr) {
        const firstDay = new Date(year, monthIndex, 1);
        const lastDay = new Date(year, monthIndex + 1, 0);
        const startDayOfWeek = firstDay.getDay();
        const totalDays = lastDay.getDate();

        const weeks = [];
        let currentDay = 1;
        let weekIndex = 0;

        // Build up to 6 weeks
        while (currentDay <= totalDays && weekIndex < 6) {
            const week = { key: 'w_' + monthIndex + '_' + weekIndex, days: [] };

            for (let dayOfWeek = 0; dayOfWeek < 7; dayOfWeek++) {
                if ((weekIndex === 0 && dayOfWeek < startDayOfWeek) || currentDay > totalDays) {
                    // Empty cell
                    week.days.push({
                        key: 'e_' + monthIndex + '_' + weekIndex + '_' + dayOfWeek,
                        dayNumber: '',
                        isEmpty: true,
                        cellClass: 'mini-day-cell empty-cell',
                        holidays: null,
                        hasHolidays: false,
                        isToday: false,
                        dots: null
                    });
                } else {
                    const dateKey = this.buildDateKey(year, monthIndex, currentDay);
                    const dayHolidays = holidaysByDate[dateKey] || [];
                    const isToday = dateKey === todayStr;
                    const hasHolidays = dayHolidays.length > 0;

                    // Build dots for this day
                    const dots = hasHolidays ? dayHolidays.map((h, idx) => {
                        const typeInfo = TYPE_COLOR_MAP[h.Type__c] || {};
                        return {
                            key: 'dot_' + h.Id + '_' + idx,
                            dotClass: 'holiday-dot ' + (typeInfo.dot || ''),
                            holidayId: h.Id
                        };
                    }) : null;

                    let cellClass = 'mini-day-cell';
                    if (isToday) cellClass += ' today-cell';
                    if (hasHolidays) cellClass += ' has-holiday';

                    week.days.push({
                        key: 'd_' + dateKey,
                        dayNumber: currentDay,
                        isEmpty: false,
                        cellClass,
                        holidays: dayHolidays,
                        hasHolidays,
                        isToday,
                        dots,
                        dateKey
                    });
                    currentDay++;
                }
            }
            weeks.push(week);
            weekIndex++;
        }

        return {
            key: 'month_' + monthIndex,
            monthName: MONTH_NAMES_SHORT[monthIndex],
            monthFullName: MONTH_NAMES[monthIndex],
            weeks
        };
    }

    // ── Year Navigation ──────────────────────────────────────────────────

    handlePreviousYear() {
        this.selectedYear--;
        this.closePopover();
        this.loadAllData();
    }

    handleNextYear() {
        this.selectedYear++;
        this.closePopover();
        this.loadAllData();
    }

    // ── View Toggle ──────────────────────────────────────────────────────

    handleCalendarView() {
        this.isCalendarView = true;
        this.closePopover();
    }

    handleListView() {
        this.isCalendarView = false;
        this.closePopover();
    }

    // ── Type Filter ──────────────────────────────────────────────────────

    handleFilterChipClick(event) {
        const typeValue = event.currentTarget.dataset.type;
        if (!typeValue) return;

        const idx = this.selectedTypeFilters.indexOf(typeValue);
        if (idx >= 0) {
            this.selectedTypeFilters = this.selectedTypeFilters.filter(t => t !== typeValue);
        } else {
            this.selectedTypeFilters = [...this.selectedTypeFilters, typeValue];
        }
        this.buildCalendarData();
    }

    // ── Territory Filter ─────────────────────────────────────────────────

    handleTerritoryFilterChange(event) {
        this.selectedTerritoryFilter = event.detail.value || '';
        this.closePopover();
        this.loadAllData();
    }

    handleEditTerritoryChange(event) {
        this.editHoliday = { ...this.editHoliday, Territory__c: event.detail.value || null };
    }

    handleBulkTerritoryChange(event) {
        const rowKey = event.target.dataset.key;
        const value = event.detail.value;
        this.bulkRows = this.bulkRows.map(row => {
            if (row.key === rowKey) {
                return { ...row, Territory__c: value || null };
            }
            return row;
        });
    }

    // ── List View Sorting ────────────────────────────────────────────────

    handleSort() {
        if (this.sortField === 'Holiday_Date__c') {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortField = 'Holiday_Date__c';
            this.sortDirection = 'asc';
        }
    }

    // ── Popover (Calendar Day Click) ─────────────────────────────────────

    handleDayClick(event) {
        const dateKey = event.currentTarget.dataset.date;
        if (!dateKey) return;

        // Find holidays for this date
        const dayHolidays = this.holidays.filter(h => h.Holiday_Date__c === dateKey);
        if (dayHolidays.length === 0) {
            this.closePopover();
            return;
        }

        // Position popover near the clicked element (using viewport coords for position:fixed)
        const rect = event.currentTarget.getBoundingClientRect();
        const viewportHeight = window.innerHeight;
        const viewportWidth = window.innerWidth;
        const popoverEstimatedHeight = 200;
        const popoverMaxWidth = 360;

        // Check if popover would overflow the bottom of the viewport
        let popoverTop;
        if (rect.bottom + popoverEstimatedHeight + 4 > viewportHeight) {
            // Show above the clicked element
            popoverTop = rect.top - popoverEstimatedHeight - 4;
            // If it would also go above viewport, clamp to top
            if (popoverTop < 4) {
                popoverTop = 4;
            }
        } else {
            // Show below the clicked element
            popoverTop = rect.bottom + 4;
        }

        // Check if popover would overflow the right edge
        let popoverLeft = rect.left;
        if (popoverLeft + popoverMaxWidth > viewportWidth) {
            popoverLeft = viewportWidth - popoverMaxWidth - 8;
        }
        if (popoverLeft < 4) {
            popoverLeft = 4;
        }

        this.popoverStyle = 'top: ' + popoverTop + 'px; left: ' + popoverLeft + 'px;';
        this.popoverHoliday = dayHolidays.map(h => {
            const typeInfo = TYPE_COLOR_MAP[h.Type__c] || {};
            return {
                ...h,
                typeBadgeClass: 'type-badge type-badge-sm ' + (typeInfo.badge || ''),
                formattedDate: this.formatDisplayDate(h.Holiday_Date__c),
                territoryDisplay: (h.Territory__r && h.Territory__r.Name) ? h.Territory__r.Name : 'All Territories'
            };
        });
        this.showPopover = true;
    }

    handlePopoverClose() {
        this.closePopover();
    }

    closePopover() {
        this.showPopover = false;
        this.popoverHoliday = null;
    }

    handleBackdropClick() {
        this.closePopover();
    }

    // ── Add / Edit Holiday ───────────────────────────────────────────────

    handleAddHoliday() {
        this.isEditMode = false;
        this.editHoliday = {
            Name: '',
            Holiday_Date__c: '',
            Type__c: '',
            Description__c: '',
            Territory__c: '',
            Is_Active__c: true
        };
        this.showEditModal = true;
    }

    handleEditHoliday(event) {
        const holidayId = event.currentTarget.dataset.id;
        const holiday = this.holidays.find(h => h.Id === holidayId);
        if (!holiday) return;

        this.isEditMode = true;
        this.editHoliday = { ...holiday };
        this.showEditModal = true;
    }

    handleEditFromPopover(event) {
        const holidayId = event.currentTarget.dataset.id;
        this.closePopover();
        const holiday = this.holidays.find(h => h.Id === holidayId);
        if (!holiday) return;

        this.isEditMode = true;
        this.editHoliday = { ...holiday };
        this.showEditModal = true;
    }

    handleCloseEditModal() {
        this.showEditModal = false;
        this.editHoliday = {};
    }

    handleEditFieldChange(event) {
        const field = event.target.dataset.field;
        if (!field) return;

        if (field === 'Is_Active__c') {
            this.editHoliday = { ...this.editHoliday, [field]: event.target.checked };
        } else {
            this.editHoliday = { ...this.editHoliday, [field]: event.target.value };
        }
    }

    handleEditTerritoryChange(event) {
        this.editHoliday = { ...this.editHoliday, Territory__c: event.detail.value || null };
    }

    async handleSaveHoliday() {
        // Validate required fields
        if (!this.editHoliday.Name || !this.editHoliday.Holiday_Date__c || !this.editHoliday.Type__c) {
            this.showToast('Warning', 'Please fill in all required fields: Name, Date, and Type.', 'warning');
            return;
        }

        this.isLoading = true;
        try {
            const holidayRecord = {
                Name: this.editHoliday.Name,
                Holiday_Date__c: this.editHoliday.Holiday_Date__c,
                Type__c: this.editHoliday.Type__c,
                Description__c: this.editHoliday.Description__c || '',
                Territory__c: this.editHoliday.Territory__c || null,
                Is_Active__c: this.editHoliday.Is_Active__c !== false
            };

            if (this.editHoliday.Id) {
                holidayRecord.Id = this.editHoliday.Id;
            }

            // Handle sobjectType for Apex serialization
            holidayRecord.sobjectType = 'Holiday__c';

            await saveHoliday({ holiday: holidayRecord });

            const action = this.isEditMode ? 'updated' : 'created';
            this.showToast('Success', 'Holiday ' + action + ' successfully.', 'success');
            this.showEditModal = false;
            this.editHoliday = {};
            await this.loadAllData();
        } catch (error) {
            this.showToast('Error', 'Failed to save holiday: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Delete Holiday ───────────────────────────────────────────────────

    async handleDeleteHoliday(event) {
        const holidayId = event.currentTarget.dataset.id;
        if (!holidayId) return;

        const holiday = this.holidays.find(h => h.Id === holidayId);
        const holidayName = holiday ? holiday.Name : 'this holiday';

        // eslint-disable-next-line no-restricted-globals, no-alert
        if (!confirm('Are you sure you want to delete "' + holidayName + '"?')) {
            return;
        }

        this.isLoading = true;
        try {
            await deleteHoliday({ holidayId });
            this.showToast('Success', 'Holiday deleted successfully.', 'success');
            await this.loadAllData();
        } catch (error) {
            this.showToast('Error', 'Failed to delete holiday: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleDeleteFromPopover(event) {
        this.closePopover();
        this.handleDeleteHoliday(event);
    }

    // ── Bulk Import ──────────────────────────────────────────────────────

    handleOpenBulkModal() {
        this.bulkRows = [this.createEmptyBulkRow()];
        this.showBulkModal = true;
    }

    handleCloseBulkModal() {
        this.showBulkModal = false;
        this.bulkRows = [];
    }

    createEmptyBulkRow() {
        return {
            key: 'bulk_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9),
            Name: '',
            Holiday_Date__c: '',
            Type__c: '',
            Territory__c: ''
        };
    }

    handleAddBulkRow() {
        this.bulkRows = [...this.bulkRows, this.createEmptyBulkRow()];
    }

    handleRemoveBulkRow(event) {
        const rowKey = event.currentTarget.dataset.key;
        if (this.bulkRows.length <= 1) return;
        this.bulkRows = this.bulkRows.filter(r => r.key !== rowKey);
    }

    handleBulkFieldChange(event) {
        const rowKey = event.currentTarget.dataset.key;
        const field = event.currentTarget.dataset.field;
        const value = event.currentTarget.value;

        this.bulkRows = this.bulkRows.map(row => {
            if (row.key === rowKey) {
                return { ...row, [field]: value };
            }
            return row;
        });
    }

    handleBulkTerritoryChange(event) {
        const rowKey = event.currentTarget.dataset.key;
        const value = event.detail.value || '';

        this.bulkRows = this.bulkRows.map(row => {
            if (row.key === rowKey) {
                return { ...row, Territory__c: value };
            }
            return row;
        });
    }

    async handleSaveBulk() {
        // Validate
        const invalidRows = this.bulkRows.filter(r => !r.Name || !r.Holiday_Date__c || !r.Type__c);
        if (invalidRows.length > 0) {
            this.showToast('Warning', 'Please fill in Name, Date, and Type for all rows.', 'warning');
            return;
        }

        this.isLoading = true;
        try {
            const records = this.bulkRows.map(r => ({
                sobjectType: 'Holiday__c',
                Name: r.Name,
                Holiday_Date__c: r.Holiday_Date__c,
                Type__c: r.Type__c,
                Territory__c: r.Territory__c || null,
                Is_Active__c: true
            }));

            await bulkCreateHolidays({ holidays: records });
            this.showToast('Success', records.length + ' holiday(s) created successfully.', 'success');
            this.showBulkModal = false;
            this.bulkRows = [];
            await this.loadAllData();
        } catch (error) {
            this.showToast('Error', 'Bulk import failed: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Utility ──────────────────────────────────────────────────────────

    getMonthName(monthIndex) {
        return MONTH_NAMES[monthIndex] || '';
    }

    getDayOfWeek(year, month, day) {
        return new Date(year, month, day).getDay();
    }

    buildDateKey(year, month, day) {
        const m = String(month + 1).padStart(2, '0');
        const d = String(day).padStart(2, '0');
        return year + '-' + m + '-' + d;
    }

    formatDateKey(date) {
        const y = date.getFullYear();
        const m = String(date.getMonth() + 1).padStart(2, '0');
        const d = String(date.getDate()).padStart(2, '0');
        return y + '-' + m + '-' + d;
    }

    formatDisplayDate(dateStr) {
        if (!dateStr) return '';
        const parts = dateStr.split('-');
        if (parts.length !== 3) return dateStr;
        const monthIdx = parseInt(parts[1], 10) - 1;
        const day = parseInt(parts[2], 10);
        return day + ' ' + MONTH_NAMES_SHORT[monthIdx] + ' ' + parts[0];
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