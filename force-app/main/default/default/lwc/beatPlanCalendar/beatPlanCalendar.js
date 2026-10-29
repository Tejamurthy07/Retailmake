import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import Id from '@salesforce/user/Id';

import getJourneyPlanById from '@salesforce/apex/BeatPlanController.getJourneyPlanById';
import getJourneyPlan from '@salesforce/apex/BeatPlanController.getJourneyPlan';
import getBeatsForUser from '@salesforce/apex/BeatPlanController.getBeatsForUser';
import getBeatsForExecutive from '@salesforce/apex/BeatPlanController.getBeatsForExecutive';
import submitForApproval from '@salesforce/apex/BeatPlanController.submitForApproval';
import addBeatToCalendarDay from '@salesforce/apex/BeatPlanController.addBeatToCalendarDay';
import removePlanDay from '@salesforce/apex/BeatPlanController.removePlanDay';
import generateDefaultPlan from '@salesforce/apex/BeatPlanController.generateDefaultPlan';
import generatePlanForDateRange from '@salesforce/apex/BeatPlanController.generatePlanForDateRange';
import regeneratePlan from '@salesforce/apex/BeatPlanController.regeneratePlan';
import removeBeatFromPlan from '@salesforce/apex/BeatPlanController.removeBeatFromPlan';
import isCurrentUserAdmin from '@salesforce/apex/BeatPlanController.isCurrentUserAdmin';

const JP_SALESPERSON_FIELD = 'Journey_Plan__c.Salesperson__c';
const JP_MONTH_FIELD = 'Journey_Plan__c.Month__c';
const JP_YEAR_FIELD = 'Journey_Plan__c.Year__c';
const JP_STATUS_FIELD = 'Journey_Plan__c.Status__c';
const JP_TERRITORY_FIELD = 'Journey_Plan__c.Territory__c';
const JP_FIELDS = [JP_SALESPERSON_FIELD, JP_MONTH_FIELD, JP_YEAR_FIELD, JP_STATUS_FIELD, JP_TERRITORY_FIELD];

const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const FULL_DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'];

const BEAT_COLORS = [
    '#1abc9c', '#3498db', '#9b59b6', '#e74c3c', '#f39c12',
    '#2ecc71', '#e67e22', '#1a5276', '#c0392b', '#27ae60',
    '#8e44ad', '#2980b9', '#d35400', '#16a085', '#7f8c8d'
];

export default class BeatPlanCalendar extends LightningElement {
    @api recordId;

    @track calendarData = {};
    @track journeyPlan = {};
    @track weekView = false;
    @track mobileCardView = false;
    @track weekDays = [];
    @track monthWeeks = [];
    @track summaryStats = {
        totalPlannedVisits: 0,
        coveragePercent: 0,
        assignedBeats: 0,
        totalOutlets: 0,
        avgVisitsPerDay: 0
    };
    @track selectedDayDetail = null;
    @track availableBeats = [];
    @track pjpStatus = 'Draft';
    @track isAdmin = false;

    currentUserId = Id;
    resolvedUserId = null;
    resolvedTerritoryId = null;
    currentDate = new Date();
    currentWeekStart = null;
    currentMonth = null;
    currentYear = null;
    isLoading = false;
    beatColorMap = {};
    allBeats = [];
    planDaysRaw = [];
    dataLoaded = false;
    selectedExecutiveId = null;
    showGenerateModal = false;
    generateFromDate = '';
    generateToDate = '';
    showRegenerateModal = false;
    regenerateToDate = '';
    excludeHolidays = true;
    excludeLeaves = true;
    excludeWeekOffs = true;

    get hasPlan() {
        return this.journeyPlan && this.journeyPlan.Id;
    }

    get noPlan() {
        return !this.hasPlan && !this.isLoading;
    }

    get calendarTitle() {
        if (this.weekView) {
            if (!this.weekDays || this.weekDays.length === 0) return '';
            const start = this.weekDays[0];
            const end = this.weekDays[this.weekDays.length - 1];
            return (start ? start.dateDisplay : '') + ' - ' + (end ? end.dateDisplay : '');
        }
        return MONTH_NAMES[this.currentMonth] + ' ' + this.currentYear;
    }

    get weekBtnVariant() { return this.weekView ? 'brand' : 'neutral'; }
    get monthBtnVariant() { return this.weekView ? 'neutral' : 'brand'; }

    get showCalendarGrid() { return !this.mobileCardView; }
    get cardBtnVariant() { return this.mobileCardView ? 'brand' : 'neutral'; }
    get calendarBtnVariant() { return this.mobileCardView ? 'neutral' : 'brand'; }

    get mobileCardDays() {
        if (!this.calendarData || this.currentMonth == null) return [];
        const lastDay = new Date(this.currentYear, this.currentMonth + 1, 0).getDate();
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const days = [];
        for (let d = 1; d <= lastDay; d++) {
            const date = new Date(this.currentYear, this.currentMonth, d);
            const dateKey = this.formatDateKey(date);
            const dayData = this.calendarData[dateKey];
            if (!dayData || !dayData.beats || dayData.beats.length === 0) continue;
            const dow = date.getDay();
            days.push({
                dateKey,
                dateNumber: d,
                dayName: FULL_DAY_NAMES[dow],
                shortDay: DAY_NAMES[dow],
                beats: dayData.beats,
                totalVisits: dayData.totalVisits,
                isToday: date.getTime() === today.getTime(),
                isSunday: dow === 0,
                cardClass: 'bpc-day-card' +
                    (date.getTime() === today.getTime() ? ' bpc-day-card-today' : '') +
                    (dow === 0 ? ' bpc-day-card-sunday' : '')
            });
        }
        return days;
    }

    get pjpStatusBadgeClass() {
        const statusMap = {
            'Draft': 'pjp-badge pjp-draft',
            'Submitted': 'pjp-badge pjp-pending',
            'Pending Approval': 'pjp-badge pjp-pending',
            'Approved': 'pjp-badge pjp-approved',
            'Active': 'pjp-badge pjp-active',
            'Rejected': 'pjp-badge pjp-rejected'
        };
        return statusMap[this.pjpStatus] || 'pjp-badge pjp-draft';
    }

    get isApprovalDisabled() {
        return !this.hasPlan || (this.pjpStatus !== 'Draft' && this.pjpStatus !== 'Rejected');
    }

    get isPlanEditable() {
        // Regular users can only edit Draft or Rejected plans. Admins
        // (profile = Modify All Data) can regenerate at any status so
        // they can unblock field teams without manually flipping the
        // Journey_Plan__c.Status__c field on the record.
        if (!this.hasPlan) return false;
        if (this.pjpStatus === 'Draft' || this.pjpStatus === 'Rejected') return true;
        return this.isAdmin === true;
    }

    get isSelectedDayEditable() {
        if (!this.isPlanEditable || !this.selectedDayDetail) return false;
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const selectedDate = new Date(this.selectedDayDetail.dateKey + 'T12:00:00');
        selectedDate.setHours(0, 0, 0, 0);
        return selectedDate >= today;
    }

    get hasSelectedBeats() {
        return this.selectedDayDetail && this.selectedDayDetail.beats && this.selectedDayDetail.beats.length > 0;
    }

    get hasAvailableBeats() {
        return this.availableBeats.length > 0;
    }

    get showExecutivePicker() {
        return !this.recordId;
    }

    get generateDateInfo() {
        if (!this.generateToDate) return '';
        const fromKey = this.generateFromDate || this.todayFormatted;
        const from = new Date(fromKey + 'T12:00:00');
        const to = new Date(this.generateToDate + 'T12:00:00');
        if (from > to) return 'To Date must be on or after From Date.';
        const days = Math.round((to - from) / (1000 * 60 * 60 * 24)) + 1;
        return 'A single plan will be generated covering ' + days + ' days.';
    }

    get generateDisabled() {
        if (!this.generateToDate) return true;
        if (!this.resolvedTerritoryId) return true;
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const to = new Date(this.generateToDate + 'T12:00:00');
        return to < today;
    }

    get regenerateDisabled() {
        if (!this.regenerateToDate) return true;
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const to = new Date(this.regenerateToDate + 'T12:00:00');
        return to < today;
    }

    get todayFormatted() {
        return this.formatDateKey(new Date());
    }

    @wire(getRecord, { recordId: '$recordId', fields: JP_FIELDS })
    wiredJourneyPlanRecord({ error, data }) {
        if (data) {
            this.resolvedUserId = getFieldValue(data, JP_SALESPERSON_FIELD);
            this.resolvedTerritoryId = getFieldValue(data, JP_TERRITORY_FIELD);
            const monthName = getFieldValue(data, JP_MONTH_FIELD);
            const yearStr = getFieldValue(data, JP_YEAR_FIELD);
            this.pjpStatus = getFieldValue(data, JP_STATUS_FIELD) || 'Draft';

            if (monthName) {
                const monthIdx = MONTH_NAMES.indexOf(monthName);
                if (monthIdx >= 0) this.currentMonth = monthIdx;
            }
            if (yearStr) this.currentYear = parseInt(yearStr, 10);

            if (!this.dataLoaded) {
                this.dataLoaded = true;
                this.loadCalendar();
                this.loadBeats();
            }
        } else if (error) {
            if (!this.dataLoaded) {
                this.resolvedUserId = this.currentUserId;
                this.dataLoaded = true;
                this.loadCalendar();
                this.loadBeats();
            }
        }
    }

    connectedCallback() {
        const today = new Date();
        if (this.currentMonth === null) this.currentMonth = today.getMonth();
        if (this.currentYear === null) this.currentYear = today.getFullYear();
        this.currentWeekStart = this.getWeekStart(today);
        this.selectedExecutiveId = this.currentUserId;
        if (window.innerWidth <= 768) {
            this.mobileCardView = true;
        }

        // Detect admin once so the UI can expose Regenerate Plan on any
        // status (Approved/Active included) for admins only. Non-admins
        // stay locked to the Draft/Rejected status gate.
        isCurrentUserAdmin()
            .then(result => { this.isAdmin = result === true; })
            .catch(() => { this.isAdmin = false; });

        if (!this.recordId) {
            this.resolvedUserId = this.currentUserId;
            this.dataLoaded = true;
            this.loadCalendar();
            this.loadBeats();
        }
    }

    async loadCalendar() {
        this.isLoading = true;
        try {
            let result;
            if (this.recordId) {
                // getJourneyPlan* return a DTO whose journeyPlan/planDays props are
                // raw SObjects — strip the namespace prefix off their nested fields.
                result = this._stripNs(await getJourneyPlanById({ journeyPlanId: this.recordId }));
            } else if (this.resolvedUserId) {
                const monthName = MONTH_NAMES[this.currentMonth];
                const yearStr = String(this.currentYear);
                result = this._stripNs(await getJourneyPlan({ userId: this.resolvedUserId, month: monthName, year: yearStr }));
            }

            if (result && result.journeyPlan) {
                this.journeyPlan = result.journeyPlan;
                this.planDaysRaw = result.planDays || [];
                this.pjpStatus = result.journeyPlan.Status__c || 'Draft';
                this.resolvedTerritoryId = result.journeyPlan.Territory__c || this.resolvedTerritoryId;
                this.calendarData = this.buildCalendarData(this.planDaysRaw);

                // Filter plan days to the current viewed month for accurate stats
                const viewMonthStart = this.formatDateKey(new Date(this.currentYear, this.currentMonth, 1));
                const viewMonthEnd = this.formatDateKey(new Date(this.currentYear, this.currentMonth + 1, 0));
                const currentMonthDays = this.planDaysRaw.filter(day => {
                    if (!day.Plan_Date__c) return true;
                    return day.Plan_Date__c >= viewMonthStart && day.Plan_Date__c <= viewMonthEnd;
                });
                this.calculateSummaryStats(currentMonthDays);
            } else {
                this.journeyPlan = {};
                this.planDaysRaw = [];
                this.calendarData = {};
                this.calculateSummaryStats([]);
            }

            this.buildView();
        } catch (error) {
            console.error('Error loading journey plan:', error);
            this.journeyPlan = {};
            this.calendarData = {};
            this.calculateSummaryStats([]);
            this.buildView();
        } finally {
            this.isLoading = false;
        }
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

    async loadBeats() {
        try {
            const userId = this.selectedExecutiveId || this.resolvedUserId || this.currentUserId;
            if (!userId) return;

            const result = this._stripNs(await getBeatsForExecutive({ userId }));
            const activeBeats = (result || []).filter(beat => beat.Is_Active__c !== false);
            this.allBeats = activeBeats.map((beat, index) => {
                const color = BEAT_COLORS[index % BEAT_COLORS.length];
                this.beatColorMap[beat.Id] = color;
                return {
                    id: beat.Id,
                    name: beat.Name,
                    code: beat.Beat_Code__c,
                    outletCount: beat.Total_Outlets__c || 0,
                    territoryId: beat.Territory__c || null,
                    territory: beat.Territory__r?.Name || '',
                    colorStyle: 'background-color: ' + color,
                    color
                };
            });

            // Resolve territory from beats when no journey plan has set it yet
            if (!this.resolvedTerritoryId && this.allBeats.length > 0) {
                const firstWithTerritory = this.allBeats.find(b => b.territoryId);
                if (firstWithTerritory) {
                    this.resolvedTerritoryId = firstWithTerritory.territoryId;
                }
            }
        } catch (error) {
            console.error('Error loading beats:', error);
        }
    }

    buildCalendarData(planDays) {
        const data = {};
        const dayNameToIndex = {
            'Sunday': 0, 'Monday': 1, 'Tuesday': 2, 'Wednesday': 3,
            'Thursday': 4, 'Friday': 5, 'Saturday': 6
        };

        planDays.forEach(day => {
            let dateKey;

            if (day.Plan_Date__c) {
                dateKey = day.Plan_Date__c;
            } else {
                const weekNum = this.parseWeekNumber(day.Week_Number__c);
                const dayIdx = dayNameToIndex[day.Day_of_Week__c];
                if (dayIdx === undefined || !weekNum) return;

                const firstOfMonth = new Date(this.currentYear, this.currentMonth, 1);
                const firstDayOfWeekInMonth = firstOfMonth.getDay();
                let dateOffset = dayIdx - firstDayOfWeekInMonth;
                if (dateOffset < 0) dateOffset += 7;
                const actualDate = new Date(this.currentYear, this.currentMonth, 1 + dateOffset + (weekNum - 1) * 7);
                dateKey = this.formatDateKey(actualDate);
            }

            if (!data[dateKey]) {
                data[dateKey] = { beats: [], totalVisits: 0 };
            }

            const beatColor = this.beatColorMap[day.Beat__c] ||
                BEAT_COLORS[Object.keys(this.beatColorMap).length % BEAT_COLORS.length];
            if (day.Beat__c) this.beatColorMap[day.Beat__c] = beatColor;

            const outlets = day.Planned_Outlets__c != null ? day.Planned_Outlets__c : (day.Beat__r?.Total_Outlets__c || 0);
            data[dateKey].beats.push({
                id: day.Beat__c || day.Id,
                planDayId: day.Id,
                name: day.Beat__r?.Name || 'Beat',
                outletCount: outlets,
                colorStyle: 'background-color: ' + beatColor,
                color: beatColor
            });
            data[dateKey].totalVisits += outlets;
        });
        return data;
    }

    parseWeekNumber(weekStr) {
        if (!weekStr) return 1;
        const match = weekStr.match(/(\d+)/);
        return match ? parseInt(match[1], 10) : 1;
    }

    calculateSummaryStats(planDays) {
        const uniqueDates = new Set();
        const uniqueBeats = new Set();
        let totalPlannedVisits = 0;
        let totalBeatOutlets = 0;
        const countedBeats = new Set();

        planDays.forEach(day => {
            if (day.Plan_Date__c) {
                uniqueDates.add(day.Plan_Date__c);
            } else {
                uniqueDates.add((day.Week_Number__c || '') + '_' + (day.Day_of_Week__c || ''));
            }
            if (day.Beat__c) uniqueBeats.add(day.Beat__c);
            totalPlannedVisits += day.Planned_Outlets__c != null ? day.Planned_Outlets__c : 0;

            // Count each beat's Total_Outlets__c only once
            if (day.Beat__c && !countedBeats.has(day.Beat__c) && day.Beat__r) {
                totalBeatOutlets += day.Beat__r.Total_Outlets__c || 0;
                countedBeats.add(day.Beat__c);
            }
        });

        const workingDays = this.getWorkingDaysInMonth();
        const coverage = workingDays > 0 ? Math.round((uniqueDates.size / workingDays) * 100) : 0;

        this.summaryStats = {
            totalPlannedVisits,
            coveragePercent: Math.min(coverage, 100),
            assignedBeats: uniqueBeats.size,
            totalOutlets: totalBeatOutlets,
            avgVisitsPerDay: uniqueDates.size > 0 ? Math.round(totalPlannedVisits / uniqueDates.size) : 0
        };
    }

    buildView() {
        if (this.weekView) this.buildWeekView();
        else this.buildMonthView();
    }

    buildWeekView() {
        const weekStart = new Date(this.currentWeekStart);
        const days = [];
        const today = new Date();
        today.setHours(0, 0, 0, 0);

        for (let i = 0; i < 7; i++) {
            const date = new Date(weekStart);
            date.setDate(weekStart.getDate() + i);
            const dateKey = this.formatDateKey(date);
            const dayData = this.calendarData[dateKey] || { beats: [], totalVisits: 0 };
            const isToday = date.getTime() === today.getTime();
            const isSunday = date.getDay() === 0;

            days.push({
                dateKey,
                dayName: DAY_NAMES[date.getDay()],
                dateDisplay: date.getDate() + ' ' + MONTH_NAMES[date.getMonth()].substring(0, 3),
                dateNumber: date.getDate(),
                beats: dayData.beats.length > 0 ? dayData.beats : null,
                hasBeats: dayData.beats.length > 0,
                totalVisits: dayData.totalVisits,
                headerClass: 'day-header' + (isToday ? ' today-header' : '') + (isSunday ? ' sunday-header' : ''),
                cellClass: 'day-cell' + (isToday ? ' today-cell' : '') + (isSunday ? ' sunday-cell' : '')
            });
        }
        this.weekDays = days;
    }

    buildMonthView() {
        const firstDay = new Date(this.currentYear, this.currentMonth, 1);
        const lastDay = new Date(this.currentYear, this.currentMonth + 1, 0);
        const startDay = firstDay.getDay();
        const totalDays = lastDay.getDate();
        const today = new Date();
        today.setHours(0, 0, 0, 0);

        const weeks = [];
        let currentDay = 1 - startDay;
        let weekNum = 0;

        while (currentDay <= totalDays) {
            const week = { id: 'week_' + weekNum, days: [] };
            for (let i = 0; i < 7; i++) {
                const date = new Date(this.currentYear, this.currentMonth, currentDay);
                const dateKey = this.formatDateKey(date);
                const dayData = this.calendarData[dateKey] || { beats: [], totalVisits: 0 };
                const isCurrentMonth = currentDay >= 1 && currentDay <= totalDays;
                const isToday = isCurrentMonth && date.getTime() === today.getTime();
                const isSunday = i === 0;

                week.days.push({
                    dateKey,
                    dateNumber: isCurrentMonth ? currentDay : '',
                    isCurrentMonth,
                    beats: dayData.beats.length > 0 ? dayData.beats : null,
                    hasBeats: dayData.beats.length > 0,
                    totalVisits: dayData.totalVisits,
                    monthCellClass: 'month-cell' +
                        (isCurrentMonth ? '' : ' other-month') +
                        (isToday ? ' today-cell' : '') +
                        (isSunday ? ' sunday-cell' : ''),
                    dateNumberClass: 'date-number' + (isToday ? ' today-date' : '')
                });
                currentDay++;
            }
            weeks.push(week);
            weekNum++;
        }
        this.monthWeeks = weeks;
    }

    // ── View Controls ────────────────────────────────────────────────────

    switchToWeekView() { this.weekView = true; this.mobileCardView = false; this.buildWeekView(); }
    switchToMonthView() { this.weekView = false; this.mobileCardView = false; this.buildMonthView(); }
    switchToCardView() { this.mobileCardView = true; }
    switchToCalendarView() { this.mobileCardView = false; }

    handlePrevious() {
        if (this.weekView) {
            this.currentWeekStart.setDate(this.currentWeekStart.getDate() - 7);
            this.buildWeekView();
        } else {
            this.currentMonth--;
            if (this.currentMonth < 0) { this.currentMonth = 11; this.currentYear--; }
            if (!this.recordId) this.loadCalendar();
            else this.buildMonthView();
        }
    }

    handleNext() {
        if (this.weekView) {
            this.currentWeekStart.setDate(this.currentWeekStart.getDate() + 7);
            this.buildWeekView();
        } else {
            this.currentMonth++;
            if (this.currentMonth > 11) { this.currentMonth = 0; this.currentYear++; }
            if (!this.recordId) this.loadCalendar();
            else this.buildMonthView();
        }
    }

    handleToday() {
        const today = new Date();
        this.currentMonth = today.getMonth();
        this.currentYear = today.getFullYear();
        this.currentWeekStart = this.getWeekStart(today);
        this.loadCalendar();
    }

    // ── Day Selection & Beat Assignment ──────────────────────────────────

    selectDay(event) {
        const dateKey = event.currentTarget.dataset.date;
        if (!dateKey) return;

        const dayData = this.calendarData[dateKey] || { beats: [], totalVisits: 0 };
        const date = new Date(dateKey + 'T12:00:00');

        this.selectedDayDetail = {
            dateKey,
            dateObj: date,
            dayOfWeek: FULL_DAY_NAMES[date.getDay()],
            dateDisplay: date.toLocaleDateString('en-IN', {
                weekday: 'long', day: '2-digit', month: 'long', year: 'numeric'
            }),
            beats: dayData.beats.length > 0 ? [...dayData.beats] : null,
            totalVisits: dayData.totalVisits
        };

        const assignedBeatIds = new Set((dayData.beats || []).map(b => b.id));
        this.availableBeats = this.allBeats.filter(b => !assignedBeatIds.has(b.id));
    }

    async assignBeatToDay(event) {
        const beatId = event.currentTarget.dataset.beatId;
        if (!this.selectedDayDetail || !beatId || !this.hasPlan) return;

        if (!this.isSelectedDayEditable) {
            this.showToast('Warning', 'Cannot modify past dates. Only future dates can be edited.', 'warning');
            return;
        }

        const beat = this.allBeats.find(b => b.id === beatId);
        if (!beat) return;

        const dateObj = this.selectedDayDetail.dateObj;
        const dayOfMonth = dateObj.getDate();
        let weekNumber = 'Week 1';
        if (dayOfMonth > 21) weekNumber = 'Week 4';
        else if (dayOfMonth > 14) weekNumber = 'Week 3';
        else if (dayOfMonth > 7) weekNumber = 'Week 2';

        this.isLoading = true;
        try {
            this._stripNs(await addBeatToCalendarDay({
                journeyPlanId: this.journeyPlan.Id,
                beatId,
                dayOfWeek: this.selectedDayDetail.dayOfWeek,
                weekNumber,
                planDate: this.selectedDayDetail.dateKey
            }));

            this.showToast('Success', beat.name + ' assigned successfully.', 'success');
            await this.loadCalendar();
            this.selectDay({ currentTarget: { dataset: { date: this.selectedDayDetail.dateKey } } });
        } catch (error) {
            this.showToast('Error', 'Failed to assign beat: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleRemoveBeat(event) {
        const planDayId = event.currentTarget.dataset.planDayId;
        if (!planDayId) return;

        if (!this.isSelectedDayEditable) {
            this.showToast('Warning', 'Cannot modify past dates. Only future dates can be edited.', 'warning');
            return;
        }

        this.isLoading = true;
        try {
            await removePlanDay({ planDayId });
            this.showToast('Success', 'Beat removed from day.', 'success');
            const dateKey = this.selectedDayDetail?.dateKey;
            await this.loadCalendar();
            if (dateKey) {
                this.selectDay({ currentTarget: { dataset: { date: dateKey } } });
            }
        } catch (error) {
            this.showToast('Error', 'Failed to remove beat: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Executive Picker ─────────────────────────────────────────────────

    handleExecutiveChange(event) {
        const value = event.detail.value;
        const selectedId = Array.isArray(value) ? value[0] : value;

        if (selectedId === this.selectedExecutiveId) return;

        this.selectedExecutiveId = selectedId;
        this.resolvedUserId = selectedId;
        this.resolvedTerritoryId = null;
        this.selectedDayDetail = null;
        this.journeyPlan = {};
        this.calendarData = {};
        this.calculateSummaryStats([]);
        this.buildView();

        if (selectedId) {
            this.loadBeats();
            this.loadCalendar();
        }
    }

    handleResetExecutive() {
        if (this.selectedExecutiveId === this.currentUserId) return;
        this.selectedExecutiveId = this.currentUserId;
        this.resolvedUserId = this.currentUserId;
        this.resolvedTerritoryId = null;
        this.selectedDayDetail = null;
        this.loadBeats();
        this.loadCalendar();
    }

    // ── Generate Plan ───────────────────────────────────────────────────

    handleOpenGenerateModal() {
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const firstDayOfViewedMonth = new Date(this.currentYear, this.currentMonth, 1);
        const lastDayOfViewedMonth = new Date(this.currentYear, this.currentMonth + 1, 0);

        // From Date pre-fill:
        //   - If the user is looking at today's (or an earlier) month, start
        //     the plan from today (we can't backfill the past).
        //   - If the user is looking at a FUTURE month, start from the 1st of
        //     that month. Otherwise viewing May in April and clicking Generate
        //     tried to create May's plan starting in April, overlapping the
        //     existing April plan.
        const fromDate = (firstDayOfViewedMonth > today) ? firstDayOfViewedMonth : today;
        const toDate = (lastDayOfViewedMonth >= fromDate) ? lastDayOfViewedMonth : fromDate;

        this.generateFromDate = this.formatDateKey(fromDate);
        this.generateToDate = this.formatDateKey(toDate);
        this.excludeHolidays = true;
        this.excludeLeaves = true;
        this.excludeWeekOffs = true;
        this.showGenerateModal = true;
    }

    handleCloseGenerateModal() {
        this.showGenerateModal = false;
    }

    handleFromDateChange(event) {
        this.generateFromDate = event.detail.value;
    }

    handleToDateChange(event) {
        this.generateToDate = event.detail.value;
    }

    handleExcludeHolidaysChange(event) {
        this.excludeHolidays = event.target.checked;
    }

    handleExcludeLeavesChange(event) {
        this.excludeLeaves = event.target.checked;
    }

    handleExcludeWeekOffsChange(event) {
        this.excludeWeekOffs = event.target.checked;
    }

    async handleConfirmGenerate() {
        const userId = this.selectedExecutiveId || this.currentUserId;
        const territoryId = this.resolvedTerritoryId;

        if (!territoryId) {
            this.showToast('Warning', 'No territory found. Ensure beats are assigned to a territory.', 'warning');
            return;
        }

        // Use the From Date derived in handleOpenGenerateModal so the plan
        // starts on the viewed-month's 1st when generating for a future
        // month (was hardcoded to today, which overlapped the current-month
        // plan whenever the user was viewing a later month).
        const fromDate = this.generateFromDate || this.todayFormatted;
        console.log('[BPC] generatePlanForDateRange args:', {
            userId, territoryId, fromDate,
            toDate: this.generateToDate,
            excludeHolidays: this.excludeHolidays,
            excludeLeaves: this.excludeLeaves,
            excludeWeekOffs: this.excludeWeekOffs
        });
        this.isLoading = true;
        this.showGenerateModal = false;
        try {
            await generatePlanForDateRange({
                userId,
                territoryId,
                fromDate,
                toDate: this.generateToDate,
                excludeHolidays: this.excludeHolidays === true,
                excludeLeaves: this.excludeLeaves === true,
                excludeWeekOffs: this.excludeWeekOffs === true
            });

            // Navigate to the month the plan starts in (handles future months)
            const from = new Date(fromDate + 'T12:00:00');
            this.currentMonth = from.getMonth();
            this.currentYear = from.getFullYear();

            await this.loadCalendar();
            const totalDays = this.planDaysRaw ? this.planDaysRaw.length : 0;
            if (totalDays > 0) {
                this.showToast('Success', 'Journey plan generated with ' + totalDays + ' beat assignments.', 'success');
            } else {
                this.showToast('Warning', 'Journey plan created but no beat assignments found. Verify beats are assigned to working days in the date range.', 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Failed to generate plan: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Regenerate Plan ──────────────────────────────────────────────────

    handleOpenRegenerateModal() {
        // Default to existing plan's end date, or 1 month from today
        if (this.journeyPlan && this.journeyPlan.Effective_To__c) {
            this.regenerateToDate = this.journeyPlan.Effective_To__c;
        } else {
            const defaultEnd = new Date();
            defaultEnd.setMonth(defaultEnd.getMonth() + 1);
            defaultEnd.setDate(0); // last day of current month
            this.regenerateToDate = this.formatDateKey(defaultEnd);
        }
        // Initialize exclusion toggles from the plan's stored preferences
        this.excludeHolidays = this.journeyPlan.Exclude_Holidays__c !== false;
        this.excludeLeaves = this.journeyPlan.Exclude_Leaves__c !== false;
        this.excludeWeekOffs = this.journeyPlan.Exclude_Week_Offs__c !== false;
        this.showRegenerateModal = true;
    }

    handleCloseRegenerateModal() {
        this.showRegenerateModal = false;
    }

    handleRegenerateToDateChange(event) {
        this.regenerateToDate = event.detail.value;
    }

    async handleConfirmRegenerate() {
        const planId = this.journeyPlan?.Id;
        if (!planId) return;

        this.isLoading = true;
        this.showRegenerateModal = false;
        try {
            await regeneratePlan({
                journeyPlanId: planId,
                toDate: this.regenerateToDate,
                excludeHolidays: this.excludeHolidays === true,
                excludeLeaves: this.excludeLeaves === true,
                excludeWeekOffs: this.excludeWeekOffs === true
            });
            await this.loadCalendar();
            this.selectedDayDetail = null;
            const totalDays = this.planDaysRaw ? this.planDaysRaw.length : 0;
            if (totalDays > 0) {
                this.showToast('Success', 'Journey plan regenerated with ' + totalDays + ' beat assignments.', 'success');
            } else {
                this.showToast('Warning', 'Journey plan regenerated but no beat assignments found. Verify beats are assigned to working days in the date range.', 'warning');
            }
        } catch (error) {
            this.showToast('Error', 'Failed to regenerate plan: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Remove Beat from Plan ───────────────────────────────────────────

    async handleRemoveBeatFromPlan(event) {
        const beatId = event.currentTarget.dataset.beatId;
        const planId = this.journeyPlan?.Id;
        if (!beatId || !planId) return;

        if (!this.isSelectedDayEditable) {
            this.showToast('Warning', 'Cannot modify past dates. Only future dates can be edited.', 'warning');
            return;
        }

        const beatInfo = this.allBeats.find(b => b.id === beatId);
        const beatName = beatInfo ? beatInfo.name : 'this beat';
        // eslint-disable-next-line no-restricted-globals
        if (!confirm('Remove "' + beatName + '" from all days in this plan?')) {
            return;
        }

        this.isLoading = true;
        try {
            await removeBeatFromPlan({ journeyPlanId: planId, beatId });
            this.showToast('Success', beatName + ' removed from the plan.', 'success');
            const dateKey = this.selectedDayDetail?.dateKey;
            await this.loadCalendar();
            if (dateKey) {
                this.selectDay({ currentTarget: { dataset: { date: dateKey } } });
            }
        } catch (error) {
            this.showToast('Error', 'Failed to remove beat: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Approval ────────────────────────────────────────────────────────

    async handleSubmitApproval() {
        const planId = this.journeyPlan?.Id || this.recordId;
        if (!planId) {
            this.showToast('Warning', 'No journey plan to submit.', 'warning');
            return;
        }

        this.isLoading = true;
        try {
            this._stripNs(await submitForApproval({ journeyPlanId: planId }));
            this.pjpStatus = 'Submitted';
            this.showToast('Success', 'Journey Plan submitted for approval.', 'success');
            await this.loadCalendar();
        } catch (error) {
            this.showToast('Error', 'Approval failed: ' + this.reduceErrors(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    getWeekStart(date) {
        const d = new Date(date);
        d.setDate(d.getDate() - d.getDay());
        d.setHours(0, 0, 0, 0);
        return d;
    }

    getWorkingDaysInMonth() {
        const firstDay = new Date(this.currentYear, this.currentMonth, 1);
        const lastDay = new Date(this.currentYear, this.currentMonth + 1, 0);
        let count = 0;
        for (let d = new Date(firstDay); d <= lastDay; d.setDate(d.getDate() + 1)) {
            if (d.getDay() !== 0) count++;
        }
        return count;
    }

    formatDateKey(date) {
        const y = date.getFullYear();
        const m = String(date.getMonth() + 1).padStart(2, '0');
        const d = String(date.getDate()).padStart(2, '0');
        return y + '-' + m + '-' + d;
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