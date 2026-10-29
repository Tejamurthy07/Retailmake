import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getRecordApprovalState from '@salesforce/apex/ApprovalPanelController.getRecordApprovalState';
import submitRecord from '@salesforce/apex/ApprovalPanelController.submitRecord';
import approveStep from '@salesforce/apex/ApprovalPanelController.approveStep';
import rejectStep from '@salesforce/apex/ApprovalPanelController.rejectStep';
import recallRequest from '@salesforce/apex/ApprovalPanelController.recallRequest';

export default class ApprovalPanel extends LightningElement {
    @api recordId;
    @track state;
    @track loading = true;
    @track showCommentsModal = false;
    @track modalAction = '';
    @track modalComments = '';
    @track isProcessing = false;
    _wired;

    @wire(getRecordApprovalState, { recordId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.state = result.data;
            this.loading = false;
        }
        if (result.error) {
            this.toast('Error', this.errMsg(result.error), 'error');
            this.loading = false;
        }
    }

    get hasRequest() { return this.state && this.state.hasRequest; }
    get noRequest() { return this.state && !this.state.hasRequest; }
    get canSubmit() { return this.state && this.state.canSubmit; }
    get canSubmitAgain() { return this.state && this.state.canSubmitAgain; }
    get canAct() { return this.state && this.state.canAct; }
    get canRecall() { return this.state && this.state.canRecall; }
    get request() { return this.state && this.state.request; }

    get submittedByName() {
        const r = this.request;
        return (r && r.Submitted_By__r && r.Submitted_By__r.Name) || '—';
    }
    get currentApproverName() {
        const r = this.request;
        return r && r.Current_Approver__r && r.Current_Approver__r.Name;
    }
    get showCurrentApprover() {
        return !!this.currentApproverName;
    }

    get statusClass() {
        if (!this.request) return '';
        const s = this.request.Status__c;
        if (s === 'Approved') return 'ap-status ap-status-approved';
        if (s === 'Rejected') return 'ap-status ap-status-rejected';
        if (s === 'Recalled') return 'ap-status ap-status-recalled';
        return 'ap-status ap-status-pending';
    }

    get progressText() {
        if (!this.request) return '';
        return `Level ${this.request.Current_Level__c || 1} of ${this.request.Total_Levels__c}`;
    }

    get steps() {
        if (!this.state || !this.state.steps) return [];
        return this.state.steps.map((s, idx) => {
            const isLast = idx === this.state.steps.length - 1;
            const status = s.Status__c || 'Pending';
            let dotClass = 'ap-step-dot';
            let badgeClass = 'ap-step-badge';
            if (status === 'Approved' || status === 'Auto-Approved') {
                dotClass += ' ap-step-dot-approved';
                badgeClass += ' ap-badge-approved';
            } else if (status === 'Rejected') {
                dotClass += ' ap-step-dot-rejected';
                badgeClass += ' ap-badge-rejected';
            } else if (status === 'Skipped') {
                dotClass += ' ap-step-dot-skipped';
                badgeClass += ' ap-badge-skipped';
            } else if (s.Is_Current__c) {
                dotClass += ' ap-step-dot-current';
                badgeClass += ' ap-badge-current';
            } else {
                dotClass += ' ap-step-dot-pending';
                badgeClass += ' ap-badge-pending';
            }
            return {
                ...s,
                key: s.Id,
                isLast,
                levelLabel: 'L' + (s.Level__c || 1),
                approverName: (s.Approver__r && s.Approver__r.Name) || '(unassigned)',
                approverMeta: this._approverMeta(s),
                statusLabel: status,
                dotClass,
                badgeClass,
                decisionDate: s.Decision_Date__c,
                comments: s.Comments__c
            };
        });
    }

    _approverMeta(s) {
        if (s.Approver_Type__c === 'User') return 'Specific User';
        if (s.Approver_Type__c === 'Manager') return "Owner's Manager";
        if (s.Approver_Type__c === 'Role') return 'Role: ' + (s.Approver_Reference__c || '');
        if (s.Approver_Type__c === 'Queue') return 'Queue: ' + (s.Approver_Reference__c || '');
        return s.Approver_Type__c || '';
    }

    handleSubmitClick() {
        this.modalAction = 'submit';
        this.modalComments = '';
        this.showCommentsModal = true;
    }
    handleApproveClick() {
        this.modalAction = 'approve';
        this.modalComments = '';
        this.showCommentsModal = true;
    }
    handleRejectClick() {
        this.modalAction = 'reject';
        this.modalComments = '';
        this.showCommentsModal = true;
    }
    handleRecallClick() {
        if (!confirm('Recall this approval request?')) return;
        this._doRecall();
    }
    handleCloseModal() { this.showCommentsModal = false; }
    handleCommentsChange(event) { this.modalComments = event.target.value; }

    get modalTitle() {
        if (this.modalAction === 'submit') return 'Submit for Approval';
        if (this.modalAction === 'approve') return 'Approve';
        if (this.modalAction === 'reject') return 'Reject';
        return '';
    }
    get modalConfirmLabel() {
        if (this.modalAction === 'submit') return 'Submit';
        if (this.modalAction === 'approve') return 'Approve';
        if (this.modalAction === 'reject') return 'Reject';
        return 'Confirm';
    }
    get isRejectMode() { return this.modalAction === 'reject'; }
    get rejectRequiresComments() {
        return this.modalAction === 'reject' && (this.modalComments || '').trim().length === 0;
    }
    get confirmDisabled() { return this.isProcessing || this.rejectRequiresComments; }

    async handleModalConfirm() {
        if (this.confirmDisabled) return;
        this.isProcessing = true;
        try {
            if (this.modalAction === 'submit') {
                await submitRecord({ recordId: this.recordId, comments: this.modalComments });
                this.toast('Submitted', 'Approval request created.', 'success');
            } else if (this.modalAction === 'approve') {
                await approveStep({ stepId: this.state.currentStepId, comments: this.modalComments });
                this.toast('Approved', 'Step approved.', 'success');
            } else if (this.modalAction === 'reject') {
                await rejectStep({ stepId: this.state.currentStepId, comments: this.modalComments });
                this.toast('Rejected', 'Step rejected.', 'success');
            }
            this.showCommentsModal = false;
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isProcessing = false;
    }

    async _doRecall() {
        try {
            await recallRequest({ requestId: this.request.Id });
            this.toast('Recalled', 'Request withdrawn.', 'success');
            await refreshApex(this._wired);
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    errMsg(e) {
        if (!e) return 'Unknown error';
        if (e.body && e.body.message) return e.body.message;
        if (Array.isArray(e.body)) return e.body.map(x => x.message).join(', ');
        if (e.message) return e.message;
        return JSON.stringify(e);
    }
}