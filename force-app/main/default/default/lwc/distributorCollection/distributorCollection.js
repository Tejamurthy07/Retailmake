import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCollections from '@salesforce/apex/DMS_PortalController.getCollections';
import getCollectibleInvoices from '@salesforce/apex/DMS_PortalController.getCollectibleInvoices';
import recordCollection from '@salesforce/apex/DMS_PortalController.recordCollection';

const MODES = ['Cash', 'Cheque', 'UPI', 'NEFT', 'RTGS', 'Online'];
const MODE_THEME = { Cash: 'success', Cheque: 'info', UPI: 'info', NEFT: 'info', RTGS: 'info', Online: 'info' };
const REF_LABEL = {
    Cheque: 'Cheque Number', UPI: 'UPI Reference', NEFT: 'Reference No.',
    RTGS: 'Reference No.', Online: 'Transaction Ref'
};

export default class DistributorCollection extends LightningElement {
    all = [];
    wiredCollections;
    invoices = [];
    wiredInvoices;
    search = '';

    // record modal
    modalOpen = false;
    formInvoice = '';
    formAmount = '';
    formMode = 'Cash';
    formRef = '';
    submitting = false;

    // detail modal
    detailOpen = false;
    selected = null;

    @wire(getCollections)
    wiredC(result) {
        this.wiredCollections = result;
        if (result.data) { this.all = result.data; }
    }

    @wire(getCollectibleInvoices)
    wiredInv(result) {
        this.wiredInvoices = result;
        if (result.data) { this.invoices = result.data; }
    }

    handleSearch(e) { this.search = e.target.value; }

    openDetail(e) {
        const id = e.currentTarget.dataset.id;
        this.selected = this.rows.find((r) => r.id === id) || null;
        this.detailOpen = !!this.selected;
    }
    closeDetail() { this.detailOpen = false; this.selected = null; }

    get rows() {
        const key = (this.search || '').toLowerCase();
        return this.all
            .filter((c) => !key
                || (c.name || '').toLowerCase().includes(key)
                || (c.payer || '').toLowerCase().includes(key)
                || (c.invoiceNumber || '').toLowerCase().includes(key))
            .map((c) => ({ ...c, key: c.id, modeTheme: MODE_THEME[c.paymentMode] || 'neutral' }));
    }
    get hasRows() { return this.rows.length > 0; }

    get summary() {
        const total = this.all.reduce((s, c) => s + (Number(c.amount) || 0), 0);
        const outstanding = this.invoices.reduce((s, i) => s + (Number(i.balanceDue) || 0), 0);
        return [
            { id: 'e', label: 'Collections', value: String(this.all.length), cls: 'dms-card__value' },
            { id: 'a', label: 'Total Collected', value: this.inr(total), cls: 'dms-card__value dms-card__value_green' },
            { id: 'o', label: 'Open Invoices', value: String(this.invoices.length), cls: 'dms-card__value' },
            { id: 'ob', label: 'Outstanding', value: this.inr(outstanding), cls: 'dms-card__value dms-card__value_amber' }
        ];
    }

    // ── record modal ──────────────────────────────────────────────────────
    get invoiceOptions() {
        const opts = [{ label: 'On account (no invoice)', value: '' }];
        this.invoices.forEach((i) => {
            opts.push({
                label: `${i.invoiceNumber || i.id}${i.party ? ' · ' + i.party : ''} · Bal ${this.inr(i.balanceDue)}`,
                value: i.id
            });
        });
        return opts;
    }
    get modeButtons() {
        return MODES.map((m) => ({ mode: m, class: m === this.formMode ? 'dms-seg dms-seg_active' : 'dms-seg' }));
    }
    get showRefField() { return this.formMode !== 'Cash'; }
    get refLabel() { return REF_LABEL[this.formMode] || 'Reference'; }
    get saveDisabled() { return !(Number(this.formAmount) > 0) || this.submitting; }

    openModal() {
        this.modalOpen = true;
        this.formInvoice = '';
        this.formAmount = '';
        this.formMode = 'Cash';
        this.formRef = '';
    }
    closeModal() { this.modalOpen = false; }
    handleInvoice(e) { this.formInvoice = e.detail.value; }
    handleAmount(e) { this.formAmount = e.target.value; }
    setMode(e) { this.formMode = e.currentTarget.dataset.mode; this.formRef = ''; }
    handleRef(e) { this.formRef = e.target.value; }

    async save() {
        this.submitting = true;
        try {
            await recordCollection({
                invoiceId: this.formInvoice || null,
                amount: Number(this.formAmount),
                paymentMode: this.formMode,
                reference: this.formRef
            });
            this.toast('Collection recorded', 'The payment was recorded.', 'success');
            this.modalOpen = false;
            await Promise.all([refreshApex(this.wiredCollections), refreshApex(this.wiredInvoices)]);
        } catch (e) {
            this.toast('Could not record collection', this.msg(e), 'error');
        } finally {
            this.submitting = false;
        }
    }

    inr(v) { return '₹' + Number(v || 0).toLocaleString('en-IN'); }
    msg(e) { return (e && e.body && e.body.message) || 'Unexpected error.'; }
    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}