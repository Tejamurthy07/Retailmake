import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getActiveSchemes from '@salesforce/apex/SchemeViewController.getActiveSchemes';
import getSchemeDetails from '@salesforce/apex/SchemeViewController.getSchemeDetails';
import calculateSchemeDiscount from '@salesforce/apex/SchemeViewController.calculateSchemeDiscount';

const CATEGORY_COLORS = {
    'Free Products': { bg: '#fff8e1', color: '#dd7a01', short: 'FP' },
    'Discount in %': { bg: '#e8f4fd', color: '#0176d3', short: '%' },
    'Discount in Value': { bg: '#e6f7e9', color: '#2e844a', short: 'Rs' },
    'Reward Points': { bg: '#f3e8ff', color: '#9b59b6', short: 'RP' }
};

export default class SchemeViewer extends LightningElement {
    @api accountId;

    @track activeSchemes = [];
    @track selectedScheme = null;
    @track calculatorResult = null;

    filterCategory = '';
    filterType = '';
    filterChannel = '';
    calculatorQty = 0;
    calculatorValue = 0;
    isLoading = false;

    get schemeCategoryOptions() {
        return [
            { label: 'All Categories', value: '' },
            { label: 'Free Products', value: 'Free Products' },
            { label: 'Discount in %', value: 'Discount in %' },
            { label: 'Discount in Value', value: 'Discount in Value' },
            { label: 'Reward Points', value: 'Reward Points' }
        ];
    }

    get schemeTypeOptions() {
        return [
            { label: 'All Types', value: '' },
            { label: 'Same Product (QTY)', value: 'Same Product (QTY)' },
            { label: 'Same Product (VAL)', value: 'Same Product (VAL)' },
            { label: 'Assorted Product (QTY)', value: 'Assorted Product (QTY)' },
            { label: 'Assorted Product (VAL)', value: 'Assorted Product (VAL)' },
            { label: 'Invoice Qty Based', value: 'Invoice Qty Based' },
            { label: 'Invoice Val Based', value: 'Invoice Val Based' }
        ];
    }

    get channelOptions() {
        return [
            { label: 'All Channels', value: '' },
            { label: 'GT', value: 'GT' },
            { label: 'MT', value: 'MT' },
            { label: 'E-Commerce', value: 'E-Commerce' },
            { label: 'Wholesale', value: 'Wholesale' },
            { label: 'Institutional', value: 'Institutional' }
        ];
    }

    get filteredSchemes() {
        return this.activeSchemes.filter(scheme => {
            const catMatch = !this.filterCategory || scheme.category === this.filterCategory;
            const typeMatch = !this.filterType || scheme.schemeType === this.filterType;
            const chanMatch = !this.filterChannel || scheme.channel === this.filterChannel || scheme.channel === 'All';
            return catMatch && typeMatch && chanMatch;
        });
    }

    get hasSchemes() {
        return this.filteredSchemes && this.filteredSchemes.length > 0;
    }

    connectedCallback() {
        this.loadSchemes();
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. No-op on camelCase
    // maps (their keys have no prefix).
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

    async loadSchemes() {
        this.isLoading = true;
        try {
            const result = this._stripNs(await getActiveSchemes({
                schemeCategory: this.filterCategory || null,
                schemeType: this.filterType || null,
                channel: this.filterChannel || null
            }));
            this.activeSchemes = (result || []).map(scheme => this.mapScheme(scheme));
        } catch (error) {
            this.showToast('Error', 'Failed to load schemes: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    mapScheme(scheme) {
        const catConfig = CATEGORY_COLORS[scheme.Scheme_Category__c] ||
            { bg: '#f3f3f3', color: '#706e6b', short: '?' };
        const isSelected = this.selectedScheme && this.selectedScheme.id === scheme.Id;

        return {
            id: scheme.Id,
            name: scheme.Name,
            code: scheme.Scheme_Code__c || '',
            category: scheme.Scheme_Category__c || '',
            schemeType: scheme.Scheme_Type__c || '',
            categoryShort: catConfig.short,
            categoryBadgeStyle: 'background-color: ' + catConfig.bg + '; color: ' + catConfig.color,
            description: scheme.Description__c || '',
            validFrom: this.formatDate(scheme.Start_Date__c),
            validTo: this.formatDate(scheme.End_Date__c),
            channel: scheme.Channel__c || 'All',
            discountPercent: scheme.Discount_Percent__c || 0,
            discountAmount: scheme.Discount_Amount__c || 0,
            priceDiscount: scheme.Price_Discount__c || 0,
            rewardPoints: scheme.Reward_Points__c || 0,
            mov: scheme.MOV__c || 0,
            freeQty: scheme.Free_Quantity__c || 0,
            freeProductName: scheme.Free_Product_Ext__r ? scheme.Free_Product_Ext__r.Name : '',
            minQty: scheme.Min_Quantity__c || 0,
            invoiceQtyThreshold: scheme.Invoice_Qty_Threshold__c || 0,
            invoiceValThreshold: scheme.Invoice_Val_Threshold__c || 0,
            budgetAmount: scheme.Budget_Amount__c || 0,
            budgetRemaining: scheme.Budget_Remaining__c || 0,
            benefitSummary: this.getBenefitSummary(scheme),
            triggerSummary: this.getTriggerSummary(scheme),
            buyProducts: scheme.Scheme_Products__r
                ? scheme.Scheme_Products__r.filter(sp => sp.Is_Buy_Product__c).map(sp => ({
                    id: sp.Id,
                    name: sp.Product_Ext__r ? sp.Product_Ext__r.Name : 'Product',
                    sku: sp.Product_Ext__r ? (sp.Product_Ext__r.SKU_Code__c || '') : '',
                    minQty: sp.Min_Quantity__c || 0,
                    isBuy: sp.Is_Buy_Product__c
                }))
                : [],
            getProducts: scheme.Scheme_Products__r
                ? scheme.Scheme_Products__r.filter(sp => sp.Is_Get_Product__c).map(sp => ({
                    id: sp.Id,
                    name: sp.Product_Ext__r ? sp.Product_Ext__r.Name : 'Product',
                    sku: sp.Product_Ext__r ? (sp.Product_Ext__r.SKU_Code__c || '') : ''
                }))
                : [],
            productBadges: scheme.Scheme_Products__r
                ? scheme.Scheme_Products__r.filter(sp => sp.Is_Buy_Product__c).slice(0, 3).map(sp =>
                    sp.Product_Ext__r ? sp.Product_Ext__r.Name : 'Product')
                : [],
            hasSlabs: scheme.Scheme_Slabs__r && scheme.Scheme_Slabs__r.length > 0,
            slabs: scheme.Scheme_Slabs__r
                ? scheme.Scheme_Slabs__r.map((slab, idx) => ({
                    id: slab.Id || 'slab_' + idx,
                    slabType: slab.Slab_Type__c || 'Value',
                    minValue: slab.Min_Value__c || 0,
                    maxValue: slab.Max_Value__c || 'Unlimited',
                    minQty: slab.Min_Quantity__c || 0,
                    maxQty: slab.Max_Quantity__c || 'Unlimited',
                    discountType: slab.Discount_Type__c || '',
                    discountPercent: slab.Discount_Percent__c || slab.Discount_Value__c || 0,
                    discountAmount: slab.Discount_Amount__c || 0,
                    priceDiscount: slab.Price_Discount__c || 0,
                    rewardPoints: slab.Reward_Points__c || 0,
                    freeQty: slab.Free_Quantity__c || 0,
                    freeProduct: slab.Free_Product_Ext__r ? slab.Free_Product_Ext__r.Name : ''
                }))
                : [],
            hasBuyProducts: scheme.Scheme_Products__r && scheme.Scheme_Products__r.some(sp => sp.Is_Buy_Product__c),
            hasGetProducts: scheme.Scheme_Products__r && scheme.Scheme_Products__r.some(sp => sp.Is_Get_Product__c),
            cardClass: 'scheme-card' + (isSelected ? ' scheme-card-selected' : '')
        };
    }

    getBenefitSummary(scheme) {
        const cat = scheme.Scheme_Category__c;
        if (cat === 'Free Products') {
            const name = scheme.Free_Product_Ext__r ? scheme.Free_Product_Ext__r.Name : 'product';
            return 'Get ' + (scheme.Free_Quantity__c || 0) + ' ' + name + ' free';
        } else if (cat === 'Discount in %') {
            return (scheme.Discount_Percent__c || 0) + '% discount';
        } else if (cat === 'Discount in Value') {
            return this.formatCurrency(scheme.Price_Discount__c || scheme.Discount_Amount__c || 0) + ' off';
        } else if (cat === 'Reward Points') {
            return (scheme.Reward_Points__c || 0) + ' reward points';
        }
        return '';
    }

    getTriggerSummary(scheme) {
        const type = scheme.Scheme_Type__c;
        if (type === 'Same Product (QTY)') {
            return 'Buy min ' + (scheme.Min_Quantity__c || 0) + ' qty of same product';
        } else if (type === 'Same Product (VAL)') {
            return 'MOV ' + this.formatCurrency(scheme.MOV__c || scheme.Min_Value__c || 0) + ' on same product';
        } else if (type === 'Assorted Product (QTY)') {
            return 'Buy assorted products (min qty per product)';
        } else if (type === 'Assorted Product (VAL)') {
            return 'MOV ' + this.formatCurrency(scheme.MOV__c || scheme.Min_Value__c || 0) + ' across assorted products';
        } else if (type === 'Invoice Qty Based') {
            return 'Invoice qty min ' + (scheme.Invoice_Qty_Threshold__c || 0) + ' ' + (scheme.Invoice_Qty_UOM__c || '');
        } else if (type === 'Invoice Val Based') {
            return 'Invoice value min ' + this.formatCurrency(scheme.Invoice_Val_Threshold__c || 0);
        }
        return type || '';
    }

    async handleSchemeSelect(event) {
        const schemeId = event.currentTarget.dataset.schemeId;
        const scheme = this.activeSchemes.find(s => s.id === schemeId);
        if (!scheme) return;

        this.activeSchemes = this.activeSchemes.map(s => ({
            ...s,
            cardClass: s.id === schemeId ? 'scheme-card scheme-card-selected' : 'scheme-card'
        }));

        try {
            const details = this._stripNs(await getSchemeDetails({ schemeId }));
            if (details) {
                this.selectedScheme = this.mapScheme(details);
            } else {
                this.selectedScheme = scheme;
            }
        } catch (error) {
            this.selectedScheme = scheme;
        }

        this.calculatorResult = null;
        this.calculatorQty = 0;
        this.calculatorValue = 0;
    }

    handleCategoryFilter(event) {
        this.filterCategory = event.detail.value;
    }

    handleTypeFilter(event) {
        this.filterType = event.detail.value;
    }

    handleChannelFilter(event) {
        this.filterChannel = event.detail.value;
    }

    handleClearFilters() {
        this.filterCategory = '';
        this.filterType = '';
        this.filterChannel = '';
    }

    handleCalculatorQtyChange(event) {
        this.calculatorQty = parseInt(event.detail.value, 10) || 0;
    }

    handleCalculatorValueChange(event) {
        this.calculatorValue = parseFloat(event.detail.value) || 0;
    }

    async handleCalculate() {
        if (!this.selectedScheme) {
            this.showToast('Warning', 'Please select a scheme first', 'warning');
            return;
        }

        if (this.calculatorQty <= 0 && this.calculatorValue <= 0) {
            this.showToast('Warning', 'Please enter quantity or order value', 'warning');
            return;
        }

        try {
            const result = await calculateSchemeDiscount({
                schemeId: this.selectedScheme.id,
                quantity: this.calculatorQty,
                value: this.calculatorValue
            });

            if (result) {
                const grossAmount = this.calculatorValue || 0;
                const discountAmt = result.discountAmount || 0;
                const priceDisc = result.priceDiscount || 0;
                const totalDisc = discountAmt + priceDisc;
                const netAmount = grossAmount - totalDisc;

                this.calculatorResult = {
                    grossAmount,
                    grossAmountFormatted: this.formatCurrency(grossAmount),
                    discount: totalDisc,
                    discountFormatted: this.formatCurrency(totalDisc),
                    discountPercent: result.discountPercent || 0,
                    priceDiscount: priceDisc,
                    priceDiscountFormatted: this.formatCurrency(priceDisc),
                    freeQty: result.freeQuantity || 0,
                    freeProductName: result.freeProductName || '',
                    rewardPoints: result.rewardPoints || 0,
                    netAmount,
                    netAmountFormatted: this.formatCurrency(netAmount),
                    effectiveDiscountPercent: grossAmount > 0
                        ? Math.round((totalDisc / grossAmount) * 100 * 100) / 100 : 0,
                    schemeCategory: result.schemeCategory || '',
                    hasFreeProduct: (result.freeQuantity || 0) > 0,
                    hasRewardPoints: (result.rewardPoints || 0) > 0,
                    hasDiscount: totalDisc > 0
                };
            }
        } catch (error) {
            this.showToast('Error', 'Calculation failed: ' + this.reduceErrors(error), 'error');
        }
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