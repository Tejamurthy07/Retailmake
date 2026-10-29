import { LightningElement, api, track, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getOutletDetails from '@salesforce/apex/OutletThreeSixtyController.getOutletDetails';
import getOutletKPIs from '@salesforce/apex/OutletThreeSixtyController.getOutletKPIs';
import getRecentOrders from '@salesforce/apex/OutletThreeSixtyController.getRecentOrders';
import getCollectionHistory from '@salesforce/apex/OutletThreeSixtyController.getCollectionHistory';
import getVisitHistory from '@salesforce/apex/OutletThreeSixtyController.getVisitHistory';
import getApplicableSchemes from '@salesforce/apex/OutletThreeSixtyController.getApplicableSchemes';
import getStockLevels from '@salesforce/apex/OutletThreeSixtyController.getStockLevels';
import getTickets from '@salesforce/apex/OutletThreeSixtyController.getTickets';

const ACCOUNT_FIELDS = [
    'Account.Name',
    'Account.Outlet_Class__c',
    'Account.Channel__c',
    'Account.Outlet_Type__c',
    'Account.GSTIN__c',
    'Account.PAN__c',
    'Account.Owner_Name__c',
    'Account.Visit_Frequency__c',
    'Account.Is_Active__c',
    'Account.Beat__c',
    'Account.Territory__c',
    'Account.BillingLatitude',
    'Account.BillingLongitude',
    'Account.BillingStreet',
    'Account.BillingCity',
    'Account.BillingState',
    'Account.Phone',
    'Account.RecordType.Name'
];

export default class OutletThreeSixty extends NavigationMixin(LightningElement) {
    @api recordId;

    @track activeTab = 'orders';
    @track outletData = {};
    @track kpiData = {};
    @track orders = [];
    @track collections = [];
    @track visits = [];
    @track schemes = [];
    @track stockItems = [];
    @track timeline = [];
    @track tickets = [];
    @track mapMarkers = null;

    isLoading = false;
    dataLoaded = false;

    // ── Computed Properties ───────────────────────────────────────────────

    get hasOrders() { return this.orders && this.orders.length > 0; }
    get hasCollections() { return this.collections && this.collections.length > 0; }
    get hasVisits() { return this.visits && this.visits.length > 0; }
    get hasSchemes() { return this.schemes && this.schemes.length > 0; }
    get hasStock() { return this.stockItems && this.stockItems.length > 0; }
    get hasTimeline() { return this.timeline && this.timeline.length > 0; }
    get hasTickets() { return this.tickets && this.tickets.length > 0; }
    get hasMapMarkers() { return this.mapMarkers && this.mapMarkers.length > 0; }

    get outletName() { return this.outletData.name || ''; }
    get outletClass() { return this.outletData.outletClass || ''; }
    get outletChannel() { return this.outletData.channel || ''; }
    get outletType() { return this.outletData.outletType || ''; }
    get outletGSTIN() { return this.outletData.gstin || ''; }
    get hasGSTIN() { return !!this.outletData.gstin; }
    get outletPAN() { return this.outletData.pan || ''; }
    get hasPAN() { return !!this.outletData.pan; }
    get outletPhone() { return this.outletData.phone || ''; }
    get hasPhone() { return !!this.outletData.phone; }
    get outletOwnerName() { return this.outletData.ownerName || ''; }
    get hasOwnerName() { return !!this.outletData.ownerName; }
    get outletBeat() { return this.outletData.beatName || ''; }
    get hasBeat() { return !!this.outletData.beatName; }
    get outletTerritory() { return this.outletData.territoryName || ''; }
    get hasTerritory() { return !!this.outletData.territoryName; }
    get outletAddress() { return this.outletData.address || ''; }
    get hasAddress() { return !!this.outletData.address; }
    get isActive() { return this.outletData.isActive !== false; }

    get classBadgeClass() {
        const cls = this.outletData.outletClass || 'B';
        const map = { 'A': 'class-a', 'B': 'class-b', 'C': 'class-c', 'D': 'class-d' };
        return 'class-badge ' + (map[cls] || 'class-b');
    }

    get activeStatusClass() {
        return this.isActive ? 'active-badge active-yes' : 'active-badge active-no';
    }

    get activeStatusLabel() {
        return this.isActive ? 'Active' : 'Inactive';
    }

    // ── KPI Formatted Values ──────────────────────────────────────────────

    get mtdOrderValue() { return this.formatCurrencyShort(this.kpiData.mtdOrderValue || 0); }
    get mtdOrderCount() { return this.kpiData.mtdOrderCount || 0; }
    get outstandingBalance() { return this.formatCurrencyShort(this.kpiData.outstandingBalance || 0); }
    get mtdCollection() { return this.formatCurrencyShort(this.kpiData.mtdCollection || 0); }
    get avgOrderValue() { return this.formatCurrencyShort(this.kpiData.avgOrderValue || 0); }
    get visitFrequency() { return this.outletData.visitFrequency || 'N/A'; }
    get overdueAmount() { return this.formatCurrencyShort(this.kpiData.overdueAmount || 0); }
    get mtdVisitCount() { return this.kpiData.mtdVisitCount || 0; }

    // Credit utilization
    get creditLimit() { return this.formatCurrency(this.kpiData.creditLimit || 0); }
    get creditUtilized() { return this.formatCurrency(this.kpiData.creditUtilized || 0); }
    get creditAvailable() { return this.formatCurrency(this.kpiData.creditAvailable || 0); }
    get creditUtilizationPct() { return this.kpiData.creditUtilizationPct || 0; }
    get hasCreditLimit() { return (this.kpiData.creditLimit || 0) > 0; }

    get creditBarStyle() {
        const pct = Math.min(this.creditUtilizationPct, 100);
        let color = '#2e844a'; // green
        if (pct > 80) color = '#ea001e'; // red
        else if (pct > 60) color = '#dd7a01'; // orange
        return `width: ${pct}%; background-color: ${color};`;
    }

    get creditBarClass() {
        const pct = this.creditUtilizationPct;
        if (pct > 80) return 'credit-bar-fill credit-danger';
        if (pct > 60) return 'credit-bar-fill credit-warning';
        return 'credit-bar-fill credit-healthy';
    }

    get hasOutstandingBalance() {
        return (this.kpiData.outstandingBalance || 0) > 0;
    }

    get hasOverdue() {
        return (this.kpiData.overdueAmount || 0) > 0;
    }

    // ── Wire Adapter ──────────────────────────────────────────────────────

    @wire(getRecord, { recordId: '$recordId', fields: ACCOUNT_FIELDS })
    wiredAccount({ error, data }) {
        if (data) {
            const name = getFieldValue(data, 'Account.Name');
            const outletClass = getFieldValue(data, 'Account.Outlet_Class__c') || 'B';
            const channel = getFieldValue(data, 'Account.Channel__c') || '';
            const outletType = getFieldValue(data, 'Account.Outlet_Type__c') || '';
            const gstin = getFieldValue(data, 'Account.GSTIN__c');
            const pan = getFieldValue(data, 'Account.PAN__c');
            const ownerName = getFieldValue(data, 'Account.Owner_Name__c');
            const visitFreq = getFieldValue(data, 'Account.Visit_Frequency__c') || 'Weekly';
            const isActive = getFieldValue(data, 'Account.Is_Active__c');
            const phone = getFieldValue(data, 'Account.Phone');
            const lat = getFieldValue(data, 'Account.BillingLatitude');
            const lng = getFieldValue(data, 'Account.BillingLongitude');
            const street = getFieldValue(data, 'Account.BillingStreet') || '';
            const city = getFieldValue(data, 'Account.BillingCity') || '';
            const state = getFieldValue(data, 'Account.BillingState') || '';
            const recordType = getFieldValue(data, 'Account.RecordType.Name') || '';

            const addressParts = [street, city, state].filter(Boolean);

            this.outletData = {
                name,
                outletClass,
                channel,
                outletType,
                gstin,
                pan,
                ownerName,
                visitFrequency: visitFreq,
                isActive,
                phone,
                beatName: '',
                territoryName: '',
                recordType,
                address: addressParts.join(', ')
            };

            if (lat && lng) {
                this.mapMarkers = [{
                    location: { Latitude: lat, Longitude: lng },
                    title: name,
                    description: addressParts.join(', ')
                }];
            }

            if (!this.dataLoaded) {
                this.dataLoaded = true;
                console.log('[O360] wiredAccount: first load, recordId =', this.recordId, 'accountName =', name);
                this.loadKPIs();
                this.loadOutletFullDetails();
                this.loadTabData('orders');
            }
        } else if (error) {
            console.error('[O360] wiredAccount error:', error);
            this.showToast('Error', 'Failed to load account', 'error');
        }
    }

    // ── Data Loading ──────────────────────────────────────────────────────

    async loadOutletFullDetails() {
        try {
            const result = await getOutletDetails({ accountId: this.recordId });
            if (result) {
                this.outletData = {
                    ...this.outletData,
                    beatName: result.Beat__r ? result.Beat__r.Name : '',
                    territoryName: result.Territory__r ? result.Territory__r.Name : ''
                };
            }
        } catch (error) {
            console.error('Error loading outlet details:', error);
        }
    }

    async loadKPIs() {
        try {
            const result = await getOutletKPIs({ accountId: this.recordId });
            if (result) {
                this.kpiData = result;
            }
        } catch (error) {
            console.error('Error loading KPIs:', error);
        }
    }

    handleTabChange(event) {
        // lightning-tabset retargets the `active` event at the shadow boundary,
        // so `event.target` becomes the tabset (no `.value`). The tab's value
        // is published on the event detail.
        const newTab = (event.detail && event.detail.value) || event.target.value;
        console.log('[O360] handleTabChange fired:', {
            'event.type': event.type,
            'event.detail': event.detail,
            'event.target.value': event.target && event.target.value,
            'resolved newTab': newTab
        });
        if (!newTab) {
            console.warn('[O360] handleTabChange: could not resolve tab value — aborting load');
            return;
        }
        this.activeTab = newTab;
        this.loadTabData(newTab);
    }

    async loadTabData(tabName) {
        console.log('[O360] loadTabData called with tabName =', tabName, 'recordId =', this.recordId);
        this.isLoading = true;
        try {
            switch (tabName) {
                case 'orders':
                    await this.loadOrders();
                    break;
                case 'collections':
                    await this.loadCollections();
                    break;
                case 'visits':
                    await this.loadVisits();
                    break;
                case 'schemes':
                    await this.loadSchemes();
                    break;
                case 'stock':
                    await this.loadStock();
                    break;
                case 'timeline':
                    await this.loadTimeline();
                    break;
                case 'tickets':
                    await this.loadTickets();
                    break;
                default:
                    console.warn('[O360] loadTabData: unknown tab, no-op:', tabName);
                    break;
            }
        } catch (error) {
            console.error('[O360] loadTabData error:', error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadOrders() {
        try {
            const result = await getRecentOrders({ accountId: this.recordId, limitCount: 20 });
            console.log('[O360] loadOrders -> rows:', (result || []).length, 'first:', result && result[0]);
            this.orders = (result || []).map(order => ({
                id: order.Id,
                orderNumber: order.Name,
                date: order.Order_Date__c,
                dateFormatted: this.formatDate(order.Order_Date__c),
                itemCount: order.Total_Items__c || 0,
                amount: order.Total_Net_Amount__c || 0,
                amountFormatted: this.formatCurrency(order.Total_Net_Amount__c || 0),
                status: order.Status__c || 'Draft',
                statusBadge: this.getStatusBadgeClass(order.Status__c),
                orderType: order.Order_Type__c || '',
                salesperson: order.Salesperson__r ? order.Salesperson__r.Name : ''
            }));
        } catch (error) {
            console.error('[O360] loadOrders error:', JSON.stringify(error), error);
            this.orders = [];
        }
    }

    async loadCollections() {
        try {
            const result = await getCollectionHistory({ accountId: this.recordId, limitCount: 20 });
            console.log('[O360] loadCollections -> rows:', (result || []).length, 'first:', result && result[0]);
            this.collections = (result || []).map(col => ({
                id: col.Id,
                receiptNumber: col.Receipt_Number__c || col.Name,
                date: col.Collection_Date__c,
                dateFormatted: this.formatDate(col.Collection_Date__c),
                amount: col.Amount__c || 0,
                amountFormatted: this.formatCurrency(col.Amount__c || 0),
                mode: col.Payment_Mode__c || 'Cash',
                status: col.Status__c || 'Confirmed',
                statusBadge: this.getStatusBadgeClass(col.Status__c),
                invoiceName: col.Invoice__r ? col.Invoice__r.Name : (col.Is_On_Account__c ? 'On Account' : ''),
                chequeNumber: col.Cheque_Number__c || '',
                bankName: col.Bank_Name__c || ''
            }));
        } catch (error) {
            console.error('[O360] loadCollections error:', JSON.stringify(error), error);
            this.collections = [];
        }
    }

    async loadVisits() {
        try {
            const result = await getVisitHistory({ accountId: this.recordId, limitCount: 20 });
            console.log('[O360] loadVisits -> rows:', (result || []).length, 'first:', result && result[0]);
            this.visits = (result || []).map(visit => ({
                id: visit.Id,
                date: visit.Visit_Date__c,
                dateFormatted: this.formatDate(visit.Visit_Date__c),
                salesperson: visit.Salesperson__r ? visit.Salesperson__r.Name : 'N/A',
                checkInTime: this.formatTime(visit.Check_In_Time__c),
                checkOutTime: this.formatTime(visit.Check_Out_Time__c),
                duration: this.formatDuration(visit.Duration_Minutes__c),
                isProductive: visit.Is_Productive__c !== false,
                isPlanned: visit.Is_Planned__c === true,
                orderValue: visit.Order_Value__c ? this.formatCurrency(visit.Order_Value__c) : '',
                collectionAmount: visit.Collection_Amount__c ? this.formatCurrency(visit.Collection_Amount__c) : '',
                status: visit.Visit_Status__c || '',
                nonProductiveReason: visit.Non_Productive_Reason__c || '',
                beatName: visit.Beat__r ? visit.Beat__r.Name : ''
            }));
        } catch (error) {
            console.error('[O360] loadVisits error:', JSON.stringify(error), error);
            this.visits = [];
        }
    }

    async loadSchemes() {
        try {
            const result = await getApplicableSchemes({ accountId: this.recordId });
            console.log('[O360] loadSchemes -> rows:', (result || []).length, 'first:', result && result[0]);
            this.schemes = (result || []).map(scheme => ({
                id: scheme.Id,
                name: scheme.Name,
                code: scheme.Scheme_Code__c || '',
                type: scheme.Scheme_Type__c || 'Discount',
                description: scheme.Description__c || '',
                validFrom: this.formatDate(scheme.Start_Date__c),
                validTo: this.formatDate(scheme.End_Date__c),
                typeBadgeStyle: this.getSchemeTypeBadgeStyle(scheme.Scheme_Type__c),
                budgetAmount: scheme.Budget_Amount__c ? this.formatCurrency(scheme.Budget_Amount__c) : '',
                budgetRemaining: scheme.Budget_Remaining__c ? this.formatCurrency(scheme.Budget_Remaining__c) : '',
                maxDiscount: scheme.Max_Discount_Cap__c ? this.formatCurrency(scheme.Max_Discount_Cap__c) : '',
                isStackable: scheme.Is_Stackable__c
            }));
        } catch (error) {
            console.error('[O360] loadSchemes error:', JSON.stringify(error), error);
            this.schemes = [];
        }
    }

    async loadStock() {
        try {
            const result = await getStockLevels({ accountId: this.recordId });
            console.log('[O360] loadStock -> rows:', (result || []).length, 'first:', result && result[0]);
            this.stockItems = (result || []).map(item => ({
                id: item.Id,
                productName: item.Product_Ext__r ? item.Product_Ext__r.Name : 'N/A',
                sku: item.Product_Ext__r ? item.Product_Ext__r.SKU_Code__c : '',
                closingStock: item.Closing_Stock__c || 0,
                openingStock: item.Opening_Stock__c || 0,
                receivedQty: item.Received_Qty__c || 0,
                soldQty: item.Sold_Qty__c || 0,
                damagedQty: item.Damaged_Qty__c || 0,
                batchNo: item.Batch_No__c || '',
                expiryDate: item.Expiry_Date__c ? this.formatDate(item.Expiry_Date__c) : '',
                stockDate: item.Stock_Date__c ? this.formatDate(item.Stock_Date__c) : '',
                qtyClass: this.getStockQtyClass(item.Closing_Stock__c)
            }));
        } catch (error) {
            console.error('[O360] loadStock error:', JSON.stringify(error), error);
            this.stockItems = [];
        }
    }

    async loadTickets() {
        try {
            const result = await getTickets({ accountId: this.recordId, limitCount: 20 });
            console.log('[O360] loadTickets -> rows:', (result || []).length);
            this.tickets = result || [];
        } catch (error) {
            console.error('[O360] loadTickets error:', JSON.stringify(error), error);
            this.tickets = [];
        }
    }

    async loadTimeline() {
        try {
            // Build timeline client-side from the same Apex methods that power
            // the Orders / Collections / Visits tabs. This avoids the separate
            // getAccountTimeline server method (which can silently return empty
            // when FLS or sharing hides any one of the three objects from the
            // running user) and guarantees the Timeline stays in sync with what
            // the other tabs show.
            const [orders, visits, collections] = await Promise.all([
                getRecentOrders({ accountId: this.recordId, limitCount: 30 }).catch(err => {
                    console.error('[O360] Timeline: orders fetch failed', JSON.stringify(err), err);
                    return [];
                }),
                getVisitHistory({ accountId: this.recordId, limitCount: 30 }).catch(err => {
                    console.error('[O360] Timeline: visits fetch failed', JSON.stringify(err), err);
                    return [];
                }),
                getCollectionHistory({ accountId: this.recordId, limitCount: 30 }).catch(err => {
                    console.error('[O360] Timeline: collections fetch failed', JSON.stringify(err), err);
                    return [];
                })
            ]);
            console.log('[O360] loadTimeline fetched:', {
                orders: (orders || []).length,
                visits: (visits || []).length,
                collections: (collections || []).length
            });

            const entries = [];

            (orders || []).forEach(order => {
                const items = order.Total_Items__c != null ? Math.round(order.Total_Items__c) : 0;
                entries.push({
                    id: order.Id,
                    type: 'Order',
                    title: order.Name,
                    description: 'Order placed - ' + items + ' items',
                    date: order.Order_Date__c,
                    amountValue: order.Total_Net_Amount__c,
                    status: order.Status__c || '',
                    iconName: 'standard:orders'
                });
            });

            (visits || []).forEach(visit => {
                const sp = visit.Salesperson__r ? visit.Salesperson__r.Name : 'N/A';
                let desc = 'Visit by ' + sp;
                if (visit.Duration_Minutes__c != null) {
                    desc += ' (' + Math.round(visit.Duration_Minutes__c) + ' min)';
                }
                entries.push({
                    id: visit.Id,
                    type: 'Visit',
                    title: visit.Name,
                    description: desc,
                    date: visit.Visit_Date__c,
                    amountValue: visit.Order_Value__c,
                    status: visit.Visit_Status__c || '',
                    iconName: 'standard:log_a_call'
                });
            });

            (collections || []).forEach(col => {
                entries.push({
                    id: col.Id,
                    type: 'Collection',
                    title: col.Receipt_Number__c || col.Name,
                    description: 'Payment via ' + (col.Payment_Mode__c || 'N/A'),
                    date: col.Collection_Date__c,
                    amountValue: col.Amount__c,
                    status: col.Status__c || '',
                    iconName: 'standard:currency'
                });
            });

            // Sort descending by date (null dates last)
            entries.sort((a, b) => {
                if (!a.date && !b.date) return 0;
                if (!a.date) return 1;
                if (!b.date) return -1;
                return a.date < b.date ? 1 : (a.date > b.date ? -1 : 0);
            });

            this.timeline = entries.slice(0, 30).map(entry => ({
                id: entry.id,
                type: entry.type,
                title: entry.title,
                description: entry.description,
                date: entry.date,
                dateFormatted: this.formatDate(entry.date),
                amount: entry.amountValue ? this.formatCurrency(entry.amountValue) : '',
                hasAmount: entry.amountValue != null && entry.amountValue > 0,
                status: entry.status,
                iconName: entry.iconName,
                statusBadge: this.getStatusBadgeClass(entry.status),
                typeBadge: this.getTimelineTypeBadge(entry.type)
            }));
        } catch (error) {
            console.error('Error loading timeline:', error);
            this.timeline = [];
        }
    }

    // ── Actions ───────────────────────────────────────────────────────────

    refreshData() {
        this.loadKPIs();
        this.loadTabData(this.activeTab);
    }

    navigateToRecord(event) {
        const recordId = event.currentTarget.dataset.id;
        if (recordId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: recordId, actionName: 'view' }
            });
        }
    }

    // ── Formatting Utilities ──────────────────────────────────────────────

    getStatusBadgeClass(status) {
        const map = {
            'Confirmed': 'status-badge badge-confirmed',
            'Approved': 'status-badge badge-confirmed',
            'Draft': 'status-badge badge-draft',
            'Pending': 'status-badge badge-pending',
            'Submitted': 'status-badge badge-pending',
            'Delivered': 'status-badge badge-delivered',
            'Completed': 'status-badge badge-delivered',
            'Cancelled': 'status-badge badge-cancelled',
            'Rejected': 'status-badge badge-cancelled',
            'Dispatched': 'status-badge badge-dispatched',
            'Bounced': 'status-badge badge-cancelled'
        };
        return map[status] || 'status-badge badge-draft';
    }

    getSchemeTypeBadgeStyle(type) {
        const colors = {
            'Percentage Discount': 'background-color: #e8f4fd; color: #0176d3',
            'Flat Discount': 'background-color: #e6f7e9; color: #2e844a',
            'Buy X Get Y Free': 'background-color: #fff8e1; color: #dd7a01',
            'Slab Discount': 'background-color: #f3e8ff; color: #9b59b6',
            'Volume Discount': 'background-color: #fce4e4; color: #ea001e'
        };
        return colors[type] || 'background-color: #f3f3f3; color: #706e6b';
    }

    getTimelineTypeBadge(type) {
        const map = {
            'Order': 'timeline-type type-order',
            'Visit': 'timeline-type type-visit',
            'Collection': 'timeline-type type-collection'
        };
        return map[type] || 'timeline-type';
    }

    getStockQtyClass(qty) {
        if (qty == null || qty <= 0) return 'qty-low';
        if (qty <= 10) return 'qty-low';
        if (qty <= 50) return 'qty-medium';
        return 'qty-high';
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-IN', {
            style: 'currency',
            currency: 'INR',
            minimumFractionDigits: 0,
            maximumFractionDigits: 0
        }).format(value || 0);
    }

    formatCurrencyShort(value) {
        if (!value) return '0';
        if (value >= 10000000) return (value / 10000000).toFixed(1) + ' Cr';
        if (value >= 100000) return (value / 100000).toFixed(1) + ' L';
        if (value >= 1000) return (value / 1000).toFixed(1) + ' K';
        return new Intl.NumberFormat('en-IN').format(Math.round(value));
    }

    formatDate(dateStr) {
        if (!dateStr) return '';
        return new Date(dateStr).toLocaleDateString('en-IN', {
            day: '2-digit', month: 'short', year: 'numeric'
        });
    }

    formatTime(timeStr) {
        if (!timeStr) return 'N/A';
        const date = new Date(timeStr);
        return date.toLocaleTimeString('en-IN', {
            hour: '2-digit', minute: '2-digit', hour12: true
        });
    }

    formatDuration(minutes) {
        if (!minutes) return 'N/A';
        if (minutes < 60) return minutes + ' min';
        const hrs = Math.floor(minutes / 60);
        const mins = minutes % 60;
        return hrs + 'h ' + mins + 'm';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}