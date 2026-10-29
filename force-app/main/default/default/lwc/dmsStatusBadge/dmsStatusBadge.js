import { LightningElement, api } from 'lwc';

/**
 * Colored status pill. Maps a free-text status to a semantic color theme.
 * Reused across Orders, Invoices and Products.
 */
const THEME_MAP = {
    // success / positive
    paid: 'success',
    delivered: 'success',
    confirmed: 'success',
    approved: 'success',
    'in stock': 'success',
    // warning
    pending: 'warning',
    shipped: 'warning',
    'low stock': 'warning',
    // danger
    overdue: 'danger',
    cancelled: 'danger',
    rejected: 'danger',
    'no sales': 'danger',
    'out of stock': 'danger'
};

export default class DmsStatusBadge extends LightningElement {
    @api label;
    @api status;
    /** Optional explicit theme (success|warning|danger|info|neutral) that
     *  overrides the auto-mapping — used where the same word needs a
     *  different color by context (e.g. collection "Pending" = danger). */
    @api theme;

    get resolvedTheme() {
        return this.theme || THEME_MAP[(this.status || this.label || '').toLowerCase()] || 'neutral';
    }

    get badgeClass() {
        return `dms-badge dms-badge_${this.resolvedTheme}`;
    }

    get displayText() {
        return this.label || this.status;
    }
}