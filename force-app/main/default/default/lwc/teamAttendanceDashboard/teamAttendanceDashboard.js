import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getTeamAttendance from '@salesforce/apex/DayAttendanceController.getTeamAttendance';
import getTeamAttendanceSummary from '@salesforce/apex/DayAttendanceController.getTeamAttendanceSummary';
import getAttendanceConfig from '@salesforce/apex/DayAttendanceController.getAttendanceConfig';

/** INR currency formatter */
const INR_FORMATTER = new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0
});

/** Number formatter for Indian locale */
const NUMBER_FORMATTER = new Intl.NumberFormat('en-IN', {
    minimumFractionDigits: 0,
    maximumFractionDigits: 1
});

/** Status-to-badge CSS class mapping */
const STATUS_BADGE_MAP = {
    'Started':      'status-badge status-badge-started',
    'Ended':        'status-badge status-badge-ended',
    'Auto-Closed':  'status-badge status-badge-autoclosed',
    'Leave':        'status-badge status-badge-leave',
    'Not Started':  'status-badge status-badge-absent'
};

/** Default auto-refresh interval in seconds */
const DEFAULT_REFRESH_INTERVAL_SEC = 120;

/** Daily datatable columns */
const DAILY_COLUMNS = [
    {
        label: 'Salesperson',
        fieldName: 'salespersonName',
        type: 'text',
        sortable: true,
        initialWidth: 160,
        cellAttributes: { class: 'slds-text-title_bold' }
    },
    {
        label: 'Status',
        fieldName: 'status',
        type: 'text',
        sortable: true,
        initialWidth: 120,
        cellAttributes: { class: { fieldName: 'statusCellClass' } }
    },
    {
        label: 'Start Time',
        fieldName: 'startTime',
        type: 'text',
        sortable: true,
        initialWidth: 100
    },
    {
        label: 'End Time',
        fieldName: 'endTime',
        type: 'text',
        sortable: true,
        initialWidth: 100
    },
    {
        label: 'Hours Worked',
        fieldName: 'hoursWorked',
        type: 'number',
        sortable: true,
        initialWidth: 100,
        typeAttributes: { minimumFractionDigits: 1, maximumFractionDigits: 1 },
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Total Visits',
        fieldName: 'totalVisits',
        type: 'number',
        sortable: true,
        initialWidth: 95,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Productive %',
        fieldName: 'productivityPercent',
        type: 'number',
        sortable: true,
        initialWidth: 105,
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 1 },
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Distance (km)',
        fieldName: 'distanceTraveled',
        type: 'number',
        sortable: true,
        initialWidth: 110,
        typeAttributes: { minimumFractionDigits: 1, maximumFractionDigits: 1 },
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Orders',
        fieldName: 'totalOrders',
        type: 'number',
        sortable: true,
        initialWidth: 80,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Order Value (INR)',
        fieldName: 'orderValueFormatted',
        type: 'text',
        sortable: true,
        initialWidth: 140,
        cellAttributes: { alignment: 'right' }
    },
    {
        label: 'Collections (INR)',
        fieldName: 'collectionsFormatted',
        type: 'text',
        sortable: true,
        initialWidth: 140,
        cellAttributes: { alignment: 'right' }
    },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'View Detail', name: 'view_detail' }
            ]
        }
    }
];

/** Weekly per-member summary columns */
const WEEKLY_COLUMNS = [
    { label: 'Salesperson', fieldName: 'name', type: 'text', sortable: true },
    { label: 'Days Present', fieldName: 'presentCount', type: 'number', cellAttributes: { alignment: 'center' } },
    { label: 'Leave Days', fieldName: 'leaveCount', type: 'number', cellAttributes: { alignment: 'center' } },
    { label: 'Avg Hours', fieldName: 'avgHours', type: 'number', typeAttributes: { minimumFractionDigits: 1, maximumFractionDigits: 1 }, cellAttributes: { alignment: 'center' } },
    { label: 'Avg Productivity %', fieldName: 'avgProductivity', type: 'number', typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 1 }, cellAttributes: { alignment: 'center' } },
    { label: 'Total Orders', fieldName: 'totalOrders', type: 'number', cellAttributes: { alignment: 'center' } },
    { label: 'Order Value (INR)', fieldName: 'totalOrderValueFormatted', type: 'text', cellAttributes: { alignment: 'right' } },
    { label: 'Collections (INR)', fieldName: 'totalCollectionsFormatted', type: 'text', cellAttributes: { alignment: 'right' } }
];

export default class TeamAttendanceDashboard extends NavigationMixin(LightningElement) {

    // ── Reactive properties ──────────────────────────────────────────
    @track selectedDate = '';
    @track selectedEndDate = '';
    @track isLoading = false;
    @track isWeeklyView = false;
    @track attendanceRecords = [];
    @track tableData = [];
    @track weeklySummary = {};
    @track weeklySummaryRows = [];
    @track lastRefreshTime = null;

    // Summary card counts
    @track presentCount = 0;
    @track leaveCount = 0;
    @track absentCount = 0;
    @track autoClosedCount = 0;

    // Table sort state
    @track sortedBy = 'salespersonName';
    @track sortedDirection = 'asc';

    // Columns
    columns = DAILY_COLUMNS;
    weeklyColumns = WEEKLY_COLUMNS;

    // Configuration
    _refreshIntervalSec = DEFAULT_REFRESH_INTERVAL_SEC;
    _refreshTimer = null;
    _isMobile = false;
    _resizeObserver = null;

    // ══════════════════════════════════════════════════════════════════
    //  LIFECYCLE
    // ══════════════════════════════════════════════════════════════════

    connectedCallback() {
        this._initDates();
        this._loadConfig();
        this._loadAttendanceData();
        this._detectViewport();
        this._initResizeListener();
    }

    disconnectedCallback() {
        this._clearRefreshTimer();
        if (this._resizeObserver) {
            this._resizeObserver.disconnect();
            this._resizeObserver = null;
        }
        window.removeEventListener('resize', this._boundHandleResize);
    }

    // ══════════════════════════════════════════════════════════════════
    //  COMPUTED GETTERS
    // ══════════════════════════════════════════════════════════════════

    /** Whether records exist for daily view */
    get hasAttendanceRecords() {
        return this.tableData && this.tableData.length > 0;
    }

    /** Whether weekly summary has data */
    get hasWeeklySummary() {
        return this.weeklySummary && (
            this.weeklySummary.totalMembers > 0 ||
            this.weeklySummary.presentCount > 0
        );
    }

    /** Whether weekly per-member rows exist */
    get hasWeeklySummaryRows() {
        return this.weeklySummaryRows && this.weeklySummaryRows.length > 0;
    }

    /** Button variant for Daily toggle */
    get dailyButtonVariant() {
        return this.isWeeklyView ? 'neutral' : 'brand';
    }

    /** Button variant for Weekly toggle */
    get weeklyButtonVariant() {
        return this.isWeeklyView ? 'brand' : 'neutral';
    }

    /** Last refresh time display string */
    get lastRefreshDisplay() {
        if (!this.lastRefreshTime) return '--';
        return this.lastRefreshTime.toLocaleTimeString('en-IN', {
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit',
            hour12: true
        });
    }

    // ══════════════════════════════════════════════════════════════════
    //  INITIALIZATION
    // ══════════════════════════════════════════════════════════════════

    /** Set default dates: today for daily, last 7 days for weekly */
    _initDates() {
        const today = new Date();
        this.selectedDate = this._toISODateString(today);

        const weekAgo = new Date(today);
        weekAgo.setDate(weekAgo.getDate() - 6);
        this.selectedEndDate = this._toISODateString(today);
    }

    /** Load configuration from Apex */
    async _loadConfig() {
        try {
            const config = await getAttendanceConfig();
            if (config) {
                this._refreshIntervalSec = config.statsRefreshInterval || DEFAULT_REFRESH_INTERVAL_SEC;
            }
            this._startRefreshTimer();
        } catch (error) {
            console.error('TeamAttendanceDashboard: Error loading config', error);
            this._startRefreshTimer();
        }
    }

    /** Viewport detection */
    _detectViewport() {
        this._isMobile = window.innerWidth < 768;
    }

    /** Listen for window resize to toggle mobile/desktop */
    _initResizeListener() {
        this._boundHandleResize = () => {
            this._detectViewport();
        };
        window.addEventListener('resize', this._boundHandleResize);
    }

    // ══════════════════════════════════════════════════════════════════
    //  DATA LOADING
    // ══════════════════════════════════════════════════════════════════

    /** Main data loader - routes to daily or weekly */
    async _loadAttendanceData() {
        if (this.isWeeklyView) {
            await this._loadWeeklySummary();
        } else {
            await this._loadDailyAttendance();
        }
        this.lastRefreshTime = new Date();
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. Recurses into arrays
    // and child relationships. No-op on camelCase maps and wrapper DTOs.
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

    /** Load daily attendance records */
    async _loadDailyAttendance() {
        this.isLoading = true;
        try {
            const result = this._stripNs(await getTeamAttendance({
                attendanceDate: this.selectedDate
            }));
            this.attendanceRecords = result || [];
            this._processAttendanceRecords();
        } catch (error) {
            this._showToast('Error', 'Failed to load attendance: ' + this._reduceErrors(error), 'error');
            this.attendanceRecords = [];
            this.tableData = [];
            this._resetSummaryCards();
        } finally {
            this.isLoading = false;
        }
    }

    /** Load weekly summary data */
    async _loadWeeklySummary() {
        this.isLoading = true;
        try {
            const result = await getTeamAttendanceSummary({
                fromDate: this.selectedDate,
                toDate: this.selectedEndDate
            });
            this._processWeeklySummary(result);
        } catch (error) {
            this._showToast('Error', 'Failed to load weekly summary: ' + this._reduceErrors(error), 'error');
            this.weeklySummary = {};
            this.weeklySummaryRows = [];
        } finally {
            this.isLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  DATA PROCESSING
    // ══════════════════════════════════════════════════════════════════

    /** Process raw Day_Attendance__c records into table rows and summary counts */
    _processAttendanceRecords() {
        let present = 0;
        let leave = 0;
        let absent = 0;
        let autoClosed = 0;

        this.tableData = this.attendanceRecords.map((record, index) => {
            const status = this._deriveStatus(record);

            // Count summary cards
            if (status === 'Leave') {
                leave++;
            } else if (status === 'Auto-Closed') {
                autoClosed++;
                present++; // auto-closed were present
            } else if (status === 'Started' || status === 'Ended') {
                present++;
            } else {
                absent++;
            }

            const orderVal = record.Total_Order_Value__c || 0;
            const collectionVal = record.Total_Collection__c || 0;

            return {
                id: record.Id || 'row_' + index,
                recordId: record.Id,
                salespersonName: record.Salesperson__r
                    ? record.Salesperson__r.Name
                    : (record.User__r ? record.User__r.Name : record.Name || 'Unknown'),
                status: status,
                statusBadgeClass: STATUS_BADGE_MAP[status] || 'status-badge status-badge-absent',
                statusCellClass: this._getStatusCellClass(status),
                startTime: this._formatTime(record.Start_Time__c),
                endTime: this._formatTime(record.End_Time__c),
                hoursWorked: record.Hours_Worked__c || 0,
                totalVisits: record.Total_Visits__c || 0,
                productiveCalls: record.Productive_Calls__c || 0,
                productivityPercent: record.Productivity_Percent__c != null
                    ? Math.round(record.Productivity_Percent__c)
                    : 0,
                distanceTraveled: record.Distance_Traveled_Km__c || 0,
                totalOrders: record.Total_Orders__c || 0,
                orderValue: orderVal,
                orderValueFormatted: INR_FORMATTER.format(orderVal),
                collectionValue: collectionVal,
                collectionsFormatted: INR_FORMATTER.format(collectionVal)
            };
        });

        this.presentCount = present;
        this.leaveCount = leave;
        this.absentCount = absent;
        this.autoClosedCount = autoClosed;
    }

    /** Derive a display status from the record fields */
    _deriveStatus(record) {
        if (record.Is_Leave_Day__c === true) {
            return 'Leave';
        }
        if (record.Auto_Closed__c === true) {
            return 'Auto-Closed';
        }
        const statusVal = (record.Status__c || '').toLowerCase();
        if (statusVal === 'started' || statusVal === 'in progress' || statusVal === 'active') {
            return 'Started';
        }
        if (statusVal === 'ended' || statusVal === 'completed' || statusVal === 'closed') {
            return 'Ended';
        }
        if (statusVal === 'leave') {
            return 'Leave';
        }
        if (statusVal === 'auto-closed' || statusVal === 'auto closed') {
            return 'Auto-Closed';
        }
        if (record.Start_Time__c && record.End_Time__c) {
            return 'Ended';
        }
        if (record.Start_Time__c && !record.End_Time__c) {
            return 'Started';
        }
        return 'Not Started';
    }

    /** Get cell class for status column styling */
    _getStatusCellClass(status) {
        const classMap = {
            'Started': 'status-cell-started',
            'Ended': 'status-cell-ended',
            'Auto-Closed': 'status-cell-autoclosed',
            'Leave': 'status-cell-leave',
            'Not Started': 'status-cell-absent'
        };
        return classMap[status] || '';
    }

    /** Process weekly summary from API response */
    _processWeeklySummary(result) {
        if (!result || !Array.isArray(result) || result.length === 0) {
            this.weeklySummary = {};
            this.weeklySummaryRows = [];
            return;
        }

        // Aggregate totals across all members
        let totalMembers = 0;
        let totalPresentDays = 0;
        let totalLeaveDays = 0;
        let totalAbsentDays = 0;
        let sumProductivity = 0;
        let sumVisits = 0;
        let sumHours = 0;
        let totalOrders = 0;
        let totalOrderValue = 0;
        let totalCollections = 0;
        let memberCount = 0;

        const memberRows = result.map((row, index) => {
            const presentDays = row.presentCount || 0;
            const leaveDays = row.leaveCount || 0;
            const absentDays = row.absentCount || 0;
            const avgProd = row.avgProductivity || 0;
            const avgVis = row.avgVisits || 0;
            const avgHrs = row.avgHours || 0;
            const orders = row.totalOrders || 0;
            const orderVal = row.totalOrderValue || 0;
            const collections = row.totalCollections || 0;

            totalPresentDays += presentDays;
            totalLeaveDays += leaveDays;
            totalAbsentDays += absentDays;
            sumProductivity += avgProd;
            sumVisits += avgVis;
            sumHours += avgHrs;
            totalOrders += orders;
            totalOrderValue += orderVal;
            totalCollections += collections;
            memberCount++;

            return {
                id: row.userId || 'member_' + index,
                name: row.userName || row.salespersonName || 'Team Member',
                presentCount: presentDays,
                leaveCount: leaveDays,
                absentCount: absentDays,
                avgHours: Number(avgHrs.toFixed(1)),
                avgProductivity: Number(avgProd.toFixed(1)),
                totalOrders: orders,
                totalOrderValue: orderVal,
                totalOrderValueFormatted: INR_FORMATTER.format(orderVal),
                totalCollections: collections,
                totalCollectionsFormatted: INR_FORMATTER.format(collections)
            };
        });

        totalMembers = memberCount;
        const avgProductivity = memberCount > 0 ? Number((sumProductivity / memberCount).toFixed(1)) : 0;
        const avgVisits = memberCount > 0 ? Number((sumVisits / memberCount).toFixed(1)) : 0;
        const avgHours = memberCount > 0 ? Number((sumHours / memberCount).toFixed(1)) : 0;

        this.weeklySummary = {
            totalMembers: totalMembers,
            presentCount: totalPresentDays,
            leaveCount: totalLeaveDays,
            absentCount: totalAbsentDays,
            avgProductivity: avgProductivity,
            avgVisits: avgVisits,
            avgHours: avgHours,
            totalOrders: totalOrders,
            totalOrderValue: totalOrderValue,
            totalOrderValueFormatted: INR_FORMATTER.format(totalOrderValue),
            totalCollections: totalCollections,
            totalCollectionsFormatted: INR_FORMATTER.format(totalCollections)
        };

        this.weeklySummaryRows = memberRows;
    }

    /** Reset summary card counts */
    _resetSummaryCards() {
        this.presentCount = 0;
        this.leaveCount = 0;
        this.absentCount = 0;
        this.autoClosedCount = 0;
    }

    // ══════════════════════════════════════════════════════════════════
    //  EVENT HANDLERS
    // ══════════════════════════════════════════════════════════════════

    /** Date picker change */
    handleDateChange(event) {
        this.selectedDate = event.target.value;
        this._loadAttendanceData();
    }

    /** End date picker change (weekly view) */
    handleEndDateChange(event) {
        this.selectedEndDate = event.target.value;
        if (this.isWeeklyView) {
            this._loadAttendanceData();
        }
    }

    /** Switch to Daily view */
    handleDailyView() {
        if (!this.isWeeklyView) return;
        this.isWeeklyView = false;
        this._loadAttendanceData();
    }

    /** Switch to Weekly Summary view */
    handleWeeklyView() {
        if (this.isWeeklyView) return;
        this.isWeeklyView = true;

        // Default end date to selectedDate, start date to 7 days before
        const endDate = new Date(this.selectedDate + 'T00:00:00');
        const startDate = new Date(endDate);
        startDate.setDate(startDate.getDate() - 6);
        this.selectedEndDate = this._toISODateString(endDate);
        this.selectedDate = this._toISODateString(startDate);

        this._loadAttendanceData();
    }

    /** Manual refresh */
    handleRefresh() {
        this._loadAttendanceData();
    }

    /** Datatable row action handler */
    handleRowAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;

        if (action.name === 'view_detail') {
            this._navigateToRecord(row.recordId);
        }
    }

    /** Mobile card click handler */
    handleMobileCardClick(event) {
        const recordId = event.currentTarget.dataset.recordId;
        if (recordId) {
            this._navigateToRecord(recordId);
        }
    }

    /** Datatable column sorting */
    handleSort(event) {
        const { fieldName, sortDirection } = event.detail;
        this.sortedBy = fieldName;
        this.sortedDirection = sortDirection;

        const cloneData = [...this.tableData];
        cloneData.sort(this._sortBy(fieldName, sortDirection === 'asc' ? 1 : -1));
        this.tableData = cloneData;
    }

    // ══════════════════════════════════════════════════════════════════
    //  NAVIGATION
    // ══════════════════════════════════════════════════════════════════

    /** Navigate to a Day_Attendance__c record page */
    _navigateToRecord(recordId) {
        if (!recordId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: recordId,
                objectApiName: 'Day_Attendance__c',
                actionName: 'view'
            }
        });
    }

    // ══════════════════════════════════════════════════════════════════
    //  AUTO-REFRESH
    // ══════════════════════════════════════════════════════════════════

    /** Start the auto-refresh timer */
    _startRefreshTimer() {
        this._clearRefreshTimer();
        const intervalMs = (this._refreshIntervalSec || DEFAULT_REFRESH_INTERVAL_SEC) * 1000;
        this._refreshTimer = setInterval(() => {
            this._loadAttendanceData();
        }, intervalMs);
    }

    /** Clear the auto-refresh timer */
    _clearRefreshTimer() {
        if (this._refreshTimer) {
            clearInterval(this._refreshTimer);
            this._refreshTimer = null;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  UTILITIES
    // ══════════════════════════════════════════════════════════════════

    /** Format a datetime field value to time string */
    _formatTime(dateTimeValue) {
        if (!dateTimeValue) return '--';
        try {
            const dt = new Date(dateTimeValue);
            if (isNaN(dt.getTime())) return '--';
            return dt.toLocaleTimeString('en-IN', {
                hour: '2-digit',
                minute: '2-digit',
                hour12: true
            });
        } catch (e) {
            return '--';
        }
    }

    /** Convert a Date to YYYY-MM-DD string */
    _toISODateString(date) {
        const year = date.getFullYear();
        const month = String(date.getMonth() + 1).padStart(2, '0');
        const day = String(date.getDate()).padStart(2, '0');
        return year + '-' + month + '-' + day;
    }

    /** Generic sort comparator factory */
    _sortBy(field, direction) {
        return (a, b) => {
            let valA = a[field];
            let valB = b[field];

            // Handle null/undefined
            if (valA === undefined || valA === null) valA = '';
            if (valB === undefined || valB === null) valB = '';

            // String comparison
            if (typeof valA === 'string' && typeof valB === 'string') {
                return direction * valA.localeCompare(valB, 'en-IN', { sensitivity: 'base' });
            }

            // Numeric comparison
            if (valA < valB) return -1 * direction;
            if (valA > valB) return 1 * direction;
            return 0;
        };
    }

    /** Show toast notification */
    _showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    /** Extract user-facing message from Apex/LDS errors */
    _reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.body && error.body.fieldErrors) {
            const fieldMsgs = Object.values(error.body.fieldErrors)
                .flat()
                .map(e => e.message);
            if (fieldMsgs.length) return fieldMsgs.join('; ');
        }
        if (error.body && error.body.pageErrors) {
            const pageMsgs = error.body.pageErrors.map(e => e.message);
            if (pageMsgs.length) return pageMsgs.join('; ');
        }
        if (error.message) return error.message;
        if (Array.isArray(error)) {
            return error.map(e => this._reduceErrors(e)).join('; ');
        }
        return 'An unknown error occurred.';
    }
}