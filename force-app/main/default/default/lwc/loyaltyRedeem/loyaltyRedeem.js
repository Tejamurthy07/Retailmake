import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getPreview from '@salesforce/apex/LoyaltyRedemptionController.getPreview';
import applyRedemption from '@salesforce/apex/LoyaltyRedemptionController.applyRedemption';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';

export default class LoyaltyRedeem extends LightningElement {
    @api recordId;          // Sales_Order__c Id

    @track balance = 0;
    @track currentlyRedeemed = 0;
    @track maxRedeemable = 0;
    @track orderStatus = '';
    @track canRedeem = false;
    @track lockedMessage = '';
    @track showModal = false;
    @track pointsInput = 0;
    @track isLoading = true;
    @track isSaving = false;

    connectedCallback() {
        this.refresh();
    }

    get balanceFormatted() {
        return Number(this.balance || 0).toLocaleString('en-IN');
    }

    get currentlyRedeemedFormatted() {
        return Number(this.currentlyRedeemed || 0).toLocaleString('en-IN');
    }

    get maxRedeemableFormatted() {
        return Number(this.maxRedeemable || 0).toLocaleString('en-IN');
    }

    get hasRedemption() {
        return Number(this.currentlyRedeemed) > 0;
    }

    get redeemDisabled() {
        return !this.canRedeem;
    }

    get clearDisabled() {
        return !this.canRedeem || !this.hasRedemption;
    }

    get applyDisabled() {
        const n = Number(this.pointsInput);
        return this.isSaving || isNaN(n) || n < 0 || n > this.maxRedeemable;
    }

    get pointsInputError() {
        const n = Number(this.pointsInput);
        if (isNaN(n)) return 'Enter a number.';
        if (n < 0) return 'Cannot be negative.';
        if (n > this.maxRedeemable) return `Max ${this.maxRedeemableFormatted}.`;
        return '';
    }

    get cashEquivalent() {
        const n = Number(this.pointsInput) || 0;
        return `₹${n.toLocaleString('en-IN')}`;
    }

    refresh() {
        this.isLoading = true;
        getPreview({ orderId: this.recordId })
            .then(p => {
                this.balance = p.balance || 0;
                this.currentlyRedeemed = p.currentlyRedeemed || 0;
                this.maxRedeemable = p.maxRedeemable || 0;
                this.orderStatus = p.orderStatus;
                this.canRedeem = !!p.canRedeem;
                this.lockedMessage = p.message || '';
                this.pointsInput = this.currentlyRedeemed;
                this.isLoading = false;
            })
            .catch(err => {
                this.isLoading = false;
                this.canRedeem = false;
                this.lockedMessage = (err.body && err.body.message) || 'Failed to load wallet.';
            });
    }

    openModal() {
        if (!this.canRedeem) return;
        this.pointsInput = this.currentlyRedeemed || 0;
        this.showModal = true;
    }

    closeModal() {
        this.showModal = false;
    }

    handlePointsChange(e) {
        this.pointsInput = e.target.value;
    }

    handleApply() {
        const n = Number(this.pointsInput);
        if (isNaN(n) || n < 0 || n > this.maxRedeemable) return;
        this.isSaving = true;
        applyRedemption({ orderId: this.recordId, points: n })
            .then(p => {
                this.balance = p.balance || 0;
                this.currentlyRedeemed = p.currentlyRedeemed || 0;
                this.maxRedeemable = p.maxRedeemable || 0;
                this.showModal = false;
                this.isSaving = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Redemption updated',
                    message: `${Number(p.currentlyRedeemed).toLocaleString('en-IN')} points (₹${Number(p.currentlyRedeemed).toLocaleString('en-IN')}) on this order`,
                    variant: 'success'
                }));
                getRecordNotifyChange([{ recordId: this.recordId }]);
            })
            .catch(err => {
                this.isSaving = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not apply redemption',
                    message: (err.body && err.body.message) || err.message || 'Unknown error',
                    variant: 'error'
                }));
            });
    }

    handleClear() {
        if (!this.hasRedemption) return;
        this.isSaving = true;
        applyRedemption({ orderId: this.recordId, points: 0 })
            .then(p => {
                this.balance = p.balance || 0;
                this.currentlyRedeemed = p.currentlyRedeemed || 0;
                this.maxRedeemable = p.maxRedeemable || 0;
                this.isSaving = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Redemption cleared',
                    variant: 'success'
                }));
                getRecordNotifyChange([{ recordId: this.recordId }]);
            })
            .catch(err => {
                this.isSaving = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not clear redemption',
                    message: (err.body && err.body.message) || err.message || 'Unknown error',
                    variant: 'error'
                }));
            });
    }
}