import { LightningElement, api } from 'lwc';

/** Vertical (column) bar chart — pure CSS, no charting library. */
const SCHEMES = {
    blue: [30, 42, 120],
    green: [15, 122, 77],
    purple: [91, 33, 182]
};

export default class DmsColumnChart extends LightningElement {
    @api title;
    @api max = 100;
    @api scheme = 'blue';
    @api ticks = []; // y-axis labels, top -> bottom

    _items = [];
    @api
    get items() {
        return this._items;
    }
    set items(value) {
        this._items = value || [];
    }

    get columns() {
        const base = SCHEMES[this.scheme] || SCHEMES.blue;
        const count = this._items.length;
        const max = this.max || 1;
        return this._items.map((item, index) => {
            const alpha = count > 1 ? Math.max(0.3, 1 - index * (0.7 / (count - 1))) : 1;
            const height = Math.min(100, Math.round((item.value / max) * 100));
            return {
                key: item.label,
                label: item.label,
                style: `height:${height}%;background-color:rgba(${base[0]},${base[1]},${base[2]},${alpha});`
            };
        });
    }
}