import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getClaims from '@salesforce/apex/DMS_PortalController.getClaims';
import getClaimSchemes from '@salesforce/apex/DMS_PortalController.getClaimSchemes';
import getClaimLines from '@salesforce/apex/DMS_PortalController.getClaimLines';
import submitClaim from '@salesforce/apex/DMS_PortalController.submitClaim';

const ALL = 'All';
const TYPES = ['Scheme Claim', 'Damage Claim', 'Expiry Claim', 'Rate Difference', 'Other'];
const STATUS_OPTIONS = ['All', 'Submitted', 'Approved', 'Partially Approved', 'Settled', 'Rejected'].map(
    (s) => ({ label: s === ALL ? 'All Status' : s, value: s })
);
const APPROVED_SET = new Set(['Approved', 'Partially Approved', 'Settled']);

export default class DistributorClaims extends LightningElement {
    statusFilter = ALL;
    statusOptions = STATUS_OPTIONS;
    typeOptions = TYPES.map((t) => ({ label: t, value: t }));
    all = [];
    wiredClaims;
    schemes = [];
    error;

    // new claim modal
    modalOpen = false;
    formType = 'Scheme Claim';
    formScheme = '';
    formAmount;
    formNotes;
    submitting = false;

    // detail modal
    detailOpen = false;
    selected = null;
    detailLines = [];

    @wire(getClaims)
    wiredC(result) {
        this.wiredClaims = result;
        if (result.data) { this.all = result.data; }
        else if (result.error) { this.error = this.msg(result.error); }
    }

    @wire(getClaimSchemes)
    wiredS({ data }) { if (data) { this.schemes = data; } }

    handleStatus(e) { this.statusFilter = e.detail.value; }

    get rows() {
        return this.all
            .filter((c) => this.statusFilter === ALL || c.Status__c === this.statusFilter)
            .map((c) => ({
                id: c.Id, key: c.Id, name: c.Name, type: c.Claim_Type__c,
                scheme: c.Scheme__r ? c.Scheme__r.Name : null,
                claimDate: c.Claim_Date__c, amount: c.Total_Amount__c,
                approved: c.Approved_Amount__c, status: c.Status__c,
                creditNote: c.Credit_Note_Number__c, notes: c.Notes__c
            }));
    }
    get hasRows() { return this.rows.length > 0; }

    get summary() {
        const list = this.all;
        const total = list.reduce((s, c) => s + (Number(c.Total_Amount__c) || 0), 0);
        const approved = list.filter((c) => APPROVED_SET.has(c.Status__c)).length;
        const pending = list.filter((c) => c.Status__c === 'Submitted').length;
        const rejected = list.filter((c) => c.Status__c === 'Rejected').length;
        return [
            { id: 't', label: 'Total Claims', value: list.length, cls: 'dms-card__value' },
            { id: 'v', label: 'Total Value', value: this.inr(total), cls: 'dms-card__value' },
            { id: 'a', label: 'Approved', value: approved, cls: 'dms-card__value dms-card__value_green' },
            { id: 'p', label: 'Pending', value: pending, cls: 'dms-card__value dms-card__value_amber' },
            { id: 'r', label: 'Rejected', value: rejected, cls: 'dms-card__value dms-card__value_red' }
        ];
    }

    // ── new claim ─────────────────────────────────────────────────────────
    get schemeOptions() {
        return [{ label: '— None —', value: '' }].concat(
            this.schemes.map((s) => ({ label: s.name, value: s.id }))
        );
    }
    get isSchemeClaim() { return this.formType === 'Scheme Claim'; }
    get submitDisabled() { return !(Number(this.formAmount) > 0) || this.submitting; }

    openModal() {
        this.modalOpen = true;
        this.formType = 'Scheme Claim';
        this.formScheme = '';
        this.formAmount = undefined;
        this.formNotes = undefined;
    }
    closeModal() { this.modalOpen = false; }
    handleType(e) { this.formType = e.detail.value; }
    handleScheme(e) { this.formScheme = e.detail.value; }
    handleAmount(e) { this.formAmount = e.target.value; }
    handleNotes(e) { this.formNotes = e.target.value; }

    async submit() {
        this.submitting = true;
        try {
            await submitClaim({
                claimType: this.formType,
                schemeId: this.formScheme || null,
                amount: Number(this.formAmount),
                notes: this.formNotes
            });
            this.toast('Claim submitted', 'Your claim was submitted for review.', 'success');
            this.modalOpen = false;
            await refreshApex(this.wiredClaims);
        } catch (e) {
            this.toast('Could not submit claim', this.msg(e), 'error');
        } finally {
            this.submitting = false;
        }
    }

    // ── detail ────────────────────────────────────────────────────────────
    async openDetail(e) {
        const id = e.currentTarget.dataset.id;
        const row = this.rows.find((r) => r.id === id);
        if (!row) { return; }
        this.selected = row;
        this.detailLines = [];
        this.detailOpen = true;
        try {
            const lines = await getClaimLines({ claimId: id });
            this.detailLines = (lines || []).map((l, i) => ({ ...l, key: i }));
        } catch (err) {
            // a claim with no lines is fine — the header still shows.
        }
    }
    closeDetail() { this.detailOpen = false; this.selected = null; this.detailLines = []; }
    get hasDetailLines() { return this.detailLines && this.detailLines.length > 0; }

    inr(v) { return '₹' + Number(v || 0).toLocaleString('en-IN'); }
    msg(e) { return (e && e.body && e.body.message) || 'Unexpected error.'; }
    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}