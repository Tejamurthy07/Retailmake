import { LightningElement, wire, track } from 'lwc';
import getCoverage from '@salesforce/apex/RangeSellingController.getCoverage';

export default class RangeSellingSubBrand extends LightningElement {
    @track rows = [];
    @track error;
    loading = true;

    @wire(getCoverage, { groupBy: 'Sub-Brand' })
    wiredCoverage({ data, error }) {
        this.loading = false;
        if (data) {
            this.rows = data.map(r => ({
                ...r,
                barStyle: `width: ${r.pct}%;`,
                display: `${r.covered} / ${r.total}`,
                pctLabel: `${r.pct}%`
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error.body ? error.body.message : JSON.stringify(error);
            this.rows = [];
        }
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get noData() {
        return !this.loading && !this.error && (!this.rows || this.rows.length === 0);
    }
}