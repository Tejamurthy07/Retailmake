import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getProducts from '@salesforce/apex/MDM_ProductCatalogController.getProducts';
import getCategoryTree from '@salesforce/apex/MDM_ProductCatalogController.getCategoryTree';
import getProductDetail from '@salesforce/apex/MDM_ProductCatalogController.getProductDetail';

const PAGE_SIZE = 20;
const SEARCH_DEBOUNCE_MS = 300;

export default class ProductCatalog extends LightningElement {
    // ── Search & Filter State ─────────────────────────────────────────────
    searchTerm = '';
    activeOnly = true;
    selectedCategoryId = null;
    selectedCategoryName = '';

    // ── Pagination State ──────────────────────────────────────────────────
    currentPage = 1;
    totalCount = 0;
    pageSize = PAGE_SIZE;

    // ── Product Data ──────────────────────────────────────────────────────
    @track products = [];
    isLoading = true;

    // ── Category Tree ─────────────────────────────────────────────────────
    @track treeItems = [];
    categoryTreeLoading = true;

    // ── Product Detail ────────────────────────────────────────────────────
    selectedProductId = null;
    @track productDetail = null;
    isDetailLoading = false;

    // ── Debounce ──────────────────────────────────────────────────────────
    _searchTimeout;

    // ── Lifecycle ─────────────────────────────────────────────────────────

    connectedCallback() {
        this.loadProducts();
    }

    // ── Wire: Category Tree ───────────────────────────────────────────────

    @wire(getCategoryTree)
    wiredCategoryTree({ error, data }) {
        this.categoryTreeLoading = false;
        if (data) {
            this.treeItems = this.buildTreeItems(data);
        } else if (error) {
            this.treeItems = [];
            this.showToast('Error', this.reduceErrors(error), 'error');
        }
    }

    /**
     * Recursively converts CategoryNode list into lightning-tree items format.
     */
    buildTreeItems(nodes) {
        if (!nodes || nodes.length === 0) {
            return [];
        }
        return nodes.map(node => {
            const item = {
                label: node.name,
                name: node.id,
                expanded: false,
                items: []
            };
            if (node.children && node.children.length > 0) {
                item.items = this.buildTreeItems(node.children);
            }
            return item;
        });
    }

    // ── Imperative: Load Products ─────────────────────────────────────────

    loadProducts() {
        this.isLoading = true;
        const offset = (this.currentPage - 1) * this.pageSize;

        getProducts({
            searchTerm: this.searchTerm || null,
            categoryId: this.selectedCategoryId || null,
            isActiveOnly: this.activeOnly,
            limitCount: this.pageSize,
            offset: offset
        })
            .then(result => {
                this.totalCount = result.totalCount;
                this.products = result.products.map(p => ({
                    ...p,
                    cardClass: this.selectedProductId === p.productId
                        ? 'slds-box slds-theme_default product-card product-card-selected'
                        : 'slds-box slds-theme_default product-card'
                }));
                this.isLoading = false;
            })
            .catch(error => {
                this.products = [];
                this.totalCount = 0;
                this.isLoading = false;
                this.showToast('Error', this.reduceErrors(error), 'error');
            });
    }

    // ── Imperative: Load Product Detail ───────────────────────────────────

    loadProductDetail(productId) {
        this.isDetailLoading = true;
        getProductDetail({ productId: productId })
            .then(result => {
                const detail = { ...result };
                if (detail.priceLists) {
                    detail.priceLists = detail.priceLists.map(p => ({
                        ...p,
                        customerName: p.Customer__r ? p.Customer__r.Name : '',
                        territoryName: p.Territory__r ? p.Territory__r.Name : ''
                    }));
                }
                this.productDetail = detail;
                this.isDetailLoading = false;
            })
            .catch(error => {
                this.productDetail = null;
                this.isDetailLoading = false;
                this.showToast('Error', this.reduceErrors(error), 'error');
            });
    }

    // ── Event Handlers ────────────────────────────────────────────────────

    handleSearchChange(event) {
        const value = event.target.value;
        clearTimeout(this._searchTimeout);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._searchTimeout = setTimeout(() => {
            this.searchTerm = value;
            this.currentPage = 1;
            this.selectedProductId = null;
            this.productDetail = null;
            this.loadProducts();
        }, SEARCH_DEBOUNCE_MS);
    }

    handleActiveToggle(event) {
        this.activeOnly = event.target.checked;
        this.currentPage = 1;
        this.selectedProductId = null;
        this.productDetail = null;
        this.loadProducts();
    }

    handleCategorySelect(event) {
        const selectedName = event.detail.name;
        if (selectedName === this.selectedCategoryId) {
            // Deselect if clicking the same category
            this.selectedCategoryId = null;
            this.selectedCategoryName = '';
        } else {
            this.selectedCategoryId = selectedName;
            this.selectedCategoryName = event.detail.label || this.findCategoryLabel(selectedName, this.treeItems);
        }
        this.currentPage = 1;
        this.selectedProductId = null;
        this.productDetail = null;
        this.loadProducts();
    }

    handleClearCategory() {
        this.selectedCategoryId = null;
        this.selectedCategoryName = '';
        this.currentPage = 1;
        this.selectedProductId = null;
        this.productDetail = null;
        this.loadProducts();
    }

    handleProductClick(event) {
        const productId = event.currentTarget.dataset.productId;
        if (this.selectedProductId === productId) {
            // Deselect if clicking the same product
            this.selectedProductId = null;
            this.productDetail = null;
        } else {
            this.selectedProductId = productId;
            this.loadProductDetail(productId);
        }
        // Update card selection styling
        this.products = this.products.map(p => ({
            ...p,
            cardClass: this.selectedProductId === p.productId
                ? 'slds-box slds-theme_default product-card product-card-selected'
                : 'slds-box slds-theme_default product-card'
        }));
    }

    handleCloseDetail() {
        this.selectedProductId = null;
        this.productDetail = null;
        this.products = this.products.map(p => ({
            ...p,
            cardClass: 'slds-box slds-theme_default product-card'
        }));
    }

    // ── Pagination Handlers ───────────────────────────────────────────────

    handlePreviousPage() {
        if (this.currentPage > 1) {
            this.currentPage--;
            this.selectedProductId = null;
            this.productDetail = null;
            this.loadProducts();
        }
    }

    handleNextPage() {
        if (this.currentPage < this.totalPages) {
            this.currentPage++;
            this.selectedProductId = null;
            this.productDetail = null;
            this.loadProducts();
        }
    }

    handlePageClick(event) {
        const pageNum = parseInt(event.currentTarget.dataset.page, 10);
        if (pageNum !== this.currentPage) {
            this.currentPage = pageNum;
            this.selectedProductId = null;
            this.productDetail = null;
            this.loadProducts();
        }
    }

    // ── Computed Properties ───────────────────────────────────────────────

    get hasCategoryTree() {
        return this.treeItems && this.treeItems.length > 0;
    }

    get hasProducts() {
        return this.products && this.products.length > 0;
    }

    get hasPriceLists() {
        return (
            this.productDetail &&
            this.productDetail.priceLists &&
            this.productDetail.priceLists.length > 0
        );
    }

    get totalPages() {
        return Math.ceil(this.totalCount / this.pageSize) || 1;
    }

    get isPreviousDisabled() {
        return this.currentPage <= 1;
    }

    get isNextDisabled() {
        return this.currentPage >= this.totalPages;
    }

    get displayRangeStart() {
        return this.totalCount === 0 ? 0 : (this.currentPage - 1) * this.pageSize + 1;
    }

    get displayRangeEnd() {
        const end = this.currentPage * this.pageSize;
        return end > this.totalCount ? this.totalCount : end;
    }

    get pageNumbers() {
        const pages = [];
        const total = this.totalPages;
        const current = this.currentPage;

        // Show up to 7 page buttons with ellipsis logic
        let start = 1;
        let end = total;

        if (total > 7) {
            if (current <= 4) {
                end = 7;
            } else if (current >= total - 3) {
                start = total - 6;
            } else {
                start = current - 3;
                end = current + 3;
            }
        }

        for (let i = start; i <= end; i++) {
            pages.push({
                number: i,
                variant: i === current ? 'brand' : 'neutral'
            });
        }

        return pages;
    }

    // ── Helper Methods ────────────────────────────────────────────────────

    /**
     * Recursively find a category label in the tree items by its name (id).
     */
    findCategoryLabel(id, items) {
        if (!items) return '';
        for (const item of items) {
            if (item.name === id) {
                return item.label;
            }
            if (item.items && item.items.length > 0) {
                const found = this.findCategoryLabel(id, item.items);
                if (found) return found;
            }
        }
        return '';
    }

    /**
     * Reduces wire/imperative errors to a display string.
     */
    reduceErrors(error) {
        if (!error) return 'Unknown error';

        if (typeof error === 'string') return error;

        if (error.body) {
            if (typeof error.body.message === 'string') return error.body.message;
            if (error.body.fieldErrors) {
                return Object.values(error.body.fieldErrors)
                    .flat()
                    .map(e => e.message)
                    .join(', ');
            }
            if (error.body.pageErrors) {
                return error.body.pageErrors.map(e => e.message).join(', ');
            }
        }

        if (error.message) return error.message;

        if (Array.isArray(error)) {
            return error.map(e => this.reduceErrors(e)).join(', ');
        }

        return JSON.stringify(error);
    }

    /**
     * Dispatches a toast notification.
     */
    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}