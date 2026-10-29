import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getProductDetails from '@salesforce/apex/ProductThreeSixtyController.getProductDetails';
import getProductKPIs from '@salesforce/apex/ProductThreeSixtyController.getProductKPIs';
import getBatches from '@salesforce/apex/ProductThreeSixtyController.getBatches';
import getWarehouseStock from '@salesforce/apex/ProductThreeSixtyController.getWarehouseStock';
import getDistributorStock from '@salesforce/apex/ProductThreeSixtyController.getDistributorStock';
import getPricing from '@salesforce/apex/ProductThreeSixtyController.getPricing';
import getRecentOrderLines from '@salesforce/apex/ProductThreeSixtyController.getRecentOrderLines';
import getActiveSchemes from '@salesforce/apex/ProductThreeSixtyController.getActiveSchemes';
import getRecentReturns from '@salesforce/apex/ProductThreeSixtyController.getRecentReturns';
import getStockTransactions from '@salesforce/apex/ProductThreeSixtyController.getStockTransactions';

export default class ProductThreeSixty extends NavigationMixin(LightningElement) {
    @api recordId;

    @track activeTab = 'batches';
    @track product = {};
    @track kpiData = {};
    @track batches = [];
    @track warehouseStock = [];
    @track distributorStock = [];
    @track pricing = [];
    @track orderLines = [];
    @track schemes = [];
    @track returns = [];
    @track stockTransactions = [];

    isLoading = false;
    dataLoaded = false;

    connectedCallback() {
        this.loadProductData();
    }

    async loadProductData() {
        this.isLoading = true;
        try {
            const [details, kpis] = await Promise.all([
                getProductDetails({ productId: this.recordId }),
                getProductKPIs({ productId: this.recordId })
            ]);
            this.product = details || {};
            this.kpiData = kpis || {};
            this.dataLoaded = true;
            this.loadTabData('batches');
        } catch (error) {
            this.showToast('Error', 'Failed to load product data', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Computed: Product Header ──────────────────────────────────────

    get productName() { return this.product.Name || ''; }
    get skuCode() { return this.product.SKU_Code__c || ''; }
    get hasSku() { return !!this.product.SKU_Code__c; }
    get brand() { return this.product.Brand__c || ''; }
    get hasBrand() { return !!this.product.Brand__c; }
    get categoryName() { return this.product.Product_Category__r ? this.product.Product_Category__r.Name : ''; }
    get hasCategory() { return !!this.categoryName; }
    get subCategoryName() { return this.product.Sub_Category__r ? this.product.Sub_Category__r.Name : ''; }
    get hasSubCategory() { return !!this.subCategoryName; }
    get hsnCode() { return this.product.HSN_SAC_Code__c || ''; }
    get hasHsn() { return !!this.product.HSN_SAC_Code__c; }
    get barcodeEan() { return this.product.Barcode_EAN__c || ''; }
    get hasBarcode() { return !!this.product.Barcode_EAN__c; }
    get unitOfMeasure() { return this.product.Unit_of_Measure__c || ''; }
    get hasUom() { return !!this.product.Unit_of_Measure__c; }
    get caseSize() { return this.product.Case_Size__c || ''; }
    get hasCaseSize() { return !!this.product.Case_Size__c; }
    get weight() {
        if (!this.product.Weight__c) return '';
        return this.product.Weight__c + ' ' + (this.product.Weight_Unit__c || '');
    }
    get hasWeight() { return !!this.product.Weight__c; }
    get shelfLifeDays() { return this.product.Shelf_Life_Days__c || ''; }
    get hasShelfLife() { return !!this.product.Shelf_Life_Days__c; }
    get isActive() { return this.product.Is_Active__c !== false; }
    get isReturnable() { return this.product.Is_Returnable__c === true; }
    get hasProductImage() { return !!this.product.Product_Image_URL__c; }
    get productImageUrl() { return this.product.Product_Image_URL__c || ''; }

    get activeStatusClass() {
        return this.isActive ? 'active-badge active-yes' : 'active-badge active-no';
    }
    get activeStatusLabel() { return this.isActive ? 'Active' : 'Inactive'; }
    get returnableBadgeClass() {
        return this.isReturnable ? 'active-badge active-yes' : 'active-badge active-no';
    }
    get returnableLabel() { return this.isReturnable ? 'Returnable' : 'Non-Returnable'; }

    // ── Computed: KPI Values ─────────────────────────────────────────

    get mrp() { return this.formatCurrency(this.product.MRP__c || 0); }
    get unitPrice() { return this.formatCurrency(this.product.Unit_Price__c || 0); }
    get gstRate() { return (this.product.GST_Rate__c || 0) + '%'; }
    get mtdOrderQty() { return this.kpiData.mtdOrderQty || 0; }
    get mtdOrderValue() { return this.formatCurrencyShort(this.kpiData.mtdOrderValue || 0); }
    get totalStockOnHand() { return this.kpiData.totalStockOnHand || 0; }
    get totalDistributorStock() { return this.kpiData.totalDistributorStock || 0; }
    get activeBatchCount() { return this.kpiData.activeBatches || 0; }
    get mtdReturnQty() { return this.kpiData.mtdReturnQty || 0; }

    // ── Tab Data ─────────────────────────────────────────────────────

    get hasBatches() { return this.batches && this.batches.length > 0; }
    get hasWarehouseStock() { return this.warehouseStock && this.warehouseStock.length > 0; }
    get hasDistributorStock() { return this.distributorStock && this.distributorStock.length > 0; }
    get hasPricing() { return this.pricing && this.pricing.length > 0; }
    get hasOrderLines() { return this.orderLines && this.orderLines.length > 0; }
    get hasSchemes() { return this.schemes && this.schemes.length > 0; }
    get hasReturns() { return this.returns && this.returns.length > 0; }
    get hasStockTransactions() { return this.stockTransactions && this.stockTransactions.length > 0; }

    // ── Tab Navigation ───────────────────────────────────────────────

    handleTabChange(event) {
        this.activeTab = event.target.value;
        this.loadTabData(this.activeTab);
    }

    async loadTabData(tabName) {
        this.isLoading = true;
        try {
            switch (tabName) {
                case 'batches': await this.loadBatches(); break;
                case 'warehouse': await this.loadWarehouseStock(); break;
                case 'distributor': await this.loadDistributorStock(); break;
                case 'pricing': await this.loadPricing(); break;
                case 'orders': await this.loadOrderLines(); break;
                case 'schemes': await this.loadSchemes(); break;
                case 'returns': await this.loadReturns(); break;
                case 'transactions': await this.loadStockTransactions(); break;
                default: break;
            }
        } catch (error) {
            console.error('Error loading tab:', error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadBatches() {
        try {
            const result = await getBatches({ productId: this.recordId });
            this.batches = (result || []).map(b => ({
                id: b.Id,
                name: b.Name,
                batchNumber: b.Batch_Number__c || b.Name,
                mfgDate: this.formatDate(b.Manufacturing_Date__c),
                expiryDate: this.formatDate(b.Expiry_Date__c),
                quantity: b.Quantity_Manufactured__c || 0,
                isActive: b.Status__c === 'Active',
                statusClass: b.Status__c === 'Active' ? 'status-badge badge-confirmed' : 'status-badge badge-cancelled',
                statusLabel: b.Status__c || 'Unknown',
                isExpiringSoon: this.isExpiringSoon(b.Expiry_Date__c),
                expiryClass: this.getExpiryClass(b.Expiry_Date__c)
            }));
        } catch (error) {
            this.batches = [];
        }
    }

    async loadWarehouseStock() {
        try {
            const result = await getWarehouseStock({ productId: this.recordId });
            this.warehouseStock = (result || []).map(ws => ({
                id: ws.Id,
                name: ws.Name,
                warehouseName: ws.Warehouse__r ? ws.Warehouse__r.Name : 'N/A',
                warehouseId: ws.Warehouse__c,
                onHand: ws.Qty_On_Hand__c || 0,
                available: ws.Qty_Available__c || 0,
                reserved: ws.Qty_Reserved__c || 0,
                lastUpdated: this.formatDate(ws.Last_Transaction_Date__c),
                qtyClass: this.getStockQtyClass(ws.Qty_Available__c)
            }));
        } catch (error) {
            this.warehouseStock = [];
        }
    }

    async loadDistributorStock() {
        try {
            const result = await getDistributorStock({ productId: this.recordId });
            this.distributorStock = (result || []).map(ds => ({
                id: ds.Id,
                name: ds.Name,
                accountName: ds.Account__r ? ds.Account__r.Name : 'N/A',
                accountId: ds.Account__c,
                opening: ds.Opening_Stock__c || 0,
                received: ds.Received_Qty__c || 0,
                sold: ds.Sold_Qty__c || 0,
                damaged: ds.Damaged_Qty__c || 0,
                closing: ds.Closing_Stock__c || 0,
                batchNo: ds.Batch_No__c || '',
                expiryDate: this.formatDate(ds.Expiry_Date__c),
                stockDate: this.formatDate(ds.Stock_Date__c),
                qtyClass: this.getStockQtyClass(ds.Closing_Stock__c)
            }));
        } catch (error) {
            this.distributorStock = [];
        }
    }

    async loadPricing() {
        try {
            const result = await getPricing({ productId: this.recordId });
            this.pricing = (result || []).map(pl => ({
                id: pl.Id,
                name: pl.Name,
                price: this.formatCurrency(pl.Unit_Price__c || 0),
                effectiveFrom: this.formatDate(pl.Effective_From__c),
                effectiveTo: this.formatDate(pl.Effective_To__c),
                isActive: pl.Is_Active__c,
                statusClass: pl.Is_Active__c ? 'status-badge badge-confirmed' : 'status-badge badge-draft',
                statusLabel: pl.Is_Active__c ? 'Active' : 'Inactive'
            }));
        } catch (error) {
            this.pricing = [];
        }
    }

    async loadOrderLines() {
        try {
            const result = await getRecentOrderLines({ productId: this.recordId, limitCount: 30 });
            this.orderLines = (result || []).map(ol => ({
                id: ol.Id,
                orderId: ol.Sales_Order__c,
                orderName: ol.Sales_Order__r ? ol.Sales_Order__r.Name : '',
                orderDate: this.formatDate(ol.Sales_Order__r ? ol.Sales_Order__r.Order_Date__c : null),
                accountName: ol.Sales_Order__r && ol.Sales_Order__r.Account__r ? ol.Sales_Order__r.Account__r.Name : '',
                quantity: ol.Quantity__c || 0,
                unitPrice: this.formatCurrency(ol.Unit_Price__c || 0),
                discount: this.formatCurrency(ol.Discount_Amount__c || 0),
                lineTotal: this.formatCurrency(ol.Line_Total__c || 0),
                status: ol.Sales_Order__r ? ol.Sales_Order__r.Status__c : '',
                statusBadge: this.getStatusBadgeClass(ol.Sales_Order__r ? ol.Sales_Order__r.Status__c : '')
            }));
        } catch (error) {
            this.orderLines = [];
        }
    }

    async loadSchemes() {
        try {
            const result = await getActiveSchemes({ productId: this.recordId });
            this.schemes = (result || []).map(s => ({
                id: s.Id,
                name: s.Name,
                code: s.Scheme_Code__c || '',
                type: s.Scheme_Type__c || 'Discount',
                description: s.Description__c || '',
                validFrom: this.formatDate(s.Start_Date__c),
                validTo: this.formatDate(s.End_Date__c),
                typeBadgeStyle: this.getSchemeTypeBadgeStyle(s.Scheme_Type__c),
                maxDiscount: s.Max_Discount_Cap__c ? this.formatCurrency(s.Max_Discount_Cap__c) : ''
            }));
        } catch (error) {
            this.schemes = [];
        }
    }

    async loadReturns() {
        try {
            const result = await getRecentReturns({ productId: this.recordId });
            this.returns = (result || []).map(r => ({
                id: r.Id,
                returnOrderId: r.Return_Order__c,
                returnOrderName: r.Return_Order__r ? r.Return_Order__r.Name : '',
                returnDate: this.formatDate(r.Return_Order__r ? r.Return_Order__r.Return_Date__c : null),
                accountName: r.Return_Order__r && r.Return_Order__r.Account__r ? r.Return_Order__r.Account__r.Name : '',
                quantity: r.Return_Quantity__c || 0,
                reason: r.Return_Reason__c || '',
                status: r.Return_Order__r ? r.Return_Order__r.Status__c : '',
                statusBadge: this.getStatusBadgeClass(r.Return_Order__r ? r.Return_Order__r.Status__c : '')
            }));
        } catch (error) {
            this.returns = [];
        }
    }

    async loadStockTransactions() {
        try {
            const result = await getStockTransactions({ productId: this.recordId });
            this.stockTransactions = (result || []).map(st => ({
                id: st.Id,
                name: st.Name,
                type: st.Transaction_Type__c || '',
                quantity: st.Quantity__c || 0,
                date: this.formatDate(st.Transaction_Date__c),
                reference: st.Reference_Id__c || '',
                warehouseName: st.Warehouse__r ? st.Warehouse__r.Name : '',
                typeBadge: this.getTransactionTypeBadge(st.Transaction_Type__c)
            }));
        } catch (error) {
            this.stockTransactions = [];
        }
    }

    // ── Actions ──────────────────────────────────────────────────────

    refreshData() {
        this.loadProductData();
    }

    navigateToRecord(event) {
        const recordId = event.currentTarget.dataset.id;
        if (recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId, actionName: 'view' }
            });
        }
    }

    // ── Formatting ───────────────────────────────────────────────────

    getStatusBadgeClass(status) {
        const map = {
            'Confirmed': 'status-badge badge-confirmed',
            'Approved': 'status-badge badge-confirmed',
            'Draft': 'status-badge badge-draft',
            'Pending': 'status-badge badge-pending',
            'Submitted': 'status-badge badge-pending',
            'Delivered': 'status-badge badge-delivered',
            'Completed': 'status-badge badge-delivered',
            'Cancelled': 'status-badge badge-cancelled',
            'Rejected': 'status-badge badge-cancelled',
            'Dispatched': 'status-badge badge-dispatched'
        };
        return map[status] || 'status-badge badge-draft';
    }

    getSchemeTypeBadgeStyle(type) {
        const colors = {
            'Percentage Discount': 'background-color: #e8f4fd; color: #0176d3',
            'Flat Discount': 'background-color: #e6f7e9; color: #2e844a',
            'Buy X Get Y Free': 'background-color: #fff8e1; color: #dd7a01',
            'Slab Discount': 'background-color: #f3e8ff; color: #9b59b6',
            'Volume Discount': 'background-color: #fce4e4; color: #ea001e'
        };
        return colors[type] || 'background-color: #f3f3f3; color: #706e6b';
    }

    getStockQtyClass(qty) {
        if (qty == null || qty <= 0) return 'qty-low';
        if (qty <= 10) return 'qty-low';
        if (qty <= 50) return 'qty-medium';
        return 'qty-high';
    }

    getTransactionTypeBadge(type) {
        const map = {
            'Inbound': 'status-badge badge-confirmed',
            'Outbound': 'status-badge badge-pending',
            'Adjustment': 'status-badge badge-dispatched',
            'Transfer': 'status-badge badge-delivered',
            'Return': 'status-badge badge-cancelled'
        };
        return map[type] || 'status-badge badge-draft';
    }

    isExpiringSoon(expiryDate) {
        if (!expiryDate) return false;
        const expiry = new Date(expiryDate);
        const today = new Date();
        const diffDays = Math.ceil((expiry - today) / (1000 * 60 * 60 * 24));
        return diffDays > 0 && diffDays <= 90;
    }

    getExpiryClass(expiryDate) {
        if (!expiryDate) return '';
        const expiry = new Date(expiryDate);
        const today = new Date();
        const diffDays = Math.ceil((expiry - today) / (1000 * 60 * 60 * 24));
        if (diffDays <= 0) return 'qty-low';
        if (diffDays <= 30) return 'qty-low';
        if (diffDays <= 90) return 'qty-medium';
        return '';
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-IN', {
            style: 'currency', currency: 'INR',
            minimumFractionDigits: 0, maximumFractionDigits: 0
        }).format(value || 0);
    }

    formatCurrencyShort(value) {
        if (!value) return '0';
        if (value >= 10000000) return (value / 10000000).toFixed(1) + ' Cr';
        if (value >= 100000) return (value / 100000).toFixed(1) + ' L';
        if (value >= 1000) return (value / 1000).toFixed(1) + ' K';
        return new Intl.NumberFormat('en-IN').format(Math.round(value));
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
}