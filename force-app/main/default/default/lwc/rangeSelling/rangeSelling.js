import { LightningElement, wire, track } from 'lwc';
import getCoverage from '@salesforce/apex/RangeSellingController.getCoverage';

export default class RangeSelling extends LightningElement {
    @track selected = 'Brand';
    @track rows = [];
    @track error;
    loading = true;

    tabs = ['Brand', 'Sub-Brand', 'SKU'];

    get tabButtons() {
        return this.tabs.map(t => ({
            label: t,
            variant: t === this.selected ? 'brand' : 'neutral'
        }));
    }

    @wire(getCoverage, { groupBy: '$selected' })
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

    handleTab(event) {
        this.loading = true;
        this.selected = event.target.dataset.tab;
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get noData() {
        return !this.loading && !this.error && (!this.rows || this.rows.length === 0);
    }
}