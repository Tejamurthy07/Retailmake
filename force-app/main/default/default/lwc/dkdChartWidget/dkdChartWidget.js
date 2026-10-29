import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ChartJs from '@salesforce/resourceUrl/ChartJs';

const DEFAULT_COLORS = [
    '#0176d3', '#2e844a', '#7b61ff', '#dd7a01',
    '#c23934', '#7e5cef', '#06a59a', '#ffa41c',
    '#0b827c', '#9c4aa1', '#f04e2e', '#3b9855'
];

export default class DkdChartWidget extends LightningElement {
    _chartType = 'bar';
    @api title = '';
    @api height = 300;
    @api format = 'Number';
    @api showLegend = false;

    @api
    get chartType() { return this._chartType; }
    set chartType(value) {
        const prev = this._chartType;
        this._chartType = value || 'bar';
        if (prev !== this._chartType) {
            this._scheduleRender();
        }
    }

    _labels = [];
    _datasets = [];
    chartJsLoaded = false;
    chartInstance = null;
    _renderTimer = null;
    _isConnected = false;

    @api
    get labels() { return this._labels; }
    set labels(value) {
        this._labels = value || [];
        this._scheduleRender();
    }

    @api
    get chartDatasets() { return this._datasets; }
    set chartDatasets(value) {
        this._datasets = value || [];
        this._scheduleRender();
    }

    connectedCallback() {
        this._isConnected = true;
        if (window.Chart) {
            this.chartJsLoaded = true;
            this._scheduleRender();
            return;
        }
        loadScript(this, ChartJs)
            .then(() => {
                this.chartJsLoaded = true;
                this._scheduleRender();
            })
            .catch(err => {
                console.error('Chart.js load failed', err);
            });
    }

    disconnectedCallback() {
        this._isConnected = false;
        if (this._renderTimer) {
            clearTimeout(this._renderTimer);
            this._renderTimer = null;
        }
        this._destroyChart();
    }

    // ── Safe rendering with debounce ────────────────────────────

    _scheduleRender() {
        if (this._renderTimer) {
            clearTimeout(this._renderTimer);
        }
        this._pendingRender = true;
        if (this._isConnected && this.chartJsLoaded) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._renderTimer = setTimeout(() => {
                this._renderTimer = null;
                this._pendingRender = false;
                this._safeRender();
            }, 200);
        }
    }

    renderedCallback() {
        if (this._pendingRender && this.chartJsLoaded && this._isConnected) {
            this._pendingRender = false;
            if (this._renderTimer) clearTimeout(this._renderTimer);
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._renderTimer = setTimeout(() => {
                this._renderTimer = null;
                this._safeRender();
            }, 200);
        }
    }

    _destroyChart() {
        if (this.chartInstance) {
            try {
                this.chartInstance.destroy();
            } catch (e) {
                // Chart.js may throw if canvas already detached from DOM
            }
            this.chartInstance = null;
        }
    }

    _safeRender() {
        if (!this._isConnected || !this.chartJsLoaded || !window.Chart) return;

        this._destroyChart();

        if (!this._datasets.length || !this._labels.length) return;

        // lwc:dom="manual" container — we create the canvas ourselves
        const container = this.template.querySelector('.dkd-chart-canvas-wrap');
        if (!container) return;

        // Remove old canvas if any
        while (container.firstChild) {
            container.removeChild(container.firstChild);
        }

        // Create a fresh canvas element
        const canvas = document.createElement('canvas');
        container.appendChild(canvas);

        const ctx = canvas.getContext('2d');
        if (!ctx) return;

        const isPie = this.chartType === 'pie' || this.chartType === 'doughnut';
        const isHorizontal = this.chartType === 'horizontalBar';
        const actualType = isHorizontal ? 'bar' : this.chartType;

        const datasets = this._datasets.map((ds, idx) => {
            const color = ds.color || DEFAULT_COLORS[idx % DEFAULT_COLORS.length];
            if (isPie) {
                return {
                    label: ds.label || '',
                    data: ds.data || [],
                    backgroundColor: this._labels.map((_, i) => DEFAULT_COLORS[i % DEFAULT_COLORS.length]),
                    borderWidth: 2,
                    borderColor: '#fff'
                };
            }
            if (this.chartType === 'line') {
                const lineDs = {
                    label: ds.label || '',
                    data: ds.data || [],
                    borderColor: color,
                    backgroundColor: ds.fill === false ? 'transparent' : this._hexToRgba(color, 0.12),
                    fill: ds.fill !== false,
                    tension: 0.3,
                    pointRadius: ds.pointRadius !== undefined ? ds.pointRadius : 4,
                    pointBackgroundColor: color,
                    borderWidth: 2
                };
                if (ds.dashed) lineDs.borderDash = [6, 6];
                if (ds.bandUpper) {
                    lineDs.fill = false;
                    lineDs.borderWidth = 0;
                    lineDs.pointRadius = 0;
                }
                if (ds.bandLower) {
                    lineDs.fill = '-1';
                    lineDs.backgroundColor = this._hexToRgba(color, 0.1);
                    lineDs.borderWidth = 0;
                    lineDs.pointRadius = 0;
                }
                return lineDs;
            }
            return {
                label: ds.label || '',
                data: ds.data || [],
                backgroundColor: color,
                borderColor: color,
                borderWidth: 1,
                borderRadius: 4
            };
        });

        const options = {
            responsive: true,
            maintainAspectRatio: false,
            animation: { duration: 300 },
            indexAxis: isHorizontal ? 'y' : 'x',
            plugins: {
                legend: {
                    display: this.showLegend && (datasets.length > 1 || isPie),
                    position: isPie ? 'bottom' : 'top',
                    labels: { font: { size: 11 }, padding: 10, boxWidth: 12 }
                },
                tooltip: {
                    callbacks: {
                        label: (ctx) => {
                            const label = ctx.dataset.label || ctx.label || '';
                            const value = ctx.parsed.y !== undefined ? ctx.parsed.y
                                        : (ctx.parsed.x !== undefined ? ctx.parsed.x : ctx.parsed);
                            return label + ': ' + this._formatValue(value);
                        }
                    }
                }
            }
        };

        if (!isPie) {
            options.scales = {
                y: {
                    beginAtZero: true,
                    ticks: { callback: (v) => this._formatValue(v) },
                    grid: { color: 'rgba(0,0,0,0.06)' }
                },
                x: { grid: { display: false } }
            };
        } else {
            options.cutout = this.chartType === 'doughnut' ? '60%' : '0%';
        }

        try {
            // Deep-clone data to strip LWC Proxy wrappers — Chart.js
            // needs to set _chartjs on arrays via defineProperty which
            // fails on read-only LWC Proxies.
            const chartData = JSON.parse(JSON.stringify({
                labels: this._labels,
                datasets
            }));

            this.chartInstance = new window.Chart(ctx, {
                type: actualType,
                data: chartData,
                options
            });
        } catch (e) {
            console.error('Chart render error:', e.message || e);
            this.chartInstance = null;
        }
    }

    // ── Formatting ──────────────────────────────────────────────

    _formatValue(value) {
        const num = Number(value) || 0;
        if (this.format === 'Currency') {
            if (num >= 10000000) return '₹' + (num / 10000000).toFixed(1) + 'Cr';
            if (num >= 100000) return '₹' + (num / 100000).toFixed(1) + 'L';
            if (num >= 1000) return '₹' + (num / 1000).toFixed(1) + 'K';
            return '₹' + num.toFixed(0);
        }
        if (this.format === 'Percent') return num.toFixed(1) + '%';
        if (this.format === 'Duration') return Math.round(num) + 'm';
        if (num >= 10000000) return (num / 10000000).toFixed(1) + 'Cr';
        if (num >= 100000) return (num / 100000).toFixed(1) + 'L';
        if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
        return new Intl.NumberFormat('en-IN').format(Math.round(num));
    }

    _hexToRgba(hex, alpha) {
        if (!hex) return 'rgba(1, 118, 211, ' + alpha + ')';
        let h = hex.replace('#', '');
        if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
        const r = parseInt(h.substring(0, 2), 16);
        const g = parseInt(h.substring(2, 4), 16);
        const b = parseInt(h.substring(4, 6), 16);
        return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
    }

    get canvasContainerStyle() {
        return 'position: relative; height: ' + this.height + 'px; width: 100%;';
    }

    get hasData() {
        return this._labels && this._labels.length > 0 &&
               this._datasets && this._datasets.length > 0 &&
               this._datasets.some(d => d.data && d.data.length > 0);
    }
}