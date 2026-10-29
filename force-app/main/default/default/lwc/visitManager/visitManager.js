import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import getInitialContext from '@salesforce/apex/VisitManagerController.getInitialContext';
import startDayApex from '@salesforce/apex/VisitManagerController.startDay';
import endDayApex from '@salesforce/apex/VisitManagerController.endDay';
import selectBeatApex from '@salesforce/apex/VisitManagerController.selectBeat';
import switchBeatApex from '@salesforce/apex/VisitManagerController.switchBeat';
import checkInVisitApex from '@salesforce/apex/VisitManagerController.checkInVisit';
import checkGeofence from '@salesforce/apex/AccountGeolocation_Controller.checkGeofence';
import saveAccountLocation from '@salesforce/apex/AccountGeolocation_Controller.saveAccountLocation';
import checkOutVisitApex from '@salesforce/apex/VisitManagerController.checkOutVisit';
import skipVisitApex from '@salesforce/apex/VisitManagerController.skipVisit';
import skipPlannedVisitApex from '@salesforce/apex/VisitManagerController.skipPlannedVisit';
import refreshDayData from '@salesforce/apex/VisitManagerController.refreshDayData';
import refreshVisitSummary from '@salesforce/apex/VisitManagerController.refreshVisitSummary';
import searchOutletsApex from '@salesforce/apex/VisitManagerController.searchOutlets';
import searchEmployeesApex from '@salesforce/apex/VisitManagerController.searchEmployees';
import getOutletSummaryApex from '@salesforce/apex/VisitManagerController.getOutletSummary';
import getCreditStatusForAccounts from '@salesforce/apex/VisitManagerController.getCreditStatusForAccounts';
import getVisitActivitiesApex from '@salesforce/apex/VisitManagerController.getVisitActivities';
import getEnabledActivityKeys from '@salesforce/apex/VisitManagerController.getEnabledActivityKeys';

// â”€â”€ VISIT ACTIVITY IMPORTS â”€â”€
import getDistributorStock from '@salesforce/apex/OVE_StockCheckController.getDistributorStock';
import getProductsForStockCheck from '@salesforce/apex/OVE_StockCheckController.getProductsForStockCheck';
import saveStockEntries from '@salesforce/apex/OVE_StockCheckController.saveStockEntries';
import getCompetitorEntriesForVisit from '@salesforce/apex/OVE_CompetitorActivityController.getCompetitorEntriesForVisit';
import getCompetitorMaster from '@salesforce/apex/OVE_CompetitorActivityController.getCompetitorMaster';
import saveCompetitorEntry from '@salesforce/apex/OVE_CompetitorActivityController.saveCompetitorEntry';
import deleteCompetitorEntry from '@salesforce/apex/OVE_CompetitorActivityController.deleteCompetitorEntry';
import getMerchandisingForVisit from '@salesforce/apex/OVE_MerchandisingController.getMerchandisingForVisit';
import saveMerchandising from '@salesforce/apex/OVE_MerchandisingController.saveMerchandising';
import getApplicableSurveys from '@salesforce/apex/OVE_SurveyController.getApplicableSurveys';
import getSurveyWithQuestions from '@salesforce/apex/OVE_SurveyController.getSurveyWithQuestions';
import submitSurveyResponse from '@salesforce/apex/OVE_SurveyController.submitSurveyResponse';
import getSurveyResponsesForVisit from '@salesforce/apex/OVE_SurveyController.getSurveyResponsesForVisit';
import uploadSurveyPhoto from '@salesforce/apex/OVE_SurveyController.uploadSurveyPhoto';
import getActiveSchemes from '@salesforce/apex/OVE_SchemeInfoController.getActiveSchemes';
import getTicketsForVisit from '@salesforce/apex/OVE_TicketController.getTicketsForVisit';
import createTicket from '@salesforce/apex/OVE_TicketController.createTicket';
import getAvailabilityData from '@salesforce/apex/OVE_AvailabilityController.getAvailabilityData';
import searchAvailabilityProducts from '@salesforce/apex/OVE_AvailabilityController.searchAvailabilityProducts';
import saveAvailability from '@salesforce/apex/OVE_AvailabilityController.saveAvailability';

// â”€â”€ GPS BREADCRUMB TRACKING â”€â”€
import logGPS from '@salesforce/apex/DayAttendanceController.logGPS';
import syncOfflineGPSLogs from '@salesforce/apex/DayAttendanceController.syncOfflineGPSLogs';

// Raw SObjects returned by Apex carry namespaced field keys once the org has a
// namespace registered. See _normalizeRecord below.
const NAMESPACE_PREFIX = 'ftretailmake__';

// â”€â”€ SCREEN STATES â”€â”€
const SCREEN = {
    LOADING: 'loading',
    DAY_START: 'day_start',
    BEAT_SELECT: 'beat_select',
    VISIT_BOARD: 'visit_board',
    VISIT_ACTIVE: 'visit_active',
    VISIT_ACTIVITY: 'visit_activity',
    VISIT_DETAIL: 'visit_detail'
};

const VISIT_STATUS = {
    PLANNED: 'Planned',
    CHECKED_IN: 'Checked In',
    IN_PROGRESS: 'In Progress',
    COMPLETED: 'Completed',
    SKIPPED: 'Skipped',
    MISSED: 'Missed'
};

const CURRENCY = new Intl.NumberFormat('en-IN', {
    style: 'currency', currency: 'INR',
    minimumFractionDigits: 0, maximumFractionDigits: 0
});

const ADDR_LEN = 45;

const GPS_QUEUE_STORAGE_KEY = 'visitManager_offlineGpsQueue';

export default class VisitManager extends NavigationMixin(LightningElement) {

    // â”€â”€ SCREEN STATE â”€â”€
    @track currentScreen = SCREEN.LOADING;
    @track isProcessing = false;

    // â”€â”€ CONFIG â”€â”€
    @track config = {};

    // â”€â”€ DAY ATTENDANCE â”€â”€
    @track dayAttendance = null;
    @track dayStats = {};
    // Today's attendance regardless of status â€” used to show summary card
    // when the user has already ended their day (prevents duplicate Start Day)
    @track todayAttendance = null;

    // â”€â”€ LOCATION & DEVICE â”€â”€
    @track latitude = 0;
    @track longitude = 0;
    @track accuracy = 0;
    @track locationCaptured = false;
    @track batteryLevel = 0;
    @track networkStatus = 'Online';

    // â”€â”€ BEATS â”€â”€
    @track todaysBeats = [];
    @track selectedBeatId = null;
    @track activeBeatId = null;
    @track showBeatConfirmModal = false;

    // â”€â”€ DAY START FORM â”€â”€
    @track dutyType = 'HQ';
    @track odometerStart = null;
    @track withCompanion = false;
    @track companionId = null;
    @track companionName = '';
    @track companionSearchTerm = '';
    @track companionSearchResults = [];
    @track showCompanionDropdown = false;
    @track startSelfiePreview = null;
    _startSelfieBase64 = null;

    // â”€â”€ VISITS â”€â”€
    @track allVisits = [];
    @track boardTab = 'planned';

    // â”€â”€ ACTIVE VISIT â”€â”€
    @track activeVisit = null;
    @track activeVisitSummary = {};
    @track visitActivities = [];
    // Profile-level enabled activity keys, so summary tiles (Orders / Collection)
    // hide when those activities are switched off in the activity config.
    @track enabledActivityKeys = [];
    _enabledKeysLoaded = false;
    @track outletSummary = {};
    @track creditStatusMap = {}; // { accountId: 'ok' | 'over' | 'none' } for day-board badges
    @track visitDuration = 0;
    @track activeVisitTab = 'activities';

    // â”€â”€ COMPLETED VISIT DETAIL â”€â”€
    @track detailVisit = null;
    @track detailVisitSummary = {};
    @track detailVisitTab = 'orders';
    @track detailSurveyResponses = [];
    @track detailTickets = [];
    @track detailMerchandising = [];
    @track detailCompetitorEntries = [];

    // â”€â”€ AD-HOC â”€â”€
    @track showAdHocModal = false;

    // Geo-fence warning state
    @track showGeofenceWarning = false;
    @track geofenceWarningMessage = '';
    @track geofenceDistance = 0;
    @track geofenceRadius = 0;
    @track geofenceOutletName = '';
    _pendingCheckIn = null; // holds the pending check-in data for retry after confirm
    @track adHocSearchTerm = '';
    @track adHocSearchResults = [];
    @track adHocSelectedAccount = null;
    @track adHocReason = '';
    @track showAdHocDropdown = false;

    // â”€â”€ SKIP â”€â”€
    @track showSkipModal = false;
    @track skipVisitId = null;
    @track skipReason = '';

    // â”€â”€ SWITCH BEAT â”€â”€
    @track showSwitchBeatModal = false;
    @track switchBeatId = null;
    @track switchBeatReason = '';

    // â”€â”€ CHECKOUT â”€â”€
    @track showCheckoutModal = false;
    @track isProductive = true;
    @track nonProductiveReason = '';
    @track visitNotes = '';
    @track checklistItems = [];

    // â”€â”€ VISIT ACTIVITY (inline forms) â”€â”€
    @track activeActivityId = null;
    // When user clicks a Draft order row on the active visit's Orders
    // tab, this gets set and the Order Entry form opens pre-loaded
    // with that order for editing.
    @track editDraftOrderId = null;
    // Stock Check
    @track stockCheckLines = [];
    @track stockProductSearch = '';
    @track stockProductResults = [];
    @track stockIsLoading = false;
    // Availability & Stock Depth
    @track availabilityLines = [];
    @track availabilitySearch = '';
    @track availabilityResults = [];
    @track availabilityIsLoading = false;
    // Competitor
    @track competitorEntries = [];
    @track competitorCompanies = [];
    @track competitorFilteredCompanies = [];
    @track competitorShowSuggestions = false;
    @track competitorForm = { competitorCompany: '', competitorSKU: '', competitorPrice: null, ownProductId: null, ownProductName: '', notes: '', photoContentVersionId: null, photoPreview: null };
    @track competitorPhotoUploading = false;
    @track competitorIsLoading = false;
    @track competitorProductSearch = '';
    @track competitorProductResults = [];
    @track competitorShowProductSearch = false;
    // Merchandising
    @track merchandisingRecord = { ownShelfShare: null, competitorShelfShare: null, planogramCompliant: false, posmPresent: false, posmCondition: '', notes: '' };
    @track merchandisingIsLoading = false;
    // Survey
    @track applicableSurveys = [];
    @track selectedSurvey = null;
    @track surveyQuestions = [];
    @track surveyAnswers = {};
    @track surveyIsLoading = false;
    // Scheme
    @track activeSchemesList = [];
    @track schemeIsLoading = false;
    // Ticket
    @track visitTickets = [];
    @track ticketForm = { category: '', priority: 'Medium', subject: '', description: '' };
    @track ticketIsLoading = false;

    // â”€â”€ DAY END â”€â”€
    @track showEndDayModal = false;
    @track odometerEnd = null;
    @track endDayRemarks = '';
    @track endSelfiePreview = null;
    _endSelfieBase64 = null;

    // â”€â”€ CLOCK â”€â”€
    @track currentTime = '';
    @track dayStartTime = null;

    // â”€â”€ INTERNALS â”€â”€
    _clockInterval = null;
    _statsInterval = null;
    _timerInterval = null;
    _gpsInterval = null;
    _offlineGpsQueue = [];
    _searchTimer = null;
    _companionTimer = null;
    _deviceInfo = '';
    _hasLoaded = false;

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // LIFECYCLE
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    _pullToRefreshHandler;
    _touchStartY = 0;

    connectedCallback() {
        this._disablePullToRefresh();
        this._updateClock();
        this._clockInterval = setInterval(() => this._updateClock(), 1000);
        this._captureLocation();
        this._captureDeviceInfo();
        this._loadOfflineGpsQueue();
        this._loadEnabledActivityKeys();
        this._loadInitialContext();
    }

    disconnectedCallback() {
        this._enablePullToRefresh();
        if (this._clockInterval) clearInterval(this._clockInterval);
        if (this._statsInterval) clearInterval(this._statsInterval);
        if (this._timerInterval) clearInterval(this._timerInterval);
        if (this._gpsInterval) clearInterval(this._gpsInterval);
    }

    _disablePullToRefresh() {
        document.body.style.overscrollBehaviorY = 'contain';
        document.documentElement.style.overscrollBehaviorY = 'contain';
        this._touchStartY = 0;
        this._pullToRefreshHandler = (e) => {
            if (window.scrollY === 0 && e.touches[0].clientY > this._touchStartY) {
                e.preventDefault();
            }
        };
        document.addEventListener('touchstart', (e) => {
            this._touchStartY = e.touches[0].clientY;
        }, { passive: true });
        document.addEventListener('touchmove', this._pullToRefreshHandler, { passive: false });
    }

    _enablePullToRefresh() {
        document.body.style.overscrollBehaviorY = '';
        document.documentElement.style.overscrollBehaviorY = '';
        if (this._pullToRefreshHandler) {
            document.removeEventListener('touchmove', this._pullToRefreshHandler);
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // INITIALIZATION
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    async _loadInitialContext() {
        try {
            // Strip the managed-package namespace from all field keys so the
            // component's unqualified SObject reads work (no-op without a namespace).
            const ctx = this._normalizeRecord(await getInitialContext());
            this.config = ctx.config || {};
            this.todaysBeats = (ctx.todaysBeats || []).map(b => ({
                ...b,
                cardClass: 'vm-beat-card',
                outletsLabel: (b.outletCount || 0) + ' Outlets'
            }));

            // Track today's attendance (any status) for the Day Start screen
            this.todayAttendance = ctx.todayAttendance || null;

            if (ctx.isDayStarted && ctx.dayAttendance) {
                this.dayAttendance = ctx.dayAttendance;
                this.dayStats = ctx.dayStats || {};
                this.activeBeatId = ctx.currentBeatId || null;
                this.dayStartTime = new Date(ctx.dayAttendance.Day_Start_Time__c || ctx.dayAttendance.Start_Time__c);

                this._startGpsTracking();

                // If day started but user hasn't explicitly selected a beat yet
                // (Original_Beat__c is set by selectBeat to confirm user's choice)
                const beatConfirmed = ctx.dayAttendance.Original_Beat__c != null;
                if (!beatConfirmed) {
                    this.currentScreen = SCREEN.BEAT_SELECT;
                } else {
                    this._processVisits(ctx.todaysVisits || [], ctx.plannedVisits || []);

                    // Auto-redirect to in-progress visit
                    if (ctx.hasActiveVisit && ctx.activeVisit) {
                        this.activeVisit = this._normalizeRecord(ctx.activeVisit);
                        this.activeVisitSummary = ctx.activeVisitSummary || {};
                        this.visitActivities = this._processActivities(ctx.visitActivities || []);
                        this._startVisitTimer();
                        this._loadOutletSummary(ctx.activeVisit.Account__c);
                        this.currentScreen = SCREEN.VISIT_ACTIVE;
                    } else {
                        this.currentScreen = SCREEN.VISIT_BOARD;
                    }

                    this._startStatsRefresh();
                }
            } else {
                this.currentScreen = SCREEN.DAY_START;
            }

            this._hasLoaded = true;
        } catch (err) {
            this._toast('Error', 'Failed to load: ' + this._err(err), 'error');
            this.currentScreen = SCREEN.DAY_START;
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // SCREEN GETTERS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get isLoadingScreen() { return this.currentScreen === SCREEN.LOADING; }
    get isDayStartScreen() { return this.currentScreen === SCREEN.DAY_START; }

    // When the user already has an attendance record today (in any status),
    // we show a summary card instead of the Start Day button.
    get hasTodayAttendance() { return !!this.todayAttendance; }

    get todayAttendanceStatus() {
        return this.todayAttendance ? this.todayAttendance.Status__c : '';
    }

    get todayAttendanceBadgeClass() {
        const s = this.todayAttendanceStatus;
        if (s === 'Started' || s === 'In Progress') return 'vm-status-pill vm-status-green';
        if (s === 'Ended' || s === 'Completed') return 'vm-status-pill vm-status-blue';
        if (s === 'Auto-Closed') return 'vm-status-pill vm-status-amber';
        return 'vm-status-pill vm-status-gray';
    }

    get todayAttendanceStartTime() {
        if (!this.todayAttendance || !this.todayAttendance.Day_Start_Time__c) return '-';
        return new Date(this.todayAttendance.Day_Start_Time__c).toLocaleTimeString('en-IN',
            { hour: '2-digit', minute: '2-digit' });
    }

    get todayAttendanceEndTime() {
        if (!this.todayAttendance || !this.todayAttendance.Day_End_Time__c) return 'In progress';
        return new Date(this.todayAttendance.Day_End_Time__c).toLocaleTimeString('en-IN',
            { hour: '2-digit', minute: '2-digit' });
    }

    get todayAttendanceHours() {
        return this.todayAttendance && this.todayAttendance.Hours_Worked__c != null
            ? this.todayAttendance.Hours_Worked__c.toFixed(1) + ' hrs' : '-';
    }

    get todayAttendanceVisits() {
        return this.todayAttendance && this.todayAttendance.Total_Visits__c != null
            ? String(this.todayAttendance.Total_Visits__c) : '0';
    }

    get todayAttendanceOrders() {
        return this.todayAttendance && this.todayAttendance.Total_Orders__c != null
            ? String(this.todayAttendance.Total_Orders__c) : '0';
    }

    get todayAttendanceOrderValue() {
        if (!this.todayAttendance || this.todayAttendance.Total_Order_Value__c == null) return 'â‚¹0';
        return new Intl.NumberFormat('en-IN', {
            style: 'currency', currency: 'INR', maximumFractionDigits: 0
        }).format(this.todayAttendance.Total_Order_Value__c);
    }

    get todayAttendanceCollection() {
        if (!this.todayAttendance || this.todayAttendance.Total_Collection__c == null) return 'â‚¹0';
        return new Intl.NumberFormat('en-IN', {
            style: 'currency', currency: 'INR', maximumFractionDigits: 0
        }).format(this.todayAttendance.Total_Collection__c);
    }

    get todayAttendanceBeatName() {
        return this.todayAttendance && this.todayAttendance.Beat__r
            ? this.todayAttendance.Beat__r.Name : 'â€”';
    }

    get todayAttendanceMessage() {
        const s = this.todayAttendanceStatus;
        if (s === 'Ended' || s === 'Completed') {
            return 'Your day is already complete. You cannot start another attendance for today.';
        }
        if (s === 'Auto-Closed') {
            return 'Your day was auto-closed. Please contact your manager if you need to adjust.';
        }
        return 'You already have an active attendance record for today.';
    }

    get isBeatSelectScreen() { return this.currentScreen === SCREEN.BEAT_SELECT; }
    get isVisitBoardScreen() { return this.currentScreen === SCREEN.VISIT_BOARD; }
    get isVisitActiveScreen() { return this.currentScreen === SCREEN.VISIT_ACTIVE; }
    get isVisitActivityScreen() { return this.currentScreen === SCREEN.VISIT_ACTIVITY; }
    get isVisitDetailScreen() { return this.currentScreen === SCREEN.VISIT_DETAIL; }

    // â”€â”€ Activity type getters â”€â”€
    get isStockCheckActivity() { return this.activeActivityId === 'stock_check'; }
    get isAvailabilityActivity() { return this.activeActivityId === 'availability'; }
    get isCompetitorActivity() { return this.activeActivityId === 'competitor'; }
    get isMerchandisingActivity() { return this.activeActivityId === 'merchandising'; }
    get isSurveyActivity() { return this.activeActivityId === 'survey'; }
    get isSchemeActivity() { return this.activeActivityId === 'scheme'; }
    get isTicketActivity() { return this.activeActivityId === 'ticket'; }
    get isOrderActivity() { return this.activeActivityId === 'order'; }
    get isCollectionActivity() { return this.activeActivityId === 'collection'; }
    get isReturnsActivity() { return this.activeActivityId === 'returns'; }
    get activeActivityTitle() {
        const titles = {
            stock_check: 'Stock Update', availability: 'Availability & Stock Depth',
            competitor: 'Competitor Activity', merchandising: 'Merchandising Audit',
            survey: 'Survey / Feedback', scheme: 'Scheme Info', ticket: 'Ticket / Complaint',
            order: 'Order Entry', collection: 'Collection', returns: 'Returns'
        };
        return titles[this.activeActivityId] || 'Activity';
    }
    get activeAccountId() { return this.activeVisit ? this.activeVisit.Account__c : null; }
    get activeVisitId() { return this.activeVisit ? this.activeVisit.Id : null; }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // CLOCK & TIME
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    _updateClock() {
        const now = new Date();
        this.currentTime = now.toLocaleTimeString('en-IN', {
            hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: true
        });
    }

    get todayDateDisplay() {
        return new Date().toLocaleDateString('en-IN', {
            weekday: 'long', year: 'numeric', month: 'long', day: 'numeric'
        });
    }

    get greetingMessage() {
        const h = new Date().getHours();
        if (h < 12) return 'Good Morning';
        if (h < 17) return 'Good Afternoon';
        return 'Good Evening';
    }

    get dayDurationDisplay() {
        // Reference currentTime to create a reactive dependency that ticks every second
        void this.currentTime;
        if (!this.dayStartTime) return '00:00:00';
        // Use Math.abs so minor clock skew between client/server still shows a
        // meaningful elapsed duration (otherwise the timer sticks at 00:00:00).
        const diff = Math.abs(Math.floor((Date.now() - this.dayStartTime.getTime()) / 1000));
        const h = Math.floor(diff / 3600);
        const m = Math.floor((diff % 3600) / 60);
        const s = diff % 60;
        return `${this._pad(h)}:${this._pad(m)}:${this._pad(s)}`;
    }

    get dayStartTimeDisplay() {
        if (!this.dayStartTime) return '--';
        return this.dayStartTime.toLocaleTimeString('en-IN', {
            hour: '2-digit', minute: '2-digit', hour12: true
        });
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // LOCATION & DEVICE
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    _captureLocation() {
        if (!navigator.geolocation) return;
        navigator.geolocation.getCurrentPosition(
            (pos) => {
                this.latitude = pos.coords.latitude;
                this.longitude = pos.coords.longitude;
                this.accuracy = pos.coords.accuracy;
                this.locationCaptured = true;
            },
            () => { this.locationCaptured = false; },
            { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
        );
    }

    _captureLocationAsync() {
        return new Promise((resolve) => {
            if (!navigator.geolocation) {
                resolve({ latitude: 0, longitude: 0, accuracy: 0 });
                return;
            }
            navigator.geolocation.getCurrentPosition(
                (pos) => {
                    this.latitude = pos.coords.latitude;
                    this.longitude = pos.coords.longitude;
                    this.accuracy = pos.coords.accuracy;
                    this.locationCaptured = true;
                    resolve({ latitude: pos.coords.latitude, longitude: pos.coords.longitude, accuracy: pos.coords.accuracy });
                },
                () => resolve({ latitude: this.latitude, longitude: this.longitude, accuracy: this.accuracy }),
                { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
            );
        });
    }

    async _captureDeviceInfo() {
        this._deviceInfo = navigator.userAgent || '';
        this.networkStatus = navigator.onLine ? 'Online' : 'Offline';
        try {
            if (navigator.getBattery) {
                const bat = await navigator.getBattery();
                this.batteryLevel = Math.round(bat.level * 100);
            }
        } catch (e) { /* ignore */ }
    }

    get locationStatusText() {
        return this.locationCaptured
            ? `${this.latitude.toFixed(5)}, ${this.longitude.toFixed(5)}`
            : 'Fetching...';
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // DAY START
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get startDayDisabled() {
        return this.isProcessing || !this.locationCaptured ||
            (this.config.selfieRequired && !this._startSelfieBase64);
    }

    get dutyTypeOptions() {
        return [
            { label: 'HQ', value: 'HQ' },
            { label: 'EX-HQ', value: 'EX-HQ' },
            { label: 'OS', value: 'OS' }
        ];
    }

    handleDutyTypeChange(e) { this.dutyType = e.detail.value; }

    handleOdometerStartChange(e) { this.odometerStart = e.detail.value ? Number(e.detail.value) : null; }

    handleCompanionToggle(e) {
        this.withCompanion = e.target.checked;
        if (!this.withCompanion) {
            this.companionId = null;
            this.companionName = '';
            this.companionSearchTerm = '';
        }
    }

    handleCompanionSearch(e) {
        const term = e.target.value || '';
        this.companionSearchTerm = term;
        if (this._companionTimer) clearTimeout(this._companionTimer);
        if (term.length < 2) { this.companionSearchResults = []; this.showCompanionDropdown = false; return; }
        this._companionTimer = setTimeout(() => this._doCompanionSearch(term), 300);
    }

    async _doCompanionSearch(term) {
        try {
            const results = this._normalizeRecord(await searchEmployeesApex({ searchTerm: term }));
            this.companionSearchResults = (results || []).map(emp => ({
                id: emp.Id, name: emp.Name, subtitle: emp.Employee_Code__c || ''
            }));
            this.showCompanionDropdown = this.companionSearchResults.length > 0;
        } catch (err) { this.showCompanionDropdown = false; }
    }

    handleCompanionSelect(e) {
        const emp = this.companionSearchResults.find(r => r.id === e.currentTarget.dataset.id);
        if (emp) {
            this.companionId = emp.id;
            this.companionName = emp.name;
            this.companionSearchTerm = emp.name;
            this.showCompanionDropdown = false;
        }
    }

    clearCompanion() {
        this.companionId = null;
        this.companionName = '';
        this.companionSearchTerm = '';
    }

    handleStartSelfieCapture(e) {
        this._processPhoto(e, (base64, preview) => {
            this._startSelfieBase64 = base64;
            this.startSelfiePreview = preview;
        });
    }

    handleOpenStartCamera() {
        if (this._isMobileDevice()) {
            this._cameraTarget = 'start';
            this._startCamera();
        } else {
            this._openFileUpload((base64, preview) => {
                this._startSelfieBase64 = base64;
                this.startSelfiePreview = preview;
            });
        }
    }

    removeStartSelfie() {
        this._startSelfieBase64 = null;
        this.startSelfiePreview = null;
    }

    async handleStartDay() {
        if (this.startDayDisabled) return;
        this.isProcessing = true;
        try {
            await this._captureLocationAsync();
            const dayData = {
                startLatitude: this.latitude,
                startLongitude: this.longitude,
                startAccuracy: this.accuracy,
                selfieBase64: this._startSelfieBase64 || '',
                batteryLevel: this.batteryLevel,
                networkStatus: this.networkStatus,
                deviceInfo: this._deviceInfo,
                dutyType: this.dutyType || 'HQ',
                odometerStart: this.odometerStart || 0,
                withCompanion: this.withCompanion,
                companionId: this.companionId
            };

            const result = this._normalizeRecord(await startDayApex({ dayJson: JSON.stringify(dayData) }));
            this.dayAttendance = result;
            this.dayStartTime = new Date(result.Day_Start_Time__c || result.Start_Time__c);

            this._startGpsTracking();

            this._toast('Success', 'Day started! Now select your beat.', 'success');
            this.currentScreen = SCREEN.BEAT_SELECT;
        } catch (err) {
            this._toast('Error', 'Failed to start day: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // BEAT SELECTION (after day start)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get hasBeats() { return this.todaysBeats.length > 0; }

    get assignedBeats() {
        return this.todaysBeats.filter(b => b.isAssigned);
    }

    get otherBeats() {
        return this.todaysBeats.filter(b => !b.isAssigned);
    }

    get hasOtherBeats() { return this.otherBeats.length > 0; }

    get selectedBeatName() {
        const b = this.todaysBeats.find(bt => bt.beatId === this.selectedBeatId);
        return b ? b.beatName : '';
    }

    get selectedBeatOutletCount() {
        const b = this.todaysBeats.find(bt => bt.beatId === this.selectedBeatId);
        return b ? (b.outletCount || 0) : 0;
    }

    get selectedBeatIsAssigned() {
        const b = this.todaysBeats.find(bt => bt.beatId === this.selectedBeatId);
        return b ? b.isAssigned : false;
    }

    get beatsWithSelection() {
        return this.todaysBeats.map(b => ({
            ...b,
            cardClass: b.beatId === this.selectedBeatId
                ? 'vm-beat-card vm-beat-selected'
                : b.isAssigned ? 'vm-beat-card vm-beat-assigned' : 'vm-beat-card',
            isSelected: b.beatId === this.selectedBeatId
        }));
    }

    get assignedBeatsWithSelection() {
        return this.beatsWithSelection.filter(b => b.isAssigned);
    }

    get otherBeatsWithSelection() {
        return this.beatsWithSelection.filter(b => !b.isAssigned);
    }

    get selectBeatDisabled() {
        return this.isProcessing || !this.selectedBeatId;
    }

    handleBeatSelect(e) {
        this.selectedBeatId = e.currentTarget.dataset.beatId;
    }

    handleBeatConfirm() {
        if (!this.selectedBeatId) {
            this._toast('Warning', 'Please select a beat first.', 'warning');
            return;
        }
        this.showBeatConfirmModal = true;
    }

    handleBeatConfirmClose() {
        this.showBeatConfirmModal = false;
    }

    async handleSelectBeatConfirm() {
        if (!this.selectedBeatId || !this.dayAttendance) return;
        this.showBeatConfirmModal = false;
        this.isProcessing = true;
        try {
            const selectedBeat = this.todaysBeats.find(b => b.beatId === this.selectedBeatId);
            const jpDayId = selectedBeat ? selectedBeat.journeyPlanDayId : null;

            const result = await selectBeatApex({
                attendanceId: this.dayAttendance.Id,
                beatId: this.selectedBeatId,
                journeyPlanDayId: jpDayId
            });

            this.dayAttendance = this._normalizeRecord(result);
            this.activeBeatId = this.selectedBeatId;

            await this._refreshAllData();
            this._startStatsRefresh();
            this.currentScreen = SCREEN.VISIT_BOARD;
            this._toast('Success', 'Beat selected: ' + this.selectedBeatName, 'success');
        } catch (err) {
            this._toast('Error', 'Failed to select beat: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // VISIT BOARD
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    _processVisits(todaysVisits, plannedVisitsMaps) {
        todaysVisits = this._normalizeRecord(todaysVisits || []);
        const processed = (todaysVisits || []).map(v => this._enrichVisit(v));
        const visitedAccountIds = new Set(todaysVisits.map(v => v.Account__c));

        const planned = (plannedVisitsMaps || [])
            .filter(p => !visitedAccountIds.has(p.accountId))
            .map((p, idx) => ({
                Id: 'planned_' + p.accountId + '_' + idx,
                Account__c: p.accountId,
                Account__r: { Name: p.accountName, BillingCity: p.city || '' },
                Beat__c: p.beatId,
                Beat__r: { Name: p.beatName },
                Visit_Status__c: VISIT_STATUS.PLANNED,
                Visit_Sequence__c: p.sequence || (idx + 1),
                Is_Planned__c: true,
                Is_Ad_Hoc__c: false,
                _journeyPlanDayId: p.journeyPlanDayId,
                _isFromPlan: true,
                outletName: p.accountName || 'Unknown Outlet',
                outletLatitude: p.outletLatitude || null,
                outletLongitude: p.outletLongitude || null,
                beatName: p.beatName || '',
                truncatedAddress: p.city || 'No address',
                checkInTimeDisplay: '--',
                durationDisplay: '--',
                orderValueFormatted: '',
                collectionFormatted: ''
            }));

        this.allVisits = [...planned, ...processed];
        this._loadCreditStatuses();
    }

    // Resolve credit status for every outlet on the board in one call, so each
    // planned row can show a color-coded badge before the rep walks in.
    async _loadCreditStatuses() {
        const ids = [...new Set(this.allVisits.map(v => v.Account__c).filter(Boolean))];
        if (!ids.length) return;
        try {
            const map = await getCreditStatusForAccounts({ accountIds: ids });
            this.creditStatusMap = map || {};
        } catch (e) {
            this.creditStatusMap = {};
        }
    }

    /**
     * Apex hands some records back as raw SObjects (for example ctx.activeVisit),
     * so once the org gained a namespace their JSON keys arrived prefixed â€”
     * Account__c became ftretailmake__Account__c â€” and every unqualified read in
     * this component returned undefined. Records that come back from wrapper
     * classes are unaffected, which is why parts of the screen kept working.
     *
     * Stripping the prefix at the point of assignment keeps every downstream
     * getter working unchanged, whether or not the payload is namespaced.
     */
    _normalizeRecord(record) {
        if (!record || typeof record !== 'object') {
            return record;
        }
        if (Array.isArray(record)) {
            return record.map(item => this._normalizeRecord(item));
        }

        const normalized = {};
        Object.keys(record).forEach(key => {
            const plainKey = key.startsWith(NAMESPACE_PREFIX)
                ? key.substring(NAMESPACE_PREFIX.length)
                : key;
            const value = record[key];
            normalized[plainKey] = (value && typeof value === 'object')
                ? this._normalizeRecord(value)
                : value;
        });
        return normalized;
    }

    // Color tier â†’ CSS classes for the availability dot and the amount text.
    _creditDotClass(tier) { return 'vm-cdot vm-cdot-' + (tier || 'none'); }
    _creditAvailClass(tier) { return 'vm-credit-avail vm-cavail-' + (tier || 'none'); }

    _enrichVisit(v) {
        const name = v.Account__r ? v.Account__r.Name : 'Unknown';
        const street = v.Account__r ? (v.Account__r.BillingStreet || '') : '';
        const city = v.Account__r ? (v.Account__r.BillingCity || '') : '';
        const addr = [street, city].filter(Boolean).join(', ');
        return {
            ...v,
            outletName: name,
            truncatedAddress: addr.length > ADDR_LEN ? addr.substring(0, ADDR_LEN) + '...' : addr || 'No address',
            beatName: v.Beat__r ? v.Beat__r.Name : '',
            checkInTimeDisplay: this._fmtTime(v.Check_In_Time__c),
            checkOutTimeDisplay: this._fmtTime(v.Check_Out_Time__c),
            durationDisplay: this._fmtDuration(v.Duration_Minutes__c),
            orderValueFormatted: v.Order_Value__c ? CURRENCY.format(v.Order_Value__c) : '',
            collectionFormatted: v.Collection_Amount__c ? CURRENCY.format(v.Collection_Amount__c) : ''
        };
    }

    // Board data getters â€” filtered by active beat
    get plannedVisits() {
        return this.allVisits
            .filter(v => v.Visit_Status__c === VISIT_STATUS.PLANNED &&
                (!this.activeBeatId || v.Beat__c === this.activeBeatId))
            .sort((a, b) => (a.Visit_Sequence__c || 0) - (b.Visit_Sequence__c || 0));
    }

    get activeVisits() {
        return this.allVisits.filter(v =>
            v.Visit_Status__c === VISIT_STATUS.CHECKED_IN ||
            v.Visit_Status__c === VISIT_STATUS.IN_PROGRESS
        );
    }
    get completedVisits() {
        return this.allVisits.filter(v => v.Visit_Status__c === VISIT_STATUS.COMPLETED);
    }
    get skippedVisits() {
        return this.allVisits.filter(v => v.Visit_Status__c === VISIT_STATUS.SKIPPED);
    }


    // Enriched planned visits â€” all can check in (no sequence restriction)
    get plannedVisitsEnriched() {
        const myLat = this.latitude;
        const myLng = this.longitude;
        const hasMyLocation = myLat != null && myLng != null && this.locationCaptured;

        return this.plannedVisits.map(v => {
            const hasOutletLoc = v.outletLatitude != null && v.outletLongitude != null;
            let distanceDisplay = '';
            let distanceClass = 'vm-distance';
            let distanceMeters = null;

            if (hasMyLocation && hasOutletLoc) {
                distanceMeters = this._haversineMeters(myLat, myLng, v.outletLatitude, v.outletLongitude);
                if (distanceMeters < 1000) {
                    distanceDisplay = Math.round(distanceMeters) + 'm away';
                } else {
                    distanceDisplay = (distanceMeters / 1000).toFixed(1) + 'km away';
                }
                distanceClass += distanceMeters <= 500 ? ' vm-dist-near' : distanceMeters <= 2000 ? ' vm-dist-mid' : ' vm-dist-far';
            } else if (!hasOutletLoc) {
                distanceDisplay = 'No location set';
                distanceClass += ' vm-dist-none';
            }

            const ci = this.creditStatusMap[v.Account__c];
            const tier = ci ? ci.tier : null;
            return {
                ...v,
                canCheckIn: v._isFromPlan,
                isLocked: false,
                rowClass: 'vm-visit-row vm-row-planned vm-row-next',
                distanceDisplay,
                distanceClass,
                distanceMeters,
                hasOutletLocation: hasOutletLoc,
                showSetLocation: !hasOutletLoc,
                creditDotClass: this._creditDotClass(tier),
                creditAvailClass: this._creditAvailClass(tier),
                creditAvailDisplay: (ci && ci.available != null) ? CURRENCY.format(ci.available) : '',
                hasCreditInfo: !!tier && tier !== 'none',
                // Credit period badge shown on the right of the row.
                creditDaysDisplay: (ci && ci.creditDays) ? ci.creditDays + ' days' : '',
                hasCreditDays: !!(ci && ci.creditDays)
            };
        });
    }

    _haversineMeters(lat1, lon1, lat2, lon2) {
        const R = 6371000;
        const toRad = d => (d * Math.PI) / 180;
        const dLat = toRad(lat2 - lat1);
        const dLon = toRad(lon2 - lon1);
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
        return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    }

    async handleSetStoreLocation(event) {
        event.stopPropagation();
        const accountId = event.currentTarget.dataset.accountId;
        if (!accountId) return;

        if (!this.locationCaptured || this.latitude == null) {
            this._toast('Error', 'Your current location is not available. Please enable GPS.', 'error');
            return;
        }

        try {
            this.isProcessing = true;
            await saveAccountLocation({
                accountId: accountId,
                latitude: this.latitude,
                longitude: this.longitude,
                radiusMeters: null
            });
            this._toast('Success', 'Store location saved from your current position.', 'success');

            // Update the planned visit in memory so UI refreshes
            this.allVisits = this.allVisits.map(v => {
                if (v.Account__c === accountId) {
                    return { ...v, outletLatitude: this.latitude, outletLongitude: this.longitude };
                }
                return v;
            });
        } catch (err) {
            this._toast('Error', 'Failed to save location: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // Stats
    get statCompleted() { return this.completedVisits.length; }
    get statPlanned() { return this.plannedVisits.length; }
    get statActive() { return this.activeVisits.length; }
    get statSkipped() { return this.skippedVisits.length; }
    get statProductivity() { return this.dayStats.Productivity_Percent__c || 0; }
    get statOrders() { return this.dayStats.Orders_Today__c || 0; }
    get statOrderValue() { return CURRENCY.format(this.dayStats.Order_Value__c || 0); }
    get statCollection() { return CURRENCY.format(this.dayStats.Collection_Total__c || 0); }
    get currentBeatName() {
        if (this.dayAttendance && this.dayAttendance.Beat__r) return this.dayAttendance.Beat__r.Name;
        const b = this.todaysBeats.find(bt => bt.beatId === this.activeBeatId);
        return b ? b.beatName : 'No Beat Assigned';
    }

    // Board tabs
    get isPlannedTab() { return this.boardTab === 'planned'; }
    get isCompletedTab() { return this.boardTab === 'completed'; }
    get isSkippedTab() { return this.boardTab === 'skipped'; }
    get plannedTabCls() { return 'vm-tab' + (this.isPlannedTab ? ' vm-tab-active vm-tab-planned' : ''); }
    get completedTabCls() { return 'vm-tab' + (this.isCompletedTab ? ' vm-tab-active vm-tab-done' : ''); }
    get skippedTabCls() { return 'vm-tab' + (this.isSkippedTab ? ' vm-tab-active vm-tab-skip' : ''); }

    handleBoardTab(e) { this.boardTab = e.currentTarget.dataset.tab; }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // CHECK-IN
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    async handleCheckIn(e) {
        e.stopPropagation();
        const accountId = e.currentTarget.dataset.accountId;
        const beatId = e.currentTarget.dataset.beatId;
        const jpdayId = e.currentTarget.dataset.jpdayId;
        const rawId = e.currentTarget.dataset.id || null;
        const existingVisitId = (rawId && rawId.startsWith('planned_')) ? null : rawId;

        if (!accountId) { this._toast('Error', 'No outlet found.', 'error'); return; }

        // Block if active visit exists
        if (this.activeVisits.length > 0) {
            this._toast('Warning', 'Complete the current active visit first.', 'warning');
            return;
        }

        this.isProcessing = true;
        try {
            const pos = await this._captureLocationAsync();
            const visitData = {
                accountId, beatId: beatId || this.activeBeatId,
                dayAttendanceId: this.dayAttendance.Id,
                journeyPlanDayId: jpdayId || null,
                latitude: pos.latitude, longitude: pos.longitude, accuracy: pos.accuracy,
                batteryLevel: this.batteryLevel,
                networkStatus: this.networkStatus,
                isPlanned: true,
                existingVisitId: existingVisitId
            };

            // Geo-fence validation â€” warn (not block) when outside
            const fenceOk = await this._validateGeofence(accountId, pos, visitData);
            if (!fenceOk) {
                // _validateGeofence opened the warning modal and stored pending data
                this.isProcessing = false;
                return;
            }

            await this._performCheckIn(visitData, accountId);
        } catch (err) {
            this._toast('Error', 'Check-in failed: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    /**
     * Validates the current GPS position against the outlet's geo-fence.
     * Returns true if within fence (or no fence set). Returns false if
     * outside fence â€” in that case, opens the warning modal and stores
     * pending data for retry after user confirms.
     */
    async _validateGeofence(accountId, pos, visitData) {
        try {
            const result = await checkGeofence({
                accountId: accountId,
                currentLat: pos.latitude,
                currentLng: pos.longitude
            });
            if (!result.hasFence || result.withinFence) {
                return true;
            }
            // Outside fence â€” store pending check-in and show warning modal
            this.geofenceDistance = result.distanceMeters;
            this.geofenceRadius = result.radiusMeters;
            this.geofenceOutletName = result.outletLat ? (result.outletName || 'the outlet') : 'the outlet';
            this.geofenceWarningMessage = result.message || '';
            this._pendingCheckIn = { visitData, accountId };
            this.showGeofenceWarning = true;
            return false;
        } catch (err) {
            // If the geo-fence check fails, don't block check-in â€” just proceed
            console.error('Geofence check failed:', err);
            return true;
        }
    }

    /**
     * Actual check-in after geo-fence validation passes (or user confirms override).
     */
    async _performCheckIn(visitData, accountId) {
        const visit = await checkInVisitApex({ visitJson: JSON.stringify(visitData) });
        this._toast('Success', 'Checked in successfully!', 'success');

        this.activeVisit = this._normalizeRecord(visit);
        await this._loadActiveVisitData(visit.Id, accountId);
        this._startVisitTimer();
        this.currentScreen = SCREEN.VISIT_ACTIVE;
        await this._refreshAllData();
    }

    handleGeofenceCancel() {
        this.showGeofenceWarning = false;
        this._pendingCheckIn = null;
        this._toast('Cancelled', 'Check-in cancelled.', 'info');
    }

    async handleGeofenceConfirm() {
        if (!this._pendingCheckIn) {
            this.showGeofenceWarning = false;
            return;
        }
        const { visitData, accountId } = this._pendingCheckIn;
        // Server-side OVE_Visit_Service.checkIn requires geoOverrideReason
        // when the user is outside the geofence. Setting it here signals the
        // server to allow the check-in and persist Geo_Fence_Override_Reason__c
        // for audit/reporting.
        visitData.geoOverrideReason = 'User confirmed physical presence at outlet. ' +
            'Distance: ' + this.geofenceDistance + 'm (radius: ' + this.geofenceRadius + 'm).';

        this.showGeofenceWarning = false;
        this.isProcessing = true;
        try {
            // Ad-hoc visits have isPlanned === false
            if (visitData.isPlanned === false && visitData.adHocReason) {
                await this._performAdHocCheckIn(visitData, accountId);
            } else {
                await this._performCheckIn(visitData, accountId);
            }
        } catch (err) {
            this._toast('Error', 'Check-in failed: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
            this._pendingCheckIn = null;
        }
    }

    async _loadActiveVisitData(visitId, accountId) {
        try {
            const [summary, , outlet] = await Promise.all([
                refreshVisitSummary({ visitId }),
                this._loadActivitiesData(),
                accountId ? getOutletSummaryApex({ accountId }) : Promise.resolve({})
            ]);
            this.activeVisitSummary = this._normalizeRecord(summary) || {};
            this.outletSummary = this._normalizeRecord(outlet) || {};
        } catch (err) {
            console.error('Error loading visit data:', err);
        }
    }

    async _loadActivitiesData() {
        try {
            const visitId = this.activeVisitId || null;
            const activities = this._normalizeRecord(await getVisitActivitiesApex({ visitId }));
            if (activities && activities.length > 0) {
                this.visitActivities = this._processActivities(activities);
                this._ensureVisibleTab();
            }
        } catch (e) {
            this.visitActivities = [
                { id: 'order', label: 'Order', icon: 'standard:orders', completed: false, cardClass: 'va-act-card' },
                { id: 'collection', label: 'Collection', icon: 'standard:currency', completed: false, cardClass: 'va-act-card' },
                { id: 'returns', label: 'Returns', icon: 'standard:return_order', completed: false, cardClass: 'va-act-card' }
            ];
        }
    }

    async _loadOutletSummary(accountId) {
        if (!accountId) return;
        try {
            this.outletSummary = this._normalizeRecord(await getOutletSummaryApex({ accountId })) || {};
        } catch (e) { /* ignore */ }
    }

    _processActivities(activities) {
        return (activities || []).map(a => ({
            ...a,
            completed: false,
            cardClass: 'va-act-card'
        }));
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // VISIT TIMER
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    _startVisitTimer() {
        this._stopVisitTimer();
        this.visitDuration = 0;
        if (this.activeVisit && this.activeVisit.Check_In_Time__c) {
            const start = new Date(this.activeVisit.Check_In_Time__c);
            this.visitDuration = Math.floor((Date.now() - start.getTime()) / 1000);
        }
        this._timerInterval = setInterval(() => { this.visitDuration++; }, 1000);
    }

    _stopVisitTimer() {
        if (this._timerInterval) { clearInterval(this._timerInterval); this._timerInterval = null; }
    }

    get visitDurationDisplay() {
        const secs = Math.abs(this.visitDuration || 0);
        const h = Math.floor(secs / 3600);
        const m = Math.floor((secs % 3600) / 60);
        const s = secs % 60;
        return `${this._pad(h)}:${this._pad(m)}:${this._pad(s)}`;
    }

    get visitCheckInTime() {
        if (!this.activeVisit || !this.activeVisit.Check_In_Time__c) return '--';
        return this._fmtTime(this.activeVisit.Check_In_Time__c);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // ACTIVE VISIT SCREEN
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get activeOutletName() { return this.activeVisit ? (this.activeVisit.Account__r ? this.activeVisit.Account__r.Name : '') : ''; }
    get activeBeatNameDisplay() { return this.activeVisit ? (this.activeVisit.Beat__r ? this.activeVisit.Beat__r.Name : '') : ''; }
    get activeSequence() { return this.activeVisit ? this.activeVisit.Visit_Sequence__c : ''; }
    get activeIsAdHoc() { return this.activeVisit ? this.activeVisit.Is_Ad_Hoc__c : false; }
    get activeOrdersCount() { return this.activeVisitSummary.ordersCount || 0; }
    get activeOrderValue() { return CURRENCY.format(this.activeVisitSummary.totalOrderValue || 0); }
    get activeCollectionAmount() { return CURRENCY.format(this.activeVisitSummary.totalCollection || 0); }
    get activeReturnsCount() { return this.activeVisitSummary.returnsCount || 0; }
    get activeStoreScore() {
        const s = this.activeVisitSummary.storeScore;
        return (s == null) ? '--' : Math.round(s) + '%';
    }
    get activeStoreScoreClass() {
        const s = this.activeVisitSummary.storeScore;
        if (s == null) return 'vm-kpi-val';
        if (s >= 80) return 'vm-kpi-val vm-score-good';
        if (s >= 50) return 'vm-kpi-val vm-score-mid';
        return 'vm-kpi-val vm-score-low';
    }
    get activeStoreScoreCoClass() {
        const s = this.activeVisitSummary.storeScore;
        if (s == null) return 'vm-co-stat-val';
        if (s >= 80) return 'vm-co-stat-val vm-score-good';
        if (s >= 50) return 'vm-co-stat-val vm-score-mid';
        return 'vm-co-stat-val vm-score-low';
    }
    get activeStoreScoreSurveys() { return this.activeVisitSummary.scoredSurveys || 0; }
    get hasActiveStoreScore() { return this.activeStoreScoreSurveys > 0; }
    get activeMustSellCompliance() { return this.activeVisitSummary.mustSellCompliance; }
    get activeMustSellOrdered() { return this.activeVisitSummary.mustSellOrdered || 0; }
    get activeMustSellRequired() { return this.activeVisitSummary.mustSellRequired || 0; }
    get hasActiveMustSellData() { return this.activeMustSellRequired > 0; }
    get activeMustSellComplianceFormatted() {
        if (this.activeMustSellCompliance == null) return '0%';
        return Math.round(this.activeMustSellCompliance) + '%';
    }
    get activeMustSellSummaryText() {
        return this.activeMustSellOrdered + '/' + this.activeMustSellRequired + ' must-sell products ordered';
    }
    get activeMustSellBarStyle() {
        const pct = Math.min(this.activeMustSellCompliance || 0, 100);
        const color = pct >= 100 ? '#2e844a' : (pct >= 50 ? '#dd7a01' : '#ea001e');
        return 'width:' + pct + '%;background:' + color;
    }
    get activeMustSellBadgeClass() {
        if (this.activeMustSellCompliance >= 100) return 'vm-compliance-badge vm-compliance-green';
        if (this.activeMustSellCompliance >= 50) return 'vm-compliance-badge vm-compliance-yellow';
        return 'vm-compliance-badge vm-compliance-red';
    }
    get activeOrders() {
        return (this.activeVisitSummary.orders || []).map(o => {
            const isEditable = o.Status__c === 'Draft';
            return {
                ...o,
                amountFormatted: CURRENCY.format(o.Total_Net_Amount__c || 0),
                // Draft rows become clickable-to-edit; other statuses are
                // read-only (we don't let users mutate approved/active
                // orders via the Order Entry form).
                isEditable,
                rowClass: isEditable ? 'vm-rec-row vm-rec-row_clickable' : 'vm-rec-row'
            };
        });
    }
    get activeCollections() {
        return (this.activeVisitSummary.collections || []).map(c => ({
            ...c,
            amountFormatted: CURRENCY.format(c.Amount__c || 0)
        }));
    }
    get activeReturns() {
        return (this.activeVisitSummary.returns || []).map(r => ({
            ...r,
            amountFormatted: CURRENCY.format(r.Total_Return_Amount__c || 0)
        }));
    }
    get hasActiveOrders() { return this.activeOrders.length > 0; }
    get hasActiveCollections() { return this.activeCollections.length > 0; }
    get hasActiveReturns() { return this.activeReturns.length > 0; }

    // Outlet summary getters
    get outletLastVisit() { return this.outletSummary.lastVisitDate || 'N/A'; }
    get outletOutstanding() {
        return this.outletSummary.creditUtilized != null
            ? CURRENCY.format(this.outletSummary.creditUtilized)
            : (this.outletSummary.outstandingBalanceFormatted || CURRENCY.format(0));
    }
    get outletPendingOrders() { return this.outletSummary.pendingOrders || 0; }
    get outletType() { return this.outletSummary.outletType || '--'; }
    get outletChannel() { return this.outletSummary.channel || '--'; }
    get outletCreditLimit() { return this.outletSummary.creditLimit ? CURRENCY.format(this.outletSummary.creditLimit) : '--'; }
    get outletCity() { return this.outletSummary.city || '--'; }

    // Credit status color code: green within limit, red when outstanding has
    // breached the limit, neutral when no ceiling is configured.
    get _outletLimitNum() { return Number(this.outletSummary.creditLimit) || 0; }
    get _outletOutstandingNum() { return Number(this.outletSummary.creditUtilized) || 0; }
    get _outletAvailableNum() { return this._outletLimitNum - this._outletOutstandingNum; }
    get outletHasCreditLimit() { return this._outletLimitNum > 0; }
    get outletCreditTier() {
        if (this._outletLimitNum <= 0) return 'none';
        if (this._outletAvailableNum <= 0) return 'over';
        const ratio = this._outletAvailableNum / this._outletLimitNum;
        return ratio < 0.2 ? 'low' : (ratio < 0.5 ? 'moderate' : 'good');
    }
    get outletCreditAvailableFormatted() { return CURRENCY.format(this._outletAvailableNum); }
    get outletCreditAvailClass() { return 'vm-credit-avail vm-cavail-' + this.outletCreditTier; }
    get outletCreditDotClass() { return 'vm-cdot vm-cdot-' + this.outletCreditTier; }

    // Active visit tabs
    get isActivitiesVTab() { return this.activeVisitTab === 'activities'; }
    get isOrdersVTab() { return this.activeVisitTab === 'orders'; }
    get isCollectionsVTab() { return this.activeVisitTab === 'collections'; }
    get isMapVTab() { return this.activeVisitTab === 'map'; }
    get isReturnsVTab() { return this.activeVisitTab === 'returns'; }
    get isOutletVTab() { return this.activeVisitTab === 'outlet'; }
    get activitiesVTabCls() { return 'vm-tab' + (this.isActivitiesVTab ? ' vm-tab-active' : ''); }
    get ordersVTabCls() { return 'vm-tab' + (this.isOrdersVTab ? ' vm-tab-active' : ''); }
    get collectionsVTabCls() { return 'vm-tab' + (this.isCollectionsVTab ? ' vm-tab-active' : ''); }
    get returnsVTabCls() { return 'vm-tab' + (this.isReturnsVTab ? ' vm-tab-active' : ''); }
    get mapVTabCls() { return 'vm-tab' + (this.isMapVTab ? ' vm-tab-active' : ''); }
    get outletVTabCls() { return 'vm-tab' + (this.isOutletVTab ? ' vm-tab-active' : ''); }
    get isPendingOrdersVTab() { return this.activeVisitTab === 'pendingorders'; }
    get pendingOrdersVTabCls() { return 'vm-tab' + (this.isPendingOrdersVTab ? ' vm-tab-active' : ''); }

    /**
     * Source for the framed Pending Orders page. The visited outlet is passed
     * through so the board can scope itself to this customer; without it the
     * page falls back to every order the user is allowed to see.
     */
    get pendingOrdersUrl() {
        const accountId = this.activeVisit ? this.activeVisit.Account__c : null;
        return '/apex/PendingOrders' + (accountId ? '?accountId=' + accountId : '');
    }

    /**
     * The Orders / Collections / Returns tabs are just another view of those
     * activities, so they follow the same Visit Activity rules the tiles do â€”
     * otherwise hiding the Returns tile still left a Returns tab open.
     * visitActivities is already filtered server-side, so deriving from it keeps
     * the two in step without a second round trip.
     *
     * An empty list means "not loaded yet" rather than "everything is hidden";
     * showing the tabs is the safer default, since a rep with no tabs at all
     * cannot work at whilst a brief extra tab is harmless.
     */
    get _visibleActivityKeys() {
        return new Set((this.visitActivities || []).map((a) => a.id));
    }
    get _activitiesLoaded() { return (this.visitActivities || []).length > 0; }

    async _loadEnabledActivityKeys() {
        try {
            const keys = await getEnabledActivityKeys();
            this.enabledActivityKeys = keys || [];
            this._enabledKeysLoaded = true;
        } catch (e) {
            // On failure, leave _enabledKeysLoaded false so the getters
            // fall through to showing the tiles (fail open, never hide a
            // working summary because the config call errored).
        }
    }

    // Summary-tile visibility (Orders / Collection) driven by the activity
    // config, so an outlet's tiles vanish when the activity is switched off.
    // Default to showing until the config loads, to avoid a layout flash.
    get showOrders() {
        return !this._enabledKeysLoaded || this.enabledActivityKeys.indexOf('order') !== -1;
    }
    get showCollection() {
        return !this._enabledKeysLoaded || this.enabledActivityKeys.indexOf('collection') !== -1;
    }
    get showReturns() {
        return !this._enabledKeysLoaded || this.enabledActivityKeys.indexOf('returns') !== -1;
    }
    get showMerchandising() {
        return !this._enabledKeysLoaded || this.enabledActivityKeys.indexOf('merchandising') !== -1;
    }
    get showCompetitor() {
        return !this._enabledKeysLoaded || this.enabledActivityKeys.indexOf('competitor') !== -1;
    }
    get showSurvey() {
        return !this._enabledKeysLoaded || this.enabledActivityKeys.indexOf('survey') !== -1;
    }
    get showTicket() {
        return !this._enabledKeysLoaded || this.enabledActivityKeys.indexOf('ticket') !== -1;
    }

    // Store Score on the completed-visit detail view (same aggregate as the
    // active visit, read from detailVisitSummary).
    get detailStoreScore() {
        const s = this.detailVisitSummary.storeScore;
        return (s == null) ? '--' : Math.round(s) + '%';
    }
    get detailStoreScoreClass() {
        const s = this.detailVisitSummary.storeScore;
        if (s == null) return 'vm-kpi-val';
        if (s >= 80) return 'vm-kpi-val vm-score-good';
        if (s >= 50) return 'vm-kpi-val vm-score-mid';
        return 'vm-kpi-val vm-score-low';
    }

    /**
     * First activity-enabled detail tab, so opening a completed visit never
     * lands on a hidden tab (e.g. Orders off â†’ default to the first tab that
     * is actually shown).
     */
    _firstVisibleDetailTab() {
        if (this.showOrders) return 'orders';
        if (this.showCollection) return 'collections';
        if (this.showReturns) return 'returns';
        if (this.showSurvey) return 'surveys';
        if (this.showTicket) return 'tickets';
        if (this.showMerchandising) return 'merchandising';
        if (this.showCompetitor) return 'competitor';
        return 'orders';
    }

    get showOrdersVTab() {
        return !this._activitiesLoaded || this._visibleActivityKeys.has('order');
    }
    get showCollectionsVTab() {
        return !this._activitiesLoaded || this._visibleActivityKeys.has('collection');
    }
    get showReturnsVTab() {
        return !this._activitiesLoaded || this._visibleActivityKeys.has('returns');
    }

    handleActiveVisitTab(e) { this.activeVisitTab = e.currentTarget.dataset.tab; }

    /**
     * Keeps the selection valid when the visible set changes â€” landing on a tab
     * that has since been hidden would render an empty panel with no way back.
     */
    _ensureVisibleTab() {
        const hidden =
            (this.activeVisitTab === 'orders' && !this.showOrdersVTab) ||
            (this.activeVisitTab === 'collections' && !this.showCollectionsVTab) ||
            (this.activeVisitTab === 'returns' && !this.showReturnsVTab);
        if (hidden) this.activeVisitTab = 'activities';
    }

    handleActivityClick(e) {
        const id = e.currentTarget.dataset.id;
        this.activeActivityId = id;
        // Starting a brand-new activity â€” clear any previous draft-edit
        // context so the form doesn't try to rehydrate a stale order.
        this.editDraftOrderId = null;
        this.currentScreen = SCREEN.VISIT_ACTIVITY;
        this._loadActivityData(id);
    }

    /**
     * Click on a Draft order row in the active-visit Orders tab re-opens
     * the Order Entry form pre-populated with that draft's line items,
     * scheme, price list, UOMs, etc. Non-draft orders just no-op here â€”
     * they remain read-only.
     */
    handleOrderRowClick(e) {
        if (e.target.closest('lightning-button-icon')) return;
        const orderId = e.currentTarget.dataset.id;
        const status = e.currentTarget.dataset.status;
        if (!orderId || status !== 'Draft') return;
        this.editDraftOrderId = orderId;
        this.activeActivityId = 'order';
        this.currentScreen = SCREEN.VISIT_ACTIVITY;
    }

    handleActivityBack() {
        this.activeActivityId = null;
        this.editDraftOrderId = null;
        this.currentScreen = SCREEN.VISIT_ACTIVE;
        this.handleRefreshVisitSummary();
        this._loadActivitiesData();
    }

    handleDownloadOrderPdf(event) {
        event.stopPropagation();
        event.preventDefault();
        const orderId = event.currentTarget.dataset.id || event.target.dataset.id;
        if (!orderId) return;
        const url = '/apex/SalesOrderPDF?id=' + orderId;
        if (this._isMobileDevice()) {
            window.location.href = url;
        } else {
            window.open(url, '_blank');
        }
    }

    handleDownloadReceipt(event) {
        event.stopPropagation();
        event.preventDefault();
        const collectionId = event.currentTarget.dataset.id || event.target.dataset.id;
        if (!collectionId) return;
        const url = '/apex/CollectionReceipt?id=' + collectionId;
        if (this._isMobileDevice()) {
            window.location.href = url;
        } else {
            window.open(url, '_blank');
        }
    }

    handleActivityFormSuccess() {
        // Child component (order/collection/return form) already shows its own
        // specific success toast with record details â€” no generic toast here
        // to avoid duplicate notifications.
        this.handleActivityBack();
    }

    async _loadActivityData(activityId) {
        try {
            switch (activityId) {
                case 'stock_check': await this._loadStockCheckData(); break;
                case 'availability': await this._loadAvailabilityData(); break;
                case 'competitor': await this._loadCompetitorData(); break;
                case 'merchandising': await this._loadMerchandisingData(); break;
                case 'survey': await this._loadSurveyData(); break;
                case 'scheme': await this._loadSchemeData(); break;
                case 'ticket': await this._loadTicketData(); break;
                default: break;
            }
        } catch (err) {
            console.error('Error loading activity data:', err);
        }
    }

    // â”€â”€ Stock Check â”€â”€
    async _loadStockCheckData() {
        this.stockIsLoading = true;
        this.stockProductSearch = '';
        this.stockProductResults = [];
        try {
            const stock = this._normalizeRecord(await getDistributorStock({ accountId: this.activeAccountId }));
            this.stockCheckLines = (stock || []).map((s, idx) => ({
                ...s, lineKey: s.Id || ('new-' + idx),
                productName: s.Product_Ext__r ? s.Product_Ext__r.Name : '',
                opening: s.Opening_Stock__c || 0, received: s.Received_Qty__c || 0,
                sold: s.Sold_Qty__c || 0, closing: s.Closing_Stock__c || 0,
                damaged: s.Damaged_Qty__c || 0, batch: s.Batch_No__c || '',
                expiry: s.Expiry_Date__c || null
            }));
        } catch (e) { this.stockCheckLines = []; }
        this.stockIsLoading = false;
    }

    handleStockProductSearch(e) {
        const term = e.target.value;
        this.stockProductSearch = term;
        clearTimeout(this._stockSearchTimer);
        if (term.length < 2) { this.stockProductResults = []; return; }
        this._stockSearchTimer = setTimeout(async () => {
            try {
                const results = this._normalizeRecord(await getProductsForStockCheck({ searchTerm: term }));
                this.stockProductResults = results || [];
            } catch (err) { this.stockProductResults = []; }
        }, 300);
    }

    handleStockProductAdd(e) {
        const productId = e.currentTarget.dataset.id;
        const product = this.stockProductResults.find(p => p.Id === productId);
        if (!product) return;
        if (this.stockCheckLines.some(l => l.Product_Ext__c === productId)) {
            this._toast('Info', 'Product already added.', 'info'); return;
        }
        this.stockCheckLines = [...this.stockCheckLines, {
            lineKey: 'new-' + Date.now(), Product_Ext__c: productId,
            productName: product.Name, opening: 0, received: 0,
            sold: 0, closing: 0, damaged: 0, batch: '', expiry: null
        }];
        this.stockProductResults = [];
        this.stockProductSearch = '';
    }

    handleStockQuantityChange(e) {
        const field = e.target.dataset.field;
        const key = e.target.dataset.key;
        const numericFields = ['opening', 'received', 'sold', 'damaged'];
        const val = numericFields.includes(field) ? (parseFloat(e.target.value) || 0) : e.target.value;
        this.stockCheckLines = this.stockCheckLines.map(l => {
            if (l.lineKey === key) {
                const updated = { ...l, [field]: val };
                updated.closing = (updated.opening || 0) + (updated.received || 0) - (updated.sold || 0) - (updated.damaged || 0);
                return updated;
            }
            return l;
        });
    }

    handleStockLineRemove(e) {
        const key = e.currentTarget.dataset.key;
        this.stockCheckLines = this.stockCheckLines.filter(l => l.lineKey !== key);
    }

    async handleStockCheckSave() {
        if (this.stockCheckLines.length === 0) {
            this._toast('Warning', 'Please add at least one product.', 'warning'); return;
        }
        this.stockIsLoading = true;
        try {
            const entries = this.stockCheckLines.map(l => ({
                id: l.Id || null, productId: l.Product_Ext__c,
                opening: l.opening, received: l.received, sold: l.sold,
                closing: l.closing, damaged: l.damaged,
                batch: l.batch, expiry: l.expiry
            }));
            await saveStockEntries({
                stockJson: JSON.stringify(entries),
                visitId: this.activeVisitId, accountId: this.activeAccountId
            });
            this._toast('Success', 'Distributor stock saved.', 'success');
            this.handleActivityBack();
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
        }
        this.stockIsLoading = false;
    }

    // â”€â”€ Availability & Stock Depth â”€â”€
    get availabilityHasLines() { return this.availabilityLines.length > 0; }
    get availabilityHasResults() { return this.availabilityResults.length > 0; }

    async _loadAvailabilityData() {
        this.availabilityIsLoading = true;
        this.availabilitySearch = '';
        this.availabilityResults = [];
        try {
            const rows = this._normalizeRecord(await getAvailabilityData({
                accountId: this.activeAccountId, visitId: this.activeVisitId
            }));
            this.availabilityLines = (rows || []).map(r => this._availRowFrom(r));
        } catch (e) {
            this.availabilityLines = [];
            this._toast('Error', this._err(e), 'error');
        }
        this.availabilityIsLoading = false;
    }

    handleAvailabilitySearch(e) {
        const term = e.target.value;
        this.availabilitySearch = term;
        clearTimeout(this._availSearchTimer);
        if (!term || term.length < 2) { this.availabilityResults = []; return; }
        this._availSearchTimer = setTimeout(async () => {
            try {
                const results = this._normalizeRecord(await searchAvailabilityProducts({ searchTerm: term }));
                const added = new Set(this.availabilityLines.map(l => l.productId));
                this.availabilityResults = (results || [])
                    .filter(r => !added.has(r.productId))
                    .map(r => ({ ...r, subLabel: (r.sku || '') + ' Â· ' + (r.category || '') }));
            } catch (err) { this.availabilityResults = []; }
        }, 300);
    }

    handleAvailabilityAdd(e) {
        const productId = e.currentTarget.dataset.id;
        const prod = this.availabilityResults.find(r => r.productId === productId);
        if (!prod) return;
        if (this.availabilityLines.some(l => l.productId === productId)) {
            this._toast('Info', 'Product already added.', 'info'); return;
        }
        this.availabilityLines = [...this.availabilityLines, this._availRowFrom({
            ...prod, observedStock: '', sellingPrice: ''
        })];
        this.availabilityResults = [];
        this.availabilitySearch = '';
    }

    handleAvailabilityLineRemove(e) {
        const productId = e.currentTarget.dataset.id;
        this.availabilityLines = this.availabilityLines.filter(l => l.productId !== productId);
    }

    handleAvailabilityInput(e) {
        const productId = e.target.dataset.id;
        const field = e.target.dataset.field;
        const value = e.target.value;
        this.availabilityLines = this.availabilityLines.map(l =>
            l.productId === productId ? this._decorateAvailRow({ ...l, [field]: value }) : l);
    }

    _availRowFrom(r) {
        return this._decorateAvailRow({
            productId: r.productId, sku: r.sku, productName: r.productName,
            category: r.category, rsp: r.rsp, minQty: r.minQty, systemStock: r.systemStock,
            observedStock: (r.observedStock === null || r.observedStock === undefined) ? '' : r.observedStock,
            sellingPrice: (r.sellingPrice === null || r.sellingPrice === undefined) ? '' : r.sellingPrice
        });
    }

    _decorateAvailRow(row) {
        const obs = parseFloat(row.observedStock);
        const min = parseFloat(row.minQty);
        const belowMin = !isNaN(obs) && !isNaN(min) && obs < min;
        const price = parseFloat(row.sellingPrice);
        const rsp = parseFloat(row.rsp);
        let priceFlag = '';
        let priceClass = 'avail-flag';
        if (!isNaN(price) && !isNaN(rsp) && rsp > 0) {
            if (price > rsp) { priceFlag = 'Over RSP'; priceClass = 'avail-flag avail-over'; }
            else if (price < rsp) { priceFlag = 'Under RSP'; priceClass = 'avail-flag avail-under'; }
            else { priceFlag = 'At RSP'; priceClass = 'avail-flag avail-at'; }
        }
        return {
            ...row, belowMin,
            stockClass: belowMin ? 'avail-cell avail-low' : 'avail-cell',
            priceFlag, priceClass
        };
    }

    async handleAvailabilitySave() {
        const entries = this.availabilityLines
            .map(l => ({
                productId: l.productId,
                observedStock: (l.observedStock === '' || l.observedStock === null) ? null : parseFloat(l.observedStock),
                sellingPrice: (l.sellingPrice === '' || l.sellingPrice === null) ? null : parseFloat(l.sellingPrice),
                systemStock: l.systemStock, rsp: l.rsp, minQty: l.minQty
            }))
            .filter(e2 => e2.observedStock !== null || e2.sellingPrice !== null);
        if (entries.length === 0) {
            this._toast('Warning', 'Add a product and capture its stock or price first.', 'warning');
            return;
        }
        this.availabilityIsLoading = true;
        try {
            await saveAvailability({
                entriesJson: JSON.stringify(entries),
                visitId: this.activeVisitId, accountId: this.activeAccountId
            });
            this._toast('Success', 'Availability & stock depth saved.', 'success');
            this.handleActivityBack();
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
        }
        this.availabilityIsLoading = false;
    }

    // â”€â”€ Competitor Activity â”€â”€
    async _loadCompetitorData() {
        this.competitorIsLoading = true;
        try {
            const [entries, companies] = await Promise.all([
                getCompetitorEntriesForVisit({ visitId: this.activeVisitId }),
                getCompetitorMaster()
            ]);
            this.competitorEntries = this._normalizeRecord(entries) || [];
            this.competitorCompanies = (companies || []).map(c => ({ label: c, value: c }));
        } catch (e) { this.competitorEntries = []; this.competitorCompanies = []; }
        this.competitorIsLoading = false;
        this.competitorForm = { competitorCompany: '', competitorSKU: '', competitorPrice: null, ownProductId: null, ownProductName: '', notes: '', photoContentVersionId: null, photoPreview: null };
        this.competitorProductSearch = '';
        this.competitorProductResults = [];
        this.competitorShowProductSearch = false;
    }

    handleCompetitorFormChange(e) {
        const field = e.target.dataset.field;
        const val = e.target.value;
        this.competitorForm = { ...this.competitorForm, [field]: val };
        if (field === 'competitorCompany') {
            if (val && val.length > 0 && this.competitorCompanies.length > 0) {
                const search = val.toLowerCase();
                this.competitorFilteredCompanies = this.competitorCompanies.filter(c => c.label.toLowerCase().includes(search));
                this.competitorShowSuggestions = this.competitorFilteredCompanies.length > 0;
            } else {
                this.competitorShowSuggestions = false;
                this.competitorFilteredCompanies = [];
            }
        }
    }

    handleCompetitorCompanyFocus() {
        if (this.competitorCompanies.length > 0) {
            this.competitorFilteredCompanies = this.competitorCompanies;
            this.competitorShowSuggestions = true;
        }
    }

    handleCompetitorCompanyBlur() {
        // Delay to allow click on suggestion
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.competitorShowSuggestions = false; }, 250);
    }

    handleCompetitorSuggestionClick(e) {
        const company = e.currentTarget.dataset.value;
        this.competitorForm = { ...this.competitorForm, competitorCompany: company };
        this.competitorShowSuggestions = false;
    }

    async handleCompetitorProductSearchChange(e) {
        const term = e.target.value;
        this.competitorProductSearch = term;
        if (term && term.length >= 2) {
            try {
                const results = this._normalizeRecord(await getProductsForStockCheck({ searchTerm: term }));
                this.competitorProductResults = results || [];
                this.competitorShowProductSearch = this.competitorProductResults.length > 0;
            } catch (err) {
                this.competitorProductResults = [];
                this.competitorShowProductSearch = false;
            }
        } else {
            this.competitorProductResults = [];
            this.competitorShowProductSearch = false;
        }
    }

    handleCompetitorProductSelect(e) {
        const productId = e.currentTarget.dataset.id;
        const productName = e.currentTarget.dataset.name;
        this.competitorForm = { ...this.competitorForm, ownProductId: productId, ownProductName: productName };
        this.competitorProductSearch = '';
        this.competitorProductResults = [];
        this.competitorShowProductSearch = false;
    }

    handleCompetitorPhotoUpload(e) {
        this.competitorPhotoUploading = true;
        this._processPhoto(e, async (base64, preview) => {
            this.competitorForm = { ...this.competitorForm, photoPreview: preview };
            try {
                const fileName = 'CompetitorPhoto_' + this.activeAccountId + '_' + (this.competitorForm.competitorCompany || 'entry');
                const contentVersionId = await uploadSurveyPhoto({ base64Data: base64, fileName });
                this.competitorForm = { ...this.competitorForm, photoContentVersionId: contentVersionId };
            } catch (err) {
                this._toast('Error', 'Failed to upload photo.', 'error');
                this.competitorForm = { ...this.competitorForm, photoPreview: null, photoContentVersionId: null };
            }
            this.competitorPhotoUploading = false;
        });
    }

    handleCompetitorPhotoRemove() {
        this.competitorForm = { ...this.competitorForm, photoPreview: null, photoContentVersionId: null };
    }

    handleCompetitorProductClear() {
        this.competitorForm = { ...this.competitorForm, ownProductId: null, ownProductName: '' };
        this.competitorProductSearch = '';
    }

    async handleCompetitorSave() {
        if (!this.competitorForm.competitorCompany) {
            this._toast('Warning', 'Please enter competitor company.', 'warning'); return;
        }
        this.competitorIsLoading = true;
        try {
            const entryData = {
                visitId: this.activeVisitId, accountId: this.activeAccountId,
                competitorCompany: this.competitorForm.competitorCompany,
                competitorSKU: this.competitorForm.competitorSKU,
                competitorPrice: this.competitorForm.competitorPrice ? parseFloat(this.competitorForm.competitorPrice) : null,
                ownProductId: this.competitorForm.ownProductId,
                notes: this.competitorForm.notes,
                photoContentVersionId: this.competitorForm.photoContentVersionId
            };
            await saveCompetitorEntry({ entryJson: JSON.stringify(entryData) });
            this._toast('Success', 'Competitor entry saved.', 'success');
            await this._loadCompetitorData();
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
        }
        this.competitorIsLoading = false;
    }

    async handleCompetitorDelete(e) {
        const entryId = e.currentTarget.dataset.id;
        this.competitorIsLoading = true;
        try {
            await deleteCompetitorEntry({ entryId });
            this._toast('Success', 'Entry removed.', 'success');
            await this._loadCompetitorData();
        } catch (err) { this._toast('Error', this._err(err), 'error'); }
        this.competitorIsLoading = false;
    }

    // â”€â”€ Merchandising Audit â”€â”€
    async _loadMerchandisingData() {
        this.merchandisingIsLoading = true;
        try {
            const merch = this._normalizeRecord(await getMerchandisingForVisit({ visitId: this.activeVisitId }));
            if (merch) {
                this.merchandisingRecord = {
                    id: merch.Id,
                    ownShelfShare: merch.Own_Shelf_Share__c, competitorShelfShare: merch.Competitor_Shelf_Share__c,
                    planogramCompliant: merch.Planogram_Compliant__c || false,
                    posmPresent: merch.POSM_Present__c || false, posmCondition: merch.POSM_Condition__c || '',
                    notes: merch.Notes__c || ''
                };
            } else {
                this.merchandisingRecord = { ownShelfShare: null, competitorShelfShare: null, planogramCompliant: false, posmPresent: false, posmCondition: '', notes: '' };
            }
        } catch (e) {
            this.merchandisingRecord = { ownShelfShare: null, competitorShelfShare: null, planogramCompliant: false, posmPresent: false, posmCondition: '', notes: '' };
        }
        this.merchandisingIsLoading = false;
    }

    handleMerchandisingChange(e) {
        const field = e.target.dataset.field;
        let value = e.target.type === 'toggle' || e.target.type === 'checkbox' ? e.target.checked : e.target.value;
        this.merchandisingRecord = { ...this.merchandisingRecord, [field]: value };
    }

    async handleMerchandisingSave() {
        this.merchandisingIsLoading = true;
        try {
            const data = {
                id: this.merchandisingRecord.id || null,
                visitId: this.activeVisitId, accountId: this.activeAccountId,
                ownShelfShare: this.merchandisingRecord.ownShelfShare ? parseFloat(this.merchandisingRecord.ownShelfShare) : null,
                competitorShelfShare: this.merchandisingRecord.competitorShelfShare ? parseFloat(this.merchandisingRecord.competitorShelfShare) : null,
                planogramCompliant: this.merchandisingRecord.planogramCompliant,
                posmPresent: this.merchandisingRecord.posmPresent,
                posmCondition: this.merchandisingRecord.posmCondition,
                notes: this.merchandisingRecord.notes
            };
            await saveMerchandising({ merchandisingJson: JSON.stringify(data) });
            this._toast('Success', 'Merchandising audit saved.', 'success');
            this.handleActivityBack();
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
        }
        this.merchandisingIsLoading = false;
    }

    // â”€â”€ Survey / Feedback â”€â”€
    async _loadSurveyData() {
        this.surveyIsLoading = true;
        this.selectedSurvey = null;
        this.surveyQuestions = [];
        this.surveyAnswers = {};
        try {
            const surveys = this._normalizeRecord(await getApplicableSurveys({ accountId: this.activeAccountId }));
            this.applicableSurveys = (surveys || []).map(s => ({ label: s.Name, value: s.Id, ...s }));
            if (this.applicableSurveys.length === 1) {
                await this._selectSurvey(this.applicableSurveys[0].Id);
            }
        } catch (e) { this.applicableSurveys = []; }
        this.surveyIsLoading = false;
    }

    async handleSurveySelect(e) {
        const surveyId = e.detail.value;
        await this._selectSurvey(surveyId);
    }

    async _selectSurvey(surveyId) {
        this.surveyIsLoading = true;
        try {
            const result = this._normalizeRecord(await getSurveyWithQuestions({ surveyId }));
            this.selectedSurvey = result.survey;
            this.surveyQuestions = (result.questions || []).map(q => ({
                ...q,
                isText: q.Question_Type__c === 'Text',
                isNumber: q.Question_Type__c === 'Number',
                isRating: q.Question_Type__c === 'Rating',
                isSingleChoice: q.Question_Type__c === 'Single Choice',
                isMultipleChoice: q.Question_Type__c === 'Multiple Choice',
                isPhoto: q.Question_Type__c === 'Photo',
                isDate: q.Question_Type__c === 'Date',
                options: this._parseOptions(q.Options__c),
                selectedValue: '',
                selectedValues: [],
                ratingOptions: [1, 2, 3, 4, 5].map(n => ({ value: n, label: '' + n, cls: 'vm-star' }))
            }));
            this.surveyAnswers = {};
        } catch (e) { this.surveyQuestions = []; }
        this.surveyIsLoading = false;
    }

    handleAnswerChange(e) {
        const qId = e.target.dataset.questionId || e.currentTarget.dataset.questionId;
        const type = e.target.dataset.type || e.currentTarget.dataset.type;
        let value = e.target.value;
        if (type === 'rating') value = parseInt(e.currentTarget.dataset.value, 10);
        if (type === 'Multiple Choice') value = e.detail.value;
        this.surveyAnswers = { ...this.surveyAnswers, [qId]: { type, value } };
        if (type === 'rating' || type === 'Single Choice' || type === 'Multiple Choice') {
            this.surveyQuestions = this.surveyQuestions.map(q => {
                if (q.Id !== qId) return q;
                const updated = { ...q };
                if (type === 'rating') {
                    updated.ratingOptions = q.ratingOptions.map(r => ({
                        ...r, cls: r.value <= value ? 'vm-star vm-star-filled' : 'vm-star'
                    }));
                } else if (type === 'Single Choice') {
                    updated.selectedValue = value;
                } else if (type === 'Multiple Choice') {
                    updated.selectedValues = value;
                }
                return updated;
            });
        }
    }

    handleSurveyPhotoUpload(e) {
        const qId = e.target.dataset.questionId;
        this._processPhoto(e, async (base64, preview) => {
            // Show uploading state and preview
            this.surveyQuestions = this.surveyQuestions.map(q =>
                q.Id === qId ? { ...q, photoUploading: true, photoPreview: preview } : q
            );
            try {
                const fileName = 'SurveyPhoto_' + qId + '_' + Date.now();
                const contentVersionId = await uploadSurveyPhoto({ base64Data: base64, fileName });
                this.surveyAnswers = { ...this.surveyAnswers, [qId]: { type: 'Photo', value: contentVersionId } };
                this.surveyQuestions = this.surveyQuestions.map(q =>
                    q.Id === qId ? { ...q, photoUploading: false } : q
                );
            } catch (err) {
                this._toast('Error', 'Failed to upload photo.', 'error');
                this.surveyQuestions = this.surveyQuestions.map(q =>
                    q.Id === qId ? { ...q, photoUploading: false, photoPreview: null } : q
                );
            }
        });
    }

    async handleSurveySubmit() {
        // Validate required questions
        const unanswered = this.surveyQuestions
            .filter(q => q.Is_Required__c)
            .filter(q => {
                const ans = this.surveyAnswers[q.Id];
                if (!ans) return true;
                const v = ans.value;
                if (v == null || v === '') return true;
                if (Array.isArray(v) && v.length === 0) return true;
                return false;
            });
        if (unanswered.length > 0) {
            this._toast('Required', 'Please answer all mandatory questions marked with *.', 'error');
            return;
        }

        this.surveyIsLoading = true;
        try {
            const answers = Object.entries(this.surveyAnswers).map(([qId, ans]) => ({
                questionId: qId,
                answerText: (ans.type === 'Text' || ans.type === 'Date') ? ans.value : null,
                answerChoice: (ans.type === 'Single Choice' || ans.type === 'Multiple Choice') ? (Array.isArray(ans.value) ? ans.value.join(';') : ans.value) : null,
                answerNumber: ans.type === 'Number' ? parseFloat(ans.value) : null,
                ratingValue: ans.type === 'rating' ? ans.value : null,
                photoContentVersionId: ans.type === 'Photo' ? ans.value : null
            }));
            const responseData = {
                visitId: this.activeVisitId, accountId: this.activeAccountId,
                surveyId: this.selectedSurvey.Id, answers
            };
            await submitSurveyResponse({ responseJson: JSON.stringify(responseData) });
            this._toast('Success', 'Survey submitted.', 'success');
            // Refresh the visit summary so the Store Score reflects this audit
            try {
                const summary = await refreshVisitSummary({ visitId: this.activeVisitId });
                if (summary) this.activeVisitSummary = summary;
            } catch (e) { /* keep existing summary if refresh fails */ }
            this.handleActivityBack();
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
        }
        this.surveyIsLoading = false;
    }

    get surveyOptions() {
        return this.applicableSurveys.map(s => ({ label: s.label, value: s.value }));
    }

    get hasSurveyQuestions() { return this.surveyQuestions.length > 0; }
    get hasMultipleSurveys() { return this.applicableSurveys.length > 1; }

    _parseOptions(optionsRaw) {
        if (!optionsRaw) return [];
        const trimmed = optionsRaw.trim();
        // Support JSON array format: ["A","B"] or [{"label":"A","value":"a"}]
        if (trimmed.startsWith('[')) {
            try {
                const parsed = JSON.parse(trimmed);
                return parsed.map(item =>
                    typeof item === 'string'
                        ? { label: item, value: item }
                        : { label: item.label || item.value, value: item.value || item.label }
                ).filter(o => o.value);
            } catch (e) { /* fall through to semicolon split */ }
        }
        return trimmed.split(/[,;]/).map(o => o.trim()).filter(o => o).map(o => ({ label: o, value: o }));
    }

    // â”€â”€ Scheme Info â”€â”€
    async _loadSchemeData() {
        this.schemeIsLoading = true;
        try {
            this.activeSchemesList = this._normalizeRecord(await getActiveSchemes({ accountId: this.activeAccountId })) || [];
        } catch (e) {
            this.activeSchemesList = [];
            this._toast('Error', 'Failed to load schemes: ' + this._err(e), 'error');
        }
        this.schemeIsLoading = false;
    }

    get hasActiveSchemes() { return this.activeSchemesList.length > 0; }

    // â”€â”€ Ticket / Complaint â”€â”€
    async _loadTicketData() {
        this.ticketIsLoading = true;
        try {
            this.visitTickets = this._normalizeRecord(await getTicketsForVisit({ visitId: this.activeVisitId })) || [];
        } catch (e) { this.visitTickets = []; }
        this.ticketIsLoading = false;
        this.ticketForm = { category: '', priority: 'Medium', subject: '', description: '' };
    }

    handleTicketFormChange(e) {
        const field = e.target.dataset.field;
        this.ticketForm = { ...this.ticketForm, [field]: e.target.value };
    }

    async handleTicketSave() {
        if (!this.ticketForm.subject) {
            this._toast('Warning', 'Please enter a subject.', 'warning'); return;
        }
        this.ticketIsLoading = true;
        try {
            const data = {
                visitId: this.activeVisitId, accountId: this.activeAccountId,
                category: this.ticketForm.category, priority: this.ticketForm.priority,
                subject: this.ticketForm.subject, description: this.ticketForm.description
            };
            await createTicket({ ticketJson: JSON.stringify(data) });
            this._toast('Success', 'Ticket created.', 'success');
            await this._loadTicketData();
        } catch (err) {
            this._toast('Error', this._err(err), 'error');
        }
        this.ticketIsLoading = false;
    }

    get hasVisitTickets() { return this.visitTickets.length > 0; }

    get ticketCategoryOptions() {
        return [
            { label: 'Product Quality', value: 'Product Quality' },
            { label: 'Delivery Issue', value: 'Delivery Issue' },
            { label: 'Pricing Dispute', value: 'Pricing Dispute' },
            { label: 'Service Request', value: 'Service Request' },
            { label: 'Scheme Claim', value: 'Scheme Claim' },
            { label: 'Other', value: 'Other' }
        ];
    }

    get ticketPriorityOptions() {
        return [
            { label: 'Low', value: 'Low' },
            { label: 'Medium', value: 'Medium' },
            { label: 'High', value: 'High' },
            { label: 'Critical', value: 'Critical' }
        ];
    }

    get posmConditionOptions() {
        return [
            { label: 'Good', value: 'Good' },
            { label: 'Average', value: 'Average' },
            { label: 'Poor', value: 'Poor' },
            { label: 'Damaged', value: 'Damaged' },
            { label: 'Missing', value: 'Missing' }
        ];
    }

    async handleRefreshVisitSummary() {
        if (!this.activeVisit) return;
        try {
            const next = this._normalizeRecord(await refreshVisitSummary({ visitId: this.activeVisit.Id })) || {};
            // Replace with a fresh object reference so LWC's @track reactivity
            // picks up the change (including when the orders list grew).
            this.activeVisitSummary = { ...next };
        } catch (e) {
            // Surface failures so missing-order issues can be diagnosed
            // instead of silently eating the error.
            console.error('[VM] refreshVisitSummary failed', e);
        }
    }

    // NAVIGATION: Back to Visit Board from Active Visit
    handleBackToBoard() {
        if (this.activeVisit) {
            this._toast('Warning', 'Please check out the current visit first.', 'warning');
            return;
        }
        this.currentScreen = SCREEN.VISIT_BOARD;
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // COMPLETED VISIT DETAIL
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    async handleCompletedVisitClick(e) {
        const visitId = e.currentTarget.dataset.id;
        const visit = this.allVisits.find(v => v.Id === visitId);
        if (!visit) return;

        this.detailVisit = visit;
        this.detailVisitSummary = {};
        this.detailSurveyResponses = [];
        this.detailVisitTab = this._firstVisibleDetailTab();
        this.currentScreen = SCREEN.VISIT_DETAIL;

        try {
            this.isProcessing = true;
            const [summary, surveyResp, tickets, merchandising, competitors] = await Promise.all([
                refreshVisitSummary({ visitId }),
                getSurveyResponsesForVisit({ visitId }).catch(() => []),
                getTicketsForVisit({ visitId }).catch(() => []),
                getMerchandisingForVisit({ visitId }).catch(() => []),
                getCompetitorEntriesForVisit({ visitId }).catch(() => [])
            ]);
            this.detailVisitSummary = this._normalizeRecord(summary) || {};
            this.detailTickets = this._normalizeRecord(tickets) || [];
            this.detailMerchandising = this._normalizeRecord(merchandising) || [];
            this.detailCompetitorEntries = this._normalizeRecord(competitors) || [];
            this.detailSurveyResponses = (this._normalizeRecord(surveyResp) || []).map(r => ({
                ...r,
                responseDateFmt: r.responseDate ? new Date(r.responseDate).toLocaleDateString() : '',
                answers: (r.answers || []).map(a => ({
                    ...a,
                    ratingStars: a.isRating ? this._buildRatingStars(a.ratingValue) : []
                }))
            }));
        } catch (err) {
            this._toast('Error', 'Failed to load visit details.', 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    handleBackToBoardFromDetail() {
        this.detailVisit = null;
        this.detailVisitSummary = {};
        this.detailSurveyResponses = [];
        this.detailTickets = [];
        this.detailMerchandising = [];
        this.detailCompetitorEntries = [];
        this.currentScreen = SCREEN.VISIT_BOARD;
    }

    handleDetailTab(e) { this.detailVisitTab = e.currentTarget.dataset.tab; }

    // Detail visit getters
    get detailOutletName() { return this.detailVisit ? (this.detailVisit.Account__r ? this.detailVisit.Account__r.Name : '') : ''; }
    get detailBeatName() { return this.detailVisit ? (this.detailVisit.Beat__r ? this.detailVisit.Beat__r.Name : '') : ''; }
    get detailSequence() { return this.detailVisit ? this.detailVisit.Visit_Sequence__c : ''; }
    get detailIsAdHoc() { return this.detailVisit ? this.detailVisit.Is_Ad_Hoc__c : false; }
    get detailIsProductive() { return this.detailVisit ? this.detailVisit.Is_Productive__c : false; }
    get detailCheckInTime() {
        if (!this.detailVisit || !this.detailVisit.Check_In_Time__c) return '--';
        return this._fmtTime(this.detailVisit.Check_In_Time__c);
    }
    get detailCheckOutTime() {
        if (!this.detailVisit || !this.detailVisit.Check_Out_Time__c) return '--';
        return this._fmtTime(this.detailVisit.Check_Out_Time__c);
    }
    get detailDuration() {
        if (!this.detailVisit || !this.detailVisit.Duration_Minutes__c) return '--';
        const mins = this.detailVisit.Duration_Minutes__c;
        const h = Math.floor(mins / 60);
        const m = Math.round(mins % 60);
        return h > 0 ? `${h}h ${m}m` : `${m}m`;
    }
    get detailOrdersCount() { return this.detailVisitSummary.ordersCount || 0; }
    get detailOrderValue() { return CURRENCY.format(this.detailVisitSummary.totalOrderValue || 0); }
    get detailCollectionAmount() { return CURRENCY.format(this.detailVisitSummary.totalCollection || 0); }
    get detailReturnsCount() { return this.detailVisitSummary.returnsCount || 0; }
    get detailOrders() {
        return (this.detailVisitSummary.orders || []).map(o => ({
            ...o,
            amountFormatted: CURRENCY.format(o.Total_Net_Amount__c || 0)
        }));
    }
    get detailCollections() {
        return (this.detailVisitSummary.collections || []).map(c => ({
            ...c,
            amountFormatted: CURRENCY.format(c.Amount__c || 0)
        }));
    }
    get detailReturns() {
        return (this.detailVisitSummary.returns || []).map(r => ({
            ...r,
            amountFormatted: CURRENCY.format(r.Total_Return_Amount__c || 0)
        }));
    }
    get hasDetailOrders() { return this.detailOrders.length > 0; }
    get hasDetailCollections() { return this.detailCollections.length > 0; }
    get hasDetailReturns() { return this.detailReturns.length > 0; }
    get hasDetailSurveyResponses() { return this.detailSurveyResponses.length > 0; }

    // Detail tabs
    get isDetailOrdersTab() { return this.detailVisitTab === 'orders'; }
    get isDetailCollectionsTab() { return this.detailVisitTab === 'collections'; }
    get isDetailReturnsTab() { return this.detailVisitTab === 'returns'; }
    get isDetailSurveysTab() { return this.detailVisitTab === 'surveys'; }
    get detailOrdersTabCls() { return 'vm-tab' + (this.isDetailOrdersTab ? ' vm-tab-active' : ''); }
    get detailCollectionsTabCls() { return 'vm-tab' + (this.isDetailCollectionsTab ? ' vm-tab-active' : ''); }
    get detailReturnsTabCls() { return 'vm-tab' + (this.isDetailReturnsTab ? ' vm-tab-active' : ''); }
    get detailSurveysTabCls() { return 'vm-tab' + (this.isDetailSurveysTab ? ' vm-tab-active' : ''); }
    get isDetailTicketsTab() { return this.detailVisitTab === 'tickets'; }
    get isDetailMerchandisingTab() { return this.detailVisitTab === 'merchandising'; }
    get isDetailCompetitorTab() { return this.detailVisitTab === 'competitor'; }
    get detailTicketsTabCls() { return 'vm-tab' + (this.isDetailTicketsTab ? ' vm-tab-active' : ''); }
    get detailMerchandisingTabCls() { return 'vm-tab' + (this.isDetailMerchandisingTab ? ' vm-tab-active' : ''); }
    get detailCompetitorTabCls() { return 'vm-tab' + (this.isDetailCompetitorTab ? ' vm-tab-active' : ''); }
    get hasDetailTickets() { return this.detailTickets.length > 0; }
    get hasDetailMerchandising() { return this.detailMerchandising.length > 0; }
    get hasDetailCompetitorEntries() { return this.detailCompetitorEntries.length > 0; }

    _buildRatingStars(value) {
        const v = value ? parseInt(value, 10) : 0;
        return [1, 2, 3, 4, 5].map(n => ({
            value: n,
            cls: n <= v ? 'vm-star vm-star-filled' : 'vm-star'
        }));
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // CHECKOUT
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get checkoutDisabled() {
        return this.isProcessing || (!this.isProductive && !this.nonProductiveReason) ||
            !this._checklistComplete;
    }

    get _checklistComplete() {
        if (this.checklistItems.length === 0) return true;
        return this.checklistItems.every(c => c.answer != null);
    }

    get nonProductiveReasonOptions() {
        return [
            { label: 'Shop Closed', value: 'Shop Closed' },
            { label: 'Owner Not Available', value: 'Owner Not Available' },
            { label: 'No Demand', value: 'No Demand' },
            { label: 'Credit Issue', value: 'Credit Issue' },
            { label: 'Access Issue', value: 'Access Issue' },
            { label: 'Weather Conditions', value: 'Weather Conditions' },
            { label: 'Vehicle Breakdown', value: 'Vehicle Breakdown' },
            { label: 'Time Constraint', value: 'Time Constraint' },
            { label: 'Emergency', value: 'Emergency' },
            { label: 'Visit Skipped', value: 'Visit Skipped' },
            { label: 'Other', value: 'Other' }
        ];
    }

    handleCheckoutClick() {
        this.checklistItems = [
            { id: 'stock', label: 'Was distributor stock captured?', answer: null, yesClass: 'vm-yn-btn', noClass: 'vm-yn-btn' },
            { id: 'display', label: 'Was product display verified?', answer: null, yesClass: 'vm-yn-btn', noClass: 'vm-yn-btn' },
            { id: 'feedback', label: 'Was retailer feedback captured?', answer: null, yesClass: 'vm-yn-btn', noClass: 'vm-yn-btn' },
            { id: 'scheme', label: 'Was scheme communication done?', answer: null, yesClass: 'vm-yn-btn', noClass: 'vm-yn-btn' }
        ];
        const hasOrders = this.activeOrdersCount > 0;
        const hasCollections = (this.activeVisitSummary.collectionsCount || 0) > 0;
        const hasReturns = (this.activeVisitSummary.returnsCount || 0) > 0;
        const hasAnyActivity = hasOrders || hasCollections || hasReturns;
        this.isProductive = hasAnyActivity;
        this.nonProductiveReason = '';
        this.visitNotes = '';
        this.showCheckoutModal = true;
    }

    handleCheckoutClose() { this.showCheckoutModal = false; }

    handleChecklistAnswer(e) {
        const id = e.currentTarget.dataset.id;
        const answer = e.currentTarget.dataset.answer;
        this.checklistItems = this.checklistItems.map(c => {
            if (c.id === id) {
                return {
                    ...c,
                    answer,
                    yesClass: answer === 'yes' ? 'vm-yn-btn vm-yn-yes-active' : 'vm-yn-btn',
                    noClass: answer === 'no' ? 'vm-yn-btn vm-yn-no-active' : 'vm-yn-btn'
                };
            }
            return c;
        });
    }

    handleProductiveChange(e) {
        this.isProductive = e.target.checked;
        if (this.isProductive) this.nonProductiveReason = '';
    }

    handleNonProductiveReasonChange(e) { this.nonProductiveReason = e.detail.value; }
    handleVisitNotesChange(e) { this.visitNotes = e.detail.value; }

    async handleCheckoutConfirm() {
        if (this.checkoutDisabled) return;
        this.isProcessing = true;
        try {
            const pos = await this._captureLocationAsync();
            const completedActs = this.checklistItems
                .filter(c => c.answer != null)
                .map(c => c.label.replace(/^Was\s+/i, '').replace(/\?$/, '') + ': ' + (c.answer === 'yes' ? 'Yes' : 'No'))
                .join(', ');

            const data = {
                visitId: this.activeVisit.Id,
                latitude: pos.latitude, longitude: pos.longitude, accuracy: pos.accuracy,
                isProductive: this.isProductive,
                nonProductiveReason: this.nonProductiveReason,
                notes: this.visitNotes,
                completedActivities: completedActs
            };

            await checkOutVisitApex({ visitJson: JSON.stringify(data) });
            this._toast('Success', 'Visit completed!', 'success');
            this._stopVisitTimer();
            this.showCheckoutModal = false;
            this.activeVisit = null;
            this.activeVisitSummary = {};
            this.activeVisitTab = 'activities';
            await this._refreshAllData();
            this.currentScreen = SCREEN.VISIT_BOARD;
        } catch (err) {
            this._toast('Error', 'Checkout failed: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // SKIP VISIT (mandatory reason)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get skipReasonOptions() {
        return [
            { label: 'Shop Closed', value: 'Shop Closed' },
            { label: 'Owner Not Available', value: 'Owner Not Available' },
            { label: 'Access Issue', value: 'Access Issue' },
            { label: 'Weather Conditions', value: 'Weather Conditions' },
            { label: 'Vehicle Breakdown', value: 'Vehicle Breakdown' },
            { label: 'Time Constraint', value: 'Time Constraint' },
            { label: 'Emergency', value: 'Emergency' },
            { label: 'Other', value: 'Other' }
        ];
    }
    get skipDisabled() { return !this.skipReason || this.isProcessing; }

    handleSkipClick(e) {
        e.stopPropagation();
        this.skipVisitId = e.currentTarget.dataset.id;
        this.skipReason = '';
        this.showSkipModal = true;
    }

    handleSkipReasonChange(e) { this.skipReason = e.detail.value; }
    handleSkipClose() { this.showSkipModal = false; this.skipVisitId = null; }

    async handleSkipConfirm() {
        if (!this.skipReason || !this.skipVisitId) return;
        this.isProcessing = true;
        this.showSkipModal = false;
        try {
            const isPlanned = String(this.skipVisitId).startsWith('planned_');
            if (isPlanned) {
                // Planned visits have synthetic IDs: planned_<accountId>_<index>
                const visit = this.allVisits.find(v => v.Id === this.skipVisitId);
                if (!visit) throw new Error('Visit not found.');
                await skipPlannedVisitApex({
                    accountId: visit.Account__c,
                    beatId: visit.Beat__c,
                    attendanceId: this.dayAttendance.Id,
                    skipReason: this.skipReason
                });
            } else {
                await skipVisitApex({ visitId: this.skipVisitId, skipReason: this.skipReason });
            }
            this._toast('Success', 'Visit skipped.', 'success');
            this.allVisits = this.allVisits.map(v =>
                v.Id === this.skipVisitId ? { ...v, Visit_Status__c: VISIT_STATUS.SKIPPED } : v
            );
            await this._refreshAllData();
        } catch (err) {
            this._toast('Error', 'Failed to skip: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
            this.skipVisitId = null;
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // SWITCH BEAT (mandatory reason)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get switchBeatReasonOptions() {
        return [
            { label: 'Road Block', value: 'Road Block' },
            { label: 'Weather Conditions', value: 'Weather Conditions' },
            { label: 'Manager Instructions', value: 'Manager Instructions' },
            { label: 'Market Emergency', value: 'Market Emergency' },
            { label: 'Vehicle Issue', value: 'Vehicle Issue' },
            { label: 'Other', value: 'Other' }
        ];
    }

    get availableBeatsForSwitch() {
        return this.todaysBeats.filter(b => b.beatId !== this.activeBeatId).map(b => ({
            ...b,
            switchCardClass: b.beatId === this.switchBeatId ? 'vm-beat-card vm-beat-selected' : 'vm-beat-card'
        }));
    }

    get switchBeatDisabled() {
        return !this.switchBeatId || !this.switchBeatReason || this.isProcessing;
    }

    handleSwitchBeatClick() {
        if (this.activeVisits.length > 0) {
            this._toast('Warning', 'Complete the current active visit before switching beats.', 'warning');
            return;
        }
        this.switchBeatId = null;
        this.switchBeatReason = '';
        this.showSwitchBeatModal = true;
    }

    handleSwitchBeatSelect(e) {
        this.switchBeatId = e.currentTarget.dataset.beatId;
    }

    handleSwitchBeatReasonChange(e) { this.switchBeatReason = e.detail.value; }
    handleSwitchBeatClose() { this.showSwitchBeatModal = false; }

    async handleSwitchBeatConfirm() {
        if (this.switchBeatDisabled) return;
        this.isProcessing = true;
        this.showSwitchBeatModal = false;
        try {
            const result = await switchBeatApex({
                attendanceId: this.dayAttendance.Id,
                newBeatId: this.switchBeatId,
                reason: this.switchBeatReason
            });
            this.dayAttendance = this._normalizeRecord(result);
            this.activeBeatId = this.switchBeatId;

            await this._refreshAllData();
            this.boardTab = 'planned';
            const beatObj = this.todaysBeats.find(b => b.beatId === this.switchBeatId);
            this._toast('Success', 'Switched to ' + (beatObj ? beatObj.beatName : 'new beat'), 'success');
        } catch (err) {
            this._toast('Error', 'Failed to switch beat: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // AD-HOC VISIT
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    get adHocReasonOptions() {
        return [
            { label: 'New Outlet', value: 'New Outlet' },
            { label: 'Urgent Order', value: 'Urgent Order' },
            { label: 'Manager Request', value: 'Manager Request' },
            { label: 'Market Intelligence', value: 'Market Intelligence' },
            { label: 'Other', value: 'Other' }
        ];
    }
    get adHocSubmitDisabled() { return !this.adHocSelectedAccount || this.isProcessing; }

    handleAdHocClick() {
        this.adHocSearchTerm = '';
        this.adHocSearchResults = [];
        this.adHocSelectedAccount = null;
        this.adHocReason = '';
        this.showAdHocDropdown = false;
        this.showAdHocModal = true;
    }

    handleAdHocSearch(e) {
        const term = e.detail.value || '';
        this.adHocSearchTerm = term;
        if (this._searchTimer) clearTimeout(this._searchTimer);
        if (term.length < 2) { this.adHocSearchResults = []; this.showAdHocDropdown = false; return; }
        this._searchTimer = setTimeout(() => this._doOutletSearch(term), 300);
    }

    async _doOutletSearch(term) {
        try {
            const results = this._normalizeRecord(await searchOutletsApex({ searchTerm: term }));
            this.adHocSearchResults = (results || []).map(a => ({
                id: a.Id, name: a.Name,
                address: [a.BillingStreet, a.BillingCity].filter(Boolean).join(', ') || 'No address',
                code: a.Customer_Code__c || a.AccountNumber || ''
            }));
            this.showAdHocDropdown = this.adHocSearchResults.length > 0;
        } catch (err) {
            this._toast('Error', 'Search failed: ' + this._err(err), 'error');
        }
    }

    handleAdHocSelect(e) {
        const sel = this.adHocSearchResults.find(a => a.id === e.currentTarget.dataset.id);
        if (sel) {
            this.adHocSelectedAccount = sel;
            this.adHocSearchTerm = sel.name;
            this.showAdHocDropdown = false;
        }
    }

    handleAdHocReasonChange(e) { this.adHocReason = e.detail.value; }
    handleAdHocClose() { this.showAdHocModal = false; }

    async handleAdHocConfirm() {
        if (!this.adHocSelectedAccount) return;
        if (this.activeVisits.length > 0) {
            this._toast('Warning', 'Complete the current active visit first.', 'warning');
            return;
        }
        this.isProcessing = true;
        this.showAdHocModal = false;
        try {
            const pos = await this._captureLocationAsync();
            const accountId = this.adHocSelectedAccount.id;
            const data = {
                accountId: accountId,
                dayAttendanceId: this.dayAttendance.Id,
                beatId: this.activeBeatId,
                latitude: pos.latitude, longitude: pos.longitude, accuracy: pos.accuracy,
                batteryLevel: this.batteryLevel,
                networkStatus: this.networkStatus,
                isPlanned: false,
                adHocReason: this.adHocReason || 'Ad-hoc visit'
            };

            // Geo-fence validation â€” warn (not block) when outside
            const fenceOk = await this._validateGeofence(accountId, pos, data);
            if (!fenceOk) {
                this.isProcessing = false;
                return;
            }

            await this._performAdHocCheckIn(data, accountId);
        } catch (err) {
            this._toast('Error', 'Ad-hoc visit failed: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    async _performAdHocCheckIn(data, accountId) {
        const visit = await checkInVisitApex({ visitJson: JSON.stringify(data) });
        this._toast('Success', 'Ad-hoc visit started for ' + this.adHocSelectedAccount.name, 'success');
        this.activeVisit = this._normalizeRecord(visit);
        await this._loadActiveVisitData(visit.Id, accountId);
        this._startVisitTimer();
        this.currentScreen = SCREEN.VISIT_ACTIVE;
        await this._refreshAllData();
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // DAY END
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    handleEndDayClick() {
        if (this.activeVisits.length > 0) {
            this._toast('Warning', 'Complete all active visits before ending the day.', 'warning');
            return;
        }
        this.odometerEnd = null;
        this.endDayRemarks = '';
        this._endSelfieBase64 = null;
        this.endSelfiePreview = null;
        this.showEndDayModal = true;
    }

    handleEndDayClose() { this.showEndDayModal = false; }
    handleOdometerEndChange(e) { this.odometerEnd = e.detail.value ? Number(e.detail.value) : null; }
    handleEndRemarksChange(e) { this.endDayRemarks = e.detail.value; }


    handleEndSelfieCapture(e) {
        this._processPhoto(e, (base64, preview) => {
            this._endSelfieBase64 = base64;
            this.endSelfiePreview = preview;
        });
    }

    handleOpenEndCamera() {
        if (this._isMobileDevice()) {
            this._cameraTarget = 'end';
            this._startCamera();
        } else {
            this._openFileUpload((base64, preview) => {
                this._endSelfieBase64 = base64;
                this.endSelfiePreview = preview;
            });
        }
    }

    removeEndSelfie() { this._endSelfieBase64 = null; this.endSelfiePreview = null; }

    async handleEndDayConfirm() {
        this.isProcessing = true;
        try {
            const pos = await this._captureLocationAsync();
            const data = {
                attendanceId: this.dayAttendance.Id,
                endLatitude: pos.latitude,
                endLongitude: pos.longitude,
                endAccuracy: pos.accuracy,
                selfieBase64: this._endSelfieBase64 || '',
                remarks: this.endDayRemarks || '',
                odometerEnd: this.odometerEnd || 0
            };

            await endDayApex({ dayJson: JSON.stringify(data) });
            this._toast('Success', 'Day ended successfully!', 'success');
            this.showEndDayModal = false;
            this._stopAllIntervals();
            this.dayAttendance = null;
            this.dayStats = {};
            this.allVisits = [];
            this.activeBeatId = null;
            this.selectedBeatId = null;
            this.currentScreen = SCREEN.DAY_START;
            // Reload context so Today's Attendance summary reflects ended state
            await this._loadInitialContext();
        } catch (err) {
            this._toast('Error', 'Failed to end day: ' + this._err(err), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // REFRESH & INTERVALS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    async _refreshAllData() {
        try {
            const data = this._normalizeRecord(await refreshDayData());
            if (data) {
                this.dayStats = data.dayStats || {};
                if (data.currentBeatId) {
                    this.activeBeatId = data.currentBeatId;
                }
                if (data.todaysVisits || data.plannedVisits) {
                    this._processVisits(data.todaysVisits || [], data.plannedVisits || []);
                }
                if (data.hasActiveVisit && data.activeVisit) {
                    this.activeVisit = this._normalizeRecord(data.activeVisit);
                    this.activeVisitSummary = data.activeVisitSummary || {};
                }
            }
        } catch (e) { /* ignore */ }
    }

    async handleBoardRefresh() {
        this.isProcessing = true;
        try {
            await this._refreshAllData();
            if (this.activeVisits.length > 0 && this.currentScreen === SCREEN.VISIT_BOARD) {
                const av = this.activeVisits[0];
                if (av && av.Id && !av.Id.startsWith('planned_')) {
                    this.activeVisit = this._normalizeRecord(av);
                    await this._loadActiveVisitData(av.Id, av.Account__c);
                    this._startVisitTimer();
                    this.currentScreen = SCREEN.VISIT_ACTIVE;
                }
            }
        } catch (e) { /* ignore */ }
        this.isProcessing = false;
    }

    _startStatsRefresh() {
        if (this._statsInterval) clearInterval(this._statsInterval);
        const interval = this.config.statsRefreshInterval || 60000;
        this._statsInterval = setInterval(() => this._refreshAllData(), interval);
    }

    _stopAllIntervals() {
        if (this._statsInterval) { clearInterval(this._statsInterval); this._statsInterval = null; }
        if (this._gpsInterval) { clearInterval(this._gpsInterval); this._gpsInterval = null; }
        this._stopVisitTimer();
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // GPS BREADCRUMB TRACKING
    // Records the rep's location every N minutes while they're on
    // Visit Manager so Day_Attendance__c.Distance_Traveled_Km__c
    // reflects actual travel â€” not just check-in pings.
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    _startGpsTracking() {
        if (!this.config || this.config.gpsTrackingEnabled !== true) return;
        if (!this.dayAttendance || !this.dayAttendance.Id) return;
        if (this._gpsInterval) clearInterval(this._gpsInterval);

        const intervalMs = this.config.gpsTrackingInterval || 300000;
        this._gpsInterval = setInterval(() => this._logGpsBreadcrumb(), intervalMs);
        this._logGpsBreadcrumb();
    }

    _logGpsBreadcrumb() {
        if (!navigator.geolocation) return;
        if (!this.dayAttendance || !this.dayAttendance.Id) return;

        navigator.geolocation.getCurrentPosition(
            (position) => {
                const gpsLog = {
                    sobjectType: 'GPS_Log__c',
                    Day_Attendance__c: this.dayAttendance.Id,
                    Latitude__c: position.coords.latitude,
                    Longitude__c: position.coords.longitude,
                    Accuracy__c: position.coords.accuracy,
                    Timestamp__c: new Date().toISOString(),
                    Battery_Level__c: this.batteryLevel || null
                };
                if (this.networkStatus === 'Offline') {
                    this._enqueueOfflineGps(gpsLog);
                } else {
                    this._sendGpsLog(gpsLog);
                }
            },
            (error) => { console.warn('VisitManager: GPS breadcrumb error', error.message); },
            { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
        );
    }

    async _sendGpsLog(gpsLog) {
        try {
            await logGPS({ gpsLog: gpsLog });
        } catch (error) {
            console.warn('VisitManager: GPS log send failed, queuing offline', error);
            this._enqueueOfflineGps(gpsLog);
        }
    }

    _enqueueOfflineGps(gpsLog) {
        this._offlineGpsQueue.push(gpsLog);
        this._persistOfflineGpsQueue();
    }

    async _syncOfflineGpsQueue() {
        if (this._offlineGpsQueue.length === 0) return;
        try {
            const logsToSync = [...this._offlineGpsQueue];
            await syncOfflineGPSLogs({ gpsLogsJson: JSON.stringify(logsToSync) });
            this._offlineGpsQueue = [];
            this._persistOfflineGpsQueue();
        } catch (error) {
            console.error('VisitManager: Failed to sync offline GPS logs', error);
        }
    }

    _loadOfflineGpsQueue() {
        try {
            const stored = localStorage.getItem(GPS_QUEUE_STORAGE_KEY);
            if (stored) this._offlineGpsQueue = JSON.parse(stored);
        } catch (error) {
            this._offlineGpsQueue = [];
        }
    }

    _persistOfflineGpsQueue() {
        try {
            localStorage.setItem(GPS_QUEUE_STORAGE_KEY, JSON.stringify(this._offlineGpsQueue));
        } catch (error) { /* storage full or disabled â€” ignore */ }
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // PHOTO HELPER
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    @track showCameraOverlay = false;
    _cameraTarget = null;
    _cameraStream = null;
    _videoEl = null;
    _canvasEl = null;

    _isMobileDevice() {
        return /Android|iPhone|iPad|iPod|webOS|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
    }

    _openFileUpload(callback) {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = 'image/*';
        input.style.display = 'none';
        input.addEventListener('change', () => {
            const file = input.files[0];
            if (!file) return;
            if (file.size > 5 * 1024 * 1024) {
                this._toast('Error', 'Photo must be less than 5MB.', 'error');
                return;
            }
            const reader = new FileReader();
            reader.onload = () => {
                callback(reader.result.split(',')[1], reader.result);
            };
            reader.readAsDataURL(file);
        }, { once: true });
        document.body.appendChild(input);
        input.click();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { if (input.parentNode) input.parentNode.removeChild(input); }, 60000);
    }

    _startCamera() {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            this._toast('Error', 'Camera not available on this device.', 'error');
            return;
        }
        this.showCameraOverlay = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => this._initCameraStream(), 150);
    }

    async _initCameraStream() {
        try {
            this._cameraStream = await navigator.mediaDevices.getUserMedia({
                video: { facingMode: 'user', width: { ideal: 720 }, height: { ideal: 960 } },
                audio: false
            });
            const container = this.template.querySelector('.vm-camera-body');
            if (!container) { this._stopCamera(); return; }

            const video = document.createElement('video');
            video.setAttribute('autoplay', '');
            video.setAttribute('playsinline', '');
            video.setAttribute('muted', '');
            video.className = 'vm-camera-video';
            video.srcObject = this._cameraStream;
            video.play();
            container.appendChild(video);
            this._videoEl = video;

            const canvas = document.createElement('canvas');
            canvas.style.display = 'none';
            container.appendChild(canvas);
            this._canvasEl = canvas;
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('Camera access failed', err);
            this._toast('Error', 'Could not access camera. Please allow camera permission.', 'error');
            this.showCameraOverlay = false;
        }
    }

    handleCameraCapture() {
        if (!this._videoEl || !this._canvasEl) return;
        const video = this._videoEl;
        const canvas = this._canvasEl;
        canvas.width = video.videoWidth || 720;
        canvas.height = video.videoHeight || 960;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        const dataUrl = canvas.toDataURL('image/jpeg', 0.8);
        const base64 = dataUrl.split(',')[1];

        if (this._cameraTarget === 'start') {
            this._startSelfieBase64 = base64;
            this.startSelfiePreview = dataUrl;
        } else {
            this._endSelfieBase64 = base64;
            this.endSelfiePreview = dataUrl;
        }
        this._stopCamera();
        this._toast('Success', 'Selfie captured.', 'success');
    }

    handleCameraClose() {
        this._stopCamera();
    }

    _stopCamera() {
        if (this._cameraStream) {
            this._cameraStream.getTracks().forEach(t => t.stop());
            this._cameraStream = null;
        }
        this._videoEl = null;
        this._canvasEl = null;
        this.showCameraOverlay = false;
    }

    _processPhoto(event, callback) {
        const file = event.target.files[0];
        if (!file) return;
        if (file.size > 5 * 1024 * 1024) {
            this._toast('Error', 'Photo must be less than 5MB.', 'error');
            return;
        }
        const reader = new FileReader();
        reader.onload = () => {
            const base64 = reader.result.split(',')[1];
            callback(base64, reader.result);
        };
        reader.readAsDataURL(file);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // UTILITIES
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    _fmtTime(dt) {
        if (!dt) return '--';
        try {
            return new Date(dt).toLocaleTimeString('en-IN', {
                hour: '2-digit', minute: '2-digit', hour12: true
            });
        } catch (e) { return '--'; }
    }

    _fmtDuration(mins) {
        if (!mins && mins !== 0) return '--';
        const h = Math.floor(mins / 60);
        const m = Math.round(mins % 60);
        return h > 0 ? `${h}h ${m}m` : `${m} min`;
    }

    _pad(n) {
        const num = Math.max(0, Math.floor(n || 0));
        return num < 10 ? '0' + num : '' + num;
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _err(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return 'Unknown error';
    }
}