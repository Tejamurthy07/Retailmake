import { LightningElement, track } from 'lwc';
import getStockKPIs from '@salesforce/apex/INV_StockDashboardController.getStockKPIs';
import getCurrentStock from '@salesforce/apex/INV_StockDashboardController.getCurrentStock';
import getNearExpiryBatches from '@salesforce/apex/INV_StockDashboardController.getNearExpiryBatches';
import getStockMovementHistory from '@salesforce/apex/INV_StockDashboardController.getStockMovementHistory';
import getDistributorsWithStock from '@salesforce/apex/INV_StockDashboardController.getDistributorsWithStock';

const PAGE_SIZE = 25;

export default class StockDashboard extends LightningElement {
    // --- State ---
    isLoading = false;
    errorMessage = '';
    activeTab = 'currentStock';

    // Account selector
    @track distributorOptions = [];
    selectedAccountId = '';

    // KPI data
    @track kpis = {
        totalSkus: 0,
        totalClosingStock: 0,
        totalOpeningStock: 0,
        totalReceived: 0,
        totalSold: 0,
        totalDamaged: 0,
        lowStockCount: 0,
        zeroStockCount: 0,
        nearExpiryBatchCount: 0
    };

    // Current Stock tab
    productSearch = '';
    stockFilter = 'all';
    @track stockRecords = [];
    stockTotalCount = 0;
    currentOffset = 0;
    _searchTimeout;

    // Near Expiry tab
    nearExpiryDays = '30';
    @track nearExpiryRecords = [];

    // Stock Movement tab
    movementAccountId = '';
    movementProductId = '';
    @track movementProductOptions = [];
    @track movementRecords = [];
    movementLoaded = false;

    // ──────────────────────────────────────────────────────────────
    // Lifecycle
    // ──────────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadDistributors();
        this.loadKPIs();
        this.loadCurrentStock();
    }

    // ──────────────────────────────────────────────────────────────
    // Data Loading
    // ──────────────────────────────────────────────────────────────

    loadDistributors() {
        getDistributorsWithStock()
            .then(result => {
                const opts = [{ label: 'All Distributors', value: '' }];
                result.forEach(acc => {
                    opts.push({ label: acc.Name, value: acc.Id });
                });
                this.distributorOptions = opts;
            })
            .catch(error => {
                this.handleError(error, 'Failed to load distributors');
            });
    }

    loadKPIs() {
        this.isLoading = true;
        const accountId = this.selectedAccountId || null;
        getStockKPIs({ accountId })
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
        const accountId = this.selectedAccountId || null;
        const productSearch = this.productSearch || null;
        getCurrentStock({
            accountId,
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

    loadNearExpiryBatches() {
        this.isLoading = true;
        getNearExpiryBatches({
            daysThreshold: parseInt(this.nearExpiryDays, 10),
            limitCount: 50
        })
            .then(result => {
                this.nearExpiryRecords = result || [];
                this.errorMessage = '';
            })
            .catch(error => {
                this.handleError(error, 'Failed to load near-expiry batches');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    loadMovementHistory() {
        if (!this.movementAccountId || !this.movementProductId) {
            return;
        }
        this.isLoading = true;
        getStockMovementHistory({
            accountId: this.movementAccountId,
            productId: this.movementProductId,
            limitCount: 30
        })
            .then(result => {
                this.movementRecords = result || [];
                this.movementLoaded = true;
                this.errorMessage = '';
            })
            .catch(error => {
                this.handleError(error, 'Failed to load stock movement');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    /**
     * Loads products for a given distributor (for movement tab product selector).
     * Uses getCurrentStock with 'all' filter to derive unique products.
     */
    loadMovementProducts() {
        if (!this.movementAccountId) {
            this.movementProductOptions = [];
            this.movementProductId = '';
            return;
        }
        getCurrentStock({
            accountId: this.movementAccountId,
            productSearch: null,
            stockFilter: 'all',
            limitCount: 100,
            offset: 0
        })
            .then(result => {
                const productMap = new Map();
                (result.records || []).forEach(rec => {
                    if (rec.Product_Ext__c && !productMap.has(rec.Product_Ext__c)) {
                        productMap.set(rec.Product_Ext__c, {
                            label: rec.Product_Ext__r ? rec.Product_Ext__r.Name : rec.Product_Ext__c,
                            value: rec.Product_Ext__c
                        });
                    }
                });
                this.movementProductOptions = Array.from(productMap.values());
            })
            .catch(error => {
                this.handleError(error, 'Failed to load products for movement');
            });
    }

    // ──────────────────────────────────────────────────────────────
    // Event Handlers
    // ──────────────────────────────────────────────────────────────

    handleAccountChange(event) {
        this.selectedAccountId = event.detail.value;
        this.currentOffset = 0;
        this.loadKPIs();
        this.loadCurrentStock();
    }

    handleRefresh() {
        this.errorMessage = '';
        this.loadKPIs();
        if (this.activeTab === 'currentStock') {
            this.loadCurrentStock();
        } else if (this.activeTab === 'nearExpiry') {
            this.loadNearExpiryBatches();
        } else if (this.activeTab === 'stockMovement' && this.movementLoaded) {
            this.loadMovementHistory();
        }
    }

    handleTabChange(event) {
        this.activeTab = event.target.value;
        if (this.activeTab === 'nearExpiry' && this.nearExpiryRecords.length === 0) {
            this.loadNearExpiryBatches();
        }
    }

    handleProductSearch(event) {
        const value = event.target.value;
        // Debounce 300ms
        if (this._searchTimeout) {
            clearTimeout(this._searchTimeout);
        }
        this._searchTimeout = setTimeout(() => {
            this.productSearch = value;
            this.currentOffset = 0;
            this.loadCurrentStock();
        }, 300);
    }

    handleStockFilterAll() {
        this.stockFilter = 'all';
        this.currentOffset = 0;
        this.loadCurrentStock();
    }

    handleStockFilterLow() {
        this.stockFilter = 'low';
        this.currentOffset = 0;
        this.loadCurrentStock();
    }

    handleStockFilterZero() {
        this.stockFilter = 'zero';
        this.currentOffset = 0;
        this.loadCurrentStock();
    }

    handleStockFilterHealthy() {
        this.stockFilter = 'healthy';
        this.currentOffset = 0;
        this.loadCurrentStock();
    }

    handleDaysThresholdChange(event) {
        this.nearExpiryDays = event.detail.value;
        this.loadNearExpiryBatches();
    }

    handleMovementAccountChange(event) {
        this.movementAccountId = event.detail.value;
        this.movementProductId = '';
        this.movementRecords = [];
        this.movementLoaded = false;
        this.loadMovementProducts();
    }

    handleMovementProductChange(event) {
        this.movementProductId = event.detail.value;
    }

    handleLoadMovement() {
        this.loadMovementHistory();
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

    get kpiTotalSkus() {
        return this.formatNumber(this.kpis.totalSkus);
    }

    get kpiTotalClosingStock() {
        return this.formatNumber(this.kpis.totalClosingStock);
    }

    get kpiTotalSold() {
        return this.formatNumber(this.kpis.totalSold);
    }

    get kpiLowStockCount() {
        return this.formatNumber(this.kpis.lowStockCount);
    }

    get kpiZeroStockCount() {
        return this.formatNumber(this.kpis.zeroStockCount);
    }

    get kpiNearExpiryCount() {
        return this.formatNumber(this.kpis.nearExpiryBatchCount);
    }

    get kpiLowStockClass() {
        return this.kpis.lowStockCount > 0
            ? 'kpi-card kpi-card_warning'
            : 'kpi-card kpi-card_default';
    }

    get kpiLowStockIconVariant() {
        return this.kpis.lowStockCount > 0 ? 'warning' : '';
    }

    get kpiZeroStockClass() {
        return this.kpis.zeroStockCount > 0
            ? 'kpi-card kpi-card_danger'
            : 'kpi-card kpi-card_default';
    }

    get kpiZeroStockIconVariant() {
        return this.kpis.zeroStockCount > 0 ? 'error' : '';
    }

    get kpiNearExpiryClass() {
        return this.kpis.nearExpiryBatchCount > 0
            ? 'kpi-card kpi-card_warning'
            : 'kpi-card kpi-card_default';
    }

    get kpiNearExpiryIconVariant() {
        return this.kpis.nearExpiryBatchCount > 0 ? 'warning' : '';
    }

    // ──────────────────────────────────────────────────────────────
    // Filter Button Variants
    // ──────────────────────────────────────────────────────────────

    get filterAllVariant() {
        return this.stockFilter === 'all' ? 'brand' : 'neutral';
    }

    get filterLowVariant() {
        return this.stockFilter === 'low' ? 'brand' : 'neutral';
    }

    get filterZeroVariant() {
        return this.stockFilter === 'zero' ? 'brand' : 'neutral';
    }

    get filterHealthyVariant() {
        return this.stockFilter === 'healthy' ? 'brand' : 'neutral';
    }

    // ──────────────────────────────────────────────────────────────
    // Stock Table Computed
    // ──────────────────────────────────────────────────────────────

    get hasStockRecords() {
        return this.stockRecords && this.stockRecords.length > 0;
    }

    get stockTableRows() {
        return this.stockRecords.map(rec => {
            const closing = rec.Closing_Stock__c != null ? rec.Closing_Stock__c : 0;
            let closingClass = 'stock-level_healthy';
            if (closing === 0) {
                closingClass = 'stock-level_danger';
            } else if (closing <= 10) {
                closingClass = 'stock-level_danger';
            } else if (closing <= 50) {
                closingClass = 'stock-level_warning';
            }

            return {
                id: rec.Id,
                name: rec.Name,
                accountName: rec.Account__r ? rec.Account__r.Name : '',
                productName: rec.Product_Ext__r ? rec.Product_Ext__r.Name : '',
                productCode: rec.Product_Ext__r ? rec.Product_Ext__r.SKU_Code__c : '',
                opening: this.formatNumber(rec.Opening_Stock__c),
                received: this.formatNumber(rec.Received_Qty__c),
                sold: this.formatNumber(rec.Sold_Qty__c),
                damaged: this.formatNumber(rec.Damaged_Qty__c),
                closing: this.formatNumber(closing),
                closingClass,
                batchNo: rec.Batch_No__c || '',
                expiryDate: this.formatDate(rec.Expiry_Date__c),
                stockDate: this.formatDate(rec.Stock_Date__c)
            };
        });
    }

    // Pagination computed
    get currentPage() {
        return Math.floor(this.currentOffset / PAGE_SIZE) + 1;
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.stockTotalCount / PAGE_SIZE));
    }

    get isPreviousDisabled() {
        return this.currentOffset === 0;
    }

    get isNextDisabled() {
        return this.currentOffset + PAGE_SIZE >= this.stockTotalCount;
    }

    // ──────────────────────────────────────────────────────────────
    // Near Expiry Computed
    // ──────────────────────────────────────────────────────────────

    get daysThresholdOptions() {
        return [
            { label: '15 Days', value: '15' },
            { label: '30 Days', value: '30' },
            { label: '60 Days', value: '60' },
            { label: '90 Days', value: '90' }
        ];
    }

    get hasNearExpiryRecords() {
        return this.nearExpiryRecords && this.nearExpiryRecords.length > 0;
    }

    get nearExpiryTableRows() {
        const today = new Date();
        today.setHours(0, 0, 0, 0);

        return this.nearExpiryRecords.map(batch => {
            const shelfPct = batch.Shelf_Life_Remaining_Pct__c != null
                ? Math.round(batch.Shelf_Life_Remaining_Pct__c)
                : 0;

            let shelfLifeClass = 'stock-level_healthy';
            let shelfLifeBarClass = 'shelf-life-bar__fill shelf-life-bar__fill_healthy';
            if (shelfPct < 20) {
                shelfLifeClass = 'stock-level_danger';
                shelfLifeBarClass = 'shelf-life-bar__fill shelf-life-bar__fill_danger';
            } else if (shelfPct < 50) {
                shelfLifeClass = 'stock-level_warning';
                shelfLifeBarClass = 'shelf-life-bar__fill shelf-life-bar__fill_warning';
            }

            // Calculate days remaining
            let daysLeft = 0;
            let daysLeftClass = 'stock-level_healthy';
            if (batch.Expiry_Date__c) {
                const expiry = new Date(batch.Expiry_Date__c);
                expiry.setHours(0, 0, 0, 0);
                daysLeft = Math.ceil((expiry - today) / (1000 * 60 * 60 * 24));
                if (daysLeft <= 7) {
                    daysLeftClass = 'stock-level_danger';
                } else if (daysLeft <= 30) {
                    daysLeftClass = 'stock-level_warning';
                }
            }

            return {
                id: batch.Id,
                batchNumber: batch.Batch_Number__c || batch.Name,
                productName: batch.Product_Ext__r ? batch.Product_Ext__r.Name : '',
                productCode: batch.Product_Ext__r ? batch.Product_Ext__r.SKU_Code__c : '',
                mfgDate: this.formatDate(batch.Manufacturing_Date__c),
                expiryDate: this.formatDate(batch.Expiry_Date__c),
                daysLeft,
                daysLeftClass,
                shelfLifePct: shelfPct,
                shelfLifeClass,
                shelfLifeBarClass,
                shelfLifeBarStyle: `width: ${Math.min(shelfPct, 100)}%`,
                status: batch.Status__c || 'Active',
                statusBadgeClass: 'slds-badge',
                qtyManufactured: this.formatNumber(batch.Quantity_Manufactured__c)
            };
        });
    }

    // ──────────────────────────────────────────────────────────────
    // Stock Movement Computed
    // ──────────────────────────────────────────────────────────────

    get isMovementProductDisabled() {
        return !this.movementAccountId || this.movementProductOptions.length === 0;
    }

    get isLoadMovementDisabled() {
        return !this.movementAccountId || !this.movementProductId;
    }

    get hasMovementRecords() {
        return this.movementLoaded && this.movementRecords && this.movementRecords.length > 0;
    }

    get showMovementPlaceholder() {
        return !this.movementLoaded;
    }

    get showMovementEmpty() {
        return this.movementLoaded && (!this.movementRecords || this.movementRecords.length === 0);
    }

    get movementTableRows() {
        return this.movementRecords.map(rec => {
            const closing = rec.Closing_Stock__c != null ? rec.Closing_Stock__c : 0;
            let closingClass = 'stock-level_healthy';
            if (closing === 0) {
                closingClass = 'stock-level_danger';
            } else if (closing <= 10) {
                closingClass = 'stock-level_danger';
            } else if (closing <= 50) {
                closingClass = 'stock-level_warning';
            }

            const received = rec.Received_Qty__c || 0;
            const damaged = rec.Damaged_Qty__c || 0;

            return {
                id: rec.Id,
                stockDate: this.formatDate(rec.Stock_Date__c),
                opening: this.formatNumber(rec.Opening_Stock__c),
                received: this.formatNumber(received),
                receivedPositive: received > 0,
                sold: this.formatNumber(rec.Sold_Qty__c),
                damaged: this.formatNumber(damaged),
                damagedPositive: damaged > 0,
                closing: this.formatNumber(closing),
                closingClass,
                isCurrent: rec.Is_Current__c === true,
                rowClass: rec.Is_Current__c === true ? 'slds-is-selected' : ''
            };
        });
    }

    get movementTrendSummary() {
        if (!this.movementRecords || this.movementRecords.length < 2) {
            return 'Insufficient data to determine trend.';
        }

        // Records are sorted DESC (newest first) from Apex
        const newest = this.movementRecords[0];
        const oldest = this.movementRecords[this.movementRecords.length - 1];
        const newestClosing = newest.Closing_Stock__c || 0;
        const oldestClosing = oldest.Closing_Stock__c || 0;
        const diff = newestClosing - oldestClosing;
        const periods = this.movementRecords.length;

        // Calculate total sold and received
        let totalSold = 0;
        let totalReceived = 0;
        this.movementRecords.forEach(r => {
            totalSold += r.Sold_Qty__c || 0;
            totalReceived += r.Received_Qty__c || 0;
        });

        let trend;
        if (diff > 0) {
            trend = `Stock increased by ${this.formatNumber(diff)} units over ${periods} periods.`;
        } else if (diff < 0) {
            trend = `Stock decreased by ${this.formatNumber(Math.abs(diff))} units over ${periods} periods.`;
        } else {
            trend = `Stock remained stable over ${periods} periods.`;
        }

        return `${trend} Total received: ${this.formatNumber(totalReceived)}, Total sold: ${this.formatNumber(totalSold)}.`;
    }

    // ──────────────────────────────────────────────────────────────
    // Utility
    // ──────────────────────────────────────────────────────────────

    formatNumber(value) {
        if (value == null || value === undefined) {
            return '0';
        }
        return Number(value).toLocaleString();
    }

    formatDate(dateValue) {
        if (!dateValue) {
            return '';
        }
        try {
            const d = new Date(dateValue);
            const year = d.getUTCFullYear();
            const month = String(d.getUTCMonth() + 1).padStart(2, '0');
            const day = String(d.getUTCDate()).padStart(2, '0');
            return `${year}-${month}-${day}`;
        } catch (e) {
            return String(dateValue);
        }
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