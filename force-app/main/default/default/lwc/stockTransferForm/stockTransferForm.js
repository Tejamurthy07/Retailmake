import { LightningElement, track } from 'lwc';
import getWarehouses from '@salesforce/apex/INV_WarehouseStockController.getWarehouses';
import getAvailableProducts from '@salesforce/apex/INV_StockTransferController.getAvailableProducts';
import createTransfer from '@salesforce/apex/INV_StockTransferController.createTransfer';
import getTransfers from '@salesforce/apex/INV_StockTransferController.getTransfers';
import getTransferDetail from '@salesforce/apex/INV_StockTransferController.getTransferDetail';
import submitTransfer from '@salesforce/apex/INV_StockTransferController.submitTransfer';
import approveTransfer from '@salesforce/apex/INV_StockTransferController.approveTransfer';
import receiveTransfer from '@salesforce/apex/INV_StockTransferController.receiveTransfer';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class StockTransferForm extends LightningElement {
    // State
    isLoading = false;
    errorMessage = '';
    activeView = 'list'; // 'list', 'create', 'detail'

    // Warehouse options
    @track warehouseOptions = [];
    @track sourceProducts = [];

    // Create form
    sourceWarehouseId = '';
    destinationWarehouseId = '';
    transferDate = new Date().toISOString().split('T')[0];
    transferNotes = '';
    @track lineItems = [];
    nextLineKey = 1;

    // List view
    filterWarehouseId = '';
    filterStatus = 'all';
    @track transfers = [];

    // Detail view
    @track transferDetail = null;
    @track receiveLineItems = [];
    showReceiveModal = false;

    // ──────────────────────────────────────────────────────────────
    // Lifecycle
    // ──────────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadWarehouses();
        this.loadTransfers();
    }

    // ──────────────────────────────────────────────────────────────
    // Data Loading
    // ──────────────────────────────────────────────────────────────

    loadWarehouses() {
        getWarehouses()
            .then(result => {
                // No empty '' placeholder option — it makes required comboboxes invalid on
                // touch. The combobox's `placeholder` attribute is used instead.
                const opts = [];
                result.forEach(wh => {
                    opts.push({
                        label: wh.Name + ' (' + (wh.Warehouse_Code__c || '') + ')',
                        value: wh.Id
                    });
                });
                this.warehouseOptions = opts;
            })
            .catch(error => this.handleError(error, 'Failed to load warehouses'));
    }

    loadTransfers() {
        this.isLoading = true;
        const warehouseId = this.filterWarehouseId || null;
        const status = this.filterStatus || 'all';
        getTransfers({ warehouseId, status })
            .then(result => {
                this.transfers = (result || []).map(t => ({
                    id: t.Id,
                    name: t.Name,
                    sourceName: t.Source_Warehouse__r ? t.Source_Warehouse__r.Name : '',
                    destName: t.Destination_Warehouse__r ? t.Destination_Warehouse__r.Name : '',
                    transferDate: t.Transfer_Date__c,
                    status: t.Status__c,
                    requestedBy: t.Requested_By__r ? t.Requested_By__r.Name : '',
                    statusClass: this.getStatusClass(t.Status__c)
                }));
                this.errorMessage = '';
            })
            .catch(error => this.handleError(error, 'Failed to load transfers'))
            .finally(() => { this.isLoading = false; });
    }

    productsLoaded = false;

    loadSourceProducts() {
        this.productsLoaded = false;
        if (!this.sourceWarehouseId) {
            this.sourceProducts = [];
            return;
        }
        getAvailableProducts({ warehouseId: this.sourceWarehouseId, searchTerm: null })
            .then(result => {
                this.sourceProducts = (result || []).map(s => ({
                    label: (s.Product_Ext__r ? s.Product_Ext__r.Name : '') + ' (Avail: ' + (s.Qty_Available__c || 0) + ')',
                    value: s.Product_Ext__c,
                    available: s.Qty_Available__c || 0,
                    batchNumber: s.Batch_Number__c || ''
                }));
            })
            .catch(error => this.handleError(error, 'Failed to load products'))
            .finally(() => { this.productsLoaded = true; });
    }

    loadTransferDetail(transferId) {
        this.isLoading = true;
        getTransferDetail({ transferId })
            .then(result => {
                this.transferDetail = result;
                this.activeView = 'detail';
                this.errorMessage = '';
            })
            .catch(error => this.handleError(error, 'Failed to load transfer detail'))
            .finally(() => { this.isLoading = false; });
    }

    // ──────────────────────────────────────────────────────────────
    // Event Handlers - List View
    // ──────────────────────────────────────────────────────────────

    handleFilterWarehouseChange(event) {
        this.filterWarehouseId = event.detail.value;
        this.loadTransfers();
    }

    handleFilterStatusChange(event) {
        this.filterStatus = event.detail.value;
        this.loadTransfers();
    }

    handleNewTransfer() {
        this.activeView = 'create';
        this.resetCreateForm();
    }

    handleViewTransfer(event) {
        const transferId = event.currentTarget.dataset.id;
        this.loadTransferDetail(transferId);
    }

    handleBackToList() {
        this.activeView = 'list';
        this.transferDetail = null;
        this.loadTransfers();
    }

    // ──────────────────────────────────────────────────────────────
    // Event Handlers - Create Form
    // ──────────────────────────────────────────────────────────────

    handleSourceWarehouseChange(event) {
        this.sourceWarehouseId = event.detail.value;
        this.loadSourceProducts();
    }

    handleDestWarehouseChange(event) {
        this.destinationWarehouseId = event.detail.value;
    }

    handleTransferDateChange(event) {
        this.transferDate = event.detail.value;
    }

    handleTransferNotesChange(event) {
        this.transferNotes = event.detail.value;
    }

    handleAddLine() {
        this.lineItems = [
            ...this.lineItems,
            {
                key: this.nextLineKey++,
                productId: '',
                batchNumber: '',
                requestedQty: 0
            }
        ];
    }

    handleLineProductChange(event) {
        const key = parseInt(event.currentTarget.dataset.key, 10);
        const value = event.detail.value;
        this.lineItems = this.lineItems.map(line => {
            if (line.key === key) {
                const product = this.sourceProducts.find(p => p.value === value);
                return {
                    ...line,
                    productId: value,
                    batchNumber: product ? product.batchNumber : ''
                };
            }
            return line;
        });
    }

    handleLineQtyChange(event) {
        const key = parseInt(event.currentTarget.dataset.key, 10);
        const value = parseFloat(event.detail.value) || 0;
        this.lineItems = this.lineItems.map(line =>
            line.key === key ? { ...line, requestedQty: value } : line
        );
    }

    handleRemoveLine(event) {
        const key = parseInt(event.currentTarget.dataset.key, 10);
        this.lineItems = this.lineItems.filter(line => line.key !== key);
    }

    handleSaveTransfer() {
        if (!this.sourceWarehouseId || !this.destinationWarehouseId) {
            this.errorMessage = 'Please select both source and destination warehouses.';
            return;
        }
        if (this.sourceWarehouseId === this.destinationWarehouseId) {
            this.errorMessage = 'Source and destination warehouses must be different.';
            return;
        }
        const validLines = this.lineItems.filter(l => l.productId && l.requestedQty > 0);
        if (validLines.length === 0) {
            this.errorMessage = 'Please add at least one line item with a product and quantity.';
            return;
        }

        this.isLoading = true;
        this.errorMessage = '';

        const lineItemsJson = JSON.stringify(validLines.map(l => ({
            productId: l.productId,
            batchNumber: l.batchNumber,
            requestedQty: l.requestedQty
        })));

        createTransfer({
            sourceWarehouseId: this.sourceWarehouseId,
            destinationWarehouseId: this.destinationWarehouseId,
            transferDate: this.transferDate,
            notes: this.transferNotes,
            lineItems: lineItemsJson
        })
            .then(result => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Success',
                    message: 'Stock transfer created successfully.',
                    variant: 'success'
                }));
                this.loadTransferDetail(result);
            })
            .catch(error => this.handleError(error, 'Failed to create transfer'))
            .finally(() => { this.isLoading = false; });
    }

    handleCancelCreate() {
        this.activeView = 'list';
        this.resetCreateForm();
    }

    // ──────────────────────────────────────────────────────────────
    // Event Handlers - Detail View
    // ──────────────────────────────────────────────────────────────

    handleSubmitTransfer() {
        if (!this.transferDetail || !this.transferDetail.transfer) return;
        this.isLoading = true;
        submitTransfer({ transferId: this.transferDetail.transfer.Id })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Success',
                    message: 'Transfer submitted for approval.',
                    variant: 'success'
                }));
                this.loadTransferDetail(this.transferDetail.transfer.Id);
            })
            .catch(error => this.handleError(error, 'Failed to submit transfer'))
            .finally(() => { this.isLoading = false; });
    }

    handleApproveTransfer() {
        if (!this.transferDetail || !this.transferDetail.transfer) return;
        this.isLoading = true;
        approveTransfer({ transferId: this.transferDetail.transfer.Id })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Success',
                    message: 'Transfer approved — source stock deducted. Ready to receive.',
                    variant: 'success'
                }));
                this.loadTransferDetail(this.transferDetail.transfer.Id);
            })
            .catch(error => this.handleError(error, 'Failed to approve transfer'))
            .finally(() => { this.isLoading = false; });
    }

    handleOpenReceiveModal() {
        if (!this.transferDetail || !this.transferDetail.lineItems) return;
        this.receiveLineItems = this.transferDetail.lineItems.map(line => ({
            id: line.Id,
            productName: line.Product_Ext__r ? line.Product_Ext__r.Name : '',
            approvedQty: line.Approved_Qty__c || line.Requested_Qty__c || 0,
            receivedQty: line.Approved_Qty__c || line.Requested_Qty__c || 0
        }));
        this.showReceiveModal = true;
    }

    handleCloseReceiveModal() {
        this.showReceiveModal = false;
    }

    handleReceiveQtyChange(event) {
        const lineId = event.currentTarget.dataset.id;
        const value = parseFloat(event.detail.value) || 0;
        this.receiveLineItems = this.receiveLineItems.map(line =>
            line.id === lineId ? { ...line, receivedQty: value } : line
        );
    }

    handleConfirmReceive() {
        this.isLoading = true;
        this.showReceiveModal = false;

        const receivedItems = JSON.stringify(this.receiveLineItems.map(line => ({
            lineItemId: line.id,
            receivedQty: line.receivedQty
        })));

        receiveTransfer({
            transferId: this.transferDetail.transfer.Id,
            receivedItems
        })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Success',
                    message: 'Transfer received successfully.',
                    variant: 'success'
                }));
                this.loadTransferDetail(this.transferDetail.transfer.Id);
            })
            .catch(error => this.handleError(error, 'Failed to receive transfer'))
            .finally(() => { this.isLoading = false; });
    }

    // ──────────────────────────────────────────────────────────────
    // Computed Properties
    // ──────────────────────────────────────────────────────────────

    get isListView() { return this.activeView === 'list'; }
    get isCreateView() { return this.activeView === 'create'; }
    get isDetailView() { return this.activeView === 'detail'; }

    get hasTransfers() { return this.transfers && this.transfers.length > 0; }
    get hasLineItems() { return this.lineItems && this.lineItems.length > 0; }
    get hasSourceProducts() { return this.sourceProducts && this.sourceProducts.length > 0; }

    get productOptions() {
        return this.sourceProducts;
    }

    // Source chosen, load finished, nothing available — so the empty product list is explained.
    get noSourceProducts() {
        return !!this.sourceWarehouseId && this.productsLoaded && this.sourceProducts.length === 0;
    }

    get statusFilterOptions() {
        return [
            { label: 'All Statuses', value: 'all' },
            { label: 'Draft', value: 'Draft' },
            { label: 'Submitted', value: 'Submitted' },
            { label: 'Approved', value: 'Approved' },
            { label: 'In Transit', value: 'In_Transit' },
            { label: 'Received', value: 'Received' },
            { label: 'Cancelled', value: 'Cancelled' }
        ];
    }

    get filterWarehouseOptions() {
        // warehouseOptions no longer carries a leading '' placeholder, so include all of them.
        return [{ label: 'All Warehouses', value: '' }, ...this.warehouseOptions];
    }

    get detailTransfer() {
        if (!this.transferDetail || !this.transferDetail.transfer) return null;
        const t = this.transferDetail.transfer;
        return {
            name: t.Name,
            sourceName: t.Source_Warehouse__r ? t.Source_Warehouse__r.Name : '',
            destName: t.Destination_Warehouse__r ? t.Destination_Warehouse__r.Name : '',
            transferDate: t.Transfer_Date__c,
            status: t.Status__c,
            requestedBy: t.Requested_By__r ? t.Requested_By__r.Name : '',
            approvedBy: t.Approved_By__r ? t.Approved_By__r.Name : '',
            notes: t.Notes__c || ''
        };
    }

    get detailLineItems() {
        if (!this.transferDetail || !this.transferDetail.lineItems) return [];
        return this.transferDetail.lineItems.map(line => ({
            id: line.Id,
            name: line.Name,
            productName: line.Product_Ext__r ? line.Product_Ext__r.Name : '',
            productCode: line.Product_Ext__r ? line.Product_Ext__r.SKU_Code__c : '',
            batchNumber: line.Batch_Number__c || '',
            requestedQty: line.Requested_Qty__c || 0,
            approvedQty: line.Approved_Qty__c || 0,
            receivedQty: line.Received_Qty__c || 0,
            shortQty: line.Short_Qty__c || 0,
            availableStock: line.Available_Stock__c || 0
        }));
    }

    get canSubmit() {
        return this.transferDetail &&
               this.transferDetail.transfer &&
               this.transferDetail.transfer.Status__c === 'Draft';
    }

    get canApprove() {
        return this.transferDetail &&
               this.transferDetail.transfer &&
               this.transferDetail.transfer.Status__c === 'Submitted';
    }

    get canReceive() {
        return this.transferDetail &&
               this.transferDetail.transfer &&
               (this.transferDetail.transfer.Status__c === 'Approved' ||
                this.transferDetail.transfer.Status__c === 'In_Transit');
    }

    // ──────────────────────────────────────────────────────────────
    // Utility
    // ──────────────────────────────────────────────────────────────

    resetCreateForm() {
        this.sourceWarehouseId = '';
        this.destinationWarehouseId = '';
        this.transferDate = new Date().toISOString().split('T')[0];
        this.transferNotes = '';
        this.lineItems = [];
        this.sourceProducts = [];
        this.nextLineKey = 1;
        this.errorMessage = '';
    }

    getStatusClass(status) {
        const classMap = {
            'Draft': 'slds-badge',
            'Submitted': 'slds-badge slds-badge_inverse',
            'Approved': 'slds-badge',
            'In_Transit': 'slds-badge slds-badge_inverse',
            'Received': 'slds-badge',
            'Cancelled': 'slds-badge'
        };
        return classMap[status] || 'slds-badge';
    }

    handleError(error, context) {
        let message = context || 'An error occurred';
        if (error) {
            if (error.body && error.body.message) {
                message += ': ' + error.body.message;
            } else if (error.message) {
                message += ': ' + error.message;
            }
        }
        this.errorMessage = message;
        console.error(context, JSON.stringify(error));
    }
}