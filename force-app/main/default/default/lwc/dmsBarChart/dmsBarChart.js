import { LightningElement, api } from 'lwc';

/**
 * Lightweight horizontal bar chart (no external charting library).
 * Bars get progressively lighter top-to-bottom within the chosen color scheme.
 */
const SCHEMES = {
    blue: [30, 42, 120],
    green: [15, 122, 77],
    purple: [91, 33, 182]
};

export default class DmsBarChart extends LightningElement {
    @api title;
    @api max = 100;
    @api scheme = 'blue';
    @api ticks = [];

    _items = [];
    @api
    get items() {
        return this._items;
    }
    set items(value) {
        this._items = value || [];
    }

    get bars() {
        const base = SCHEMES[this.scheme] || SCHEMES.blue;
        const count = this._items.length;
        const max = this.max || 1;
        return this._items.map((item, index) => {
            const alpha = count > 1 ? Math.max(0.28, 1 - index * (0.72 / (count - 1))) : 1;
            const width = Math.min(100, Math.round((item.value / max) * 100));
            return {
                key: item.label,
                label: item.label,
                display: item.display,
                style: `width:${width}%;background-color:rgba(${base[0]},${base[1]},${base[2]},${alpha});`
            };
        });
    }
}