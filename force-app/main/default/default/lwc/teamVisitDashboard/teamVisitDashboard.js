/**
 * @description Team Visit Dashboard - Manager view of team visit performance.
 *              Displays KPI summary cards, a detailed data table with sortable columns,
 *              productivity color-coding, team totals, and responsive card layout
 *              for mobile devices. Auto-refreshes every 60 seconds.
 *
 * @author  SFA Development Team
 * @date    2026
 */
import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import getTeamVisits from '@salesforce/apex/VisitCheckInController.getTeamVisits';

/* ─── Constants ─── */
const AUTO_REFRESH_INTERVAL_MS = 60000; // 60 seconds

const INR_FORMATTER = new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0
});

const INR_FORMATTER_DECIMAL = new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
});

const ROW_ACTIONS = [
    { label: 'View Visits', name: 'view_visits' }
];

const COLUMNS = [
    {
        label: 'Salesperson',
        fieldName: 'userName',
        type: 'text',
        sortable: true,
        initialWidth: 180,
        cellAttributes: { class: 'slds-text-title_bold' }
    },
    {
        label: 'Total Visits',
        fieldName: 'totalVisits',
        type: 'number',
        sortable: true,
        initialWidth: 110,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Productive',
        fieldName: 'productiveVisits',
        type: 'number',
        sortable: true,
        initialWidth: 110,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Non-Productive',
        fieldName: 'nonProductiveVisits',
        type: 'number',
        sortable: true,
        initialWidth: 130,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Skipped',
        fieldName: 'skippedVisits',
        type: 'number',
        sortable: true,
        initialWidth: 100,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Avg Duration (min)',
        fieldName: 'avgDurationMinutes',
        type: 'number',
        sortable: true,
        initialWidth: 150,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: 'Orders Value (INR)',
        fieldName: 'totalOrderValueFormatted',
        type: 'text',
        sortable: true,
        initialWidth: 160,
        cellAttributes: { alignment: 'right' }
    },
    {
        label: 'Collections (INR)',
        fieldName: 'totalCollectionsFormatted',
        type: 'text',
        sortable: true,
        initialWidth: 160,
        cellAttributes: { alignment: 'right' }
    },
    {
        label: 'Productivity %',
        fieldName: 'productivity',
        type: 'number',
        sortable: true,
        initialWidth: 130,
        cellAttributes: {
            alignment: 'center',
            class: { fieldName: 'productivityCellClass' }
        }
    },
    {
        type: 'action',
        typeAttributes: { rowActions: ROW_ACTIONS }
    }
];

export default class TeamVisitDashboard extends NavigationMixin(LightningElement) {

    /* ─── Tracked Properties ─── */
    @track selectedDate;
    @track teamData = [];
    @track isLoading = false;
    @track sortedBy = 'userName';
    @track sortedDirection = 'asc';
    @track lastRefreshed = null;

    /* ─── Private Properties ─── */
    columns = COLUMNS;
    autoRefreshTimer = null;
    autoRefreshActive = true;

    /* ─── Lifecycle ─── */
    connectedCallback() {
        this.selectedDate = this.getTodayDateString();
        this.loadTeamVisits();
        this.startAutoRefresh();
    }

    disconnectedCallback() {
        this.stopAutoRefresh();
    }

    /* ─── Date Helpers ─── */
    getTodayDateString() {
        const today = new Date();
        const year = today.getFullYear();
        const month = String(today.getMonth() + 1).padStart(2, '0');
        const day = String(today.getDate()).padStart(2, '0');
        return `${year}-${month}-${day}`;
    }

    /* ─── Data Loading ─── */
    async loadTeamVisits() {
        this.isLoading = true;
        try {
            const result = await getTeamVisits({ visitDate: this.selectedDate });
            if (result) {
                this.teamData = result.map(item => this.transformVisitRecord(item));
            } else {
                this.teamData = [];
            }
            this.lastRefreshed = new Date();
            this.applySorting();
        } catch (error) {
            this.teamData = [];
            this.showToast('Error', 'Failed to load team visit data: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    transformVisitRecord(item) {
        const totalVisits = item.totalVisits || 0;
        const productiveVisits = item.productiveVisits || 0;
        const nonProductiveVisits = item.nonProductiveVisits || 0;
        const skippedVisits = item.skippedVisits || 0;
        const avgDurationMinutes = item.avgDurationMinutes != null ? Math.round(item.avgDurationMinutes) : 0;
        const totalOrderValue = item.totalOrderValue || 0;
        const totalCollections = item.totalCollections || 0;
        const productivity = item.productivity != null ? Math.round(item.productivity) : 0;
        const lastVisitTime = item.lastVisitTime || null;

        return {
            userId: item.userId,
            userName: item.userName || 'Unknown',
            totalVisits,
            productiveVisits,
            nonProductiveVisits,
            skippedVisits,
            avgDurationMinutes,
            totalOrderValue,
            totalOrderValueFormatted: this.formatCurrency(totalOrderValue),
            totalCollections,
            totalCollectionsFormatted: this.formatCurrency(totalCollections),
            productivity,
            lastVisitTime,
            productivityCellClass: this.getProductivityCellClass(productivity),
            productivityBadgeClass: this.getProductivityBadgeClass(productivity)
        };
    }

    /* ─── KPI Computed Properties ─── */
    get kpiTotalVisits() {
        return this.teamData.reduce((sum, m) => sum + m.totalVisits, 0);
    }

    get kpiAvgDuration() {
        if (this.teamData.length === 0) return 0;
        const totalDuration = this.teamData.reduce((sum, m) => sum + m.avgDurationMinutes, 0);
        return Math.round(totalDuration / this.teamData.length);
    }

    get kpiProductivePercent() {
        const totalVisits = this.kpiTotalVisits;
        if (totalVisits === 0) return 0;
        const totalProductive = this.teamData.reduce((sum, m) => sum + m.productiveVisits, 0);
        return Math.round((totalProductive / totalVisits) * 100);
    }

    get kpiOrdersValue() {
        const total = this.teamData.reduce((sum, m) => sum + m.totalOrderValue, 0);
        return this.formatCurrency(total);
    }

    get kpiCollections() {
        const total = this.teamData.reduce((sum, m) => sum + m.totalCollections, 0);
        return this.formatCurrency(total);
    }

    /* ─── Team Totals ─── */
    get teamTotals() {
        const totalVisits = this.teamData.reduce((sum, m) => sum + m.totalVisits, 0);
        const productiveVisits = this.teamData.reduce((sum, m) => sum + m.productiveVisits, 0);
        const nonProductiveVisits = this.teamData.reduce((sum, m) => sum + m.nonProductiveVisits, 0);
        const skippedVisits = this.teamData.reduce((sum, m) => sum + m.skippedVisits, 0);
        const totalOrderValue = this.teamData.reduce((sum, m) => sum + m.totalOrderValue, 0);
        const totalCollections = this.teamData.reduce((sum, m) => sum + m.totalCollections, 0);

        let avgDurationMinutes = 0;
        if (this.teamData.length > 0) {
            const totalDuration = this.teamData.reduce((sum, m) => sum + m.avgDurationMinutes, 0);
            avgDurationMinutes = Math.round(totalDuration / this.teamData.length);
        }

        const productivity = totalVisits > 0 ? Math.round((productiveVisits / totalVisits) * 100) : 0;

        return {
            totalVisits,
            productiveVisits,
            nonProductiveVisits,
            skippedVisits,
            avgDurationMinutes,
            totalOrderValue,
            totalOrderValueFormatted: this.formatCurrency(totalOrderValue),
            totalCollections,
            totalCollectionsFormatted: this.formatCurrency(totalCollections),
            productivity,
            productivityClass: this.getProductivityBadgeClass(productivity)
        };
    }

    /* ─── Table Data ─── */
    get tableData() {
        return this.teamData;
    }

    get hasData() {
        return this.teamData && this.teamData.length > 0;
    }

    get hasNoData() {
        return !this.isLoading && (!this.teamData || this.teamData.length === 0);
    }

    get lastRefreshedDisplay() {
        if (!this.lastRefreshed) return '';
        return this.lastRefreshed.toLocaleTimeString('en-IN', {
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit',
            hour12: true
        });
    }

    /* ─── Sorting ─── */
    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortedDirection = event.detail.sortDirection;
        this.applySorting();
    }

    applySorting() {
        const fieldName = this.sortedBy;
        const direction = this.sortedDirection === 'asc' ? 1 : -1;
        const isNumericField = [
            'totalVisits', 'productiveVisits', 'nonProductiveVisits',
            'skippedVisits', 'avgDurationMinutes', 'productivity'
        ].includes(fieldName);

        /* For formatted currency columns, sort by the raw numeric value */
        const sortFieldMap = {
            'totalOrderValueFormatted': 'totalOrderValue',
            'totalCollectionsFormatted': 'totalCollections'
        };
        const actualSortField = sortFieldMap[fieldName] || fieldName;
        const useNumericSort = isNumericField || sortFieldMap[fieldName];

        const sorted = [...this.teamData].sort((a, b) => {
            const valA = a[actualSortField];
            const valB = b[actualSortField];

            if (valA == null && valB == null) return 0;
            if (valA == null) return 1;
            if (valB == null) return -1;

            if (useNumericSort) {
                return (Number(valA) - Number(valB)) * direction;
            }
            return String(valA).localeCompare(String(valB)) * direction;
        });

        this.teamData = sorted;
    }

    /* ─── Event Handlers ─── */
    handleDateChange(event) {
        this.selectedDate = event.detail.value;
        this.loadTeamVisits();
    }

    handleRefresh() {
        this.loadTeamVisits();
        this.showToast('Refreshed', 'Team visit data has been refreshed.', 'success');
    }

    handleRowAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;

        if (action.name === 'view_visits') {
            this.navigateToUserVisits(row.userId);
        }
    }

    handleMobileViewVisits(event) {
        const userId = event.currentTarget.dataset.userId;
        this.navigateToUserVisits(userId);
    }

    /* ─── Navigation ─── */
    navigateToUserVisits(userId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: userId,
                objectApiName: 'User',
                actionName: 'view'
            }
        });
    }

    /* ─── Auto-Refresh ─── */
    startAutoRefresh() {
        this.stopAutoRefresh();
        this.autoRefreshActive = true;
        this.autoRefreshTimer = setInterval(() => {
            this.loadTeamVisits();
        }, AUTO_REFRESH_INTERVAL_MS);
    }

    stopAutoRefresh() {
        if (this.autoRefreshTimer) {
            clearInterval(this.autoRefreshTimer);
            this.autoRefreshTimer = null;
        }
        this.autoRefreshActive = false;
    }

    /* ─── Productivity Styling ─── */
    getProductivityCellClass(productivity) {
        if (productivity >= 80) {
            return 'productivity-high';
        } else if (productivity >= 60) {
            return 'productivity-medium';
        }
        return 'productivity-low';
    }

    getProductivityBadgeClass(productivity) {
        if (productivity >= 80) {
            return 'productivity-badge badge-green';
        } else if (productivity >= 60) {
            return 'productivity-badge badge-orange';
        }
        return 'productivity-badge badge-red';
    }

    /* ─── Formatting ─── */
    formatCurrency(value) {
        if (value == null) return INR_FORMATTER.format(0);
        if (value >= 100) {
            return INR_FORMATTER.format(value);
        }
        return INR_FORMATTER_DECIMAL.format(value);
    }

    /* ─── Toast ─── */
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    /* ─── Error Handling ─── */
    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        if (Array.isArray(error.body)) {
            return error.body.map(e => e.message).join(', ');
        }
        return 'Unknown error';
    }
}