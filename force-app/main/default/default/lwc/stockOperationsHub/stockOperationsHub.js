import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getActiveWarehouses from '@salesforce/apex/StockOperationsHubController.getActiveWarehouses';
import getAvailability from '@salesforce/apex/StockOperationsHubController.getAvailability';
import searchSourceProducts from '@salesforce/apex/StockOperationsHubController.searchSourceProducts';
import getMyRequests from '@salesforce/apex/StockOperationsHubController.getMyRequests';
import createRequest from '@salesforce/apex/StockOperationsHubController.createRequest';
import submitRequest from '@salesforce/apex/StockOperationsHubController.submitRequest';
import getPendingReceipts from '@salesforce/apex/StockOperationsHubController.getPendingReceipts';
import getRequestLines from '@salesforce/apex/StockOperationsHubController.getRequestLines';
import confirmReceipt from '@salesforce/apex/StockOperationsHubController.confirmReceipt';

const TABS = {
    AVAILABILITY: 'availability',
    REQUESTS: 'requests',
    RECEIPTS: 'receipts',
    ADJUSTMENTS: 'adjustments'
};

export default class StockOperationsHub extends NavigationMixin(LightningElement) {
    @track activeTab = TABS.AVAILABILITY;
    @track warehouses = [];

    // ── Availability tab ──
    @track availabilityWarehouseId = null;
    @track availabilitySearch = '';
    @track availabilityFilter = 'all';
    @track availabilityRows = [];
    @track loadingAvailability = false;

    // ── Requests tab ──
    @track requests = [];
    @track requestFilter = 'all';
    @track requestSearch = '';
    @track loadingRequests = false;

    // ── Request create modal ──
    @track showRequestModal = false;
    @track requestForm = this._emptyRequestForm();
    @track productSearchTerm = '';
    @track productSearchResults = [];
    @track isCreatingRequest = false;

    // ── Submit-for-approval modal ──
    @track showSubmitModal = false;
    @track submitTargetId = null;
    @track submitTargetName = '';
    @track submitComments = '';
    @track isSubmitting = false;

    // ── Receipts tab ──
    @track receipts = [];
    @track loadingReceipts = false;

    // ── Receipt confirm modal ──
    @track showReceiptModal = false;
    @track receiptTargetId = null;
    @track receiptTargetName = '';
    @track receiptLines = [];
    @track isConfirmingReceipt = false;

    _productSearchTimer;

    connectedCallback() {
        this._loadWarehouses();
        this._loadAvailability();
        this._loadRequests();
        this._loadReceipts();
    }

    // ── Tab plumbing ──
    get tabPills() {
        const pills = [
            { key: TABS.AVAILABILITY, label: 'Availability', icon: 'utility:knowledge_base' },
            { key: TABS.REQUESTS, label: 'Requests', icon: 'utility:upload' },
            { key: TABS.RECEIPTS, label: 'Receipts', icon: 'utility:download' },
            { key: TABS.ADJUSTMENTS, label: 'Adjustments', icon: 'utility:edit' }
        ];
        return pills.map(p => ({
            ...p,
            cssClass: 'soh-pill' + (p.key === this.activeTab ? ' soh-pill-active' : '')
        }));
    }

    get isAvailability() { return this.activeTab === TABS.AVAILABILITY; }
    get isRequests() { return this.activeTab === TABS.REQUESTS; }
    get isReceipts() { return this.activeTab === TABS.RECEIPTS; }
    get isAdjustments() { return this.activeTab === TABS.ADJUSTMENTS; }

    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.key;
        if (this.isAdjustments) {
            // Don't render the empty Adjustments section — bounce straight to the
            // existing dedicated Adjustments tab where the full manager lives.
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: { url: '/lightning/n/Stock_Adjustments' }
            });
            // Stay on the previous tab visually so the click feels reversible.
            this.activeTab = TABS.AVAILABILITY;
        }
    }

    // ── Data loading ──
    async _loadWarehouses() {
        try {
            this.warehouses = await getActiveWarehouses();
            if (!this.availabilityWarehouseId && this.warehouses.length) {
                this.availabilityWarehouseId = this.warehouses[0].value;
                this._loadAvailability();
            }
        } catch (e) { this._toast('Error', this._err(e), 'error'); }
    }

    get warehouseOptions() {
        return this.warehouses.map(w => ({ label: w.label, value: w.value }));
    }

    // ── Availability tab ──
    get availabilityFilterPills() {
        const pills = [
            { key: 'all', label: 'All' },
            { key: 'low', label: 'Low Stock' },
            { key: 'zero', label: 'Out of Stock' }
        ];
        return pills.map(p => ({
            ...p,
            cssClass: 'soh-filter' + (p.key === this.availabilityFilter ? ' soh-filter-active' : '')
        }));
    }

    async _loadAvailability() {
        if (!this.availabilityWarehouseId) {
            this.availabilityRows = [];
            return;
        }
        this.loadingAvailability = true;
        try {
            const rows = await getAvailability({
                warehouseId: this.availabilityWarehouseId,
                searchTerm: this.availabilitySearch,
                filterMode: this.availabilityFilter
            });
            this.availabilityRows = (rows || []).map(r => ({
                ...r,
                stockBadge: r.isZero ? 'OUT' : (r.isLow ? 'LOW' : 'OK'),
                stockBadgeClass: 'soh-stock-badge ' +
                    (r.isZero ? 'soh-badge-zero' : (r.isLow ? 'soh-badge-low' : 'soh-badge-ok'))
            }));
        } catch (e) { this._toast('Error', this._err(e), 'error'); }
        this.loadingAvailability = false;
    }

    handleAvailabilityWarehouseChange(event) {
        this.availabilityWarehouseId = event.detail.value;
        this._loadAvailability();
    }
    handleAvailabilitySearch(event) {
        this.availabilitySearch = event.target.value || '';
        this._loadAvailability();
    }
    handleAvailabilityFilter(event) {
        this.availabilityFilter = event.currentTarget.dataset.key;
        this._loadAvailability();
    }

    // ── Requests tab ──
    get requestFilterPills() {
        const counts = {
            all: this.requests.length,
            Draft: this.requests.filter(r => r.status === 'Draft').length,
            Submitted: this.requests.filter(r => r.status === 'Submitted').length,
            Approved: this.requests.filter(r => r.status === 'Approved').length,
            In_Transit: this.requests.filter(r => r.status === 'In_Transit').length,
            Received: this.requests.filter(r => r.status === 'Received').length
        };
        const pills = [
            { key: 'all', label: 'All' },
            { key: 'Draft', label: 'Draft' },
            { key: 'Submitted', label: 'Submitted' },
            { key: 'Approved', label: 'Approved' },
            { key: 'In_Transit', label: 'In Transit' },
            { key: 'Received', label: 'Received' }
        ];
        return pills.map(p => ({
            ...p,
            count: counts[p.key],
            cssClass: 'soh-filter' + (p.key === this.requestFilter ? ' soh-filter-active' : '')
        }));
    }

    get filteredRequests() {
        const term = (this.requestSearch || '').toLowerCase();
        return this.requests
            .filter(r => this.requestFilter === 'all' || r.status === this.requestFilter)
            .filter(r => !term ||
                (r.name || '').toLowerCase().includes(term) ||
                (r.sourceWarehouse || '').toLowerCase().includes(term) ||
                (r.destinationWarehouse || '').toLowerCase().includes(term) ||
                (r.requestedBy || '').toLowerCase().includes(term))
            .map(r => ({
                ...r,
                statusClass: 'soh-status ' + this._statusClass(r.status),
                statusLabel: r.status.replace('_', ' '),
                canSubmit: r.status === 'Draft' && r.isMine
            }));
    }
    get hasRequests() { return this.filteredRequests.length > 0; }

    handleRequestFilter(event) {
        this.requestFilter = event.currentTarget.dataset.key;
    }
    handleRequestSearch(event) {
        this.requestSearch = event.target.value || '';
    }

    async _loadRequests() {
        this.loadingRequests = true;
        try { this.requests = await getMyRequests(); }
        catch (e) { this._toast('Error', this._err(e), 'error'); }
        this.loadingRequests = false;
    }

    // ── Request create modal ──
    _emptyRequestForm() {
        return {
            sourceWarehouseId: null,
            destinationWarehouseId: null,
            transferDate: this._today(),
            notes: '',
            lines: []
        };
    }

    handleNewRequest() {
        this.requestForm = this._emptyRequestForm();
        this.productSearchTerm = '';
        this.productSearchResults = [];
        this.showRequestModal = true;
    }
    handleCloseRequestModal() { this.showRequestModal = false; }

    handleRequestSourceChange(event) {
        this.requestForm = { ...this.requestForm, sourceWarehouseId: event.detail.value };
        this.productSearchResults = [];
    }
    handleRequestDestChange(event) {
        this.requestForm = { ...this.requestForm, destinationWarehouseId: event.detail.value };
    }
    handleRequestDateChange(event) {
        this.requestForm = { ...this.requestForm, transferDate: event.target.value };
    }
    handleRequestNotesChange(event) {
        this.requestForm = { ...this.requestForm, notes: event.target.value };
    }

    handleProductSearch(event) {
        const term = event.target.value || '';
        this.productSearchTerm = term;
        if (this._productSearchTimer) clearTimeout(this._productSearchTimer);
        if (!this.requestForm.sourceWarehouseId || term.length < 2) {
            this.productSearchResults = [];
            return;
        }
        this._productSearchTimer = setTimeout(async () => {
            try {
                this.productSearchResults = await searchSourceProducts({
                    sourceWarehouseId: this.requestForm.sourceWarehouseId,
                    searchTerm: term
                });
            } catch (e) { this.productSearchResults = []; }
        }, 250);
    }

    handleAddLine(event) {
        const productId = event.currentTarget.dataset.id;
        const product = this.productSearchResults.find(p => p.value === productId);
        if (!product) return;
        if (this.requestForm.lines.some(l => l.productId === productId)) {
            this._toast('Already added', product.label + ' is already in the request', 'warning');
            return;
        }
        this.requestForm = {
            ...this.requestForm,
            lines: [
                ...this.requestForm.lines,
                {
                    productId: product.value,
                    productName: product.label,
                    batchNumber: product.batchNumber || '',
                    availableQty: product.availableQty,
                    requestedQty: 1,
                    _key: product.value + '_' + Date.now()
                }
            ]
        };
        this.productSearchTerm = '';
        this.productSearchResults = [];
    }

    handleLineQtyChange(event) {
        const key = event.target.dataset.key;
        const qty = event.target.value === '' ? null : Number(event.target.value);
        this.requestForm = {
            ...this.requestForm,
            lines: this.requestForm.lines.map(l =>
                l._key === key ? { ...l, requestedQty: qty } : l
            )
        };
    }

    handleRemoveLine(event) {
        const key = event.currentTarget.dataset.key;
        this.requestForm = {
            ...this.requestForm,
            lines: this.requestForm.lines.filter(l => l._key !== key)
        };
    }

    get hasRequestLines() { return this.requestForm.lines.length > 0; }
    get saveRequestDisabled() {
        return this.isCreatingRequest ||
            !this.requestForm.sourceWarehouseId ||
            !this.requestForm.destinationWarehouseId ||
            this.requestForm.sourceWarehouseId === this.requestForm.destinationWarehouseId ||
            this.requestForm.lines.length === 0 ||
            this.requestForm.lines.some(l => !l.requestedQty || l.requestedQty <= 0);
    }

    async handleSaveRequest() {
        if (this.saveRequestDisabled) return;
        this.isCreatingRequest = true;
        try {
            const payload = JSON.stringify(
                this.requestForm.lines.map(l => ({
                    productId: l.productId,
                    batchNumber: l.batchNumber,
                    requestedQty: l.requestedQty
                }))
            );
            await createRequest({
                sourceWarehouseId: this.requestForm.sourceWarehouseId,
                destinationWarehouseId: this.requestForm.destinationWarehouseId,
                transferDate: this.requestForm.transferDate,
                notes: this.requestForm.notes,
                lineItemsJson: payload
            });
            this._toast('Saved', 'Stock request created as Draft', 'success');
            this.showRequestModal = false;
            await this._loadRequests();
        } catch (e) { this._toast('Error', this._err(e), 'error'); }
        this.isCreatingRequest = false;
    }

    // ── Submit-for-approval modal ──
    handleSubmitClick(event) {
        const id = event.currentTarget.dataset.id;
        const r = this.requests.find(x => x.id === id);
        if (!r) return;
        this.submitTargetId = id;
        this.submitTargetName = r.name;
        this.submitComments = '';
        this.showSubmitModal = true;
    }
    handleCloseSubmitModal() { this.showSubmitModal = false; }
    handleSubmitCommentsChange(event) { this.submitComments = event.target.value; }

    async handleConfirmSubmit() {
        if (this.isSubmitting) return;
        this.isSubmitting = true;
        try {
            await submitRequest({ transferId: this.submitTargetId, comments: this.submitComments });
            this._toast('Submitted', 'Sent for approval', 'success');
            this.showSubmitModal = false;
            await this._loadRequests();
        } catch (e) { this._toast('Error', this._err(e), 'error'); }
        this.isSubmitting = false;
    }

    // ── Receipts tab ──
    get hasReceipts() { return this.receipts.length > 0; }

    async _loadReceipts() {
        this.loadingReceipts = true;
        try {
            const rows = await getPendingReceipts();
            this.receipts = (rows || []).map(r => ({
                ...r,
                statusClass: 'soh-status ' + this._statusClass(r.status),
                statusLabel: r.status.replace('_', ' ')
            }));
        } catch (e) { this._toast('Error', this._err(e), 'error'); }
        this.loadingReceipts = false;
    }

    // ── Receipt confirm modal ──
    async handleConfirmReceiptClick(event) {
        const id = event.currentTarget.dataset.id;
        const r = this.receipts.find(x => x.id === id);
        if (!r) return;
        this.receiptTargetId = id;
        this.receiptTargetName = r.name;
        try {
            const lines = await getRequestLines({ transferId: id });
            // Per-line working state, with the input pre-populated to the
            // default (approved or requested) qty as the spec calls for.
            this.receiptLines = (lines || []).map(l => ({
                ...l,
                receivedInput: l.defaultReceivedQty
            }));
            this.showReceiptModal = true;
        } catch (e) { this._toast('Error', this._err(e), 'error'); }
    }
    handleCloseReceiptModal() { this.showReceiptModal = false; }

    handleReceivedQtyChange(event) {
        const id = event.target.dataset.id;
        const qty = event.target.value === '' ? null : Number(event.target.value);
        this.receiptLines = this.receiptLines.map(l =>
            l.id === id ? { ...l, receivedInput: qty } : l
        );
    }

    get confirmReceiptDisabled() {
        return this.isConfirmingReceipt ||
            this.receiptLines.some(l => l.receivedInput == null || l.receivedInput < 0);
    }

    async handleConfirmReceipt() {
        if (this.confirmReceiptDisabled) return;
        this.isConfirmingReceipt = true;
        try {
            const payload = JSON.stringify(this.receiptLines.map(l => ({
                lineItemId: l.id,
                receivedQty: l.receivedInput
            })));
            await confirmReceipt({ transferId: this.receiptTargetId, receivedItemsJson: payload });
            this._toast('Received', 'Stock added to destination warehouse', 'success');
            this.showReceiptModal = false;
            await this._loadReceipts();
            await this._loadRequests();
        } catch (e) { this._toast('Error', this._err(e), 'error'); }
        this.isConfirmingReceipt = false;
    }

    // ── Helpers ──
    _statusClass(s) {
        if (s === 'Draft') return 'soh-status-draft';
        if (s === 'Submitted') return 'soh-status-submitted';
        if (s === 'Approved') return 'soh-status-approved';
        if (s === 'In_Transit') return 'soh-status-transit';
        if (s === 'Received') return 'soh-status-received';
        if (s === 'Rejected' || s === 'Cancelled') return 'soh-status-rejected';
        return '';
    }
    _today() { return new Date().toISOString().slice(0, 10); }
    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    _err(e) {
        if (!e) return 'Unknown error';
        if (e.body && e.body.message) return e.body.message;
        if (Array.isArray(e.body)) return e.body.map(x => x.message).join(', ');
        if (e.message) return e.message;
        return JSON.stringify(e);
    }
}