import { LightningElement, wire } from 'lwc';
import getOverview from '@salesforce/apex/INV_StockManagementController.getOverview';

const TABS = [
    { id: 'overview', label: 'Overview' },
    { id: 'adjustments', label: 'Adjustments' },
    { id: 'transfers', label: 'Transfers' }
];

export default class StockManagement extends LightningElement {
    data;
    error;
    active = 'overview';

    // The adjustment and transfer screens were fully built but unreachable — no tab, no
    // flexipage. The org is at its custom-tab limit, so rather than burn a tab each they are
    // mounted here as sub-tabs: one Stock Management area, three screens.
    get tabs() {
        return TABS.map((t) => ({
            ...t,
            css: t.id === this.active ? 'sm-tab sm-tab_active' : 'sm-tab'
        }));
    }
    get isOverview() { return this.active === 'overview'; }
    get isAdjustments() { return this.active === 'adjustments'; }
    get isTransfers() { return this.active === 'transfers'; }
    selectTab(e) { this.active = e.currentTarget.dataset.id; }

    @wire(getOverview)
    wiredOverview({ data, error }) {
        if (data) {
            this.data = this.decorate(data);
            this.error = undefined;
        } else if (error) {
            this.error = (error.body && error.body.message) || 'Unable to load stock overview.';
        }
    }

    decorate(d) {
        return {
            ...d,
            warehouseUnitsFmt: this.num(d.warehouseUnits),
            warehouseValueFmt: this.money(d.warehouseValue),
            distributorUnitsFmt: this.num(d.distributorUnits),
            distributorValueFmt: this.money(d.distributorValue),
            inTransitUnitsFmt: this.num(d.inTransitUnits),
            warehouses: (d.warehouses || []).map((r) => ({
                ...r, key: r.name, unitsFmt: this.num(r.units), valueFmt: this.money(r.value)
            })),
            distributors: (d.distributors || []).map((r) => ({
                ...r, key: r.name, unitsFmt: this.num(r.units), valueFmt: this.money(r.value)
            })),
            inTransit: (d.inTransit || []).map((r) => ({
                ...r, key: r.id, unitsFmt: this.num(r.units)
            })),
            alerts: (d.alerts || []).map((r, i) => ({
                ...r,
                key: i,
                qtyFmt: this.num(r.quantity),
                pillClass: r.kind === 'Near Expiry' ? 'sm-pill sm-pill_amber' : 'sm-pill sm-pill_red'
            })),
            movements: (d.movements || []).map((m) => ({
                ...m,
                key: m.id,
                qtyFmt: this.num(m.quantity),
                dirClass: m.direction === 'In' ? 'sm-dir sm-dir_in' : 'sm-dir sm-dir_out',
                dirLabel: m.direction === 'In' ? '▲ In' : '▼ Out'
            }))
        };
    }

    get hasWarehouses() { return this.data && this.data.warehouses.length > 0; }
    get hasDistributors() { return this.data && this.data.distributors.length > 0; }
    get hasTransit() { return this.data && this.data.inTransit.length > 0; }
    get hasAlerts() { return this.data && this.data.alerts.length > 0; }
    get hasMovements() { return this.data && this.data.movements.length > 0; }

    num(v) {
        return Number(v || 0).toLocaleString('en-IN');
    }
    money(v) {
        v = Number(v || 0);
        if (v >= 10000000) return '₹' + (v / 10000000).toFixed(2) + ' Cr';
        if (v >= 100000) return '₹' + (v / 100000).toFixed(2) + ' L';
        if (v >= 1000) return '₹' + (v / 1000).toFixed(1) + 'K';
        return '₹' + Math.round(v);
    }
}