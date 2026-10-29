import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getTierOrders from '@salesforce/apex/DMS_PortalController.getTierOrders';
import getSecondaryOrders from '@salesforce/apex/DMS_PortalController.getSecondaryOrders';
import getSalesOrderLines from '@salesforce/apex/DMS_PortalController.getSalesOrderLines';
import getPrimaryOrderLines from '@salesforce/apex/DMS_PortalController.getPrimaryOrderLines';
import submitOrder from '@salesforce/apex/DMS_PortalController.submitOrder';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class DistributorOrders extends LightningElement {
    sub = 'primary';
    showEntry = false;

    primary = [];
    wiredPrimary;
    secondary = [];
    error;

    // detail flyout (secondary)
    detail;
    detailLines = [];

    // detail flyout (primary indent)
    primaryDetail;
    primaryLines = [];

    @wire(getTierOrders, { tier: 'P1' })
    wiredPrimaryOrders(result) {
        this.wiredPrimary = result;
        if (result.data) {
            this.primary = result.data.map((r) => ({
                ...r,
                dateLabel: this.fmtDate(r.orderDate),
                amountLabel: this.money(r.amount),
                // Draft = a replenishment suggestion the distributor still has to send.
                isDraft: r.status === 'Draft'
            }));
        } else if (result.error) {
            this.error = this.msg(result.error);
        }
    }

    @wire(getSecondaryOrders)
    wiredSecOrders(result) {
        if (result.data) {
            this.secondary = result.data.map((r) => ({
                ...r,
                dateLabel: this.fmtDate(r.orderDate),
                totalLabel: this.money(r.total),
                itemsLabel: r.items ? String(r.items) : '—'
            }));
        } else if (result.error) {
            this.error = this.msg(result.error);
        }
    }

    /* sub-tabs */
    get subTabs() {
        return [
            { id: 'primary', label: 'Primary Orders' },
            { id: 'secondary', label: 'Secondary Orders' }
        ].map((t) => ({ ...t, class: t.id === this.sub ? 'dms-subtab dms-subtab_active' : 'dms-subtab' }));
    }
    handleTab(e) { this.sub = e.currentTarget.dataset.tab; this.showEntry = false; }
    get isPrimary() { return this.sub === 'primary'; }
    get isSecondary() { return this.sub === 'secondary'; }

    get hasPrimary() { return this.primary.length > 0; }
    get hasSecondary() { return this.secondary.length > 0; }

    /* primary: new order entry */
    newOrder() { this.showEntry = true; }
    backToList() { this.showEntry = false; }
    handlePlaced() { this.showEntry = false; return refreshApex(this.wiredPrimary); }

    /* primary: view indent detail */
    viewPrimary(e) {
        const id = e.currentTarget.dataset.id;
        const row = this.primary.find((r) => r.id === id);
        if (!row) { return; }
        this.primaryDetail = row;
        this.primaryLines = [];
        getPrimaryOrderLines({ primaryOrderId: id })
            .then((data) => {
                this.primaryLines = (data || []).map((l) => ({
                    ...l,
                    productName: l.Product_Ext__r ? l.Product_Ext__r.Name : '',
                    qtyLabel: `${this.num(l.Quantity__c)} ${l.UOM__c || ''}`.trim(),
                    rate: this.money(l.Unit_Price__c),
                    scheme: l.Scheme__r ? l.Scheme__r.Name : '',
                    discLabel: l.Discount_Amount__c ? '−' + this.money(l.Discount_Amount__c) : '',
                    amount: this.money(l.Line_Total__c)
                }));
            })
            .catch(() => { this.primaryLines = []; });
    }
    closePrimary() { this.primaryDetail = undefined; this.primaryLines = []; }
    get hasPrimaryLines() { return this.primaryLines.length > 0; }

    /* secondary: view detail */
    viewOrder(e) {
        const id = e.currentTarget.dataset.id;
        const row = this.secondary.find((r) => r.id === id);
        if (!row) { return; }
        this.detail = row;
        this.detailLines = [];
        getSalesOrderLines({ salesOrderId: id })
            .then((data) => {
                this.detailLines = (data || []).map((l) => ({
                    ...l,
                    productName: l.Product_Ext__r ? l.Product_Ext__r.Name : '',
                    rate: this.money(l.Unit_Price__c),
                    amount: this.money(l.Net_Amount__c != null ? l.Net_Amount__c : l.Line_Amount__c)
                }));
            })
            .catch(() => { this.detailLines = []; });
    }
    closeDetail() { this.detail = undefined; this.detailLines = []; }
    get hasDetailLines() { return this.detailLines.length > 0; }

    /* helpers */
    statusTheme(status) {
        const s = (status || '').toLowerCase();
        if (s.includes('deliver') || s.includes('approved') || s.includes('paid') || s.includes('received')) return 'success';
        if (s.includes('cancel') || s.includes('reject')) return 'danger';
        if (s.includes('draft') || s.includes('pending') || s.includes('submit') || s.includes('process')) return 'warning';
        return 'info';
    }
    fmtDate(d) {
        if (!d) { return ''; }
        return new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(d));
    }
    money(v) { return '₹' + Math.round(Number(v || 0)).toLocaleString('en-IN'); }
    num(v) { return Number(v || 0).toLocaleString('en-IN'); }
    /**
     * Send a DRAFT order to the company. The nightly replenishment scheduler creates its
     * suggestions as drafts, and until now nothing could move an order out of Draft — so a
     * suggested replenishment was visible and permanently inert.
     */
    submitting = false;
    handleSubmitOrder(e) {
        const id = e.currentTarget.dataset.id;
        this.submitting = true;
        submitOrder({ orderId: id })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Order submitted', message: 'Sent to the company for approval.', variant: 'success'
                }));
                return refreshApex(this.wiredPrimary);
            })
            .catch((err) => {
                this.error = this.msg(err);
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not submit', message: this.msg(err), variant: 'error'
                }));
            })
            .finally(() => { this.submitting = false; });
    }

    msg(e) { return (e && e.body && e.body.message) || 'Unexpected error.'; }

    get primaryRows() { return this.primary.map((r) => ({ ...r, theme: this.statusTheme(r.status) })); }
    get secondaryRows() { return this.secondary.map((r) => ({ ...r, theme: this.statusTheme(r.status) })); }
}