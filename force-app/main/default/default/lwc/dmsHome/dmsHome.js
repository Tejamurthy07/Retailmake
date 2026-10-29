import { LightningElement } from 'lwc';
import getTierDashboard from '@salesforce/apex/DMS_PortalController.getTierDashboard';

const PERIODS = [
    { label: 'This Month', value: 'THIS_JC' },
    { label: 'Last Month', value: 'LAST_JC' },
    { label: 'This Week', value: 'THIS_WEEK' },
    { label: 'Last Week', value: 'LAST_WEEK' },
    { label: 'This Quarter', value: 'THIS_QUARTER' },
    { label: 'This Year', value: 'THIS_YEAR' }
];

const TABS = [
    { label: 'Primary', value: 'Primary', sub: 'Company → Distributor (inbound purchases)' },
    { label: 'Secondary', value: 'Secondary', sub: 'Distributor → Retailer (outbound sales)' }
];

// Order-analysis grouping dimensions — our real product structure.
const DIMENSIONS = [
    { id: 'brand', label: 'Brand' },
    { id: 'category', label: 'Category' },
    { id: 'subcategory', label: 'Sub-Category' }
];

export default class DmsHome extends LightningElement {
    tier = 'Primary';
    period = 'THIS_YEAR';
    dim = 'brand';
    data;
    error;
    loading = false;

    connectedCallback() {
        this.load();
    }

    get tabs() {
        return TABS.map((t) => ({
            ...t,
            css: 'tier-tab' + (t.value === this.tier ? ' tier-tab_active' : '')
        }));
    }
    get periods() {
        return PERIODS.map((p) => ({ ...p, css: 'period-chip' + (p.value === this.period ? ' period-chip_active' : '') }));
    }
    get activeSub() {
        const t = TABS.find((x) => x.value === this.tier);
        return t ? t.sub : '';
    }
    get isSecondary() {
        return this.tier === 'Secondary';
    }

    selectTier(e) {
        this.tier = e.currentTarget.dataset.value;
        this.load();
    }
    selectPeriod(e) {
        this.period = e.currentTarget.dataset.value;
        this.load();
    }

    get dimensions() {
        return DIMENSIONS.map((dm) => ({
            ...dm,
            css: 'seg-btn' + (dm.id === this.dim ? ' seg-btn_active' : '')
        }));
    }
    selectDim(e) {
        this.dim = e.currentTarget.dataset.dim;
        this.load();
    }

    load() {
        this.loading = true;
        getTierDashboard({ tier: this.tier, period: this.period, dim: this.dim })
            .then((d) => {
                this.data = this.decorate(d);
                this.error = undefined;
                this.loading = false;
            })
            .catch((e) => {
                this.error = (e.body && e.body.message) || 'Unable to load dashboard.';
                this.loading = false;
            });
    }

    decorate(d) {
        const bars = (arr, fmt) =>
            (arr || []).map((b) => ({
                brand: b.brand,
                pct: b.pct,
                barStyle: `width:${b.pct || 0}%`,
                display: fmt(b.value)
            }));
        const aging = d.aging || {};
        const agingKeys = ['Current', '1-30', '31-60', '61-90', '90+'];
        const agingMax = Math.max(1, ...agingKeys.map((k) => Number(aging[k] || 0)));
        return {
            ...d,
            orderValueFmt: this.fmtCurrency(d.orderValue),
            invoiceValueFmt: this.fmtCurrency(d.invoiceValue),
            avgOrderValueFmt: this.fmtCurrency(d.avgOrderValue),
            outstandingFmt: this.fmtCurrency(d.outstanding),
            collectionFmt: this.fmtCurrency(d.collectionValue),
            stockValueFmt: this.fmtCurrency(d.stockValue),
            creditAvailableFmt: this.fmtCurrency(d.creditAvailable),
            brandOrders: bars(d.brandOrders, (v) => this.fmtNum(v)),
            brandValue: bars(d.brandValue, (v) => this.fmtCurrency(v)),
            aging: agingKeys.map((k) => ({
                bucket: k,
                amount: this.fmtCurrency(aging[k]),
                barStyle: `width:${Math.round((Number(aging[k] || 0) / agingMax) * 100)}%`,
                tone: k === 'Current' ? 'age-green' : k === '90+' || k === '61-90' ? 'age-red' : 'age-amber'
            })),
            topProducts: (d.topProducts || []).map((p) => ({
                ...p,
                valueFmt: this.fmtCurrency(p.value),
                qtyFmt: this.fmtNum(p.qty),
                barStyle: `width:${p.pct || 0}%`
            })),
            recentInvoices: (d.recentInvoices || []).map((r) => ({
                ...r,
                amountFmt: this.fmtCurrency(r.amount),
                balanceFmt: this.fmtCurrency(r.balance),
                statusClass: 'pill ' + this.statusTone(r.status)
            }))
        };
    }

    statusTone(status) {
        const s = (status || '').toLowerCase();
        if (s.includes('paid')) return 'pill-green';
        if (s.includes('cancel')) return 'pill-grey';
        if (s.includes('partial')) return 'pill-amber';
        return 'pill-blue';
    }

    fmtCurrency(v) {
        v = Number(v || 0);
        if (v >= 100000) return '₹' + (v / 100000).toFixed(2) + 'L';
        if (v >= 1000) return '₹' + (v / 1000).toFixed(1) + 'K';
        return '₹' + v;
    }
    fmtNum(v) {
        v = Number(v || 0);
        return v >= 1000 ? (v / 1000).toFixed(1) + 'K' : String(v);
    }

    get hasBrandOrders() {
        return this.data && this.data.brandOrders && this.data.brandOrders.length > 0;
    }
    get hasBrandValue() {
        return this.data && this.data.brandValue && this.data.brandValue.length > 0;
    }
    get hasTopProducts() {
        return this.data && this.data.topProducts && this.data.topProducts.length > 0;
    }
    get hasRecent() {
        return this.data && this.data.recentInvoices && this.data.recentInvoices.length > 0;
    }
}