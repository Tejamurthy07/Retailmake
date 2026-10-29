import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ChartJs from '@salesforce/resourceUrl/ChartJs';
import getDashboardData from '@salesforce/apex/TAM_KpiDashboard_Controller.getDashboardData';
import getComparisonKpis from '@salesforce/apex/TAM_KpiDashboard_Controller.getComparisonKpis';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const COLORS = ['#0176d3', '#2e844a', '#7e5cef', '#e65100', '#c23934', '#00796b', '#1565c0', '#ad1457'];
const CIRC = 2 * Math.PI * 34;

export default class TamKpiDashboard extends LightningElement {

    @track isLoading = false;
    chartJsLoaded = false;

    // Controls
    @track periodOptions = [];
    selectedPeriod = '';
    @track selectedView = 'self';

    // Comparison
    @track comparisonPeriod = '';
    @track comparisonKpisData = [];

    // Chart type selectors
    @track trendChartType = 'line';
    @track criteriaChartType = 'bar';

    // KPI filter
    @track selectedKpiNames = new Set();

    // Data
    @track kpis = [];
    @track grandTarget = 0;
    @track grandActual = 0;
    @track grandPercent = 0;
    @track incentiveSummary = {};
    @track team = [];
    @track trend = [];
    @track leaderboard = [];

    // Chart instances
    trendChart = null;
    incentiveChart = null;
    criteriaChart = null;

    connectedCallback() {
        loadScript(this, ChartJs)
            .then(() => { this.chartJsLoaded = true; })
            .catch(error => {
                this.chartJsLoaded = false;
                // eslint-disable-next-line no-console
                console.error('Chart.js failed to load', error);
                this.showToast('Charts Unavailable', 'Charts could not be loaded. Try refreshing the page.', 'warning');
            });
        this.loadData();
    }

    // ===== DATA LOADING =====
    loadData() {
        this.isLoading = true;
        getDashboardData({ periodId: this.selectedPeriod, viewType: this.selectedView })
            .then(result => {
                this.periodOptions = (result.periods || []).map(p => ({ label: p.Name, value: p.Id }));
                if (!this.selectedPeriod) this.selectedPeriod = result.currentPeriodId || '';

                this.kpis = result.kpis || [];
                this.grandTarget = result.grandTarget || 0;
                this.grandActual = result.grandActual || 0;
                this.grandPercent = result.grandPercent || 0;
                this.incentiveSummary = result.incentiveSummary || {};
                this.team = result.team || [];
                this.trend = result.trend || [];
                this.processLeaderboard(result.leaderboard || []);

                if (this.selectedKpiNames.size === 0) {
                    this.selectedKpiNames = new Set(this.kpis.map(k => k.name));
                }

                this.loadComparisonIfNeeded();

                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.renderCharts(); }, 300);
            })
            .catch(e => { this.showToast('Error', e?.body?.message || 'Failed to load', 'error'); })
            .finally(() => { this.isLoading = false; });
    }

    loadComparisonIfNeeded() {
        if (!this.comparisonPeriod) {
            this.comparisonKpisData = [];
            return;
        }
        getComparisonKpis({ periodId: this.comparisonPeriod, viewType: this.selectedView })
            .then(data => {
                this.comparisonKpisData = data || [];
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.renderCriteriaChart(); }, 100);
            })
            .catch(() => { this.comparisonKpisData = []; });
    }

    processLeaderboard(data) {
        this.leaderboard = (data || []).map((row, idx) => {
            const pct = Number(row.percent) || 0;
            return {
                ...row,
                rank: idx + 1,
                percentDisplay: pct.toFixed(1),
                actualDisplay: this.fmt(row.actual),
                progressWidth: `width: ${Math.min(pct, 100)}%`,
                rankClass: idx === 0 ? 'kd-rank-gold' : idx === 1 ? 'kd-rank-silver' : idx === 2 ? 'kd-rank-bronze' : 'kd-rank-default',
                percentColorClass: pct >= 100 ? 'kd-leader-pct kd-pct-green' : pct >= 70 ? 'kd-leader-pct kd-pct-amber' : 'kd-leader-pct kd-pct-red'
            };
        });
    }

    // ===== VIEW / PERIOD CONTROLS =====
    get viewOptions() {
        return [
            { value: 'self', label: 'My KPIs', pillClass: 'kd-pill' + (this.selectedView === 'self' ? ' kd-pill-active' : '') },
            { value: 'team', label: 'Team', pillClass: 'kd-pill' + (this.selectedView === 'team' ? ' kd-pill-active' : '') },
            { value: 'org', label: 'Organization', pillClass: 'kd-pill' + (this.selectedView === 'org' ? ' kd-pill-active' : '') }
        ];
    }

    get comparisonPeriodOptions() {
        const opts = [{ label: '-- No Comparison --', value: '' }];
        this.periodOptions.forEach(p => {
            if (p.value !== this.selectedPeriod) {
                opts.push({ label: p.label, value: p.value });
            }
        });
        return opts;
    }

    handleViewChange(event) {
        this.selectedView = event.currentTarget.dataset.value;
        this.loadData();
    }

    handlePeriodChange(event) {
        this.selectedPeriod = event.target.value;
        if (this.comparisonPeriod === this.selectedPeriod) this.comparisonPeriod = '';
        this.loadData();
    }

    handleComparisonChange(event) {
        this.comparisonPeriod = event.target.value;
        this.loadComparisonIfNeeded();
    }

    handleRefresh() { this.loadData(); }

    // ===== KPI FILTER =====
    get kpiFilterOptions() {
        return this.kpis.map(k => ({
            name: k.name,
            pillClass: 'kd-filter-pill' + (this.selectedKpiNames.has(k.name) ? ' kd-filter-pill-active' : '')
        }));
    }

    get allPillClass() {
        return 'kd-filter-pill' + (this.selectedKpiNames.size === this.kpis.length ? ' kd-filter-pill-active' : '');
    }

    handleToggleAll() {
        if (this.selectedKpiNames.size === this.kpis.length) {
            this.selectedKpiNames = new Set();
        } else {
            this.selectedKpiNames = new Set(this.kpis.map(k => k.name));
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.renderCriteriaChart(); }, 50);
    }

    handleToggleKpi(event) {
        const name = event.currentTarget.dataset.name;
        const updated = new Set(this.selectedKpiNames);
        if (updated.has(name)) {
            updated.delete(name);
        } else {
            updated.add(name);
        }
        this.selectedKpiNames = updated;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.renderCriteriaChart(); }, 50);
    }

    get filteredKpis() {
        if (this.selectedKpiNames.size === 0) return this.kpis;
        return this.kpis.filter(k => this.selectedKpiNames.has(k.name));
    }

    // ===== CHART TYPE CONTROLS =====
    handleTrendTypeChange(event) {
        this.trendChartType = event.currentTarget.dataset.type;
        this.renderTrendChart();
    }

    handleCriteriaTypeChange(event) {
        this.criteriaChartType = event.currentTarget.dataset.type;
        this.renderCriteriaChart();
    }

    get trendLineVariant() { return this.trendChartType === 'line' ? 'brand' : 'border'; }
    get trendBarVariant() { return this.trendChartType === 'bar' ? 'brand' : 'border'; }
    get criteriaBarVariant() { return this.criteriaChartType === 'bar' ? 'brand' : 'border'; }
    get criteriaRadarVariant() { return this.criteriaChartType === 'radar' ? 'brand' : 'border'; }
    get criteriaDoughnutVariant() { return this.criteriaChartType === 'doughnut' ? 'brand' : 'border'; }

    get criteriaChartTitle() {
        if (this.criteriaChartType === 'radar') return 'KPI Radar';
        if (this.criteriaChartType === 'doughnut') return 'KPI Distribution';
        return 'Achievement by Criteria';
    }

    // ===== COMPUTED GETTERS =====
    get hasKpis() { return this.kpis.length > 0; }
    get hasFilteredKpis() { return this.filteredKpis.length > 0; }
    get hasTeam() { return this.team.length > 0; }
    get hasLeaderboard() { return this.leaderboard.length > 0; }
    get showTeam() { return this.selectedView !== 'self'; }

    get grandPercentDisplay() { return Number(this.grandPercent).toFixed(1); }
    get grandTargetDisplay() { return this.fmt(this.grandTarget); }
    get grandActualDisplay() { return this.fmt(this.grandActual); }
    get totalIncentiveDisplay() { return this.fmt(this.incentiveSummary.total_amount || 0); }

    get computedFilteredKpis() {
        return this.filteredKpis.map((k, i) => {
            const pct = Number(k.percent) || 0;
            return {
                key: k.name || String(i),
                name: k.name,
                weight: k.weight,
                percent: pct.toFixed(1),
                color: COLORS[i % COLORS.length],
                circumference: CIRC,
                offset: CIRC - (CIRC * Math.min(pct, 100) / 100),
                targetDisplay: this.fmt(k.target),
                actualDisplay: this.fmt(k.actual),
                percentClass: pct >= 100 ? 'kd-pct-green' : pct >= 70 ? 'kd-pct-amber' : 'kd-pct-red'
            };
        });
    }

    get computedKpis() { return this.computedFilteredKpis; }
    get computedLeaderboard() { return this.leaderboard; }

    get computedTeam() {
        return this.team.map(row => {
            const pct = Number(row.percent) || 0;
            return {
                ...row,
                percentDisplay: pct.toFixed(1),
                targetDisplay: this.fmt(row.target),
                actualDisplay: this.fmt(row.actual),
                incentiveDisplay: this.fmt(row.incentive || 0),
                progressWidth: `width: ${Math.min(pct, 100)}%`,
                percentClass: pct >= 100 ? 'kd-pct-green' : pct >= 70 ? 'kd-pct-amber' : 'kd-pct-red'
            };
        });
    }

    // ===== CHART RENDERING =====
    renderCharts() {
        if (!this.chartJsLoaded) return;
        this.renderTrendChart();
        this.renderIncentiveChart();
        this.renderCriteriaChart();
    }

    renderTrendChart() {
        const canvas = this.template.querySelector('.kd-trend-canvas');
        if (!canvas) return;
        if (this.trendChart) this.trendChart.destroy();

        const labels = this.trend.map(d => d.label || '');
        const targets = this.trend.map(d => d.target || 0);
        const actuals = this.trend.map(d => d.actual || 0);

        const isLine = this.trendChartType === 'line';

        this.trendChart = new window.Chart(canvas.getContext('2d'), {
            type: this.trendChartType,
            data: {
                labels,
                datasets: [
                    {
                        label: 'Target',
                        data: targets,
                        borderColor: '#0176d3',
                        backgroundColor: isLine ? 'rgba(1, 118, 211, 0.1)' : 'rgba(1, 118, 211, 0.3)',
                        fill: isLine,
                        tension: isLine ? 0.3 : undefined,
                        pointRadius: isLine ? 4 : undefined,
                        pointBackgroundColor: isLine ? '#0176d3' : undefined,
                        borderWidth: isLine ? 2 : 1,
                        borderRadius: isLine ? undefined : 4
                    },
                    {
                        label: 'Achievement',
                        data: actuals,
                        borderColor: '#2e844a',
                        backgroundColor: isLine ? 'rgba(46, 132, 74, 0.1)' : 'rgba(46, 132, 74, 0.6)',
                        fill: isLine,
                        tension: isLine ? 0.3 : undefined,
                        pointRadius: isLine ? 4 : undefined,
                        pointBackgroundColor: isLine ? '#2e844a' : undefined,
                        borderWidth: isLine ? 2 : 1,
                        borderRadius: isLine ? undefined : 4
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: { legend: { position: 'top' } },
                scales: { y: { beginAtZero: true }, x: {} }
            }
        });
    }

    renderIncentiveChart() {
        const canvas = this.template.querySelector('.kd-incentive-canvas');
        if (!canvas) return;
        if (this.incentiveChart) this.incentiveChart.destroy();

        const s = this.incentiveSummary;
        const data = [
            s['Calculated_amount'] || 0,
            s['Pending Approval_amount'] || 0,
            s['Approved_amount'] || 0,
            s['Paid_amount'] || 0
        ];

        if (data.every(d => d === 0)) return;

        this.incentiveChart = new window.Chart(canvas.getContext('2d'), {
            type: 'doughnut',
            data: {
                labels: ['Calculated', 'Pending', 'Approved', 'Paid'],
                datasets: [{
                    data,
                    backgroundColor: ['#0176d3', '#f5a742', '#2e844a', '#7e5cef'],
                    borderWidth: 2,
                    borderColor: '#fff'
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                cutout: '60%',
                plugins: { legend: { position: 'bottom', labels: { font: { size: 11 }, padding: 10 } } }
            }
        });
    }

    renderCriteriaChart() {
        const canvas = this.template.querySelector('.kd-criteria-canvas');
        if (!canvas || !this.filteredKpis.length) return;

        if (this.criteriaChart) this.criteriaChart.destroy();

        const filtered = this.filteredKpis;
        const labels = filtered.map(k => k.name);
        const percents = filtered.map(k => Number(k.percent) || 0);

        if (this.criteriaChartType === 'radar') {
            this.renderRadarChart(canvas, labels, percents);
        } else if (this.criteriaChartType === 'doughnut') {
            this.renderDoughnutChart(canvas, labels, percents);
        } else {
            this.renderBarChart(canvas, labels, percents);
        }
    }

    renderBarChart(canvas, labels, percents) {
        const bgColors = percents.map(p =>
            p >= 100 ? 'rgba(46,132,74,0.7)' : p >= 70 ? 'rgba(230,81,0,0.7)' : 'rgba(194,57,52,0.7)'
        );

        const datasets = [{
            label: 'Current Period',
            data: percents,
            backgroundColor: bgColors,
            borderRadius: 4,
            barThickness: this.comparisonKpisData.length > 0 ? 18 : 24
        }];

        if (this.comparisonKpisData.length > 0) {
            const compMap = {};
            this.comparisonKpisData.forEach(k => { compMap[k.name] = Number(k.percent) || 0; });
            const compPercents = labels.map(l => compMap[l] || 0);

            datasets.push({
                label: 'Comparison Period',
                data: compPercents,
                backgroundColor: 'rgba(126, 92, 239, 0.5)',
                borderRadius: 4,
                barThickness: 18
            });
        }

        const maxVal = Math.max(120, ...percents.map(p => p + 10));

        this.criteriaChart = new window.Chart(canvas.getContext('2d'), {
            type: 'bar',
            data: { labels, datasets },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                indexAxis: 'y',
                plugins: {
                    legend: { display: datasets.length > 1 },
                    tooltip: { callbacks: { label: ctx => ctx.dataset.label + ': ' + ctx.parsed.x + '%' } }
                },
                scales: {
                    x: { beginAtZero: true, max: maxVal, ticks: { callback: v => v + '%' } },
                    y: { ticks: { font: { size: 12 } } }
                }
            }
        });
    }

    renderRadarChart(canvas, labels, percents) {
        const datasets = [{
            label: 'Achievement %',
            data: percents,
            backgroundColor: 'rgba(1, 118, 211, 0.2)',
            borderColor: '#0176d3',
            borderWidth: 2,
            pointBackgroundColor: '#0176d3',
            pointRadius: 4
        }];

        if (this.comparisonKpisData.length > 0) {
            const compMap = {};
            this.comparisonKpisData.forEach(k => { compMap[k.name] = Number(k.percent) || 0; });
            datasets.push({
                label: 'Comparison',
                data: labels.map(l => compMap[l] || 0),
                backgroundColor: 'rgba(126, 92, 239, 0.15)',
                borderColor: '#7e5cef',
                borderWidth: 2,
                pointBackgroundColor: '#7e5cef',
                pointRadius: 4
            });
        }

        this.criteriaChart = new window.Chart(canvas.getContext('2d'), {
            type: 'radar',
            data: { labels, datasets },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: { legend: { position: 'bottom' } },
                scales: {
                    r: {
                        beginAtZero: true,
                        suggestedMax: Math.max(120, ...percents) + 10,
                        ticks: { callback: v => v + '%', stepSize: 25 },
                        pointLabels: { font: { size: 12 } }
                    }
                }
            }
        });
    }

    renderDoughnutChart(canvas, labels, percents) {
        this.criteriaChart = new window.Chart(canvas.getContext('2d'), {
            type: 'doughnut',
            data: {
                labels,
                datasets: [{
                    data: percents,
                    backgroundColor: labels.map((_, i) => COLORS[i % COLORS.length]),
                    borderWidth: 2,
                    borderColor: '#fff'
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                cutout: '55%',
                plugins: {
                    legend: { position: 'bottom', labels: { font: { size: 11 }, padding: 10 } },
                    tooltip: { callbacks: { label: ctx => ctx.label + ': ' + ctx.parsed + '%' } }
                }
            }
        });
    }

    // ===== HELPERS =====
    fmt(val) {
        if (val == null) return '0';
        val = Number(val);
        if (val >= 10000000) return (val / 10000000).toFixed(1) + 'Cr';
        if (val >= 100000) return (val / 100000).toFixed(1) + 'L';
        if (val >= 1000) return (val / 1000).toFixed(1) + 'K';
        return String(Math.round(val));
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}