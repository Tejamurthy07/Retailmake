import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getTodaysVisits from '@salesforce/apex/VisitCheckInController.getTodaysVisits';
import getPlannedVisits from '@salesforce/apex/VisitCheckInController.getPlannedVisits';
import skipVisit from '@salesforce/apex/VisitCheckInController.skipVisit';
import getVisitConfig from '@salesforce/apex/VisitCheckInController.getVisitConfig';
import createVisit from '@salesforce/apex/VisitCheckInController.createVisit';
import searchOutlets from '@salesforce/apex/VisitCheckInController.searchOutlets';
import getCurrentDayAttendance from '@salesforce/apex/DayAttendanceController.getCurrentDayAttendance';

import Id from '@salesforce/user/Id';

const VISIT_STATUS = {
    PLANNED: 'Planned',
    CHECKED_IN: 'Checked In',
    IN_PROGRESS: 'In Progress',
    COMPLETED: 'Completed',
    SKIPPED: 'Skipped',
    MISSED: 'Missed'
};

const AUTO_REFRESH_INTERVAL = 60000; // 60 seconds
const ADDRESS_TRUNCATE_LENGTH = 40;

const INR_FORMATTER = new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0
});

const INR_FORMATTER_DECIMAL = new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
});

export default class VisitPlanBoard extends NavigationMixin(LightningElement) {
    currentUserId = Id;

    @track visits = [];
    @track plannedOutlets = [];
    @track visitConfig = {};
    @track isLoading = true;
    @track isSkipModalOpen = false;
    @track selectedSkipReason = '';
    @track skipVisitId = null;

    // Ad-hoc visit state
    @track isAdHocModalOpen = false;
    @track adHocSearchTerm = '';
    @track adHocSearchResults = [];
    @track adHocSelectedAccount = null;
    @track adHocReason = '';
    @track showAdHocDropdown = false;
    @track dayAttendanceId = null;
    @track activeTab = 'planned';

    refreshInterval = null;
    hasLoadedOnce = false;
    _adHocSearchTimer = null;
    _batteryLevel = 0;

    // ----- Skip Reason Options -----
    get skipReasonOptions() {
        return [
            { label: 'Shop Closed', value: 'Shop Closed' },
            { label: 'Owner Not Available', value: 'Owner Not Available' },
            { label: 'No Demand', value: 'No Demand' },
            { label: 'Other', value: 'Other' }
        ];
    }

    get isSkipDisabled() {
        return !this.selectedSkipReason;
    }

    // ----- Lifecycle -----
    connectedCallback() {
        this.loadAllData();
        this.startAutoRefresh();
        this._captureBattery();
    }

    /** Capture battery level for visit data */
    async _captureBattery() {
        try {
            if (navigator.getBattery) {
                const battery = await navigator.getBattery();
                this._batteryLevel = Math.round(battery.level * 100);
                battery.addEventListener('levelchange', () => {
                    this._batteryLevel = Math.round(battery.level * 100);
                });
            }
        } catch (e) {
            this._batteryLevel = 0;
        }
    }

    disconnectedCallback() {
        this.stopAutoRefresh();
    }

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

    // ----- Data Loading -----
    async loadAllData() {
        this.isLoading = true;
        try {
            const [visitsResult, configResult, dayAttendance] = await Promise.all([
                getTodaysVisits({ userId: this.currentUserId }).then((r) => this._stripNs(r)),
                getVisitConfig(),
                getCurrentDayAttendance({ userId: this.currentUserId }).then((r) => this._stripNs(r))
            ]);

            this.visitConfig = configResult || {};
            this.dayAttendanceId = dayAttendance ? dayAttendance.Id : null;

            // Merge actual visits with planned outlets from journey plan
            const actualVisits = visitsResult || [];
            await this._mergeWithPlannedVisits(actualVisits);
            this.hasLoadedOnce = true;
        } catch (error) {
            this.showToast('Error', 'Failed to load visits: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async refreshVisits() {
        try {
            const visitsResult = this._stripNs(await getTodaysVisits({ userId: this.currentUserId }));
            const actualVisits = visitsResult || [];
            await this._mergeWithPlannedVisits(actualVisits);
        } catch (error) {
            console.error('Auto-refresh failed:', error);
        }
    }

    async _mergeWithPlannedVisits(actualVisits) {
        const processedVisits = this.processVisits(actualVisits);

        // Load planned outlets from journey plan
        try {
            const today = new Date();
            const todayStr = today.getFullYear() + '-' +
                String(today.getMonth() + 1).padStart(2, '0') + '-' +
                String(today.getDate()).padStart(2, '0');
            const plannedResult = await getPlannedVisits({
                userId: this.currentUserId,
                visitDate: todayStr
            });

            if (plannedResult && plannedResult.length > 0) {
                // Find accounts that already have a Visit__c record today
                const visitedAccountIds = new Set(
                    actualVisits.map(v => v.Account__c)
                );

                // Add planned outlets that don't have visits yet as synthetic 'Planned' entries
                const plannedEntries = plannedResult
                    .filter(po => !visitedAccountIds.has(po.accountId))
                    .map((po, idx) => ({
                        Id: 'planned_' + po.accountId + '_' + idx,
                        Account__c: po.accountId,
                        Account__r: { Name: po.accountName, BillingCity: po.city || '' },
                        Beat__c: po.beatId,
                        Beat__r: { Name: po.beatName },
                        Visit_Status__c: VISIT_STATUS.PLANNED,
                        Visit_Sequence__c: po.sequence || (idx + 1),
                        Is_Planned__c: true,
                        Is_Ad_Hoc__c: false,
                        _journeyPlanDayId: po.journeyPlanDayId,
                        _isFromPlan: true,
                        beatName: po.beatName || '',
                        outletName: po.accountName || 'Unknown Outlet',
                        fullAddress: po.city || '',
                        truncatedAddress: po.city || 'No address',
                        checkInTimeDisplay: '--',
                        checkOutTimeDisplay: '--',
                        durationDisplay: '--',
                        orderValueFormatted: '',
                        collectionFormatted: ''
                    }));

                this.visits = [...plannedEntries, ...processedVisits];
            } else {
                this.visits = processedVisits;
            }
        } catch (err) {
            console.error('Failed to load planned visits:', err);
            this.visits = processedVisits;
        }
    }

    // ----- Data Processing -----
    processVisits(rawVisits) {
        return rawVisits.map(visit => {
            const accountName = visit.Account__r ? visit.Account__r.Name : 'Unknown Outlet';
            const street = visit.Account__r ? (visit.Account__r.BillingStreet || '') : '';
            const city = visit.Account__r ? (visit.Account__r.BillingCity || '') : '';
            const fullAddress = [street, city].filter(Boolean).join(', ');
            const truncatedAddress = fullAddress.length > ADDRESS_TRUNCATE_LENGTH
                ? fullAddress.substring(0, ADDRESS_TRUNCATE_LENGTH) + '...'
                : fullAddress || 'No address';

            return {
                ...visit,
                outletName: accountName,
                fullAddress: fullAddress,
                truncatedAddress: truncatedAddress,
                beatName: visit.Beat__r ? visit.Beat__r.Name : '',
                checkInTimeDisplay: this.formatTime(visit.Check_In_Time__c),
                checkOutTimeDisplay: this.formatTime(visit.Check_Out_Time__c),
                durationDisplay: this.formatDuration(visit.Duration_Minutes__c),
                orderValueFormatted: this.formatCurrency(visit.Order_Value__c),
                collectionFormatted: this.formatCurrency(visit.Collection_Amount__c)
            };
        });
    }

    // ----- Computed: Column Lists -----
    get plannedVisits() {
        return this.visits
            .filter(v => v.Visit_Status__c === VISIT_STATUS.PLANNED)
            .sort((a, b) => (a.Visit_Sequence__c || 0) - (b.Visit_Sequence__c || 0));
    }

    get activeVisits() {
        return this.visits
            .filter(v =>
                v.Visit_Status__c === VISIT_STATUS.CHECKED_IN ||
                v.Visit_Status__c === VISIT_STATUS.IN_PROGRESS
            )
            .sort((a, b) => (a.Visit_Sequence__c || 0) - (b.Visit_Sequence__c || 0));
    }

    get completedVisits() {
        return this.visits
            .filter(v => v.Visit_Status__c === VISIT_STATUS.COMPLETED)
            .sort((a, b) => (a.Visit_Sequence__c || 0) - (b.Visit_Sequence__c || 0));
    }

    get skippedVisits() {
        return this.visits
            .filter(v => v.Visit_Status__c === VISIT_STATUS.SKIPPED)
            .sort((a, b) => (a.Visit_Sequence__c || 0) - (b.Visit_Sequence__c || 0));
    }

    get missedVisits() {
        return this.visits
            .filter(v => v.Visit_Status__c === VISIT_STATUS.MISSED)
            .sort((a, b) => (a.Visit_Sequence__c || 0) - (b.Visit_Sequence__c || 0));
    }

    // ----- Computed: Tab State -----
    get isPlannedTab() { return this.activeTab === 'planned'; }
    get isActiveTab() { return this.activeTab === 'active'; }
    get isCompletedTab() { return this.activeTab === 'completed'; }
    get isSkippedTab() { return this.activeTab === 'skipped'; }

    get plannedTabClass() {
        return 'tab-btn' + (this.isPlannedTab ? ' tab-btn-selected tab-btn-planned' : '');
    }
    get activeTabClass() {
        return 'tab-btn' + (this.isActiveTab ? ' tab-btn-selected tab-btn-active' : '');
    }
    get completedTabClass() {
        return 'tab-btn' + (this.isCompletedTab ? ' tab-btn-selected tab-btn-completed' : '');
    }
    get skippedTabClass() {
        return 'tab-btn' + (this.isSkippedTab ? ' tab-btn-selected tab-btn-skipped' : '');
    }

    // ----- Computed: Stats -----
    get totalVisitCount() {
        return this.visits.length;
    }

    get completedCount() {
        return this.completedVisits.length;
    }

    get productivityPercent() {
        const completed = this.completedVisits;
        if (completed.length === 0) return 0;
        const productive = completed.filter(v => v.Is_Productive__c).length;
        return Math.round((productive / completed.length) * 100);
    }

    get totalTimeSpent() {
        const totalMinutes = this.completedVisits.reduce((sum, v) => {
            return sum + (v.Duration_Minutes__c || 0);
        }, 0);
        const hours = Math.floor(totalMinutes / 60);
        const minutes = Math.round(totalMinutes % 60);
        if (hours > 0) {
            return hours + 'h ' + minutes + 'm';
        }
        return minutes + 'm';
    }

    get totalOrdersValue() {
        return this.completedVisits.reduce((sum, v) => {
            return sum + (v.Order_Value__c || 0);
        }, 0);
    }

    get totalOrdersFormatted() {
        return INR_FORMATTER.format(this.totalOrdersValue);
    }

    get totalCollectionValue() {
        return this.completedVisits.reduce((sum, v) => {
            return sum + (v.Collection_Amount__c || 0);
        }, 0);
    }

    get totalCollectionFormatted() {
        return INR_FORMATTER.format(this.totalCollectionValue);
    }

    get hasNoVisits() {
        return this.hasLoadedOnce && this.visits.length === 0;
    }

    get isAdHocEnabled() {
        // Show ad-hoc button by default; hide only if config explicitly disables it
        if (!this.visitConfig || this.visitConfig.adHocVisitsEnabled === undefined) {
            return true;
        }
        return this.visitConfig.adHocVisitsEnabled === true;
    }

    get isAdHocSubmitDisabled() {
        return !this.adHocSelectedAccount;
    }

    // ----- Formatting Helpers -----
    formatTime(dateTimeValue) {
        if (!dateTimeValue) return '--';
        try {
            const dt = new Date(dateTimeValue);
            return dt.toLocaleTimeString('en-IN', {
                hour: '2-digit',
                minute: '2-digit',
                hour12: true
            });
        } catch (e) {
            return '--';
        }
    }

    formatDuration(minutes) {
        if (!minutes && minutes !== 0) return '--';
        const hrs = Math.floor(minutes / 60);
        const mins = Math.round(minutes % 60);
        if (hrs > 0) {
            return hrs + 'h ' + mins + 'm';
        }
        return mins + ' min';
    }

    formatCurrency(value) {
        if (!value && value !== 0) return '';
        return INR_FORMATTER_DECIMAL.format(value);
    }

    // ----- Event Handlers: Tab Click -----
    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    // ----- Event Handlers: Card Click (Navigate to Visit Activity) -----
    handleCardClick(event) {
        // Prevent navigation when clicking action buttons
        const clickedElement = event.target;
        if (clickedElement.closest('.action-btn') || clickedElement.closest('.skip-button')) {
            return;
        }

        const visitId = event.currentTarget.dataset.id;
        const visit = this.visits.find(v => v.Id === visitId);
        if (visit && visit.Id && !visit.Id.startsWith('planned_')) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: visit.Id,
                    objectApiName: 'Visit__c',
                    actionName: 'view'
                }
            });
        }
    }

    // ----- Event Handlers: Planned Visit Check-In -----
    async handlePlannedCheckIn(event) {
        event.stopPropagation();
        const accountId = event.currentTarget.dataset.accountId;
        const beatId = event.currentTarget.dataset.beatId;
        const jpdayId = event.currentTarget.dataset.jpdayId;

        if (!accountId) {
            this.showToast('Error', 'No outlet found for this planned visit.', 'error');
            return;
        }


        // Also block if there is already an active visit (Checked In / In Progress)
        if (this.activeVisits.length > 0) {
            this.showToast('Warning',
                'Please complete or check out the current active visit before checking into a new one.',
                'warning'
            );
            return;
        }

        this.isLoading = true;
        try {
            // Capture current GPS location
            const position = await this._captureCurrentLocation();

            const visitData = {
                accountId: accountId,
                beatId: beatId || null,
                dayAttendanceId: this.dayAttendanceId,
                journeyPlanDayId: jpdayId || null,
                latitude: position.latitude,
                longitude: position.longitude,
                accuracy: position.accuracy,
                batteryLevel: this._batteryLevel || 0,
                networkStatus: navigator.onLine ? 'Online' : 'Offline',
                isPlanned: true
            };

            this._stripNs(await createVisit({ visitJson: JSON.stringify(visitData) }));
            this.showToast('Success', 'Checked in successfully.', 'success');
            await this.refreshVisits();
            this.activeTab = 'active'; // Switch to active tab after check-in
        } catch (error) {
            this.showToast('Error', 'Check-in failed: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    /** Capture current GPS location as a Promise */
    _captureCurrentLocation() {
        return new Promise((resolve) => {
            if (!navigator.geolocation) {
                resolve({ latitude: 0, longitude: 0, accuracy: 0 });
                return;
            }
            navigator.geolocation.getCurrentPosition(
                (pos) => {
                    resolve({
                        latitude: pos.coords.latitude,
                        longitude: pos.coords.longitude,
                        accuracy: pos.coords.accuracy
                    });
                },
                () => {
                    // On error, resolve with 0s rather than blocking
                    resolve({ latitude: 0, longitude: 0, accuracy: 0 });
                },
                { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
            );
        });
    }

    // ----- Event Handlers: Skip Visit -----
    handleSkipClick(event) {
        event.stopPropagation();
        this.skipVisitId = event.currentTarget.dataset.id;
        this.selectedSkipReason = '';
        this.isSkipModalOpen = true;
    }

    handleSkipReasonChange(event) {
        this.selectedSkipReason = event.detail.value;
    }

    handleSkipModalClose() {
        this.isSkipModalOpen = false;
        this.skipVisitId = null;
        this.selectedSkipReason = '';
    }

    async handleSkipConfirm() {
        if (!this.selectedSkipReason || !this.skipVisitId) {
            this.showToast('Warning', 'Please select a reason for skipping.', 'warning');
            return;
        }

        this.isLoading = true;
        this.isSkipModalOpen = false;

        try {
            this._stripNs(await skipVisit({
                visitId: this.skipVisitId,
                skipReason: this.selectedSkipReason
            }));

            this.showToast('Success', 'Visit has been skipped.', 'success');

            // Update local state immediately
            this.visits = this.visits.map(v => {
                if (v.Id === this.skipVisitId) {
                    return { ...v, Visit_Status__c: VISIT_STATUS.SKIPPED };
                }
                return v;
            });

            this.skipVisitId = null;
            this.selectedSkipReason = '';

            // Also refresh from server to get the latest data
            await this.refreshVisits();
        } catch (error) {
            this.showToast('Error', 'Failed to skip visit: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ----- Event Handlers: Refresh -----
    async handleRefresh() {
        this.isLoading = true;
        try {
            await this.refreshVisits();
            this.showToast('Success', 'Visit board refreshed.', 'success');
        } catch (error) {
            this.showToast('Error', 'Failed to refresh: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ----- Event Handlers: Ad-Hoc Visit -----
    handleAdHocClick() {
        this.adHocSearchTerm = '';
        this.adHocSearchResults = [];
        this.adHocSelectedAccount = null;
        this.adHocReason = '';
        this.showAdHocDropdown = false;
        this.isAdHocModalOpen = true;
    }

    handleAdHocModalClose() {
        this.isAdHocModalOpen = false;
        this.adHocSelectedAccount = null;
        this.adHocSearchTerm = '';
        this.adHocReason = '';
    }

    handleAdHocSearch(event) {
        const term = event.detail.value || '';
        this.adHocSearchTerm = term;

        if (this._adHocSearchTimer) {
            clearTimeout(this._adHocSearchTimer);
        }

        if (!term || term.length < 2) {
            this.adHocSearchResults = [];
            this.showAdHocDropdown = false;
            return;
        }

        this._adHocSearchTimer = setTimeout(() => {
            this._doOutletSearch(term);
        }, 300);
    }

    async _doOutletSearch(term) {
        try {
            const results = this._stripNs(await searchOutlets({ searchTerm: term }));
            this.adHocSearchResults = (results || []).map(acct => ({
                id: acct.Id,
                name: acct.Name,
                address: [acct.BillingStreet, acct.BillingCity].filter(Boolean).join(', ') || 'No address'
            }));
            this.showAdHocDropdown = this.adHocSearchResults.length > 0;
            if (!this.showAdHocDropdown) {
                this.showToast('Info', 'No outlets found matching "' + term + '"', 'info');
            }
        } catch (error) {
            this.showToast('Error', 'Outlet search failed: ' + this.reduceErrors(error), 'error');
            this.adHocSearchResults = [];
            this.showAdHocDropdown = false;
        }
    }

    handleAdHocOutletSelect(event) {
        const selectedId = event.currentTarget.dataset.id;
        const selected = this.adHocSearchResults.find(a => a.id === selectedId);
        if (selected) {
            this.adHocSelectedAccount = selected;
            this.adHocSearchTerm = selected.name;
            this.showAdHocDropdown = false;
        }
    }

    handleAdHocReasonChange(event) {
        this.adHocReason = event.detail.value;
    }

    get adHocReasonOptions() {
        return [
            { label: 'New Outlet', value: 'New Outlet' },
            { label: 'Manager Request', value: 'Manager Request' },
            { label: 'Customer Request', value: 'Customer Request' },
            { label: 'Nearby Outlet', value: 'Nearby Outlet' },
            { label: 'Other', value: 'Other' }
        ];
    }

    async handleAdHocConfirm() {
        if (!this.adHocSelectedAccount) {
            this.showToast('Warning', 'Please select an outlet.', 'warning');
            return;
        }

        this.isLoading = true;
        this.isAdHocModalOpen = false;

        try {
            const position = await this._captureCurrentLocation();

            const visitData = {
                accountId: this.adHocSelectedAccount.id,
                dayAttendanceId: this.dayAttendanceId,
                latitude: position.latitude,
                longitude: position.longitude,
                accuracy: position.accuracy,
                batteryLevel: this._batteryLevel || 0,
                networkStatus: navigator.onLine ? 'Online' : 'Offline',
                isPlanned: false,
                adHocReason: this.adHocReason || 'Ad-hoc visit'
            };

            this._stripNs(await createVisit({ visitJson: JSON.stringify(visitData) }));
            this.showToast('Success', 'Ad-hoc visit created for ' + this.adHocSelectedAccount.name, 'success');

            this.adHocSelectedAccount = null;
            this.adHocSearchTerm = '';
            this.adHocReason = '';

            await this.refreshVisits();
        } catch (error) {
            this.showToast('Error', 'Failed to create ad-hoc visit: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ----- Auto Refresh -----
    startAutoRefresh() {
        this.stopAutoRefresh();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.refreshInterval = setInterval(() => {
            this.refreshVisits();
        }, AUTO_REFRESH_INTERVAL);
    }

    stopAutoRefresh() {
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
            this.refreshInterval = null;
        }
    }

    // ----- Utility -----
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        if (Array.isArray(error.body)) {
            return error.body.map(e => e.message).join(', ');
        }
        return 'Unknown error';
    }
}