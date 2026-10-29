import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getActiveUOMs from '@salesforce/apex/UOMConversionController.getActiveUOMs';
import getConversions from '@salesforce/apex/UOMConversionController.getConversions';
import saveConversion from '@salesforce/apex/UOMConversionController.saveConversion';
import deleteConversion from '@salesforce/apex/UOMConversionController.deleteConversion';
import convertQuantity from '@salesforce/apex/UOMConversionController.convertQuantity';

const CONVERSION_COLUMNS = [
    { label: 'Name', fieldName: 'Name', type: 'text' },
    { label: 'From UOM', fieldName: 'fromUOMName', type: 'text' },
    { label: 'To UOM', fieldName: 'toUOMName', type: 'text' },
    { label: 'Factor', fieldName: 'Conversion_Factor__c', type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 6 } },
    { label: 'Inverse Factor', fieldName: 'Inverse_Conversion_Factor__c', type: 'number',
        typeAttributes: { minimumFractionDigits: 4, maximumFractionDigits: 4 } },
    { label: 'Product', fieldName: 'productName', type: 'text' },
    { label: 'Active', fieldName: 'Is_Active__c', type: 'boolean' },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [
                { label: 'Edit', name: 'edit' },
                { label: 'Delete', name: 'delete' }
            ]
        }
    }
];

export default class UomConversionManager extends LightningElement {
    @track uomOptions = [];
    @track conversions = [];
    @track convertedResult = null;
    columns = CONVERSION_COLUMNS;

    // Conversion form fields
    showConversionModal = false;
    editConversionId = null;
    fromUOMId = '';
    toUOMId = '';
    conversionFactor = null;
    productId = null;
    isConversionActive = true;

    // Calculator fields
    calcFromUOMId = '';
    calcToUOMId = '';
    calcQuantity = null;
    calcProductId = null;

    isLoading = false;

    _wiredConversionsResult;
    _wiredUOMsResult;

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working (applied to wired
    // data; the raw wire result is kept for refreshApex).
    _stripNs(value) {
        if (Array.isArray(value)) return value.map((v) => this._stripNs(v));
        if (value && typeof value === 'object') {
            const out = {};
            Object.keys(value).forEach((k) => {
                const nk = k.startsWith('ftretailmake__') ? k.slice('ftretailmake__'.length) : k;
                out[nk] = this._stripNs(value[k]);
            });
            return out;
        }
        return value;
    }

    @wire(getActiveUOMs)
    wiredUOMs(result) {
        this._wiredUOMsResult = result;
        if (result.data) {
            this.uomOptions = this._stripNs(result.data).map(uom => ({
                label: `${uom.Name} (${uom.UOM_Code__c})`,
                value: uom.Id
            }));
        }
    }

    @wire(getConversions, { productId: null })
    wiredConversions(result) {
        this._wiredConversionsResult = result;
        if (result.data) {
            this.conversions = this._stripNs(result.data).map(conv => ({
                ...conv,
                fromUOMName: conv.From_UOM__r ? conv.From_UOM__r.Name : '',
                toUOMName: conv.To_UOM__r ? conv.To_UOM__r.Name : '',
                productName: conv.Product__r ? conv.Product__r.Name : 'Global'
            }));
        }
    }

    get hasConversions() {
        return this.conversions && this.conversions.length > 0;
    }

    get modalTitle() {
        return this.editConversionId ? 'Edit UOM Conversion' : 'New UOM Conversion';
    }

    get hasResult() {
        return this.convertedResult !== null;
    }

    // --- Conversion CRUD ---

    handleNewConversion() {
        this.resetConversionForm();
        this.showConversionModal = true;
    }

    handleRowAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;

        if (action.name === 'edit') {
            this.editConversionId = row.Id;
            this.fromUOMId = row.From_UOM__c;
            this.toUOMId = row.To_UOM__c;
            this.conversionFactor = row.Conversion_Factor__c;
            this.productId = row.Product__c || null;
            this.isConversionActive = row.Is_Active__c;
            this.showConversionModal = true;
        } else if (action.name === 'delete') {
            this.handleDeleteConversion(row.Id);
        }
    }

    handleFromUOMChange(event) {
        this.fromUOMId = event.detail.value;
    }

    handleToUOMChange(event) {
        this.toUOMId = event.detail.value;
    }

    handleFactorChange(event) {
        this.conversionFactor = event.detail.value;
    }

    handleProductChange(event) {
        this.productId = event.detail.value[0] || null;
    }

    handleActiveChange(event) {
        this.isConversionActive = event.detail.checked;
    }

    handleCloseModal() {
        this.showConversionModal = false;
        this.resetConversionForm();
    }

    async handleSaveConversion() {
        if (!this.fromUOMId || !this.toUOMId || !this.conversionFactor) {
            this.showToast('Error', 'Please fill in all required fields.', 'error');
            return;
        }

        this.isLoading = true;
        try {
            const conversion = {
                From_UOM__c: this.fromUOMId,
                To_UOM__c: this.toUOMId,
                Conversion_Factor__c: parseFloat(this.conversionFactor),
                Is_Active__c: this.isConversionActive
            };

            if (this.productId) {
                conversion.Product__c = this.productId;
            }
            if (this.editConversionId) {
                conversion.Id = this.editConversionId;
            }

            await saveConversion({ conversionJson: JSON.stringify(conversion) });
            this.showToast('Success', 'UOM Conversion saved successfully.', 'success');
            this.showConversionModal = false;
            this.resetConversionForm();
            await refreshApex(this._wiredConversionsResult);
        } catch (error) {
            this.showToast('Error', this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleDeleteConversion(conversionId) {
        this.isLoading = true;
        try {
            await deleteConversion({ conversionId });
            this.showToast('Success', 'UOM Conversion deleted.', 'success');
            await refreshApex(this._wiredConversionsResult);
        } catch (error) {
            this.showToast('Error', this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // --- Calculator ---

    handleCalcFromUOMChange(event) {
        this.calcFromUOMId = event.detail.value;
        this.convertedResult = null;
    }

    handleCalcToUOMChange(event) {
        this.calcToUOMId = event.detail.value;
        this.convertedResult = null;
    }

    handleCalcQuantityChange(event) {
        this.calcQuantity = event.detail.value;
        this.convertedResult = null;
    }

    handleCalcProductChange(event) {
        this.calcProductId = event.detail.value[0] || null;
        this.convertedResult = null;
    }

    async handleConvert() {
        if (!this.calcFromUOMId || !this.calcToUOMId || !this.calcQuantity) {
            this.showToast('Error', 'Please fill in quantity and select both UOMs.', 'error');
            return;
        }

        this.isLoading = true;
        try {
            const result = await convertQuantity({
                quantity: parseFloat(this.calcQuantity),
                fromUOMId: this.calcFromUOMId,
                toUOMId: this.calcToUOMId,
                productId: this.calcProductId || null
            });
            this.convertedResult = result;
        } catch (error) {
            this.showToast('Error', this.reduceErrors(error), 'error');
            this.convertedResult = null;
        } finally {
            this.isLoading = false;
        }
    }

    // --- Helpers ---

    resetConversionForm() {
        this.editConversionId = null;
        this.fromUOMId = '';
        this.toUOMId = '';
        this.conversionFactor = null;
        this.productId = null;
        this.isConversionActive = true;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return 'An unexpected error occurred.';
    }
}