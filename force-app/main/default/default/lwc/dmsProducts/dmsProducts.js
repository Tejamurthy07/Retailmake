import { LightningElement, wire } from 'lwc';
import getProductCatalog from '@salesforce/apex/DMS_PortalController.getProductCatalog';
import getProductStock from '@salesforce/apex/DMS_PortalController.getProductStock';
import getSchemes from '@salesforce/apex/DMS_PortalController.getSchemes';

const COLUMNS = [
    { label: 'SKU', fieldName: 'sku', initialWidth: 120 },
    { label: 'Product', fieldName: 'name' },
    { label: 'Brand', fieldName: 'brand' },
    { label: 'Category', fieldName: 'category' },
    { label: 'Pack', fieldName: 'packSize', initialWidth: 90 },
    { label: 'MRP', fieldName: 'mrp', type: 'currency', cellAttributes: { alignment: 'left' }, initialWidth: 100 },
    { label: 'Price/Unit', fieldName: 'unitPrice', type: 'currency', cellAttributes: { alignment: 'left' }, initialWidth: 110 },
    { label: 'GST %', fieldName: 'gstRate', type: 'number', cellAttributes: { alignment: 'left' }, initialWidth: 80 },
    { label: 'Dist. Price/Case', fieldName: 'distPriceCase', type: 'currency', cellAttributes: { alignment: 'left' } },
    { label: 'On Hand', fieldName: 'onHand', type: 'number', cellAttributes: { alignment: 'left' }, initialWidth: 100 },
    { label: 'Stock', fieldName: 'stockStatus', initialWidth: 110 },
    { type: 'button-icon', fixedWidth: 50,
      typeAttributes: { iconName: 'utility:preview', name: 'view', variant: 'bare', alternativeText: 'Details' } }
];

const BATCH_COLUMNS = [
    { label: 'Distributor', fieldName: 'distName' },
    { label: 'Batch', fieldName: 'Batch_No__c' },
    { label: 'On Hand', fieldName: 'Closing_Stock__c', type: 'number', cellAttributes: { alignment: 'left' } },
    { label: 'Expiry', fieldName: 'Expiry_Date__c', type: 'date' }
];

const STATUS_BADGE = {
    Active: 'status-badge status-active',
    'Expiring Soon': 'status-badge status-expiring',
    Upcoming: 'status-badge status-upcoming',
    Expired: 'status-badge status-expired'
};

const CATEGORY_COLORS = {
    'Free Products': { bg: '#fff8e1', color: '#dd7a01', short: 'FP' },
    'Discount in %': { bg: '#e8f4fd', color: '#0176d3', short: '%' },
    'Discount in Value': { bg: '#e6f7e9', color: '#2e844a', short: 'Rs' },
    'Reward Points': { bg: '#f3e8ff', color: '#9b59b6', short: 'RP' }
};

const STOCK_BADGE = {
    'In Stock': 'pill pill_green',
    Low: 'pill pill_orange',
    'Out of Stock': 'pill pill_red'
};

export default class DmsProducts extends LightningElement {
    sub = 'products';
    view = 'grid';
    allRows = [];
    rows = [];
    brand = 'all';
    category = 'all';
    search = '';
    brandOptions = [{ label: 'All Brands', value: 'all' }];
    categoryOptions = [{ label: 'All Categories', value: 'all' }];
    categoryRail = [];
    columns = COLUMNS;
    batchColumns = BATCH_COLUMNS;
    schemeData;
    selectedProduct;
    batches = [];
    error;

    @wire(getProductCatalog)
    wiredProducts({ data, error }) {
        if (data) {
            this.allRows = data.map((r) => this.decorate(r));
            const brands = [...new Set(data.map((r) => r.brand).filter(Boolean))].sort();
            const cats = [...new Set(data.map((r) => r.category).filter(Boolean))].sort();
            this.brandOptions = [{ label: 'All Brands', value: 'all' }, ...brands.map((b) => ({ label: b, value: b }))];
            this.categoryOptions = [{ label: 'All Categories', value: 'all' }, ...cats.map((c) => ({ label: c, value: c }))];
            this.buildRail(cats);
            this.applyFilter();
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Unable to load products.';
        }
    }

    @wire(getSchemes)
    wiredSchemes({ data, error }) {
        if (data) {
            this.schemeData = {
                ...data,
                schemes: data.schemes.map((s) => {
                    const cat = CATEGORY_COLORS[s.category] || { bg: '#f3f3f3', color: '#706e6b', short: '?' };
                    return {
                        ...s,
                        badgeCss: STATUS_BADGE[s.status] || 'status-badge status-expired',
                        categoryShort: cat.short,
                        categoryStyle: `background-color:${cat.bg};color:${cat.color}`,
                        hasProducts: s.products && s.products.length > 0,
                        priorityText: s.priority != null ? 'P' + s.priority : null
                    };
                })
            };
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Unable to load schemes.';
        }
    }

    schemeStatFilter = 'all';
    handleSchemeStat(e) {
        const k = e.currentTarget.dataset.key;
        this.schemeStatFilter = this.schemeStatFilter === k ? 'all' : k;
    }
    get schemeStatCards() {
        const d = this.schemeData || {};
        return [
            { key: 'all', label: 'Total Schemes', value: d.total || 0, cls: this.statCls('all', 'total') },
            { key: 'Active', label: 'Active', value: d.active || 0, cls: this.statCls('Active', 'active') },
            { key: 'Expiring Soon', label: 'Expiring Soon', value: d.expiringSoon || 0, cls: this.statCls('Expiring Soon', 'expiring') },
            { key: 'Upcoming', label: 'Upcoming', value: d.upcoming || 0, cls: this.statCls('Upcoming', 'upcoming') }
        ];
    }
    statCls(key, tone) {
        return 'stat-card stat-' + tone + (this.schemeStatFilter === key ? ' stat-card_active' : '');
    }
    get visibleSchemes() {
        if (!this.schemeData) { return []; }
        if (this.schemeStatFilter === 'all') { return this.schemeData.schemes; }
        return this.schemeData.schemes.filter((s) => s.status === this.schemeStatFilter);
    }
    get hasVisibleSchemes() { return this.visibleSchemes.length > 0; }
    get activeBudgetText() {
        const v = (this.schemeData && this.schemeData.activeBudget) || 0;
        return '₹' + Number(v).toLocaleString('en-IN');
    }

    decorate(r) {
        return {
            ...r,
            hasImage: !!r.imageUrl,
            initials: (r.name || '?').trim().charAt(0).toUpperCase(),
            stockCss: STOCK_BADGE[r.stockStatus] || 'pill pill_grey',
            gstText: r.gstRate != null ? r.gstRate + '%' : '—'
        };
    }

    buildRail(cats) {
        const counts = {};
        this.allRows.forEach((r) => {
            const k = r.category || 'Uncategorised';
            counts[k] = (counts[k] || 0) + 1;
        });
        const items = cats.map((c) => ({ value: c, label: c, count: counts[c] || 0 }));
        this.categoryRail = [{ value: 'all', label: 'All Products', count: this.allRows.length }, ...items];
    }

    get railItems() {
        return this.categoryRail.map((c) => ({
            ...c,
            css: 'rail-item' + (this.category === c.value ? ' rail-item_active' : '')
        }));
    }

    // ── Sub-tabs (Products / Schemes) ─────────────────────────────────────
    get isProducts() { return this.sub === 'products'; }
    get isSchemes() { return this.sub === 'schemes'; }
    get prodCss() { return 'sub' + (this.isProducts ? ' sub_active' : ''); }
    get schemeCss() { return 'sub' + (this.isSchemes ? ' sub_active' : ''); }
    showProducts() { this.sub = 'products'; }
    showSchemes() { this.sub = 'schemes'; }

    // ── View toggle (Grid / Table) ────────────────────────────────────────
    get isGrid() { return this.view === 'grid'; }
    get isTable() { return this.view === 'table'; }
    get gridBtnCss() { return 'vtoggle' + (this.isGrid ? ' vtoggle_active' : ''); }
    get tableBtnCss() { return 'vtoggle' + (this.isTable ? ' vtoggle_active' : ''); }
    showGrid() { this.view = 'grid'; }
    showTable() { this.view = 'table'; }

    handleBrand(e) { this.brand = e.detail.value; this.applyFilter(); }
    handleCategory(e) { this.category = e.detail.value; this.applyFilter(); }
    handleSearch(e) { this.search = (e.target.value || '').toLowerCase(); this.applyFilter(); }
    pickCategory(e) { this.category = e.currentTarget.dataset.value; this.applyFilter(); }

    applyFilter() {
        this.rows = this.allRows.filter((r) => {
            const okBrand = this.brand === 'all' || r.brand === this.brand;
            const okCat = this.category === 'all' || r.category === this.category;
            const okSearch =
                !this.search ||
                (r.name || '').toLowerCase().includes(this.search) ||
                (r.sku || '').toLowerCase().includes(this.search) ||
                (r.brand || '').toLowerCase().includes(this.search);
            return okBrand && okCat && okSearch;
        });
    }

    openDetail(productId) {
        const row = this.allRows.find((r) => r.id === productId);
        if (!row) { return; }
        this.selectedProduct = row;
        this.batches = [];
        getProductStock({ productId: row.id })
            .then((data) => {
                this.batches = (data || []).map((b) => ({
                    ...b,
                    distName: b.Account__r ? b.Account__r.Name : ''
                }));
            })
            .catch(() => { this.batches = []; });
    }

    handleRowAction(e) {
        if (e.detail.action.name === 'view') { this.openDetail(e.detail.row.id); }
    }
    handleCardClick(e) { this.openDetail(e.currentTarget.dataset.id); }
    closeDetail() { this.selectedProduct = undefined; this.batches = []; }

    get count() { return this.rows.length; }
    get hasRows() { return this.rows.length > 0; }
    get hasBatches() { return this.batches && this.batches.length > 0; }
}