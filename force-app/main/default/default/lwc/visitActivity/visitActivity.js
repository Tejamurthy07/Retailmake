import { LightningElement, api, track, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';

import getVisitCompletionSummary from '@salesforce/apex/VisitCheckInController.getVisitCompletionSummary';

// Visit fields
import VISIT_STATUS from '@salesforce/schema/Visit__c.Visit_Status__c';
import ACCOUNT_NAME from '@salesforce/schema/Visit__c.Account__r.Name';
import BEAT_NAME from '@salesforce/schema/Visit__c.Beat__r.Name';
import CHECK_IN_TIME from '@salesforce/schema/Visit__c.Check_In_Time__c';
import CHECK_OUT_TIME from '@salesforce/schema/Visit__c.Check_Out_Time__c';
import VISIT_SEQUENCE from '@salesforce/schema/Visit__c.Visit_Sequence__c';
import ORDER_VALUE from '@salesforce/schema/Visit__c.Order_Value__c';
import COLLECTION_AMOUNT from '@salesforce/schema/Visit__c.Collection_Amount__c';
import TOTAL_ORDERS_COUNT from '@salesforce/schema/Visit__c.Total_Orders_Count__c';
import IS_AD_HOC from '@salesforce/schema/Visit__c.Is_Ad_Hoc__c';
import IS_PRODUCTIVE from '@salesforce/schema/Visit__c.Is_Productive__c';
import NON_PRODUCTIVE_REASON from '@salesforce/schema/Visit__c.Non_Productive_Reason__c';
import DURATION_MINUTES from '@salesforce/schema/Visit__c.Duration_Minutes__c';

const VISIT_FIELDS = [
    VISIT_STATUS, ACCOUNT_NAME, BEAT_NAME,
    CHECK_IN_TIME, CHECK_OUT_TIME, VISIT_SEQUENCE, ORDER_VALUE,
    COLLECTION_AMOUNT, TOTAL_ORDERS_COUNT, IS_AD_HOC,
    IS_PRODUCTIVE, NON_PRODUCTIVE_REASON, DURATION_MINUTES
];

const INR_FORMATTER = new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0
});

export default class VisitActivity extends NavigationMixin(LightningElement) {
    @api recordId;

    @track activeTab = 'orders';
    @track orders = [];
    @track collections = [];
    @track returns = [];
    @track isLoading = false;
    @track mustSellCompliance = null;
    @track mustSellOrdered = 0;
    @track mustSellRequired = 0;

    visitRecord = null;

    @wire(getRecord, { recordId: '$recordId', fields: VISIT_FIELDS })
    wiredVisit({ error, data }) {
        if (data) {
            this.visitRecord = data;
            this._loadSummary();
        } else if (error) {
            console.error('Error loading visit:', error);
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

    async _loadSummary() {
        try {
            this.isLoading = true;
            const summary = this._stripNs(await getVisitCompletionSummary({ visitId: this.recordId }));

            if (summary) {
                this.orders = (summary.orders || []).map(o => ({
                    ...o,
                    amountFormatted: INR_FORMATTER.format(o.Total_Net_Amount__c || 0)
                }));
                this.collections = (summary.collections || []).map(c => ({
                    ...c,
                    amountFormatted: INR_FORMATTER.format(c.Amount__c || 0)
                }));
                this.returns = (summary.returns || []).map(r => ({
                    ...r,
                    amountFormatted: INR_FORMATTER.format(r.Total_Return_Amount__c || 0)
                }));
                this.mustSellCompliance = summary.mustSellCompliance;
                this.mustSellOrdered = summary.mustSellOrdered || 0;
                this.mustSellRequired = summary.mustSellRequired || 0;
            }
        } catch (err) {
            console.error('Error loading visit summary:', err);
        } finally {
            this.isLoading = false;
        }
    }

    // ----- Getters for visit data -----
    get outletName() {
        return this.visitRecord ? getFieldValue(this.visitRecord, ACCOUNT_NAME) : '';
    }
    get beatName() {
        return this.visitRecord ? getFieldValue(this.visitRecord, BEAT_NAME) : '';
    }
    get visitStatus() {
        return this.visitRecord ? getFieldValue(this.visitRecord, VISIT_STATUS) : '';
    }
    get checkInTime() {
        const t = this.visitRecord ? getFieldValue(this.visitRecord, CHECK_IN_TIME) : null;
        return this._fmtTime(t);
    }
    get checkOutTime() {
        const t = this.visitRecord ? getFieldValue(this.visitRecord, CHECK_OUT_TIME) : null;
        return this._fmtTime(t);
    }
    get visitSequence() {
        return this.visitRecord ? getFieldValue(this.visitRecord, VISIT_SEQUENCE) : '';
    }
    get orderValue() {
        const v = this.visitRecord ? getFieldValue(this.visitRecord, ORDER_VALUE) : 0;
        return INR_FORMATTER.format(v || 0);
    }
    get collectionAmount() {
        const v = this.visitRecord ? getFieldValue(this.visitRecord, COLLECTION_AMOUNT) : 0;
        return INR_FORMATTER.format(v || 0);
    }
    get totalOrdersCount() {
        return this.visitRecord ? getFieldValue(this.visitRecord, TOTAL_ORDERS_COUNT) || 0 : 0;
    }
    get isAdHoc() {
        return this.visitRecord ? getFieldValue(this.visitRecord, IS_AD_HOC) : false;
    }
    get isActiveVisit() {
        return this.visitStatus === 'Checked In' || this.visitStatus === 'In Progress';
    }
    get isCompletedVisit() {
        return this.visitStatus === 'Completed';
    }
    get isProductiveVisit() {
        return this.visitRecord ? getFieldValue(this.visitRecord, IS_PRODUCTIVE) : false;
    }
    get nonProductiveReasonDisplay() {
        return this.visitRecord ? getFieldValue(this.visitRecord, NON_PRODUCTIVE_REASON) : '';
    }
    get durationDisplay() {
        const mins = this.visitRecord ? getFieldValue(this.visitRecord, DURATION_MINUTES) : null;
        if (!mins && mins !== 0) return '--';
        const h = Math.floor(mins / 60);
        const m = Math.round(mins % 60);
        return h > 0 ? `${h}h ${m}m` : `${m}m`;
    }
    get statusBadgeClass() {
        if (this.isActiveVisit) return 'status-badge status-active';
        if (this.isCompletedVisit) return 'status-badge status-completed';
        return 'status-badge status-other';
    }

    // ----- Tab management -----
    get isOrdersTab() { return this.activeTab === 'orders'; }
    get isCollectionsTab() { return this.activeTab === 'collections'; }
    get isReturnsTab() { return this.activeTab === 'returns'; }

    get ordersTabClass() { return 'va-tab' + (this.isOrdersTab ? ' va-tab-selected' : ''); }
    get collectionsTabClass() { return 'va-tab' + (this.isCollectionsTab ? ' va-tab-selected' : ''); }
    get returnsTabClass() { return 'va-tab' + (this.isReturnsTab ? ' va-tab-selected' : ''); }

    get hasOrders() { return this.orders.length > 0; }
    get hasCollections() { return this.collections.length > 0; }
    get hasReturns() { return this.returns.length > 0; }

    // ----- Must Sell compliance -----
    get hasMustSellData() {
        return this.mustSellRequired > 0;
    }

    get mustSellComplianceFormatted() {
        if (this.mustSellCompliance == null) return '0%';
        return Math.round(this.mustSellCompliance) + '%';
    }

    get mustSellSummaryText() {
        return this.mustSellOrdered + '/' + this.mustSellRequired + ' priority sell products ordered';
    }

    get complianceBarStyle() {
        const pct = Math.min(this.mustSellCompliance || 0, 100);
        const color = pct >= 100 ? '#2e844a' : (pct >= 50 ? '#dd7a01' : '#ea001e');
        return 'width:' + pct + '%;background:' + color;
    }

    get mustSellComplianceClass() {
        if (this.mustSellCompliance >= 100) return 'compliance-badge compliance-green';
        if (this.mustSellCompliance >= 50) return 'compliance-badge compliance-yellow';
        return 'compliance-badge compliance-red';
    }

    // ----- Tab click -----
    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    // ----- View record (navigate to record detail) -----
    handleViewRecord(event) {
        const recId = event.currentTarget.dataset.id;
        const objApi = event.currentTarget.dataset.object;
        if (recId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: recId,
                    objectApiName: objApi || 'Sales_Order__c',
                    actionName: 'view'
                }
            });
        }
    }

    _fmtTime(dt) {
        if (!dt) return '--';
        try {
            return new Date(dt).toLocaleTimeString('en-IN', {
                hour: '2-digit', minute: '2-digit', hour12: true
            });
        } catch (e) { return '--'; }
    }
}