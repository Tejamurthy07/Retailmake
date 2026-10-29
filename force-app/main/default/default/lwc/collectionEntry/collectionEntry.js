import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import getOutstandingInvoices from '@salesforce/apex/CollectionEntryController.getOutstandingInvoices';
import createCollection from '@salesforce/apex/CollectionEntryController.createCollection';
import getAgingSummary from '@salesforce/apex/CollectionEntryController.getAgingSummary';
import getCollectionHistory from '@salesforce/apex/CollectionEntryController.getCollectionHistory';

export default class CollectionEntry extends NavigationMixin(LightningElement) {
    @api accountId;
    @api visitId;

    get isEmbedded() { return !!this.accountId; }

    @track outstandingInvoices = [];
    @track agingSummary = {
        totalOutstanding: 0,
        totalOutstandingFormatted: '0.00',
        bucket0to30: 0,
        bucket0to30Formatted: '0.00',
        bucket31to60: 0,
        bucket31to60Formatted: '0.00',
        bucket61to90: 0,
        bucket61to90Formatted: '0.00',
        bucket90Plus: 0,
        bucket90PlusFormatted: '0.00'
    };
    @track collectionRecord = {
        amount: null,
        paymentMode: 'Cash',
        allocationType: 'Against Invoice',
        chequeNumber: '',
        chequeDate: null,
        bankName: '',
        upiReference: '',
        neftReference: '',
        transactionDate: null,
        remarks: ''
    };
    @track collectionHistory = [];

    isLoading = false;
    isSubmitting = false;
    lastCollectionId = null;
    allSelected = false;

    get hasOutstandingInvoices() {
        return this.outstandingInvoices && this.outstandingInvoices.length > 0;
    }

    get hasCollectionHistory() {
        return this.collectionHistory && this.collectionHistory.length > 0;
    }

    get isChequePayment() {
        return this.collectionRecord.paymentMode === 'Cheque';
    }

    get isUpiPayment() {
        return this.collectionRecord.paymentMode === 'UPI';
    }

    get isNeftPayment() {
        return this.collectionRecord.paymentMode === 'NEFT';
    }

    get paymentModeOptions() {
        return [
            { label: 'Cash', value: 'Cash' },
            { label: 'Cheque', value: 'Cheque' },
            { label: 'UPI', value: 'UPI' },
            { label: 'NEFT/RTGS', value: 'NEFT' }
        ];
    }

    get allocationTypeOptions() {
        return [
            { label: 'Against Invoice', value: 'Against Invoice' },
            { label: 'On Account', value: 'On Account' }
        ];
    }

    get collectionAmountFormatted() {
        return this.formatCurrency(this.collectionRecord.amount || 0);
    }

    get totalAllocated() {
        return this.outstandingInvoices
            .filter(inv => inv.selected)
            .reduce((sum, inv) => sum + (parseFloat(inv.allocatedAmount) || 0), 0);
    }

    get totalAllocatedFormatted() {
        return this.formatCurrency(this.totalAllocated);
    }

    get unallocatedAmount() {
        return (this.collectionRecord.amount || 0) - this.totalAllocated;
    }

    get unallocatedAmountFormatted() {
        return this.formatCurrency(this.unallocatedAmount);
    }

    get unallocatedClass() {
        return this.unallocatedAmount < 0 ? 'text-danger' : 'text-normal';
    }

    get showAllocationSummary() {
        return this.collectionRecord.allocationType === 'Against Invoice' &&
            this.collectionRecord.amount > 0 &&
            this.outstandingInvoices.some(inv => inv.selected);
    }

    get disableReceipt() {
        return !this.lastCollectionId;
    }

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            await Promise.all([
                this.loadOutstandingInvoices(),
                this.loadAgingSummary(),
                this.loadCollectionHistory()
            ]);
        } catch (error) {
            console.error('Error loading data:', error);
        } finally {
            this.isLoading = false;
        }
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. No-op on camelCase
    // maps (getAgingSummary) and plain values.
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

    async loadOutstandingInvoices() {
        try {
            const result = this._stripNs(await getOutstandingInvoices({ accountId: this.accountId }));
            this.outstandingInvoices = (result || []).map(inv => {
                const daysOverdue = this.calculateDaysOverdue(inv.Due_Date__c);
                return {
                    id: inv.Id,
                    invoiceNumber: inv.Name || inv.Invoice_Number__c,
                    invoiceDate: inv.Invoice_Date__c,
                    invoiceDateFormatted: this.formatDate(inv.Invoice_Date__c),
                    invoiceAmount: inv.Invoice_Amount__c || 0,
                    invoiceAmountFormatted: this.formatCurrency(inv.Invoice_Amount__c || 0),
                    balanceDue: inv.Balance_Due__c || 0,
                    balanceDueFormatted: this.formatCurrency(inv.Balance_Due__c || 0),
                    daysOverdue: Math.max(daysOverdue, 0),
                    overdueBadgeClass: this.getOverdueBadgeClass(daysOverdue),
                    selected: false,
                    allocatedAmount: 0,
                    rowClass: ''
                };
            });
        } catch (error) {
            console.error('Error loading invoices:', error);
        }
    }

    async loadAgingSummary() {
        try {
            const result = await getAgingSummary({ accountId: this.accountId });
            if (result) {
                this.agingSummary = {
                    totalOutstanding: result.total || 0,
                    totalOutstandingFormatted: this.formatCurrency(result.total || 0),
                    bucket0to30: result.current || 0,
                    bucket0to30Formatted: this.formatCurrency(result.current || 0),
                    bucket31to60: result.days31_60 || 0,
                    bucket31to60Formatted: this.formatCurrency(result.days31_60 || 0),
                    bucket61to90: result.days61_90 || 0,
                    bucket61to90Formatted: this.formatCurrency(result.days61_90 || 0),
                    bucket90Plus: result.days90Plus || 0,
                    bucket90PlusFormatted: this.formatCurrency(result.days90Plus || 0)
                };
            }
        } catch (error) {
            console.error('Error loading aging summary:', error);
        }
    }

    async loadCollectionHistory() {
        try {
            const result = this._stripNs(await getCollectionHistory({ accountId: this.accountId }));
            this.collectionHistory = (result || []).map(col => ({
                id: col.Id,
                receiptNumber: col.Name || col.Receipt_Number__c,
                date: col.Collection_Date__c,
                dateFormatted: this.formatDate(col.Collection_Date__c || col.CreatedDate),
                amount: col.Amount__c || 0,
                amountFormatted: this.formatCurrency(col.Amount__c || 0),
                paymentMode: col.Payment_Mode__c || 'Cash',
                reference: col.Reference_Number__c || col.Cheque_Number__c || '-',
                status: col.Status__c || 'Confirmed',
                statusBadgeClass: this.getStatusBadgeClass(col.Status__c)
            }));
        } catch (error) {
            console.error('Error loading collection history:', error);
        }
    }

    handlePaymentModeChange(event) {
        this.collectionRecord = {
            ...this.collectionRecord,
            paymentMode: event.detail.value,
            chequeNumber: '',
            chequeDate: null,
            bankName: '',
            upiReference: '',
            neftReference: '',
            transactionDate: null
        };
    }

    handleAmountChange(event) {
        this.collectionRecord = { ...this.collectionRecord, amount: parseFloat(event.detail.value) || 0 };
        this.autoAllocateToInvoices();
    }

    handleAllocationTypeChange(event) {
        this.collectionRecord = { ...this.collectionRecord, allocationType: event.detail.value };
        if (event.detail.value === 'On Account') {
            this.outstandingInvoices = this.outstandingInvoices.map(inv => ({
                ...inv, selected: false, allocatedAmount: 0
            }));
        }
    }

    handleChequeNumberChange(event) {
        this.collectionRecord = { ...this.collectionRecord, chequeNumber: event.detail.value };
    }

    handleChequeDateChange(event) {
        this.collectionRecord = { ...this.collectionRecord, chequeDate: event.detail.value };
    }

    handleBankNameChange(event) {
        this.collectionRecord = { ...this.collectionRecord, bankName: event.detail.value };
    }

    handleUpiReferenceChange(event) {
        this.collectionRecord = { ...this.collectionRecord, upiReference: event.detail.value };
    }

    handleNeftReferenceChange(event) {
        this.collectionRecord = { ...this.collectionRecord, neftReference: event.detail.value };
    }

    handleTransactionDateChange(event) {
        this.collectionRecord = { ...this.collectionRecord, transactionDate: event.detail.value };
    }

    handleRemarksChange(event) {
        this.collectionRecord = { ...this.collectionRecord, remarks: event.target.value };
    }

    handleInvoiceSelect(event) {
        const invoiceId = event.target.dataset.invoiceId;
        const isChecked = event.target.checked;

        this.outstandingInvoices = this.outstandingInvoices.map(inv => {
            if (inv.id === invoiceId) {
                return {
                    ...inv,
                    selected: isChecked,
                    allocatedAmount: isChecked ? inv.balanceDue : 0,
                    rowClass: isChecked ? 'selected-row' : ''
                };
            }
            return inv;
        });

        this.allSelected = this.outstandingInvoices.every(inv => inv.selected);
        this._syncCollectionAmountFromAllocations();
    }

    handleSelectAll(event) {
        const isChecked = event.target.checked;
        this.allSelected = isChecked;
        this.outstandingInvoices = this.outstandingInvoices.map(inv => ({
            ...inv,
            selected: isChecked,
            allocatedAmount: isChecked ? inv.balanceDue : 0,
            rowClass: isChecked ? 'selected-row' : ''
        }));
        this._syncCollectionAmountFromAllocations();
    }

    handleAllocationChange(event) {
        const invoiceId = event.target.dataset.invoiceId;
        const amount = parseFloat(event.detail.value) || 0;

        this.outstandingInvoices = this.outstandingInvoices.map(inv => {
            if (inv.id === invoiceId) {
                const allocatedAmount = Math.min(amount, inv.balanceDue);
                return { ...inv, allocatedAmount: allocatedAmount };
            }
            return inv;
        });
        this._syncCollectionAmountFromAllocations();
    }

    _syncCollectionAmountFromAllocations() {
        // Auto-fill Collection Amount with the sum of selected allocations
        // (only when user hasn't typed a higher amount manually — preserves any
        // "on account" overage the user entered explicitly)
        const selectedTotal = this.outstandingInvoices
            .filter(inv => inv.selected)
            .reduce((sum, inv) => sum + (parseFloat(inv.allocatedAmount) || 0), 0);

        const currentAmount = parseFloat(this.collectionRecord.amount) || 0;
        if (selectedTotal > currentAmount || currentAmount === 0) {
            this.collectionRecord = { ...this.collectionRecord, amount: selectedTotal };
        }
    }

    autoAllocateToInvoices() {
        if (this.collectionRecord.allocationType !== 'Against Invoice') return;

        let remainingAmount = this.collectionRecord.amount || 0;
        this.outstandingInvoices = this.outstandingInvoices.map(inv => {
            if (inv.selected && remainingAmount > 0) {
                const allocation = Math.min(remainingAmount, inv.balanceDue);
                remainingAmount -= allocation;
                return { ...inv, allocatedAmount: allocation };
            }
            return inv;
        });
    }

    allocateToInvoice(invoiceId, amount) {
        this.outstandingInvoices = this.outstandingInvoices.map(inv => {
            if (inv.id === invoiceId) {
                return { ...inv, allocatedAmount: Math.min(amount, inv.balanceDue), selected: true };
            }
            return inv;
        });
    }

    async handleSubmitCollection() {
        if (!this.validateCollection()) return;

        this.isSubmitting = true;
        this.isLoading = true;

        try {
            const allocations = this.collectionRecord.allocationType === 'Against Invoice'
                ? this.outstandingInvoices
                    .filter(inv => inv.selected && inv.allocatedAmount > 0)
                    .map(inv => ({
                        invoiceId: inv.id,
                        allocatedAmount: inv.allocatedAmount
                    }))
                : [];

            const collectionData = {
                accountId: this.accountId,
                visitId: this.visitId,
                amount: this.collectionRecord.amount,
                paymentMode: this.collectionRecord.paymentMode,
                allocationType: this.collectionRecord.allocationType,
                chequeNumber: this.collectionRecord.chequeNumber,
                chequeDate: this.collectionRecord.chequeDate,
                bankName: this.collectionRecord.bankName,
                upiReference: this.collectionRecord.upiReference,
                neftReference: this.collectionRecord.neftReference,
                transactionDate: this.collectionRecord.transactionDate,
                remarks: this.collectionRecord.remarks,
                allocations: allocations
            };

            const result = await createCollection({ collectionJson: JSON.stringify(collectionData) });
            this.lastCollectionId = result.Id;

            this.showToast('Success',
                'Collection of ' + this.formatCurrency(this.collectionRecord.amount) + ' recorded successfully!',
                'success');

            // Dispatch success event for parent components
            this.dispatchEvent(new CustomEvent('success', {
                detail: { recordId: result.Id, amount: this.collectionRecord.amount, type: 'collection' }
            }));

            this.resetForm();
            this.loadData();
        } catch (error) {
            this.showToast('Error', 'Failed to submit collection: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSubmitting = false;
            this.isLoading = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleDownloadReceipt(event) {
        event.preventDefault();
        event.stopPropagation();
        const collectionId = event.currentTarget.dataset.id;
        if (!collectionId) return;
        const url = '/apex/CollectionReceipt?id=' + collectionId;
        if (/Android|iPhone|iPad|iPod/i.test(navigator.userAgent)) {
            window.location.href = url;
        } else {
            window.open(url, '_blank');
        }
    }

    viewInvoice(event) {
        event.preventDefault();
        event.stopPropagation();
        const invoiceId = event.currentTarget.dataset.invoiceId;
        if (!invoiceId) return;
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: {
                recordId: invoiceId,
                objectApiName: 'Invoice__c',
                actionName: 'view'
            }
        }).then(url => {
            window.open(url, '_blank');
        });
    }

    validateCollection() {
        if (!this.collectionRecord.amount || this.collectionRecord.amount <= 0) {
            this.showToast('Error', 'Please enter a valid collection amount', 'error');
            return false;
        }

        if (this.collectionRecord.paymentMode === 'Cheque') {
            if (!this.collectionRecord.chequeNumber) {
                this.showToast('Error', 'Cheque number is required', 'error');
                return false;
            }
            if (!this.collectionRecord.chequeDate) {
                this.showToast('Error', 'Cheque date is required', 'error');
                return false;
            }
            if (!this.collectionRecord.bankName) {
                this.showToast('Error', 'Bank name is required', 'error');
                return false;
            }
        }

        if (this.collectionRecord.paymentMode === 'UPI' && !this.collectionRecord.upiReference) {
            this.showToast('Error', 'UPI reference number is required', 'error');
            return false;
        }

        if (this.collectionRecord.paymentMode === 'NEFT' && !this.collectionRecord.neftReference) {
            this.showToast('Error', 'NEFT/RTGS reference is required', 'error');
            return false;
        }

        if (this.collectionRecord.allocationType === 'Against Invoice') {
            const hasAllocations = this.outstandingInvoices.some(inv => inv.selected && inv.allocatedAmount > 0);
            if (!hasAllocations) {
                this.showToast('Warning', 'Please select at least one invoice to allocate against, or choose On Account', 'warning');
                return false;
            }
            if (this.unallocatedAmount < 0) {
                this.showToast('Error', 'Allocated amount exceeds collection amount', 'error');
                return false;
            }
        }

        return true;
    }

    resetForm() {
        this.collectionRecord = {
            amount: null,
            paymentMode: 'Cash',
            allocationType: 'Against Invoice',
            chequeNumber: '',
            chequeDate: null,
            bankName: '',
            upiReference: '',
            neftReference: '',
            transactionDate: null,
            remarks: ''
        };
        this.allSelected = false;
    }

    calculateDaysOverdue(dueDate) {
        if (!dueDate) return 0;
        const due = new Date(dueDate);
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        due.setHours(0, 0, 0, 0);
        return Math.floor((today - due) / (1000 * 60 * 60 * 24));
    }

    getOverdueBadgeClass(daysOverdue) {
        if (daysOverdue <= 0) return 'overdue-badge badge-current';
        if (daysOverdue <= 30) return 'overdue-badge badge-30';
        if (daysOverdue <= 60) return 'overdue-badge badge-60';
        if (daysOverdue <= 90) return 'overdue-badge badge-90';
        return 'overdue-badge badge-90plus';
    }

    getStatusBadgeClass(status) {
        const map = {
            'Confirmed': 'status-badge badge-confirmed',
            'Pending': 'status-badge badge-pending',
            'Bounced': 'status-badge badge-bounced',
            'Cancelled': 'status-badge badge-cancelled'
        };
        return map[status] || 'status-badge badge-confirmed';
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
            day: '2-digit',
            month: 'short',
            year: 'numeric'
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