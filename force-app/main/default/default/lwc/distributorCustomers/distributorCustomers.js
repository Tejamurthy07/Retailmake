import { LightningElement, wire } from 'lwc';
import getCustomers from '@salesforce/apex/DMS_PortalController.getCustomers';

export default class DistributorCustomers extends LightningElement {
    allRows = [];
    search = '';
    error;

    @wire(getCustomers)
    wired({ data, error }) {
        if (data) {
            this.allRows = data.map((r, i) => ({
                ...r, key: i,
                statusLabel: r.active ? 'Active' : 'No Orders',
                statusTheme: r.active ? 'success' : 'neutral'
            }));
            this.error = undefined;
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Unable to load customers.';
        }
    }

    handleSearch(e) { this.search = (e.target.value || '').toLowerCase(); }

    get rows() {
        return this.allRows.filter((r) => !this.search
            || (r.name || '').toLowerCase().includes(this.search)
            || (r.city || '').toLowerCase().includes(this.search));
    }
    get hasRows() { return this.rows.length > 0; }

    get cards() {
        const active = this.allRows.filter((r) => r.active).length;
        const dues = this.allRows.filter((r) => Number(r.outstanding) > 0).length;
        return [
            { id: 't', label: 'Total Customers', value: this.allRows.length, cls: 'dms-card__value' },
            { id: 'a', label: 'Active', value: active, cls: 'dms-card__value dms-card__value_green' },
            { id: 'd', label: 'With Dues', value: dues, cls: 'dms-card__value dms-card__value_amber' }
        ];
    }
}