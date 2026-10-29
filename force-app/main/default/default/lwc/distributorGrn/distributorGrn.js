import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getGrns from '@salesforce/apex/DMS_PortalController.getGrns';
import getPendingGrnInvoices from '@salesforce/apex/DMS_PortalController.getPendingGrnInvoices';
import getGrnLines from '@salesforce/apex/DMS_PortalController.getGrnLines';
import createGrns from '@salesforce/apex/DMS_PortalController.createGrns';

export default class DistributorGrn extends LightningElement {
    grns = [];
    pendingInvoices = [];
    _wiredGrns;
    _wiredPending;
    error;

    // wizard
    wizardOpen = false;
    step = 1;
    selectedInvoiceIds = [];
    items = [];          // flat line list across selected invoices
    saving = false;
    wizardError;
    showSuccess = false;
    successInfo = {};

    // detail flyout
    detail;
    detailLines = [];

    @wire(getGrns)
    wiredGrns(result) {
        this._wiredGrns = result;
        if (result.data) {
            this.grns = result.data.map((g) => ({
                ...g,
                key: g.id,
                dateLabel: this.fmtDate(g.grnDate),
                skuLabel: `${g.skuCount} SKU${g.skuCount === 1 ? '' : 's'}`,
                qtyLabel: `${this.num(g.receivedQty)} / ${this.num(g.dispatchedQty)}`,
                theme: this.statusTheme(g.status),
                hasIssue: (g.damagedQty || 0) > 0 || (g.shortQty || 0) > 0,
                issueLabel: this.issueLabel(g)
            }));
        } else if (result.error) {
            this.error = this.msg(result.error);
        }
    }

    @wire(getPendingGrnInvoices)
    wiredPending(result) {
        // Keep the handle so a freshly generated dispatch shows without a reload,
        // and surface errors: this used to destructure { data } only, so an Apex
        // failure left the list silently empty with nothing to explain it.
        this._wiredPending = result;
        if (result.data) {
            this.pendingInvoices = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.pendingInvoices = [];
            this.error = this.msg(result.error);
        }
    }

    issueLabel(g) {
        const parts = [];
        if (g.shortQty > 0) { parts.push(`${this.num(g.shortQty)} short`); }
        if (g.damagedQty > 0) { parts.push(`${this.num(g.damagedQty)} damaged`); }
        return parts.join(' · ');
    }

    /* ── summary ── */
    get grnRows() { return this.grns; }
    get hasGrns() { return this.grns.length > 0; }
    get pendingCount() { return this.pendingInvoices.length; }
    get summary() {
        const received = this.grns.filter((g) => g.status === 'Received').length;
        return [
            { id: 'total', label: 'Total GRNs', value: String(this.grns.length), cls: 'dms-chip__value' },
            { id: 'done', label: 'Fully Received', value: String(received), cls: 'dms-chip__value dms-chip__value_done' },
            { id: 'partial', label: 'Partial / Short', value: String(this.grns.length - received), cls: 'dms-chip__value dms-chip__value_pending' }
        ];
    }

    /* ── wizard ── */
    openWizard() {
        this.wizardOpen = true;
        this.step = 1;
        this.selectedInvoiceIds = [];
        this.items = [];
        this.wizardError = undefined;
    }
    closeWizard() { this.wizardOpen = false; }
    get isStep1() { return this.step === 1; }
    get isStep2() { return this.step === 2; }
    get stepLabel() { return this.step === 1 ? 'Select Dispatches' : 'Confirm Received Quantities'; }
    get stepDots() {
        return [1, 2].map((n) => ({ n, class: n === this.step ? 'dms-step__dot dms-step__dot_active' : 'dms-step__dot' }));
    }
    get hasPending() { return this.pendingInvoices.length > 0; }

    get invoiceCards() {
        return this.pendingInvoices.map((inv) => {
            const selected = this.selectedInvoiceIds.includes(inv.id);
            return {
                ...inv,
                key: inv.id,
                amountLabel: this.money(inv.amount),
                metaLabel: `${this.fmtDate(inv.invoiceDate)} · ${inv.lines.length} SKUs · from ${inv.supplier}`,
                productsLabel: inv.lines.map((l) => l.name).join(', '),
                rowClass: selected ? 'dms-pick dms-pick_on' : 'dms-pick',
                boxClass: selected ? 'dms-check dms-check_on' : 'dms-check'
            };
        });
    }
    get selectedCountLabel() { return `${this.selectedInvoiceIds.length} selected`; }

    toggleInvoice(e) {
        const id = e.currentTarget.dataset.id;
        this.selectedInvoiceIds = this.selectedInvoiceIds.includes(id)
            ? this.selectedInvoiceIds.filter((x) => x !== id)
            : [...this.selectedInvoiceIds, id];
    }

    buildItems() {
        const items = [];
        this.pendingInvoices
            .filter((inv) => this.selectedInvoiceIds.includes(inv.id))
            .forEach((inv) => {
                (inv.lines || []).forEach((l, i) => {
                    items.push({
                        id: `${inv.id}__${i}`,
                        invoiceId: inv.id,
                        productId: l.productId,
                        name: l.name,
                        skuMeta: `${l.sku} · ${inv.invoiceNumber}`,
                        dispatched: Number(l.dispatchedQty || 0),
                        received: Number(l.dispatchedQty || 0),
                        damaged: 0,
                        batchNo: '',
                        expiryDate: ''
                    });
                });
            });
        this.items = items;
    }

    get itemRows() {
        return this.items.map((it) => {
            const shortQ = Math.max(0, it.dispatched - it.received);
            const flag = shortQ > 0 || it.damaged > 0;
            return {
                ...it,
                shortLabel: shortQ > 0 ? `${shortQ} short` : '',
                rowClass: flag ? 'dms-trow dms-trow_flag' : 'dms-trow'
            };
        });
    }

    handleReceived(e) { this.updateItem(e, 'received', true); }
    handleDamaged(e) { this.updateItem(e, 'damaged', true); }
    handleBatch(e) { this.updateItem(e, 'batchNo', false); }
    handleExpiry(e) { this.updateItem(e, 'expiryDate', false); }

    updateItem(e, field, numeric) {
        const id = e.currentTarget.dataset.id;
        let val = e.target.value;
        if (numeric) {
            val = parseInt(val, 10);
            if (Number.isNaN(val) || val < 0) { val = 0; }
        }
        this.items = this.items.map((it) => {
            if (it.id !== id) { return it; }
            const next = { ...it, [field]: val };
            if (field === 'received') { next.received = Math.min(val, it.dispatched); }
            if (field === 'damaged') { next.damaged = Math.min(val, next.received); }
            return next;
        });
    }

    get nextDisabled() {
        if (this.saving) { return true; }
        return this.step === 1 && this.selectedInvoiceIds.length === 0;
    }
    nextStep() {
        if (this.nextDisabled) { return; }
        if (this.step === 1) { this.buildItems(); this.step = 2; }
        else { this.saveGrn(); }
    }
    backStep() { if (this.step === 2) { this.step = 1; } else { this.closeWizard(); } }

    async saveGrn() {
        this.wizardError = undefined;
        // Group the flat item list back into one GRN per dispatch invoice.
        const byInvoice = {};
        this.items.forEach((it) => {
            if (!byInvoice[it.invoiceId]) { byInvoice[it.invoiceId] = []; }
            byInvoice[it.invoiceId].push({
                productId: it.productId,
                dispatchedQty: it.dispatched,
                receivedQty: it.received,
                damagedQty: it.damaged,
                batchNo: it.batchNo,
                expiryDate: it.expiryDate
            });
        });
        const payload = Object.keys(byInvoice).map((invoiceId) => ({ invoiceId, lines: byInvoice[invoiceId] }));

        this.saving = true;
        try {
            const res = await createGrns({ grnsJson: JSON.stringify(payload) });
            this.wizardOpen = false;
            this.successInfo = {
                count: res.grnCount || 0,
                returnCount: res.returnCount || 0,
                returnValue: res.returnValue || 0,
                refs: this.selectedOrderRefs()
            };
            this.showSuccess = true;
            await refreshApex(this._wiredGrns);
            this.dispatchEvent(new ShowToastEvent({
                title: 'GRN saved', message: 'Received stock posted to your inventory.', variant: 'success'
            }));
        } catch (e) {
            this.wizardError = this.msg(e);
        } finally {
            this.saving = false;
        }
    }
    selectedOrderRefs() {
        return this.pendingInvoices
            .filter((inv) => this.selectedInvoiceIds.includes(inv.id))
            .map((inv) => inv.invoiceNumber)
            .join(', ');
    }
    get successMessage() {
        const n = this.successInfo.count || 0;
        return `${n} GRN${n === 1 ? '' : 's'} recorded for ${this.successInfo.refs || ''}`;
    }
    get hasReturn() { return (this.successInfo.returnCount || 0) > 0; }
    get returnMessage() {
        const n = this.successInfo.returnCount || 0;
        return `Auto-created ${n} damaged-goods return${n === 1 ? '' : 's'} (${this.money(this.successInfo.returnValue)}) for company credit.`;
    }
    closeSuccess() { this.showSuccess = false; }

    /* ── GRN detail flyout ── */
    view(e) {
        const id = e.currentTarget.dataset.id;
        const row = this.grns.find((g) => g.id === id);
        if (!row) { return; }
        this.detail = row;
        this.detailLines = [];
        getGrnLines({ grnId: id })
            .then((data) => {
                this.detailLines = (data || []).map((l) => ({
                    id: l.Id,
                    name: l.Product_Ext__r ? l.Product_Ext__r.Name : '',
                    dispatched: this.num(l.Dispatched_Qty__c),
                    received: this.num(l.Received_Qty__c),
                    damaged: this.num(l.Damaged_Qty__c),
                    shortQ: this.num(l.Short_Qty__c),
                    batch: l.Batch_No__c || '—',
                    expiry: l.Expiry_Date__c ? this.fmtDate(l.Expiry_Date__c) : '—'
                }));
            })
            .catch(() => { this.detailLines = []; });
    }
    closeDetail() { this.detail = undefined; this.detailLines = []; }
    get hasDetailLines() { return this.detailLines.length > 0; }

    /* ── helpers ── */
    statusTheme(status) {
        const s = (status || '').toLowerCase();
        if (s.includes('received')) { return 'success'; }
        if (s.includes('partial') || s.includes('pending')) { return 'warning'; }
        if (s.includes('disput')) { return 'danger'; }
        return 'info';
    }
    fmtDate(d) {
        if (!d) { return ''; }
        return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(d));
    }
    money(v) { return '₹' + Math.round(Number(v || 0)).toLocaleString('en-IN'); }
    num(v) { return Number(v || 0).toLocaleString('en-IN'); }
    msg(e) { return (e && e.body && e.body.message) || 'Something went wrong. Please try again.'; }
}