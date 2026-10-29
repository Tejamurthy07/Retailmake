import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getAccountLocation from '@salesforce/apex/AccountGeolocation_Controller.getAccountLocation';
import saveAccountLocation from '@salesforce/apex/AccountGeolocation_Controller.saveAccountLocation';
import clearAccountLocation from '@salesforce/apex/AccountGeolocation_Controller.clearAccountLocation';

export default class AccountGeolocationButton extends LightningElement {
    @api recordId;

    @track isLoading = false;
    @track isCapturing = false;
    @track currentLocation = null;
    @track radiusMeters = 100;
    @track capturedLat;
    @track capturedLng;
    @track capturedAccuracy;

    _wiredAccount;

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. Recurses into arrays
    // and child relationships. No-op on camelCase maps and wrapper DTOs.
    _stripNs(value) {
        if (Array.isArray(value)) return value.map((v) => this._stripNs(v));
        if (value && typeof value === 'object') {
            const out = {};
            Object.keys(value).forEach((k) => {
                const nk = k.startsWith('ftretailmake__') ? k.slice('ftretailmake__'.length) : k;
                out[nk] = this._stripNs(value[k]);
            });
            return out;
        }
        return value;
    }

    @wire(getAccountLocation, { accountId: '$recordId' })
    wiredLocation(result) {
        this._wiredAccount = result;
        if (result.data) {
            const loc = this._stripNs(result.data);
            this.currentLocation = loc;
            if (loc.Geofence_Radius__c) {
                this.radiusMeters = loc.Geofence_Radius__c;
            }
        }
    }

    get hasLocation() {
        return this.currentLocation &&
               this.currentLocation.Outlet_Latitude__c != null &&
               this.currentLocation.Outlet_Longitude__c != null;
    }

    get hasBillingFallback() {
        return this.currentLocation &&
               this.currentLocation.BillingLatitude != null &&
               this.currentLocation.BillingLongitude != null &&
               !this.hasLocation;
    }

    get savedLatLngLabel() {
        if (!this.hasLocation) return 'Not set';
        const lat = Number(this.currentLocation.Outlet_Latitude__c).toFixed(6);
        const lng = Number(this.currentLocation.Outlet_Longitude__c).toFixed(6);
        return `${lat}, ${lng}`;
    }

    get capturedLabel() {
        if (this.capturedLat == null || this.capturedLng == null) return '';
        return `${this.capturedLat.toFixed(6)}, ${this.capturedLng.toFixed(6)} (±${Math.round(this.capturedAccuracy)}m)`;
    }

    get hasCapture() {
        return this.capturedLat != null && this.capturedLng != null;
    }

    get mapUrl() {
        if (!this.hasLocation) return '';
        return `https://www.google.com/maps?q=${this.currentLocation.Outlet_Latitude__c},${this.currentLocation.Outlet_Longitude__c}`;
    }

    handleRadiusChange(event) {
        this.radiusMeters = parseInt(event.target.value, 10) || 100;
    }

    handleCaptureClick() {
        if (!navigator.geolocation) {
            this.toast('Error', 'Browser does not support geolocation', 'error');
            return;
        }
        this.isCapturing = true;
        navigator.geolocation.getCurrentPosition(
            (pos) => {
                this.capturedLat = pos.coords.latitude;
                this.capturedLng = pos.coords.longitude;
                this.capturedAccuracy = pos.coords.accuracy;
                this.isCapturing = false;
                this.toast('Location captured', 'Click "Save to Account" to apply.', 'success');
            },
            (err) => {
                this.isCapturing = false;
                let msg = err.message || 'Failed to capture location';
                if (err.code === 1) msg = 'Permission denied. Allow location access in your browser.';
                if (err.code === 2) msg = 'Location unavailable. Check GPS or network.';
                if (err.code === 3) msg = 'Location request timed out.';
                this.toast('Capture failed', msg, 'error');
            },
            { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
        );
    }

    async handleSaveClick() {
        if (!this.hasCapture) {
            this.toast('Warning', 'Capture a location first.', 'warning');
            return;
        }
        this.isLoading = true;
        try {
            this._stripNs(await saveAccountLocation({
                accountId: this.recordId,
                latitude: this.capturedLat,
                longitude: this.capturedLng,
                accuracy: this.capturedAccuracy,
                radiusMeters: this.radiusMeters
            }));
            this.toast('Saved', 'Outlet location saved successfully.', 'success');
            this.capturedLat = null;
            this.capturedLng = null;
            this.capturedAccuracy = null;
            await refreshApex(this._wiredAccount);
        } catch (e) {
            this.toast('Save failed', this.errMsg(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleUseBilling() {
        if (!this.currentLocation || this.currentLocation.BillingLatitude == null) return;
        this.isLoading = true;
        try {
            this._stripNs(await saveAccountLocation({
                accountId: this.recordId,
                latitude: this.currentLocation.BillingLatitude,
                longitude: this.currentLocation.BillingLongitude,
                accuracy: 0,
                radiusMeters: this.radiusMeters
            }));
            this.toast('Saved', 'Outlet location set from billing address.', 'success');
            await refreshApex(this._wiredAccount);
        } catch (e) {
            this.toast('Save failed', this.errMsg(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleClearClick() {
        // eslint-disable-next-line no-alert
        if (!confirm('Clear the saved outlet location?')) return;
        this.isLoading = true;
        try {
            await clearAccountLocation({ accountId: this.recordId });
            this.toast('Cleared', 'Outlet location removed.', 'success');
            await refreshApex(this._wiredAccount);
        } catch (e) {
            this.toast('Clear failed', this.errMsg(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleOpenMap() {
        if (this.hasLocation) {
            window.open(this.mapUrl, '_blank');
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