import { LightningElement, api } from 'lwc';

/**
 * KPI tile: label + large value. `variant` colors the value
 * (default | accent | warning | danger).
 */
export default class DmsKpiCard extends LightningElement {
    @api label;
    @api value;
    @api variant = 'default';

    get valueClass() {
        return `dms-kpi__value dms-kpi__value_${this.variant}`;
    }
}