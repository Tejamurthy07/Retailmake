import { LightningElement, wire } from 'lwc';
import getPortalConfig from '@salesforce/apex/DMS_PortalController.getPortalConfig';

export default class DistributorPortal extends LightningElement {
    active;
    navTabs = [];

    @wire(getPortalConfig)
    wiredConfig({ data }) {
        if (data && data.tabs) {
            this.navTabs = data.tabs;
            if (!this.active && this.navTabs.length) {
                this.active = this.navTabs[0].key;
            }
        }
    }

    get tabs() {
        return this.navTabs.map((t) => ({
            ...t,
            css: 'nav-item' + (t.key === this.active ? ' nav-item_active' : '')
        }));
    }

    select(e) {
        this.active = e.currentTarget.dataset.name;
    }

    get isHome() { return this.active === 'home'; }
    get isProducts() { return this.active === 'products'; }
    get isOrders() { return this.active === 'orders'; }
    get isInvoices() { return this.active === 'invoices'; }
    get isGrn() { return this.active === 'grn'; }
    get isInventory() { return this.active === 'inventory'; }
    get isLedger() { return this.active === 'ledger'; }
    get isCollection() { return this.active === 'collection'; }
    get isReturns() { return this.active === 'returns'; }
    get isClaims() { return this.active === 'claims'; }
    get isCustomers() { return this.active === 'customers'; }
    get isSupport() { return this.active === 'support'; }
}