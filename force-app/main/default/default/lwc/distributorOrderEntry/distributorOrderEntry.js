import { LightningElement, wire, track, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getProductCatalog from '@salesforce/apex/DMS_PortalController.getProductCatalog';
import getProductClassifications from '@salesforce/apex/DMS_PortalController.getProductClassifications';
import getSchemes from '@salesforce/apex/DMS_PortalController.getSchemes';
import getRetailers from '@salesforce/apex/DMS_PortalController.getRetailers';
import placeIndent from '@salesforce/apex/DMS_PortalController.placeIndent';
import placeSecondarySale from '@salesforce/apex/DMS_PortalController.placeSecondarySale';
import previewPrimaryOrder from '@salesforce/apex/DMS_PortalController.previewPrimaryOrder';

export default class DistributorOrderEntry extends LightningElement {
    @api mode = 'P1'; // 'P1' | 'Secondary'
    retailerId;
    retailerOptions = [];
    allProducts = [];
    products = [];
    schemeByProduct = {}; // product name -> scheme object (numeric benefit data)
    classById = {};       // product id -> { classification, minQty }
    // Server-authoritative per-line scheme result (product id -> { discount, tax,
    // net, freeQty }) from previewPrimaryOrder. Empty until the first preview
    // returns, so the UI shows a local estimate first and then the exact figures
    // the order will be saved with. Never blocks the screen if the call fails.
    serverLines = {};
    _previewTimer;        // debounce handle for the server preview
    _applyingPreview = false; // guard so applying a preview doesn't re-trigger one
    _seeded = false;      // must-sell products auto-added once
    removalReasons = [];  // reasons captured when a must-sell line is removed
    brand = 'all';
    category = 'all';
    search = '';
    brandOptions = [{ label: 'All Brands', value: 'all' }];
    categoryOptions = [{ label: 'All Categories', value: 'all' }];
    @track cart = [];
    submitting = false;
    submitError;
    error;
    cartOpen = false; // mobile bottom-sheet state
    // Remove-must-sell reason prompt
    removeTargetId;
    removeProductName = '';
    removeReason = '';
    removeError = '';

    get isSecondary() { return this.mode === 'Secondary'; }
    get headerTitle() { return this.isSecondary ? 'New Secondary Sale' : 'New Primary Order'; }
    get headerSub() { return this.isSecondary ? 'Bill a retailer from your stock' : 'Order stock from the company'; }
    get submitLabel() { return this.isSecondary ? 'Place Secondary Sale' : 'Place Primary Order'; }

    @wire(getRetailers)
    wiredRetailers({ data }) {
        if (data) { this.retailerOptions = data.map((r) => ({ label: r.Name, value: r.Id })); }
    }

    handleRetailer(e) { this.retailerId = e.detail.value; }

    @wire(getProductCatalog)
    wiredProducts({ data, error }) {
        if (data) {
            this.allProducts = data;
            const brands = [...new Set(data.map((r) => r.brand).filter(Boolean))].sort();
            const cats = [...new Set(data.map((r) => r.category).filter(Boolean))].sort();
            this.brandOptions = [{ label: 'All Brands', value: 'all' }, ...brands.map((b) => ({ label: b, value: b }))];
            this.categoryOptions = [{ label: 'All Categories', value: 'all' }, ...cats.map((c) => ({ label: c, value: c }))];
            this.maybeSeedMustSell();
            this.applyFilter();
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Unable to load products.';
        }
    }

    @wire(getProductClassifications)
    wiredClasses({ data }) {
        if (data) {
            const m = {};
            data.forEach((c) => { m[c.productId] = { classification: c.classification, minQty: Number(c.minQty || 0) }; });
            this.classById = m;
            this.maybeSeedMustSell();
            this.applyFilter();
        }
    }

    // Once both the catalog and classifications are loaded, auto-add every
    // Must-Sell product at its minimum quantity (primary orders only).
    maybeSeedMustSell() {
        if (this._seeded || this.isSecondary) { return; }
        if (!this.allProducts.length || !Object.keys(this.classById).length) { return; }
        this._seeded = true;
        Object.keys(this.classById).forEach((pid) => {
            const info = this.classById[pid];
            if (info.classification !== 'Must Sell') { return; }
            if (!this.allProducts.some((p) => p.id === pid)) { return; }
            if (this.cart.some((l) => l.id === pid)) { return; }
            this.addProduct(pid, true);
        });
    }

    @wire(getSchemes)
    wiredSchemes({ data }) {
        if (data && data.schemes) {
            const m = {};
            data.schemes.forEach((s) => {
                if (s.status === 'Active' || s.status === 'Expiring Soon') {
                    (s.products || []).forEach((p) => { if (!m[p]) { m[p] = s; } });
                }
            });
            this.schemeByProduct = m;
            this.applyFilter();
        }
    }

    handleBrand(e) { this.brand = e.detail.value; this.applyFilter(); }
    handleCategory(e) { this.category = e.detail.value; this.applyFilter(); }
    handleSearch(e) { this.search = (e.target.value || '').toLowerCase(); this.applyFilter(); }

    applyFilter() {
        const qtyById = {};
        this.cart.forEach((l) => { qtyById[l.id] = l.qty; });
        this.products = this.allProducts
            .filter((r) => {
                const okBrand = this.brand === 'all' || r.brand === this.brand;
                const okCat = this.category === 'all' || r.category === this.category;
                const okSearch =
                    !this.search ||
                    (r.name || '').toLowerCase().includes(this.search) ||
                    (r.sku || '').toLowerCase().includes(this.search) ||
                    (r.brand || '').toLowerCase().includes(this.search);
                return okBrand && okCat && okSearch;
            })
            .map((r) => {
                const scheme = this.schemeByProduct[r.name];
                const outOfStock = this.isSecondary && r.stockStatus === 'Out of Stock';
                const inCartQty = qtyById[r.id] || 0;
                const info = this.classById[r.id] || {};
                const cls = info.classification || '';
                const minQty = Number(info.minQty || 0);
                return {
                    ...r,
                    hasImage: !!r.imageUrl,
                    initials: (r.name || '?').trim().charAt(0).toUpperCase(),
                    classLabel: cls,
                    hasClass: !!cls,
                    classCss: 'oe-chip ' + (cls === 'Must Sell' ? 'oe-chip_must' : 'oe-chip_focus'),
                    minLabel: minQty > 0 ? `Min ${minQty} ${r.baseUomName || 'unit'}` : '',
                    hasMin: minQty > 0,
                    schemeLabel: scheme ? (scheme.benefitSummary || scheme.name) : '',
                    hasScheme: !!scheme,
                    priceFmt: r.unitPrice != null ? '₹' + this.fmt(r.unitPrice) : '—',
                    priceUnitLabel: '/ ' + (r.baseUomName || 'unit'),
                    mrpFmt: r.mrp != null ? '₹' + this.fmt(r.mrp) : '',
                    showMrp: r.mrp != null && r.unitPrice != null && Number(r.mrp) > Number(r.unitPrice),
                    showStock: this.isSecondary,
                    stockLabel: this.isSecondary ? `${r.onHand || 0} in stock` : '',
                    stockCss: 'oe-chip ' + (r.stockStatus === 'Out of Stock' ? 'oe-chip_red' : r.stockStatus === 'Low' ? 'oe-chip_amber' : 'oe-chip_green'),
                    inCart: inCartQty > 0,
                    cartQty: inCartQty,
                    addDisabled: outOfStock,
                    addLabel: outOfStock ? 'Out of stock' : 'Add'
                };
            });
    }

    tierPrice(tiers, qty) {
        let price = tiers && tiers.length ? tiers[0].unitPrice : 0;
        (tiers || []).forEach((t) => { if (qty >= t.minQty) { price = t.unitPrice; } });
        return Number(price || 0);
    }

    // Header-level scheme benefit: % / value discount and Buy-X-Get-Y free qty.
    computeScheme(scheme, baseQty, gross) {
        const out = { discount: 0, freeQty: 0 };
        if (!scheme) { return out; }
        const cat = scheme.category;
        const buyQty = Number(scheme.buyQty || 0);
        const minVal = Number(scheme.minValue || 0);
        const meetsQty = !buyQty || baseQty >= buyQty;
        const meetsVal = !minVal || gross >= minVal;
        if (cat === 'Discount in %' && scheme.discountPercent && meetsQty && meetsVal) {
            out.discount = gross * Number(scheme.discountPercent) / 100;
        } else if (cat === 'Discount in Value' && scheme.discountValue && meetsQty && meetsVal) {
            out.discount = Math.min(Number(scheme.discountValue), gross);
        } else if (cat === 'Free Products' && scheme.freeQty && buyQty && baseQty >= buyQty) {
            out.freeQty = Math.floor(baseQty / buyQty) * Number(scheme.freeQty);
        }
        out.discount = Math.round(out.discount * 100) / 100;
        return out;
    }

    get count() { return this.products.length; }


    // Add a product to the cart (creates the line if needed). When seedToMin is
    // true (must-sell auto-add), the starting qty is the smallest ordering-UOM
    // quantity that meets the base-unit minimum.
    addProduct(id, seedToMin) {
        const p = this.allProducts.find((x) => x.id === id);
        if (!p) { return; }
        const tiers = (p.priceTiers && p.priceTiers.length) ? p.priceTiers : [{ minQty: 1, unitPrice: Number(p.unitPrice || 0) }];
        const existing = this.cart.find((l) => l.id === id);
        if (existing) {
            existing.qty += 1;
        } else {
            const unitsPerCase = Number(p.unitsPerCase || 0);
            const inCases = unitsPerCase > 1;
            const cf = inCases ? unitsPerCase : 1;    // base units per ordering UOM
            const info = this.classById[p.id] || {};
            const isMustSell = !this.isSecondary && info.classification === 'Must Sell';
            // Minimum is defined in BASE units (pieces).
            const minQtyBase = Math.max(isMustSell ? 1 : 0, Number(info.minQty || 0));
            const startQty = (seedToMin && minQtyBase > 0) ? Math.max(1, Math.ceil(minQtyBase / cf)) : 1;
            this.cart = [
                ...this.cart,
                {
                    id: p.id,
                    name: p.name,
                    sku: p.sku,
                    imageUrl: p.imageUrl,
                    initials: (p.name || '?').trim().charAt(0).toUpperCase(),
                    tiers,
                    unitsPerCase,
                    baseUomName: p.baseUomName || 'Piece',
                    caseUomName: p.caseUomName || 'Case',
                    gstRate: Number(p.gstRate || 0),
                    scheme: this.schemeByProduct[p.name] || null,
                    onHand: Number(p.onHand || 0),
                    classification: info.classification || '',
                    isMustSell,
                    minQtyBase, // in base units
                    // Order in cases whenever the product has a case pack; no toggle.
                    uom: inCases ? 'Cases' : 'Pieces',
                    qty: startQty
                }
            ];
        }
        this.recompute();
    }

    addToCart(e) { this.addProduct(e.currentTarget.dataset.id); }

    incItem(e) { this.addProduct(e.currentTarget.dataset.id); }

    decItem(e) {
        const id = e.currentTarget.dataset.id;
        const line = this.cart.find((l) => l.id === id);
        if (!line) { return; }
        const upc = Number(line.unitsPerCase || 0);
        const cf = (line.uom === 'Cases' && upc > 1) ? upc : 1;
        // Smallest ordering-UOM qty that still meets the base-unit minimum.
        const floor = line.isMustSell ? Math.max(1, Math.ceil((line.minQtyBase || 1) / cf)) : 1;
        if (line.qty <= floor) {
            // Must-sell can't be stepped below its minimum — remove needs a reason.
            if (line.isMustSell) { this.promptRemove(line); return; }
            this.cart = this.cart.filter((l) => l.id !== id);
        } else {
            line.qty -= 1;
        }
        this.recompute();
    }

    handleQty(e) {
        const id = e.currentTarget.dataset.id;
        const qty = Math.max(1, Math.floor(Number(e.detail.value) || 1));
        const line = this.cart.find((l) => l.id === id);
        if (line) { line.qty = qty; this.recompute(); }
    }

    removeLine(e) {
        const id = e.currentTarget.dataset.id;
        const line = this.cart.find((l) => l.id === id);
        if (line && line.isMustSell) { this.promptRemove(line); return; }
        this.cart = this.cart.filter((l) => l.id !== id);
        this.recompute();
    }

    // ── Remove-must-sell reason prompt ──
    promptRemove(line) {
        this.removeTargetId = line.id;
        this.removeProductName = line.name;
        this.removeReason = '';
        this.removeError = '';
    }
    get showRemovePrompt() { return !!this.removeTargetId; }
    handleReason(e) { this.removeReason = e.target.value; this.removeError = ''; }
    cancelRemove() { this.removeTargetId = undefined; this.removeReason = ''; this.removeError = ''; }
    confirmRemove() {
        const reason = (this.removeReason || '').trim();
        if (!reason) { this.removeError = 'Please enter a reason to remove this must-sell product.'; return; }
        const line = this.cart.find((l) => l.id === this.removeTargetId);
        if (line) { this.removalReasons.push(`Removed must-sell "${line.name}": ${reason}`); }
        this.cart = this.cart.filter((l) => l.id !== this.removeTargetId);
        this.removeTargetId = undefined;
        this.removeReason = '';
        this.recompute();
    }

    clearCart() { this.cart = []; this.removalReasons = []; this.recompute(); }

    recompute() {
        this.cart = this.cart.map((l) => {
            const upc = Number(l.unitsPerCase || 0);
            const inCases = l.uom === 'Cases' && upc > 1;
            const cf = inCases ? upc : 1;            // base units per selected UOM
            const baseQty = l.qty * cf;              // always in base units
            const basePrice = this.tierPrice(l.tiers, baseQty); // price per base unit
            const effUnit = basePrice * cf;          // price per selected UOM (per case when in cases)
            const gross = baseQty * basePrice;
            // Prefer the server-authoritative scheme result (same engine the SFA
            // order-entry uses); until it arrives, fall back to a local estimate.
            // Secondary sales don't run the primary scheme preview.
            const sv = (!this.isSecondary && this.serverLines) ? this.serverLines[l.id] : null;
            const sc = sv || this.computeScheme(l.scheme, baseQty, gross);
            const discount = sv ? sv.discount : sc.discount;
            const freeQty = sv ? sv.freeQty : sc.freeQty; // in base units
            const taxable = gross - discount;
            const tax = sv ? sv.tax : (taxable * l.gstRate) / 100;
            const net = sv ? sv.net : taxable + tax;
            const overStock = this.isSecondary && baseQty > l.onHand;
            // Min is in base units; compare against the converted base quantity.
            const belowMin = l.isMustSell && baseQty < (l.minQtyBase || 0);
            const schemeLabel = l.scheme ? (l.scheme.benefitSummary || l.scheme.name) : '';
            const baseName = l.baseUomName || 'Piece';
            const caseName = l.caseUomName || 'Case';
            return {
                ...l,
                conversionFactor: cf,
                baseQty,
                effUnit,
                gross,
                discount,
                freeQty,
                taxable,
                tax,
                net,
                overStock,
                belowMin,
                classBadgeCss: l.isMustSell ? 'oe-tag oe-tag_must' : (l.classification === 'Focused Sell' ? 'oe-tag oe-tag_focus' : ''),
                minQtyLabel: (l.minQtyBase > 0) ? `Min ${this.fmt0(l.minQtyBase)} ${baseName}` : '',
                minWarn: belowMin ? `Must-sell minimum ${this.fmt0(l.minQtyBase)} ${baseName} — you have ${this.fmt0(baseQty)} ${baseName}` : '',
                stockWarn: overStock ? `Only ${l.onHand} in stock` : '',
                lineCss: (overStock || belowMin) ? 'oe-line oe-line_warn' : 'oe-line',
                // Static ordering unit (no selector).
                uomLabel: inCases ? caseName : baseName,
                // Price for the ordering UOM (per case when in cases).
                unitPriceFmt: '₹' + this.fmt(effUnit) + ' / ' + (inCases ? caseName : baseName),
                // Always show the per-base-unit price so it's explicit.
                showPerUnit: inCases,
                perUnitFmt: '₹' + this.fmt(basePrice) + ' / ' + baseName,
                // "2 Cases = 72 Pieces" so pieces-per-order is clear.
                baseQtyLabel: inCases ? `${this.fmt0(l.qty)} ${caseName} = ${this.fmt0(baseQty)} ${baseName}` : '',
                schemeLabel,
                discountFmt: discount > 0 ? '−₹' + this.fmt(discount) : '',
                freeLabel: freeQty > 0 ? `+${this.fmt0(freeQty)} ${baseName} free` : '',
                lineTotalFmt: '₹' + this.fmt(net)
            };
        });
        this.applyFilter();
        // A user-driven change refreshes the authoritative preview; the recompute
        // triggered by applying a preview result must not schedule another one.
        if (!this._applyingPreview) { this.scheduleServerPreview(); }
    }

    // Debounced authoritative preview: prices + applies schemes server-side with
    // the exact logic used at placement, so the on-screen summary equals the
    // order that gets saved. Primary orders only; secondary billing is FEFO.
    scheduleServerPreview() {
        if (this.isSecondary) { return; }
        clearTimeout(this._previewTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._previewTimer = setTimeout(() => { this.refreshServerPreview(); }, 350);
    }

    async refreshServerPreview() {
        if (this.isSecondary) { return; }
        if (!this.cart.length) {
            if (Object.keys(this.serverLines).length) { this.applyServerLines({}); }
            return;
        }
        const lines = this.cart.map((l) => ({
            productId: l.id,
            quantity: l.qty,
            uom: l.uom,
            conversionFactor: (l.uom === 'Cases' && Number(l.unitsPerCase || 0) > 1) ? Number(l.unitsPerCase) : 1
        }));
        try {
            const pv = await previewPrimaryOrder({ linesJson: JSON.stringify(lines) });
            const m = {};
            if (pv && pv.ok && pv.lines) {
                pv.lines.forEach((pl) => {
                    m[pl.productId] = {
                        discount: Number(pl.discount || 0),
                        tax: Number(pl.tax || 0),
                        net: Number(pl.net || 0),
                        freeQty: Number(pl.freeQty || 0)
                    };
                });
            }
            this.applyServerLines(m);
        } catch (e) {
            // Preview failed — keep the local estimate, never break the screen.
            this.applyServerLines({});
        }
    }

    applyServerLines(map) {
        this.serverLines = map;
        this._applyingPreview = true;
        this.recompute();
        this._applyingPreview = false;
    }

    isSalesforceId(v) { return typeof v === 'string' && /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/.test(v); }
    fmt(v) { return Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
    fmt0(v) { return Number(v || 0).toLocaleString('en-IN', { maximumFractionDigits: 0 }); }

    get hasOverStock() { return this.cart.some((l) => l.overStock); }
    get hasBelowMin() { return this.cart.some((l) => l.belowMin); }
    get hasCart() { return this.cart.length > 0; }
    get itemCount() { return this.cart.length; }

    get gross() { return this.cart.reduce((s, l) => s + (l.gross || 0), 0); }
    get totalDiscount() { return this.cart.reduce((s, l) => s + (l.discount || 0), 0); }
    get taxable() { return this.gross - this.totalDiscount; }
    get tax() { return this.cart.reduce((s, l) => s + (l.tax || 0), 0); }
    get net() { return this.taxable + this.tax; }
    get totalFree() { return this.cart.reduce((s, l) => s + (l.freeQty || 0), 0); }

    get grossFmt() { return '₹' + this.fmt(this.gross); }
    get discountFmt() { return '−₹' + this.fmt(this.totalDiscount); }
    get taxableFmt() { return '₹' + this.fmt(this.taxable); }
    get taxFmt() { return '₹' + this.fmt(this.tax); }
    get netFmt() { return '₹' + this.fmt(this.net); }
    get netFmt0() { return '₹' + this.fmt0(this.net); }
    get hasDiscount() { return this.totalDiscount > 0; }
    get hasFree() { return this.totalFree > 0; }
    get freeFmt() { return `${this.totalFree} free unit${this.totalFree === 1 ? '' : 's'}`; }
    get cartCountLabel() { return `${this.itemCount} item${this.itemCount === 1 ? '' : 's'}`; }
    get barLabel() { return `${this.itemCount} item${this.itemCount === 1 ? '' : 's'} · ${this.netFmt0}`; }

    // Mobile bottom-sheet open/close
    openCart() { this.cartOpen = true; }
    closeCart() { this.cartOpen = false; }
    get cartClass() { return this.cartOpen ? 'oe-cart is-open' : 'oe-cart'; }
    get scrimClass() { return this.cartOpen ? 'oe-scrim is-open' : 'oe-scrim'; }

    get isSubmitDisabled() {
        if (this.cart.length === 0 || this.submitting) { return true; }
        if (this.hasBelowMin) { return true; }
        if (this.isSecondary && (!this.retailerId || this.hasOverStock)) { return true; }
        return false;
    }

    async submit() {
        if (this.hasBelowMin) {
            const bad = this.cart.filter((l) => l.belowMin).map((l) => l.name).join(', ');
            this.submitError = `Must-sell products below minimum quantity: ${bad}. Increase the quantity or remove them with a reason.`;
            return;
        }
        this.submitting = true;
        this.submitError = undefined;
        // Primary: send qty in the selected UOM + conversion + scheme/discount.
        // Secondary: bill from stock in base (piece) units, so send base qty.
        const lines = this.cart.map((l) => (this.isSecondary
            ? { productId: l.id, quantity: l.baseQty }
            : {
                productId: l.id,
                quantity: l.qty,
                uom: l.uom,
                conversionFactor: l.conversionFactor,
                schemeId: (l.scheme && this.isSalesforceId(l.scheme.id)) ? l.scheme.id : null,
                schemeName: l.scheme ? l.scheme.name : null,
                discountAmount: l.discount,
                freeQty: l.freeQty
            }));
        if (lines.some((x) => !x.productId)) {
            this.submitError = 'One or more products could not be identified. Remove and re-add them, then try again.';
            this.submitting = false;
            return;
        }
        const linesJson = JSON.stringify(lines);
        const note = this.removalReasons.length ? this.removalReasons.join('\n') : null;
        try {
            const orderId = this.isSecondary
                ? await placeSecondarySale({ retailerId: this.retailerId, linesJson })
                : await placeIndent({ linesJson, note });
            this.dispatchEvent(new ShowToastEvent({
                title: this.isSecondary ? 'Sale placed' : 'Order placed',
                message: this.isSecondary
                    ? 'Secondary invoice created from your stock (FEFO).'
                    : 'Your primary order (indent) was created as Draft.',
                variant: 'success'
            }));
            this.cart = [];
            this.removalReasons = [];
            this.retailerId = undefined;
            this.cartOpen = false;
            this.recompute();
            this.dispatchEvent(new CustomEvent('orderplaced', { detail: { orderId } }));
        } catch (e) {
            this.submitError = (e && e.body && e.body.message) || 'Unexpected error placing the order.';
            this.dispatchEvent(new ShowToastEvent({
                title: this.isSecondary ? 'Could not place sale' : 'Could not place order',
                message: this.submitError, variant: 'error'
            }));
        } finally {
            this.submitting = false;
        }
    }
}