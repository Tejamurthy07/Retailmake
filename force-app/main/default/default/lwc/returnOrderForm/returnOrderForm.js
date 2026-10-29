import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import getAccountInvoices from '@salesforce/apex/ReturnOrderController.getAccountInvoices';
import getInvoiceLines from '@salesforce/apex/ReturnOrderController.getInvoiceLines';
import createReturnOrder from '@salesforce/apex/ReturnOrderController.createReturnOrder';

export default class ReturnOrderForm extends NavigationMixin(LightningElement) {
    @api accountId;
    @api visitId;

    get isEmbedded() { return !!this.accountId; }

    @track selectedInvoice = null;
    @track invoiceLines = [];
    @track returnLines = [];

    selectedInvoiceId = '';
    invoiceOptions = [];
    invoicesMap = {};
    returnRemarks = '';
    isLoading = false;
    isSubmitting = false;
    activePhotoLineId = null;

    get hasInvoiceLines() {
        return this.invoiceLines && this.invoiceLines.length > 0;
    }

    get hasReturnLines() {
        return this.invoiceLines.some(line => line.returnQty > 0);
    }

    get returnReasonOptions() {
        // Values must match the Return_Line__c.Return_Reason__c restricted picklist,
        // else the line insert is rejected (INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST).
        return [
            { label: 'Damaged', value: 'Damaged' },
            { label: 'Expired', value: 'Expired' },
            { label: 'Wrong Delivery', value: 'Wrong Delivery' },
            { label: 'Quality Issue', value: 'Quality Issue' },
            { label: 'Other', value: 'Other' }
        ];
    }

    get returnSummary() {
        const returnItems = this.invoiceLines.filter(line => line.returnQty > 0);
        const totalQty = returnItems.reduce((sum, line) => sum + (line.returnQty || 0), 0);
        const totalAmount = returnItems.reduce((sum, line) => sum + (line.returnAmount || 0), 0);

        return {
            totalItems: returnItems.length,
            totalQuantity: totalQty,
            totalAmount: totalAmount,
            totalAmountFormatted: this.formatCurrency(totalAmount)
        };
    }

    _isEmbedded = false;

    connectedCallback() {
        // Detect if used as embedded child component (accountId passed via @api)
        if (this.accountId && this.visitId) {
            this._isEmbedded = true;
        }
        this.loadInvoices();
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. No-op on the camelCase
    // maps returned by getInvoiceLines.
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

    async loadInvoices() {
        this.isLoading = true;
        try {
            const result = this._stripNs(await getAccountInvoices({ accountId: this.accountId }));
            this.invoicesMap = {};
            this.invoiceOptions = (result || []).map(inv => {
                const label = (inv.Name || inv.Invoice_Number__c) +
                    ' - ' + this.formatDate(inv.Invoice_Date__c) +
                    ' - ' + this.formatCurrency(inv.Net_Amount__c || 0);
                this.invoicesMap[inv.Id] = {
                    id: inv.Id,
                    invoiceNumber: inv.Name || inv.Invoice_Number__c,
                    date: inv.Invoice_Date__c,
                    dateFormatted: this.formatDate(inv.Invoice_Date__c),
                    amount: inv.Net_Amount__c || 0,
                    amountFormatted: this.formatCurrency(inv.Net_Amount__c || 0)
                };
                return { label: label, value: inv.Id };
            });
        } catch (error) {
            this.showToast('Error', 'Failed to load invoices: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleInvoiceSelect(event) {
        this.selectedInvoiceId = event.detail.value;
        this.selectedInvoice = this.invoicesMap[this.selectedInvoiceId] || null;

        if (!this.selectedInvoiceId) {
            this.invoiceLines = [];
            return;
        }

        this.isLoading = true;
        try {
            const result = await getInvoiceLines({ invoiceId: this.selectedInvoiceId });
            this.invoiceLines = (result || []).map(line => {
                // Backend returns Map<String, Object> with these keys:
                // invoiceLineId, productId, productName, productCode,
                // invoicedQty, unitPrice, discount, taxAmount, lineTotal,
                // hsnCode, batchNo, alreadyReturned, availableForReturn
                const qtySold = line.invoicedQty || 0;
                const qtyReturned = line.alreadyReturned || 0;
                const maxReturn = line.availableForReturn || (qtySold - qtyReturned);
                const unitPrice = line.unitPrice || 0;
                const isFullyReturned = maxReturn <= 0;

                return {
                    id: line.invoiceLineId,
                    productId: line.productId,
                    productName: line.productName || 'Product',
                    sku: line.productCode || 'N/A',
                    batchNo: line.batchNo || null,
                    qtySold: qtySold,
                    qtyAlreadyReturned: qtyReturned,
                    maxReturnQty: maxReturn,
                    unitPrice: unitPrice,
                    returnQty: 0,
                    returnReason: '',
                    returnAmount: 0,
                    returnAmountFormatted: this.formatCurrency(0),
                    photoPreview: null,
                    photoData: null,
                    isFullyReturned: isFullyReturned,
                    rowClass: isFullyReturned ? 'fully-returned-row' : ''
                };
            });
        } catch (error) {
            this.showToast('Error', 'Failed to load invoice lines: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleReturnQtyChange(event) {
        const lineId = event.target.dataset.lineId;
        const returnQty = parseInt(event.detail.value, 10) || 0;

        this.invoiceLines = this.invoiceLines.map(line => {
            if (line.id === lineId) {
                const validatedQty = this.validateReturnQty(returnQty, line.maxReturnQty, line.productName);
                const returnAmount = validatedQty * line.unitPrice;
                return {
                    ...line,
                    returnQty: validatedQty,
                    returnAmount: returnAmount,
                    returnAmountFormatted: this.formatCurrency(returnAmount),
                    rowClass: validatedQty > 0 ? 'return-active-row' : (line.isFullyReturned ? 'fully-returned-row' : '')
                };
            }
            return line;
        });
    }

    validateReturnQty(qty, maxQty, productName) {
        if (qty < 0) {
            this.showToast('Warning', 'Return quantity cannot be negative', 'warning');
            return 0;
        }
        if (qty > maxQty) {
            this.showToast('Warning',
                'Return quantity for ' + productName + ' cannot exceed ' + maxQty,
                'warning');
            return maxQty;
        }
        return qty;
    }

    handleReturnReasonChange(event) {
        const lineId = event.target.dataset.lineId;
        const reason = event.detail.value;
        this.invoiceLines = this.invoiceLines.map(line => {
            if (line.id === lineId) {
                return { ...line, returnReason: reason };
            }
            return line;
        });
    }

    triggerLinePhotoUpload(event) {
        this.activePhotoLineId = event.currentTarget.dataset.lineId;
        const fileInput = this.template.querySelector('.file-input');
        if (fileInput) fileInput.click();
    }

    handleLinePhotoCapture(event) {
        const file = event.target.files[0];
        if (!file || !this.activePhotoLineId) return;

        if (file.size > 5 * 1024 * 1024) {
            this.showToast('Error', 'Photo must be less than 5MB', 'error');
            return;
        }

        const reader = new FileReader();
        reader.onload = () => {
            const lineId = this.activePhotoLineId;
            this.invoiceLines = this.invoiceLines.map(line => {
                if (line.id === lineId) {
                    return {
                        ...line,
                        photoPreview: reader.result,
                        photoData: reader.result.split(',')[1]
                    };
                }
                return line;
            });
            this.activePhotoLineId = null;
        };
        reader.readAsDataURL(file);
    }

    removeLinePhoto(event) {
        const lineId = event.currentTarget.dataset.lineId;
        this.invoiceLines = this.invoiceLines.map(line => {
            if (line.id === lineId) {
                return { ...line, photoPreview: null, photoData: null };
            }
            return line;
        });
    }

    handleReturnRemarksChange(event) {
        this.returnRemarks = event.target.value;
    }

    addReturnLine(lineId, qty, reason) {
        const line = this.invoiceLines.find(l => l.id === lineId);
        if (!line) return;

        const validatedQty = this.validateReturnQty(qty, line.maxReturnQty, line.productName);
        const returnAmount = validatedQty * line.unitPrice;

        this.invoiceLines = this.invoiceLines.map(l => {
            if (l.id === lineId) {
                return {
                    ...l,
                    returnQty: validatedQty,
                    returnReason: reason,
                    returnAmount: returnAmount,
                    returnAmountFormatted: this.formatCurrency(returnAmount),
                    rowClass: validatedQty > 0 ? 'return-active-row' : ''
                };
            }
            return l;
        });
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    async handleSubmit() {
        if (!this.validateReturn()) return;

        this.isSubmitting = true;
        this.isLoading = true;

        try {
            const returnItems = this.invoiceLines
                .filter(line => line.returnQty > 0)
                .map(line => ({
                    invoiceLineId: line.id,
                    productId: line.productId,
                    returnQty: line.returnQty,
                    reason: line.returnReason,
                    returnAmount: line.returnAmount,
                    batchNo: line.batchNo,
                    photo: line.photoData
                }));

            const returnData = {
                accountId: this.accountId,
                visitId: this.visitId,
                invoiceId: this.selectedInvoiceId,
                remarks: this.returnRemarks,
                totalItems: this.returnSummary.totalItems,
                totalQuantity: this.returnSummary.totalQuantity,
                totalAmount: this.returnSummary.totalAmount,
                returnLines: returnItems
            };

            const result = await createReturnOrder({ returnJson: JSON.stringify(returnData) });

            this.showToast('Success',
                'Return order created successfully! Return #: ' + (result.Name || result.Id),
                'success'
            );

            // Dispatch success event for parent components
            this.dispatchEvent(new CustomEvent('success', {
                detail: { recordId: result.Id, returnNumber: result.Name, type: 'return' }
            }));

            // Only navigate if not embedded (check if accountId was passed as @api)
            if (result.Id && !this._isEmbedded) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: result.Id,
                        objectApiName: 'Return_Order__c',
                        actionName: 'view'
                    }
                });
            }
        } catch (error) {
            this.showToast('Error', 'Failed to create return: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSubmitting = false;
            this.isLoading = false;
        }
    }

    validateReturn() {
        const returnItems = this.invoiceLines.filter(line => line.returnQty > 0);

        if (returnItems.length === 0) {
            this.showToast('Error', 'Please enter return quantity for at least one product', 'error');
            return false;
        }

        for (const item of returnItems) {
            if (!item.returnReason) {
                this.showToast('Error',
                    'Please select a return reason for ' + item.productName,
                    'error');
                return false;
            }
            if (item.returnQty > item.maxReturnQty) {
                this.showToast('Error',
                    'Return quantity for ' + item.productName + ' exceeds maximum allowed (' + item.maxReturnQty + ')',
                    'error');
                return false;
            }
        }

        return true;
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'INR',
            minimumFractionDigits: 2
        }).format(value || 0);
    }

    formatDate(dateStr) {
        if (!dateStr) return '';
        return new Date(dateStr).toLocaleDateString('en-IN', {
            day: '2-digit', month: 'short', year: 'numeric'
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return 'Unknown error';
    }
}