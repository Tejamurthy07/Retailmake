import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getEInvoice from '@salesforce/apex/EInvoiceController.getEInvoice';
import generateEInvoice from '@salesforce/apex/EInvoiceController.generate';
import cancelEInvoice from '@salesforce/apex/EInvoiceController.cancel';

const CANCEL_REASONS = [
    { label: 'Duplicate', value: 'Duplicate' },
    { label: 'Data entry mistake', value: 'Data entry mistake' },
    { label: 'Order cancelled', value: 'Order cancelled' },
    { label: 'Others', value: 'Others' }
];

export default class EinvoicePanel extends LightningElement {
    @api recordId;
    view;
    error;
    busy = false;
    cancelOpen = false;
    cancelReason = 'Duplicate';
    cancelReasons = CANCEL_REASONS;
    _wired;

    @wire(getEInvoice, { invoiceId: '$recordId' })
    wiredEInvoice(result) {
        this._wired = result;
        if (result.data) {
            this.view = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = this.msg(result.error);
        }
    }

    get generated() { return this.view && this.view.generated; }
    get enabled() { return this.view && this.view.enabled; }
    get hasEway() { return this.view && this.view.ewbNo; }
    get statusPillClass() {
        const s = ((this.view && this.view.status) || '').toLowerCase();
        if (s === 'generated') return 'pill pill-green';
        if (s === 'cancelled') return 'pill pill-red';
        return 'pill pill-grey';
    }

    generate() {
        this.busy = true;
        generateEInvoice({ invoiceId: this.recordId })
            .then((r) => {
                if (r && r.success) {
                    this.toast('E-Invoice generated', 'IRN ' + (r.irn || '').substring(0, 16) + '…', 'success');
                } else {
                    this.toast('Not generated', (r && r.message) || 'See details', 'warning');
                }
                return refreshApex(this._wired);
            })
            .catch((e) => this.toast('Error', this.msg(e), 'error'))
            .finally(() => { this.busy = false; });
    }

    openCancel() { this.cancelOpen = true; }
    closeCancel() { this.cancelOpen = false; }
    handleReason(e) { this.cancelReason = e.detail.value; }
    doCancel() {
        this.busy = true;
        cancelEInvoice({ invoiceId: this.recordId, reason: this.cancelReason })
            .then(() => {
                this.toast('E-Invoice cancelled', '', 'success');
                this.cancelOpen = false;
                return refreshApex(this._wired);
            })
            .catch((e) => this.toast('Error', this.msg(e), 'error'))
            .finally(() => { this.busy = false; });
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    msg(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}