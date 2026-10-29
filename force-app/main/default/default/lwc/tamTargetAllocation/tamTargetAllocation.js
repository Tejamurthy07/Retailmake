import { LightningElement, track, wire } from 'lwc';
import getData from '@salesforce/apex/TAM_TargetAllocation_Controller.getAllData';
import getTargetActuals from '@salesforce/apex/TAM_TargetAllocation_Controller.getTargetActuals';
import getUserTargetActuals from '@salesforce/apex/TAM_TargetAllocation_Controller.getUserTargets';
import saveTargets from '@salesforce/apex/TAM_TargetAllocation_Controller.saveTargets';
import saveAdminTargetActuals from '@salesforce/apex/TAM_TargetAllocation_Controller.saveAdminTargets';
import saveInlineTarget from '@salesforce/apex/TAM_TargetAllocation_Controller.saveInlineTarget';
import syncAchievements from '@salesforce/apex/TAM_TargetAllocation_Controller.syncAchievements';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CurrentPageReference } from 'lightning/navigation';

export default class TamTargetAllocation extends LightningElement {

    // ===== URL PARAMS =====
    @wire(CurrentPageReference)
    wiredCurrentPageRef(result) {
        if (result && result.state) {
            const pid = result.state.c__periodId;
            const eid = result.state.c__ExecutiveId;
            if (pid) this._urlPeriodId = pid;
            if (eid) this._urlExecutiveId = eid;
        }
    }

    _urlPeriodId;
    _urlExecutiveId;

    // ===== STATE =====
    selectedUser = '';
    selectedPeriod = '';
    selectedAdminPeriod = '';
    isLoading = false;
    isPopupLoading = false;
    isAdmin = false;

    @track userOptions = [];
    @track userList = [];
    @track periodOptions = [];
    @track currentPeriodOptions = [];
    @track targetList = [];
    @track curTargets = [];

    // Distribute modal
    @track showDistributeModal = false;
    @track distributionColumns = [];
    @track distributionRows = [];
    @track uniqueTargetCriterias = [];
    @track targetCriteriasWithManagerMap = new Map();
    @track parentSubordinateTotals = new Map();

    // Add target modal
    @track showAddTargetModal = false;
    @track adminTargets = [];
    @track targetCriterias = [];
    @track parentToTotalTargetValueMap = new Map();

    // Inline editing
    @track editingTargetId = null;
    @track editValue = null;

    // ===== LIFECYCLE =====
    connectedCallback() {
        this.fetchAllData();
    }

    fetchAllData() {
        this.isLoading = true;
        getData({})
            .then(result => {
                this.userOptions = this._toOptions(result?.userList, 'Name', 'Id');
                this.userList = result?.userList || [];
                this.periodOptions = this._toOptions(result?.periodsList, 'Name', 'Id');
                this.currentPeriodOptions = this._toOptions(result?.currentPeriods, 'Name', 'Id');

                this.selectedUser = result?.currentUserId || '';
                this.selectedPeriod = result?.period || '';
                this.selectedAdminPeriod = result?.period || '';
                this.isAdmin = result?.isAdmin || false;

                this.targetList = result?.targetActuals || [];
                this._refreshCurrentTargets();
                this._aggregateSubordinateTotals();

                // Apply URL params if present
                if (this._urlPeriodId) {
                    this.selectedPeriod = this._urlPeriodId;
                    this.selectedUser = this._urlExecutiveId || this.selectedUser;
                    this._loadTargetActuals();
                }
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to load data', 'error');
            })
            .finally(() => { this.isLoading = false; });
    }

    // ===== GETTERS =====
    get hasCurrentTargets() {
        return this.curTargets && this.curTargets.length > 0;
    }

    get hasSubordinates() {
        return this.distributionRows && this.distributionRows.length > 0 &&
            this.distributionRows.some(r => r.targets && r.targets.length > 0);
    }

    get hasAdminTargets() {
        return this.adminTargets && this.adminTargets.length > 0;
    }

    // Compute display values with achievement %, progress bars, totals
    get computedTargets() {
        return this.curTargets.map(t => {
            const tv = t.Target_Value__c || 0;
            const av = t.Achievement_Value__c || 0;
            const ttv = t.Teams_Target__c || 0;
            const tav = t.Teams_Achievement__c || 0;
            const totalTarget = tv + ttv;
            const totalAchievement = av + tav;
            const pct = totalTarget > 0 ? Math.round((totalAchievement / totalTarget) * 100) : 0;
            const clampedPct = Math.min(pct, 100);

            let percentClass = 'ta-percent';
            if (pct >= 100) percentClass += ' ta-percent-green';
            else if (pct >= 70) percentClass += ' ta-percent-amber';
            else percentClass += ' ta-percent-red';

            return {
                Id: t.Id,
                criteriaName: t.Target_Criteria__r?.Name || '—',
                targetValue: tv,
                teamsTarget: ttv,
                totalTarget: totalTarget,
                achievementValue: av,
                teamsAchievement: tav,
                totalAchievement: totalAchievement,
                achievementPercent: pct,
                percentClass: percentClass,
                progressStyle: `width: ${clampedPct}%`,
                isEditing: this.editingTargetId === t.Id,
                editValue: this.editingTargetId === t.Id ? this.editValue : tv
            };
        });
    }

    // ===== EVENT HANDLERS =====
    handlePeriodChange(event) {
        this.selectedPeriod = event.target.value;
        this.selectedAdminPeriod = event.target.value;
        this._loadTargetActuals();
    }

    handleUserChange(event) {
        this.selectedUser = event.target.value;
        this._refreshCurrentTargets();
    }

    // ===== INLINE EDITING =====
    handleInlineEdit(event) {
        const id = event.currentTarget.dataset.id;
        const target = this.curTargets.find(t => t.Id === id);
        this.editingTargetId = id;
        this.editValue = target ? target.Target_Value__c : 0;
        // Force re-render
        this.curTargets = [...this.curTargets];
    }

    handleInlineChange(event) {
        this.editValue = Number(event.target.value) || 0;
    }

    handleInlineSave() {
        if (!this.editingTargetId) return;
        const id = this.editingTargetId;
        const val = this.editValue;
        this.editingTargetId = null;
        this.editValue = null;

        // Optimistic update
        this.curTargets = this.curTargets.map(t =>
            t.Id === id ? { ...t, Target_Value__c: val } : t
        );

        saveInlineTarget({ targetId: id, targetValue: val })
            .then(result => {
                // Replace with server response
                this.curTargets = this.curTargets.map(t =>
                    t.Id === result.Id ? { ...result } : t
                );
                this.showToast('Success', 'Target updated', 'success');
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to save', 'error');
                this._loadTargetActuals(); // Reload on error
            });
    }

    // ===== SYNC ACHIEVEMENTS =====
    handleSyncAchievements() {
        if (!this.selectedPeriod) {
            this.showToast('Warning', 'Select a period first', 'warning');
            return;
        }
        this.isLoading = true;
        syncAchievements({ periodId: this.selectedPeriod })
            .then(result => {
                this.showToast('Success', result, 'success');
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => { this.fetchAllData(); }, 4000);
            })
            .catch(e => this.showToast('Error', e?.body?.message || 'Sync failed', 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ===== DISTRIBUTE MODAL =====
    openDistributeModal() {
        this.showDistributeModal = true;

        const subordinates = this.userList.filter(u => u.ManagerId === this.selectedUser);

        const targetListCopy = this.targetList.map(t => ({ ...t }));
        const targetMap = new Map();
        targetListCopy.forEach(t => {
            targetMap.set(t.User__c + t.Target_Criteria__c, t);
        });

        const rows = [];
        for (const user of subordinates) {
            const targets = [];
            for (const criteria of this.uniqueTargetCriterias) {
                const key = user.Id + criteria.Id;
                if (targetMap.has(key)) {
                    targets.push({ ...targetMap.get(key) });
                } else {
                    const parentTarget = this.targetCriteriasWithManagerMap.get(criteria.Id);
                    targets.push({
                        sobjectType: 'Target_Actual__c',
                        Target_Criteria__r: { Id: criteria.Id, Name: criteria.Name },
                        Target_Criteria__c: criteria.Id,
                        Target_Value__c: '',
                        Achievement_Value__c: 0,
                        User__c: user.Id,
                        Parent_Target__c: parentTarget ? parentTarget.Id : null
                    });
                }
            }
            rows.push({ id: user.Id, name: user.Name, targets: targets });
        }

        this.distributionRows = rows;
        this.distributionColumns = this.uniqueTargetCriterias.map(c => ({ Id: c.Id, Name: c.Name }));
    }

    closeDistributeModal() {
        this.showDistributeModal = false;
        this.distributionRows = [];
        this.distributionColumns = [];
    }

    handleDistributeChange(event) {
        const criteriaId = event.target.dataset.targetcriteria;
        const userId = event.target.dataset.userid;
        const newValue = Number(event.target.value) || 0;

        const parentTarget = this.targetCriteriasWithManagerMap.get(criteriaId);
        const parentTargetValue = parentTarget ? (parentTarget.Target_Value__c || 0) : 0;

        // Calculate total across all subordinates for this criteria
        let totalOthers = 0;
        for (const row of this.distributionRows) {
            for (const t of row.targets) {
                if (t.Target_Criteria__c === criteriaId && row.id !== userId) {
                    totalOthers += Number(t.Target_Value__c || 0);
                }
            }
        }

        const newTotal = totalOthers + newValue;

        // Update the row
        this.distributionRows = this.distributionRows.map(row => ({
            ...row,
            targets: row.targets.map(t => {
                if (t.Target_Criteria__c === criteriaId && row.id === userId) {
                    const updated = { ...t, Target_Value__c: newValue };
                    if (newTotal > parentTargetValue) {
                        updated.Max_Value__c = parentTargetValue - totalOthers;
                        updated.Message = `Max allowed: ${parentTargetValue - totalOthers}`;
                    } else {
                        updated.Max_Value__c = undefined;
                        updated.Message = undefined;
                    }
                    return updated;
                }
                return t;
            })
        }));
    }

    saveDistribution() {
        const allTargets = this.distributionRows.flatMap(row => row.targets);
        const invalid = allTargets.filter(t =>
            t.Max_Value__c !== undefined && t.Target_Value__c > t.Max_Value__c
        );

        if (invalid.length > 0) {
            this.showToast('Error', 'Some targets exceed the allowed maximum', 'error');
            return;
        }

        this.isLoading = true;
        this.showDistributeModal = false;

        saveTargets({ targetList: JSON.stringify(allTargets), selectedPeriod: this.selectedPeriod })
            .then(result => {
                this.targetList = result;
                this._refreshCurrentTargets();
                this._aggregateSubordinateTotals();
                this.showToast('Success', 'Targets distributed successfully', 'success');
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to save', 'error');
            })
            .finally(() => { this.isLoading = false; });
    }

    // ===== ADD TARGET MODAL =====
    openAddTargetModal() {
        this.showAddTargetModal = true;
        this._loadUserTargets(this.selectedAdminPeriod);
    }

    closeAddTargetModal() {
        this.showAddTargetModal = false;
        this.adminTargets = [];
    }

    handleAdminPeriodChange(event) {
        this.selectedAdminPeriod = event.target.value;
        this._loadUserTargets(this.selectedAdminPeriod);
    }

    handleAdminTargetChange(event) {
        const criteriaId = event.target.dataset.targetcriteria;
        const newValue = parseFloat(event.target.value) || 0;
        const targetId = event.target.dataset.id;

        const minValue = this.parentToTotalTargetValueMap.get(targetId) || 0;

        this.adminTargets = this.adminTargets.map(t => {
            if (t.Target_Criteria__c === criteriaId) {
                const updated = { ...t, Target_Value__c: newValue };
                if (newValue < minValue) {
                    updated.Min_Value__c = minValue;
                    updated.Message = `Min value allowed: ${minValue}`;
                }
                return updated;
            }
            return t;
        });
    }

    saveAdminTargets() {
        const invalid = this.adminTargets.filter(t =>
            t.Min_Value__c && t.Target_Value__c < t.Min_Value__c
        );
        if (invalid.length > 0) {
            this.showToast('Error', 'Some targets are below the minimum allowed value', 'error');
            return;
        }

        this.isLoading = true;
        this.showAddTargetModal = false;

        const filtered = this.adminTargets.filter(t => t.Target_Value__c > 0);

        saveAdminTargetActuals({
            targetActuals: filtered,
            selectedAdminPeriod: this.selectedAdminPeriod,
            selectedPeriod: this.selectedPeriod,
            userId: this.selectedUser
        })
            .then(result => {
                this.targetList = result;
                this._refreshCurrentTargets();
                this._aggregateSubordinateTotals();
                this.showToast('Success', 'Targets saved successfully', 'success');
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to save', 'error');
            })
            .finally(() => { this.isLoading = false; });
    }

    // ===== PRIVATE HELPERS =====
    _loadTargetActuals() {
        this.isLoading = true;
        getTargetActuals({ period: this.selectedPeriod, userId: this.selectedUser })
            .then(result => {
                this.targetList = result;
                this._refreshCurrentTargets();
                this._aggregateSubordinateTotals();
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to load targets', 'error');
            })
            .finally(() => { this.isLoading = false; });
    }

    _loadUserTargets(period) {
        this.isPopupLoading = true;
        getUserTargetActuals({ period: period, userId: this.selectedUser })
            .then(result => {
                this.targetCriterias = result?.targetCriterias || [];
                const existingTargets = (result?.targetActuals || []).filter(t => t.User__c === this.selectedUser);
                this.parentToTotalTargetValueMap = new Map(
                    Object.entries(result?.parentToTotalTargetValueMap || {})
                );

                // Build admin targets: existing + new for missing criteria
                const existingMap = new Map();
                existingTargets.forEach(t => existingMap.set(t.Target_Criteria__c, t));

                this.adminTargets = this.targetCriterias.map(c => {
                    if (existingMap.has(c.Id)) {
                        return { ...existingMap.get(c.Id) };
                    }
                    return {
                        sobjectType: 'Target_Actual__c',
                        Target_Criteria__r: { Id: c.Id, Name: c.Name },
                        Target_Criteria__c: c.Id,
                        Target_Value__c: '',
                        Achievement_Value__c: 0,
                        User__c: this.selectedUser
                    };
                });
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to load', 'error');
            })
            .finally(() => { this.isPopupLoading = false; });
    }

    _refreshCurrentTargets() {
        this.curTargets = this.targetList.filter(t => t.User__c === this.selectedUser);

        this.uniqueTargetCriterias = [];
        const seen = new Set();
        for (const t of this.curTargets) {
            if (t.Target_Criteria__c && !seen.has(t.Target_Criteria__c)) {
                seen.add(t.Target_Criteria__c);
                this.uniqueTargetCriterias.push({
                    Id: t.Target_Criteria__c,
                    Name: t.Target_Criteria__r?.Name || '—'
                });
            }
        }

        this.targetCriteriasWithManagerMap = new Map(
            this.curTargets.map(t => [t.Target_Criteria__c, t])
        );
    }

    _aggregateSubordinateTotals() {
        this.parentSubordinateTotals = new Map();
        this.targetList.forEach(t => {
            if (t.Parent_Target__c) {
                const current = this.parentSubordinateTotals.get(t.Parent_Target__c) || 0;
                this.parentSubordinateTotals.set(t.Parent_Target__c, current + (t.Target_Value__c || 0));
            }
        });
    }

    _toOptions(dataList, labelField, valueField) {
        return (dataList || []).map(item => ({
            label: item[labelField],
            value: item[valueField]
        }));
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}