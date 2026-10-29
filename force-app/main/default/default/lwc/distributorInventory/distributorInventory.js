import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getInventorySummary from '@salesforce/apex/DMS_PortalController.getInventorySummary';
import placeReplenishmentIndent from '@salesforce/apex/DMS_PortalController.placeReplenishmentIndent';
import saveDistributorAdjustment from '@salesforce/apex/DMS_PortalController.saveDistributorAdjustment';
import getAdjustableProducts from '@salesforce/apex/DMS_PortalController.getAdjustableProducts';
import getStockMovements from '@salesforce/apex/DMS_PortalController.getStockMovements';

// 'Committed' = physically in stock but every unit is already promised to an
// unbilled order, so it cannot be sold again — warn rather than show it green.
const STATUS_THEME = {
    'In Stock': 'success', Low: 'warning', Reorder: 'danger',
    Out: 'danger', Committed: 'warning'
};
const ADJ_TYPES = [
    { label: 'Physical Count (enter the actual counted quantity)', value: 'Physical_Count' },
    { label: 'Damage', value: 'Damage' },
    { label: 'Expiry Write-Off', value: 'Expiry_Write_Off' },
    { label: 'Correction — Add stock', value: 'Correction_Add' },
    { label: 'Correction — Deduct stock', value: 'Correction_Deduct' }
];

export default class DistributorInventory extends LightningElement {
    activeTab = 'onhand';

    // Stock on hand
    summary;
    _rows = [];
    error;
    placing = false;
    expanded = {};
    _wired;

    // Movements
    movements = [];
    movementsError;
    _wiredMovements;

    // Adjust form
    adjProductId = '';
    adjProductName = '';
    adjBatch = '';
    adjType = '';
    adjQty = null;
    adjReason = '';
    submitting = false;
    adjError = '';

    // Catalogue product search. Sourced from the full product list rather than the
    // inventory rows: a product with no stock yet must still be selectable, or
    // opening stock can never be entered for it.
    productSearch = '';
    productResults = [];
    productLoading = false;
    _productTimer;

    // ── Wires ──────────────────────────────────────────────────────────────
    @wire(getInventorySummary)
    wired(result) {
        this._wired = result;
        const { data, error } = result;
        if (data) {
            this.summary = data;
            this._rows = data.rows || [];
            this.error = undefined;
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Unable to load inventory.';
        }
    }

    @wire(getStockMovements, { rowLimit: 100 })
    wiredMovements(result) {
        this._wiredMovements = result;
        const { data, error } = result;
        if (data) {
            this.movements = data.map((m, i) => ({
                key: i,
                dateLabel: this.fmtDateTime(m.txnDate),
                type: this.humanize(m.txnType),
                dir: m.direction,
                dirCls: 'dms-dir ' + (m.direction === 'In' ? 'dms-dir_in' : 'dms-dir_out'),
                dirSign: m.direction === 'In' ? '+' : '−',
                product: m.product,
                batch: m.batch || '—',
                qty: this.num(m.quantity),
                reference: this.humanize(m.reference)
            }));
            this.movementsError = undefined;
        } else if (error) {
            this.movementsError = (error.body && error.body.message) || 'Unable to load stock movements.';
        }
    }

    // ── Tabs ───────────────────────────────────────────────────────────────
    get isOnhand() { return this.activeTab === 'onhand'; }
    get isAdjust() { return this.activeTab === 'adjust'; }
    get isMovements() { return this.activeTab === 'movements'; }
    get onhandTabCls() { return this.tabCls('onhand'); }
    get adjustTabCls() { return this.tabCls('adjust'); }
    get movementsTabCls() { return this.tabCls('movements'); }
    tabCls(name) { return 'dms-tab' + (this.activeTab === name ? ' dms-tab_active' : ''); }
    showOnhand() { this.activeTab = 'onhand'; }
    showAdjust() { this.activeTab = 'adjust'; }
    showMovements() { this.activeTab = 'movements'; }

    // ── Stock on hand ──────────────────────────────────────────────────────
    get cards() {
        const s = this.summary || {};
        return [
            { id: 'k', label: 'SKUs in Stock', value: s.skuCount || 0, cls: 'dms-card__value' },
            { id: 'u', label: 'Total Units', value: this.num(s.totalUnits), cls: 'dms-card__value' },
            { id: 'v', label: 'Stock Value', value: this.inr(s.stockValue), cls: 'dms-card__value' },
            { id: 'e', label: 'Near-Expiry SKUs', value: s.nearExpirySkus || 0, cls: 'dms-card__value dms-card__value_amber' },
            { id: 'r', label: 'Below Reorder', value: s.belowReorderSkus || 0, cls: 'dms-card__value dms-card__value_red' }
        ];
    }

    get rows() {
        return (this._rows || []).map((r, i) => {
            const isExp = !!this.expanded[r.productId];
            const batches = r.batchDetail || [];
            return {
                ...r,
                key: i,
                statusTheme: STATUS_THEME[r.status] || 'neutral',
                // Flag the case that looks fine on paper but isn't: stock is on the
                // shelf, yet all of it is already promised to unbilled orders.
                availableClass: (r.committed > 0 && r.available <= 0)
                    ? 'dms-num dms-num_committed' : 'dms-num',
                expanded: isExp,
                caret: isExp ? '▾' : '▸',
                expandTitle: isExp ? 'Hide batches' : 'Show batches',
                hasBatches: batches.length > 0,
                batchRows: batches.map((b, j) => ({
                    key: j,
                    batchLabel: b.batchNo || '(no batch)',
                    qty: this.num(b.qty),
                    expiryLabel: b.expiryDate ? this.fmtDate(b.expiryDate) : '—',
                    nearExpiry: b.nearExpiry,
                    cls: 'dms-btrow' + (b.nearExpiry ? ' dms-btrow_warn' : '')
                }))
            };
        });
    }
    get hasRows() { return (this._rows || []).length > 0; }
    get canReplenishDisabled() { return !(this.summary && this.summary.belowReorderSkus > 0) || this.placing; }

    toggleExpand(e) {
        const id = e.currentTarget.dataset.id;
        this.expanded = { ...this.expanded, [id]: !this.expanded[id] };
    }

    async replenish() {
        this.placing = true;
        try {
            const id = await placeReplenishmentIndent();
            this.toast('Replenishment order created', `Draft order ${id} created for below-reorder products.`, 'success');
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Could not create order', this.msg(e), 'error');
        } finally {
            this.placing = false;
        }
    }

    // ── Adjust form ────────────────────────────────────────────────────────
    get adjTypeOptions() { return ADJ_TYPES; }
    get productOptions() {
        return (this._rows || []).map((r) => ({ label: r.name, value: r.productId }));
    }
    get selectedProduct() {
        return (this._rows || []).find((r) => r.productId === this.adjProductId) || null;
    }
    get batchOptions() {
        const p = this.selectedProduct;
        if (!p) { return []; }
        return (p.batchDetail || []).map((b) => ({
            label: (b.batchNo || '(no batch)') + '  •  ' + this.num(b.qty) + ' on hand'
                + (b.expiryDate ? '  •  exp ' + this.fmtDate(b.expiryDate) : ''),
            value: b.batchNo || ''
        }));
    }
    get hasBatchChoice() { return this.batchOptions.length > 0; }
    get selectedOnHand() {
        const p = this.selectedProduct;
        if (!p) { return 0; }
        const b = (p.batchDetail || []).find((x) => (x.batchNo || '') === (this.adjBatch || ''));
        return b ? b.qty : 0;
    }
    get isPhysical() { return this.adjType === 'Physical_Count'; }
    get qtyLabel() { return this.isPhysical ? 'Counted quantity' : 'Quantity'; }
    get qtyHint() {
        if (!this.adjType || !this.adjProductId) { return ''; }
        const oh = this.num(this.selectedOnHand);
        if (this.isPhysical) { return `System shows ${oh} on hand for this batch — enter the actual counted quantity.`; }
        if (this.adjType === 'Correction_Add') { return `Units to add to the ${oh} currently on hand.`; }
        return `Units to remove from the ${oh} currently on hand.`;
    }
    get submitDisabled() {
        return this.submitting || !this.adjProductId || !this.adjType
            || this.adjQty === null || this.adjQty === '' || !this.adjReason;
    }
    get noProducts() { return (this._rows || []).length === 0; }

    handleAdjProduct(e) {
        this.adjProductId = e.detail.value;
        this.adjBatch = '';
        this.adjError = '';
        // Preselect the sole / first (earliest-expiry) batch for convenience.
        const opts = this.batchOptions;
        if (opts.length) { this.adjBatch = opts[0].value; }
    }

    // ── Catalogue product search ──
    get showProductResults() {
        return this.productLoading || this.productResults.length > 0 || this.noProductMatches;
    }
    get noProductMatches() {
        return !this.productLoading && this.productSearch.length >= 2 && this.productResults.length === 0;
    }

    handleProductSearch(e) {
        this.productSearch = e.target.value || '';
        this.adjError = '';
        if (this._productTimer) { clearTimeout(this._productTimer); }
        if (this.productSearch.trim().length < 2) {
            this.productResults = [];
            this.productLoading = false;
            return;
        }
        this.productLoading = true;
        this._productTimer = setTimeout(() => this._runProductSearch(), 250);
    }

    async _runProductSearch() {
        try {
            const data = await getAdjustableProducts({ searchTerm: this.productSearch.trim() });
            this.productResults = (data || []).map((p) => ({
                ...p,
                onHandLabel: p.onHand > 0 ? `${this.num(p.onHand)} on hand` : 'no stock yet'
            }));
        } catch (err) {
            this.productResults = [];
            this.adjError = this.msg(err) || 'Could not search products.';
        } finally {
            this.productLoading = false;
        }
    }

    handlePickProduct(e) {
        const id = e.currentTarget.dataset.id;
        const picked = this.productResults.find((p) => p.productId === id);
        if (!picked) { return; }
        this.adjProductId = id;
        this.adjProductName = picked.name;
        this.productResults = [];
        this.productSearch = '';
        this.adjBatch = '';
        this.adjError = '';
        // Preselect the earliest-expiry batch when the product already has stock.
        const opts = this.batchOptions;
        if (opts.length) { this.adjBatch = opts[0].value; }
    }

    handleClearProduct() {
        this.adjProductId = '';
        this.adjProductName = '';
        this.adjBatch = '';
        this.productSearch = '';
        this.productResults = [];
    }
    handleAdjBatch(e) { this.adjBatch = e.detail.value; this.adjError = ''; }
    handleAdjType(e) { this.adjType = e.detail.value; this.adjError = ''; }
    handleAdjQty(e) { this.adjQty = e.detail.value; }
    handleAdjReason(e) { this.adjReason = e.detail.value; }

    async submitAdjustment() {
        this.adjError = '';
        if (!this.adjProductId) { this.adjError = 'Please choose a product.'; return; }
        if (!this.adjType) { this.adjError = 'Please choose an adjustment type.'; return; }
        const q = Number(this.adjQty);
        if (this.adjQty === null || this.adjQty === '' || isNaN(q) || q < 0) {
            this.adjError = 'Please enter a valid quantity.'; return;
        }
        if (!this.adjReason || !this.adjReason.trim()) { this.adjError = 'A reason is required.'; return; }

        this.submitting = true;
        try {
            await saveDistributorAdjustment({
                productId: this.adjProductId,
                batchNumber: this.adjBatch || null,
                adjustmentType: this.adjType,
                quantity: q,
                reason: this.adjReason
            });
            this.toast('Adjustment applied', 'Your stock on hand and the movement ledger have been updated.', 'success');
            this.resetAdjust();
            await Promise.all([refreshApex(this._wired), refreshApex(this._wiredMovements)]);
        } catch (e) {
            this.adjError = this.msg(e);
        } finally {
            this.submitting = false;
        }
    }

    resetAdjust() {
        this.adjProductId = '';
        this.adjProductName = '';
        this.productSearch = '';
        this.productResults = [];
        this.adjBatch = '';
        this.adjType = '';
        this.adjQty = null;
        this.adjReason = '';
    }

    // ── Movements ──────────────────────────────────────────────────────────
    get hasMovements() { return this.movements.length > 0; }

    // ── Helpers ────────────────────────────────────────────────────────────
    num(v) { return Number(v || 0).toLocaleString('en-IN'); }
    inr(v) { return '₹' + Number(v || 0).toLocaleString('en-IN'); }
    humanize(v) { return v ? String(v).replace(/_/g, ' ') : '—'; }
    fmtDate(d) {
        if (!d) { return ''; }
        return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(d));
    }
    fmtDateTime(d) {
        if (!d) { return ''; }
        return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(d));
    }
    msg(e) { return (e && e.body && e.body.message) || 'Unexpected error.'; }
    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}