/**
 * @description Expense Approval LWC for managers and finance approvers.
 *              Features per-line-item approval with inline amount editing,
 *              file preview, select-all checkboxes, and multi-level workflow.
 *
 * @author  SFA Development Team
 * @date    2026
 */
import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getExpenseForApproval from '@salesforce/apex/ExpenseController.getExpenseForApproval';
import approveExpenseItems from '@salesforce/apex/ExpenseController.approveExpenseItems';
import rejectExpenseItems from '@salesforce/apex/ExpenseController.rejectExpenseItems';
import updateApprovedAmounts from '@salesforce/apex/ExpenseController.updateApprovedAmounts';
import approveReport from '@salesforce/apex/ExpenseController.approveReport';
import rejectReport from '@salesforce/apex/ExpenseController.rejectReport';

export default class ExpenseApproval extends NavigationMixin(LightningElement) {
    @api recordId;

    @track expense = {};
    @track items = [];
    @track filesByItem = {};
    @track isLoading = false;
    @track errorMessage = '';
    @track successMessage = '';
    @track selectAll = false;

    // Action modal
    @track showActionModal = false;
    @track actionType = '';
    @track actionRemarks = '';

    connectedCallback() {
        if (this.recordId) {
            this.loadData();
        }
    }

    async loadData() {
        try {
            this.isLoading = true;
            const data = await getExpenseForApproval({ expenseId: this.recordId });

            this.expense = data.expense || {};
            const rawItems = data.items || [];
            const files = data.files || [];

            // Build file map
            this.filesByItem = {};
            files.forEach(f => {
                if (!this.filesByItem[f.expenseItemId]) {
                    this.filesByItem[f.expenseItemId] = [];
                }
                this.filesByItem[f.expenseItemId].push(f);
            });

            // Process items for display
            this.items = rawItems.map(item => this.processItem(item));
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    processItem(item) {
        const files = this.filesByItem[item.Id] || [];
        const isEditable = this.isApprover && (
            item.Approval_Status__c === 'Pending' ||
            item.Approval_Status__c === 'L1 Approved'
        );

        return {
            id: item.Id,
            key: item.Id,
            date: item.Expense_Date__c,
            expenseType: item.Expense_Type__c,
            category: item.Expense_Category__c,
            rateType: item.Rate_Type__c,
            fromLocation: item.From_Location__c || '',
            toLocation: item.To_Location__c || '',
            gpsDistance: item.GPS_Distance_KM__c || 0,
            manualDistance: item.Manual_Distance_KM__c || 0,
            eligibleAmount: item.Eligible_Amount__c || 0,
            claimedAmount: item.Claimed_Amount__c || 0,
            approvedAmount: item.Approved_Amount__c != null ? item.Approved_Amount__c : item.Claimed_Amount__c,
            systemCalcAmount: item.System_Calculated_Amount__c || 0,
            notes: item.Notes__c || '',
            vehicleType: item.Vehicle_Type__c || '',
            travelMode: item.Travel_Mode__c || '',
            city: item.City__c || '',
            approvalStatus: item.Approval_Status__c || 'Not Submitted',
            approverComments: item.Approver_Comments__c || '',
            inlineComment: '',
            showInlineComment: false,
            isEditable: isEditable,
            selected: false,
            files: files,
            hasFiles: files.length > 0,
            fileCount: files.length,
            statusClass: this.getStatusClass(item.Approval_Status__c),
            rowClass: isEditable ? 'highlight-row' : '',
            exceedsClaimed: false,
            claimedExceedsSystem: (item.Claimed_Amount__c || 0) > (item.System_Calculated_Amount__c || 0) && (item.System_Calculated_Amount__c || 0) > 0
        };
    }

    getStatusClass(status) {
        if (status === 'Pending') return 'status-badge-sm status-pending';
        if (status === 'L1 Approved') return 'status-badge-sm status-l1';
        if (status === 'L2 Approved') return 'status-badge-sm status-l2';
        if (status === 'Finance Approved') return 'status-badge-sm status-finance';
        if (status === 'Rejected') return 'status-badge-sm status-rejected';
        return 'status-badge-sm';
    }

    get isApprover() {
        const status = this.expense.Status__c;
        return status === 'Submitted' || status === 'Manager Approved';
    }

    get isManagerLevel() {
        return this.expense.Status__c === 'Submitted';
    }

    get isFinanceLevel() {
        return this.expense.Status__c === 'Manager Approved';
    }

    get approvalLevel() {
        return this.isManagerLevel ? 'manager' : 'finance';
    }

    get employeeName() {
        const emp = this.expense.Employee__r;
        return emp ? emp.First_Name__c + ' ' + emp.Last_Name__c : '';
    }

    get employeeBand() {
        return this.expense.Employee__r ? this.expense.Employee__r.Band__c : '';
    }

    get totalClaimed() { return this.expense.Total_Claimed__c || 0; }
    get totalApproved() {
        return this.items.reduce((sum, i) => sum + (i.approvedAmount || 0), 0);
    }
    get totalEligible() { return this.expense.Total_Eligible__c || 0; }

    get selectedCount() {
        return this.items.filter(i => i.selected).length;
    }

    get hasSelected() {
        return this.selectedCount > 0;
    }

    get statusBadgeClass() {
        const s = this.expense.Status__c;
        if (s === 'Submitted') return 'exp-status-badge exp-status-submitted';
        if (s === 'Manager Approved') return 'exp-status-badge exp-status-approved';
        if (s === 'Finance Approved') return 'exp-status-badge exp-status-finance';
        if (s === 'Rejected') return 'exp-status-badge exp-status-rejected';
        return 'exp-status-badge';
    }

    // ── Selection ────────────────────────────────────────────────
    handleSelectAll(event) {
        this.selectAll = event.target.checked;
        this.items = this.items.map(item => ({
            ...item,
            selected: item.isEditable ? this.selectAll : item.selected
        }));
    }

    handleSelectItem(event) {
        const itemId = event.currentTarget.dataset.id;
        const checked = event.target.checked;
        this.items = this.items.map(item => {
            if (item.id === itemId) {
                return { ...item, selected: checked };
            }
            return item;
        });
        this.selectAll = this.items.filter(i => i.isEditable).every(i => i.selected);
    }

    // ── Inline Amount Edit ───────────────────────────────────────
    handleAmountChange(event) {
        const itemId = event.currentTarget.dataset.id;
        const value = event.detail.value ? parseFloat(event.detail.value) : 0;
        this.items = this.items.map(item => {
            if (item.id === itemId) {
                return {
                    ...item,
                    approvedAmount: value,
                    exceedsClaimed: value > item.claimedAmount
                };
            }
            return item;
        });
    }

    async handleSaveAmounts() {
        const amountsMap = {};
        this.items.forEach(item => {
            if (item.isEditable && item.approvedAmount != null) {
                amountsMap[item.id] = item.approvedAmount;
            }
        });

        if (Object.keys(amountsMap).length === 0) return;

        try {
            this.isLoading = true;
            await updateApprovedAmounts({
                itemAmountsJson: JSON.stringify(amountsMap)
            });
            this.showSuccess('Approved amounts updated.');
            await this.loadData();
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ── File Preview ─────────────────────────────────────────────
    handlePreviewFile(event) {
        const docId = event.currentTarget.dataset.docid;
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: {
                pageName: 'filePreview'
            },
            state: {
                selectedRecordId: docId
            }
        });
    }

    // ── Approve / Reject ─────────────────────────────────────────
    handleApproveSelected() {
        this.actionType = 'approve';
        this.actionRemarks = '';
        this.showActionModal = true;
    }

    handleRejectSelected() {
        this.actionType = 'reject';
        this.actionRemarks = '';
        this.showActionModal = true;
    }

    handleApproveAll() {
        this.actionType = 'approveAll';
        this.actionRemarks = '';
        this.showActionModal = true;
    }

    handleRejectAll() {
        this.actionType = 'rejectAll';
        this.actionRemarks = '';
        this.showActionModal = true;
    }

    handleActionRemarksChange(event) {
        this.actionRemarks = event.detail.value;
    }

    closeActionModal() {
        this.showActionModal = false;
    }

    async handleConfirmAction() {
        try {
            this.isLoading = true;

            if (this.actionType === 'approve') {
                const selectedIds = this.items.filter(i => i.selected).map(i => i.id);
                if (selectedIds.length === 0) {
                    this.showError({ message: 'No items selected.' });
                    this.isLoading = false;
                    return;
                }
                await approveExpenseItems({
                    itemIds: selectedIds,
                    remarks: this.actionRemarks,
                    level: this.approvalLevel
                });
                this.showSuccess(selectedIds.length + ' item(s) approved.');
            } else if (this.actionType === 'reject') {
                if (!this.actionRemarks) {
                    this.showError({ message: 'Rejection reason is required.' });
                    this.isLoading = false;
                    return;
                }
                const selectedIds = this.items.filter(i => i.selected).map(i => i.id);
                if (selectedIds.length === 0) {
                    this.showError({ message: 'No items selected.' });
                    this.isLoading = false;
                    return;
                }
                await rejectExpenseItems({
                    itemIds: selectedIds,
                    reason: this.actionRemarks,
                    level: this.approvalLevel
                });
                this.showSuccess(selectedIds.length + ' item(s) rejected.');
            } else if (this.actionType === 'approveAll') {
                await approveReport({
                    expenseId: this.recordId,
                    remarks: this.actionRemarks,
                    level: this.approvalLevel
                });
                this.showSuccess('Expense report approved.');
            } else if (this.actionType === 'rejectAll') {
                if (!this.actionRemarks) {
                    this.showError({ message: 'Rejection reason is required.' });
                    this.isLoading = false;
                    return;
                }
                await rejectReport({
                    expenseId: this.recordId,
                    reason: this.actionRemarks,
                    level: this.approvalLevel
                });
                this.showSuccess('Expense report rejected.');
            }

            this.showActionModal = false;
            await this.loadData();
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    get actionModalTitle() {
        if (this.actionType === 'approve') return 'Approve Selected Items';
        if (this.actionType === 'reject') return 'Reject Selected Items';
        if (this.actionType === 'approveAll') return 'Approve Entire Report';
        if (this.actionType === 'rejectAll') return 'Reject Entire Report';
        return 'Confirm';
    }

    get actionConfirmLabel() {
        if (this.actionType === 'approve' || this.actionType === 'approveAll') return 'Approve';
        return 'Reject';
    }

    get actionConfirmVariant() {
        return this.actionType.includes('reject') ? 'destructive' : 'brand';
    }

    // ── Inline Comments ─────────────────────────────────────────
    handleToggleInlineComment(event) {
        const itemId = event.currentTarget.dataset.id;
        this.items = this.items.map(item => {
            if (item.id === itemId) {
                return { ...item, showInlineComment: !item.showInlineComment };
            }
            return item;
        });
    }

    handleInlineCommentChange(event) {
        const itemId = event.currentTarget.dataset.id;
        const value = event.detail.value;
        this.items = this.items.map(item => {
            if (item.id === itemId) {
                return { ...item, inlineComment: value };
            }
            return item;
        });
    }

    // ── Helpers ──────────────────────────────────────────────────
    showError(e) {
        let msg = 'An error occurred.';
        if (e && e.body && e.body.message) msg = e.body.message;
        else if (e && e.message) msg = e.message;
        this.errorMessage = msg;
        this.successMessage = '';
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.errorMessage = ''; }, 6000);
    }

    showSuccess(msg) {
        this.successMessage = msg;
        this.errorMessage = '';
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.successMessage = ''; }, 4000);
    }
}