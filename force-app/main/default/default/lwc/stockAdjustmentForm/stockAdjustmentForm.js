import { LightningElement, track } from 'lwc';
import getWarehouses from '@salesforce/apex/INV_WarehouseStockController.getWarehouses';
import checkStockAvailability from '@salesforce/apex/INV_WarehouseStockController.checkStockAvailability';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { createRecord, updateRecord } from 'lightning/uiRecordApi';
import ID_FIELD from '@salesforce/schema/Stock_Adjustment__c.Id';
import STOCK_ADJUSTMENT_OBJECT from '@salesforce/schema/Stock_Adjustment__c';
import WAREHOUSE_FIELD from '@salesforce/schema/Stock_Adjustment__c.Warehouse__c';
import PRODUCT_FIELD from '@salesforce/schema/Stock_Adjustment__c.Product_Ext__c';
import BATCH_FIELD from '@salesforce/schema/Stock_Adjustment__c.Batch_Number__c';
import ADJ_TYPE_FIELD from '@salesforce/schema/Stock_Adjustment__c.Adjustment_Type__c';
import SYSTEM_QTY_FIELD from '@salesforce/schema/Stock_Adjustment__c.System_Qty__c';
import ACTUAL_QTY_FIELD from '@salesforce/schema/Stock_Adjustment__c.Actual_Qty__c';
import ADJ_QTY_FIELD from '@salesforce/schema/Stock_Adjustment__c.Adjustment_Qty__c';
import REASON_FIELD from '@salesforce/schema/Stock_Adjustment__c.Reason__c';
import STATUS_FIELD from '@salesforce/schema/Stock_Adjustment__c.Status__c';
import ADJ_DATE_FIELD from '@salesforce/schema/Stock_Adjustment__c.Adjustment_Date__c';

export default class StockAdjustmentForm extends LightningElement {
    // State
    isLoading = false;
    errorMessage = '';
    successMessage = '';

    // Warehouse options
    @track warehouseOptions = [];

    // Form fields
    selectedWarehouseId = '';
    selectedProductId = '';
    batchNumber = '';
    adjustmentType = '';
    systemQty = 0;
    actualQty = 0;
    adjustmentQty = 0;
    reason = '';
    adjustmentDate = new Date().toISOString().split('T')[0];
    stockChecked = false;

    // Adjustment history
    @track adjustmentHistory = [];
    historyLoaded = false;

    // ──────────────────────────────────────────────────────────────
    // Lifecycle
    // ──────────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadWarehouses();
    }

    // ──────────────────────────────────────────────────────────────
    // Data Loading
    // ──────────────────────────────────────────────────────────────

    loadWarehouses() {
        getWarehouses()
            .then(result => {
                // No empty '' placeholder option: on a required combobox that flips the field
                // to an invalid ("Complete this field") state the moment it's touched. Use the
                // combobox's own `placeholder` attribute instead.
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

    checkCurrentStock() {
        if (!this.selectedWarehouseId || !this.selectedProductId) {
            return;
        }
        this.isLoading = true;
        checkStockAvailability({
            warehouseId: this.selectedWarehouseId,
            productId: this.selectedProductId
        })
            .then(result => {
                this.systemQty = result.totalOnHand || 0;
                this.stockChecked = true;
                this.errorMessage = '';
            })
            .catch(error => this.handleError(error, 'Failed to check stock'))
            .finally(() => { this.isLoading = false; });
    }

    // ──────────────────────────────────────────────────────────────
    // Event Handlers
    // ──────────────────────────────────────────────────────────────

    handleWarehouseChange(event) {
        this.selectedWarehouseId = event.detail.value;
        this.stockChecked = false;
        this.systemQty = 0;
    }

    handleProductChange(event) {
        // lightning-record-picker exposes the selection as event.detail.recordId (null when
        // cleared) — not event.detail.value, which is undefined here and left the product
        // unset, so "Check Stock" stayed disabled even after a product was picked.
        this.selectedProductId = event.detail.recordId || '';
        this.stockChecked = false;
        this.systemQty = 0;
    }

    handleBatchChange(event) {
        this.batchNumber = event.detail.value;
    }

    handleTypeChange(event) {
        this.adjustmentType = event.detail.value;
    }

    handleActualQtyChange(event) {
        this.actualQty = parseFloat(event.detail.value) || 0;
        if (this.adjustmentType === 'Physical_Count') {
            this.adjustmentQty = this.actualQty - this.systemQty;
        }
    }

    handleAdjustmentQtyChange(event) {
        this.adjustmentQty = parseFloat(event.detail.value) || 0;
    }

    handleReasonChange(event) {
        this.reason = event.detail.value;
    }

    handleDateChange(event) {
        this.adjustmentDate = event.detail.value;
    }

    handleCheckStock() {
        this.checkCurrentStock();
    }

    handleSubmit() {
        this.errorMessage = '';
        this.successMessage = '';

        // Validation
        if (!this.selectedWarehouseId) {
            this.errorMessage = 'Please select a warehouse.';
            return;
        }
        if (!this.selectedProductId) {
            this.errorMessage = 'Please select a product.';
            return;
        }
        if (!this.adjustmentType) {
            this.errorMessage = 'Please select an adjustment type.';
            return;
        }
        if (this.adjustmentQty === 0) {
            this.errorMessage = 'Adjustment quantity cannot be zero.';
            return;
        }
        if (!this.reason || this.reason.trim() === '') {
            this.errorMessage = 'Reason is required for all adjustments.';
            return;
        }

        this.isLoading = true;

        const fields = {};
        fields[WAREHOUSE_FIELD.fieldApiName] = this.selectedWarehouseId;
        fields[PRODUCT_FIELD.fieldApiName] = this.selectedProductId;
        fields[BATCH_FIELD.fieldApiName] = this.batchNumber || null;
        fields[ADJ_TYPE_FIELD.fieldApiName] = this.adjustmentType;
        fields[SYSTEM_QTY_FIELD.fieldApiName] = this.systemQty;
        fields[ACTUAL_QTY_FIELD.fieldApiName] = this.adjustmentType === 'Physical_Count' ? this.actualQty : null;
        fields[ADJ_QTY_FIELD.fieldApiName] = this.adjustmentQty;
        fields[REASON_FIELD.fieldApiName] = this.reason;
        fields[STATUS_FIELD.fieldApiName] = 'Draft';
        fields[ADJ_DATE_FIELD.fieldApiName] = this.adjustmentDate;

        // Create as Draft, then immediately approve it. The trigger applies the stock change
        // (and writes the ledger row) on the Draft->Approved transition, and there is no separate
        // approval UI, so a plain Draft would just sit there and never move stock.
        createRecord({ apiName: STOCK_ADJUSTMENT_OBJECT.objectApiName, fields })
            .then(result => {
                const approveFields = {};
                approveFields[ID_FIELD.fieldApiName] = result.id;
                approveFields[STATUS_FIELD.fieldApiName] = 'Approved';
                return updateRecord({ fields: approveFields });
            })
            .then(() => {
                this.successMessage = 'Stock adjustment applied — the warehouse stock and the movement ledger have been updated.';
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Adjustment applied',
                    message: 'Warehouse stock and the movement ledger have been updated.',
                    variant: 'success'
                }));
                this.resetForm();
            })
            .catch(error => this.handleError(error, 'Failed to create adjustment'))
            .finally(() => { this.isLoading = false; });
    }

    handleReset() {
        this.resetForm();
        this.errorMessage = '';
        this.successMessage = '';
    }

    // ──────────────────────────────────────────────────────────────
    // Computed Properties
    // ──────────────────────────────────────────────────────────────

    get adjustmentTypeOptions() {
        return [
            { label: 'Physical Count', value: 'Physical_Count' },
            { label: 'Damage', value: 'Damage' },
            { label: 'Expiry Write-Off', value: 'Expiry_Write_Off' },
            { label: 'Correction (Add)', value: 'Correction_Add' },
            { label: 'Correction (Deduct)', value: 'Correction_Deduct' }
        ];
    }

    get isPhysicalCount() {
        return this.adjustmentType === 'Physical_Count';
    }

    get isManualAdjustment() {
        return this.adjustmentType && this.adjustmentType !== 'Physical_Count';
    }

    get canCheckStock() {
        return this.selectedWarehouseId && this.selectedProductId;
    }

    get isCheckStockDisabled() {
        return !this.canCheckStock;
    }

    get adjustmentDirection() {
        if (this.adjustmentQty > 0) return 'Add';
        if (this.adjustmentQty < 0) return 'Deduct';
        return 'None';
    }

    get adjustmentDirectionClass() {
        if (this.adjustmentQty > 0) return 'stock-level_healthy';
        if (this.adjustmentQty < 0) return 'stock-level_danger';
        return '';
    }

    get formattedSystemQty() {
        return Number(this.systemQty).toLocaleString();
    }

    get formattedAdjQty() {
        const prefix = this.adjustmentQty > 0 ? '+' : '';
        return prefix + Number(this.adjustmentQty).toLocaleString();
    }

    get projectedQty() {
        return Number(this.systemQty + this.adjustmentQty).toLocaleString();
    }

    // ──────────────────────────────────────────────────────────────
    // Utility
    // ──────────────────────────────────────────────────────────────

    resetForm() {
        this.selectedProductId = '';
        this.batchNumber = '';
        this.adjustmentType = '';
        this.systemQty = 0;
        this.actualQty = 0;
        this.adjustmentQty = 0;
        this.reason = '';
        this.adjustmentDate = new Date().toISOString().split('T')[0];
        this.stockChecked = false;
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