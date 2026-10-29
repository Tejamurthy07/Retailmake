import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import getScheme from '@salesforce/apex/SchemeDefinitionController.getScheme';
import saveScheme from '@salesforce/apex/SchemeDefinitionController.saveScheme';
import searchProducts from '@salesforce/apex/SchemeDefinitionController.searchProducts';
import generateSchemeCode from '@salesforce/apex/SchemeDefinitionController.generateSchemeCode';

const CATEGORY_OPTIONS = [
    { label: 'Free Products', value: 'Free Products' },
    { label: 'Discount in %', value: 'Discount in %' },
    { label: 'Discount in Value', value: 'Discount in Value' },
    { label: 'Reward Points', value: 'Reward Points' }
];

const TYPE_OPTIONS = [
    { label: 'Same Product (QTY)', value: 'Same Product (QTY)' },
    { label: 'Same Product (VAL)', value: 'Same Product (VAL)' },
    { label: 'Assorted Product (QTY)', value: 'Assorted Product (QTY)' },
    { label: 'Assorted Product (VAL)', value: 'Assorted Product (VAL)' },
    { label: 'Invoice Qty Based', value: 'Invoice Qty Based' },
    { label: 'Invoice Val Based', value: 'Invoice Val Based' }
];

const STATUS_OPTIONS = [
    { label: 'Draft', value: 'Draft' },
    { label: 'Pending Approval', value: 'Pending Approval' },
    { label: 'Active', value: 'Active' },
    { label: 'Expired', value: 'Expired' },
    { label: 'Cancelled', value: 'Cancelled' }
];

const CHANNEL_OPTIONS = [
    { label: 'GT', value: 'GT' },
    { label: 'MT', value: 'MT' },
    { label: 'E-Commerce', value: 'E-Commerce' },
    { label: 'All', value: 'All' }
];

const OUTLET_TYPE_OPTIONS = [
    { label: 'Grocery', value: 'Grocery' },
    { label: 'Medical', value: 'Medical' },
    { label: 'Hardware', value: 'Hardware' },
    { label: 'General Store', value: 'General Store' }
];

const TIER_OPTIONS = [
    { label: '--None--', value: '' },
    { label: 'Base', value: 'Base' },
    { label: 'Pro', value: 'Pro' },
    { label: 'Enterprise', value: 'Enterprise' }
];

const INVOICE_UOM_OPTIONS = [
    { label: 'PC', value: 'PC' },
    { label: 'KG', value: 'KG' },
    { label: 'LTR', value: 'LTR' },
    { label: 'CS', value: 'CS' }
];

const SLAB_TYPE_OPTIONS = [
    { label: 'Quantity', value: 'Quantity' },
    { label: 'Value', value: 'Value' }
];

const DISCOUNT_TYPE_OPTIONS = [
    { label: 'Percent', value: 'Percent' },
    { label: 'Amount', value: 'Amount' },
    { label: 'Free Product', value: 'Free Product' },
    { label: 'Price Discount', value: 'Price Discount' },
    { label: 'Reward Points', value: 'Reward Points' }
];

const CUSTOMER_TYPE_OPTIONS = [
    { label: 'D2R', value: 'D2R' },
    { label: 'Wholesale', value: 'Wholesale' },
    { label: 'Modern Trade', value: 'Modern Trade' },
    { label: 'Institutional', value: 'Institutional' }
];

let _tempIdCounter = 0;
function tempId() { return 'tmp_' + (++_tempIdCounter); }

export default class SchemeDefinition extends NavigationMixin(LightningElement) {
    @api recordId;

    // Picklist options
    categoryOptions = CATEGORY_OPTIONS;
    typeOptions = TYPE_OPTIONS;
    statusOptions = STATUS_OPTIONS;
    channelOptions = CHANNEL_OPTIONS;
    outletTypeOptions = OUTLET_TYPE_OPTIONS;
    tierOptions = TIER_OPTIONS;
    invoiceUomOptions = INVOICE_UOM_OPTIONS;
    slabTypeOptions = SLAB_TYPE_OPTIONS;
    discountTypeOptions = DISCOUNT_TYPE_OPTIONS;
    customerTypeOptions = CUSTOMER_TYPE_OPTIONS;

    // Scheme fields
    @track scheme = {
        Name: '',
        Scheme_Code__c: '',
        Scheme_Category__c: 'Free Products',
        Scheme_Type__c: 'Same Product (QTY)',
        Description__c: '',
        Start_Date__c: null,
        End_Date__c: null,
        Status__c: 'Draft',
        Applicable_Channel__c: '',
        Applicable_Outlet_Type__c: '',
        Discount_Percent__c: null,
        Discount_Amount__c: null,
        Price_Discount__c: null,
        Reward_Points__c: null,
        MOV__c: null,
        Free_Product_Ext__c: null,
        Free_Quantity__c: null,
        Min_Quantity__c: null,
        Max_Quantity__c: null,
        Min_Value__c: null,
        Max_Value__c: null,
        Invoice_Qty_Threshold__c: null,
        Invoice_Qty_UOM__c: 'PC',
        Invoice_Val_Threshold__c: null,
        Max_Discount_Cap__c: null,
        Priority__c: 1,
        Is_Stackable__c: false,
        Tier__c: '',
        Budget_Amount__c: null,
        Product_Ext__c: null,
        Product_Category__c: null
    };

    // Child records
    @track schemeProducts = [];
    @track schemeSlabs = [];
    @track schemeMappings = [];

    // Deleted IDs for tracking
    deletedProductIds = [];
    deletedSlabIds = [];
    deletedMappingIds = [];

    // UI State
    isLoading = false;
    activeStep = '1';
    @track productSearchResults = [];
    @track freeProductSearchResults = [];
    productSearchTerm = '';
    freeProductSearchTerm = '';

    get isEditMode() { return !!this.recordId; }
    get pageTitle() { return this.isEditMode ? 'Edit Scheme' : 'New Scheme'; }

    // ── Step Navigation ──────────────────────────────────────────────────

    get steps() {
        return ['Basic Info', 'Benefit Config', 'Products', 'Slabs', 'Geo Mapping'].map((label, i) => {
            const value = String(i + 1);
            const active = this.activeStep === value;
            return {
                label,
                value,
                active,
                circleClass: active ? 'step-circle step-active' : 'step-circle',
                labelClass: active ? 'step-label step-label-active' : 'step-label'
            };
        });
    }

    get isStep1() { return this.activeStep === '1'; }
    get isStep2() { return this.activeStep === '2'; }
    get isStep3() { return this.activeStep === '3'; }
    get isStep4() { return this.activeStep === '4'; }
    get isStep5() { return this.activeStep === '5'; }
    get isFirstStep() { return this.activeStep === '1'; }
    get isLastStep() { return this.activeStep === '5'; }

    handleStepClick(event) {
        this.activeStep = event.currentTarget.dataset.step;
    }

    handleNext() {
        const num = parseInt(this.activeStep, 10);
        if (num < 5) this.activeStep = String(num + 1);
    }

    handlePrevious() {
        const num = parseInt(this.activeStep, 10);
        if (num > 1) this.activeStep = String(num - 1);
    }

    // ── Category/Type Conditional Visibility ──────────────────────────────

    get isFreeProducts() { return this.scheme.Scheme_Category__c === 'Free Products'; }
    get isDiscountPercent() { return this.scheme.Scheme_Category__c === 'Discount in %'; }
    get isDiscountValue() { return this.scheme.Scheme_Category__c === 'Discount in Value'; }
    get isRewardPoints() { return this.scheme.Scheme_Category__c === 'Reward Points'; }

    get isQtyBased() {
        const t = this.scheme.Scheme_Type__c;
        return t === 'Same Product (QTY)' || t === 'Assorted Product (QTY)';
    }
    get isValBased() {
        const t = this.scheme.Scheme_Type__c;
        return t === 'Same Product (VAL)' || t === 'Assorted Product (VAL)';
    }
    get isInvoiceQtyBased() { return this.scheme.Scheme_Type__c === 'Invoice Qty Based'; }
    get isInvoiceValBased() { return this.scheme.Scheme_Type__c === 'Invoice Val Based'; }

    get showMinMaxQty() { return this.isQtyBased; }
    get showMOV() { return this.isValBased; }
    get showInvoiceQtyFields() { return this.isInvoiceQtyBased; }
    get showInvoiceValFields() { return this.isInvoiceValBased; }

    get hasProducts() { return this.schemeProducts.length > 0; }
    get hasSlabs() { return this.schemeSlabs.length > 0; }
    get hasMappings() { return this.schemeMappings.length > 0; }

    // ── Lifecycle ─────────────────────────────────────────────────────────

    connectedCallback() {
        if (this.recordId) {
            this.loadScheme();
        } else {
            this.genCode();
        }
    }

    async genCode() {
        try {
            const code = await generateSchemeCode();
            this.scheme = { ...this.scheme, Scheme_Code__c: code };
        } catch (e) {
            // non-blocking
        }
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. Recurses into child
    // relationships (Scheme_Products__r, Product_Ext__r). No-op on plain maps.
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

    async loadScheme() {
        this.isLoading = true;
        try {
            const data = this._stripNs(await getScheme({ schemeId: this.recordId }));
            this.scheme = { ...data };

            this.schemeProducts = (data.Scheme_Products__r || []).map(p => ({
                ...p,
                _key: p.Id,
                productName: p.Product_Ext__r ? p.Product_Ext__r.Name : '',
                productSku: p.Product_Ext__r ? (p.Product_Ext__r.SKU_Code__c || '') : ''
            }));

            this.schemeSlabs = (data.Scheme_Slabs__r || []).map(s => ({
                ...s,
                _key: s.Id
            }));

            this.schemeMappings = (data.Scheme_Mappings__r || []).map(m => ({
                ...m,
                _key: m.Id,
                accountName: m.Account__r ? m.Account__r.Name : ''
            }));
        } catch (error) {
            this.showToast('Error', 'Failed to load scheme: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Scheme Field Handlers ─────────────────────────────────────────────

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        let value = event.detail.value;

        // Handle multiselect (returns array)
        if (Array.isArray(value)) {
            value = value.join(';');
        }

        this.scheme = { ...this.scheme, [field]: value };
    }

    handleCheckboxChange(event) {
        const field = event.target.dataset.field;
        this.scheme = { ...this.scheme, [field]: event.target.checked };
    }

    // ── Product Search & Management ───────────────────────────────────────

    handleProductSearch(event) {
        this.productSearchTerm = event.detail.value;
        if (this.productSearchTerm.length >= 2) {
            this.doProductSearch(this.productSearchTerm, false);
        } else {
            this.productSearchResults = [];
        }
    }

    handleFreeProductSearch(event) {
        this.freeProductSearchTerm = event.detail.value;
        if (this.freeProductSearchTerm.length >= 2) {
            this.doProductSearch(this.freeProductSearchTerm, true);
        } else {
            this.freeProductSearchResults = [];
        }
    }

    async doProductSearch(term, isFree) {
        try {
            const results = this._stripNs(await searchProducts({ searchTerm: term }));
            const mapped = results.map(p => ({
                id: p.Id,
                name: p.Name,
                sku: p.SKU_Code__c || '',
                brand: p.Brand__c || '',
                mrp: p.MRP__c || 0,
                label: p.Name + (p.SKU_Code__c ? ' (' + p.SKU_Code__c + ')' : '')
            }));
            if (isFree) {
                this.freeProductSearchResults = mapped;
            } else {
                this.productSearchResults = mapped;
            }
        } catch (e) {
            // silent
        }
    }

    handleSelectProduct(event) {
        const prodId = event.currentTarget.dataset.id;
        const prod = this.productSearchResults.find(p => p.id === prodId);
        if (!prod) return;

        // Check duplicate
        if (this.schemeProducts.some(p => p.Product_Ext__c === prodId && p.Is_Buy_Product__c)) return;

        this.schemeProducts = [...this.schemeProducts, {
            _key: tempId(),
            Product_Ext__c: prodId,
            productName: prod.name,
            productSku: prod.sku,
            Is_Buy_Product__c: true,
            Is_Get_Product__c: false,
            Min_Quantity__c: 1
        }];
        this.productSearchResults = [];
        this.productSearchTerm = '';
    }

    handleSelectFreeProduct(event) {
        const prodId = event.currentTarget.dataset.id;
        const prod = this.freeProductSearchResults.find(p => p.id === prodId);
        if (!prod) return;

        this.scheme = { ...this.scheme, Free_Product_Ext__c: prodId };
        this.freeProductSearchResults = [];
        this.freeProductSearchTerm = prod.name;
    }

    handleSelectGetProduct(event) {
        const prodId = event.currentTarget.dataset.id;
        const prod = this.productSearchResults.find(p => p.id === prodId);
        if (!prod) return;

        if (this.schemeProducts.some(p => p.Product_Ext__c === prodId && p.Is_Get_Product__c)) return;

        this.schemeProducts = [...this.schemeProducts, {
            _key: tempId(),
            Product_Ext__c: prodId,
            productName: prod.name,
            productSku: prod.sku,
            Is_Buy_Product__c: false,
            Is_Get_Product__c: true,
            Min_Quantity__c: 0
        }];
        this.productSearchResults = [];
        this.productSearchTerm = '';
    }

    handleProductMinQtyChange(event) {
        const key = event.target.dataset.key;
        const val = parseInt(event.detail.value, 10) || 0;
        this.schemeProducts = this.schemeProducts.map(p =>
            p._key === key ? { ...p, Min_Quantity__c: val } : p
        );
    }

    handleRemoveProduct(event) {
        const key = event.currentTarget.dataset.key;
        const prod = this.schemeProducts.find(p => p._key === key);
        if (prod && prod.Id) {
            this.deletedProductIds.push(prod.Id);
        }
        this.schemeProducts = this.schemeProducts.filter(p => p._key !== key);
    }

    get buyProducts() { return this.schemeProducts.filter(p => p.Is_Buy_Product__c); }
    get getProducts() { return this.schemeProducts.filter(p => p.Is_Get_Product__c); }
    get hasBuyProducts() { return this.buyProducts.length > 0; }
    get hasGetProducts() { return this.getProducts.length > 0; }

    // ── Slab Management ───────────────────────────────────────────────────

    handleAddSlab() {
        this.schemeSlabs = [...this.schemeSlabs, {
            _key: tempId(),
            Slab_Type__c: 'Value',
            Min_Value__c: 0,
            Max_Value__c: null,
            Min_Quantity__c: null,
            Max_Quantity__c: null,
            Discount_Type__c: 'Percent',
            Discount_Value__c: 0,
            Discount_Percent__c: null,
            Discount_Amount__c: null,
            Price_Discount__c: null,
            Reward_Points__c: null,
            Free_Product_Ext__c: null,
            Free_Quantity__c: null,
            Is_Active__c: true
        }];
    }

    handleSlabFieldChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        const value = event.detail.value;
        this.schemeSlabs = this.schemeSlabs.map(s =>
            s._key === key ? { ...s, [field]: value } : s
        );
    }

    handleRemoveSlab(event) {
        const key = event.currentTarget.dataset.key;
        const slab = this.schemeSlabs.find(s => s._key === key);
        if (slab && slab.Id) {
            this.deletedSlabIds.push(slab.Id);
        }
        this.schemeSlabs = this.schemeSlabs.filter(s => s._key !== key);
    }

    // ── Mapping Management ────────────────────────────────────────────────

    handleAddMapping() {
        this.schemeMappings = [...this.schemeMappings, {
            _key: tempId(),
            Zone__c: '',
            Sub_Zone__c: '',
            District__c: '',
            Area__c: '',
            Customer_Type__c: '',
            Is_Active__c: true
        }];
    }

    handleMappingFieldChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        const value = event.detail.value;
        this.schemeMappings = this.schemeMappings.map(m =>
            m._key === key ? { ...m, [field]: value } : m
        );
    }

    handleRemoveMapping(event) {
        const key = event.currentTarget.dataset.key;
        const mapping = this.schemeMappings.find(m => m._key === key);
        if (mapping && mapping.Id) {
            this.deletedMappingIds.push(mapping.Id);
        }
        this.schemeMappings = this.schemeMappings.filter(m => m._key !== key);
    }

    // ── Save ──────────────────────────────────────────────────────────────

    async handleSave() {
        if (!this.validateForm()) return;

        this.isLoading = true;
        try {
            // Build scheme record (strip relationship fields)
            const schemeToSave = this.buildSchemeRecord();

            // Build child records (strip temp keys and relationship fields)
            const productsToSave = this.schemeProducts.map(p => {
                const rec = { Product_Ext__c: p.Product_Ext__c, Is_Buy_Product__c: p.Is_Buy_Product__c, Is_Get_Product__c: p.Is_Get_Product__c, Min_Quantity__c: p.Min_Quantity__c };
                if (p.Id) rec.Id = p.Id;
                return rec;
            });

            const slabsToSave = this.schemeSlabs.map(s => {
                const rec = {
                    Slab_Type__c: s.Slab_Type__c, Min_Value__c: s.Min_Value__c,
                    Max_Value__c: s.Max_Value__c, Min_Quantity__c: s.Min_Quantity__c,
                    Max_Quantity__c: s.Max_Quantity__c, Discount_Type__c: s.Discount_Type__c,
                    Discount_Value__c: s.Discount_Value__c, Discount_Percent__c: s.Discount_Percent__c,
                    Discount_Amount__c: s.Discount_Amount__c, Price_Discount__c: s.Price_Discount__c,
                    Reward_Points__c: s.Reward_Points__c, Free_Product_Ext__c: s.Free_Product_Ext__c,
                    Free_Quantity__c: s.Free_Quantity__c, Is_Active__c: s.Is_Active__c
                };
                if (s.Id) rec.Id = s.Id;
                return rec;
            });

            const mappingsToSave = this.schemeMappings.map(m => {
                const rec = {
                    Zone__c: m.Zone__c, Sub_Zone__c: m.Sub_Zone__c,
                    District__c: m.District__c, Area__c: m.Area__c,
                    Customer_Type__c: m.Customer_Type__c, Is_Active__c: m.Is_Active__c
                };
                if (m.Id) rec.Id = m.Id;
                return rec;
            });

            // Pass records as JSON, not typed SObjects — in the ftretailmake
            // managed-package namespace an SObject param drops any value whose
            // key lacks the prefix, so the server rebuilds them from these maps.
            const schemeId = await saveScheme({
                schemeJson: JSON.stringify(schemeToSave),
                productsJson: JSON.stringify(productsToSave),
                slabsJson: JSON.stringify(slabsToSave),
                mappingsJson: JSON.stringify(mappingsToSave),
                deletedProductIds: this.deletedProductIds,
                deletedSlabIds: this.deletedSlabIds,
                deletedMappingIds: this.deletedMappingIds
            });

            this.showToast('Success', 'Scheme saved successfully', 'success');
            this.navigateToRecord(schemeId);
        } catch (error) {
            this.showToast('Error', 'Failed to save: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    buildSchemeRecord() {
        const s = this.scheme;
        const rec = {
            Name: s.Name,
            Scheme_Code__c: s.Scheme_Code__c,
            Scheme_Category__c: s.Scheme_Category__c,
            Scheme_Type__c: s.Scheme_Type__c,
            Description__c: s.Description__c || null,
            Start_Date__c: s.Start_Date__c,
            End_Date__c: s.End_Date__c,
            Status__c: s.Status__c,
            Applicable_Channel__c: s.Applicable_Channel__c || null,
            Applicable_Outlet_Type__c: s.Applicable_Outlet_Type__c || null,
            Discount_Percent__c: s.Discount_Percent__c,
            Discount_Amount__c: s.Discount_Amount__c,
            Price_Discount__c: s.Price_Discount__c,
            Reward_Points__c: s.Reward_Points__c,
            MOV__c: s.MOV__c,
            Free_Product_Ext__c: s.Free_Product_Ext__c || null,
            Free_Quantity__c: s.Free_Quantity__c,
            Min_Quantity__c: s.Min_Quantity__c,
            Max_Quantity__c: s.Max_Quantity__c,
            Min_Value__c: s.Min_Value__c,
            Max_Value__c: s.Max_Value__c,
            Invoice_Qty_Threshold__c: s.Invoice_Qty_Threshold__c,
            Invoice_Qty_UOM__c: s.Invoice_Qty_UOM__c || null,
            Invoice_Val_Threshold__c: s.Invoice_Val_Threshold__c,
            Max_Discount_Cap__c: s.Max_Discount_Cap__c,
            Priority__c: s.Priority__c,
            Is_Stackable__c: s.Is_Stackable__c || false,
            Tier__c: s.Tier__c || null,
            Budget_Amount__c: s.Budget_Amount__c,
            Product_Ext__c: s.Product_Ext__c || null,
            Product_Category__c: s.Product_Category__c || null
        };
        if (s.Id) rec.Id = s.Id;
        return rec;
    }

    validateForm() {
        const s = this.scheme;
        if (!s.Name || !s.Name.trim()) {
            this.showToast('Validation', 'Scheme Name is required', 'error');
            this.activeStep = '1';
            return false;
        }
        if (!s.Scheme_Code__c || !s.Scheme_Code__c.trim()) {
            this.showToast('Validation', 'Scheme Code is required', 'error');
            this.activeStep = '1';
            return false;
        }
        if (!s.Start_Date__c || !s.End_Date__c) {
            this.showToast('Validation', 'Start Date and End Date are required', 'error');
            this.activeStep = '1';
            return false;
        }
        if (s.Start_Date__c > s.End_Date__c) {
            this.showToast('Validation', 'End Date must be after Start Date', 'error');
            this.activeStep = '1';
            return false;
        }
        return true;
    }

    handleCancel() {
        if (this.recordId) {
            this.navigateToRecord(this.recordId);
        } else {
            this[NavigationMixin.Navigate]({
                type: 'standard__objectPage',
                attributes: { objectApiName: 'Scheme__c', actionName: 'list' },
                state: { filterName: 'Recent' }
            });
        }
    }

    navigateToRecord(recordId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, objectApiName: 'Scheme__c', actionName: 'view' }
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