import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getStats from '@salesforce/apex/AccountGeolocation_Controller.getGeolocationStats';
import bulkCopyFromBillingAddress from '@salesforce/apex/AccountGeolocation_Controller.bulkCopyFromBillingAddress';

export default class BulkGeolocateAccounts extends LightningElement {
    @track stats = { total: 0, withLocation: 0, withBilling: 0, missing: 0 };
    @track radiusMeters = 100;
    @track isLoading = false;
    @track isProcessing = false;

    connectedCallback() {
        this.loadStats();
    }

    async loadStats() {
        this.isLoading = true;
        try {
            this.stats = await getStats({ territoryId: null });
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    get coveragePercent() {
        if (!this.stats.total) return 0;
        return Math.round((this.stats.withLocation / this.stats.total) * 100);
    }

    get coverageBarStyle() {
        return `width: ${this.coveragePercent}%;`;
    }

    get canBulkCopy() {
        return this.stats.withBilling > 0 && !this.isProcessing;
    }

    handleRadiusChange(event) {
        this.radiusMeters = parseInt(event.target.value, 10) || 100;
    }

    handleRefresh() {
        this.loadStats();
    }

    async handleBulkCopy() {
        // eslint-disable-next-line no-alert
        if (!confirm(`Copy billing address coordinates to ${this.stats.withBilling} accounts? This sets a default geofence radius of ${this.radiusMeters}m.`)) {
            return;
        }
        this.isProcessing = true;
        try {
            const updatedCount = await bulkCopyFromBillingAddress({
                territoryId: null,
                radiusMeters: this.radiusMeters
            });
            this.toast('Bulk update complete', `Updated ${updatedCount} accounts.`, 'success');
            await this.loadStats();
        } catch (e) {
            this.toast('Bulk update failed', this.errMsg(e), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    errMsg(e) {
        if (!e) return 'Unknown error';
        if (e.body && e.body.message) return e.body.message;
        return e.message || String(e);
    }
}