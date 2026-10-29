import { LightningElement, api, track, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import searchProducts from '@salesforce/apex/OrderEntryController.searchProducts';
import createSalesOrder from '@salesforce/apex/OrderEntryController.createSalesOrder';
import getLastOrder from '@salesforce/apex/OrderEntryController.getLastOrder';
import getApplicableSchemes from '@salesforce/apex/OrderEntryController.getApplicableSchemes';
import getMustSellProducts from '@salesforce/apex/OrderEntryController.getMustSellProducts';
import getProductCategories from '@salesforce/apex/OrderEntryController.getProductCategories';
import getTopSellingProducts from '@salesforce/apex/OrderEntryController.getTopSellingProducts';
import getOrderUOMOptions from '@salesforce/apex/OrderEntryController.getOrderUOMOptions';
import getProductUOMOptions from '@salesforce/apex/OrderEntryController.getProductUOMOptions';
import convertQuantity from '@salesforce/apex/OrderEntryController.convertQuantity';
import getDraftOrder from '@salesforce/apex/OrderEntryController.getDraftOrder';
import getWarehouses from '@salesforce/apex/OrderEntryController.getWarehouses';
import checkStockAvailability from '@salesforce/apex/OrderEntryController.checkStockAvailability';
import getAccountCredit from '@salesforce/apex/OrderEntryController.getAccountCredit';

const ACCOUNT_FIELDS = [
    'Account.Name',
    'Account.Channel__c',
    'Account.Outlet_Class__c',
    'Account.Outlet_Type__c',
    'Account.Territory__c',
    'Account.BillingCity'
];

export default class OrderEntryForm extends NavigationMixin(LightningElement) {
    @api recordId;
    @api visitId;
    @api accountId;
    // When set, the form rehydrates the given Draft Sales_Order__c and
    // saves back to the same record instead of creating a new one.
    @api draftOrderId;
    // Internal: the order Id we're editing; populated from @api or from
    // an earlier save-draft that returned an Id.
    editingOrderId = null;

    get isEmbedded() { return !!this.accountId; }
    get isEditingDraft() { return !!this.editingOrderId; }
    get headerTitle() {
        return this.isEditingDraft
            ? ('Edit Order ' + (this.editingOrderName || ''))
            : 'New Order';
    }
    get headerSubtitle() {
        return this.isEditingDraft
            ? 'Update this draft and save or submit'
            : 'Create sales order for outlet';
    }
    // Set by loadDraftOrder so the header can show SO-xxxxx.
    editingOrderName = '';

    @track lineItems = [];
    @track orderSummary = {
        grossAmount: 0,
        totalDiscount: 0,
        taxableAmount: 0,
        totalTax: 0,
        netAmount: 0,
        totalItems: 0,
        totalQuantity: 0,
        grossAmountFormatted: '₹0.00',
        totalDiscountFormatted: '₹0.00',
        taxableAmountFormatted: '₹0.00',
        totalTaxFormatted: '₹0.00',
        netAmountFormatted: '₹0.00'
    };
    @track productResults = [];
    @track lastOrderInfo;
    @track schemes = [];
    @track mustSellProducts = [];
    @track focusedSellProducts = [];
    @track showMustSellWarning = false;
    @track missingMustSellProducts = [];
    @track mustSellBelowMinQty = [];
    @track topSellingProducts = [];
    @track mustSellHighlightActive = false;
    showFocusedSell = false;
    showSchemesPanel = false;
    showTopSelling = true;

    searchTerm = '';
    selectedCategory = '';
    categoryOptionsData = [];
    uomOptionsData = [];
    @track productUOMOptionsMap = {}; // productId -> [{label, value, uomId, isBase}]
    @track conversionFactorMap = {}; // productId|fromCode|toCode -> factor
    selectedAccountId;
    accountName = '';
    // Outlet credit position, loaded when the account is set; used to warn on submit.
    creditLimit = 0;
    outstandingBalance = 0;
    accountChannel = '';
    accountClass = '';
    orderRemarks = '';
    isLoading = false;
    isSubmitting = false;
    lineIdCounter = 0;

    // Warehouse & Stock Availability
    @track warehouseOptions = [];
    @track showOrderPdfPrompt = false;
    _lastCreatedOrderId;
    _lastCreatedOrderName;
    @track selectedWarehouseId = '';
    @track stockAvailabilityMap = {}; // productId -> available qty

    get effectiveAccountId() {
        return this.accountId || this.recordId || this.selectedAccountId;
    }

    get showProductResults() {
        return this.productResults && this.productResults.length > 0;
    }

    get hasLineItems() {
        return this.lineItems && this.lineItems.length > 0;
    }

    get lineItemCount() {
        return this.lineItems.length;
    }

    get hasMustSellProducts() {
        return this.mustSellProducts && this.mustSellProducts.length > 0;
    }

    get hasFocusedSellProducts() {
        return this.focusedSellProducts && this.focusedSellProducts.length > 0;
    }

    get hasMissingMustSell() {
        return this.missingMustSellProducts && this.missingMustSellProducts.length > 0;
    }

    get hasMustSellBelowMinQty() {
        return this.mustSellBelowMinQty && this.mustSellBelowMinQty.length > 0;
    }

    // --- Schemes panel getters ---
    get hasSchemes() {
        return this.schemes && this.schemes.length > 0;
    }

    get schemesCount() {
        return this.schemes ? this.schemes.length : 0;
    }

    get schemesPanelIcon() {
        return this.showSchemesPanel ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get focusedSellIcon() {
        return this.showFocusedSell ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get hasTopSellingProducts() {
        return this.topSellingProducts && this.topSellingProducts.length > 0;
    }

    get topSellingIcon() {
        return this.showTopSelling ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get schemesForDisplay() {
        if (!this.schemes) return [];
        return this.schemes.map(scheme => {
            const cat = scheme.Scheme_Category__c || '';
            let iconName = 'utility:discount';
            let cardClass = 'oef-scheme-card';
            let categoryBadgeClass = 'oef-scheme-cat-badge';

            if (cat === 'Free Products') {
                iconName = 'utility:package';
                cardClass += ' oef-scheme-card-free';
                categoryBadgeClass += ' oef-cat-free';
            } else if (cat === 'Discount in %' || cat === 'Discount in Value') {
                iconName = 'utility:percent';
                cardClass += ' oef-scheme-card-discount';
                categoryBadgeClass += ' oef-cat-discount';
            } else if (cat === 'Reward Points') {
                iconName = 'utility:ribbon';
                cardClass += ' oef-scheme-card-reward';
                categoryBadgeClass += ' oef-cat-reward';
            } else {
                cardClass += ' oef-scheme-card-default';
                categoryBadgeClass += ' oef-cat-default';
            }

            const benefitText = this.buildSchemeBenefitText(scheme);

            return {
                ...scheme,
                iconName,
                cardClass,
                categoryBadgeClass,
                benefitText
            };
        });
    }

    buildSchemeBenefitText(scheme) {
        const parts = [];
        if (scheme.Discount_Percent__c) {
            parts.push(scheme.Discount_Percent__c + '% off');
        }
        if (scheme.Discount_Amount__c) {
            parts.push(this.formatCurrency(scheme.Discount_Amount__c) + ' off');
        }
        if (scheme.Free_Quantity__c && scheme.Free_Product_Ext__r) {
            parts.push('Get ' + scheme.Free_Quantity__c + ' ' + scheme.Free_Product_Ext__r.Name + ' free');
        } else if (scheme.Free_Quantity__c) {
            parts.push('Get ' + scheme.Free_Quantity__c + ' free');
        }
        if (scheme.Reward_Points__c) {
            parts.push(scheme.Reward_Points__c + ' reward points');
        }
        if (scheme.MOV__c) {
            parts.push('Min order: ' + this.formatCurrency(scheme.MOV__c));
        }
        if (scheme.Invoice_Qty_Threshold__c) {
            parts.push('Min invoice qty: ' + scheme.Invoice_Qty_Threshold__c + ' ' + (scheme.Invoice_Qty_UOM__c || ''));
        }
        if (scheme.Min_Quantity__c) {
            parts.push('Min qty: ' + scheme.Min_Quantity__c);
        }
        if (parts.length === 0 && scheme.Description__c) {
            return scheme.Description__c;
        }
        return parts.join(' | ') || scheme.Description__c || scheme.Scheme_Type__c || '';
    }

    // --- Must Sell progress getters ---
    get mustSellOrderedCount() {
        return this.mustSellProducts ? this.mustSellProducts.filter(p => p.isInOrder).length : 0;
    }

    get mustSellTotalCount() {
        return this.mustSellProducts ? this.mustSellProducts.length : 0;
    }

    get mustSellBarStyle() {
        if (!this.mustSellTotalCount) return 'width: 0%';
        const pct = Math.round((this.mustSellOrderedCount / this.mustSellTotalCount) * 100);
        return 'width: ' + pct + '%';
    }

    // --- Summary getters ---
    get hasSchemeSavings() {
        return this.orderSummary.totalDiscount > 0;
    }

    get totalFreeQuantity() {
        if (!this.lineItems) return 0;
        return this.lineItems.reduce((sum, item) => sum + (item.freeQty || 0), 0);
    }

    get categoryOptions() {
        if (this.categoryOptionsData && this.categoryOptionsData.length > 0) {
            return this.categoryOptionsData;
        }
        return [{ label: 'All Categories', value: '' }];
    }

    get uomOptions() {
        if (this.uomOptionsData && this.uomOptionsData.length > 0) {
            return this.uomOptionsData;
        }
        return [
            { label: 'Piece (PCS)', value: 'PCS' },
            { label: 'Case (CS)', value: 'CS' },
            { label: 'Box (BOX)', value: 'BOX' },
            { label: 'Kilogram (KG)', value: 'KG' },
            { label: 'Litre (LTR)', value: 'LTR' }
        ];
    }

    mapProductUOMToOrderUOM(productUOM) {
        if (!productUOM) return 'Pieces';
        const mapping = {
            'Piece': 'Pieces',
            'Box': 'Boxes',
            'Case': 'Cases',
            'Kg': 'Kg',
            'Litre': 'Liters',
            'Dozen': 'Pieces',
            'Pack': 'Pieces'
        };
        return mapping[productUOM] || 'Pieces';
    }

    mapPicklistToCode(picklistValue) {
        if (!picklistValue) return 'PCS';
        const mapping = {
            'Pieces': 'PCS', 'Cases': 'CS', 'Boxes': 'BOX',
            'Kg': 'KG', 'Liters': 'LTR', 'Piece': 'PCS',
            'Box': 'BOX', 'Case': 'CS', 'Litre': 'LTR',
            'Dozen': 'DZ', 'Pack': 'PK', 'Gram': 'GRM',
            'Millilitre': 'ML', 'Kilogram': 'KG'
        };
        return mapping[picklistValue] || 'PCS';
    }

    mapCodeToPicklist(uomCode) {
        if (!uomCode) return 'Pieces';
        const mapping = {
            'PCS': 'Pieces', 'PC': 'Pieces', 'CS': 'Cases',
            'BOX': 'Boxes', 'BX': 'Boxes', 'KG': 'Kg',
            'LTR': 'Liters', 'DZ': 'Pieces', 'PK': 'Pieces',
            'GRM': 'Kg', 'G': 'Kg', 'ML': 'Liters'
        };
        return mapping[uomCode] || 'Pieces';
    }

    buildProductUOMOptions(product) {
        const options = [];
        const addedCodes = new Set();

        // The picker offers every active UOM from the master (getOrderUOMOptions).
        const master = this.uomOptionsData || [];
        const masterByCode = {};
        master.forEach(u => { if (u && u.value) masterByCode[u.value] = u.label; });

        // Base UOM first, as the default selection.
        const baseCode = product.BaseUOMCode || product.baseUOMCode || 'PCS';
        const baseName = product.BaseUOMName || product.baseUOMName || 'Piece';
        options.push({ label: masterByCode[baseCode] || (baseName + ' (' + baseCode + ')'), value: baseCode });
        addedCodes.add(baseCode);

        // Then every other active UOM from the master. (We do NOT parse the
        // product's free-text Ordering_UOMs__c into options — that is what
        // produced the malformed "PCS;BOX (PCS;BOX)" entry; the master is the
        // single source of the option list.)
        master.forEach(u => {
            if (u && u.value && !addedCodes.has(u.value)) {
                options.push({ label: u.label, value: u.value });
                addedCodes.add(u.value);
            }
        });

        return options;
    }

    getUOMOptionsForProduct(productId) {
        if (this.productUOMOptionsMap[productId]) {
            return this.productUOMOptionsMap[productId];
        }
        return this.uomOptions;
    }

    @wire(getProductCategories)
    wiredCategories({ error, data }) {
        if (data) {
            this.categoryOptionsData = data;
        } else if (error) {
            // eslint-disable-next-line no-console
            console.error('Failed to load product categories', error);
            this.categoryOptionsData = [];
            this.showToast('Error', 'Could not load product categories. Please refresh.', 'error');
        }
    }

    @wire(getWarehouses)
    wiredWarehouses({ error, data }) {
        if (data) {
            this.warehouseOptions = [
                { label: '-- Select Warehouse --', value: '' },
                ...data.map(w => ({ label: w.label, value: w.value }))
            ];
        } else if (error) {
            // eslint-disable-next-line no-console
            console.error('Failed to load warehouses', error);
            this.warehouseOptions = [{ label: '-- Select Warehouse --', value: '' }];
            this.showToast('Error', 'Could not load warehouses. Please refresh.', 'error');
        }
    }

    get hasWarehouseSelected() {
        return !!this.selectedWarehouseId;
    }

    handleWarehouseChange(event) {
        this.selectedWarehouseId = event.detail.value;
        // Re-check stock availability for all products in cart
        if (this.selectedWarehouseId && this.lineItems.length > 0) {
            this.refreshStockAvailability();
        } else {
            this.stockAvailabilityMap = {};
            this.updateLineItemStockInfo();
        }
    }

    async refreshStockAvailability() {
        if (!this.selectedWarehouseId) return;
        const productIds = [...new Set(this.lineItems.map(li => li.productId))];
        if (productIds.length === 0) return;

        try {
            const result = await checkStockAvailability({
                warehouseId: this.selectedWarehouseId,
                productIds: productIds
            });
            this.stockAvailabilityMap = result || {};
            this.updateLineItemStockInfo();
        } catch (error) {
            console.error('Error checking stock availability:', error);
        }
    }

    async checkStockForProducts(productIds) {
        if (!this.selectedWarehouseId || !productIds || productIds.length === 0) return;
        try {
            const result = await checkStockAvailability({
                warehouseId: this.selectedWarehouseId,
                productIds: productIds
            });
            if (result) {
                this.stockAvailabilityMap = { ...this.stockAvailabilityMap, ...result };
                this.updateLineItemStockInfo();
            }
        } catch (error) {
            console.error('Error checking stock:', error);
        }
    }

    updateLineItemStockInfo() {
        this.lineItems = this.lineItems.map(item => {
            const availQty = this.stockAvailabilityMap[item.productId];
            const hasStock = availQty !== undefined && availQty !== null;
            const isLowStock = hasStock && availQty < (item.quantity || 0);
            return {
                ...item,
                availableStock: hasStock ? availQty : null,
                availableStockLabel: hasStock ? 'Avail: ' + availQty : '',
                stockClass: isLowStock ? 'oef-stock-low' : (hasStock ? 'oef-stock-ok' : '')
            };
        });

        // Also update product search results
        if (this.productResults && this.productResults.length > 0) {
            this.productResults = this.productResults.map(product => {
                const availQty = this.stockAvailabilityMap[product.id];
                const hasStock = availQty !== undefined && availQty !== null;
                return {
                    ...product,
                    availableStock: hasStock ? availQty : null,
                    availableStockLabel: hasStock ? 'Stock: ' + availQty : ''
                };
            });
        }
    }

    @wire(getOrderUOMOptions)
    wiredUOMOptions({ error, data }) {
        if (data) {
            this.uomOptionsData = data;
            // Refresh UOM options on any existing line items that may have loaded before master UOMs
            this.refreshLineItemUOMOptions();
        }
    }

    refreshLineItemUOMOptions() {
        if (!this.lineItems || this.lineItems.length === 0 || !this.uomOptionsData || this.uomOptionsData.length === 0) return;

        this.lineItems = this.lineItems.map(item => {
            // Rebuild UOM options for each line item using the now-available master UOMs
            const uomOptions = this.buildProductUOMOptions({
                BaseUOMCode: item.baseUOMCode,
                BaseUOMName: this.getUOMNameByCode(item.baseUOMCode),
                SecondaryUOMCode: null,
                OrderingUOMs: null
            });
            this.productUOMOptionsMap = { ...this.productUOMOptionsMap, [item.productId]: uomOptions };
            return { ...item, productUOMOptions: uomOptions };
        });
    }

    getUOMNameByCode(code) {
        if (!code) return 'Piece';
        if (this.uomOptionsData && this.uomOptionsData.length > 0) {
            const match = this.uomOptionsData.find(u => u.value === code);
            if (match) {
                // Extract name from "Name (CODE)" format
                const label = match.label;
                const parenIdx = label.lastIndexOf('(');
                return parenIdx > 0 ? label.substring(0, parenIdx).trim() : label;
            }
        }
        const codeNameMap = {
            'PCS': 'Piece', 'PC': 'Piece', 'CS': 'Case', 'BOX': 'Box', 'BX': 'Box',
            'KG': 'Kilogram', 'LTR': 'Litre', 'DZ': 'Dozen', 'PK': 'Pack',
            'GRM': 'Gram', 'G': 'Gram', 'ML': 'Millilitre'
        };
        return codeNameMap[code] || code;
    }

    @wire(getRecord, { recordId: '$recordId', fields: ACCOUNT_FIELDS })
    wiredAccount({ error, data }) {
        if (data) {
            this.accountName = getFieldValue(data, 'Account.Name');
            this.accountChannel = getFieldValue(data, 'Account.Channel__c') || 'General Trade';
            this.accountClass = getFieldValue(data, 'Account.Outlet_Class__c') || 'B';
            this.selectedAccountId = this.recordId;
            this.initializeOrderData();
        } else if (error) {
            this.showToast('Error', 'Failed to load account details', 'error');
        }
    }

    _pullToRefreshHandler;
    _touchStartY = 0;

    connectedCallback() {
        this._disablePullToRefresh();
        if (this.draftOrderId) {
            this.loadDraftOrder(this.draftOrderId);
            return;
        }
        if (!this.recordId && this.accountId) {
            this.selectedAccountId = this.accountId;
            this.initializeOrderData();
        }
    }

    disconnectedCallback() {
        this._enablePullToRefresh();
    }

    _disablePullToRefresh() {
        document.body.style.overscrollBehaviorY = 'contain';
        document.documentElement.style.overscrollBehaviorY = 'contain';
        this._touchStartY = 0;
        this._pullToRefreshHandler = (e) => {
            if (window.scrollY === 0 && e.touches[0].clientY > this._touchStartY) {
                e.preventDefault();
            }
        };
        document.addEventListener('touchstart', (e) => {
            this._touchStartY = e.touches[0].clientY;
        }, { passive: true });
        document.addEventListener('touchmove', this._pullToRefreshHandler, { passive: false });
    }

    _enablePullToRefresh() {
        document.body.style.overscrollBehaviorY = '';
        document.documentElement.style.overscrollBehaviorY = '';
        if (this._pullToRefreshHandler) {
            document.removeEventListener('touchmove', this._pullToRefreshHandler);
        }
    }

    /**
     * Loads an existing Draft Sales_Order__c into the form for editing.
     * Populates selectedAccountId, lineItems, orderRemarks, totals, and
     * marks editingOrderId so Save Draft / Submit go to an UPDATE path
     * on the same record rather than creating a new order.
     */
    async loadDraftOrder(orderId) {
        this.isLoading = true;
        try {
            const data = await getDraftOrder({ orderId });
            if (!data) return;

            this.editingOrderId = data.orderId;
            this.editingOrderName = data.orderName || '';
            this.selectedAccountId = data.accountId;
            this.accountId = data.accountId;
            if (data.visitId) this.visitId = data.visitId;
            this.orderRemarks = data.remarks || '';
            if (data.warehouseId) this.selectedWarehouseId = data.warehouseId;

            // Load account-side context (pricing, schemes, must-sell products)
            // before mapping lines so each line can look up its scheme / UOM.
            await this.initializeOrderData();

            const newLineItems = (data.lineItems || []).map((li, idx) => {
                this.lineIdCounter++;
                const qty = li.quantity || 0;
                const rate = li.rate || 0;
                const taxRate = li.taxRate != null ? li.taxRate : 0;

                const baseUOMCode = li.baseUOMCode || 'PCS';
                const uomCode = li.uomCode || this.mapPicklistToCode(li.uom || 'Pieces');
                const convFactor = li.conversionFactor || 1;
                const baseQty = li.baseQuantity != null
                    ? li.baseQuantity
                    : qty * convFactor;

                // Re-run scheme resolution locally exactly like the
                // add-to-cart path does. We deliberately do NOT trust the
                // stored li.schemeId — earlier buggy saves (where an
                // order-level 'Snacks & Noodles 3% Off' scheme got stamped
                // on every line regardless of product) would otherwise
                // round-trip that wrong value forever.
                //
                // If the stored scheme still applies to this product per
                // findAllApplicableSchemes, we keep it (respects a user's
                // explicit choice among several applicable schemes). If
                // not, we pick the top applicable scheme for the product.
                const pseudoProduct = { id: li.productId, Id: li.productId };
                const applicableSchemes = this.findAllApplicableSchemes(pseudoProduct);
                let resolvedScheme = null;
                if (li.schemeId) {
                    resolvedScheme = applicableSchemes.find(s => s.Id === li.schemeId) || null;
                }
                if (!resolvedScheme) {
                    resolvedScheme = applicableSchemes.length > 0 ? applicableSchemes[0] : null;
                }

                const schemeInfo = {
                    schemeId: resolvedScheme ? resolvedScheme.Id : null,
                    schemeName: resolvedScheme ? resolvedScheme.Name : ''
                };

                // Recompute totals from qty * rate + scheme discount + tax so
                // the view agrees with whatever scheme now applies (either the
                // stored one or a newly-resolved one).
                const grossAmount = baseQty * rate;
                const freeQty = resolvedScheme
                    ? this.calculateFreeQty(qty, resolvedScheme,
                          { baseQuantity: baseQty, baseUOMCode, uomCode, conversionFactor: li.conversionFactor || 1 })
                    : (li.freeQty || 0);
                const discountAmount = resolvedScheme
                    ? this.calculateSchemeDiscount(grossAmount, qty, resolvedScheme)
                    : (li.discountAmount || 0);
                const taxableAmount = grossAmount - discountAmount;
                const taxAmount = taxableAmount * (taxRate / 100);
                const totalAmount = taxableAmount + taxAmount;
                // Build per-product UOM options so the UOM combobox has
                // something to show for its current value. Uses the base
                // UOM info we saved in getDraftOrder; secondary UOMs fall
                // back to 'not available' because that data isn't persisted
                // on the line. refreshLineItemUOMOptions() below re-runs
                // with the now-loaded master UOMs for a fuller option list.
                const productUOMOptions = this.buildProductUOMOptions({
                    BaseUOMCode: baseUOMCode,
                    BaseUOMName: this.getUOMNameByCode(baseUOMCode),
                    SecondaryUOMCode: null,
                    OrderingUOMs: null
                });
                this.productUOMOptionsMap = {
                    ...this.productUOMOptionsMap,
                    [li.productId]: productUOMOptions
                };

                // Line up with the minQuantity / classification surfaced by
                // getMustSellProducts so the 'Min: X' badge is correct when
                // the line's product is a Must-Sell.
                const msMatch = (this.mustSellProducts || []).find(p => p.productId === li.productId);
                const fsMatch = (this.focusedSellProducts || []).find(p => p.productId === li.productId);
                const classification = msMatch ? 'Must Sell' : (fsMatch ? 'Focused Sell' : '');
                const resolvedMinQty = msMatch ? msMatch.minQuantity
                    : (fsMatch ? fsMatch.minQuantity : 1);

                return {
                    id: 'LINE_' + this.lineIdCounter,
                    existingLineId: li.lineId,
                    productId: li.productId,
                    productName: li.productName,
                    sku: li.sku,
                    mrp: li.mrp,
                    quantity: qty,
                    baseQuantity: baseQty,
                    baseQuantityLabel: (uomCode !== baseUOMCode && qty > 0)
                        ? '= ' + baseQty + ' ' + baseUOMCode : '',
                    conversionFactor: convFactor,
                    freeQty: freeQty,
                    rate: rate,
                    rateFormatted: this.formatCurrency(rate * convFactor),
                    uom: li.uom || 'Pieces',
                    uomCode: uomCode,
                    baseUOMCode: baseUOMCode,
                    productUOMOptions: productUOMOptions,
                    grossAmount: grossAmount,
                    discountAmount: discountAmount,
                    discountFormatted: this.formatCurrency(discountAmount),
                    taxRate: taxRate,
                    taxAmount: taxAmount,
                    taxFormatted: this.formatCurrency(taxAmount),
                    totalAmount: totalAmount,
                    totalFormatted: this.formatCurrency(totalAmount),
                    schemeId: schemeInfo.schemeId,
                    schemeName: schemeInfo.schemeName,
                    classification: classification,
                    classificationBadgeClass: this.getClassificationBadgeClass(classification),
                    priceListId: li.priceListId,
                    priceListName: li.priceListName,
                    serialNumber: idx + 1,
                    rowClass: classification === 'Must Sell' ? 'oef-row-must-sell-pending' : '',
                    isMustSell: classification === 'Must Sell',
                    minQuantity: resolvedMinQty
                };
            });
            this.lineItems = newLineItems;
            // Refresh UOM options after master data is loaded (initializeOrderData
            // kicks off async loads; by now uomOptionsData may have arrived).
            this.refreshLineItemUOMOptions();
            this.calculateTotals();
            this.refreshMustSellStatus();
        } catch (error) {
            this.showToast('Error', 'Failed to load draft order: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleAccountChange(event) {
        this.selectedAccountId = event.detail.recordId;
        if (this.selectedAccountId) {
            this.loadAccountDetails();
            this.initializeOrderData();
        }
    }

    /**
     * Coordinates loading of order data ensuring schemes are loaded
     * before top-selling and must-sell products that depend on them.
     */
    async initializeOrderData() {
        this.loadCreditInfo();
        this.loadLastOrder();
        await this.loadSchemes();
        this.loadMustSellProducts();
        this.loadTopSellingProducts();
    }

    async loadCreditInfo() {
        if (!this.effectiveAccountId) return;
        try {
            const info = await getAccountCredit({ accountId: this.effectiveAccountId });
            if (info) {
                this.creditLimit = Number(info.creditLimit) || 0;
                this.outstandingBalance = Number(info.outstanding) || 0;
                // Prefer the real outlet name over the embedded 'Selected Outlet' placeholder.
                if (info.accountName) this.accountName = info.accountName;
            }
        } catch (error) {
            // Non-fatal: without credit data we simply do not block the submit.
            this.creditLimit = 0;
            this.outstandingBalance = 0;
        }
    }

    /**
     * Returns a message when this order would push the outlet past its credit
     * limit, or null when it is within limit / no ceiling is configured.
     */
    creditExceededMessage() {
        const limit = Number(this.creditLimit) || 0;
        if (limit <= 0) return null; // no ceiling configured -> never block
        const outstanding = Number(this.outstandingBalance) || 0;
        const orderNet = Number(this.orderSummary.netAmount) || 0;
        const projected = outstanding + orderNet;
        if (projected <= limit) return null;
        const over = projected - limit;
        return `This order of ${this.formatCurrency(orderNet)} would take ${this.accountName || 'the outlet'} `
            + `to ${this.formatCurrency(projected)} against a credit limit of ${this.formatCurrency(limit)} `
            + `(outstanding ${this.formatCurrency(outstanding)}) — over by ${this.formatCurrency(over)}.`;
    }

    loadAccountDetails() {
        if (this.selectedAccountId && !this.recordId) {
            this.accountName = 'Selected Outlet';
            this.accountChannel = 'General Trade';
            this.accountClass = 'B';
        }
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. No-op on camelCase
    // maps and wrapper DTOs (their keys have no prefix).
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

    async loadLastOrder() {
        if (!this.effectiveAccountId) return;
        try {
            const result = this._stripNs(await getLastOrder({ accountId: this.effectiveAccountId }));
            if (result) {
                this.lastOrderInfo = {
                    orderNumber: result.Name || result.Order_Number__c,
                    orderDate: this.formatDate(result.Order_Date__c || result.CreatedDate),
                    itemCount: result.Line_Item_Count__c || 0,
                    totalFormatted: this.formatCurrency(result.Net_Amount__c || 0),
                    id: result.Id,
                    lineItems: result.Order_Line_Items__r || []
                };
            }
        } catch (error) {
            console.error('Error loading last order:', error);
        }
    }

    async loadSchemes() {
        if (!this.effectiveAccountId) return;
        try {
            const result = this._stripNs(await getApplicableSchemes({ accountId: this.effectiveAccountId }));
            this.schemes = result || [];
        } catch (error) {
            console.error('Error loading schemes:', error);
        }
    }

    async loadMustSellProducts() {
        if (!this.effectiveAccountId) return;
        try {
            const result = await getMustSellProducts({
                accountId: this.effectiveAccountId,
                orderDate: null
            });
            const items = result || [];
            const orderedProductIds = new Set(this.lineItems.map(li => li.productId));

            this.mustSellProducts = items
                .filter(p => p.classification === 'Must Sell')
                .map(p => ({
                    ...p,
                    isInOrder: orderedProductIds.has(p.productId),
                    cardClass: orderedProductIds.has(p.productId)
                        ? 'oef-ms-card oef-ms-card-done' : 'oef-ms-card',
                    hasMinQty: p.minQuantity && p.minQuantity >= 1,
                    minQtyLabel: p.minQuantity ? 'Min Qty: ' + p.minQuantity : ''
                }));

            this.focusedSellProducts = items
                .filter(p => p.classification === 'Focused Sell')
                .map(p => ({
                    ...p,
                    isInOrder: orderedProductIds.has(p.productId),
                    cardClass: orderedProductIds.has(p.productId)
                        ? 'oef-ms-card oef-fs-card oef-ms-card-done' : 'oef-ms-card oef-fs-card'
                }));

            // Auto-add must-sell products to cart with qty 0
            this.autoAddMustSellToCart();
        } catch (error) {
            console.error('Error loading must-sell products:', error);
        }
    }

    autoAddMustSellToCart() {
        if (!this.mustSellProducts || this.mustSellProducts.length === 0) return;
        const orderedProductIds = new Set(this.lineItems.map(li => li.productId));
        let added = false;

        this.mustSellProducts.forEach(product => {
            if (orderedProductIds.has(product.productId)) return;

            this.lineIdCounter++;
            const baseUOMCode = product.baseUOMCode || this.mapPicklistToCode(product.uom || 'Piece');
            const defaultUOMCode = baseUOMCode;
            const defaultUOM = this.mapCodeToPicklist(defaultUOMCode);

            // Build full UOM options from product data
            const uomOptions = this.buildProductUOMOptions({
                BaseUOMCode: product.baseUOMCode,
                BaseUOMName: product.baseUOMName,
                SecondaryUOMCode: product.secondaryUOMCode,
                SecondaryUOMName: product.secondaryUOMName,
                OrderingUOMs: product.orderingUOMs,
                UOM: product.uom
            });
            this.productUOMOptionsMap = { ...this.productUOMOptionsMap, [product.productId]: uomOptions };

            // Auto-fill with min qty
            const qty = product.minQuantity || 1;
            const rate = product.unitPrice || product.mrp || 0;
            const grossAmount = qty * rate;
            const taxRate = product.gstRate || 18;

            // Find applicable scheme for must-sell product
            const scheme = this.findApplicableScheme({ id: product.productId, Id: product.productId });
            const freeQty = scheme ? this.calculateFreeQty(qty, scheme) : 0;
            const discountAmount = scheme ? this.calculateSchemeDiscount(grossAmount, qty, scheme) : 0;
            const taxableAmount = grossAmount - discountAmount;
            const taxAmount = taxableAmount * (taxRate / 100);
            const totalAmount = taxableAmount + taxAmount;

            const newItem = {
                id: 'LINE_' + this.lineIdCounter,
                productId: product.productId,
                productCategoryId: product.categoryId || '',
                productName: product.productName,
                sku: product.sku || 'N/A',
                uom: defaultUOM,
                uomCode: defaultUOMCode,
                baseUOMCode: baseUOMCode,
                conversionFactor: 1,
                baseQuantity: qty,
                baseQuantityLabel: '',
                productUOMOptions: uomOptions,
                rate: rate,
                rateFormatted: this.formatCurrency(rate),
                quantity: qty,
                freeQty: freeQty,
                schemeName: scheme ? scheme.Name : '',
                schemeId: scheme ? scheme.Id : null,
                classification: 'Must Sell',
                classificationBadgeClass: this.getClassificationBadgeClass('Must Sell'),
                taxRate: taxRate,
                grossAmount: grossAmount,
                discountAmount: discountAmount,
                discountFormatted: this.formatCurrency(discountAmount),
                taxAmount: taxAmount,
                taxFormatted: this.formatCurrency(taxAmount),
                totalAmount: totalAmount,
                totalFormatted: this.formatCurrency(totalAmount),
                serialNumber: this.lineItems.length + 1,
                rowClass: 'oef-row-must-sell-pending',
                isMustSell: true,
                minQuantity: product.minQuantity || 1
            };
            this.lineItems = [...this.lineItems, newItem];
            added = true;
        });

        if (added) {
            this.calculateTotals();
            this.refreshMustSellStatus();
        }
    }

    async loadTopSellingProducts() {
        if (!this.effectiveAccountId) return;
        try {
            const results = await getTopSellingProducts({ accountId: this.effectiveAccountId });
            const orderedProductIds = new Set(this.lineItems.map(li => li.productId));
            this.topSellingProducts = (results || []).map(product => {
                const allSchemes = this.findAllApplicableSchemes(product);
                const scheme = allSchemes.length > 0 ? allSchemes[0] : null;
                const schemeStrips = allSchemes.map(s => ({
                    id: s.Id,
                    name: s.Name,
                    description: this.buildSchemeBenefitText(s)
                }));
                const uomOpts = this.buildProductUOMOptions(product);
                this.productUOMOptionsMap = { ...this.productUOMOptionsMap, [product.Id]: uomOpts };

                return {
                    id: product.Id,
                    name: product.Name,
                    sku: product.SKU_Code || 'N/A',
                    mrp: product.MRP || product.Unit_Price || 0,
                    mrpFormatted: this.formatCurrency(product.MRP || product.Unit_Price || 0),
                    unitPrice: product.Unit_Price || 0,
                    taxRate: product.GST_Rate || 18,
                    productUOM: product.UOM || 'Piece',
                    baseUOMCode: product.BaseUOMCode || 'PCS',
                    baseUOMName: product.BaseUOMName || 'Piece',
                    secondaryUOMCode: product.SecondaryUOMCode,
                    orderingUOMs: product.OrderingUOMs,
                    caseSize: product.CaseSize,
                    productUOMOptions: uomOpts,
                    schemeName: scheme ? scheme.Name : '',
                    schemeId: scheme ? scheme.Id : null,
                    schemeStrips: schemeStrips,
                    hasSchemes: schemeStrips.length > 0,
                    isInOrder: orderedProductIds.has(product.Id),
                    cardClass: 'oef-top-sell-card' + (orderedProductIds.has(product.Id) ? ' oef-top-sell-done' : '')
                };
            });
        } catch (error) {
            console.error('Error loading top selling products:', error);
        }
    }

    toggleTopSelling() {
        this.showTopSelling = !this.showTopSelling;
    }

    handleAddTopSelling(event) {
        const productId = event.currentTarget.dataset.productId;
        const product = this.topSellingProducts.find(p => p.id === productId);
        if (!product) return;

        const existingIndex = this.lineItems.findIndex(item => item.productId === productId);
        if (existingIndex >= 0) {
            this.showToast('Info', product.name + ' is already in the order', 'info');
            return;
        }

        this.lineIdCounter++;
        const qty = 1;
        const scheme = product.schemeId ? this.schemes.find(s => s.Id === product.schemeId) : null;
        const freeQty = scheme ? this.calculateFreeQty(qty, scheme) : 0;
        const grossAmount = qty * product.unitPrice;
        const discountAmount = scheme ? this.calculateSchemeDiscount(grossAmount, qty, scheme) : 0;
        const taxableAmount = grossAmount - discountAmount;
        const taxAmount = taxableAmount * (product.taxRate / 100);
        const totalAmount = taxableAmount + taxAmount;

        const baseUOMCode = product.baseUOMCode || 'PCS';
        const defaultUOMCode = baseUOMCode;
        const defaultUOM = this.mapCodeToPicklist(defaultUOMCode);
        const uomOptions = product.productUOMOptions || this.buildProductUOMOptions(product);

        const newItem = {
            id: 'LINE_' + this.lineIdCounter,
            productId: product.id,
            productCategoryId: product.Product_Category || product.categoryId || '',
            productName: product.name,
            sku: product.sku,
            uom: defaultUOM,
            uomCode: defaultUOMCode,
            baseUOMCode: baseUOMCode,
            conversionFactor: 1,
            baseQuantity: qty,
            baseQuantityLabel: '',
            productUOMOptions: uomOptions,
            rate: product.unitPrice,
            rateFormatted: this.formatCurrency(product.unitPrice),
            quantity: qty,
            freeQty: freeQty,
            schemeName: product.schemeName || '',
            schemeId: product.schemeId || null,
            classification: '',
            classificationBadgeClass: '',
            taxRate: product.taxRate,
            grossAmount: grossAmount,
            discountAmount: discountAmount,
            discountFormatted: this.formatCurrency(discountAmount),
            taxAmount: taxAmount,
            taxFormatted: this.formatCurrency(taxAmount),
            totalAmount: totalAmount,
            totalFormatted: this.formatCurrency(totalAmount),
            serialNumber: this.lineItems.length + 1,
            rowClass: ''
        };
        this.lineItems = [...this.lineItems, newItem];
        this.calculateTotals();
        this.refreshMustSellStatus();
        this.refreshTopSellingStatus();
        this.showToast('Success', product.name + ' added to order', 'success');
    }

    refreshTopSellingStatus() {
        const orderedProductIds = new Set(this.lineItems.map(li => li.productId));
        this.topSellingProducts = this.topSellingProducts.map(p => ({
            ...p,
            isInOrder: orderedProductIds.has(p.id),
            cardClass: 'oef-top-sell-card' + (orderedProductIds.has(p.id) ? ' oef-top-sell-done' : '')
        }));
    }

    refreshMustSellStatus() {
        const orderedProductIds = new Set(this.lineItems.map(li => li.productId));
        this.mustSellProducts = this.mustSellProducts.map(p => ({
            ...p,
            isInOrder: orderedProductIds.has(p.productId),
            cardClass: orderedProductIds.has(p.productId)
                ? 'oef-ms-card oef-ms-card-done' : 'oef-ms-card',
            hasMinQty: p.minQuantity && p.minQuantity > 1,
            minQtyLabel: p.minQuantity ? 'Min Qty: ' + p.minQuantity : ''
        }));
        this.focusedSellProducts = this.focusedSellProducts.map(p => ({
            ...p,
            isInOrder: orderedProductIds.has(p.productId),
            cardClass: orderedProductIds.has(p.productId)
                ? 'oef-ms-card oef-fs-card oef-ms-card-done' : 'oef-ms-card oef-fs-card'
        }));
    }

    toggleSchemesPanel() {
        this.showSchemesPanel = !this.showSchemesPanel;
    }

    toggleFocusedSell() {
        this.showFocusedSell = !this.showFocusedSell;
    }

    handleAddMustSell(event) {
        const productId = event.currentTarget.dataset.productId;
        const classification = event.currentTarget.dataset.classification;
        const source = classification === 'Must Sell' ? this.mustSellProducts : this.focusedSellProducts;
        const product = source.find(p => p.productId === productId);
        if (!product) return;

        const existingIndex = this.lineItems.findIndex(item => item.productId === productId);
        if (existingIndex >= 0) {
            // If already in cart with qty 0 (auto-added must-sell), update to min qty
            const existingItem = this.lineItems[existingIndex];
            if (existingItem.quantity === 0) {
                const qty = product.minQuantity || 1;
                this.lineItems = this.lineItems.map((item, idx) => {
                    if (idx === existingIndex) {
                        return this.recalculateLineItem({
                            ...item,
                            quantity: qty,
                            rowClass: classification === 'Must Sell' ? 'oef-row-must-sell-pending' : ''
                        });
                    }
                    return item;
                });
                this.calculateTotals();
                this.refreshMustSellStatus();
                this.showToast('Success', product.productName + ' quantity updated', 'success');
                return;
            }
            this.showToast('Info', product.productName + ' is already in the order', 'info');
            return;
        }

        this.lineIdCounter++;
        const qty = product.minQuantity || 1;
        const rate = product.unitPrice || product.mrp || 0;
        const baseUOMCode = product.baseUOMCode || this.mapPicklistToCode(product.uom || 'Piece');
        const defaultUOMCode = baseUOMCode;
        const defaultUOM = this.mapCodeToPicklist(defaultUOMCode);

        // Build full UOM options from product data
        const uomOptions = this.buildProductUOMOptions({
            BaseUOMCode: product.baseUOMCode,
            BaseUOMName: product.baseUOMName,
            SecondaryUOMCode: product.secondaryUOMCode,
            SecondaryUOMName: product.secondaryUOMName,
            OrderingUOMs: product.orderingUOMs,
            UOM: product.uom
        });
        this.productUOMOptionsMap = { ...this.productUOMOptionsMap, [product.productId]: uomOptions };

        const taxRate = product.gstRate || 18;
        const grossAmount = qty * rate;
        const taxAmount = grossAmount * (taxRate / 100);
        const totalAmount = grossAmount + taxAmount;
        const newItem = {
            id: 'LINE_' + this.lineIdCounter,
            productId: product.productId,
            productCategoryId: product.Product_Category || product.categoryId || '',
            productName: product.productName,
            sku: product.sku || 'N/A',
            uom: defaultUOM,
            uomCode: defaultUOMCode,
            baseUOMCode: baseUOMCode,
            conversionFactor: 1,
            baseQuantity: qty,
            baseQuantityLabel: '',
            productUOMOptions: uomOptions,
            rate: rate,
            rateFormatted: this.formatCurrency(rate),
            quantity: qty,
            freeQty: 0,
            schemeName: product.schemeName || '',
            schemeId: product.schemeId || null,
            classification: classification,
            classificationBadgeClass: this.getClassificationBadgeClass(classification),
            taxRate: taxRate,
            grossAmount: grossAmount,
            discountAmount: 0,
            discountFormatted: this.formatCurrency(0),
            taxAmount: taxAmount,
            taxFormatted: this.formatCurrency(taxAmount),
            totalAmount: totalAmount,
            totalFormatted: this.formatCurrency(totalAmount),
            serialNumber: this.lineItems.length + 1,
            rowClass: classification === 'Must Sell' ? 'oef-row-must-sell-pending' : '',
            isMustSell: classification === 'Must Sell',
            minQuantity: product.minQuantity || 1
        };
        this.lineItems = [...this.lineItems, newItem];
        this.calculateTotals();
        this.refreshMustSellStatus();
        this.showToast('Success', product.productName + ' added to order', 'success');
    }

    handleSearchTermChange(event) {
        this.searchTerm = event.target.value;
        if (this.searchTerm.length >= 2) {
            this.debounceSearch();
        }
    }

    handleCategoryChange(event) {
        this.selectedCategory = event.detail.value;
        this.handleProductSearch();
    }

    debounceSearch() {
        clearTimeout(this._searchTimeout);
        this._searchTimeout = setTimeout(() => {
            this.handleProductSearch();
        }, 300);
    }

    async handleProductSearch() {
        if (!this.searchTerm && !this.selectedCategory) {
            this.showToast('Info', 'Please enter a search term or select a category', 'info');
            return;
        }

        this.isLoading = true;
        try {
            const results = await searchProducts({
                searchTerm: this.searchTerm,
                categoryId: this.selectedCategory,
                accountId: this.effectiveAccountId
            });

            this.productResults = (results || []).map(product => {
                const allSchemes = this.findAllApplicableSchemes(product);
                const scheme = allSchemes.length > 0 ? allSchemes[0] : null;
                const qty = 0;
                const unitPrice = product.Unit_Price || 0;
                const mrp = product.MRP || unitPrice;
                const freeQty = scheme ? this.calculateFreeQty(qty, scheme) : 0;
                const lineTotal = qty * unitPrice;
                const schemeDescription = scheme ? this.buildSchemeBenefitText(scheme) : '';

                const schemeStrips = allSchemes.map(s => ({
                    id: s.Id,
                    name: s.Name,
                    description: this.buildSchemeBenefitText(s)
                }));

                // Check if product is Must Sell or Focused Sell
                const msMatch = this.mustSellProducts.find(p => p.productId === product.Id);
                const fsMatch = this.focusedSellProducts.find(p => p.productId === product.Id);
                const classification = msMatch ? 'Must Sell' : (fsMatch ? 'Focused Sell' : '');
                const classificationBadgeClass = this.getClassificationBadgeClass(classification);

                // Build per-product UOM options
                const productUOMOpts = this.buildProductUOMOptions(product);
                const baseCode = product.BaseUOMCode || 'PCS';
                this.productUOMOptionsMap = {
                    ...this.productUOMOptionsMap,
                    [product.Id]: productUOMOpts
                };

                return {
                    id: product.Id,
                    name: product.Name,
                    sku: product.SKU_Code || 'N/A',
                    mrp: mrp,
                    mrpFormatted: this.formatCurrency(mrp),
                    unitPrice: unitPrice,
                    category: '',
                    taxRate: product.GST_Rate || 18,
                    productUOM: product.UOM || 'Piece',
                    defaultOrderUOM: this.mapProductUOMToOrderUOM(product.UOM || 'Piece'),
                    baseUOMCode: baseCode,
                    baseUOMId: product.BaseUOMId,
                    baseUOMName: product.BaseUOMName || 'Piece',
                    secondaryUOMCode: product.SecondaryUOMCode,
                    orderingUOMs: product.OrderingUOMs,
                    caseSize: product.CaseSize,
                    quantity: qty,
                    freeQty: freeQty,
                    schemeName: scheme ? scheme.Name : '',
                    schemeId: scheme ? scheme.Id : null,
                    schemeDescription: schemeDescription,
                    schemeStrips: schemeStrips,
                    hasSchemes: schemeStrips.length > 0,
                    classification: classification,
                    classificationBadgeClass: classificationBadgeClass,
                    hasClassification: !!classification,
                    lineTotal: lineTotal,
                    lineTotalFormatted: this.formatCurrency(lineTotal),
                    cardClass: allSchemes.length > 0 ? 'oef-product-card oef-product-card-scheme' : 'oef-product-card'
                };
            });
            // Check stock availability for search results if warehouse selected
            if (this.selectedWarehouseId && this.productResults.length > 0) {
                const searchProductIds = this.productResults.map(p => p.id);
                this.checkStockForProducts(searchProductIds);
            }
        } catch (error) {
            this.showToast('Error', 'Failed to search products: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleProductQtyChange(event) {
        const productId = event.target.dataset.productId;
        const qty = parseInt(event.target.value, 10) || 0;

        this.productResults = this.productResults.map(product => {
            if (product.id === productId) {
                const scheme = this.findApplicableScheme(product);
                const freeQty = scheme ? this.calculateFreeQty(qty, scheme) : 0;
                const lineTotal = qty * product.unitPrice;
                return {
                    ...product,
                    quantity: qty,
                    freeQty: freeQty,
                    lineTotal: lineTotal,
                    lineTotalFormatted: this.formatCurrency(lineTotal)
                };
            }
            return product;
        });
    }

    addToOrder(event) {
        const productId = event.target.dataset.productId || event.currentTarget.dataset.productId;
        const product = this.productResults.find(p => p.id === productId);

        if (!product) return;

        const qty = product.quantity || 1;
        if (qty <= 0) {
            this.showToast('Warning', 'Please enter a valid quantity', 'warning');
            return;
        }

        const existingIndex = this.lineItems.findIndex(item => item.productId === productId);
        if (existingIndex >= 0) {
            this.lineItems = this.lineItems.map((item, idx) => {
                if (idx === existingIndex) {
                    const newQty = item.quantity + qty;
                    return this.recalculateLineItem({ ...item, quantity: newQty });
                }
                return item;
            });
        } else {
            this.lineIdCounter++;
            const scheme = this.findApplicableScheme(product);
            const freeQty = scheme ? this.calculateFreeQty(qty, scheme) : 0;
            const grossAmount = qty * product.unitPrice;
            const discountAmount = scheme ? this.calculateSchemeDiscount(grossAmount, qty, scheme) : 0;
            const taxableAmount = grossAmount - discountAmount;
            const taxAmount = taxableAmount * (product.taxRate / 100);
            const totalAmount = taxableAmount + taxAmount;

            const msMatch = this.mustSellProducts.find(p => p.productId === product.id);
            const fsMatch = this.focusedSellProducts.find(p => p.productId === product.id);
            const classification = msMatch ? 'Must Sell' : (fsMatch ? 'Focused Sell' : '');

            const baseUOMCode = product.baseUOMCode || 'PCS';
            const defaultUOMCode = baseUOMCode;
            const defaultUOM = this.mapCodeToPicklist(defaultUOMCode);
            const uomOptions = this.buildProductUOMOptions(product);
            this.productUOMOptionsMap = { ...this.productUOMOptionsMap, [product.id]: uomOptions };

            const newItem = {
                id: 'LINE_' + this.lineIdCounter,
                productId: product.id,
                productName: product.name,
                sku: product.sku,
                uom: defaultUOM,
                uomCode: defaultUOMCode,
                baseUOMCode: baseUOMCode,
                conversionFactor: 1,
                baseQuantity: qty,
                baseQuantityLabel: '',
                productUOMOptions: uomOptions,
                rate: product.unitPrice,
                rateFormatted: this.formatCurrency(product.unitPrice),
                quantity: qty,
                freeQty: freeQty,
                schemeName: scheme ? scheme.Name : '',
                schemeId: scheme ? scheme.Id : null,
                classification: classification,
                classificationBadgeClass: this.getClassificationBadgeClass(classification),
                taxRate: product.taxRate,
                grossAmount: grossAmount,
                discountAmount: discountAmount,
                discountFormatted: this.formatCurrency(discountAmount),
                taxAmount: taxAmount,
                taxFormatted: this.formatCurrency(taxAmount),
                totalAmount: totalAmount,
                totalFormatted: this.formatCurrency(totalAmount),
                serialNumber: this.lineItems.length + 1,
                rowClass: ''
            };
            this.lineItems = [...this.lineItems, newItem];
        }

        this.calculateTotals();
        this.refreshMustSellStatus();
        this.refreshTopSellingStatus();
        // Check stock for newly added product
        if (this.selectedWarehouseId) {
            this.checkStockForProducts([product.id]);
        }
        this.showToast('Success', product.name + ' added to order', 'success');
    }

    removeLineItem(event) {
        const lineId = event.target.dataset.lineId || event.currentTarget.dataset.lineId;
        this.lineItems = this.lineItems
            .filter(item => item.id !== lineId)
            .map((item, idx) => ({ ...item, serialNumber: idx + 1 }));
        this.calculateTotals();
        this.refreshMustSellStatus();
        this.refreshTopSellingStatus();
    }

    handleLineQtyChange(event) {
        const lineId = event.target.dataset.lineId;
        const newQty = parseInt(event.target.value, 10) || 0;

        const item = this.lineItems.find(i => i.id === lineId);
        if (!item) return;

        // For non-must-sell items, qty must be at least 1
        if (!item.isMustSell && newQty <= 0) {
            this.showToast('Warning', 'Quantity must be at least 1', 'warning');
            return;
        }

        // Compute base quantity using the stored conversion factor
        const convFactor = item.conversionFactor || 1;
        const baseQty = newQty * convFactor;
        const baseUOMCode = item.baseUOMCode || 'PCS';
        const uomCode = item.uomCode || baseUOMCode;
        const baseQtyLabel = (uomCode !== baseUOMCode && newQty > 0)
            ? '= ' + baseQty + ' ' + baseUOMCode : '';

        this.lineItems = this.lineItems.map(li => {
            if (li.id === lineId) {
                const updated = this.recalculateLineItem({
                    ...li,
                    quantity: newQty,
                    baseQuantity: baseQty,
                    baseQuantityLabel: baseQtyLabel
                });
                // Clear red highlight when user enters valid qty
                if (li.isMustSell && newQty > 0) {
                    updated.rowClass = 'oef-row-must-sell-pending';
                }
                return updated;
            }
            return li;
        });

        this.calculateTotals();
        this.refreshMustSellStatus();
    }

    async handleLineUOMChange(event) {
        const lineId = event.target.dataset.lineId;
        const newUOMCode = event.detail.value;

        const item = this.lineItems.find(i => i.id === lineId);
        if (!item) return;

        const newUOMPicklist = this.mapCodeToPicklist(newUOMCode);
        const baseUOMCode = item.baseUOMCode || 'PCS';

        // Get conversion factor for the new UOM
        let convFactor = 1;
        let baseQty = item.quantity || 0;
        let baseQtyLabel = '';

        if (newUOMCode !== baseUOMCode && item.quantity > 0) {
            try {
                const result = await convertQuantity({
                    productId: item.productId,
                    fromUomCode: newUOMCode,
                    toUomCode: baseUOMCode,
                    quantity: item.quantity
                });
                convFactor = result.conversionFactor || 1;
                baseQty = result.convertedQuantity || item.quantity;
                baseQtyLabel = '= ' + baseQty + ' ' + baseUOMCode;

                // Warn if no conversion rule was found
                if (!result.hasConversion) {
                    this.showToast(
                        'Warning',
                        'No UOM conversion rule found from ' + newUOMCode + ' to ' + baseUOMCode +
                        ' for ' + item.productName + '. Please set up a conversion rule to get accurate pricing.',
                        'warning'
                    );
                }
            } catch (error) {
                console.error('UOM conversion error:', error);
                this.showToast(
                    'Error',
                    'UOM conversion failed: ' + (error.body ? error.body.message : error.message || 'Unknown error'),
                    'error'
                );
                convFactor = 1;
                baseQty = item.quantity;
            }
        }

        this.lineItems = this.lineItems.map(li => {
            if (li.id === lineId) {
                return this.recalculateLineItem({
                    ...li,
                    uom: newUOMPicklist,
                    uomCode: newUOMCode,
                    conversionFactor: convFactor,
                    baseQuantity: baseQty,
                    baseQuantityLabel: baseQtyLabel
                });
            }
            return li;
        });
        this.calculateTotals();
    }

    recalculateLineItem(item) {
        let scheme = this.schemes.find(s => s.Id === item.schemeId);
        // If no scheme found by ID, try to find one by product matching
        if (!scheme && item.productId) {
            scheme = this.findApplicableScheme({ id: item.productId, Id: item.productId });
            if (scheme) {
                item = { ...item, schemeId: scheme.Id, schemeName: scheme.Name };
            }
        }

        // Always recompute base quantity from entered qty and conversion factor
        const convFactor = item.conversionFactor || 1;
        const baseQuantity = item.quantity * convFactor;
        const baseUOMCode = item.baseUOMCode || 'PCS';
        const uomCode = item.uomCode || baseUOMCode;
        const baseQuantityLabel = (uomCode !== baseUOMCode && item.quantity > 0)
            ? '= ' + baseQuantity + ' ' + baseUOMCode : '';

        const freeQty = scheme ? this.calculateFreeQty(item.quantity, scheme, { ...item, baseQuantity }) : 0;

        // Unit price is per base UOM, so pricing must use base quantity
        const grossAmount = baseQuantity * item.rate;

        // Effective rate per selected UOM (for display purposes)
        const effectiveRate = item.rate * convFactor;

        // Use base quantity for scheme discount calculation (UOM-aware)
        const effectiveQtyForScheme = scheme ? this.convertQtyForScheme(item.quantity, { ...item, baseQuantity }, scheme) : baseQuantity;
        const discountAmount = scheme ? this.calculateSchemeDiscount(grossAmount, effectiveQtyForScheme, scheme) : 0;

        const taxableAmount = grossAmount - discountAmount;
        const taxAmount = taxableAmount * (item.taxRate / 100);
        const totalAmount = taxableAmount + taxAmount;

        return {
            ...item,
            baseQuantity: baseQuantity,
            baseQuantityLabel: baseQuantityLabel,
            freeQty: freeQty,
            grossAmount: grossAmount,
            rateFormatted: this.formatCurrency(effectiveRate),
            discountAmount: discountAmount,
            discountFormatted: this.formatCurrency(discountAmount),
            taxAmount: taxAmount,
            taxFormatted: this.formatCurrency(taxAmount),
            totalAmount: totalAmount,
            totalFormatted: this.formatCurrency(totalAmount)
        };
    }

    calculateTotals() {
        let grossAmount = 0;
        let totalDiscount = 0;
        let totalTax = 0;
        let totalQuantity = 0;

        this.lineItems.forEach(item => {
            grossAmount += item.grossAmount || 0;
            totalDiscount += item.discountAmount || 0;
            totalTax += item.taxAmount || 0;
            totalQuantity += item.quantity || 0;
        });

        const taxableAmount = grossAmount - totalDiscount;
        const netAmount = taxableAmount + totalTax;

        this.orderSummary = {
            grossAmount: grossAmount,
            totalDiscount: totalDiscount,
            taxableAmount: taxableAmount,
            totalTax: totalTax,
            netAmount: netAmount,
            totalItems: this.lineItems.length,
            totalQuantity: totalQuantity,
            grossAmountFormatted: this.formatCurrency(grossAmount),
            totalDiscountFormatted: this.formatCurrency(totalDiscount),
            taxableAmountFormatted: this.formatCurrency(taxableAmount),
            totalTaxFormatted: this.formatCurrency(totalTax),
            netAmountFormatted: this.formatCurrency(netAmount)
        };
    }

    findAllApplicableSchemes(product) {
        if (!this.schemes || this.schemes.length === 0) return [];
        const productId = product.id || product.Id;
        let productCategory = product.category || product.Category__c || product.Product_Category__c || '';

        // Resolve category from loaded product data if not provided
        if (!productCategory && productId && this.lineItems) {
            const line = this.lineItems.find(li => li.productId === productId);
            if (line) productCategory = line.productCategoryId || '';
        }
        if (!productCategory && productId) {
            const searchResult = (this.lastSearchResults || []).find(p => (p.productId || p.Id) === productId);
            if (searchResult) productCategory = searchResult.categoryId || searchResult.Product_Category__c || '';
        }

        const productSchemes = [];
        const categorySchemes = [];
        const invoiceSchemes = [];

        this.schemes.forEach(scheme => {
            // 1. Direct product match on scheme header
            if (scheme.Product_Ext__c && scheme.Product_Ext__c === productId) {
                productSchemes.push(scheme);
                return;
            }

            // 2. Check Scheme_Products__r child records for product-level mapping
            const schemeProducts = scheme.Scheme_Products__r;
            if (schemeProducts && schemeProducts.length > 0) {
                const hasProductInScheme = schemeProducts.some(
                    sp => sp.Product_Ext__c === productId && sp.Is_Buy_Product__c
                );
                if (hasProductInScheme) {
                    productSchemes.push(scheme);
                }
                return;
            }

            // 3. Category-level scheme (no specific products mapped)
            if (scheme.Product_Category__c && productCategory &&
                scheme.Product_Category__c === productCategory) {
                categorySchemes.push(scheme);
                return;
            }

            // 4. Invoice-level schemes (no product or category restriction)
            const invoiceTypes = ['Invoice Qty Based', 'Invoice Val Based'];
            if (!scheme.Product_Ext__c && !scheme.Product_Category__c &&
                invoiceTypes.includes(scheme.Scheme_Type__c)) {
                invoiceSchemes.push(scheme);
            }
        });

        return [...productSchemes, ...categorySchemes, ...invoiceSchemes];
    }

    findApplicableScheme(product) {
        const all = this.findAllApplicableSchemes(product);
        return all.length > 0 ? all[0] : null;
    }

    calculateFreeQty(qty, scheme, lineItem) {
        if (!scheme || !qty || qty <= 0) return 0;

        // Convert qty to scheme base UOM if applicable
        let effectiveQty = qty;
        if (lineItem) {
            effectiveQty = this.convertQtyForScheme(qty, lineItem, scheme);
        }

        // Check slab-based free products first
        if (scheme.Scheme_Slabs__r && scheme.Scheme_Slabs__r.length > 0) {
            const slab = this.findApplicableSlab(effectiveQty, 0, scheme);
            if (slab && slab.Discount_Type__c === 'Free Product' && slab.Free_Quantity__c) {
                // Slab gives a flat free quantity for the matched tier
                // (matches server-side applySlabBenefit which assigns slab.Free_Quantity__c directly)
                return slab.Free_Quantity__c;
            }
            // If slabs exist but no slab matched (qty below first slab threshold),
            // fall through to scheme-level logic below
        }

        // Scheme-level free products: repeating "Buy X Get Y Free" pattern
        if (scheme.Scheme_Category__c === 'Free Products') {
            // Determine the "buy X" divisor: prefer Scheme_Products buy product min qty,
            // then scheme header Min_Quantity__c
            let buyQty = scheme.Min_Quantity__c || 0;
            if (scheme.Scheme_Products__r && scheme.Scheme_Products__r.length > 0) {
                const buyProduct = scheme.Scheme_Products__r.find(
                    sp => sp.Is_Buy_Product__c && sp.Min_Quantity__c && sp.Min_Quantity__c > 0
                );
                if (buyProduct) {
                    buyQty = buyProduct.Min_Quantity__c;
                }
            }

            const freeQtyPerSet = scheme.Free_Quantity__c || 0;
            if (buyQty <= 0 || freeQtyPerSet <= 0) return 0;
            if (effectiveQty < buyQty) return 0;
            return Math.floor(effectiveQty / buyQty) * freeQtyPerSet;
        }
        return 0;
    }

    /**
     * Convert order line qty to scheme's base UOM for scheme evaluation.
     * Uses the line item's conversion factor and base UOM to align with scheme base UOM.
     */
    convertQtyForScheme(qty, lineItem, scheme) {
        if (!qty || qty <= 0) return 0;

        // Get scheme base UOM code
        const schemeBaseUOM = scheme.Base_UOM__r?.UOM_Code__c || null;
        const lineUOMCode = lineItem.uomCode || lineItem.baseUOMCode || 'PCS';
        const productBaseUOMCode = lineItem.baseUOMCode || 'PCS';

        // If scheme has a base UOM, convert to it
        if (schemeBaseUOM) {
            if (lineUOMCode === schemeBaseUOM) {
                return qty;
            }
            // First convert to product base UOM, then to scheme base UOM
            // Use the line's conversion factor to get base qty
            const baseQty = lineItem.baseQuantity || (qty * (lineItem.conversionFactor || 1));
            if (productBaseUOMCode === schemeBaseUOM) {
                return baseQty;
            }
            // Different base UOMs - use the base qty as best approximation
            return baseQty;
        }

        // No scheme base UOM: convert to product base UOM
        if (lineUOMCode !== productBaseUOMCode) {
            return lineItem.baseQuantity || (qty * (lineItem.conversionFactor || 1));
        }

        return qty;
    }

    calculateSchemeDiscount(amount, qty, scheme) {
        if (!scheme || !scheme.Scheme_Category__c) return 0;

        // Check slab-based discounts first
        if (scheme.Scheme_Slabs__r && scheme.Scheme_Slabs__r.length > 0) {
            const slab = this.findApplicableSlab(qty, amount, scheme);
            if (!slab) return 0;
            return this.calculateSlabDiscount(amount, slab, scheme);
        }

        // Check minimum thresholds before applying scheme-level discounts
        if (!this.meetsSchemeThreshold(qty, amount, scheme)) return 0;

        let discount = 0;

        if (scheme.Scheme_Category__c === 'Discount in %' && scheme.Discount_Percent__c) {
            discount = amount * (scheme.Discount_Percent__c / 100);
        } else if (scheme.Scheme_Category__c === 'Discount in Value') {
            const discountVal = scheme.Price_Discount__c || scheme.Discount_Amount__c || 0;
            discount = Math.min(discountVal, amount);
        }

        // Apply Max Discount Cap
        if (scheme.Max_Discount_Cap__c && discount > scheme.Max_Discount_Cap__c) {
            discount = scheme.Max_Discount_Cap__c;
        }

        return discount;
    }

    meetsSchemeThreshold(qty, amount, scheme) {
        const schemeType = scheme.Scheme_Type__c || '';

        // Quantity-based types: check Min_Quantity__c
        if (schemeType.includes('(QTY)') || schemeType === 'Invoice Qty Based') {
            const minQty = scheme.Min_Quantity__c || 0;
            if (minQty > 0 && qty < minQty) return false;
        }

        // Value-based types: check MOV or Min_Value__c
        if (schemeType.includes('(VAL)') || schemeType === 'Invoice Val Based') {
            const minVal = scheme.MOV__c || scheme.Min_Value__c || 0;
            if (minVal > 0 && amount < minVal) return false;
        }

        // Invoice Val Based: also check Invoice_Val_Threshold__c
        if (schemeType === 'Invoice Val Based' && scheme.Invoice_Val_Threshold__c) {
            if (amount < scheme.Invoice_Val_Threshold__c) return false;
        }

        // Invoice Qty Based: also check Invoice_Qty_Threshold__c
        if (schemeType === 'Invoice Qty Based' && scheme.Invoice_Qty_Threshold__c) {
            if (qty < scheme.Invoice_Qty_Threshold__c) return false;
        }

        return true;
    }

    findApplicableSlab(qty, amount, scheme) {
        if (!scheme.Scheme_Slabs__r || scheme.Scheme_Slabs__r.length === 0) return null;

        // Slabs are ordered ASC by Min_Quantity/Min_Value.
        // For tiered slabs (with Max boundaries), only one slab matches.
        // For open-ended slabs (no Max), return the highest matching slab.
        let matchedSlab = null;
        for (const slab of scheme.Scheme_Slabs__r) {
            if (slab.Slab_Type__c === 'Quantity') {
                const compareQty = qty || 0;
                const minQ = slab.Min_Quantity__c != null ? slab.Min_Quantity__c : slab.Min_Value__c;
                const maxQ = slab.Max_Quantity__c != null ? slab.Max_Quantity__c : slab.Max_Value__c;
                const meetsMin = minQ == null || compareQty >= minQ;
                const meetsMax = maxQ == null || compareQty <= maxQ;
                if (meetsMin && meetsMax) matchedSlab = slab;
            } else {
                const compareVal = amount || 0;
                const meetsMin = slab.Min_Value__c == null || compareVal >= slab.Min_Value__c;
                const meetsMax = slab.Max_Value__c == null || compareVal <= slab.Max_Value__c;
                if (meetsMin && meetsMax) matchedSlab = slab;
            }
        }
        return matchedSlab;
    }

    calculateSlabDiscount(amount, slab, scheme) {
        let discount = 0;
        const discountType = slab.Discount_Type__c || '';

        if (discountType === 'Percent') {
            const pct = slab.Discount_Value__c || slab.Discount_Percent__c || 0;
            discount = amount * (pct / 100);
        } else if (discountType === 'Amount') {
            discount = slab.Discount_Value__c || slab.Discount_Amount__c || 0;
            discount = Math.min(discount, amount);
        } else if (discountType === 'Price Discount') {
            discount = slab.Price_Discount__c || 0;
            discount = Math.min(discount, amount);
        }
        // Free Product and Reward Points don't produce a monetary discount

        // Apply Max Discount Cap from parent scheme
        if (scheme && scheme.Max_Discount_Cap__c && discount > scheme.Max_Discount_Cap__c) {
            discount = scheme.Max_Discount_Cap__c;
        }

        return discount;
    }

    async handleReorderLastOrder() {
        if (!this.lastOrderInfo || !this.lastOrderInfo.lineItems) return;

        this.isLoading = true;
        try {
            const lastItems = this.lastOrderInfo.lineItems;
            for (const lastItem of lastItems) {
                this.lineIdCounter++;
                const reorderUOM = lastItem.UOM__c || 'Pieces';
                const reorderUOMCode = this.mapPicklistToCode(reorderUOM);

                // Use the product's actual base UOM, not the order UOM
                const productBaseUOMCode = lastItem.Product_Ext__r?.Base_UOM__r?.UOM_Code__c || reorderUOMCode;
                const convFactor = lastItem.Conversion_Factor__c || 1;
                const enteredQty = lastItem.Quantity__c || 0;
                const baseQty = lastItem.Base_Quantity__c || (enteredQty * convFactor);
                const baseQtyLabel = (reorderUOMCode !== productBaseUOMCode && enteredQty > 0)
                    ? '= ' + baseQty + ' ' + productBaseUOMCode : '';

                // Build full UOM options; use cached map if available
                const reorderUOMOptions = this.productUOMOptionsMap[lastItem.Product_Ext__c]
                    || this.buildProductUOMOptions({ BaseUOMCode: productBaseUOMCode, BaseUOMName: this.getUOMNameByCode(productBaseUOMCode) });
                this.productUOMOptionsMap = { ...this.productUOMOptionsMap, [lastItem.Product_Ext__c]: reorderUOMOptions };

                // Pricing uses base quantity since unit price is per base UOM
                const rate = lastItem.Unit_Price__c || 0;
                const grossAmount = baseQty * rate;

                // Find applicable scheme for recalculation
                const scheme = this.findApplicableScheme({ id: lastItem.Product_Ext__c, Id: lastItem.Product_Ext__c });
                const freeQty = scheme ? this.calculateFreeQty(enteredQty, scheme, { baseQuantity: baseQty, baseUOMCode: productBaseUOMCode, uomCode: reorderUOMCode, conversionFactor: convFactor }) : (lastItem.Free_Quantity__c || 0);
                const discountAmount = scheme ? this.calculateSchemeDiscount(grossAmount, baseQty, scheme) : (lastItem.Discount_Amount__c || 0);
                const taxRate = lastItem.Tax_Rate__c || 18;
                const taxableAmount = grossAmount - discountAmount;
                const taxAmount = taxableAmount * (taxRate / 100);
                const totalAmount = taxableAmount + taxAmount;

                const newItem = {
                    id: 'LINE_' + this.lineIdCounter,
                    productId: lastItem.Product_Ext__c,
                    productName: lastItem.Product_Ext__r?.Name || 'Product',
                    sku: lastItem.Product_Ext__r?.SKU_Code__c || 'N/A',
                    uom: reorderUOM,
                    uomCode: reorderUOMCode,
                    baseUOMCode: productBaseUOMCode,
                    conversionFactor: convFactor,
                    baseQuantity: baseQty,
                    baseQuantityLabel: baseQtyLabel,
                    productUOMOptions: reorderUOMOptions,
                    rate: rate,
                    rateFormatted: this.formatCurrency(rate),
                    quantity: enteredQty,
                    freeQty: freeQty,
                    schemeName: scheme ? scheme.Name : '',
                    schemeId: scheme ? scheme.Id : null,
                    taxRate: taxRate,
                    grossAmount: grossAmount,
                    discountAmount: discountAmount,
                    discountFormatted: this.formatCurrency(discountAmount),
                    taxAmount: taxAmount,
                    taxFormatted: this.formatCurrency(taxAmount),
                    totalAmount: totalAmount,
                    totalFormatted: this.formatCurrency(totalAmount),
                    serialNumber: this.lineItems.length + 1,
                    rowClass: 'oef-reorder-row'
                };
                this.lineItems = [...this.lineItems, newItem];
            }
            this.calculateTotals();
            this.refreshMustSellStatus();
            this.showToast('Success', 'Last order items loaded for reorder', 'success');
        } catch (error) {
            this.showToast('Error', 'Failed to load last order', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleClearCart() {
        this.lineItems = [];
        this.calculateTotals();
        this.refreshMustSellStatus();
        this.refreshTopSellingStatus();
        this.mustSellHighlightActive = false;
        // Re-add must-sell products with qty 0
        this.autoAddMustSellToCart();
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleRemarksChange(event) {
        this.orderRemarks = event.target.value;
    }

    async handleSubmitOrder() {
        if (!this.validateOrder()) return;

        // Check must-sell products with qty 0 or below min - highlight red
        if (this.mustSellProducts && this.mustSellProducts.length > 0) {
            let hasViolation = false;

            this.lineItems = this.lineItems.map(item => {
                if (item.isMustSell && (!item.quantity || item.quantity <= 0)) {
                    hasViolation = true;
                    return { ...item, rowClass: 'oef-row-must-sell-error' };
                }
                // Check if must-sell below min qty
                const msProduct = this.mustSellProducts.find(p => p.productId === item.productId);
                if (msProduct && msProduct.minQuantity && item.quantity < msProduct.minQuantity) {
                    hasViolation = true;
                    return { ...item, rowClass: 'oef-row-must-sell-error' };
                }
                // Clear any previous highlight for non-violating rows
                if (item.rowClass === 'oef-row-must-sell-error') {
                    return { ...item, rowClass: item.isMustSell ? 'oef-row-must-sell-pending' : '' };
                }
                return item;
            });

            this.mustSellHighlightActive = hasViolation;

            if (hasViolation) {
                this.showToast('Warning', 'Please add quantity for all Must Sell products (highlighted in red) before submitting', 'warning');
                return;
            }
        }

        this._submitOrder(false);
    }

    handleMustSellWarningClose() {
        this.showMustSellWarning = false;
    }

    handleMustSellAddProducts() {
        this.showMustSellWarning = false;
    }

    get canOverrideMustSell() {
        // Cannot override if Must Sell products are missing or below min qty
        return this.missingMustSellProducts.length === 0 && this.mustSellBelowMinQty.length === 0;
    }

    handleMustSellSubmitAnyway() {
        if (!this.canOverrideMustSell) {
            this.showToast('Error', 'Cannot submit without all priority sell products meeting minimum quantity', 'error');
            return;
        }
        this.showMustSellWarning = false;
        this._submitOrder(true);
    }

    async _submitOrder(mustSellOverride) {
        // Credit control — an over-limit order is not blocked; it is submitted
        // and routed for approval on the server. Warn the rep up front so the
        // "sent for approval" outcome is expected.
        const creditMsg = this.creditExceededMessage();
        if (creditMsg) {
            this.showToast('Credit Limit Exceeded', creditMsg + ' This order will be sent for approval.', 'warning');
        }

        this.isSubmitting = true;
        this.isLoading = true;

        try {
            const orderData = this.buildOrderPayload('Submitted');
            orderData.mustSellOverride = mustSellOverride;
            if (mustSellOverride && this.mustSellProducts.length > 0) {
                const orderedProductIds = new Set(this.lineItems.map(li => li.productId));
                const ordered = this.mustSellProducts.filter(p => orderedProductIds.has(p.productId)).length;
                orderData.mustSellCompliance = (ordered / this.mustSellProducts.length) * 100;
            } else if (this.mustSellProducts.length > 0) {
                orderData.mustSellCompliance = 100;
            }
            const result = this._stripNs(await createSalesOrder({ orderJson: JSON.stringify(orderData) }));

            if (result && result.Requires_Credit_Approval__c) {
                this.showToast('Sent for Approval',
                    'Order ' + (result.Name || result.Id) + ' exceeds the credit limit and has been submitted for approval.',
                    'warning');
            } else {
                this.showToast('Success', 'Order submitted successfully! Order #: ' + (result.Name || result.Id), 'success');
            }
            this._lastCreatedOrderId = result.Id;
            this._lastCreatedOrderName = result.Name;
            this.showOrderPdfPrompt = true;
            this.resetForm();

            this.dispatchEvent(new CustomEvent('success', {
                detail: { recordId: result.Id, orderNumber: result.Name, type: 'order' }
            }));

            if (result.Id && !this.accountId) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: result.Id,
                        objectApiName: 'Sales_Order__c',
                        actionName: 'view'
                    }
                });
            }
        } catch (error) {
            this.showToast('Error', 'Failed to submit order: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSubmitting = false;
            this.isLoading = false;
        }
    }

    async handleSaveDraft() {
        if (this.lineItems.length === 0) {
            this.showToast('Warning', 'Add at least one product to save draft', 'warning');
            return;
        }
        this.isSubmitting = true;
        this.isLoading = true;

        try {
            const orderData = this.buildOrderPayload('Draft');
            const result = this._stripNs(await createSalesOrder({ orderJson: JSON.stringify(orderData) }));

            // Remember the draft's Id so subsequent Save Draft / Submit
            // calls update the SAME record instead of creating duplicates.
            if (result && result.Id) {
                this.editingOrderId = result.Id;
                this.editingOrderName = result.Name || this.editingOrderName;
            }

            this.showToast('Success', 'Draft saved successfully!', 'success');
        } catch (error) {
            this.showToast('Error', 'Failed to save draft: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isSubmitting = false;
            this.isLoading = false;
        }
    }

    buildOrderPayload(status) {
        // Filter out must-sell items with qty 0 (placeholders only)
        const activeLineItems = this.lineItems.filter(item => item.quantity && item.quantity > 0);
        return {
            // Present only in the edit flow — controller uses this as the
            // 'update existing order' signal (see createSalesOrder).
            orderId: this.editingOrderId || undefined,
            accountId: this.effectiveAccountId,
            visitId: this.visitId || this.recordId,
            warehouseId: this.selectedWarehouseId || null,
            status: status,
            remarks: this.orderRemarks,
            grossAmount: this.orderSummary.grossAmount,
            totalDiscount: this.orderSummary.totalDiscount,
            totalTax: this.orderSummary.totalTax,
            netAmount: this.orderSummary.netAmount,
            lineItems: activeLineItems.map(item => ({
                productId: item.productId,
                quantity: item.quantity,
                baseQuantity: item.baseQuantity || item.quantity,
                conversionFactor: item.conversionFactor || 1,
                freeQty: item.freeQty,
                rate: item.rate,
                uom: item.uom || 'Pieces',
                uomCode: item.uomCode || this.mapPicklistToCode(item.uom || 'Pieces'),
                baseUOMCode: item.baseUOMCode || 'PCS',
                grossAmount: item.grossAmount,
                discountAmount: item.discountAmount,
                taxRate: item.taxRate,
                taxAmount: item.taxAmount,
                totalAmount: item.totalAmount,
                schemeId: item.schemeId,
                // Tell the server the Min Qty the UI showed for this
                // product (from the Must-Sell 'Min: X' badge). The OLI
                // trigger honours this over the product MOQ so the save
                // can't reject a line that the UI said was acceptable.
                minQuantity: item.minQuantity,
                // Persist the Price_List__c that priced this line so the
                // record shows exactly which entry applied, and a future
                // draft-edit can rehydrate with the same source.
                priceListId: item.priceListId || null
            }))
        };
    }

    validateOrder() {
        if (!this.effectiveAccountId) {
            this.showToast('Error', 'Please select an outlet', 'error');
            return false;
        }
        // Count non-must-sell items with valid qty
        const validItems = this.lineItems.filter(item => item.quantity && item.quantity > 0);
        if (validItems.length === 0) {
            this.showToast('Error', 'Add at least one product with quantity to the order', 'error');
            return false;
        }
        // Check non-must-sell items have valid qty
        const invalidNonMustSell = this.lineItems.filter(item => !item.isMustSell && (!item.quantity || item.quantity <= 0));
        if (invalidNonMustSell.length > 0) {
            this.showToast('Error', 'All non-priority line items must have a valid quantity', 'error');
            return false;
        }
        return true;
    }

    resetForm() {
        this.lineItems = [];
        this.productResults = [];
        this.searchTerm = '';
        this.selectedCategory = '';
        this.orderRemarks = '';
        // Clear the edit-context so the next save creates a fresh order
        // instead of re-saving the submitted one.
        this.editingOrderId = null;
        this.editingOrderName = '';
        this.calculateTotals();
    }

    getClassificationBadgeClass(classification) {
        if (classification === 'Must Sell') return 'oef-badge-must-sell';
        if (classification === 'Focused Sell') return 'oef-badge-focused-sell';
        return '';
    }

    formatCurrency(value) {
        if (value === null || value === undefined) return '₹0.00';
        return new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'INR',
            minimumFractionDigits: 2
        }).format(value);
    }

    formatDate(dateStr) {
        if (!dateStr) return '';
        const date = new Date(dateStr);
        return date.toLocaleDateString('en-IN', {
            day: '2-digit',
            month: 'short',
            year: 'numeric'
        });
    }

    handleDownloadOrderPdf() {
        if (this._lastCreatedOrderId) {
            const url = '/apex/SalesOrderPDF?id=' + this._lastCreatedOrderId;
            if (/Android|iPhone|iPad|iPod/i.test(navigator.userAgent)) {
                window.location.href = url;
            } else {
                window.open(url, '_blank');
            }
        }
        this.showOrderPdfPrompt = false;
    }

    handleDismissPdfPrompt() {
        this.showOrderPdfPrompt = false;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        if (Array.isArray(error.body)) {
            return error.body.map(e => e.message).join(', ');
        }
        return 'Unknown error';
    }
}