import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getTickets from '@salesforce/apex/DMS_PortalController.getTickets';
import raiseTicket from '@salesforce/apex/DMS_PortalController.raiseTicket';

const CATEGORIES = ['Product Quality', 'Delivery Issue', 'Pricing Dispute', 'Service Request', 'Scheme Claim', 'Other'];
const PRIORITIES = ['Low', 'Medium', 'High', 'Critical'];
const PRIORITY_THEME = { Low: 'neutral', Medium: 'info', High: 'warning', Critical: 'danger' };
const OPEN_SET = new Set(['Open', 'In Progress', 'Pending', 'New']);

export default class DistributorTickets extends LightningElement {
    all = [];
    wiredTickets;
    error;
    categoryOptions = CATEGORIES.map((c) => ({ label: c, value: c }));
    priorityOptions = PRIORITIES.map((p) => ({ label: p, value: p }));

    // new ticket modal
    modalOpen = false;
    subject;
    description;
    category = 'Service Request';
    priority = 'Medium';
    submitting = false;

    @wire(getTickets)
    wired(result) {
        this.wiredTickets = result;
        if (result.data) { this.all = result.data; }
        else if (result.error) { this.error = this.msg(result.error); }
    }

    get rows() {
        return this.all.map((t, i) => ({
            key: i, id: t.Id, subject: t.Subject__c, category: t.Category__c,
            priority: t.Priority__c, status: t.Status__c, ticketDate: t.Ticket_Date__c,
            priorityTheme: PRIORITY_THEME[t.Priority__c] || 'neutral'
        }));
    }
    get hasRows() { return this.rows.length > 0; }

    get cards() {
        const open = this.all.filter((t) => OPEN_SET.has(t.Status__c)).length;
        const resolved = this.all.filter((t) => t.Status__c === 'Resolved' || t.Status__c === 'Closed').length;
        return [
            { id: 't', label: 'Total Tickets', value: this.all.length, cls: 'dms-card__value' },
            { id: 'o', label: 'Open', value: open, cls: 'dms-card__value dms-card__value_amber' },
            { id: 'r', label: 'Resolved', value: resolved, cls: 'dms-card__value dms-card__value_green' }
        ];
    }

    get submitDisabled() { return !this.subject || this.submitting; }

    openModal() {
        this.modalOpen = true;
        this.subject = undefined;
        this.description = undefined;
        this.category = 'Service Request';
        this.priority = 'Medium';
    }
    closeModal() { this.modalOpen = false; }
    handleSubject(e) { this.subject = e.detail.value; }
    handleDescription(e) { this.description = e.detail.value; }
    handleCategory(e) { this.category = e.detail.value; }
    handlePriority(e) { this.priority = e.detail.value; }

    async submit() {
        this.submitting = true;
        try {
            await raiseTicket({
                subject: this.subject, description: this.description,
                category: this.category, priority: this.priority
            });
            this.toast('Ticket raised', 'Your support ticket was created.', 'success');
            this.modalOpen = false;
            await refreshApex(this.wiredTickets);
        } catch (e) {
            this.toast('Could not raise ticket', this.msg(e), 'error');
        } finally {
            this.submitting = false;
        }
    }

    msg(e) { return (e && e.body && e.body.message) || 'Unexpected error.'; }
    toast(title, message, variant) { this.dispatchEvent(new ShowToastEvent({ title, message, variant })); }
}