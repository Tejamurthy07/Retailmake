import { LightningElement, api } from 'lwc';

/** Pie chart rendered with a CSS conic-gradient + a legend. */
const PALETTE = [
    'rgba(30,42,120,1)',
    'rgba(37,99,235,1)',
    'rgba(59,130,246,1)',
    'rgba(96,165,250,1)',
    'rgba(147,197,253,1)',
    'rgba(191,219,254,1)'
];

export default class DmsPieChart extends LightningElement {
    @api title;

    _items = [];
    @api
    get items() {
        return this._items;
    }
    set items(value) {
        this._items = value || [];
    }

    get total() {
        return this._items.reduce((sum, i) => sum + i.value, 0) || 1;
    }

    get pieStyle() {
        let start = 0;
        const stops = this._items.map((item, index) => {
            const color = PALETTE[index % PALETTE.length];
            const end = start + (item.value / this.total) * 100;
            const stop = `${color} ${start.toFixed(2)}% ${end.toFixed(2)}%`;
            start = end;
            return stop;
        });
        return `background: conic-gradient(${stops.join(',')});`;
    }

    get legend() {
        return this._items.map((item, index) => ({
            key: item.label,
            label: item.label,
            dotStyle: `background-color:${PALETTE[index % PALETTE.length]};`
        }));
    }
}