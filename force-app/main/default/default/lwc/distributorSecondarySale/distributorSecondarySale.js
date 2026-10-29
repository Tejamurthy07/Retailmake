import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRetailers from '@salesforce/apex/DMS_PortalController.getRetailers';
import getProducts from '@salesforce/apex/DMS_PortalController.getProducts';
import placeSecondarySale from '@salesforce/apex/DMS_PortalController.placeSecondarySale';

const LINE_COLUMNS = [
    { label: 'Product', fieldName: 'productName' },
    { label: 'Quantity', fieldName: 'quantity', type: 'number', cellAttributes: { alignment: 'left' } },
    {
        type: 'button-icon',
        fixedWidth: 50,
        typeAttributes: { iconName: 'utility:delete', name: 'remove', variant: 'bare', alternativeText: 'Remove' }
    }
];

export default class DistributorSecondarySale extends LightningElement {
    retailerId;
    productId;
    quantity;
    retailerOptions = [];
    productOptions = [];
    productNameById = {};
    @track lines = [];
    columns = LINE_COLUMNS;
    submitting = false;

    @wire(getRetailers)
    wiredRetailers({ data, error }) {
        if (data) {
            this.retailerOptions = data.map((r) => ({ label: r.Name, value: r.Id }));
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

    handleRetailer(e) { this.retailerId = e.detail.value; }
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
        return !(this.retailerId && this.lines.length > 0) || this.submitting;
    }

    async submit() {
        this.submitting = true;
        try {
            const invoiceId = await placeSecondarySale({
                retailerId: this.retailerId,
                linesJson: JSON.stringify(this.lines.map((l) => ({ productId: l.productId, quantity: l.quantity })))
            });
            this.toast('Sale placed', `Secondary invoice created: ${invoiceId}`, 'success');
            this.lines = [];
            this.retailerId = undefined;
        } catch (e) {
            this.toast('Could not place sale', this.msg(e), 'error');
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