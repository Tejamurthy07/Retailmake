import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ChartJs from '@salesforce/resourceUrl/ChartJs';
import getDashboardInit from '@salesforce/apex/AchievementDashboardController.getDashboardInit';
import getTargetsAndAchievements from '@salesforce/apex/AchievementDashboardController.getTargetsAndAchievements';
import getTrendData from '@salesforce/apex/AchievementDashboardController.getTrendData';
import getLeaderboard from '@salesforce/apex/AchievementDashboardController.getLeaderboard';
import getDrillDown from '@salesforce/apex/AchievementDashboardController.getDrillDown';
import runAchievementCalculation from '@salesforce/apex/AchievementDashboardController.runAchievementCalculation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class AchievementDashboard extends LightningElement {

    @track isLoading = false;
    chartJsLoaded = false;

    @track periodOptions = [];
    periodsRaw = [];
    selectedPeriod = '';
    selectedYear = '';
    currentUserId = '';

    @track kpiCards = [];
    @track totalPercent = 0;
    @track totalTarget = 0;
    @track totalActual = 0;
    @track leaderboard = [];
    @track drillDown = [];
    @track trendData = [];

    trendChart = null;
    kpiChart = null;
    criteriaChart = null;

    connectedCallback() {
        this.loadChartJs();
        this.loadInit();
    }

    loadChartJs() {
        loadScript(this, ChartJs)
            .then(() => { this.chartJsLoaded = true; })
            .catch(() => { this.showToast('Error', 'Failed to load Chart.js', 'error'); });
    }

    loadInit() {
        this.isLoading = true;
        getDashboardInit()
            .then(result => {
                const periods = result.periods || [];
                this.periodsRaw = periods;
                this.periodOptions = periods.map(p => ({ label: p.Name, value: p.Id }));
                this.selectedPeriod = result.currentPeriodId || '';
                this.currentUserId = result.currentUserId || '';
                this.selectedYear = this.deriveYearFromPeriod(this.selectedPeriod)
                    || String(result.currentYear || new Date().getFullYear());

                this.loadAllData();
            })
            .catch(e => {
                this.showToast('Error', e?.body?.message || 'Failed to initialize', 'error');
                this.isLoading = false;
            });
    }

    loadAllData() {
        this.isLoading = true;
        Promise.all([
            getTargetsAndAchievements({ userId: this.currentUserId, periodId: this.selectedPeriod }),
            getLeaderboard({ periodId: this.selectedPeriod }),
            getDrillDown({ userId: this.currentUserId, periodId: this.selectedPeriod }),
            getTrendData({ userId: this.currentUserId, year: Number(this.selectedYear) })
        ]).then(([kpiData, leaderboardData, drillDownData, trendData]) => {
            this.processKpiData(kpiData);
            this.processLeaderboard(leaderboardData);
            this.drillDown = drillDownData || [];
            this.trendData = trendData || [];

            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => { this.renderCharts(); }, 300);
        })
        .catch(e => { this.showToast('Error', e?.body?.message || 'Failed to load data', 'error'); })
        .finally(() => { this.isLoading = false; });
    }

    processKpiData(data) {
        if (!data) { this.kpiCards = []; return; }

        const criteria = data.criteria || [];
        const colors = ['#0176d3', '#2e844a', '#7e5cef', '#e65100', '#c23934', '#00796b', '#1565c0', '#ad1457'];

        this.kpiCards = criteria.map((c, i) => {
            const pct = Number(c.percent) || 0;
            const circumference = 2 * Math.PI * 34;
            const offset = circumference - (circumference * Math.min(pct, 100) / 100);

            return {
                key: c.name,
                name: c.name,
                category: c.category || '',
                target: this.fmt(c.target),
                actual: this.fmt(c.actual),
                percent: pct,
                color: colors[i % colors.length],
                ringOffset: offset,
                ringCircumference: circumference,
                percentClass: pct >= 100 ? 'ad-pct-green' : pct >= 70 ? 'ad-pct-amber' : 'ad-pct-red'
            };
        });

        this.totalPercent = Number(data.totalPercent) || 0;
        this.totalTarget = Number(data.totalTarget) || 0;
        this.totalActual = Number(data.totalAchievement) || 0;
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
                rankClass: idx === 0 ? 'ad-rank-gold' : idx === 1 ? 'ad-rank-silver' : idx === 2 ? 'ad-rank-bronze' : 'ad-rank-default',
                percentColorClass: pct >= 100 ? 'ad-leader-pct ad-pct-green' : pct >= 70 ? 'ad-leader-pct ad-pct-amber' : 'ad-leader-pct ad-pct-red'
            };
        });
    }

    renderCharts() {
        if (!this.chartJsLoaded) return;
        this.renderTrendChart();
        this.renderKpiChart();
        this.renderCriteriaChart();
    }

    renderTrendChart() {
        const canvas = this.template.querySelector('.ad-trend-canvas');
        if (!canvas || !this.trendData.length) return;

        if (this.trendChart) this.trendChart.destroy();

        this.trendChart = new window.Chart(canvas.getContext('2d'), {
            type: 'bar',
            data: {
                labels: this.trendData.map(d => d.label),
                datasets: [
                    {
                        label: 'Target',
                        data: this.trendData.map(d => d.target || 0),
                        backgroundColor: 'rgba(1, 118, 211, 0.3)',
                        borderColor: '#0176d3',
                        borderWidth: 1,
                        borderRadius: 4
                    },
                    {
                        label: 'Achievement',
                        data: this.trendData.map(d => d.actual || 0),
                        backgroundColor: 'rgba(46, 132, 74, 0.6)',
                        borderColor: '#2e844a',
                        borderWidth: 1,
                        borderRadius: 4
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: { legend: { position: 'top', labels: { font: { size: 12 } } } },
                scales: {
                    y: { beginAtZero: true, ticks: { font: { size: 11 } } },
                    x: { ticks: { font: { size: 11 } } }
                }
            }
        });
    }

    renderKpiChart() {
        const canvas = this.template.querySelector('.ad-kpi-canvas');
        if (!canvas || !this.kpiCards.length) return;

        if (this.kpiChart) this.kpiChart.destroy();

        this.kpiChart = new window.Chart(canvas.getContext('2d'), {
            type: 'doughnut',
            data: {
                labels: this.kpiCards.map(k => k.name),
                datasets: [{
                    data: this.kpiCards.map(k => Number(k.percent) || 0),
                    backgroundColor: this.kpiCards.map(k => k.color),
                    borderWidth: 2,
                    borderColor: '#fff'
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                cutout: '65%',
                plugins: { legend: { position: 'bottom', labels: { font: { size: 11 }, padding: 12 } } }
            }
        });
    }

    renderCriteriaChart() {
        const canvas = this.template.querySelector('.ad-criteria-canvas');
        if (!canvas || !this.kpiCards.length) return;

        if (this.criteriaChart) this.criteriaChart.destroy();

        const labels = this.kpiCards.map(k => k.name);
        const percents = this.kpiCards.map(k => Number(k.percent) || 0);
        const bgColors = percents.map(p => p >= 100 ? 'rgba(46,132,74,0.7)' : p >= 70 ? 'rgba(230,81,0,0.7)' : 'rgba(194,57,52,0.7)');

        this.criteriaChart = new window.Chart(canvas.getContext('2d'), {
            type: 'bar',
            data: {
                labels,
                datasets: [{
                    label: 'Achievement %',
                    data: percents,
                    backgroundColor: bgColors,
                    borderRadius: 4,
                    barThickness: 24
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                indexAxis: 'y',
                plugins: {
                    legend: { display: false },
                    tooltip: { callbacks: { label: ctx => ctx.parsed.x + '%' } }
                },
                scales: {
                    x: { beginAtZero: true, max: Math.max(120, ...percents.map(p => p + 10)), ticks: { callback: v => v + '%' } },
                    y: { ticks: { font: { size: 12 } } }
                }
            }
        });
    }

    handlePeriodChange(event) {
        this.selectedPeriod = event.target.value;
        this.selectedYear = this.deriveYearFromPeriod(this.selectedPeriod) || this.selectedYear;
        this.loadAllData();
    }

    deriveYearFromPeriod(periodId) {
        const period = this.periodsRaw.find(p => p.Id === periodId);
        if (period && period.Start_Date__c) {
            return String(new Date(period.Start_Date__c).getFullYear());
        }
        return null;
    }

    handleRefresh() { this.loadAllData(); }

    handleRunCalculation() {
        if (!this.selectedPeriod) {
            this.showToast('No Period', 'Select a period first.', 'warning');
            return;
        }
        this.isLoading = true;
        runAchievementCalculation({ periodId: this.selectedPeriod })
            .then(msg => {
                this.showToast('Calculation Started', msg, 'success');
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.loadAllData(); }, 5000);
            })
            .catch(e => {
                this.showToast('Error', e?.body?.message || 'Failed to run calculation', 'error');
            })
            .finally(() => { this.isLoading = false; });
    }

    get hasKpiCards() { return this.kpiCards.length > 0; }
    get hasLeaderboard() { return this.leaderboard.length > 0; }
    get hasDrillDown() { return this.drillDown.length > 0; }
    get hasTrendData() { return this.trendData.length > 0; }
    get kpiCount() { return this.kpiCards.length; }
    get totalTargetDisplay() { return this.fmt(this.totalTarget); }
    get totalActualDisplay() { return this.fmt(this.totalActual); }

    get totalPercentClass() {
        return this.totalPercent >= 100 ? 'ad-pct-green' : this.totalPercent >= 70 ? 'ad-pct-amber' : 'ad-pct-red';
    }

    get computedDrillDown() {
        return this.drillDown.map(row => {
            const pct = Number(row.percent) || 0;
            return {
                ...row,
                percentDisplay: pct.toFixed(1),
                targetDisplay: this.fmt(row.target),
                actualDisplay: this.fmt(row.actual),
                progressWidth: `width: ${Math.min(pct, 100)}%`,
                percentClass: pct >= 100 ? 'ad-pct-green' : pct >= 70 ? 'ad-pct-amber' : 'ad-pct-red'
            };
        });
    }

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