import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import Id from '@salesforce/user/Id';

import getLeaveRequests from '@salesforce/apex/LeaveRequestController.getLeaveRequests';
import getTeamLeaveRequests from '@salesforce/apex/LeaveRequestController.getTeamLeaveRequests';
import saveLeaveRequest from '@salesforce/apex/LeaveRequestController.saveLeaveRequest';
import approveLeaveRequest from '@salesforce/apex/LeaveRequestController.approveLeaveRequest';
import rejectLeaveRequest from '@salesforce/apex/LeaveRequestController.rejectLeaveRequest';
import cancelLeaveRequest from '@salesforce/apex/LeaveRequestController.cancelLeaveRequest';
import getLeaveBalance from '@salesforce/apex/LeaveRequestController.getLeaveBalance';
import getLeavesSummary from '@salesforce/apex/LeaveRequestController.getLeavesSummary';
import getUpcomingLeaves from '@salesforce/apex/LeaveRequestController.getUpcomingLeaves';
import getTeamLeavesOnDate from '@salesforce/apex/LeaveRequestController.getTeamLeavesOnDate';
import checkIsManager from '@salesforce/apex/LeaveRequestController.checkIsManager';
import getPendingApprovalsForManager from '@salesforce/apex/LeaveRequestController.getPendingApprovalsForManager';
import getApprovalHistoryForManager from '@salesforce/apex/LeaveRequestController.getApprovalHistoryForManager';

const RING_RADIUS = 30;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;

const LEAVE_TYPE_CONFIG = {
    'Casual Leave': { short: 'CL', color: '#0176d3', bgColor: '#e8f4fd', key: 'CL' },
    'Sick Leave': { short: 'SL', color: '#2e844a', bgColor: '#e6f7e9', key: 'SL' },
    'Earned Leave': { short: 'EL', color: '#7b61ff', bgColor: '#f0ebff', key: 'EL' },
    'Compensatory Off': { short: 'CO', color: '#dd7a01', bgColor: '#fff8e1', key: 'CO' }
};

const STATUS_CONFIG = {
    'Pending': { class: 'status-badge status-pending', icon: 'utility:clock', variant: 'warning' },
    'Submitted': { class: 'status-badge status-submitted', icon: 'utility:routing_offline', variant: 'warning' },
    'Approved': { class: 'status-badge status-approved', icon: 'utility:check', variant: 'success' },
    'Rejected': { class: 'status-badge status-rejected', icon: 'utility:close', variant: 'error' },
    'Cancelled': { class: 'status-badge status-cancelled', icon: 'utility:ban', variant: 'default' }
};

const LEAVE_TYPE_OPTIONS = [
    { label: 'Casual Leave', value: 'Casual Leave' },
    { label: 'Sick Leave', value: 'Sick Leave' },
    { label: 'Earned Leave', value: 'Earned Leave' },
    { label: 'Compensatory Off', value: 'Compensatory Off' }
];

const SESSION_OPTIONS = [
    { label: 'Session 1', value: 'Session 1' },
    { label: 'Session 2', value: 'Session 2' }
];

export default class LeaveManager extends LightningElement {
    currentUserId = Id;

    // View state
    @track activeView = 'my-leaves';
    @track selectedYear = new Date().getFullYear().toString();
    @track selectedStatus = 'All';
    @track isManager = false;

    // Data
    @track leaveRequests = [];
    @track teamRequests = [];
    @track recentDecisions = [];
    @track leaveBalance = {};
    @track leaveSummary = {};
    @track upcomingLeaves = [];

    // UI state
    isLoading = false;
    @track expandedLeaveId = null;
    @track expandedTeamRowId = null;
    @track teamComments = {};

    // Apply leave modal
    showApplyModal = false;
    @track leaveForm = {
        Leave_Type__c: '',
        Start_Date__c: '',
        Start_Session__c: 'Session 1',
        End_Date__c: '',
        End_Session__c: 'Session 2',
        Reason__c: ''
    };

    // Detail modal
    showDetailModal = false;
    @track selectedLeave = null;

    // Options
    leaveTypeOptions = LEAVE_TYPE_OPTIONS;
    sessionOptions = SESSION_OPTIONS;

    get yearOptions() {
        const currentYear = new Date().getFullYear();
        return [
            { label: String(currentYear), value: String(currentYear) },
            { label: String(currentYear - 1), value: String(currentYear - 1) },
            { label: String(currentYear + 1), value: String(currentYear + 1) }
        ];
    }

    get statusFilters() {
        const counts = { All: this.leaveRequests.length };
        this.leaveRequests.forEach(lr => {
            const s = lr.Status__c || 'Pending';
            counts[s] = (counts[s] || 0) + 1;
        });

        return ['All', 'Submitted', 'Pending', 'Approved', 'Rejected', 'Cancelled'].map(status => ({
            label: status,
            value: status,
            count: counts[status] || 0,
            pillClass: this.selectedStatus === status
                ? 'filter-pill filter-pill-active'
                : 'filter-pill'
        }));
    }

    get filteredLeaveRequests() {
        if (this.selectedStatus === 'All') {
            return this.processedLeaveRequests;
        }
        return this.processedLeaveRequests.filter(lr => lr.Status__c === this.selectedStatus);
    }

    get processedLeaveRequests() {
        return this.leaveRequests.map(lr => this.enrichLeaveRequest(lr));
    }

    get hasLeaveRequests() {
        return this.filteredLeaveRequests.length > 0;
    }

    // Team view getters
    get pendingTeamRequests() {
        return this.teamRequests
            .filter(tr => tr.Status__c === 'Pending' || tr.Status__c === 'Submitted')
            .map(tr => this.enrichTeamRequest(tr));
    }

    get pendingTeamCount() {
        return this.pendingTeamRequests.length;
    }

    get hasPendingTeamRequests() {
        return this.pendingTeamRequests.length > 0;
    }

    get processedRecentDecisions() {
        return this.recentDecisions.map(tr => this.enrichTeamRequest(tr));
    }

    get hasRecentDecisions() {
        return this.recentDecisions.length > 0;
    }

    // View toggles
    get isMyLeavesView() {
        return this.activeView === 'my-leaves';
    }

    get isTeamView() {
        return this.activeView === 'team';
    }

    get myLeavesTabClass() {
        return this.activeView === 'my-leaves'
            ? 'view-tab view-tab-active'
            : 'view-tab';
    }

    get teamTabClass() {
        return this.activeView === 'team'
            ? 'view-tab view-tab-active'
            : 'view-tab';
    }

    // Balance cards — uses detailed Leave_Balance__c data when available
    get balanceCards() {
        const colorMap = {
            'Casual Leave': '#0176d3', 'Sick Leave': '#2e844a',
            'Earned Leave': '#7b61ff', 'Compensatory Off': '#dd7a01',
            'Maternity Leave': '#e65100', 'Paternity Leave': '#00796b',
            'Loss of Pay': '#c23934'
        };
        const shortMap = {
            'Casual Leave': 'CL', 'Sick Leave': 'SL',
            'Earned Leave': 'EL', 'Compensatory Off': 'CO',
            'Maternity Leave': 'ML', 'Paternity Leave': 'PL',
            'Loss of Pay': 'LOP'
        };

        // If we have detailed balance data, use it
        if (this.leaveBalanceDetails && this.leaveBalanceDetails.length > 0) {
            return this.leaveBalanceDetails.map(lb => {
                const entitled = lb.entitled || 0;
                const accrued = lb.accrued || 0;
                const carryFwd = lb.carryForward || 0;
                const used = lb.used || 0;
                const pending = lb.pending || 0;
                const available = lb.available || 0;
                const totalPool = accrued + carryFwd;
                const percent = totalPool > 0 ? Math.round((available / totalPool) * 100) : 0;
                const cappedPercent = Math.min(Math.max(percent, 0), 100);
                const dashOffset = RING_CIRCUMFERENCE - (cappedPercent / 100) * RING_CIRCUMFERENCE;
                const color = colorMap[lb.leaveType] || '#54698d';

                return {
                    key: shortMap[lb.leaveType] || lb.leaveType,
                    label: lb.leaveType,
                    available: available,
                    total: totalPool,
                    entitled: entitled,
                    accrued: accrued,
                    carryForward: carryFwd,
                    used: used,
                    pending: pending,
                    percent: percent,
                    color: color,
                    ringDashArray: RING_CIRCUMFERENCE.toFixed(2),
                    ringDashOffset: dashOffset.toFixed(2),
                    ringStyle: 'stroke: ' + color,
                    hasDetails: true
                };
            });
        }

        // Fallback: use simple balance map (backward compatible)
        const configs = [
            { type: 'Casual Leave', key: 'CL', color: '#0176d3', label: 'Casual Leave' },
            { type: 'Sick Leave', key: 'SL', color: '#2e844a', label: 'Sick Leave' },
            { type: 'Earned Leave', key: 'EL', color: '#7b61ff', label: 'Earned Leave' },
            { type: 'Compensatory Off', key: 'CO', color: '#dd7a01', label: 'Comp Off' }
        ];

        return configs.map(cfg => {
            const available = this.leaveBalance[cfg.key] || 0;
            const total = this.getTotalForType(cfg.key);
            const used = Math.max(total - available, 0);
            const percent = total > 0 ? Math.round((available / total) * 100) : 0;
            const cappedPercent = Math.min(percent, 100);
            const dashOffset = RING_CIRCUMFERENCE - (cappedPercent / 100) * RING_CIRCUMFERENCE;

            return {
                key: cfg.key,
                label: cfg.label,
                available: available,
                total: total,
                used: used,
                pending: 0,
                percent: percent,
                color: cfg.color,
                ringDashArray: RING_CIRCUMFERENCE.toFixed(2),
                ringDashOffset: dashOffset.toFixed(2),
                ringStyle: 'stroke: ' + cfg.color,
                hasDetails: false
            };
        });
    }

    // Apply leave modal getters
    get calculatedDays() {
        if (!this.leaveForm.Start_Date__c || !this.leaveForm.End_Date__c) {
            return 0;
        }
        const startSession = this.leaveForm.Start_Session__c || 'Session 1';
        const endSession = this.leaveForm.End_Session__c || 'Session 2';

        // Validate: same date, start Session 2 and end Session 1 is invalid
        if (this.leaveForm.Start_Date__c === this.leaveForm.End_Date__c &&
            startSession === 'Session 2' && endSession === 'Session 1') {
            return 0;
        }

        let days = this.calculateBusinessDays(this.leaveForm.Start_Date__c, this.leaveForm.End_Date__c);
        if (days <= 0) return 0;

        // Adjust for sessions
        if (startSession === 'Session 2') {
            days -= 0.5;
        }
        if (endSession === 'Session 1') {
            days -= 0.5;
        }

        return days > 0 ? days : 0;
    }

    get calculatedDaysDisplay() {
        const days = this.calculatedDays;
        if (days === 0) return '-';
        return days + (days === 1 || days === 0.5 ? ' day' : ' days');
    }

    get selectedTypeBalance() {
        if (!this.leaveForm.Leave_Type__c) return null;
        const cfg = LEAVE_TYPE_CONFIG[this.leaveForm.Leave_Type__c];
        if (!cfg) return null;
        const available = this.leaveBalance[cfg.key] || 0;
        return {
            available: available,
            type: this.leaveForm.Leave_Type__c,
            hasBalance: available > 0,
            balanceClass: available > 0 ? 'balance-indicator balance-ok' : 'balance-indicator balance-low'
        };
    }

    get isApplyDisabled() {
        return !this.leaveForm.Leave_Type__c ||
            !this.leaveForm.Start_Date__c ||
            !this.leaveForm.End_Date__c ||
            !this.leaveForm.Reason__c ||
            this.calculatedDays <= 0;
    }

    get isInvalidSessionCombo() {
        return this.leaveForm.Start_Date__c &&
            this.leaveForm.End_Date__c &&
            this.leaveForm.Start_Date__c === this.leaveForm.End_Date__c &&
            this.leaveForm.Start_Session__c === 'Session 2' &&
            this.leaveForm.End_Session__c === 'Session 1';
    }

    // Detail modal getters
    get detailLeave() {
        if (!this.selectedLeave) return null;
        return this.enrichLeaveRequest(this.selectedLeave);
    }

    get detailTimelineSteps() {
        if (!this.selectedLeave) return [];
        const isPendingOrSubmitted = this.selectedLeave.Status__c === 'Pending' || this.selectedLeave.Status__c === 'Submitted';
        const steps = [
            {
                label: 'Applied',
                isComplete: true,
                isCurrent: false,
                stepClass: 'timeline-step step-complete'
            },
            {
                label: this.selectedLeave.Status__c === 'Submitted' ? 'Submitted for Approval' : 'Pending Review',
                isComplete: !isPendingOrSubmitted,
                isCurrent: isPendingOrSubmitted,
                stepClass: isPendingOrSubmitted
                    ? 'timeline-step step-current'
                    : 'timeline-step step-complete'
            }
        ];

        if (this.selectedLeave.Status__c === 'Approved') {
            steps.push({
                label: 'Approved',
                isComplete: true,
                isCurrent: false,
                stepClass: 'timeline-step step-complete step-success'
            });
        } else if (this.selectedLeave.Status__c === 'Rejected') {
            steps.push({
                label: 'Rejected',
                isComplete: true,
                isCurrent: false,
                stepClass: 'timeline-step step-complete step-error'
            });
        } else if (this.selectedLeave.Status__c === 'Cancelled') {
            steps.push({
                label: 'Cancelled',
                isComplete: true,
                isCurrent: false,
                stepClass: 'timeline-step step-complete step-cancelled'
            });
        } else {
            steps.push({
                label: 'Decision',
                isComplete: false,
                isCurrent: false,
                stepClass: 'timeline-step step-pending'
            });
        }

        return steps;
    }

    get hasApprovalInfo() {
        return this.selectedLeave && this.selectedLeave.Approved_By__c != null;
    }

    get approvalInfoLabel() {
        if (!this.selectedLeave) return 'Approval Information';
        if (this.selectedLeave.Status__c === 'Submitted' || this.selectedLeave.Status__c === 'Pending') {
            return 'Pending Approval From';
        }
        return 'Approval Information';
    }

    get approverFieldLabel() {
        if (!this.selectedLeave) return 'Approved/Rejected By';
        if (this.selectedLeave.Status__c === 'Submitted' || this.selectedLeave.Status__c === 'Pending') {
            return 'Assigned Approver';
        }
        return 'Approved/Rejected By';
    }

    get approverName() {
        if (!this.selectedLeave || !this.selectedLeave.Approved_By__r) return '-';
        return this.selectedLeave.Approved_By__r.Name;
    }

    get approvalDateFormatted() {
        if (!this.selectedLeave || !this.selectedLeave.Approval_Date__c) return '-';
        return this.formatDate(this.selectedLeave.Approval_Date__c);
    }

    get showDecisionDate() {
        return this.selectedLeave &&
            (this.selectedLeave.Status__c === 'Approved' || this.selectedLeave.Status__c === 'Rejected');
    }

    get detailComments() {
        return this.selectedLeave ? (this.selectedLeave.Comments__c || '-') : '-';
    }

    get canCancelSelected() {
        return this.selectedLeave &&
            (this.selectedLeave.Status__c === 'Pending' || this.selectedLeave.Status__c === 'Submitted' || this.selectedLeave.Status__c === 'Approved');
    }

    // ── Lifecycle ───────────────────────────────────────────

    connectedCallback() {
        this.loadAllData();
    }

    async loadAllData() {
        this.isLoading = true;
        try {
            // Check manager status first, then load everything
            await this.checkManagerStatus();
            await Promise.all([
                this.loadLeaveBalance(),
                this.loadLeaveRequests(),
                this.loadLeaveSummary(),
                this.loadUpcomingLeaves(),
                this.isManager ? this.loadTeamRequests() : Promise.resolve()
            ]);
        } catch (error) {
            console.error('Leave Manager load error:', error);
        } finally {
            this.isLoading = false;
        }
    }

    async checkManagerStatus() {
        try {
            this.isManager = await checkIsManager({ userId: this.currentUserId });
        } catch (error) {
            console.error('Error checking manager status:', error);
            this.isManager = false;
        }
    }

    // ── Data Loading ────────────────────────────────────────

    @track leaveBalanceDetails = []; // Full breakdown from Leave_Balance__c

    async loadLeaveBalance() {
        try {
            const result = await getLeaveBalance({ userId: this.currentUserId });
            if (result) {
                this.leaveBalance = result.simple || {};
                this.leaveBalanceDetails = result.balances || [];
            } else {
                this.leaveBalance = {};
                this.leaveBalanceDetails = [];
            }
        } catch (error) {
            console.error('Error loading leave balance:', error);
        }
    }

    async loadLeaveRequests() {
        try {
            const result = await getLeaveRequests({
                userId: this.currentUserId,
                status: '',
                year: parseInt(this.selectedYear, 10)
            });
            this.leaveRequests = result || [];
        } catch (error) {
            console.error('Error loading leave requests:', error);
        }
    }

    async loadLeaveSummary() {
        try {
            const result = await getLeavesSummary({
                userId: this.currentUserId,
                year: parseInt(this.selectedYear, 10)
            });
            this.leaveSummary = result || {};
        } catch (error) {
            console.error('Error loading leave summary:', error);
        }
    }

    async loadUpcomingLeaves() {
        try {
            const result = await getUpcomingLeaves({
                userId: this.currentUserId,
                limitCount: 5
            });
            this.upcomingLeaves = result || [];
        } catch (error) {
            console.error('Error loading upcoming leaves:', error);
        }
    }

    async loadTeamRequests() {
        try {
            // Load pending approvals assigned to this manager
            const pendingResult = await getPendingApprovalsForManager({
                managerId: this.currentUserId
            });
            this.teamRequests = pendingResult || [];

            // Load recent decisions (approved/rejected) by this manager
            const recentResult = await getApprovalHistoryForManager({
                managerId: this.currentUserId
            });
            this.recentDecisions = (recentResult || []).slice(0, 10);
        } catch (error) {
            console.error('Error loading team requests:', error);
        }
    }

    // ── View Handlers ───────────────────────────────────────

    handleMyLeavesTab() {
        this.activeView = 'my-leaves';
    }

    handleTeamTab() {
        this.activeView = 'team';
    }

    handleYearChange(event) {
        this.selectedYear = event.detail.value;
        this.loadLeaveRequests();
        this.loadLeaveSummary();
    }

    handleStatusFilter(event) {
        this.selectedStatus = event.currentTarget.dataset.status;
    }

    // ── Leave Card Interaction ──────────────────────────────

    handleToggleExpand(event) {
        const leaveId = event.currentTarget.dataset.id;
        this.expandedLeaveId = this.expandedLeaveId === leaveId ? null : leaveId;
    }

    handleViewDetail(event) {
        event.stopPropagation();
        const leaveId = event.currentTarget.dataset.id;
        const leave = this.leaveRequests.find(lr => lr.Id === leaveId);
        if (leave) {
            this.selectedLeave = leave;
            this.showDetailModal = true;
        }
    }

    handleCloseDetailModal() {
        this.showDetailModal = false;
        this.selectedLeave = null;
    }

    // ── Cancel Leave ────────────────────────────────────────

    async handleCancelLeave(event) {
        event.stopPropagation();
        const leaveId = event.currentTarget.dataset.id;
        this.isLoading = true;
        try {
            await cancelLeaveRequest({ leaveRequestId: leaveId });
            this.showToast('Success', 'Leave request cancelled successfully.', 'success');
            await Promise.all([
                this.loadLeaveRequests(),
                this.loadLeaveBalance(),
                this.loadLeaveSummary()
            ]);
        } catch (error) {
            this.showToast('Error', 'Failed to cancel leave: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleCancelFromDetail() {
        if (!this.selectedLeave) return;
        this.isLoading = true;
        try {
            await cancelLeaveRequest({ leaveRequestId: this.selectedLeave.Id });
            this.showToast('Success', 'Leave request cancelled successfully.', 'success');
            this.showDetailModal = false;
            this.selectedLeave = null;
            await Promise.all([
                this.loadLeaveRequests(),
                this.loadLeaveBalance(),
                this.loadLeaveSummary()
            ]);
        } catch (error) {
            this.showToast('Error', 'Failed to cancel leave: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Apply Leave Modal ───────────────────────────────────

    handleOpenApplyModal() {
        this.leaveForm = {
            Leave_Type__c: '',
            Start_Date__c: '',
            Start_Session__c: 'Session 1',
            End_Date__c: '',
            End_Session__c: 'Session 2',
            Reason__c: ''
        };
        this.showApplyModal = true;
    }

    handleCloseApplyModal() {
        this.showApplyModal = false;
    }

    handleLeaveFormChange(event) {
        const field = event.target.dataset.field;
        this.leaveForm = { ...this.leaveForm, [field]: event.target.value };
    }

    async handleSubmitLeave() {
        // Validate
        if (!this.leaveForm.Leave_Type__c) {
            this.showToast('Error', 'Please select a leave type.', 'error');
            return;
        }
        if (!this.leaveForm.Start_Date__c || !this.leaveForm.End_Date__c) {
            this.showToast('Error', 'Please select start and end dates.', 'error');
            return;
        }
        if (new Date(this.leaveForm.End_Date__c) < new Date(this.leaveForm.Start_Date__c)) {
            this.showToast('Error', 'End date cannot be before start date.', 'error');
            return;
        }
        if (this.isInvalidSessionCombo) {
            this.showToast('Error', 'Invalid session selection. End session cannot be Session 1 when start session is Session 2 on the same date.', 'error');
            return;
        }
        if (!this.leaveForm.Reason__c || !this.leaveForm.Reason__c.trim()) {
            this.showToast('Error', 'Please provide a reason.', 'error');
            return;
        }

        const days = this.calculatedDays;
        const cfg = LEAVE_TYPE_CONFIG[this.leaveForm.Leave_Type__c];
        if (cfg) {
            const available = this.leaveBalance[cfg.key] || 0;
            if (days > available) {
                this.showToast('Error',
                    'Insufficient balance. Available: ' + available + ' days, Requested: ' + days + ' days.',
                    'error'
                );
                return;
            }
        }

        this.isLoading = true;
        try {
            const leaveRecord = {
                Employee__c: this.currentUserId,
                Leave_Type__c: this.leaveForm.Leave_Type__c,
                Start_Date__c: this.leaveForm.Start_Date__c,
                Start_Session__c: this.leaveForm.Start_Session__c,
                End_Date__c: this.leaveForm.End_Date__c,
                End_Session__c: this.leaveForm.End_Session__c,
                Number_of_Days__c: days,
                Reason__c: this.leaveForm.Reason__c.trim(),
                Status__c: 'Pending'
            };

            await saveLeaveRequest({ leaveRequest: leaveRecord });
            this.showToast('Success', 'Leave request submitted for approval successfully.', 'success');
            this.showApplyModal = false;
            await Promise.all([
                this.loadLeaveRequests(),
                this.loadLeaveBalance(),
                this.loadLeaveSummary()
            ]);
        } catch (error) {
            this.showToast('Error', 'Failed to submit leave: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Team Approval Actions ───────────────────────────────

    handleToggleTeamRow(event) {
        const rowId = event.currentTarget.dataset.id;
        this.expandedTeamRowId = this.expandedTeamRowId === rowId ? null : rowId;
    }

    handleTeamCommentChange(event) {
        const leaveId = event.target.dataset.id;
        this.teamComments = { ...this.teamComments, [leaveId]: event.target.value };
    }

    async handleApproveLeave(event) {
        event.stopPropagation();
        const leaveId = event.currentTarget.dataset.id;
        const comments = this.teamComments[leaveId] || '';
        this.isLoading = true;
        try {
            await approveLeaveRequest({
                leaveRequestId: leaveId,
                comments: comments
            });
            this.showToast('Success', 'Leave request approved.', 'success');
            this.expandedTeamRowId = null;
            this.teamComments = { ...this.teamComments, [leaveId]: '' };
            await this.loadTeamRequests();
        } catch (error) {
            this.showToast('Error', 'Failed to approve: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleRejectLeave(event) {
        event.stopPropagation();
        const leaveId = event.currentTarget.dataset.id;
        const comments = this.teamComments[leaveId] || '';
        if (!comments.trim()) {
            this.showToast('Error', 'Please provide a reason for rejection.', 'error');
            return;
        }
        this.isLoading = true;
        try {
            await rejectLeaveRequest({
                leaveRequestId: leaveId,
                comments: comments
            });
            this.showToast('Success', 'Leave request rejected.', 'success');
            this.expandedTeamRowId = null;
            this.teamComments = { ...this.teamComments, [leaveId]: '' };
            await this.loadTeamRequests();
        } catch (error) {
            this.showToast('Error', 'Failed to reject: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Data Enrichment Helpers ─────────────────────────────

    enrichLeaveRequest(lr) {
        const typeConfig = LEAVE_TYPE_CONFIG[lr.Leave_Type__c] || {};
        const statusConfig = STATUS_CONFIG[lr.Status__c] || {};
        const isExpanded = this.expandedLeaveId === lr.Id;
        const canCancel = lr.Status__c === 'Pending' || lr.Status__c === 'Submitted' || lr.Status__c === 'Approved';
        const startSession = lr.Start_Session__c || 'Session 1';
        const endSession = lr.End_Session__c || 'Session 2';

        return {
            ...lr,
            typeShort: typeConfig.short || lr.Leave_Type__c,
            typeBadgeClass: 'leave-type-badge',
            typeBadgeStyle: 'background: ' + (typeConfig.bgColor || '#f3f3f3') +
                '; color: ' + (typeConfig.color || '#706e6b'),
            statusBadgeClass: statusConfig.class || 'status-badge',
            dateRange: this.formatDateRangeWithSession(lr.Start_Date__c, startSession, lr.End_Date__c, endSession),
            daysDisplay: lr.Number_of_Days__c + (lr.Number_of_Days__c === 1 || lr.Number_of_Days__c === 0.5 ? ' day' : ' days'),
            reasonPreview: lr.Reason__c ? (lr.Reason__c.length > 60 ? lr.Reason__c.substring(0, 60) + '...' : lr.Reason__c) : '-',
            isExpanded: isExpanded,
            expandIcon: isExpanded ? 'utility:chevronup' : 'utility:chevrondown',
            canCancel: canCancel,
            cardClass: isExpanded ? 'leave-card leave-card-expanded' : 'leave-card',
            startDateFormatted: this.formatDate(lr.Start_Date__c),
            endDateFormatted: this.formatDate(lr.End_Date__c),
            startSessionDisplay: startSession,
            endSessionDisplay: endSession,
            approverName: lr.Approved_By__r ? lr.Approved_By__r.Name : '-',
            approvalDateFormatted: lr.Approval_Date__c ? this.formatDate(lr.Approval_Date__c) : '-',
            commentsDisplay: lr.Comments__c || '-'
        };
    }

    enrichTeamRequest(tr) {
        const typeConfig = LEAVE_TYPE_CONFIG[tr.Leave_Type__c] || {};
        const statusConfig = STATUS_CONFIG[tr.Status__c] || {};
        const isExpanded = this.expandedTeamRowId === tr.Id;
        const startSession = tr.Start_Session__c || 'Session 1';
        const endSession = tr.End_Session__c || 'Session 2';

        return {
            ...tr,
            employeeName: tr.Employee__r ? tr.Employee__r.Name : 'Unknown',
            typeShort: typeConfig.short || tr.Leave_Type__c,
            typeBadgeClass: 'leave-type-badge',
            typeBadgeStyle: 'background: ' + (typeConfig.bgColor || '#f3f3f3') +
                '; color: ' + (typeConfig.color || '#706e6b'),
            statusBadgeClass: statusConfig.class || 'status-badge',
            dateRange: this.formatDateRangeWithSession(tr.Start_Date__c, startSession, tr.End_Date__c, endSession),
            daysDisplay: tr.Number_of_Days__c + (tr.Number_of_Days__c === 1 || tr.Number_of_Days__c === 0.5 ? ' day' : ' days'),
            reasonPreview: tr.Reason__c ? (tr.Reason__c.length > 80 ? tr.Reason__c.substring(0, 80) + '...' : tr.Reason__c) : '-',
            isExpanded: isExpanded,
            rowClass: isExpanded ? 'team-row team-row-expanded' : 'team-row',
            commentValue: this.teamComments[tr.Id] || '',
            approvalDateFormatted: tr.Approval_Date__c ? this.formatDate(tr.Approval_Date__c) : '-'
        };
    }

    // ── Utility Methods ─────────────────────────────────────

    getTotalForType(key) {
        const defaults = { CL: 12, SL: 7, EL: 15, CO: 0 };
        return defaults.hasOwnProperty(key) ? defaults[key] : 12;
    }

    calculateBusinessDays(startStr, endStr) {
        const start = new Date(startStr);
        const end = new Date(endStr);
        if (isNaN(start.getTime()) || isNaN(end.getTime())) return 0;
        if (end < start) return 0;

        let count = 0;
        const current = new Date(start);
        while (current <= end) {
            const day = current.getDay();
            if (day !== 0 && day !== 6) {
                count++;
            }
            current.setDate(current.getDate() + 1);
        }
        return count;
    }

    formatDate(dateStr) {
        if (!dateStr) return '-';
        const d = new Date(dateStr + 'T00:00:00');
        if (isNaN(d.getTime())) return dateStr;
        const options = { day: '2-digit', month: 'short', year: 'numeric' };
        return d.toLocaleDateString('en-IN', options);
    }

    formatDateRange(startStr, endStr) {
        const start = this.formatDate(startStr);
        const end = this.formatDate(endStr);
        if (start === end) return start;
        return start + ' - ' + end;
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