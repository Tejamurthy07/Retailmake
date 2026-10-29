import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSupplier from '@salesforce/apex/DMS_PortalController.getSupplier';
import getProducts from '@salesforce/apex/DMS_PortalController.getProducts';
import placeP2Order from '@salesforce/apex/DMS_PortalController.placeP2Order';

const LINE_COLUMNS = [
    { label: 'Product', fieldName: 'productName' },
    { label: 'Quantity', fieldName: 'quantity', type: 'number', cellAttributes: { alignment: 'left' } },
    {
        type: 'button-icon',
        fixedWidth: 50,
        typeAttributes: { iconName: 'utility:delete', name: 'remove', variant: 'bare', alternativeText: 'Remove' }
    }
];

export default class DistributorP2Order extends LightningElement {
    supplier;
    productId;
    quantity;
    productOptions = [];
    productNameById = {};
    @track lines = [];
    columns = LINE_COLUMNS;
    submitting = false;

    @wire(getSupplier)
    wiredSupplier({ data, error }) {
        if (data) {
            this.supplier = data;
        } else if (error) {
            this.toast('Error', this.msg(error), 'error');
        }
    }

    @wire(getProducts)
    wiredProducts({ data, error }) {
        if (data) {
            this.productOptions = data.map((p) => ({
                label: p.Unit_Price__c ? `${p.Name} — ₹${p.Unit_Price__c}` : p.Name,
                value: p.Id
            }));
            this.productNameById = {};
            data.forEach((p) => {
                this.productNameById[p.Id] = p.Name;
            });
        } else if (error) {
            this.toast('Error', this.msg(error), 'error');
        }
    }

    get hasSupplier() {
        return this.supplier && this.supplier.canOrder;
    }
    get supplierName() {
        return this.supplier ? this.supplier.supplierName : '';
    }

    handleProduct(e) { this.productId = e.detail.value; }
    handleQty(e) { this.quantity = e.detail.value; }

    addLine() {
        if (!this.productId || !this.quantity || Number(this.quantity) <= 0) {
            this.toast('Incomplete', 'Pick a product and a positive quantity.', 'warning');
            return;
        }
        const existing = this.lines.find((l) => l.productId === this.productId);
        if (existing) {
            existing.quantity = Number(this.quantity);
            this.lines = [...this.lines];
        } else {
            this.lines = [
                ...this.lines,
                { productId: this.productId, productName: this.productNameById[this.productId], quantity: Number(this.quantity) }
            ];
        }
        this.productId = undefined;
        this.quantity = undefined;
    }

    handleRowAction(e) {
        if (e.detail.action.name === 'remove') {
            const id = e.detail.row.productId;
            this.lines = this.lines.filter((l) => l.productId !== id);
        }
    }

    get isSubmitDisabled() {
        return !(this.hasSupplier && this.lines.length > 0) || this.submitting;
    }

    async submit() {
        this.submitting = true;
        try {
            const invoiceId = await placeP2Order({
                linesJson: JSON.stringify(this.lines.map((l) => ({ productId: l.productId, quantity: l.quantity })))
            });
            this.toast('Order placed', `P2 invoice created: ${invoiceId}`, 'success');
            this.lines = [];
            this.dispatchEvent(new CustomEvent('orderplaced'));
        } catch (e) {
            this.toast('Could not place order', this.msg(e), 'error');
        } finally {
            this.submitting = false;
        }
    }

    msg(e) {
        return (e && e.body && e.body.message) || 'Unexpected error.';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}