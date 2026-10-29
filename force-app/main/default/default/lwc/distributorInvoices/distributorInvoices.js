import { LightningElement, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getInvoiceSummary from '@salesforce/apex/DMS_PortalController.getInvoiceSummary';
import getInvoiceLines from '@salesforce/apex/DMS_PortalController.getInvoiceLines';
import getCustomers from '@salesforce/apex/DMS_PortalController.getCustomers';
import getOpenSalesOrders from '@salesforce/apex/DMS_PortalController.getOpenSalesOrders';
import previewInvoiceFromOrders from '@salesforce/apex/DMS_PortalController.previewInvoiceFromOrders';
import createSecondaryInvoiceFromOrders from '@salesforce/apex/DMS_PortalController.createSecondaryInvoiceFromOrders';
import getEInvoiceDetail from '@salesforce/apex/DMS_PortalController.getEInvoiceDetail';
import generateEInvoice from '@salesforce/apex/DMS_PortalController.generateEInvoice';
import getDemoContext from '@salesforce/apex/DMS_PortalController.getDemoContext';
import createMockDispatch from '@salesforce/apex/DMS_PortalController.createMockDispatch';

const ALL = 'All';
const GRN_OPTIONS = [
    { label: 'All GRN Status', value: ALL },
    { label: 'GRN Done', value: 'done' },
    { label: 'GRN Not Done', value: 'notdone' }
];
const DATE_OPTIONS = [
    { label: 'All Dates', value: ALL },
    { label: 'This Month', value: 'this-month' },
    { label: 'Last Month', value: 'last-month' },
    { label: 'This Quarter', value: 'this-quarter' },
    { label: 'This Year', value: 'this-year' }
];
const TYPE_THEME = { Retailer: 'info', 'Sub-Dist.': 'purple' };
const STEP_LABELS = { 1: 'Select Customer', 2: 'Select Orders', 3: 'Review & Save' };

export default class DistributorInvoices extends LightningElement {
    activeTab = 'primary';
    grnFilter = ALL;
    grnOptions = GRN_OPTIONS;
    dateOptions = DATE_OPTIONS;
    dateFilter = ALL;

    primary = [];
    secondary = [];
    _wired;

    // Demo helper visibility (DMS-015, ships off).
    demoTools = false;
    mockBusy = false;
    // An internal user has no distributor of their own, so they must pick one.
    needsDistributor = false;
    distributorOptions = [];
    mockDistributorId = '';

    // wizard
    wizardOpen = false;
    step = 1;
    custType = 'Retailer';
    selectedCustomer = null;
    salesOrders = [];        // open SOs for the selected customer
    selectedOrderIds = [];   // chosen SO ids
    ordersLoading = false;
    billedByProduct = {};    // productId -> invoice qty
    orderedByProduct = {};   // productId -> ordered qty (max)
    preview = { lines: [], subtotal: 0, discount: 0, tax: 0, net: 0, freeTotal: 0 };
    previewLoading = false;
    _previewTimer;
    showSuccess = false;
    showSummaryText = '';
    saving = false;
    wizardError;

    customers = { Retailer: [], 'Sub-Distributor': [] };
    _custId = {};        // name -> Id

    @wire(getInvoiceSummary)
    wiredInv(result) {
        this._wired = result;
        const data = result.data;
        if (!data) { return; }
        this.primary = (data.rows || [])
            .filter((r) => r.orderType === 'Primary')
            .map((r) => ({
                id: r.invoiceNumber, key: r.id, rawDate: r.invoiceDate, date: this.fmtDate(r.invoiceDate),
                supplier: r.supplier, orderRef: '—', amountLabel: this.money(r.total),
                grnDone: r.grnDone, grnLabel: r.grnDone ? 'GRN Done' : 'GRN Not Done',
                grnClass: r.grnDone ? 'dms-grn dms-grn_done' : 'dms-grn dms-grn_pending',
                canGenEInv: false
            }));
        this.secondary = (data.rows || [])
            .filter((r) => r.orderType === 'Secondary')
            .map((r) => ({
                id: r.invoiceNumber, key: r.id, rawDate: r.invoiceDate, date: this.fmtDate(r.invoiceDate),
                customer: r.party, type: r.customerType, typeTheme: TYPE_THEME[r.customerType] || 'neutral',
                orderRef: r.orderRef || '—', amountLabel: this.money(r.total),
                statusLabel: r.status, statusTheme: r.overdue ? 'danger' : undefined,
                canGenEInv: r.canGenerateEInvoice,
                eInvStatus: r.eInvoiceStatus,
                eInvClass: this.eInvClass(r.eInvoiceStatus)
            }));
    }

    eInvClass(status) {
        if (status === 'Generated') return 'dms-einv dms-einv_gen';
        if (status === 'Cancelled') return 'dms-einv dms-einv_cancel';
        return 'dms-einv dms-einv_none';
    }

    /* date period filter */
    inRange(rawDate) {
        if (this.dateFilter === ALL || !rawDate) { return true; }
        const d = new Date(rawDate);
        const now = new Date();
        const y = now.getFullYear();
        const m = now.getMonth();
        if (this.dateFilter === 'this-month') { return d.getFullYear() === y && d.getMonth() === m; }
        if (this.dateFilter === 'last-month') {
            const lm = new Date(y, m - 1, 1);
            return d.getFullYear() === lm.getFullYear() && d.getMonth() === lm.getMonth();
        }
        if (this.dateFilter === 'this-quarter') {
            const q = Math.floor(m / 3);
            return d.getFullYear() === y && Math.floor(d.getMonth() / 3) === q;
        }
        if (this.dateFilter === 'this-year') { return d.getFullYear() === y; }
        return true;
    }

    @wire(getCustomers)
    wiredCustomers({ data }) {
        if (data) {
            const ret = [];
            const sub = [];
            data.forEach((c) => {
                this._custId[c.name] = c.id;
                const row = { name: c.name, type: c.custType || 'Retailer' };
                if (c.custType === 'Sub-Distributor') { sub.push(row); } else { ret.push(row); }
            });
            this.customers = { Retailer: ret, 'Sub-Distributor': sub };
        }
    }

    /* tabs */
    get subTabs() {
        return [
            { id: 'primary', label: 'Primary Invoices' },
            { id: 'secondary', label: 'Secondary Invoices' }
        ].map((t) => ({ ...t, class: t.id === this.activeTab ? 'dms-subtab dms-subtab_active' : 'dms-subtab' }));
    }
    get isPrimary() { return this.activeTab === 'primary'; }
    get isSecondary() { return this.activeTab === 'secondary'; }
    handleTab(e) { this.activeTab = e.currentTarget.dataset.tab; }
    handleGrnFilter(e) { this.grnFilter = e.detail.value; }
    handleDateFilter(e) { this.dateFilter = e.detail.value; }

    /* primary */
    get primaryInvoices() {
        return this.primary.filter(
            (i) =>
                (this.grnFilter === ALL || (this.grnFilter === 'done' ? i.grnDone : !i.grnDone)) &&
                this.inRange(i.rawDate)
        );
    }
    get primarySummary() {
        const done = this.primary.filter((i) => i.grnDone).length;
        return [
            { id: 'total', label: 'Total Primary Invoices', value: this.primary.length, cls: 'dms-chip__value' },
            { id: 'done', label: 'GRN Done', value: done, cls: 'dms-chip__value dms-chip__value_done' },
            { id: 'notdone', label: 'GRN Not Done', value: this.primary.length - done, cls: 'dms-chip__value dms-chip__value_pending' }
        ];
    }

    /* secondary */
    get secondaryInvoices() { return this.secondary.filter((i) => this.inRange(i.rawDate)); }

    /* ── line-item detail flyout (View / PDF action) ── */
    detail;
    detailLines = [];
    einv = { generated: false };
    einvBusy = false;
    einvMsg;
    einvMsgOk = false;
    view(e) {
        const id = e.currentTarget.dataset.id;
        const row = [...this.primary, ...this.secondary].find((r) => r.key === id);
        if (!row) { return; }
        this.detail = { key: id, number: row.id, party: row.customer || row.supplier, amount: row.amountLabel, canGen: row.canGenEInv };
        this.detailLines = [];
        this.einv = { generated: false };
        this.einvMsg = undefined;
        getInvoiceLines({ invoiceId: id })
            .then((data) => {
                this.detailLines = (data || []).map((l) => ({
                    ...l,
                    productName: l.Product_Ext__r ? l.Product_Ext__r.Name : '',
                    rate: this.money(l.Unit_Price__c),
                    amount: this.money(l.Total_Amount__c)
                }));
            })
            .catch(() => { this.detailLines = []; });
        this.loadEInvoice(id);
    }
    loadEInvoice(id) {
        getEInvoiceDetail({ invoiceId: id })
            .then((v) => { this.einv = v || { generated: false }; })
            .catch((e) => {
                // Surface the failure — don't let it look like "no e-invoice registered".
                this.einv = { generated: false };
                this.einvMsgOk = false;
                this.einvMsg = this.msg(e);
            });
    }
    genEInvoice(e) {
        const id = e.currentTarget.dataset.id;
        this.einvBusy = true;
        this.einvMsg = undefined;
        generateEInvoice({ invoiceId: id })
            .then((r) => {
                if (r && r.success) {
                    this.einvMsgOk = true;
                    this.einvMsg = 'E-Invoice generated · IRN ' + (r.irn || '').substring(0, 20) + '…';
                    this.toast('E-Invoice generated', 'IRN ' + (r.irn || '').substring(0, 16) + '…', 'success');
                } else {
                    this.einvMsgOk = false;
                    this.einvMsg = (r && r.message) || 'Could not generate the e-invoice.';
                    this.toast('Not generated', this.einvMsg, 'warning');
                }
                return refreshApex(this._wired);
            })
            .then(() => { if (this.detail && this.detail.key === id) { this.loadEInvoice(id); } })
            .catch((err) => {
                this.einvMsgOk = false;
                this.einvMsg = this.msg(err);
                this.toast('Error', this.msg(err), 'error');
            })
            .finally(() => { this.einvBusy = false; });
    }
    openPdf(e) {
        const id = e.currentTarget.dataset.id;
        // Open the Visualforce invoice PDF (renderAs=pdf) in a new tab.
        window.open('/apex/InvoicePDF?id=' + id, '_blank');
    }
    get einvMsgClass() {
        return this.einvMsgOk ? 'dms-einv-msg dms-einv-msg_ok' : 'dms-einv-msg dms-einv-msg_err';
    }
    closeDetail() { this.detail = undefined; this.detailLines = []; this.einv = { generated: false }; this.einvMsg = undefined; }
    get hasDetailLines() { return this.detailLines.length > 0; }
    get detailCanGen() { return this.detail && this.detail.canGen && !(this.einv && this.einv.generated); }
    get einvGenerated() { return this.einv && this.einv.generated; }
    get einvHasEway() { return this.einv && this.einv.ewbNo; }
    get einvPillClass() {
        const s = ((this.einv && this.einv.status) || '').toLowerCase();
        if (s === 'generated') return 'dms-einv dms-einv_gen';
        if (s === 'cancelled') return 'dms-einv dms-einv_cancel';
        return 'dms-einv dms-einv_none';
    }
    @wire(getDemoContext)
    wiredDemoCtx({ data }) {
        if (!data) { return; }
        this.demoTools = data.enabled === true;
        this.needsDistributor = data.needsDistributor === true;
        this.distributorOptions = data.distributors || [];
        // Only one distributor to choose from — choose it for them.
        if (this.needsDistributor && this.distributorOptions.length === 1) {
            this.mockDistributorId = this.distributorOptions[0].value;
        }
    }

    handleMockDistributor(e) {
        this.mockDistributorId = e.detail.value;
    }

    get mockDisabled() {
        return this.mockBusy || (this.needsDistributor && !this.mockDistributorId);
    }

    /**
     * Demo only. Raises and dispatches a mock primary order through the real
     * fulfilment path, so a genuine primary invoice appears here and becomes
     * receivable on the GRN screen.
     */
    async handleMockDispatch() {
        this.mockBusy = true;
        try {
            const summary = await createMockDispatch({
                distributorId: this.mockDistributorId || null
            });
            this.toast('Mock dispatch created', summary, 'success');
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Could not create mock dispatch', this.msg(e), 'error');
        } finally {
            this.mockBusy = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    msg(e) { return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error'; }
    get secondarySummary() {
        const total = this.secondary.reduce((s, i) => s + this.unmoney(i.amountLabel), 0);
        const ret = this.secondary.filter((i) => i.type === 'Retailer').length;
        return [
            { id: 'total', label: 'Total Invoices', value: String(this.secondary.length), cls: 'dms-chip__value' },
            { id: 'value', label: 'Total Value', value: this.money(total), cls: 'dms-chip__value' },
            { id: 'ret', label: 'Retailers', value: String(ret), cls: 'dms-chip__value dms-chip__value_info' },
            { id: 'sub', label: 'Sub-Distributors', value: String(this.secondary.length - ret), cls: 'dms-chip__value dms-chip__value_purple' }
        ];
    }

    /* wizard */
    openWizard() {
        this.wizardOpen = true; this.step = 1; this.custType = 'Retailer';
        this.selectedCustomer = null; this.salesOrders = []; this.selectedOrderIds = [];
        this.billedByProduct = {}; this.orderedByProduct = {};
        this.preview = { lines: [], subtotal: 0, discount: 0, tax: 0, net: 0, freeTotal: 0 };
        this.wizardError = undefined;
    }
    closeWizard() { this.wizardOpen = false; }
    get stepLabel() { return STEP_LABELS[this.step]; }
    get isStep1() { return this.step === 1; }
    get isStep2() { return this.step === 2; }
    get isStep3() { return this.step === 3; }
    get stepDots() { return [1, 2, 3].map((n) => ({ n, class: n === this.step ? 'dms-step__dot dms-step__dot_active' : 'dms-step__dot' })); }

    get custTypeButtons() {
        return ['Retailer', 'Sub-Distributor'].map((t) => ({ type: t, class: t === this.custType ? 'dms-seg dms-seg_active' : 'dms-seg' }));
    }
    get customerList() {
        const list = this.customers[this.custType] || [];
        return list.map((c) => ({
            ...c, typeTheme: TYPE_THEME[c.type] || 'neutral',
            class: this.selectedCustomer === c.name ? 'dms-custrow dms-custrow_selected' : 'dms-custrow'
        }));
    }
    get hasCustomers() { return this.customerList.length > 0; }
    get emptyCustomerMsg() {
        return this.custType === 'Sub-Distributor'
            ? 'No sub-distributors are linked to your account.'
            : 'No retailers are linked to your account yet. Retailers appear here once their Parent Account is set to your distributor (or they share your territory).';
    }
    setCustType(e) { this.custType = e.currentTarget.dataset.type; this.selectedCustomer = null; this.selectedOrderIds = []; }
    selectCustomer(e) { this.selectedCustomer = e.currentTarget.dataset.name; this.selectedOrderIds = []; }

    // step 2: the retailer's open (uninvoiced) sales orders
    async loadSalesOrders() {
        const customerId = this._custId[this.selectedCustomer];
        this.ordersLoading = true;
        this.salesOrders = [];
        this.selectedOrderIds = [];
        try {
            const data = await getOpenSalesOrders({ customerId });
            this.salesOrders = (data || []).map((o) => ({
                ...o,
                dateLabel: this.fmtDate(o.orderDate),
                amountLabel: this.money(o.amount),
                countLabel: `${o.productCount} product${o.productCount === 1 ? '' : 's'}`
            }));
        } catch (e) {
            this.wizardError = (e && e.body && e.body.message) || 'Could not load sales orders.';
        } finally {
            this.ordersLoading = false;
        }
    }
    get orderList() {
        return this.salesOrders.map((o) => {
            const selected = this.selectedOrderIds.includes(o.id);
            return {
                ...o, key: o.id,
                rowClass: selected ? 'dms-ordrow dms-ordrow_selected' : 'dms-ordrow',
                boxClass: selected ? 'dms-check dms-check_on' : 'dms-check'
            };
        });
    }
    get hasOrders() { return this.salesOrders.length > 0; }
    get selectedCountLabel() { return `${this.selectedOrderIds.length} selected`; }
    toggleOrder(e) {
        const id = e.currentTarget.dataset.id;
        this.selectedOrderIds = this.selectedOrderIds.includes(id)
            ? this.selectedOrderIds.filter((x) => x !== id)
            : [...this.selectedOrderIds, id];
    }

    // Seed billed = ordered from the selected orders, then fetch the exact
    // invoice preview from the server (same computation as the create path).
    enterReview() {
        const ordered = {};
        this.salesOrders
            .filter((o) => this.selectedOrderIds.includes(o.id))
            .forEach((o) => {
                (o.lines || []).forEach((l) => {
                    if (!l.productId) { return; }
                    ordered[l.productId] = (ordered[l.productId] || 0) + Number(l.qty || 0);
                });
            });
        this.orderedByProduct = ordered;
        this.billedByProduct = { ...ordered };
        this.refreshPreview();
    }

    _billedLines() {
        return Object.keys(this.billedByProduct)
            .filter((pid) => this.billedByProduct[pid] > 0)
            .map((pid) => ({ productId: pid, quantity: this.billedByProduct[pid] }));
    }

    async refreshPreview() {
        this.previewLoading = true;
        try {
            const data = await previewInvoiceFromOrders({
                salesOrderIdsJson: JSON.stringify(this.selectedOrderIds),
                linesJson: JSON.stringify(this._billedLines())
            });
            this.preview = data || { lines: [], subtotal: 0, discount: 0, tax: 0, net: 0, freeTotal: 0 };
        } catch (e) {
            this.wizardError = (e && e.body && e.body.message) || 'Could not calculate the invoice.';
        } finally {
            this.previewLoading = false;
        }
    }

    get reviewRows() {
        return (this.preview.lines || []).map((l) => ({
            key: l.productId,
            productId: l.productId,
            name: l.productName,
            ordered: l.ordered,
            qty: this.billedByProduct[l.productId] != null ? this.billedByProduct[l.productId] : l.qty,
            rateLabel: this.money(l.unitPrice) + '/unit',
            discLabel: l.discount > 0 ? '−' + this.money(l.discount) : '—',
            taxLabel: this.money(l.tax),
            amountLabel: this.money(l.net)
        }));
    }
    get subtotalLabel() { return this.money(this.preview.subtotal); }
    get discountLabel() { return '−' + this.money(this.preview.discount); }
    get taxLabel() { return this.money(this.preview.tax); }
    get invoiceTotalLabel() { return this.money(this.preview.net); }
    get hasPreviewDiscount() { return this.preview.discount > 0; }
    get hasPreviewFree() { return this.preview.freeTotal > 0; }
    get freeGoodsLabel() { return `${this.preview.freeTotal} free unit${this.preview.freeTotal === 1 ? '' : 's'}`; }

    get selectedOrders() { return this.salesOrders.filter((o) => this.selectedOrderIds.includes(o.id)); }
    get selectedOrdersLabel() { return this.selectedOrders.map((o) => o.name).join(', '); }
    get selectedOrdersHeading() {
        const n = this.selectedOrderIds.length;
        return `Billing ${n} order${n === 1 ? '' : 's'} into 1 invoice`;
    }
    handleQty(e) {
        const pid = e.currentTarget.dataset.id;
        let val = parseInt(e.target.value, 10);
        if (Number.isNaN(val) || val < 0) { val = 0; }
        const max = this.orderedByProduct[pid] || 0;
        this.billedByProduct = { ...this.billedByProduct, [pid]: Math.min(val, max) };
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        clearTimeout(this._previewTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._previewTimer = setTimeout(() => this.refreshPreview(), 250);
    }

    get nextDisabled() {
        if (this.saving) { return true; }
        if (this.step === 1) { return !this.selectedCustomer; }
        if (this.step === 2) { return this.selectedOrderIds.length === 0; }
        return false;
    }
    nextStep() {
        if (this.nextDisabled) { return; }
        if (this.step === 1) { this.step = 2; this.wizardError = undefined; this.loadSalesOrders(); }
        else if (this.step === 2) { this.enterReview(); this.step = 3; }
        else { this.generateInvoice(); }
    }
    backStep() { if (this.step > 1) { this.step -= 1; } else { this.closeWizard(); } }

    async generateInvoice() {
        this.wizardError = undefined;
        const retailerId = this._custId[this.selectedCustomer];
        const lines = this._billedLines();
        if (!retailerId) { this.wizardError = 'Select a customer before generating the invoice.'; return; }
        if (lines.length === 0) { this.wizardError = 'Set a quantity on at least one line.'; return; }

        this.saving = true;
        try {
            await createSecondaryInvoiceFromOrders({
                retailerId,
                linesJson: JSON.stringify(lines),
                salesOrderIdsJson: JSON.stringify(this.selectedOrderIds)
            });
            this.showSummaryText = `${this.selectedOrderIds.length} order(s) · ${lines.length} products · ${this.invoiceTotalLabel}`;
            this.wizardOpen = false;
            this.showSuccess = true;
            await refreshApex(this._wired);
        } catch (e) {
            // Show inline (always visible) AND toast.
            this.wizardError = (e && e.body && e.body.message) || 'Unexpected error generating the invoice.';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not generate invoice', message: this.wizardError, variant: 'error'
            }));
        } finally {
            this.saving = false;
        }
    }
    get successSummary() { return this.showSummaryText; }
    handleDone() { this.showSuccess = false; }

    /* helpers */
    fmtDate(d) {
        if (!d) { return ''; }
        const dt = new Date(d);
        return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(dt);
    }
    money(v) { return '₹' + Math.round(Number(v || 0)).toLocaleString('en-IN'); }
    unmoney(s) { return Number(String(s).replace(/[^0-9.]/g, '')) || 0; }
}