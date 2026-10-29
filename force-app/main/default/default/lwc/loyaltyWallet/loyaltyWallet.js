import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getBalance from '@salesforce/apex/LoyaltyService.getBalance';
import getLedger from '@salesforce/apex/LoyaltyService.getLedger';

const TYPE_CLASSES = {
    'Earned':   'lw-pill lw-pill-earned',
    'Redeemed': 'lw-pill lw-pill-redeemed',
    'Expired':  'lw-pill lw-pill-expired',
    'Adjusted': 'lw-pill lw-pill-adjusted'
};

export default class LoyaltyWallet extends LightningElement {
    @api recordId;          // Account Id when placed on Account record page
    @api accountId;         // For App page usage where recordId isn't bound

    @track balance = 0;
    @track ledger = [];
    @track isLoading = true;

    _balanceWired;
    _ledgerWired;

    get effectiveAccountId() {
        return this.recordId || this.accountId;
    }

    get hasBalance() {
        return this.balance > 0;
    }

    get hasLedger() {
        return this.ledger && this.ledger.length > 0;
    }

    get balanceFormatted() {
        return Number(this.balance || 0).toLocaleString('en-IN');
    }

    get cashValueFormatted() {
        return `₹${Number(this.balance || 0).toLocaleString('en-IN')}`;
    }

    @wire(getBalance, { accountId: '$effectiveAccountId' })
    wiredBalance(result) {
        this._balanceWired = result;
        if (result.data !== undefined) {
            this.balance = result.data || 0;
            this.isLoading = false;
        } else if (result.error) {
            this.isLoading = false;
            // eslint-disable-next-line no-console
            console.error('LoyaltyWallet balance error', result.error);
        }
    }

    @wire(getLedger, { accountId: '$effectiveAccountId', recordLimit: 20 })
    wiredLedger(result) {
        this._ledgerWired = result;
        if (result.data) {
            this.ledger = result.data.map(row => ({
                id: row.Id,
                name: row.Name,
                points: row.Points__c,
                pointsDisplay: this._formatSignedPoints(row.Points__c),
                pointsClass: row.Points__c >= 0 ? 'lw-points-pos' : 'lw-points-neg',
                balance: row.Balance_After__c,
                balanceDisplay: Number(row.Balance_After__c || 0).toLocaleString('en-IN'),
                type: row.Transaction_Type__c,
                typeClass: TYPE_CLASSES[row.Transaction_Type__c] || 'lw-pill',
                date: row.Transaction_Date__c,
                reference: row.Reference__c || '—',
                notes: row.Notes__c || ''
            }));
        } else if (result.error) {
            // eslint-disable-next-line no-console
            console.error('LoyaltyWallet ledger error', result.error);
        }
    }

    handleRefresh() {
        this.isLoading = true;
        Promise.all([
            refreshApex(this._balanceWired),
            refreshApex(this._ledgerWired)
        ]).finally(() => { this.isLoading = false; });
    }

    _formatSignedPoints(n) {
        if (n == null) return '0';
        const abs = Math.abs(n).toLocaleString('en-IN');
        return n >= 0 ? `+${abs}` : `-${abs}`;
    }
}