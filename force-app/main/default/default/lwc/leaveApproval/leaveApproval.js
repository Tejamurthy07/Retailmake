import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import Id from '@salesforce/user/Id';

import checkIsManager from '@salesforce/apex/LeaveRequestController.checkIsManager';
import getPendingApprovalsForManager from '@salesforce/apex/LeaveRequestController.getPendingApprovalsForManager';
import getApprovalHistoryForManager from '@salesforce/apex/LeaveRequestController.getApprovalHistoryForManager';
import approveLeaveRequest from '@salesforce/apex/LeaveRequestController.approveLeaveRequest';
import rejectLeaveRequest from '@salesforce/apex/LeaveRequestController.rejectLeaveRequest';

const LEAVE_TYPE_CONFIG = {
    'Casual Leave': { short: 'CL', color: '#0176d3', bgColor: '#e8f4fd' },
    'Sick Leave': { short: 'SL', color: '#2e844a', bgColor: '#e6f7e9' },
    'Earned Leave': { short: 'EL', color: '#7b61ff', bgColor: '#f0ebff' },
    'Compensatory Off': { short: 'CO', color: '#dd7a01', bgColor: '#fff8e1' }
};

const STATUS_CONFIG = {
    'Pending': { class: 'status-badge status-pending' },
    'Submitted': { class: 'status-badge status-submitted' },
    'Approved': { class: 'status-badge status-approved' },
    'Rejected': { class: 'status-badge status-rejected' },
    'Cancelled': { class: 'status-badge status-cancelled' }
};

export default class LeaveApproval extends LightningElement {
    currentUserId = Id;

    @track isManager = false;
    @track isLoading = false;
    @track pendingRequests = [];
    @track historyRequests = [];
    @track activeTab = 'pending';

    // Expanded row and comments
    @track expandedRowId = null;
    @track comments = {};

    // Detail modal
    @track showDetailModal = false;
    @track selectedRequest = null;
    @track detailComments = '';

    // ── Getters ──────────────────────────────────────────────

    get isPendingTab() {
        return this.activeTab === 'pending';
    }

    get isHistoryTab() {
        return this.activeTab === 'history';
    }

    get pendingTabClass() {
        return this.activeTab === 'pending' ? 'view-tab view-tab-active' : 'view-tab';
    }

    get historyTabClass() {
        return this.activeTab === 'history' ? 'view-tab view-tab-active' : 'view-tab';
    }

    get pendingCount() {
        return this.pendingRequests.length;
    }

    get hasPendingRequests() {
        return this.pendingRequests.length > 0;
    }

    get hasHistoryRequests() {
        return this.historyRequests.length > 0;
    }

    get processedPendingRequests() {
        return this.pendingRequests.map(r => this.enrichRequest(r));
    }

    get processedHistoryRequests() {
        return this.historyRequests.map(r => this.enrichRequest(r));
    }

    // Detail modal getters
    get detailLeave() {
        if (!this.selectedRequest) return null;
        return this.enrichRequest(this.selectedRequest);
    }

    get canApproveSelected() {
        return this.selectedRequest &&
            (this.selectedRequest.Status__c === 'Pending' || this.selectedRequest.Status__c === 'Submitted');
    }

    // ── Lifecycle ────────────────────────────────────────────

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            this.isManager = await checkIsManager({ userId: this.currentUserId });
            if (this.isManager) {
                await Promise.all([
                    this.loadPendingRequests(),
                    this.loadHistory()
                ]);
            }
        } catch (error) {
            console.error('Leave Approval load error:', error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadPendingRequests() {
        try {
            const result = await getPendingApprovalsForManager({
                managerId: this.currentUserId
            });
            this.pendingRequests = result || [];
        } catch (error) {
            console.error('Error loading pending approvals:', error);
        }
    }

    async loadHistory() {
        try {
            const result = await getApprovalHistoryForManager({
                managerId: this.currentUserId
            });
            this.historyRequests = result || [];
        } catch (error) {
            console.error('Error loading approval history:', error);
        }
    }

    // ── Tab Handlers ─────────────────────────────────────────

    handlePendingTab() {
        this.activeTab = 'pending';
    }

    handleHistoryTab() {
        this.activeTab = 'history';
    }

    // ── Row Interaction ──────────────────────────────────────

    handleToggleRow(event) {
        const rowId = event.currentTarget.dataset.id;
        this.expandedRowId = this.expandedRowId === rowId ? null : rowId;
    }

    handleCommentChange(event) {
        const leaveId = event.target.dataset.id;
        this.comments = { ...this.comments, [leaveId]: event.target.value };
    }

    // ── Detail Modal ─────────────────────────────────────────

    handleViewDetail(event) {
        event.stopPropagation();
        const leaveId = event.currentTarget.dataset.id;
        const allRequests = [...this.pendingRequests, ...this.historyRequests];
        const request = allRequests.find(r => r.Id === leaveId);
        if (request) {
            this.selectedRequest = request;
            this.detailComments = '';
            this.showDetailModal = true;
        }
    }

    handleCloseDetailModal() {
        this.showDetailModal = false;
        this.selectedRequest = null;
        this.detailComments = '';
    }

    handleDetailCommentChange(event) {
        this.detailComments = event.target.value;
    }

    // ── Approve/Reject from Table ────────────────────────────

    async handleApprove(event) {
        event.stopPropagation();
        const leaveId = event.currentTarget.dataset.id;
        const leaveComments = this.comments[leaveId] || '';
        this.isLoading = true;
        try {
            await approveLeaveRequest({
                leaveRequestId: leaveId,
                comments: leaveComments
            });
            this.showToast('Success', 'Leave request approved successfully.', 'success');
            this.expandedRowId = null;
            this.comments = { ...this.comments, [leaveId]: '' };
            await Promise.all([this.loadPendingRequests(), this.loadHistory()]);
        } catch (error) {
            this.showToast('Error', 'Failed to approve: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleReject(event) {
        event.stopPropagation();
        const leaveId = event.currentTarget.dataset.id;
        const leaveComments = this.comments[leaveId] || '';
        if (!leaveComments.trim()) {
            this.showToast('Error', 'Please provide a reason for rejection.', 'error');
            return;
        }
        this.isLoading = true;
        try {
            await rejectLeaveRequest({
                leaveRequestId: leaveId,
                comments: leaveComments
            });
            this.showToast('Success', 'Leave request rejected.', 'success');
            this.expandedRowId = null;
            this.comments = { ...this.comments, [leaveId]: '' };
            await Promise.all([this.loadPendingRequests(), this.loadHistory()]);
        } catch (error) {
            this.showToast('Error', 'Failed to reject: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Approve/Reject from Detail Modal ─────────────────────

    async handleApproveFromDetail() {
        if (!this.selectedRequest) return;
        this.isLoading = true;
        try {
            await approveLeaveRequest({
                leaveRequestId: this.selectedRequest.Id,
                comments: this.detailComments || ''
            });
            this.showToast('Success', 'Leave request approved successfully.', 'success');
            this.showDetailModal = false;
            this.selectedRequest = null;
            await Promise.all([this.loadPendingRequests(), this.loadHistory()]);
        } catch (error) {
            this.showToast('Error', 'Failed to approve: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleRejectFromDetail() {
        if (!this.selectedRequest) return;
        if (!this.detailComments || !this.detailComments.trim()) {
            this.showToast('Error', 'Please provide a reason for rejection.', 'error');
            return;
        }
        this.isLoading = true;
        try {
            await rejectLeaveRequest({
                leaveRequestId: this.selectedRequest.Id,
                comments: this.detailComments
            });
            this.showToast('Success', 'Leave request rejected.', 'success');
            this.showDetailModal = false;
            this.selectedRequest = null;
            await Promise.all([this.loadPendingRequests(), this.loadHistory()]);
        } catch (error) {
            this.showToast('Error', 'Failed to reject: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Data Enrichment ──────────────────────────────────────

    enrichRequest(r) {
        const typeConfig = LEAVE_TYPE_CONFIG[r.Leave_Type__c] || {};
        const statusConfig = STATUS_CONFIG[r.Status__c] || {};
        const isExpanded = this.expandedRowId === r.Id;
        const startSession = r.Start_Session__c || 'Session 1';
        const endSession = r.End_Session__c || 'Session 2';

        return {
            ...r,
            employeeName: r.Employee__r ? r.Employee__r.Name : 'Unknown',
            typeShort: typeConfig.short || r.Leave_Type__c,
            typeBadgeClass: 'leave-type-badge',
            typeBadgeStyle: 'background: ' + (typeConfig.bgColor || '#f3f3f3') +
                '; color: ' + (typeConfig.color || '#706e6b'),
            statusBadgeClass: statusConfig.class || 'status-badge',
            dateRange: this.formatDateRangeWithSession(r.Start_Date__c, startSession, r.End_Date__c, endSession),
            daysDisplay: r.Number_of_Days__c + (r.Number_of_Days__c === 1 || r.Number_of_Days__c === 0.5 ? ' day' : ' days'),
            reasonPreview: r.Reason__c ? (r.Reason__c.length > 80 ? r.Reason__c.substring(0, 80) + '...' : r.Reason__c) : '-',
            isExpanded: isExpanded,
            rowClass: isExpanded ? 'approval-row approval-row-expanded' : 'approval-row',
            commentValue: this.comments[r.Id] || '',
            startDateFormatted: this.formatDate(r.Start_Date__c),
            endDateFormatted: this.formatDate(r.End_Date__c),
            startSessionDisplay: startSession,
            endSessionDisplay: endSession,
            approvalDateFormatted: r.Approval_Date__c ? this.formatDate(r.Approval_Date__c) : '-',
            commentsDisplay: r.Comments__c || '-'
        };
    }

    // ── Utility Methods ──────────────────────────────────────

    formatDate(dateStr) {
        if (!dateStr) return '-';
        const d = new Date(dateStr + 'T00:00:00');
        if (isNaN(d.getTime())) return dateStr;
        const options = { day: '2-digit', month: 'short', year: 'numeric' };
        return d.toLocaleDateString('en-IN', options);
    }

    formatDateRangeWithSession(startStr, startSession, endStr, endSession) {
        const start = this.formatDate(startStr);
        const end = this.formatDate(endStr);
        const sLabel = startSession === 'Session 2' ? ' (S2)' : ' (S1)';
        const eLabel = endSession === 'Session 2' ? ' (S2)' : ' (S1)';
        if (start === end) {
            if (startSession === endSession) return start + sLabel;
            return start + ' (S1 - S2)';
        }
        return start + sLabel + ' - ' + end + eLabel;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return 'Unknown error';
    }
}