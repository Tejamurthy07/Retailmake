/**
 * @description Full-fledged Dynamic Expense Management LWC
 *              - Single bulk API data loading
 *              - Configuration-driven expense types per band/travel type
 *              - Auto-calculation of DA (working hours) and TA (distance × rate)
 *              - Dynamic add/remove expense line items per day
 *              - Travel-mode-specific TA rates (Bike/Car/Auto/Flight/etc.)
 *              - City-based lodging limits (Metro/Non-Metro)
 *              - Configurable receipt & remarks requirements
 *              - File upload with validation before submit
 *              - Per-line-item approval status tracking
 *              - Comments history with timestamps
 *              - Accordion day view with select-all checkboxes
 *              - Multi-level approval (L1/L2/Finance)
 *              - Responsive design (Desktop/Phone)
 *
 * @author  SFA Development Team
 * @date    2026
 */
import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getExpenseData from '@salesforce/apex/ExpenseController.getExpenseData';
import getOrCreateReport from '@salesforce/apex/ExpenseController.getOrCreateReport';
import saveExpenseItems from '@salesforce/apex/ExpenseController.saveExpenseItems';
import deleteExpenseItems from '@salesforce/apex/ExpenseController.deleteExpenseItems';
import submitReport from '@salesforce/apex/ExpenseController.submitReport';
import approveReport from '@salesforce/apex/ExpenseController.approveReport';
import rejectReport from '@salesforce/apex/ExpenseController.rejectReport';
import markAsPaid from '@salesforce/apex/ExpenseController.markAsPaid';
import getReportSummary from '@salesforce/apex/ExpenseController.getReportSummary';
import getMonthlyOverview from '@salesforce/apex/ExpenseController.getMonthlyOverview';
import getTeamExpenseReports from '@salesforce/apex/ExpenseController.getTeamExpenseReports';
import getExpenseItemFiles from '@salesforce/apex/ExpenseController.getExpenseItemFiles';
import deleteExpenseItemFile from '@salesforce/apex/ExpenseController.deleteExpenseItemFile';
import getSubmitSummary from '@salesforce/apex/ExpenseController.getSubmitSummary';
import uploadReceiptBase64 from '@salesforce/apex/ExpenseController.uploadReceiptBase64';

const MONTHS = [
    { label: 'January', value: 'January' },
    { label: 'February', value: 'February' },
    { label: 'March', value: 'March' },
    { label: 'April', value: 'April' },
    { label: 'May', value: 'May' },
    { label: 'June', value: 'June' },
    { label: 'July', value: 'July' },
    { label: 'August', value: 'August' },
    { label: 'September', value: 'September' },
    { label: 'October', value: 'October' },
    { label: 'November', value: 'November' },
    { label: 'December', value: 'December' }
];

const DA_MIN_HOURS = 4;
const DA_HALF_DAY_HOURS = 8;

const VEHICLE_OPTIONS = [
    { label: 'Bike', value: 'Bike' },
    { label: 'Car', value: 'Car' },
    { label: 'Auto', value: 'Auto' },
    { label: 'Bus', value: 'Bus' },
    { label: 'Bus: AC', value: 'Bus: AC' },
    { label: 'Bus: Non-AC', value: 'Bus: Non-AC' },
    { label: 'Train', value: 'Train' },
    { label: 'Train: 1AC', value: 'Train: 1AC' },
    { label: 'Train: 2AC', value: 'Train: 2AC' },
    { label: 'Train: 3AC', value: 'Train: 3AC' },
    { label: 'Train: Sleeper', value: 'Train: Sleeper' },
    { label: 'Train: General', value: 'Train: General' },
    { label: 'Flight', value: 'Flight' },
    { label: 'Flight: Business', value: 'Flight: Business' },
    { label: 'Flight: Economy', value: 'Flight: Economy' },
    { label: 'Flight: Premium Economy', value: 'Flight: Premium Economy' },
    { label: 'Own Bike', value: 'Own Bike' },
    { label: 'Own Car', value: 'Own Car' },
    { label: 'Public Transport', value: 'Public Transport' }
];

const TRAVEL_MODE_OPTIONS = [
    { label: 'Bike', value: 'Bike' },
    { label: 'Car', value: 'Car' },
    { label: 'Auto', value: 'Auto' },
    { label: 'Bus', value: 'Bus' },
    { label: 'Bus: AC', value: 'Bus: AC' },
    { label: 'Bus: Non-AC', value: 'Bus: Non-AC' },
    { label: 'Train', value: 'Train' },
    { label: 'Train: 1AC', value: 'Train: 1AC' },
    { label: 'Train: 2AC', value: 'Train: 2AC' },
    { label: 'Train: 3AC', value: 'Train: 3AC' },
    { label: 'Train: Sleeper', value: 'Train: Sleeper' },
    { label: 'Train: General', value: 'Train: General' },
    { label: 'Flight', value: 'Flight' },
    { label: 'Flight: Business', value: 'Flight: Business' },
    { label: 'Flight: Economy', value: 'Flight: Economy' },
    { label: 'Flight: Premium Economy', value: 'Flight: Premium Economy' },
    { label: 'Own Bike', value: 'Own Bike' },
    { label: 'Own Car', value: 'Own Car' },
    { label: 'Public Transport', value: 'Public Transport' }
];

const CITY_TIER_OPTIONS = [
    { label: 'Tier 1 (Metro)', value: 'Tier 1' },
    { label: 'Tier 2', value: 'Tier 2' },
    { label: 'Tier 3', value: 'Tier 3' }
];

export default class ExpenseManager extends NavigationMixin(LightningElement) {
    // ── State ─────────────────────────────────────────────────────
    @track currentScreen = 'LOADING';
    @track selectedMonth;
    @track selectedYear;
    @track expense = {};
    @track employee = {};
    @track eligibleDates = [];
    @track eligibilityRules = [];
    @track expenseTypePicklist = [];
    @track config = {};

    // Accordion day list
    @track dayRows = [];
    @track showDayExpenses = false;
    @track selectAllDays = false;

    // Summary / Overview / Team
    @track summary = {};
    @track monthlyOverview = [];
    @track teamReports = [];

    // Approval modal
    @track showApprovalModal = false;
    @track approvalRemarks = '';
    @track approvalAction = '';
    @track approvalExpenseId = null;
    @track approvalLevel = '';

    // Submit confirmation
    @track showSubmitConfirmModal = false;
    @track submitSummary = {};
    @track submitRemarks = '';

    // Comments
    @track showCommentsModal = false;
    @track commentsHistory = [];

    // Active tab
    @track activeTab = 'expense';

    // Loading/error/messages
    @track isLoading = false;
    @track errorMessage = '';
    @track successMessage = '';
    @track saveError = '';

    // Options
    monthOptions = MONTHS;
    vehicleOptions = VEHICLE_OPTIONS;
    travelModeOptions = TRAVEL_MODE_OPTIONS;
    cityTierOptions = CITY_TIER_OPTIONS;

    // City tier & employee data
    cityTiers = {};        // Map<cityName, tier>
    employeeHQCity = '';
    @track cityOptions = [];  // [{label, value}] built from cityTiers

    get yearOptions() {
        const now = new Date();
        const y = now.getFullYear();
        return [
            { label: String(y - 1), value: y - 1 },
            { label: String(y), value: y },
            { label: String(y + 1), value: y + 1 }
        ];
    }

    // ── Lifecycle ────────────────────────────────────────────────
    _pullToRefreshHandler;
    _touchStartY = 0;

    connectedCallback() {
        this._disablePullToRefresh();
        const now = new Date();
        this.selectedMonth = MONTHS[now.getMonth()].value;
        this.selectedYear = now.getFullYear();
        this.loadExpenseData();
    }

    disconnectedCallback() {
        this._enablePullToRefresh();
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

    async loadExpenseData() {
        try {
            this.isLoading = true;
            this.clearMessages();
            this.showDayExpenses = false;
            this.dayRows = [];
            this.selectAllDays = false;

            const data = await getExpenseData({
                month: this.selectedMonth,
                year: this.selectedYear
            });

            this.expense = data.expense || {};
            this.employee = data.employee || {};
            this.eligibilityRules = data.eligibilityRules || [];
            this.expenseTypePicklist = data.expenseTypePicklist || [];
            this.eligibleDates = data.eligibleDates || [];
            this.config = data.config || {};
            this.cityTiers = data.cityTiers || {};
            this.employeeHQCity = data.hqCity || '';

            // Build city options from cityTiers map for searchable combobox
            this.cityOptions = Object.keys(this.cityTiers)
                .sort()
                .map(name => ({ label: name + ' (' + this.cityTiers[name] + ')', value: name }));

            // Store existing items and files for later use
            this._existingItems = data.expenseItems || [];
            this._existingFiles = data.files || [];

            this.currentScreen = 'MAIN';

            // Auto-show day expenses if there are eligible dates
            if (this.eligibleDates.length > 0) {
                this.handleAddDayExpenses();
            }
        } catch (e) {
            this.showError(e);
            this.currentScreen = 'MAIN';
        } finally {
            this.isLoading = false;
        }
    }

    // ── Event Handlers ───────────────────────────────────────────
    handleMonthChange(event) {
        this.selectedMonth = event.detail.value;
        this.loadExpenseData();
    }

    handleYearChange(event) {
        this.selectedYear = parseInt(event.detail.value, 10);
        this.loadExpenseData();
    }

    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.tab;
        if (this.activeTab === 'overview') {
            this.loadMonthlyOverview();
        } else if (this.activeTab === 'team') {
            this.loadTeamReports();
        } else if (this.activeTab === 'summary') {
            this.loadSummary();
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // ADD DAY EXPENSES — Build accordion from eligibility rules
    // ═══════════════════════════════════════════════════════════════

    handleAddDayExpenses() {
        if (this.eligibleDates.length === 0) return;

        this.saveError = '';

        // Group existing items by date
        const itemsByDate = {};
        (this._existingItems || []).forEach(item => {
            const d = item.Expense_Date__c;
            if (!itemsByDate[d]) itemsByDate[d] = [];
            itemsByDate[d].push(item);
        });

        // Group files by item ID
        const filesByItem = {};
        (this._existingFiles || []).forEach(f => {
            const itemId = f.expenseItemId;
            if (!filesByItem[itemId]) filesByItem[itemId] = [];
            filesByItem[itemId].push(f);
        });

        // Build day rows
        this.dayRows = this.eligibleDates.map((dayInfo) => {
            const dateStr = dayInfo.date;
            const existingItems = itemsByDate[dateStr] || [];

            // Auto-calculate hours from checkIn/checkOut if both available
            let hoursWorked = dayInfo.hoursWorked || 0;
            let missingCheckOut = false;
            if (dayInfo.checkIn && dayInfo.checkOut) {
                const diff = this.calcHoursBetween(dayInfo.checkIn, dayInfo.checkOut);
                if (diff > 0) hoursWorked = diff;
            } else if (dayInfo.checkIn && !dayInfo.checkOut) {
                missingCheckOut = true;
                // hoursWorked stays as server value or 0 for manual entry
            }

            // Build items: all eligibility expense types for each day
            // (deduplicated by expense type)
            const items = [];
            const usedTypes = new Set();

            const dutyType = dayInfo.dutyType || 'HQ';

            const seenTypes = new Set();
            this.eligibilityRules.forEach(rule => {
                if (seenTypes.has(rule.Expense_Type__c)) return;
                // Match rule by duty type
                const ruledt = rule.Travel_Type__c || 'All';
                if (ruledt !== 'All' && ruledt !== dutyType) return;
                const existing = existingItems.find(i => i.Expense_Type__c === rule.Expense_Type__c);
                if (!existing && rule.Auto_Create__c === false) return;
                const matchedRule = existing
                    ? this.findRuleForItem(existing.Expense_Type__c, dutyType)
                    : rule;
                items.push(this.buildItemFromRule(matchedRule || rule, existing, dateStr, dayInfo, filesByItem, hoursWorked));
                usedTypes.add(rule.Expense_Type__c);
                seenTypes.add(rule.Expense_Type__c);
            });

            // Add any existing items that don't match auto-create rules
            existingItems.forEach(existing => {
                if (!usedTypes.has(existing.Expense_Type__c)) {
                    const rule = this.findRuleForItem(existing.Expense_Type__c, dutyType);
                    items.push(this.buildItemFromRule(rule, existing, dateStr, dayInfo, filesByItem, hoursWorked));
                }
            });

            const dayTotal = items.reduce((sum, i) => sum + (i.claimedAmount || 0), 0);

            return {
                key: dateStr,
                dateStr: dateStr,
                formattedDate: this.formatDisplayDate(dateStr),
                beatName: dayInfo.beatName || '',
                attendanceId: dayInfo.attendanceId,
                gpsDistance: dayInfo.gpsDistance || 0,
                hoursWorked: hoursWorked,
                checkIn: dayInfo.checkIn || null,
                checkOut: dayInfo.checkOut || null,
                missingCheckOut: missingCheckOut,
                dutyType: dutyType,
                dutyTypeClass: 'duty-badge duty-' + dutyType.toLowerCase().replace('-', ''),
                expanded: false,
                selected: false,
                items: items,
                dayTotal: Math.round(dayTotal * 100) / 100,
                dayTotalClass: dayTotal > 0 ? 'day-total-badge day-total-positive' : 'day-total-badge',
                rowClass: 'day-accordion-row'
            };
        });

        this.showDayExpenses = true;
    }

    findRuleForItem(expenseType, dutyType) {
        const dt = dutyType || 'All';
        let rule = this.eligibilityRules.find(
            r => r.Expense_Type__c === expenseType && (r.Travel_Type__c || 'All') === dt
        );
        if (!rule) {
            rule = this.eligibilityRules.find(
                r => r.Expense_Type__c === expenseType && (r.Travel_Type__c || 'All') === 'All'
            );
        }
        if (!rule) {
            rule = this.eligibilityRules.find(r => r.Expense_Type__c === expenseType);
        }
        return rule || null;
    }

    // Get allowed travel modes from rule's Allowed_Travel_Modes__c multi-select
    getAllowedModesForRule(rule) {
        if (!rule || !rule.Allowed_Travel_Modes__c) return TRAVEL_MODE_OPTIONS;
        const allowed = rule.Allowed_Travel_Modes__c.split(';').map(s => s.trim());
        if (allowed.includes('All')) return TRAVEL_MODE_OPTIONS;
        return allowed.map(m => ({ label: m, value: m }));
    }

    // Get mode rate config from rule's child Expense_Rate_Slabs__r
    getModeRateConfig(rule, travelMode) {
        const slabs = rule?.Expense_Rate_Slabs__r || [];
        return slabs.find(s => s.Travel_Mode__c === travelMode && s.Distance_From__c == null) || null;
    }

    // Get distance slabs for a specific mode
    getSlabsForMode(rule, travelMode) {
        const slabs = rule?.Expense_Rate_Slabs__r || [];
        return slabs.filter(s => s.Travel_Mode__c === travelMode && s.Distance_From__c != null)
            .sort((a, b) => (a.Sort_Order__c || 0) - (b.Sort_Order__c || 0));
    }

    buildItemFromRule(rule, existing, dateStr, dayInfo, filesByItem, hoursWorked) {
        const isTravel = rule && (rule.Rate_Type__c === 'Per KM' || (rule.Min_Distance_KM__c && rule.Min_Distance_KM__c > 0));
        const isDA = rule && rule.Rate_Type__c === 'Per Day';
        const isActual = rule && rule.Rate_Type__c === 'Actual';
        const hasCityTierLimits = rule && (
            rule.City_Tier_1_Limit__c > 0 || rule.City_Tier_2_Limit__c > 0 || rule.City_Tier_3_Limit__c > 0
        );
        const hasMetroLimits = rule && (
            rule.Lodging_Metro_Limit__c > 0 || rule.Lodging_Non_Metro_Limit__c > 0
        );
        const isLodging = hasCityTierLimits || hasMetroLimits;
        const isFood = rule && rule.Expense_Type__c === 'Food';
        const showFromTo = rule && rule.Expense_Category__c === 'Travel' && rule.Rate_Type__c === 'Per KM';
        const showVehicle = false; // consolidated into Travel Mode
        const allowedModes = rule ? this.getAllowedModesForRule(rule) : [];
        const showTravelMode = isTravel && allowedModes.length > 0;
        const showRemarks = true;
        const needsCity = isLodging || (rule && rule.Expense_Category__c === 'Travel' && hasCityTierLimits);
        const showCity = needsCity;
        const showCityTier = needsCity;
        const mandatoryRemarks = rule && rule.Mandatory_Remarks__c;
        const dutyType = existing ? existing.Duty_Type__c : (dayInfo.dutyType || 'HQ');

        const itemFiles = existing && existing.Id ? (filesByItem[existing.Id] || []) : [];

        const item = {
            key: dateStr + '-' + (rule ? rule.Expense_Type__c : (existing ? existing.Expense_Type__c : 'Unknown')),
            id: existing ? existing.Id : null,
            expenseType: rule ? rule.Expense_Type__c : (existing ? existing.Expense_Type__c : ''),
            category: rule ? rule.Expense_Category__c : (existing ? existing.Expense_Category__c : ''),
            rateType: rule ? rule.Rate_Type__c : (existing ? existing.Rate_Type__c : ''),
            rateAmount: rule ? (rule.Rate_Amount__c || 0) : (existing ? existing.Rate_Amount__c : 0),
            maxPerDay: rule ? (rule.Max_Per_Day__c || 0) : 0,
            minDistance: rule ? (rule.Min_Distance_KM__c || 0) : 0,
            dailyKmLimit: rule ? (rule.Daily_KM_Limit__c || 0) : 0,
            receiptRequired: rule ? rule.Receipt_Required__c : (existing ? existing.Receipt_Required__c : false),
            receiptThreshold: rule ? (rule.Receipt_Threshold__c || 0) : 0,
            mandatoryRemarks: mandatoryRemarks,
            lodgingMetroLimit: rule ? (rule.Lodging_Metro_Limit__c || 0) : 0,
            lodgingNonMetroLimit: rule ? (rule.Lodging_Non_Metro_Limit__c || 0) : 0,
            gpsDistance: existing ? existing.GPS_Distance_KM__c : (dayInfo.gpsDistance || 0),
            manualDistance: existing ? existing.Manual_Distance_KM__c : null,
            overrideReason: existing ? existing.Distance_Override_Reason__c : '',
            eligibleAmount: existing ? existing.Eligible_Amount__c : 0,
            claimedAmount: existing ? existing.Claimed_Amount__c : 0,
            approvedAmount: existing ? existing.Approved_Amount__c : null,
            fromLocation: existing ? existing.From_Location__c : '',
            toLocation: existing ? existing.To_Location__c : '',
            notes: existing ? existing.Notes__c : '',
            vehicleType: existing ? existing.Vehicle_Type__c : '',
            travelMode: existing ? (existing.Travel_Mode__c || '') : '',
            city: existing ? existing.City__c : '',
            isMetro: existing ? existing.Is_Metro__c : false,
            workingHours: existing ? existing.Working_Hours__c : hoursWorked,
            approvalStatus: existing ? existing.Approval_Status__c : 'Not Submitted',
            approverComments: existing ? existing.Approver_Comments__c : '',
            isEligible: existing ? existing.Is_Eligible__c : true,
            dutyType: dutyType,
            cityTier: existing ? (existing.City_Tier__c || '') : '',
            cityTier1Limit: rule ? (rule.City_Tier_1_Limit__c || 0) : 0,
            cityTier2Limit: rule ? (rule.City_Tier_2_Limit__c || 0) : 0,
            cityTier3Limit: rule ? (rule.City_Tier_3_Limit__c || 0) : 0,
            allowedTravelModes: allowedModes,
            modeRateConfig: null,
            modeSlabs: [],
            hasSlabs: false,
            hasExisting: !!existing,
            isActual: isActual,
            isTravel: isTravel,
            isDA: isDA,
            isLodging: isLodging,
            isFood: isFood,
            showFromTo: showFromTo,
            showVehicle: showVehicle,
            showTravelMode: showTravelMode,
            showRemarks: showRemarks,
            showCity: showCity,
            showCityTier: showCityTier,
            showOverrideReason: isTravel && existing && existing.GPS_Distance_KM__c > 0 && existing.Manual_Distance_KM__c != null && existing.Manual_Distance_KM__c !== existing.GPS_Distance_KM__c,
            systemCalcAmount: existing ? (existing.System_Calculated_Amount__c || 0) : 0,
            exceedsEligible: false,
            lodgingLimitExceeded: false,
            lodgingTierLimit: 0,
            statusLabel: existing ? this.getItemStatusLabel(existing.Approval_Status__c) : 'New',
            statusClass: existing ? this.getItemStatusClass(existing.Approval_Status__c) : 'item-status item-status-new',
            isReadonly: existing ? ['Submitted', 'Pending', 'L1 Approved', 'L2 Approved', 'Finance Approved'].includes(existing.Approval_Status__c) : false,
            files: itemFiles,
            hasFiles: itemFiles.length > 0,
            hasAnyFiles: itemFiles.length > 0,
            pendingFiles: [],
            hasPendingFiles: false,
            dirty: false
        };

        // Resolve mode-specific rate config if travel mode is set
        if (item.travelMode && rule) {
            const modeConfig = this.getModeRateConfig(rule, item.travelMode);
            const modeSlabs = this.getSlabsForMode(rule, item.travelMode);
            item.modeRateConfig = modeConfig;
            item.modeSlabs = modeSlabs;
            item.hasSlabs = modeSlabs.length > 0;
            if (modeConfig) {
                item.rateType = modeConfig.Rate_Type__c || item.rateType;
                item.rateAmount = modeConfig.Rate_Amount__c || item.rateAmount;
                item.isActual = (modeConfig.Rate_Type__c === 'Actual');
                item.isTravel = (modeConfig.Rate_Type__c === 'Per KM');
                item.showFromTo = item.isTravel;
            }
        }

        // Always recalculate eligible amount from current rule + attendance data
        item.eligibleAmount = this.recalcEligible(item);

        return item;
    }

    buildGenericItem(expenseType, dateStr, dayInfo) {
        // Even without an eligibility rule, infer which travel/lodging fields
        // should be visible based on the expense type name so users can still
        // fill From/To/Mode/City when claiming actuals.
        const et = (expenseType || '').toLowerCase();
        const isTravel = et.includes('travel') || et.includes('conveyance') ||
                         et.includes('fuel') || et.includes('taxi') || et.includes('cab');
        const isDA = et.includes('daily allowance') || et.includes(' da ') || et === 'da';
        const isLodging = et.includes('lodging') || et.includes('hotel') ||
                          et.includes('accommodation') || et.includes('stay');
        const isFood = et.includes('food') || et.includes('meal');

        const showFromTo = isTravel;
        const showTravelMode = isTravel;
        const showCity = isLodging || isTravel;

        return {
            key: dateStr + '-' + expenseType,
            id: null,
            expenseType: expenseType,
            category: isTravel ? 'Travel' : (isLodging ? 'Lodging' : (isFood ? 'Food' : 'Miscellaneous')),
            rateType: 'Actual',
            rateAmount: 0,
            maxPerDay: 0,
            minDistance: 0,
            dailyKmLimit: 0,
            receiptRequired: false,
            receiptThreshold: 0,
            mandatoryRemarks: false,
            lodgingMetroLimit: 0,
            lodgingNonMetroLimit: 0,
            gpsDistance: dayInfo.gpsDistance || 0,
            manualDistance: null,
            overrideReason: '',
            eligibleAmount: 0,
            claimedAmount: 0,
            approvedAmount: null,
            fromLocation: '',
            toLocation: '',
            notes: '',
            vehicleType: '',
            travelMode: '',
            allowedTravelModes: isTravel ? [
                { label: 'Own Bike', value: 'Own Bike' },
                { label: 'Own Car', value: 'Own Car' },
                { label: 'Bike', value: 'Bike' },
                { label: 'Car', value: 'Car' },
                { label: 'Auto', value: 'Auto' },
                { label: 'Bus', value: 'Bus' },
                { label: 'Train', value: 'Train' },
                { label: 'Flight', value: 'Flight' },
                { label: 'Public Transport', value: 'Public Transport' }
            ] : [],
            city: '',
            isMetro: false,
            workingHours: dayInfo.hoursWorked || 0,
            approvalStatus: 'Not Submitted',
            approverComments: '',
            isEligible: true,
            hasExisting: false,
            isActual: true,
            isTravel: isTravel,
            isDA: isDA,
            isLodging: isLodging,
            isFood: isFood,
            showFromTo: showFromTo,
            showVehicle: false,
            showTravelMode: showTravelMode,
            showRemarks: true,
            showCity: showCity,
            showCityTier: false,
            systemCalcAmount: 0,
            exceedsEligible: false,
            lodgingLimitExceeded: false,
            lodgingTierLimit: 0,
            statusLabel: 'New',
            statusClass: 'item-status item-status-new',
            isReadonly: false,
            files: [],
            hasFiles: false,
            hasAnyFiles: false,
            pendingFiles: [],
            hasPendingFiles: false,
            dirty: false
        };
    }

    getItemStatusLabel(status) {
        if (!status || status === 'Not Submitted') return 'Saved';
        return status;
    }

    getItemStatusClass(status) {
        if (!status || status === 'Not Submitted') return 'item-status item-status-saved';
        if (status === 'Pending') return 'item-status item-status-pending';
        if (status === 'L1 Approved' || status === 'L2 Approved') return 'item-status item-status-approved';
        if (status === 'Finance Approved') return 'item-status item-status-finance';
        if (status === 'Rejected') return 'item-status item-status-rejected';
        return 'item-status item-status-saved';
    }

    formatDisplayDate(dateStr) {
        const parts = dateStr.split('-');
        const d = new Date(parseInt(parts[0], 10), parseInt(parts[1], 10) - 1, parseInt(parts[2], 10));
        const weekday = d.toLocaleDateString('en-IN', { weekday: 'short' });
        const formatted = d.toLocaleDateString('en-IN', { day: '2-digit', month: '2-digit', year: 'numeric' });
        return weekday + ', ' + formatted;
    }

    // ═══════════════════════════════════════════════════════════════
    // ADD / REMOVE LINE ITEMS PER DAY
    // ═══════════════════════════════════════════════════════════════

    get availableExpenseTypes() {
        // Include all picklist values, plus any from eligibility rules
        const seen = new Set();
        const options = [];
        // Eligibility rule types first
        this.eligibilityRules.forEach(r => {
            if (!seen.has(r.Expense_Type__c)) {
                seen.add(r.Expense_Type__c);
                options.push({ label: r.Expense_Type__c, value: r.Expense_Type__c });
            }
        });
        // Then remaining picklist values
        (this.expenseTypePicklist || []).forEach(val => {
            if (!seen.has(val)) {
                seen.add(val);
                options.push({ label: val, value: val });
            }
        });
        return options;
    }

    handleAddLineItem(event) {
        const dateStr = event.currentTarget.dataset.date;
        const typeToAdd = event.currentTarget.dataset.type;
        if (!typeToAdd) return;

        const rule = this.findRuleForItem(typeToAdd, null);
        if (!rule) return;

        this.dayRows = this.dayRows.map(row => {
            if (row.dateStr !== dateStr) return row;

            // Check if type already exists
            if (row.items.find(i => i.expenseType === typeToAdd)) {
                return row; // already exists
            }

            const dayInfo = this.eligibleDates.find(d => d.date === dateStr) || {};
            const newItem = this.buildItemFromRule(rule, null, dateStr, dayInfo, {}, dayInfo.hoursWorked || 0);
            const items = [...row.items, newItem];
            const dayTotal = items.reduce((sum, i) => sum + (i.claimedAmount || 0), 0);

            return {
                ...row,
                items,
                dayTotal: Math.round(dayTotal * 100) / 100,
                dayTotalClass: dayTotal > 0 ? 'day-total-badge day-total-positive' : 'day-total-badge'
            };
        });
    }

    handleAddTypeChange(event) {
        const dateStr = event.currentTarget.dataset.date;
        const typeToAdd = event.detail.value;
        if (!typeToAdd || !dateStr) return;

        this.dayRows = this.dayRows.map(row => {
            if (row.dateStr !== dateStr) return row;

            if (row.items.find(i => i.expenseType === typeToAdd)) {
                return row;
            }

            const dayInfo = this.eligibleDates.find(d => d.date === dateStr) || {};
            const rule = this.findRuleForItem(typeToAdd, null);
            let newItem;
            if (rule) {
                newItem = this.buildItemFromRule(rule, null, dateStr, dayInfo, {}, dayInfo.hoursWorked || 0);
            } else {
                newItem = this.buildGenericItem(typeToAdd, dateStr, dayInfo);
            }
            const items = [...row.items, newItem];
            const dayTotal = items.reduce((sum, i) => sum + (i.claimedAmount || 0), 0);

            return {
                ...row,
                items,
                dayTotal: Math.round(dayTotal * 100) / 100,
                dayTotalClass: dayTotal > 0 ? 'day-total-badge day-total-positive' : 'day-total-badge'
            };
        });

        // Reset the combobox value
        event.currentTarget.value = '';
    }

    // ── Accordion Toggle ─────────────────────────────────────────
    handleToggleDay(event) {
        const dateStr = event.currentTarget.dataset.date;
        this.dayRows = this.dayRows.map(row => {
            if (row.dateStr === dateStr) {
                return { ...row, expanded: !row.expanded };
            }
            return row;
        });
    }

    // ── Day Selection (checkboxes) ───────────────────────────────
    handleSelectAllDays(event) {
        this.selectAllDays = event.target.checked;
        this.dayRows = this.dayRows.map(row => ({
            ...row,
            selected: this.selectAllDays
        }));
    }

    handleSelectDay(event) {
        const dateStr = event.currentTarget.dataset.date;
        const checked = event.target.checked;
        this.dayRows = this.dayRows.map(row => {
            if (row.dateStr === dateStr) {
                return { ...row, selected: checked };
            }
            return row;
        });
        this.selectAllDays = this.dayRows.every(r => r.selected);
    }

    // ═══════════════════════════════════════════════════════════════
    // ITEM FIELD CHANGES — Inline editing
    // ═══════════════════════════════════════════════════════════════

    handleItemFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        const itemKey = event.currentTarget.dataset.key;
        let value = event.detail.value;
        if (event.detail.checked !== undefined) {
            value = event.detail.checked;
        }

        this.dayRows = this.dayRows.map(row => {
            const itemIdx = row.items.findIndex(i => i.key === itemKey);
            if (itemIdx < 0) return row;

            const items = [...row.items];
            const item = { ...items[itemIdx] };

            switch (field) {
                case 'claimedAmount':
                    item.claimedAmount = value ? parseFloat(value) : 0;
                    if (item.isActual) {
                        item.eligibleAmount = this.recalcEligible(item);
                    }
                    item.exceedsEligible = !item.isActual && item.claimedAmount > 0 && item.claimedAmount > item.eligibleAmount;
                    if (item.isLodging && item.lodgingTierLimit > 0) {
                        item.lodgingLimitExceeded = item.claimedAmount > item.lodgingTierLimit;
                    }
                    break;
                case 'manualDistance':
                    item.manualDistance = value ? parseFloat(value) : null;
                    item.showOverrideReason = item.isTravel && item.gpsDistance > 0 && item.manualDistance != null && item.manualDistance !== item.gpsDistance;
                    item.eligibleAmount = this.recalcEligible(item);
                    break;
                case 'fromLocation':
                    item.fromLocation = value;
                    break;
                case 'toLocation':
                    item.toLocation = value;
                    break;
                case 'notes':
                    item.notes = value;
                    break;
                case 'overrideReason':
                    item.overrideReason = value;
                    break;
                case 'vehicleType':
                    item.vehicleType = value;
                    // Re-match eligibility rule for the vehicle/travel mode
                    {
                        const matchedRule = this.findRuleForItem(item.expenseType, value);
                        if (matchedRule) {
                            item.rateAmount = matchedRule.Rate_Amount__c || 0;
                            item.maxPerDay = matchedRule.Max_Per_Day__c || 0;
                            item.dailyKmLimit = matchedRule.Daily_KM_Limit__c || 0;
                        }
                    }
                    item.eligibleAmount = this.recalcEligible(item);
                    break;
                case 'travelMode':
                    item.travelMode = value;
                    item.vehicleType = value;
                    // Look up mode config from rule's children
                    {
                        const matchedRule = this.findRuleForItem(item.expenseType, item.dutyType);
                        if (matchedRule) {
                            const modeConfig = this.getModeRateConfig(matchedRule, value);
                            const modeSlabs = this.getSlabsForMode(matchedRule, value);
                            item.modeRateConfig = modeConfig;
                            item.modeSlabs = modeSlabs;
                            item.hasSlabs = modeSlabs.length > 0;
                            if (modeConfig) {
                                item.rateType = modeConfig.Rate_Type__c || item.rateType;
                                item.rateAmount = modeConfig.Rate_Amount__c || item.rateAmount;
                                item.isActual = (modeConfig.Rate_Type__c === 'Actual');
                                item.isTravel = (modeConfig.Rate_Type__c === 'Per KM');
                                item.showFromTo = item.isTravel;
                            } else {
                                item.rateAmount = matchedRule.Rate_Amount__c || 0;
                                item.maxPerDay = matchedRule.Max_Per_Day__c || 0;
                                item.dailyKmLimit = matchedRule.Daily_KM_Limit__c || 0;
                            }
                        }
                    }
                    item.eligibleAmount = this.recalcEligible(item);
                    break;
                case 'city':
                    item.city = value;
                    // Auto-resolve city tier from City Tier master
                    {
                        const tier = this.cityTiers[value];
                        if (tier) {
                            item.cityTier = tier;
                            item.isMetro = (tier === 'Tier 1');
                        } else {
                            item.cityTier = '';
                            item.isMetro = false;
                        }
                    }
                    item.eligibleAmount = this.recalcEligible(item);
                    break;
                case 'workingHours':
                    item.workingHours = value ? parseFloat(value) : 0;
                    if (item.isDA) {
                        item.eligibleAmount = this.recalcEligible(item);
                    }
                    break;
                default:
                    break;
            }

            item.dirty = true;
            items[itemIdx] = item;

            const dayTotal = items.reduce((sum, i) => sum + (i.claimedAmount || 0), 0);
            return {
                ...row,
                items,
                dayTotal: Math.round(dayTotal * 100) / 100,
                dayTotalClass: dayTotal > 0 ? 'day-total-badge day-total-positive' : 'day-total-badge'
            };
        });
    }

    // ═══════════════════════════════════════════════════════════════
    // ELIGIBILITY CALCULATION (Client-side mirror of server logic)
    // ═══════════════════════════════════════════════════════════════

    recalcEligible(item) {
        const dist = item.manualDistance != null ? item.manualDistance : (item.gpsDistance || 0);
        let eligible = 0;

        if (item.minDistance > 0 && dist < item.minDistance) return 0;

        // TA: use mode-specific calculation
        if (item.expenseType === 'Travelling Allowance' && item.travelMode) {
            eligible = this.calcTAForMode(item, dist);
        } else if (item.rateType === 'Per Day') {
            // DA with working hours logic
            eligible = this.calcDA(item);
        } else if (item.rateType === 'Per KM') {
            // TA/Fuel with vehicle type
            if (item.modeSlabs && item.modeSlabs.length > 0) {
                eligible = this.calcTAWithSlabs(item, dist, item.modeSlabs);
            } else {
                eligible = this.calcTA(item, dist);
            }
        } else if (item.rateType === 'Actual') {
            eligible = item.claimedAmount || 0;
            if (item.isLodging) {
                let limit = 0;
                if (item.cityTier === 'Tier 1' && item.cityTier1Limit > 0) limit = item.cityTier1Limit;
                else if (item.cityTier === 'Tier 2' && item.cityTier2Limit > 0) limit = item.cityTier2Limit;
                else if (item.cityTier === 'Tier 3' && item.cityTier3Limit > 0) limit = item.cityTier3Limit;
                else limit = item.isMetro ? item.lodgingMetroLimit : item.lodgingNonMetroLimit;
                item.lodgingTierLimit = limit;
                item.lodgingLimitExceeded = limit > 0 && eligible > limit;
                if (limit > 0 && eligible > limit) {
                    eligible = limit;
                }
            }
        } else if (item.rateType === 'Flat Monthly') {
            const wd = this.expense.Working_Days__c || 22;
            eligible = wd > 0 ? item.rateAmount / wd : 0;
        }

        return Math.round(eligible * 100) / 100;
    }

    // Mode-aware TA calculation (handles both Per KM and Actual modes)
    calcTAForMode(item, dist) {
        // Check for slab rates for this mode
        if (item.modeSlabs && item.modeSlabs.length > 0) {
            return this.calcTAWithSlabs(item, dist, item.modeSlabs);
        }
        // Check for mode flat config
        if (item.modeRateConfig) {
            const config = item.modeRateConfig;
            if (config.Rate_Type__c === 'Actual') {
                const claimed = item.claimedAmount || 0;
                const max = config.Max_Amount__c || 0;
                return (max > 0 && claimed > max) ? max : claimed;
            }
            // Per KM flat
            let appliedDist = dist;
            if (item.dailyKmLimit > 0 && appliedDist > item.dailyKmLimit) appliedDist = item.dailyKmLimit;
            return appliedDist * (config.Rate_Amount__c || 0);
        }
        // Fallback: parent rate
        return this.calcTA(item, dist);
    }

    // Slab-based TA calculation
    calcTAWithSlabs(item, dist, slabs) {
        let appliedDist = dist;
        if (item.dailyKmLimit > 0 && appliedDist > item.dailyKmLimit) appliedDist = item.dailyKmLimit;
        let total = 0;
        for (const slab of slabs) {
            const slabEnd = (slab.Distance_To__c && slab.Distance_To__c > 0) ? slab.Distance_To__c : appliedDist;
            const slabStart = slab.Distance_From__c || 0;
            const slabDist = Math.min(appliedDist, slabEnd) - slabStart;
            if (slabDist > 0) total += slabDist * (slab.Rate_Amount__c || slab.Rate__c || 0);
            if (appliedDist <= slabEnd) break;
        }
        return total;
    }

    calcHoursBetween(startTime, endTime) {
        // startTime/endTime can be ISO datetime strings or epoch millis from Salesforce Time fields
        try {
            let startMs, endMs;
            if (typeof startTime === 'number') {
                startMs = startTime;
            } else {
                startMs = new Date(startTime).getTime();
            }
            if (typeof endTime === 'number') {
                endMs = endTime;
            } else {
                endMs = new Date(endTime).getTime();
            }
            if (isNaN(startMs) || isNaN(endMs)) return 0;
            const diffHours = (endMs - startMs) / (1000 * 60 * 60);
            return Math.round(diffHours * 10) / 10; // round to 1 decimal
        } catch (e) {
            return 0;
        }
    }

    calcDA(item) {
        const fullRate = item.rateAmount || 0;
        const halfRate = fullRate / 2;
        const hours = item.workingHours || 0;

        if (hours > 0) {
            if (hours < DA_MIN_HOURS) return 0;
            if (hours <= DA_HALF_DAY_HOURS) return halfRate;
        }
        return fullRate;
    }

    calcTA(item, dist) {
        let appliedDist = dist;
        if (item.dailyKmLimit > 0 && appliedDist > item.dailyKmLimit) {
            appliedDist = item.dailyKmLimit;
        }

        const rate = item.rateAmount || 0;

        return appliedDist * rate;
    }

    // ═══════════════════════════════════════════════════════════════
    // FILE UPLOAD
    // ═══════════════════════════════════════════════════════════════

    async loadAllFiles() {
        const allItemIds = [];
        this.dayRows.forEach(row => {
            row.items.forEach(item => {
                if (item.id) allItemIds.push(item.id);
            });
        });
        if (allItemIds.length === 0) return;

        try {
            const files = await getExpenseItemFiles({ itemIds: allItemIds });
            const filesByItem = {};
            files.forEach(f => {
                const itemId = f.expenseItemId;
                if (!filesByItem[itemId]) filesByItem[itemId] = [];
                filesByItem[itemId].push(f);
            });

            this.dayRows = this.dayRows.map(row => ({
                ...row,
                items: row.items.map(item => {
                    const itemFiles = item.id ? (filesByItem[item.id] || []) : [];
                    const hasFiles = itemFiles.length > 0;
                    return {
                        ...item,
                        files: itemFiles,
                        hasFiles: hasFiles,
                        hasAnyFiles: hasFiles
                    };
                })
            }));
        } catch (e) {
            this.showError(e);
        }
    }

    handleFileSelect(event) {
        const itemKey = event.currentTarget.dataset.key;
        const files = event.currentTarget.files;
        if (!files || files.length === 0) return;

        // Find the item to check if it's saved
        let targetItem = null;
        for (const row of this.dayRows) {
            for (const item of row.items) {
                if (item.key === itemKey) { targetItem = item; break; }
            }
            if (targetItem) break;
        }

        const readers = [];
        for (let i = 0; i < files.length; i++) {
            const file = files[i];
            readers.push(new Promise((resolve) => {
                const reader = new FileReader();
                reader.onload = () => {
                    resolve({
                        fileName: file.name,
                        base64: reader.result.split(',')[1],
                        size: file.size,
                        key: file.name + '-' + Date.now() + '-' + i
                    });
                };
                reader.readAsDataURL(file);
            }));
        }

        Promise.all(readers).then(async (readFiles) => {
            if (targetItem && targetItem.id) {
                // Saved item: upload immediately via base64
                try {
                    this.isLoading = true;
                    const uploads = readFiles.map(pf =>
                        uploadReceiptBase64({
                            expenseItemId: targetItem.id,
                            fileName: pf.fileName,
                            base64Data: pf.base64
                        })
                    );
                    await Promise.all(uploads);
                    this.showSuccess(readFiles.length + ' receipt(s) uploaded.');
                    await this.loadAllFiles();
                } catch (e) {
                    this.showError('Failed to upload receipt: ' + (e.body?.message || e.message || e));
                } finally {
                    this.isLoading = false;
                }
            } else {
                // Unsaved item: stage files locally
                this.dayRows = this.dayRows.map(row => ({
                    ...row,
                    items: row.items.map(item => {
                        if (item.key !== itemKey) return item;
                        const allPending = [...(item.pendingFiles || []), ...readFiles];
                        return {
                            ...item,
                            pendingFiles: allPending,
                            hasPendingFiles: allPending.length > 0,
                            hasAnyFiles: item.hasFiles || allPending.length > 0
                        };
                    })
                }));
            }
        });

        // Reset file input so same file can be selected again
        event.currentTarget.value = '';
    }

    handleRemovePendingFile(event) {
        const itemKey = event.currentTarget.dataset.key;
        const fileKey = event.currentTarget.dataset.filekey;

        this.dayRows = this.dayRows.map(row => ({
            ...row,
            items: row.items.map(item => {
                if (item.key !== itemKey) return item;
                const pendingFiles = (item.pendingFiles || []).filter(f => f.key !== fileKey);
                return {
                    ...item,
                    pendingFiles,
                    hasPendingFiles: pendingFiles.length > 0,
                    hasAnyFiles: item.hasFiles || pendingFiles.length > 0
                };
            })
        }));
    }

    async uploadPendingFiles() {
        const uploads = [];
        this.dayRows.forEach(row => {
            row.items.forEach(item => {
                if (item.id && item.pendingFiles && item.pendingFiles.length > 0) {
                    item.pendingFiles.forEach(pf => {
                        uploads.push(
                            uploadReceiptBase64({
                                expenseItemId: item.id,
                                fileName: pf.fileName,
                                base64Data: pf.base64
                            })
                        );
                    });
                }
            });
        });

        if (uploads.length > 0) {
            await Promise.all(uploads);

            // Clear pending files
            this.dayRows = this.dayRows.map(row => ({
                ...row,
                items: row.items.map(item => ({
                    ...item,
                    pendingFiles: [],
                    hasPendingFiles: false
                }))
            }));
        }
    }

    async handleDeleteFile(event) {
        const docId = event.currentTarget.dataset.docid;
        try {
            this.isLoading = true;
            await deleteExpenseItemFile({ contentDocumentId: docId });
            this.showSuccess('Receipt deleted.');
            await this.loadAllFiles();
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SAVE ALL
    // ═══════════════════════════════════════════════════════════════

    async handleSaveAll() {
        this.saveError = '';

        // Client-side validations
        const errors = this.validateItems();
        if (errors.length > 0) {
            this.saveError = errors.join(' | ');
            return;
        }

        try {
            this.isLoading = true;

            const itemsToSave = this.collectItemsToSave();

            if (itemsToSave.length > 0) {
                const savedItems = await saveExpenseItems({
                    expenseId: this.expense.Id,
                    itemsJson: JSON.stringify(itemsToSave)
                });

                // Map saved IDs back to dayRows
                this.dayRows = this.dayRows.map(row => ({
                    ...row,
                    items: row.items.map(item => {
                        const saved = savedItems.find(
                            s => s.Expense_Date__c === row.dateStr && s.Expense_Type__c === item.expenseType
                        );
                        if (saved) {
                            const approvalStatus = saved.Approval_Status__c || 'Not Submitted';
                            return {
                                ...item,
                                id: saved.Id,
                                hasExisting: true,
                                dirty: false,
                                approvalStatus: approvalStatus,
                                statusLabel: this.getItemStatusLabel(saved.Approval_Status__c),
                                statusClass: this.getItemStatusClass(saved.Approval_Status__c),
                                isReadonly: ['Submitted', 'Pending', 'L1 Approved', 'L2 Approved', 'Finance Approved'].includes(approvalStatus)
                            };
                        }
                        return item;
                    })
                }));

                this.showSuccess('All expense items saved successfully.');
            }

            // Upload any pending (staged) receipt files now that items have IDs
            await this.uploadPendingFiles();

            // Refresh file attachments and expense totals
            await this.loadAllFiles();
            this.expense = await getOrCreateReport({ month: this.selectedMonth, year: this.selectedYear });
        } catch (e) {
            let msg = 'An error occurred.';
            if (e && e.body && e.body.message) msg = e.body.message;
            else if (e && e.message) msg = e.message;
            this.saveError = msg;
        } finally {
            this.isLoading = false;
        }
    }

    validateItems() {
        const errors = [];

        this.dayRows.forEach(row => {
            row.items.forEach(item => {
                // Notes required when claimed exceeds eligible
                if (!item.isActual && item.claimedAmount > 0 && item.claimedAmount > item.eligibleAmount
                    && (!item.notes || item.notes.trim() === '')) {
                    errors.push('Notes required for ' + item.expenseType + ' on ' + row.formattedDate + ' (exceeds eligible)');
                }
                // Mandatory remarks
                if (item.mandatoryRemarks && item.claimedAmount > 0 && (!item.notes || item.notes.trim() === '')) {
                    errors.push('Remarks required for ' + item.expenseType + ' on ' + row.formattedDate);
                }
                // From/To required for travel
                if (item.showFromTo && item.claimedAmount > 0) {
                    if (!item.fromLocation || !item.toLocation) {
                        errors.push('From/To required for ' + item.expenseType + ' on ' + row.formattedDate);
                    }
                }
                // City required for lodging
                if (item.showCity && item.claimedAmount > 0 && !item.city) {
                    errors.push('City required for ' + item.expenseType + ' on ' + row.formattedDate);
                }
                // Lodging exceeds city tier limit — require notes
                if (item.lodgingLimitExceeded && (!item.notes || item.notes.trim() === '')) {
                    errors.push(item.expenseType + ' on ' + row.formattedDate + ' exceeds ' + (item.cityTier || 'city') + ' limit of ₹' + item.lodgingTierLimit + '. Notes required.');
                }
            });
        });

        return errors;
    }

    collectItemsToSave() {
        const itemsToSave = [];
        this.dayRows.forEach(row => {
            row.items.forEach(item => {
                if (item.isReadonly) return;
                if ((item.claimedAmount && item.claimedAmount > 0) || item.hasExisting) {
                    const rec = {
                        Expense_Date__c: row.dateStr,
                        Expense_Type__c: item.expenseType,
                        Expense_Category__c: item.category,
                        GPS_Distance_KM__c: item.gpsDistance,
                        Manual_Distance_KM__c: item.manualDistance,
                        Distance_Override_Reason__c: item.overrideReason,
                        Eligible_Amount__c: item.eligibleAmount,
                        Claimed_Amount__c: item.claimedAmount || 0,
                        From_Location__c: item.fromLocation || '',
                        To_Location__c: item.toLocation || '',
                        Notes__c: item.notes,
                        Rate_Type__c: item.rateType,
                        Rate_Amount__c: item.rateAmount,
                        Receipt_Required__c: item.receiptRequired,
                        Is_Eligible__c: item.isEligible,
                        Day_Attendance__c: row.attendanceId || null,
                        Vehicle_Type__c: item.vehicleType || null,
                        Travel_Mode__c: item.travelMode || null,
                        Working_Hours__c: item.workingHours || null,
                        City__c: item.city || null,
                        Is_Metro__c: item.isMetro || false,
                        Duty_Type__c: item.dutyType || null,
                        City_Tier__c: item.cityTier || null
                    };
                    if (item.id) rec.Id = item.id;
                    itemsToSave.push(rec);
                }
            });
        });
        return itemsToSave;
    }

    // ── Save & Submit with Confirmation ──────────────────────────
    async handleSaveAndSubmit() {
        await this.handleSaveAll();
        if (this.saveError) return;

        // Show confirmation popup with summary
        try {
            this.isLoading = true;
            const summary = await getSubmitSummary({ expenseId: this.expense.Id });
            this.submitSummary = summary;
            this.submitRemarks = '';
            this.showSubmitConfirmModal = true;
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    handleSubmitRemarksChange(event) {
        this.submitRemarks = event.detail.value;
    }

    closeSubmitConfirmModal() {
        this.showSubmitConfirmModal = false;
    }

    async handleConfirmSubmit() {
        try {
            this.isLoading = true;
            this.showSubmitConfirmModal = false;
            const result = await submitReport({ expenseId: this.expense.Id });
            this.showSuccess('Expense submitted for approval.');
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: result.Id,
                    objectApiName: 'Expense__c',
                    actionName: 'view'
                }
            });
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    get submitSummaryItems() {
        return this.submitSummary.typeBreakdown || [];
    }

    get submitCanProceed() {
        return this.submitSummary.canSubmit === true;
    }

    get submitMissingReceipts() {
        return this.submitSummary.missingReceipts || 0;
    }

    get submitHasMissingReceipts() {
        return this.submitMissingReceipts > 0;
    }

    validateReceiptsForSubmit() {
        const errors = [];
        this.dayRows.forEach(row => {
            row.items.forEach(item => {
                if (item.receiptRequired && item.claimedAmount > 0) {
                    const threshold = item.receiptThreshold || 0;
                    if (threshold === 0 || item.claimedAmount > threshold) {
                        if (!item.hasFiles) {
                            errors.push('Receipt required for ' + item.expenseType + ' on ' + row.formattedDate);
                        }
                    }
                }
            });
        });
        return errors;
    }

    // ── Cancel ───────────────────────────────────────────────────
    handleCancel() {
        this.saveError = '';
        this.selectAllDays = false;
        this.loadExpenseData();
    }

    // ── Delete Item ──────────────────────────────────────────────
    async handleDeleteItem(event) {
        const itemKey = event.currentTarget.dataset.key;
        let itemId = null;

        this.dayRows = this.dayRows.map(row => {
            const itemIdx = row.items.findIndex(i => i.key === itemKey);
            if (itemIdx < 0) return row;

            const items = [...row.items];
            const item = items[itemIdx];
            itemId = item.id;

            // Remove item entirely (dynamic add/remove)
            items.splice(itemIdx, 1);

            const dayTotal = items.reduce((sum, i) => sum + (i.claimedAmount || 0), 0);
            return {
                ...row,
                items,
                dayTotal: Math.round(dayTotal * 100) / 100,
                dayTotalClass: dayTotal > 0 ? 'day-total-badge day-total-positive' : 'day-total-badge'
            };
        });

        if (itemId) {
            try {
                this.isLoading = true;
                await deleteExpenseItems({ itemIds: [itemId] });
                this.showSuccess('Expense item deleted.');
            } catch (e) {
                this.showError(e);
            } finally {
                this.isLoading = false;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SUBMIT / APPROVE / REJECT
    // ═══════════════════════════════════════════════════════════════

    async handleSubmit() {
        try {
            this.isLoading = true;
            this.expense = await submitReport({ expenseId: this.expense.Id });
            this.showSuccess('Expense submitted for approval.');
            this.showDayExpenses = false;
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    handleOpenApproval(event) {
        this.approvalAction = event.currentTarget.dataset.action;
        this.approvalLevel = event.currentTarget.dataset.level || 'manager';
        this.approvalExpenseId = event.currentTarget.dataset.id || this.expense.Id;
        this.approvalRemarks = '';
        this.showApprovalModal = true;
    }

    handleRemarksChange(event) {
        this.approvalRemarks = event.detail.value;
    }

    async handleApprovalConfirm() {
        try {
            this.isLoading = true;
            if (this.approvalAction === 'approve') {
                await approveReport({
                    expenseId: this.approvalExpenseId,
                    remarks: this.approvalRemarks,
                    level: this.approvalLevel
                });
                this.showSuccess('Expense approved.');
            } else if (this.approvalAction === 'reject') {
                if (!this.approvalRemarks) {
                    this.showError({ body: { message: 'Rejection reason is required.' } });
                    this.isLoading = false;
                    return;
                }
                await rejectReport({
                    expenseId: this.approvalExpenseId,
                    reason: this.approvalRemarks,
                    level: this.approvalLevel
                });
                this.showSuccess('Expense rejected.');
            } else if (this.approvalAction === 'paid') {
                await markAsPaid({ expenseId: this.approvalExpenseId });
                this.showSuccess('Expense marked as paid.');
            }
            this.showApprovalModal = false;
            await this.loadExpenseData();
            if (this.activeTab === 'team') {
                await this.loadTeamReports();
            }
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    closeApprovalModal() {
        this.showApprovalModal = false;
    }

    // ═══════════════════════════════════════════════════════════════
    // COMMENTS HISTORY
    // ═══════════════════════════════════════════════════════════════

    handleShowComments() {
        const raw = this.expense.Comments_History__c || '';
        this.commentsHistory = raw.split('\n').filter(l => l.trim() !== '').map((line, idx) => ({
            key: 'comment-' + idx,
            text: line
        }));
        this.showCommentsModal = true;
    }

    closeCommentsModal() {
        this.showCommentsModal = false;
    }

    // ── Summary ──────────────────────────────────────────────────
    async loadSummary() {
        if (!this.expense.Id) return;
        try {
            this.isLoading = true;
            this.summary = await getReportSummary({ expenseId: this.expense.Id });
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ── Monthly Overview ─────────────────────────────────────────
    async loadMonthlyOverview() {
        try {
            this.isLoading = true;
            this.monthlyOverview = await getMonthlyOverview({ year: this.selectedYear });
        } catch (e) {
            this.showError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ── Team Reports ─────────────────────────────────────────────
    async loadTeamReports() {
        try {
            this.isLoading = true;
            const reports = await getTeamExpenseReports({
                month: this.selectedMonth,
                year: this.selectedYear
            });
            this.teamReports = reports.map(r => ({
                ...r,
                _approvalLevel: r.Status__c === 'Manager Approved' ? 'finance' : 'manager',
                _canApprove: r.Status__c === 'Submitted' || r.Status__c === 'Manager Approved',
                _canMarkPaid: r.Status__c === 'Finance Approved'
            }));
        } catch (e) {
            this.showError(e);
            this.teamReports = [];
        } finally {
            this.isLoading = false;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // COMPUTED PROPERTIES
    // ═══════════════════════════════════════════════════════════════

    get isMainScreen() { return this.currentScreen === 'MAIN'; }
    get isDraft() { return this.expense.Status__c === 'Draft'; }
    get isSubmitted() { return this.expense.Status__c === 'Submitted'; }
    get isRejected() { return this.expense.Status__c === 'Rejected'; }
    get isFinanceApproved() { return this.expense.Status__c === 'Finance Approved'; }
    get isPaid() { return this.expense.Status__c === 'Paid'; }
    get canSubmit() { return !this.isPaid; }
    get canEdit() { return !this.isPaid; }
    get acceptedFileFormats() { return ['.pdf', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp']; }
    get cannotEdit() { return !this.canEdit; }
    get isExpenseTab() { return this.activeTab === 'expense'; }
    get isSummaryTab() { return this.activeTab === 'summary'; }
    get isOverviewTab() { return this.activeTab === 'overview'; }
    get isTeamTab() { return this.activeTab === 'team'; }

    get expenseTabClass() { return 'tab-btn' + (this.isExpenseTab ? ' tab-active' : ''); }
    get summaryTabClass() { return 'tab-btn' + (this.isSummaryTab ? ' tab-active' : ''); }
    get overviewTabClass() { return 'tab-btn' + (this.isOverviewTab ? ' tab-active' : ''); }
    get teamTabClass() { return 'tab-btn' + (this.isTeamTab ? ' tab-active' : ''); }

    get statusBadgeClass() {
        const s = this.expense.Status__c;
        if (s === 'Draft') return 'status-badge status-draft';
        if (s === 'Submitted') return 'status-badge status-submitted';
        if (s === 'Manager Approved') return 'status-badge status-manager-approved';
        if (s === 'Finance Approved') return 'status-badge status-finance-approved';
        if (s === 'Rejected') return 'status-badge status-rejected';
        if (s === 'Paid') return 'status-badge status-paid';
        return 'status-badge';
    }

    get totalClaimed() { return this.expense.Total_Claimed__c || 0; }
    get totalEligible() { return this.expense.Total_Eligible__c || 0; }
    get totalApproved() { return this.expense.Total_Approved__c || 0; }
    get workingDays() { return this.expense.Working_Days__c || 0; }
    get totalDistance() { return this.expense.Total_Distance_KM__c || 0; }

    get grandTotal() {
        return this.dayRows.reduce((sum, row) => sum + row.dayTotal, 0);
    }

    get hasEligibleDates() { return this.eligibleDates.length > 0; }
    get noAttendanceMessage() {
        if (this.eligibleDates.length > 0) return '';
        const monthIdx = MONTHS.findIndex(m => m.value === this.selectedMonth);
        const start = new Date(this.selectedYear, monthIdx, 1);
        const end = new Date(this.selectedYear, monthIdx + 1, 0);
        const fmt = d => d.toISOString().split('T')[0];
        return 'There are no attendance entries available between ' + fmt(start) + ' and ' + fmt(end) + '.';
    }

    get hasComments() {
        return this.expense.Comments_History__c && this.expense.Comments_History__c.trim() !== '';
    }

    get hasCommentsEntries() { return this.commentsHistory.length > 0; }

    get summaryTypeBreakdown() { return this.summary.typeBreakdown || []; }
    get summaryDayBreakdown() { return this.summary.dayBreakdown || []; }
    get hasTeamReports() { return this.teamReports.length > 0; }

    get acceptedFormats() {
        return ['.pdf', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'];
    }

    // Receipt status helper — determines CSS class for receipt indicator
    getReceiptStatusClass(item) {
        if (!item.receiptRequired) return '';
        if (item.hasFiles) return 'receipt-status receipt-uploaded';
        return 'receipt-status receipt-missing';
    }

    getReceiptStatusLabel(item) {
        if (!item.receiptRequired) return '';
        if (item.hasFiles) return 'Receipt Uploaded';
        if (!item.id) return 'Save to upload';
        return 'Receipt Missing';
    }

    get approvalModalTitle() {
        if (this.approvalAction === 'approve') return 'Approve Expense';
        if (this.approvalAction === 'reject') return 'Reject Expense';
        if (this.approvalAction === 'paid') return 'Mark as Paid';
        return 'Confirmation';
    }

    get approvalActionLabel() {
        if (this.approvalAction === 'approve') return 'Approve';
        if (this.approvalAction === 'reject') return 'Reject';
        if (this.approvalAction === 'paid') return 'Mark Paid';
        return 'Confirm';
    }

    get approvalActionVariant() {
        return this.approvalAction === 'reject' ? 'destructive' : 'brand';
    }

    get showRemarksField() {
        return this.approvalAction === 'approve' || this.approvalAction === 'reject';
    }

    get employeeName() {
        if (this.employee.First_Name__c) {
            return this.employee.First_Name__c + ' ' + (this.employee.Last_Name__c || '');
        }
        return '';
    }

    get employeeBand() {
        return this.employee.Band__c || '';
    }

    get expenseStartDate() {
        const monthIdx = MONTHS.findIndex(m => m.value === this.selectedMonth);
        const d = new Date(this.selectedYear, monthIdx, 1);
        return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
    }

    get expenseEndDate() {
        const monthIdx = MONTHS.findIndex(m => m.value === this.selectedMonth);
        const d = new Date(this.selectedYear, monthIdx + 1, 0);
        return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
    }

    get selectedDaysCount() {
        return this.dayRows.filter(r => r.selected).length;
    }

    get hasSelectedDays() {
        return this.selectedDaysCount > 0;
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

    clearMessages() {
        this.errorMessage = '';
        this.successMessage = '';
        this.saveError = '';
    }
}