import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getReturns from '@salesforce/apex/DMS_PortalController.getReturns';
import getReturnableInvoices from '@salesforce/apex/DMS_PortalController.getReturnableInvoices';
import getReturnLines from '@salesforce/apex/DMS_PortalController.getReturnLines';
import placeReturn from '@salesforce/apex/DMS_PortalController.placeReturn';

const ALL = 'All';
// Must match the Return_Order__c.Return_Reason__c restricted picklist.
const REASONS = ['Damaged', 'Expired', 'Wrong Delivery', 'Quality Issue', 'Other'];
const STATUS_OPTIONS = ['All', 'Draft', 'Submitted', 'Approved', 'Rejected', 'Cancelled'].map(
    (s) => ({ label: s === ALL ? 'All Status' : s, value: s })
);

export default class DistributorReturns extends LightningElement {
    activeTab = 'Primary';
    statusFilter = ALL;
    statusOptions = STATUS_OPTIONS;
    all = [];
    wiredReturns;
    invoices = [];

    // create wizard
    wizardOpen = false;
    step = 1;
    selectedInvoiceId = null;
    items = [];
    submitting = false;

    // detail modal
    detailOpen = false;
    selected = null;
    detailLines = [];

    @wire(getReturns)
    wiredR(result) {
        this.wiredReturns = result;
        if (result.data) { this.all = result.data; }
    }

    @wire(getReturnableInvoices)
    wiredInv({ data }) {
        if (data) { this.invoices = data; }
    }

    // ── list ──────────────────────────────────────────────────────────────
    get subTabs() {
        return [
            { id: 'Primary', label: 'Primary Returns' },
            { id: 'Secondary', label: 'Secondary Returns' }
        ].map((t) => ({
            ...t,
            class: t.id === this.activeTab ? 'dms-subtab dms-subtab_active' : 'dms-subtab'
        }));
    }
    handleTab(e) { this.activeTab = e.currentTarget.dataset.tab; this.statusFilter = ALL; }
    handleStatus(e) { this.statusFilter = e.detail.value; }

    // ── detail modal ──────────────────────────────────────────────────────
    async openDetail(e) {
        const id = e.currentTarget.dataset.id;
        const row = this.all.find((r) => r.id === id);
        if (!row) { return; }
        this.selected = row;
        this.detailLines = [];
        this.detailOpen = true;
        try {
            const lines = await getReturnLines({ returnId: id });
            this.detailLines = (lines || []).map((l, i) => ({ ...l, key: i }));
        } catch (err) {
            this.toast('Could not load return', this.msg(err), 'error');
        }
    }
    closeDetail() { this.detailOpen = false; this.selected = null; this.detailLines = []; }
    get hasDetailLines() { return this.detailLines && this.detailLines.length > 0; }

    get tabReturns() {
        return this.all.filter((r) => (r.returnType || 'Primary') === this.activeTab);
    }
    get rows() {
        return this.tabReturns
            .filter((r) => this.statusFilter === ALL || r.status === this.statusFilter)
            .map((r) => ({ ...r, key: r.id }));
    }
    get hasRows() { return this.rows.length > 0; }
    // Only PRIMARY returns (distributor -> company) are raised from the portal.
    // Secondary returns (retailer -> distributor) are created in the field/SFA flow
    // and are view-only here.
    get canCreate() { return this.activeTab === 'Primary'; }

    get summary() {
        const list = this.tabReturns;
        const count = (s) => list.filter((r) => r.status === s).length;
        const pending = list.filter((r) => r.status === 'Draft' || r.status === 'Submitted').length;
        return [
            { id: 't', label: 'Total Returns', value: list.length, cls: 'dms-card__value' },
            { id: 'a', label: 'Approved', value: count('Approved'), cls: 'dms-card__value dms-card__value_green' },
            { id: 'p', label: 'Pending', value: pending, cls: 'dms-card__value dms-card__value_amber' },
            { id: 'r', label: 'Rejected', value: count('Rejected'), cls: 'dms-card__value dms-card__value_red' }
        ];
    }

    // ── wizard ────────────────────────────────────────────────────────────
    get isStep1() { return this.step === 1; }
    get isStep2() { return this.step === 2; }
    get stepLabel() { return this.step === 1 ? 'Select Invoice' : 'Return Quantity & Reason'; }
    get stepDots() {
        return [1, 2].map((n) => ({
            n,
            class: n === this.step ? 'dms-step__dot dms-step__dot_active' : 'dms-step__dot'
        }));
    }
    get invoiceCards() {
        // Portal returns are PRIMARY only — offer primary/P2 invoices (billed to the
        // distributor), never the distributor's own secondary (retailer) invoices.
        return this.invoices
            .filter((inv) => (inv.orderType || '') !== 'Secondary')
            .map((inv) => {
            const on = inv.id === this.selectedInvoiceId;
            return {
                ...inv,
                key: inv.id,
                metaLabel: `${inv.orderType || 'Invoice'} · ${inv.lines ? inv.lines.length : 0} products`,
                productsLabel: (inv.lines || []).map((l) => l.productName).filter(Boolean).join(', '),
                rowClass: on ? 'dms-pick dms-pick_on' : 'dms-pick',
                radioClass: on ? 'dms-radio dms-radio_on' : 'dms-radio'
            };
        });
    }
    get totalReturnQty() { return this.items.reduce((s, it) => s + (Number(it.returnQty) || 0), 0); }
    get nextDisabled() {
        if (this.step === 1) { return !this.selectedInvoiceId; }
        return this.totalReturnQty <= 0 || this.submitting;
    }

    openWizard() {
        this.wizardOpen = true;
        this.step = 1;
        this.selectedInvoiceId = null;
        this.items = [];
    }
    closeWizard() { this.wizardOpen = false; }
    selectInvoice(e) { this.selectedInvoiceId = e.currentTarget.dataset.id; }

    buildItems() {
        const inv = this.invoices.find((i) => i.id === this.selectedInvoiceId);
        this.items = (inv ? inv.lines : []).map((l, idx) => ({
            id: `i${idx}`, productId: l.productId, name: l.productName,
            batch: l.batch, delivered: l.quantity, returnQty: 0, reason: 'Damaged'
        }));
    }

    // Per-line rows with a pre-selected reason (native <select> needs `selected`).
    get itemRows() {
        return this.items.map((it) => ({
            ...it,
            options: REASONS.map((r) => ({ label: r, value: r, selected: r === it.reason }))
        }));
    }
    handleItemReason(e) {
        const id = e.currentTarget.dataset.id;
        const reason = e.target.value;
        this.items = this.items.map((it) => (it.id === id ? { ...it, reason } : it));
    }
    handleReturnQty(e) {
        const id = e.currentTarget.dataset.id;
        let v = Number(e.target.value);
        this.items = this.items.map((it) => {
            if (it.id !== id) { return it; }
            if (Number.isNaN(v) || v < 0) { v = 0; }
            if (it.delivered != null && v > it.delivered) { v = it.delivered; }
            return { ...it, returnQty: v };
        });
    }

    nextStep() {
        if (this.nextDisabled) { return; }
        if (this.step === 1) { this.buildItems(); this.step = 2; }
        else { this.save(); }
    }
    backStep() {
        if (this.step === 2) { this.step = 1; } else { this.closeWizard(); }
    }

    async save() {
        this.submitting = true;
        try {
            const returned = this.items.filter((it) => Number(it.returnQty) > 0);
            const lines = returned.map((it) => ({
                productId: it.productId, batch: it.batch, quantity: Number(it.returnQty), reason: it.reason
            }));
            const headerReason = (returned[0] && returned[0].reason) || 'Damaged';
            await placeReturn({
                invoiceId: this.selectedInvoiceId,
                linesJson: JSON.stringify(lines),
                reason: headerReason
            });
            this.toast('Return raised', 'Your return was submitted for approval.', 'success');
            this.wizardOpen = false;
            await refreshApex(this.wiredReturns);
        } catch (e) {
            this.toast('Could not raise return', this.msg(e), 'error');
        } finally {
            this.submitting = false;
        }
    }

    msg(e) { return (e && e.body && e.body.message) || 'Unexpected error.'; }
    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}