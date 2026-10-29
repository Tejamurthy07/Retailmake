import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getInitData from '@salesforce/apex/DKD_Dashboard_Controller.getInitData';
import getKpiValues from '@salesforce/apex/DKD_Dashboard_Controller.getKpiValues';
import getMetricData from '@salesforce/apex/DKD_Dashboard_Controller.getMetricData';
import getTimeSeries from '@salesforce/apex/DKD_Dashboard_Controller.getTimeSeries';
import getPreviousPeriodValues from '@salesforce/apex/DKD_Dashboard_Controller.getPreviousPeriodValues';
import getForecast from '@salesforce/apex/DKD_Dashboard_Controller.getForecast';
import drillDown from '@salesforce/apex/DKD_Dashboard_Controller.drillDown';
import getInsights from '@salesforce/apex/DKD_Dashboard_Controller.getInsights';

// Saved views (Sprint 6)
import getMyViews from '@salesforce/apex/DKD_DashboardView_Controller.getMyViews';
import getDefaultView from '@salesforce/apex/DKD_DashboardView_Controller.getDefaultView';
import createView from '@salesforce/apex/DKD_DashboardView_Controller.createView';
import updateView from '@salesforce/apex/DKD_DashboardView_Controller.updateView';
import deleteView from '@salesforce/apex/DKD_DashboardView_Controller.deleteView';
import setDefaultView from '@salesforce/apex/DKD_DashboardView_Controller.setDefaultView';
import clearDefaultView from '@salesforce/apex/DKD_DashboardView_Controller.clearDefaultView';

const USER_SCOPES = [
    { label: 'Self', value: 'self' },
    { label: 'My Team', value: 'team' },
    { label: 'Organization', value: 'org' }
];

const DATE_PRESETS = [
    { label: 'Today', value: 'today' },
    { label: 'Yesterday', value: 'yesterday' },
    { label: 'This Week', value: 'this_week' },
    { label: 'Month to Date', value: 'mtd' },
    { label: 'Last Month', value: 'last_month' },
    { label: 'Quarter to Date', value: 'qtd' },
    { label: 'Year to Date', value: 'ytd' },
    { label: 'Last 30 Days', value: 'last_30' },
    { label: 'Last 90 Days', value: 'last_90' },
    { label: 'Custom', value: 'custom' }
];

export default class DynamicKpiDashboard extends LightningElement {
    @track isLoading = true;
    @track initError;

    // Filter state
    @track dateFrom;
    @track dateTo;
    @track datePreset = 'mtd';
    @track userScope = 'self';
    @track selectedCategory = '';
    @track selectedTerritory = '';
    @track selectedMetricKeys = [];

    // Data
    @track allMetrics = [];
    @track categoryOptions = [];
    @track territoryOptions = [];
    @track currentUser;
    @track kpiCards = [];

    // Breakdown chart (by dimension)
    @track selectedChartMetric = '';
    @track selectedGroupBy = 'Status__c';
    @track breakdownChartType = 'bar';
    @track breakdownLabels = [];
    @track breakdownDatasets = [];

    // Trend chart (time series)
    @track selectedTrendMetric = '';
    @track selectedTrendInterval = 'MONTH';
    @track trendChartType = 'line';
    @track trendLabels = [];
    @track trendDatasets = [];

    // Forecast chart
    @track selectedForecastMetric = '';
    @track selectedForecastInterval = 'MONTH';
    @track selectedForecastHorizon = 6;
    @track forecastLabels = [];
    @track forecastDatasets = [];
    @track forecastInsight = '';
    @track forecastStats = null;

    // Saved views (Sprint 6)
    @track savedViews = [];
    @track activeViewId = null;
    @track activeViewName = '';
    @track showSaveModal = false;
    @track saveModalMode = 'new'; // 'new' or 'edit'
    @track isSaving = false;

    // Sprint 7: Drill-down
    @track showDrillDown = false;
    @track drillDownTitle = '';
    @track drillDownRows = [];
    @track drillDownColumns = [];
    @track drillDownRecordCount = 0;
    @track drillDownLoading = false;

    // Sprint 7: Auto-refresh
    @track autoRefreshInterval = 'off';
    _autoRefreshTimer = null;

    // Sprint 8: Insights
    @track insights = [];
    @track showInsights = true;

    // UI state
    @track showFilterPanel = true;
    @track lastUpdated;

    // ── Lifecycle ────────────────────────────────────────────────

    connectedCallback() {
        this.loadInit();
    }

    async loadInit() {
        this.isLoading = true;
        try {
            const data = await getInitData();
            this.allMetrics = data.metrics || [];
            this.currentUser = data.currentUser;
            this.userScope = data.defaultScope || 'self';

            // Build category options
            const cats = [{ label: 'All Categories', value: '' }];
            (data.categories || []).forEach(c => cats.push({ label: c, value: c }));
            this.categoryOptions = cats;

            // Territory options
            this.territoryOptions = [{ label: 'All Territories', value: '' }]
                .concat((data.territories || []).map(t => ({ label: t.name, value: t.id })));

            // Default date range
            if (data.defaultDateRange) {
                this.dateFrom = data.defaultDateRange.from;
                this.dateTo = data.defaultDateRange.to;
            }

            // Default metric selection (first 4 Sales metrics)
            this.selectedMetricKeys = data.defaultMetricKeys || [];
            if (this.selectedMetricKeys.length > 0) {
                this.selectedChartMetric = this.selectedMetricKeys[0];
                this.selectedTrendMetric = this.selectedMetricKeys[0];
                // For the forecast, prefer a metric with Allow_Forecast__c = true
                const forecastable = this.allMetrics.find(m => m.allowForecast);
                this.selectedForecastMetric = forecastable ? forecastable.key : this.selectedMetricKeys[0];
            }

            // Load saved views + apply default if present
            await this.loadSavedViews();
            const defaultView = await getDefaultView();
            if (defaultView && defaultView.Configuration_JSON__c) {
                this.applyViewConfig(defaultView);
            }

            await this.refreshData();
        } catch (error) {
            this.initError = this.reduceError(error);
            this.showToast('Error', 'Failed to load dashboard: ' + this.initError, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async loadSavedViews() {
        try {
            this.savedViews = await getMyViews() || [];
        } catch (e) {
            console.error('Failed to load saved views', e);
            this.savedViews = [];
        }
    }

    applyViewConfig(view) {
        try {
            const config = typeof view.Configuration_JSON__c === 'string'
                ? JSON.parse(view.Configuration_JSON__c)
                : (view.configuration ? JSON.parse(view.configuration) : null);
            if (!config) return;

            if (config.userScope) this.userScope = config.userScope;
            if (config.datePreset) {
                this.datePreset = config.datePreset;
                if (config.datePreset !== 'custom') {
                    this.applyDatePreset(config.datePreset);
                }
            }
            if (config.dateFrom) this.dateFrom = config.dateFrom;
            if (config.dateTo) this.dateTo = config.dateTo;
            if (config.selectedCategory !== undefined) this.selectedCategory = config.selectedCategory;
            if (config.selectedTerritory !== undefined) this.selectedTerritory = config.selectedTerritory;
            if (Array.isArray(config.selectedMetricKeys)) this.selectedMetricKeys = [...config.selectedMetricKeys];
            if (config.selectedChartMetric) this.selectedChartMetric = config.selectedChartMetric;
            if (config.selectedGroupBy) this.selectedGroupBy = config.selectedGroupBy;
            if (config.breakdownChartType) this.breakdownChartType = config.breakdownChartType;
            if (config.selectedTrendMetric) this.selectedTrendMetric = config.selectedTrendMetric;
            if (config.trendChartType) this.trendChartType = config.trendChartType;
            if (config.selectedTrendInterval) this.selectedTrendInterval = config.selectedTrendInterval;
            if (config.selectedForecastMetric) this.selectedForecastMetric = config.selectedForecastMetric;
            if (config.selectedForecastInterval) this.selectedForecastInterval = config.selectedForecastInterval;
            if (config.selectedForecastHorizon) this.selectedForecastHorizon = config.selectedForecastHorizon;

            this.activeViewId = view.Id || view.id;
            this.activeViewName = view.Name || view.name || '';
        } catch (e) {
            console.error('Failed to parse view configuration', e);
        }
    }

    buildCurrentConfig() {
        return {
            userScope: this.userScope,
            datePreset: this.datePreset,
            dateFrom: this.dateFrom,
            dateTo: this.dateTo,
            selectedCategory: this.selectedCategory,
            selectedTerritory: this.selectedTerritory,
            selectedMetricKeys: [...this.selectedMetricKeys],
            selectedChartMetric: this.selectedChartMetric,
            selectedGroupBy: this.selectedGroupBy,
            breakdownChartType: this.breakdownChartType,
            selectedTrendMetric: this.selectedTrendMetric,
            trendChartType: this.trendChartType,
            selectedTrendInterval: this.selectedTrendInterval,
            selectedForecastMetric: this.selectedForecastMetric,
            selectedForecastInterval: this.selectedForecastInterval,
            selectedForecastHorizon: this.selectedForecastHorizon
        };
    }

    // ── Getters ──────────────────────────────────────────────────

    get userScopeOptions() { return USER_SCOPES; }
    get datePresetOptions() { return DATE_PRESETS; }
    get isCustomRange() { return this.datePreset === 'custom'; }

    get filteredMetricOptions() {
        const selected = new Set(this.selectedMetricKeys);
        const metrics = !this.selectedCategory
            ? this.allMetrics
            : this.allMetrics.filter(m => m.category === this.selectedCategory);
        return metrics.map(m => ({
            label: !this.selectedCategory ? (m.category + ' — ' + m.label) : m.label,
            value: m.key,
            isSelected: selected.has(m.key),
            rowClass: 'dkd-metric-row' + (selected.has(m.key) ? ' dkd-metric-row-selected' : ''),
            checkClass: 'dkd-metric-check' + (selected.has(m.key) ? ' dkd-metric-check-active' : '')
        }));
    }

    get chartMetricOptions() {
        return this.allMetrics.map(m => ({ label: m.label, value: m.key }));
    }

    get hasKpiCards() { return this.kpiCards.length > 0; }

    get chartTypeOptions() {
        return [
            { label: 'Bar', value: 'bar' },
            { label: 'Horizontal Bar', value: 'horizontalBar' },
            { label: 'Line', value: 'line' },
            { label: 'Pie', value: 'pie' },
            { label: 'Doughnut', value: 'doughnut' }
        ];
    }

    get groupByOptions() {
        const metric = this.allMetrics.find(m => m.key === this.selectedChartMetric);
        const obj = metric ? metric.sourceObject : '';
        if (obj === 'Sales_Order__c') {
            return [
                { label: 'Status', value: 'Status__c' },
                { label: 'Channel', value: 'Channel__c' },
                { label: 'Territory', value: 'Territory__c' },
                { label: 'Order Type', value: 'Order_Type__c' },
                { label: 'Salesperson', value: 'Salesperson__c' },
                { label: 'Beat', value: 'Beat__c' }
            ];
        }
        if (obj === 'Order_Line_Item__c') {
            return [
                { label: 'Product', value: 'Product__c' },
                { label: 'Product Category', value: 'Product_Category__c' },
                { label: 'UOM', value: 'UOM__c' }
            ];
        }
        if (obj === 'Visit__c') {
            return [
                { label: 'Status', value: 'Visit_Status__c' },
                { label: 'Is Productive', value: 'Is_Productive__c' },
                { label: 'Is Ad-Hoc', value: 'Is_Ad_Hoc__c' },
                { label: 'Beat', value: 'Beat__c' },
                { label: 'Salesperson', value: 'Salesperson__c' }
            ];
        }
        if (obj === 'Collection__c') {
            return [
                { label: 'Payment Mode', value: 'Payment_Mode__c' },
                { label: 'Status', value: 'Status__c' },
                { label: 'Salesperson', value: 'Salesperson__c' }
            ];
        }
        if (obj === 'Account') {
            return [
                { label: 'Type', value: 'Type' },
                { label: 'Channel', value: 'Channel__c' },
                { label: 'Outlet Type', value: 'Outlet_Type__c' },
                { label: 'Territory', value: 'Territory__c' }
            ];
        }
        if (obj === 'Return_Order__c') {
            return [
                { label: 'Status', value: 'Status__c' },
                { label: 'Return Reason', value: 'Return_Reason__c' },
                { label: 'Salesperson', value: 'Salesperson__c' }
            ];
        }
        return [{ label: 'Status', value: 'Status__c' }];
    }

    get trendIntervalOptions() {
        return [
            { label: 'Daily', value: 'DAY' },
            { label: 'Weekly', value: 'WEEK' },
            { label: 'Monthly', value: 'MONTH' },
            { label: 'Quarterly', value: 'QUARTER' },
            { label: 'Yearly', value: 'YEAR' }
        ];
    }

    get breakdownChartFormat() {
        const metric = this.allMetrics.find(m => m.key === this.selectedChartMetric);
        return metric ? metric.format : 'Number';
    }

    get trendChartFormat() {
        const metric = this.allMetrics.find(m => m.key === this.selectedTrendMetric);
        return metric ? metric.format : 'Number';
    }

    get breakdownChartTitle() {
        const metric = this.allMetrics.find(m => m.key === this.selectedChartMetric);
        const label = metric ? metric.label : 'Metric';
        const dim = this.groupByOptions.find(g => g.value === this.selectedGroupBy);
        const dimLabel = dim ? dim.label : this.selectedGroupBy;
        return label + ' by ' + dimLabel;
    }

    get trendChartTitle() {
        const metric = this.allMetrics.find(m => m.key === this.selectedTrendMetric);
        const label = metric ? metric.label : 'Metric';
        const intv = this.trendIntervalOptions.find(i => i.value === this.selectedTrendInterval);
        const intvLabel = intv ? intv.label : 'Time';
        return label + ' — ' + intvLabel + ' Trend';
    }

    // Forecast widget options
    get forecastMetricOptions() {
        return this.allMetrics
            .filter(m => m.allowForecast)
            .map(m => ({ label: m.label, value: m.key }));
    }

    get forecastHorizonOptions() {
        return [
            { label: 'Next 3 Periods', value: 3 },
            { label: 'Next 6 Periods', value: 6 },
            { label: 'Next 12 Periods', value: 12 }
        ];
    }

    get forecastChartFormat() {
        const metric = this.allMetrics.find(m => m.key === this.selectedForecastMetric);
        return metric ? metric.format : 'Number';
    }

    get forecastChartTitle() {
        const metric = this.allMetrics.find(m => m.key === this.selectedForecastMetric);
        const label = metric ? metric.label : 'Metric';
        const intv = this.trendIntervalOptions.find(i => i.value === this.selectedForecastInterval);
        const intvLabel = intv ? intv.label : 'Time';
        return label + ' — ' + intvLabel + ' Forecast';
    }

    get hasForecastData() {
        return this.forecastDatasets && this.forecastDatasets.length > 0;
    }

    get forecastStatsItems() {
        if (!this.forecastStats) return [];
        return [
            {
                key: 'growth',
                label: 'Historical Growth',
                value: this.forecastStats.growthRatePercent + '%',
                positive: this.forecastStats.growthRatePercent >= 0
            },
            {
                key: 'slope',
                label: 'Trend Slope',
                value: this.formatValue(this.forecastStats.slope, this.selectedForecastMetric) + '/period',
                positive: this.forecastStats.slope >= 0
            },
            {
                key: 'confidence',
                label: 'Fit (R²)',
                value: (this.forecastStats.rSquared * 100).toFixed(0) + '%',
                positive: this.forecastStats.rSquared >= 0.5
            }
        ];
    }

    // Saved views (Sprint 6) ─────────────────────────────────────

    get viewPickerOptions() {
        const opts = [{ label: '— Default Layout —', value: '' }];
        (this.savedViews || []).forEach(v => {
            const prefix = v.isDefault ? '★ ' : (v.isShared && !v.isOwn ? '🌐 ' : '');
            opts.push({
                label: prefix + v.name,
                value: v.id
            });
        });
        return opts;
    }

    get hasActiveView() {
        return !!this.activeViewId;
    }

    get activeView() {
        if (!this.activeViewId) return null;
        return this.savedViews.find(v => v.id === this.activeViewId) || null;
    }

    get canEditActiveView() {
        const v = this.activeView;
        return v && v.isOwn;
    }

    get isActiveViewDefault() {
        const v = this.activeView;
        return v && v.isDefault === true;
    }

    get setDefaultButtonLabel() {
        return this.isActiveViewDefault ? 'Unset Default' : 'Set as Default';
    }

    get isEditSaveMode() {
        return this.saveModalMode === 'edit';
    }

    get activeFilterChips() {
        const chips = [];
        chips.push({ key: 'scope', label: 'Scope: ' + this.scopeLabel });
        chips.push({ key: 'range', label: 'Period: ' + this.dateRangeLabel });
        if (this.selectedCategory) {
            chips.push({ key: 'cat', label: 'Category: ' + this.selectedCategory });
        }
        if (this.selectedTerritory) {
            const t = this.territoryOptions.find(o => o.value === this.selectedTerritory);
            chips.push({ key: 'terr', label: 'Territory: ' + (t ? t.label : this.selectedTerritory) });
        }
        return chips;
    }

    get scopeLabel() {
        const s = USER_SCOPES.find(o => o.value === this.userScope);
        return s ? s.label : this.userScope;
    }

    get dateRangeLabel() {
        if (!this.dateFrom || !this.dateTo) return 'Not set';
        return this.formatDate(this.dateFrom) + ' → ' + this.formatDate(this.dateTo);
    }

    get lastUpdatedLabel() {
        if (!this.lastUpdated) return '';
        return 'Last updated: ' + this.lastUpdated;
    }

    get filterPanelClass() {
        return this.showFilterPanel ? 'dkd-filter-panel dkd-filter-panel-open' : 'dkd-filter-panel';
    }

    get bodyClass() {
        return this.showFilterPanel ? 'dkd-body' : 'dkd-body dkd-body-collapsed';
    }

    get toggleFilterIcon() {
        return this.showFilterPanel ? 'utility:chevronleft' : 'utility:filterList';
    }

    // ── Filter handlers ──────────────────────────────────────────

    handleDatePresetChange(event) {
        this.datePreset = event.detail.value;
        this.applyDatePreset(this.datePreset);
    }

    applyDatePreset(preset) {
        const today = new Date();
        const y = today.getFullYear();
        const m = today.getMonth();
        const d = today.getDate();

        switch (preset) {
            case 'today':
                this.dateFrom = this.toISODate(new Date(y, m, d));
                this.dateTo = this.toISODate(new Date(y, m, d));
                break;
            case 'yesterday':
                this.dateFrom = this.toISODate(new Date(y, m, d - 1));
                this.dateTo = this.toISODate(new Date(y, m, d - 1));
                break;
            case 'this_week': {
                const day = today.getDay();
                const monday = new Date(y, m, d - (day === 0 ? 6 : day - 1));
                this.dateFrom = this.toISODate(monday);
                this.dateTo = this.toISODate(new Date(y, m, d));
                break;
            }
            case 'mtd':
                this.dateFrom = this.toISODate(new Date(y, m, 1));
                this.dateTo = this.toISODate(new Date(y, m, d));
                break;
            case 'last_month':
                this.dateFrom = this.toISODate(new Date(y, m - 1, 1));
                this.dateTo = this.toISODate(new Date(y, m, 0));
                break;
            case 'qtd': {
                const q = Math.floor(m / 3) * 3;
                this.dateFrom = this.toISODate(new Date(y, q, 1));
                this.dateTo = this.toISODate(new Date(y, m, d));
                break;
            }
            case 'ytd':
                this.dateFrom = this.toISODate(new Date(y, 0, 1));
                this.dateTo = this.toISODate(new Date(y, m, d));
                break;
            case 'last_30':
                this.dateFrom = this.toISODate(new Date(y, m, d - 30));
                this.dateTo = this.toISODate(new Date(y, m, d));
                break;
            case 'last_90':
                this.dateFrom = this.toISODate(new Date(y, m, d - 90));
                this.dateTo = this.toISODate(new Date(y, m, d));
                break;
            // custom: leave as-is
        }
    }

    handleDateFromChange(event) { this.dateFrom = event.detail.value; }
    handleDateToChange(event) { this.dateTo = event.detail.value; }

    handleScopeChange(event) { this.userScope = event.detail.value; }
    handleCategoryChange(event) { this.selectedCategory = event.detail.value; }
    handleTerritoryChange(event) { this.selectedTerritory = event.detail.value; }

    handleSelectAllMetrics() {
        this.selectedMetricKeys = this.filteredMetricOptions.map(m => m.value);
    }

    handleClearMetrics() {
        this.selectedMetricKeys = [];
    }

    buildFiltersJson() {
        const filters = [];
        let id = 1;
        if (this.selectedTerritory) {
            filters.push({ id: id++, field: 'Territory__c', operator: 'equals', value: this.selectedTerritory, type: 'STRING' });
        }
        if (filters.length === 0) return null;
        return JSON.stringify({ filters });
    }

    validateDateRange() {
        if (!this.dateFrom || !this.dateTo) return true;
        return this.dateFrom <= this.dateTo;
    }

    handleMetricToggle(event) {
        const key = event.currentTarget.dataset.metricKey;
        if (!key) return;
        const idx = this.selectedMetricKeys.indexOf(key);
        if (idx >= 0) {
            this.selectedMetricKeys = this.selectedMetricKeys.filter(k => k !== key);
        } else {
            this.selectedMetricKeys = [...this.selectedMetricKeys, key];
        }
    }

    handleChartMetricChange(event) {
        this.selectedChartMetric = event.detail.value;
        this.loadBreakdownChart();
    }

    handleGroupByChange(event) {
        this.selectedGroupBy = event.detail.value;
        this.loadBreakdownChart();
    }

    handleChartTypeChange(event) {
        this.breakdownChartType = event.detail.value;
    }

    handleTrendMetricChange(event) {
        this.selectedTrendMetric = event.detail.value;
        this.loadTrendChart();
    }

    handleTrendChartTypeChange(event) {
        this.trendChartType = event.detail.value;
    }

    handleTrendIntervalChange(event) {
        this.selectedTrendInterval = event.detail.value;
        this.loadTrendChart();
    }

    handleForecastMetricChange(event) {
        this.selectedForecastMetric = event.detail.value;
        this.loadForecastChart();
    }

    handleForecastIntervalChange(event) {
        this.selectedForecastInterval = event.detail.value;
        this.loadForecastChart();
    }

    handleForecastHorizonChange(event) {
        this.selectedForecastHorizon = parseInt(event.detail.value, 10);
        this.loadForecastChart();
    }

    handleToggleFilterPanel() {
        this.showFilterPanel = !this.showFilterPanel;
    }

    handleApplyFilters() { this.refreshData(); }

    handleResetFilters() {
        this.userScope = 'self';
        this.selectedCategory = '';
        this.selectedTerritory = '';
        this.datePreset = 'mtd';
        this.applyDatePreset('mtd');
        this.refreshData();
    }

    handleRefresh() { this.refreshData(); }

    // ── Auto-Refresh (Sprint 7) ──────────────────────────────────

    get autoRefreshOptions() {
        return [
            { label: 'Off', value: 'off' },
            { label: 'Every 30 seconds', value: '30' },
            { label: 'Every 1 minute', value: '60' },
            { label: 'Every 5 minutes', value: '300' }
        ];
    }

    get autoRefreshLabel() {
        if (this.autoRefreshInterval === 'off') return 'Auto-refresh: Off';
        const s = parseInt(this.autoRefreshInterval, 10);
        if (s >= 60) return 'Auto-refresh: every ' + (s / 60) + ' min';
        return 'Auto-refresh: every ' + s + 's';
    }

    handleAutoRefreshChange(event) {
        this.autoRefreshInterval = event.detail.value;
        this._restartAutoRefresh();
    }

    _restartAutoRefresh() {
        if (this._autoRefreshTimer) {
            clearInterval(this._autoRefreshTimer);
            this._autoRefreshTimer = null;
        }
        if (this.autoRefreshInterval === 'off') return;
        const seconds = parseInt(this.autoRefreshInterval, 10);
        if (isNaN(seconds) || seconds <= 0) return;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._autoRefreshTimer = setInterval(() => {
            if (!this.isLoading) this.refreshData();
        }, seconds * 1000);
    }

    disconnectedCallback() {
        if (this._autoRefreshTimer) {
            clearInterval(this._autoRefreshTimer);
            this._autoRefreshTimer = null;
        }
        if (this._revokeBlobTimers) {
            this._revokeBlobTimers.forEach(id => clearTimeout(id));
            this._revokeBlobTimers = [];
        }
    }

    // ── Drill-Down (Sprint 7) ────────────────────────────────────

    async handleChartClick(event) {
        const groupKey = event.currentTarget.dataset.groupKey;
        const label = event.currentTarget.dataset.label;
        if (!this.selectedChartMetric) return;
        await this._openDrillDown(
            this.selectedChartMetric, this.selectedGroupBy, groupKey, label
        );
    }

    async handleKpiCardClick(event) {
        const metricKey = event.currentTarget.dataset.metricKey;
        if (!metricKey) return;
        await this._openDrillDown(metricKey, null, null, null);
    }

    async _openDrillDown(metricKey, groupBy, groupKey, groupLabel) {
        this.drillDownLoading = true;
        this.showDrillDown = true;
        const metric = this.allMetrics.find(m => m.key === metricKey);
        const metricLabel = metric ? metric.label : metricKey;
        this.drillDownTitle = groupLabel
            ? metricLabel + ' — ' + groupLabel
            : metricLabel + ' — All records';
        try {
            const result = await drillDown({
                metricKey: metricKey,
                filtersJson: this.buildFiltersJson(),
                groupBy: groupBy || null,
                groupKey: groupKey || null,
                dateFrom: this.dateFrom,
                dateTo: this.dateTo,
                userScope: this.userScope,
                recordLimit: 200
            });
            this.drillDownColumns = (result.columns || []).map(c => ({
                field: c.field,
                label: c.label
            }));
            this.drillDownRows = (result.rows || []).map(r => {
                const cells = this.drillDownColumns.map(c => ({
                    field: c.field,
                    value: this._formatCell(r[c.field])
                }));
                return { id: r._id, cells };
            });
            this.drillDownRecordCount = result.recordCount || 0;
        } catch (error) {
            this.showToast('Drill-down failed', this.reduceError(error), 'error');
            this.drillDownRows = [];
            this.drillDownColumns = [];
            this.drillDownRecordCount = 0;
        } finally {
            this.drillDownLoading = false;
        }
    }

    handleCloseDrillDown() {
        this.showDrillDown = false;
        this.drillDownRows = [];
        this.drillDownColumns = [];
    }

    _formatCell(value) {
        if (value === null || value === undefined) return '';
        if (typeof value === 'number') {
            return new Intl.NumberFormat('en-IN').format(value);
        }
        if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}/.test(value)) {
            // ISO date
            try {
                return new Date(value).toLocaleDateString('en-IN', {
                    day: '2-digit', month: 'short', year: 'numeric'
                });
            } catch (e) { return value; }
        }
        return String(value);
    }

    // ── Export (Sprint 7) ────────────────────────────────────────

    handleExportKpis() {
        console.log('[DKD-CSV] handleExportKpis called');
        console.log('[DKD-CSV] kpiCards count:', this.kpiCards ? this.kpiCards.length : 0);
        if (!this.kpiCards || !this.kpiCards.length) {
            this.showToast('Nothing to export', 'Add some KPI cards first.', 'warning');
            return;
        }
        const header = ['Category', 'Metric', 'Current Value', 'Previous Value', 'Change %'];
        const rows = this.kpiCards.map(c => [
            c.category,
            c.label,
            c.value,
            c.prevValue,
            c.hasComparison ? (c.delta >= 0 ? '+' : '-') + c.deltaPct : ''
        ]);
        console.log('[DKD-CSV] rows built:', rows.length);
        this._downloadCsv('kpi-dashboard-' + this._timestamp() + '.csv', header, rows);
    }

    handleExportDrillDown() {
        if (!this.drillDownRows.length) return;
        const header = this.drillDownColumns.map(c => c.label);
        const rows = this.drillDownRows.map(r => r.cells.map(c => c.value));
        this._downloadCsv('drill-down-' + this._timestamp() + '.csv', header, rows);
    }

    _downloadCsv(filename, header, rows) {
        console.log('[DKD-CSV] _downloadCsv called, filename:', filename);
        try {
            const esc = v => {
                if (v === null || v === undefined) return '';
                const s = String(v).replace(/"/g, '""');
                return /[",\n]/.test(s) ? '"' + s + '"' : s;
            };
            const lines = [header.map(esc).join(',')];
            rows.forEach(r => lines.push(r.map(esc).join(',')));
            const csvContent = '\uFEFF' + lines.join('\n');
            console.log('[DKD-CSV] CSV built, length:', csvContent.length);

            const anchor = this.template.querySelector('.dkd-download-anchor');
            console.log('[DKD-CSV] template anchor found:', !!anchor);

            if (anchor) {
                const blob = new Blob([csvContent], { type: 'text/plain' });
                const url = URL.createObjectURL(blob);
                console.log('[DKD-CSV] blob URL created:', url);
                anchor.href = url;
                anchor.download = filename;
                anchor.style.display = '';
                anchor.click();
                console.log('[DKD-CSV] anchor clicked');
                anchor.style.display = 'none';
                if (!this._revokeBlobTimers) this._revokeBlobTimers = [];
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                const revokeId = setTimeout(() => {
                    URL.revokeObjectURL(url);
                    if (this._revokeBlobTimers) {
                        this._revokeBlobTimers = this._revokeBlobTimers.filter(t => t !== revokeId);
                    }
                }, 1000);
                this._revokeBlobTimers.push(revokeId);
                this.showToast('Exported', filename, 'success');
                return;
            }

            console.log('[DKD-CSV] No anchor found, trying fallback');
            const encoded = 'data:text/csv;charset=utf-8,' + encodeURIComponent(csvContent);
            window.open(encoded, '_blank');
            this.showToast('Exported', filename, 'success');
        } catch (err) {
            console.error('[DKD-CSV] Error in _downloadCsv:', err);
            this.showToast('Export Failed', String(err.message || err), 'error');
        }
    }

    handlePrintDashboard() {
        // Trigger browser print — CSS @media print controls the layout
        window.print();
    }

    _timestamp() {
        const d = new Date();
        const pad = n => String(n).padStart(2, '0');
        return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
               '-' + pad(d.getHours()) + pad(d.getMinutes());
    }

    // ── Insights (Sprint 8) ──────────────────────────────────────

    get hasInsights() { return this.insights && this.insights.length > 0; }

    get insightCards() {
        return (this.insights || []).map(i => ({
            ...i,
            cardStyle: 'border-left-color: ' + (i.color || '#0176d3') + ';',
            iconStyle: 'background: ' + (i.color || '#0176d3') + '1a; color: ' + (i.color || '#0176d3') + ';'
        }));
    }

    handleToggleInsights() {
        this.showInsights = !this.showInsights;
    }

    async loadInsights() {
        if (!this.selectedMetricKeys || !this.selectedMetricKeys.length) {
            this.insights = [];
            return;
        }
        try {
            const result = await getInsights({
                metricKeys: this.selectedMetricKeys,
                filtersJson: this.buildFiltersJson(),
                dateFrom: this.dateFrom,
                dateTo: this.dateTo,
                userScope: this.userScope
            });
            this.insights = (result && result.insights) ? result.insights : [];
        } catch (error) {
            console.error('Insights load failed', error);
            this.insights = [];
        }
    }

    // ── Saved View Handlers (Sprint 6) ──────────────────────────

    async handleViewSelect(event) {
        const viewId = event.detail.value;
        if (!viewId) {
            // "Default Layout" selected — clear the active view
            this.activeViewId = null;
            this.activeViewName = '';
            return;
        }
        const view = this.savedViews.find(v => v.id === viewId);
        if (!view) return;
        this.applyViewConfig({
            Id: view.id,
            Name: view.name,
            configuration: view.configuration
        });
        await this.refreshData();
        this.showToast('View Loaded', 'Switched to: ' + view.name, 'success');
    }

    handleOpenSaveModal() {
        this.saveModalMode = 'new';
        this.showSaveModal = true;
    }

    handleOpenEditModal() {
        if (!this.canEditActiveView) return;
        this.saveModalMode = 'edit';
        this.showSaveModal = true;
    }

    handleCancelSave() {
        this.showSaveModal = false;
        this.isSaving = false;
    }

    async handleSaveView(event) {
        const { name, description, isShared } = event.detail;
        const configJson = JSON.stringify(this.buildCurrentConfig());
        this.isSaving = true;
        try {
            let saved;
            if (this.saveModalMode === 'edit' && this.activeViewId) {
                saved = await updateView({
                    viewId: this.activeViewId,
                    name: name,
                    description: description,
                    configurationJson: configJson,
                    isShared: isShared,
                    icon: null
                });
                this.showToast('View Updated', name + ' has been updated.', 'success');
            } else {
                saved = await createView({
                    name: name,
                    description: description,
                    configurationJson: configJson,
                    isShared: isShared,
                    icon: null
                });
                this.activeViewId = saved.Id;
                this.activeViewName = name;
                this.showToast('View Saved', name + ' saved to your views.', 'success');
            }
            this.showSaveModal = false;
            await this.loadSavedViews();
        } catch (error) {
            this.showToast('Save Failed', this.reduceError(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleDeleteView() {
        if (!this.canEditActiveView || !this.activeViewId) return;
        // eslint-disable-next-line no-alert
        if (!confirm('Delete "' + this.activeViewName + '"? This cannot be undone.')) {
            return;
        }
        try {
            await deleteView({ viewId: this.activeViewId });
            this.showToast('View Deleted', this.activeViewName + ' has been deleted.', 'success');
            this.activeViewId = null;
            this.activeViewName = '';
            await this.loadSavedViews();
        } catch (error) {
            this.showToast('Delete Failed', this.reduceError(error), 'error');
        }
    }

    async handleToggleDefault() {
        if (!this.canEditActiveView || !this.activeViewId) return;
        try {
            if (this.isActiveViewDefault) {
                await clearDefaultView();
                this.showToast('Default Cleared', 'No default view set.', 'success');
            } else {
                await setDefaultView({ viewId: this.activeViewId });
                this.showToast('Default Set', this.activeViewName + ' is now your default view.', 'success');
            }
            await this.loadSavedViews();
        } catch (error) {
            this.showToast('Update Failed', this.reduceError(error), 'error');
        }
    }

    // ── Data loading ─────────────────────────────────────────────

    async refreshData() {
        if (!this.selectedMetricKeys.length) {
            this.kpiCards = [];
            this.isLoading = false;
            return;
        }
        if (!this.validateDateRange()) {
            this.showToast('Invalid Date Range', 'From date must be before To date.', 'error');
            return;
        }
        this.isLoading = true;
        let current = {};
        let previous = {};
        const fJson = this.buildFiltersJson();
        try {
            const kpiResults = await Promise.allSettled([
                getKpiValues({
                    metricKeys: this.selectedMetricKeys,
                    filtersJson: fJson,
                    dateFrom: this.dateFrom,
                    dateTo: this.dateTo,
                    userScope: this.userScope
                }),
                getPreviousPeriodValues({
                    metricKeys: this.selectedMetricKeys,
                    filtersJson: fJson,
                    dateFrom: this.dateFrom,
                    dateTo: this.dateTo,
                    userScope: this.userScope
                })
            ]);
            current = kpiResults[0].status === 'fulfilled' ? kpiResults[0].value : {};
            previous = kpiResults[1].status === 'fulfilled' ? kpiResults[1].value : {};
        } catch (e) {
            console.error('KPI load error', e);
        }

        this.kpiCards = this.buildKpiCards(current || {}, previous || {});
        this.lastUpdated = new Date().toLocaleTimeString();
        this.isLoading = false;

        // Fire-and-forget: load secondary widgets AFTER spinner stops.
        // Each has its own try/catch so failures are silent.
        if (this.selectedChartMetric) {
            this.loadBreakdownChart().catch(e => console.error('Breakdown error', e));
        }
        if (this.selectedTrendMetric) {
            this.loadTrendChart().catch(e => console.error('Trend error', e));
        }
        if (this.selectedForecastMetric) {
            this.loadForecastChart().catch(e => console.error('Forecast error', e));
        }
        this.loadInsights().catch(e => console.error('Insights error', e));
    }

    async loadBreakdownChart() {
        if (!this.selectedChartMetric) return;
        try {
            const rows = await getMetricData({
                metricKey: this.selectedChartMetric,
                filtersJson: this.buildFiltersJson(),
                groupBy: this.selectedGroupBy,
                dateFrom: this.dateFrom,
                dateTo: this.dateTo,
                userScope: this.userScope
            });
            const metric = this.allMetrics.find(m => m.key === this.selectedChartMetric);
            const color = metric ? metric.color : '#0176d3';
            const labels = rows.map(r => r.label || '(blank)');
            const data = rows.map(r => Number(r.value) || 0);
            this.breakdownLabels = labels;
            this.breakdownDatasets = [{
                label: metric ? metric.label : 'Value',
                data: data,
                color: color
            }];
        } catch (error) {
            console.error('Breakdown chart load failed', error);
            this.breakdownLabels = [];
            this.breakdownDatasets = [];
        }
    }

    async loadTrendChart() {
        if (!this.selectedTrendMetric) return;
        try {
            // Use a longer window for trends so there's enough data to see the pattern
            const trendFrom = this.extendedTrendStart();
            const rows = await getTimeSeries({
                metricKey: this.selectedTrendMetric,
                filtersJson: this.buildFiltersJson(),
                dateFrom: trendFrom,
                dateTo: this.dateTo,
                interval: this.selectedTrendInterval,
                userScope: this.userScope
            });
            const metric = this.allMetrics.find(m => m.key === this.selectedTrendMetric);
            const color = metric ? metric.color : '#0176d3';
            const labels = rows.map(r => r.label || '');
            const data = rows.map(r => Number(r.value) || 0);
            this.trendLabels = labels;
            this.trendDatasets = [{
                label: metric ? metric.label : 'Value',
                data: data,
                color: color
            }];
        } catch (error) {
            console.error('Trend chart load failed', error);
            this.trendLabels = [];
            this.trendDatasets = [];
        }
    }

    extendedTrendStart() {
        return this.extendedWindowStart(this.selectedTrendInterval);
    }

    extendedWindowStart(interval) {
        // For trends/forecasts, extend the window backwards to provide enough history
        if (!this.dateTo) return this.dateFrom;
        const end = new Date(this.dateTo);
        let start;
        switch (interval) {
            case 'DAY':
                start = new Date(end.getFullYear(), end.getMonth(), end.getDate() - 30);
                break;
            case 'WEEK':
                start = new Date(end.getFullYear(), end.getMonth(), end.getDate() - 84);
                break;
            case 'MONTH':
                start = new Date(end.getFullYear(), end.getMonth() - 11, 1);
                break;
            case 'QUARTER':
                start = new Date(end.getFullYear() - 2, 0, 1);
                break;
            case 'YEAR':
                start = new Date(end.getFullYear() - 4, 0, 1);
                break;
            default:
                start = new Date(end.getFullYear(), end.getMonth() - 5, 1);
        }
        return this.toISODate(start);
    }

    async loadForecastChart() {
        if (!this.selectedForecastMetric) return;
        try {
            const fromDate = this.extendedWindowStart(this.selectedForecastInterval);
            const result = await getForecast({
                metricKey: this.selectedForecastMetric,
                filtersJson: this.buildFiltersJson(),
                dateFrom: fromDate,
                dateTo: this.dateTo,
                interval: this.selectedForecastInterval,
                forecastPeriods: this.selectedForecastHorizon,
                userScope: this.userScope
            });

            const metric = this.allMetrics.find(m => m.key === this.selectedForecastMetric);
            const color = metric ? metric.color : '#0176d3';

            const historical = result.historical || [];
            const forecast = result.forecast || [];

            // Build combined X-axis labels (historical + forecast)
            const labels = [
                ...historical.map(h => h.label || ''),
                ...forecast.map(f => f.label || '')
            ];

            // Historical dataset: actual values, null for forecast positions
            const histValues = historical.map(h => Number(h.value) || 0);
            const histData = [...histValues, ...forecast.map(() => null)];

            // Forecast dataset: null for historical positions, then projected values
            // Include one transition point (last historical value) so the line connects
            const fcData = historical.map(() => null);
            if (histValues.length > 0 && forecast.length > 0) {
                // Replace the last historical null with the actual last value to connect lines
                fcData[fcData.length - 1] = histValues[histValues.length - 1];
            }
            forecast.forEach(f => fcData.push(Number(f.value) || 0));

            // Upper confidence band
            const upperData = historical.map(() => null);
            if (histValues.length > 0 && forecast.length > 0) {
                upperData[upperData.length - 1] = histValues[histValues.length - 1];
            }
            forecast.forEach(f => upperData.push(Number(f.upper) || 0));

            // Lower confidence band
            const lowerData = historical.map(() => null);
            if (histValues.length > 0 && forecast.length > 0) {
                lowerData[lowerData.length - 1] = histValues[histValues.length - 1];
            }
            forecast.forEach(f => lowerData.push(Number(f.lower) || 0));

            this.forecastLabels = labels;
            this.forecastDatasets = [
                {
                    label: 'Upper Bound',
                    data: upperData,
                    color: color,
                    bandUpper: true
                },
                {
                    label: 'Lower Bound',
                    data: lowerData,
                    color: color,
                    bandLower: true
                },
                {
                    label: 'Historical',
                    data: histData,
                    color: color
                },
                {
                    label: 'Forecast',
                    data: fcData,
                    color: color,
                    dashed: true,
                    fill: false
                }
            ];

            this.forecastInsight = result.insight || '';
            this.forecastStats = {
                slope: Number(result.slope) || 0,
                rSquared: Number(result.rSquared) || 0,
                growthRatePercent: Number(result.growthRatePercent) || 0,
                standardError: Number(result.standardError) || 0
            };
        } catch (error) {
            console.error('Forecast load failed', error);
            this.forecastLabels = [];
            this.forecastDatasets = [];
            this.forecastInsight = 'Unable to generate forecast: ' + this.reduceError(error);
            this.forecastStats = null;
        }
    }

    // ── KPI card builder ─────────────────────────────────────────

    buildKpiCards(current, previous) {
        const cards = [];
        for (const key of this.selectedMetricKeys) {
            const metric = this.allMetrics.find(m => m.key === key);
            if (!metric) continue;

            const curVal = Number(current[key]) || 0;
            const prevVal = Number(previous[key]) || 0;
            const delta = curVal - prevVal;
            let deltaPct = 0;
            if (prevVal !== 0) {
                deltaPct = (delta / Math.abs(prevVal)) * 100;
            } else if (curVal !== 0) {
                deltaPct = 100;
            }

            const trendClass = delta > 0
                ? 'dkd-trend dkd-trend-up'
                : (delta < 0 ? 'dkd-trend dkd-trend-down' : 'dkd-trend dkd-trend-flat');
            const trendIcon = delta > 0
                ? 'utility:arrowup'
                : (delta < 0 ? 'utility:arrowdown' : 'utility:dash');

            cards.push({
                key,
                label: metric.label,
                category: metric.category,
                icon: metric.icon || 'utility:chart',
                color: metric.color || '#0176d3',
                cardStyle: 'border-left-color: ' + (metric.color || '#0176d3') + ';',
                iconStyle: 'background: ' + (metric.color || '#0176d3') + '1a; color: ' + (metric.color || '#0176d3') + ';',
                value: curVal,
                formattedValue: this.formatValue(curVal, key),
                prevValue: prevVal,
                formattedPrevValue: this.formatValue(prevVal, key),
                delta,
                deltaPct: Math.abs(deltaPct).toFixed(1) + '%',
                trendClass,
                trendIcon,
                hasComparison: prevVal !== 0
            });
        }
        return cards;
    }

    // ── Formatting ───────────────────────────────────────────────

    formatValue(value, metricKey) {
        const metric = this.allMetrics.find(m => m.key === metricKey);
        const format = metric ? metric.format : 'Number';
        const num = Number(value) || 0;
        if (format === 'Currency') {
            return new Intl.NumberFormat('en-IN', {
                style: 'currency', currency: 'INR', maximumFractionDigits: 0
            }).format(num);
        }
        if (format === 'Percent') {
            return num.toFixed(1) + '%';
        }
        if (format === 'Duration') {
            return Math.round(num) + ' min';
        }
        return new Intl.NumberFormat('en-IN').format(Math.round(num));
    }

    formatDate(isoDate) {
        if (!isoDate) return '';
        const d = new Date(isoDate);
        return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
    }

    toISODate(date) {
        const y = date.getFullYear();
        const m = String(date.getMonth() + 1).padStart(2, '0');
        const d = String(date.getDate()).padStart(2, '0');
        return `${y}-${m}-${d}`;
    }

    // ── Utilities ────────────────────────────────────────────────

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceError(error) {
        if (!error) return 'Unknown error';
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return JSON.stringify(error);
    }
}