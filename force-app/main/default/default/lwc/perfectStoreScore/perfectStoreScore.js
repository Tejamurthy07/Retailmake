import { LightningElement, track } from 'lwc';
import getSurveyOptions from '@salesforce/apex/PerfectStoreScoreController.getSurveyOptions';
import getScoreKPIs from '@salesforce/apex/PerfectStoreScoreController.getScoreKPIs';
import getOutletRanking from '@salesforce/apex/PerfectStoreScoreController.getOutletRanking';
import getTerritoryRanking from '@salesforce/apex/PerfectStoreScoreController.getTerritoryRanking';
import getRepRanking from '@salesforce/apex/PerfectStoreScoreController.getRepRanking';

export default class PerfectStoreScore extends LightningElement {
    isLoading = false;
    errorMessage = '';
    activeTab = 'outlet';

    @track surveyOptions = [{ label: 'All Audit Surveys', value: '' }];
    selectedSurveyId = '';
    startDate;
    endDate;

    @track kpis = { avgScore: 0, totalAudits: 0, perfectStores: 0, outletsAudited: 0, threshold: 85 };
    @track outletRows = [];
    @track territoryRows = [];
    @track repRows = [];

    connectedCallback() {
        const today = new Date();
        const from = new Date();
        from.setDate(today.getDate() - 90);
        this.endDate = today.toISOString().slice(0, 10);
        this.startDate = from.toISOString().slice(0, 10);
        this.loadSurveyOptions();
        this.loadAll();
    }

    loadSurveyOptions() {
        getSurveyOptions()
            .then(opts => {
                if (opts && opts.length) {
                    this.surveyOptions = opts;
                    // Default the view to the Perfect Store Audit when present.
                    const psa = opts.find(o => o.label && o.label.toLowerCase().indexOf('perfect store') !== -1);
                    if (psa && !this.selectedSurveyId) { this.selectedSurveyId = psa.value; this.loadAll(); }
                }
            })
            .catch(() => { /* keep default */ });
    }

    loadAll() {
        this.loadKPIs();
        this.loadOutlets();
        this.loadTerritory();
        this.loadReps();
    }

    get filterArgs() {
        return {
            surveyId: this.selectedSurveyId || '',
            startDate: this.startDate || null,
            endDate: this.endDate || null
        };
    }

    loadKPIs() {
        this.isLoading = true;
        getScoreKPIs(this.filterArgs)
            .then(res => { this.kpis = res; this.errorMessage = ''; })
            .catch(err => this.handleError(err))
            .finally(() => { this.isLoading = false; });
    }

    loadOutlets() {
        getOutletRanking({ ...this.filterArgs, topN: 20 })
            .then(rows => { this.outletRows = this.decorate(rows); })
            .catch(err => this.handleError(err));
    }

    loadTerritory() {
        getTerritoryRanking(this.filterArgs)
            .then(rows => { this.territoryRows = this.decorate(rows); })
            .catch(err => this.handleError(err));
    }

    loadReps() {
        getRepRanking({ ...this.filterArgs, topN: 20 })
            .then(rows => { this.repRows = this.decorate(rows); })
            .catch(err => this.handleError(err));
    }

    // ── ranking presentation ──
    decorate(rows) {
        const threshold = this.kpis && this.kpis.threshold ? this.kpis.threshold : 85;
        return (rows || []).map((r, i) => {
            const score = Number(r.avgScore) || 0;
            let band = 'pss-band_danger';
            if (score >= threshold) band = 'pss-band_healthy';
            else if (score >= 70) band = 'pss-band_warning';
            const rank = i + 1;
            let rankClass = 'pss-rank';
            if (rank === 1) rankClass = 'pss-rank pss-rank_gold';
            else if (rank === 2) rankClass = 'pss-rank pss-rank_silver';
            else if (rank === 3) rankClass = 'pss-rank pss-rank_bronze';
            return {
                id: r.id, name: r.name, territory: r.territory,
                rank, rankClass, band,
                scoreDisplay: score.toFixed(1),
                surveyCount: r.surveyCount,
                barStyle: 'width:' + Math.min(100, Math.max(0, score)) + '%',
                barClass: 'pss-bar-fill ' + band
            };
        });
    }

    // ── KPI display ──
    get avgScoreDisplay() { return (Number(this.kpis.avgScore) || 0).toFixed(1); }
    get avgScoreClass() {
        const s = Number(this.kpis.avgScore) || 0;
        const t = Number(this.kpis.threshold) || 85;
        return 'pss-kpi pss-kpi_score ' + (s >= t ? 'pss-band_healthy' : s >= 70 ? 'pss-band_warning' : 'pss-band_danger');
    }
    get thresholdLabel() { return 'Perfect Store (≥' + (Number(this.kpis.threshold) || 85) + '%)'; }

    get hasOutletRows() { return this.outletRows.length > 0; }
    get hasTerritoryRows() { return this.territoryRows.length > 0; }
    get hasRepRows() { return this.repRows.length > 0; }

    // ── filters ──
    handleSurveyChange(e) { this.selectedSurveyId = e.detail.value; this.loadAll(); }
    handleStartDate(e) { this.startDate = e.detail.value; this.loadAll(); }
    handleEndDate(e) { this.endDate = e.detail.value; this.loadAll(); }
    handleRefresh() { this.loadAll(); }
    handleTabActive(e) { this.activeTab = e.target.value; }

    handleError(error) {
        let msg = 'Something went wrong.';
        if (error && error.body && error.body.message) msg = error.body.message;
        else if (error && error.message) msg = error.message;
        this.errorMessage = msg;
    }
}