import { LightningElement, track } from 'lwc';
import getWarehouseStockKPIs from '@salesforce/apex/INV_WarehouseStockController.getWarehouseStockKPIs';
import getWarehouseStock from '@salesforce/apex/INV_WarehouseStockController.getWarehouseStock';
import getWarehouses from '@salesforce/apex/INV_WarehouseStockController.getWarehouses';
import getStockTransactions from '@salesforce/apex/INV_WarehouseStockController.getStockTransactions';
import getLowStockAlerts from '@salesforce/apex/INV_WarehouseStockController.getLowStockAlerts';

const PAGE_SIZE = 25;

export default class WarehouseStockDashboard extends LightningElement {
    // --- State ---
    isLoading = false;
    errorMessage = '';
    activeTab = 'currentStock';

    // Warehouse selector
    @track warehouseOptions = [];
    selectedWarehouseId = '';

    // KPI data
    @track kpis = {
        totalSkus: 0,
        totalOnHand: 0,
        totalReserved: 0,
        totalAvailable: 0,
        totalDamaged: 0,
        lowStockCount: 0,
        zeroStockCount: 0
    };

    // Current Stock tab
    productSearch = '';
    stockFilter = 'all';
    @track stockRecords = [];
    stockTotalCount = 0;
    currentOffset = 0;
    _searchTimeout;

    // Transaction Log tab
    @track transactionRecords = [];
    transactionsLoaded = false;

    // Low Stock Alerts tab
    @track lowStockRecords = [];
    lowStockLoaded = false;

    // ──────────────────────────────────────────────────────────────
    // Lifecycle
    // ──────────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadWarehouses();
        this.loadKPIs();
        this.loadCurrentStock();
        this.loadTransactions();
        this.loadLowStockAlerts();
    }

    // ──────────────────────────────────────────────────────────────
    // Data Loading
    // ──────────────────────────────────────────────────────────────

    loadWarehouses() {
        getWarehouses()
            .then(result => {
                const opts = [{ label: 'All Warehouses', value: '' }];
                result.forEach(wh => {
                    opts.push({
                        label: wh.Name + ' (' + (wh.Warehouse_Code__c || '') + ')',
                        value: wh.Id
                    });
                });
                this.warehouseOptions = opts;
            })
            .catch(error => {
                this.handleError(error, 'Failed to load warehouses');
            });
    }

    loadKPIs() {
        this.isLoading = true;
        const warehouseId = this.selectedWarehouseId || null;
        getWarehouseStockKPIs({ warehouseId })
            .then(result => {
                this.kpis = result;
                this.errorMessage = '';
            })
            .catch(error => {
                this.handleError(error, 'Failed to load KPIs');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    loadCurrentStock() {
        this.isLoading = true;
        const warehouseId = this.selectedWarehouseId || null;
        const productSearch = this.productSearch || null;
        getWarehouseStock({
            warehouseId,
            productSearch,
            stockFilter: this.stockFilter,
            limitCount: PAGE_SIZE,
            offset: this.currentOffset
        })
            .then(result => {
                this.stockRecords = result.records || [];
                this.stockTotalCount = result.totalCount || 0;
                this.errorMessage = '';
            })
            .catch(error => {
                this.handleError(error, 'Failed to load stock records');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    loadTransactions() {
        this.isLoading = true;
        const warehouseId = this.selectedWarehouseId || null;
        getStockTransactions({
            warehouseId,
            productId: null,
            limitCount: 50
        })
            .then(result => {
                this.transactionRecords = result || [];
                this.transactionsLoaded = true;
                this.errorMessage = '';
            })
            .catch(error => {
                this.transactionsLoaded = true;
                this.handleError(error, 'Failed to load transactions');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    loadLowStockAlerts() {
        this.isLoading = true;
        const warehouseId = this.selectedWarehouseId || null;
        getLowStockAlerts({ warehouseId })
            .then(result => {
                this.lowStockRecords = result || [];
                this.lowStockLoaded = true;
                this.errorMessage = '';
            })
            .catch(error => {
                this.lowStockLoaded = true;
                this.handleError(error, 'Failed to load low stock alerts');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    // ──────────────────────────────────────────────────────────────
    // Event Handlers
    // ──────────────────────────────────────────────────────────────

    handleWarehouseChange(event) {
        this.selectedWarehouseId = event.detail.value;
        this.currentOffset = 0;
        this.transactionsLoaded = false;
        this.lowStockLoaded = false;
        this.loadKPIs();
        this.loadCurrentStock();
        this.loadTransactions();
        this.loadLowStockAlerts();
    }

    handleRefresh() {
        this.errorMessage = '';
        this.loadKPIs();
        if (this.activeTab === 'currentStock') {
            this.loadCurrentStock();
        } else if (this.activeTab === 'transactions') {
            this.loadTransactions();
        } else if (this.activeTab === 'lowStock') {
            this.loadLowStockAlerts();
        }
    }

    handleTabChange(event) {
        this.activeTab = event.target.activeTabValue;
        if (this.activeTab === 'transactions' && !this.transactionsLoaded) {
            this.loadTransactions();
        } else if (this.activeTab === 'lowStock' && !this.lowStockLoaded) {
            this.loadLowStockAlerts();
        }
    }

    handleProductSearch(event) {
        const value = event.target.value;
        if (this._searchTimeout) {
            clearTimeout(this._searchTimeout);
        }
        this._searchTimeout = setTimeout(() => {
            this.productSearch = value;
            this.currentOffset = 0;
            this.loadCurrentStock();
        }, 300);
    }

    handleStockFilterAll() { this.setFilter('all'); }
    handleStockFilterLow() { this.setFilter('low'); }
    handleStockFilterZero() { this.setFilter('zero'); }
    handleStockFilterHealthy() { this.setFilter('healthy'); }

    setFilter(filter) {
        this.stockFilter = filter;
        this.currentOffset = 0;
        this.loadCurrentStock();
    }

    // Pagination
    handlePreviousPage() {
        if (this.currentOffset >= PAGE_SIZE) {
            this.currentOffset -= PAGE_SIZE;
            this.loadCurrentStock();
        }
    }

    handleNextPage() {
        if (this.currentOffset + PAGE_SIZE < this.stockTotalCount) {
            this.currentOffset += PAGE_SIZE;
            this.loadCurrentStock();
        }
    }

    // ──────────────────────────────────────────────────────────────
    // KPI Computed Properties
    // ──────────────────────────────────────────────────────────────

    get kpiTotalSkus() { return this.formatNumber(this.kpis.totalSkus); }
    get kpiTotalOnHand() { return this.formatNumber(this.kpis.totalOnHand); }
    get kpiTotalReserved() { return this.formatNumber(this.kpis.totalReserved); }
    get kpiTotalAvailable() { return this.formatNumber(this.kpis.totalAvailable); }
    get kpiLowStockCount() { return this.formatNumber(this.kpis.lowStockCount); }
    get kpiZeroStockCount() { return this.formatNumber(this.kpis.zeroStockCount); }

    get kpiLowStockClass() {
        return this.kpis.lowStockCount > 0 ? 'kpi-card kpi-card_warning' : 'kpi-card kpi-card_default';
    }

    get kpiLowStockIconVariant() {
        return this.kpis.lowStockCount > 0 ? 'warning' : '';
    }

    get kpiZeroStockClass() {
        return this.kpis.zeroStockCount > 0 ? 'kpi-card kpi-card_danger' : 'kpi-card kpi-card_default';
    }

    get kpiZeroStockIconVariant() {
        return this.kpis.zeroStockCount > 0 ? 'error' : '';
    }

    // ──────────────────────────────────────────────────────────────
    // Filter Button Variants
    // ──────────────────────────────────────────────────────────────

    get filterAllVariant() { return this.stockFilter === 'all' ? 'brand' : 'neutral'; }
    get filterLowVariant() { return this.stockFilter === 'low' ? 'brand' : 'neutral'; }
    get filterZeroVariant() { return this.stockFilter === 'zero' ? 'brand' : 'neutral'; }
    get filterHealthyVariant() { return this.stockFilter === 'healthy' ? 'brand' : 'neutral'; }

    // ──────────────────────────────────────────────────────────────
    // Stock Table Computed
    // ──────────────────────────────────────────────────────────────

    get hasStockRecords() {
        return this.stockRecords && this.stockRecords.length > 0;
    }

    get stockTableRows() {
        return this.stockRecords.map(rec => {
            const available = rec.Qty_Available__c != null ? rec.Qty_Available__c : 0;
            const onHand = rec.Qty_On_Hand__c != null ? rec.Qty_On_Hand__c : 0;
            const minLevel = rec.Min_Stock_Level__c != null ? rec.Min_Stock_Level__c : 0;

            let availableClass = 'stock-level_healthy';
            if (onHand === 0) {
                availableClass = 'stock-level_danger';
            } else if (available <= minLevel && available > 0) {
                availableClass = 'stock-level_warning';
            } else if (available <= 0) {
                availableClass = 'stock-level_danger';
            }

            return {
                id: rec.Id,
                name: rec.Name,
                warehouseName: rec.Warehouse__r ? rec.Warehouse__r.Name : '',
                productName: rec.Product_Ext__r ? rec.Product_Ext__r.Name : '',
                productCode: rec.Product_Ext__r ? rec.Product_Ext__r.SKU_Code__c : '',
                onHand: this.formatNumber(rec.Qty_On_Hand__c),
                reserved: this.formatNumber(rec.Qty_Reserved__c),
                available: this.formatNumber(available),
                availableClass,
                damaged: this.formatNumber(rec.Qty_Damaged__c),
                minLevel: this.formatNumber(rec.Min_Stock_Level__c),
                maxLevel: this.formatNumber(rec.Max_Stock_Level__c),
                batchNumber: rec.Batch_Number__c || '',
                expiryDate: this.formatDate(rec.Expiry_Date__c),
                lastTransaction: this.formatDateTime(rec.Last_Transaction_Date__c),
                isLowStock: rec.Is_Low_Stock__c === true,
                isZeroStock: rec.Is_Zero_Stock__c === true
            };
        });
    }

    // Pagination computed
    get currentPage() { return Math.floor(this.currentOffset / PAGE_SIZE) + 1; }
    get totalPages() { return Math.max(1, Math.ceil(this.stockTotalCount / PAGE_SIZE)); }
    get isPreviousDisabled() { return this.currentOffset === 0; }
    get isNextDisabled() { return this.currentOffset + PAGE_SIZE >= this.stockTotalCount; }

    // ──────────────────────────────────────────────────────────────
    // Transaction Log Computed
    // ──────────────────────────────────────────────────────────────

    get hasTransactionRecords() {
        return this.transactionsLoaded && this.transactionRecords && this.transactionRecords.length > 0;
    }

    get showTransactionPlaceholder() {
        return !this.transactionsLoaded;
    }

    get showTransactionEmpty() {
        return this.transactionsLoaded && (!this.transactionRecords || this.transactionRecords.length === 0);
    }

    get transactionTableRows() {
        return this.transactionRecords.map(rec => {
            const isIn = rec.Direction__c === 'In';
            return {
                id: rec.Id,
                name: rec.Name,
                warehouseName: rec.Warehouse__r ? rec.Warehouse__r.Name : '',
                productName: rec.Product_Ext__r ? rec.Product_Ext__r.Name : '',
                productCode: rec.Product_Ext__r ? rec.Product_Ext__r.SKU_Code__c : '',
                txnType: this.formatTxnType(rec.Transaction_Type__c),
                quantity: this.formatNumber(rec.Quantity__c),
                direction: rec.Direction__c,
                directionClass: isIn ? 'stock-level_healthy' : 'stock-level_danger',
                directionIcon: isIn ? '+' : '-',
                refType: rec.Reference_Type__c || '',
                refId: rec.Reference_Id__c || '',
                batchNumber: rec.Batch_Number__c || '',
                runningBalance: this.formatNumber(rec.Running_Balance__c),
                txnDate: this.formatDateTime(rec.Transaction_Date__c),
                txnBy: rec.Transaction_By__r ? rec.Transaction_By__r.Name : '',
                notes: rec.Notes__c || ''
            };
        });
    }

    // ──────────────────────────────────────────────────────────────
    // Low Stock Alerts Computed
    // ──────────────────────────────────────────────────────────────

    get hasLowStockRecords() {
        return this.lowStockLoaded && this.lowStockRecords && this.lowStockRecords.length > 0;
    }

    get showLowStockPlaceholder() {
        return !this.lowStockLoaded;
    }

    get showLowStockEmpty() {
        return this.lowStockLoaded && (!this.lowStockRecords || this.lowStockRecords.length === 0);
    }

    get lowStockTableRows() {
        return this.lowStockRecords.map(rec => {
            const available = rec.Qty_Available__c != null ? rec.Qty_Available__c : 0;
            const minLevel = rec.Min_Stock_Level__c != null ? rec.Min_Stock_Level__c : 0;
            const maxLevel = rec.Max_Stock_Level__c != null ? rec.Max_Stock_Level__c : 0;
            const reorderQty = maxLevel > 0 ? Math.max(0, maxLevel - available) : 0;
            const isZero = rec.Is_Zero_Stock__c === true;

            return {
                id: rec.Id,
                warehouseName: rec.Warehouse__r ? rec.Warehouse__r.Name : '',
                productName: rec.Product_Ext__r ? rec.Product_Ext__r.Name : '',
                productCode: rec.Product_Ext__r ? rec.Product_Ext__r.SKU_Code__c : '',
                onHand: this.formatNumber(rec.Qty_On_Hand__c),
                reserved: this.formatNumber(rec.Qty_Reserved__c),
                available: this.formatNumber(available),
                availableClass: isZero ? 'stock-level_danger' : 'stock-level_warning',
                minLevel: this.formatNumber(minLevel),
                maxLevel: this.formatNumber(maxLevel),
                reorderQty: this.formatNumber(reorderQty),
                severity: isZero ? 'Out of Stock' : 'Low Stock',
                severityClass: isZero ? 'slds-badge slds-badge_inverse' : 'slds-badge'
            };
        });
    }

    // ──────────────────────────────────────────────────────────────
    // Utility
    // ──────────────────────────────────────────────────────────────

    formatNumber(value) {
        if (value == null || value === undefined) return '0';
        return Number(value).toLocaleString();
    }

    formatDate(dateValue) {
        if (!dateValue) return '';
        try {
            const d = new Date(dateValue);
            return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
        } catch (e) {
            return String(dateValue);
        }
    }

    formatDateTime(dtValue) {
        if (!dtValue) return '';
        try {
            const d = new Date(dtValue);
            return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')} ${String(d.getUTCHours()).padStart(2, '0')}:${String(d.getUTCMinutes()).padStart(2, '0')}`;
        } catch (e) {
            return String(dtValue);
        }
    }

    formatTxnType(txnType) {
        if (!txnType) return '';
        return txnType.replace(/_/g, ' ');
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