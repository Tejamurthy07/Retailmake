import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getHomePageData from '@salesforce/apex/HomePageController.getHomePageData';
import getMyVisibleComponents from '@salesforce/apex/FMCGWorkspaceConfigController.getMyVisibleComponents';

const TABS = {
    DASHBOARD: 'dashboard',
    FIELD_OPS: 'field_ops',
    SALES: 'sales',
    INVENTORY: 'inventory',
    HR: 'hr',
    ADMIN: 'admin'
};

export default class HomePage extends NavigationMixin(LightningElement) {

    @track activeTab = TABS.DASHBOARD;
    @track isLoading = true;
    @track data = {};
    @track currentTime = '';
    @track vis = {};

    _clockInterval;

    connectedCallback() {
        this.loadData();
        this.updateClock();
        this._clockInterval = setInterval(() => this.updateClock(), 60000);
    }

    disconnectedCallback() {
        if (this._clockInterval) clearInterval(this._clockInterval);
    }

    loadData() {
        this.isLoading = true;
        Promise.all([
            getHomePageData(),
            getMyVisibleComponents().catch(() => ({}))
        ])
            .then(([result, visibility]) => {
                this.data = result || {};
                this.vis = visibility || {};
                const tabOrder = [TABS.DASHBOARD, TABS.FIELD_OPS, TABS.SALES,
                    TABS.INVENTORY, TABS.HR, TABS.ADMIN];
                if (this.vis['tab_' + this.activeTab] === false) {
                    const firstVisible = tabOrder.find(k => this.vis['tab_' + k] !== false);
                    if (firstVisible) this.activeTab = firstVisible;
                }
                this.isLoading = false;
            })
            .catch(error => {
                this.isLoading = false;
                this.showToast('Error', 'Failed to load dashboard data', 'error');
                console.error('HomePage load error:', error);
            });
    }

    updateClock() {
        const now = new Date();
        const options = { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' };
        this.currentTime = now.toLocaleDateString('en-IN', options);
    }

    get tabItems() {
        return [
            { key: TABS.DASHBOARD, label: 'Dashboard', icon: 'standard:home' },
            { key: TABS.FIELD_OPS, label: 'Field Ops', icon: 'standard:address' },
            { key: TABS.SALES, label: 'Sales', icon: 'standard:opportunity' },
            { key: TABS.INVENTORY, label: 'Inventory', icon: 'standard:product' },
            { key: TABS.HR, label: 'HR & Expense', icon: 'standard:people' },
            { key: TABS.ADMIN, label: 'Admin', icon: 'standard:settings' }
        ]
            .filter(t => this.vis['tab_' + t.key] !== false)
            .map(t => ({
                ...t,
                cssClass: 'hp-tab-item' + (t.key === this.activeTab ? ' hp-tab-active' : '')
            }));
    }

    handleTabClick(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    // ── Section visibility helpers ──
    _sectionHasVisible(keys) {
        return keys.some(k => this.vis[k] !== false);
    }

    // Field Ops sections (already existed)
    get showFieldOpsSetup() {
        return this._sectionHasVisible(['fo_beat_manager', 'fo_beat_calendar', 'fo_journey_plans']);
    }
    get showFieldOpsDaily() {
        return this._sectionHasVisible(['fo_visit_manager', 'fo_team_visit_dashboard', 'fo_visit_records']);
    }

    // Dashboard sections — NEW
    get showDashboardOverview() {
        return this._sectionHasVisible([
            'card_day_status','card_visits_completed','card_pending_orders','card_pending_collections',
            'card_open_tickets','card_active_schemes','card_pending_returns','card_low_stock_alerts','card_near_expiry_batches'
        ]);
    }
    get showDashboardQuickActions() {
        return this._sectionHasVisible([
            'qa_start_day','qa_visit_board','qa_beat_plan','qa_new_order','qa_collections','qa_catalog','qa_kpi_dashboard'
        ]);
    }
    get showDashboardAnalytics() {
        return this._sectionHasVisible([
            'ai_dynamic_kpi','ai_achievement_dashboard','ai_kpi_metric_manager'
        ]);
    }

    // Sales sections — NEW
    get showSalesSetup() {
        return this._sectionHasVisible(['sales_accounts','sales_scheme_manager','sales_competitors']);
    }
    get showSalesOrderMgmt() {
        return this._sectionHasVisible(['sales_orders','sales_collections','sales_invoices','sales_returns']);
    }
    get showSalesTargets() {
        return this._sectionHasVisible([
            'sales_target_periods','sales_target_criteria','sales_target_allocation',
            'sales_incentive_slabs','sales_incentive_dashboard'
        ]);
    }

    // Inventory sections — NEW
    get showInvSetup() {
        return this._sectionHasVisible(['inv_product_hub','inv_uom_conversions','inv_warehouses_setup']);
    }
    get showInvOps() {
        return this._sectionHasVisible([
            'inv_stock_dashboard','inv_warehouse_dashboard','inv_stock_transfers','inv_product_catalog'
        ]);
    }

    // HR sections — NEW
    get showHrSetup() {
        return this._sectionHasVisible([
            'hr_employee_manager','hr_leave_policies','hr_holiday_manager','hr_expense_eligibility'
        ]);
    }
    get showHrLeave() {
        return this._sectionHasVisible(['hr_leave_manager','hr_leave_approval','hr_leave_balances']);
    }
    get showHrAttendanceExpense() {
        return this._sectionHasVisible(['hr_team_attendance','hr_expense_manager']);
    }

    // Admin sections — NEW
    get showAdminMasterData() {
        return this._sectionHasVisible(['admin_territory_master','admin_warehouses']);
    }
    get showAdminMappings() {
        return this._sectionHasVisible([
            'admin_category_mapping','admin_kpi_metric_manager','admin_survey_manager'
        ]);
    }
    get showAdminDashboards() {
        return this._sectionHasVisible([
            'admin_fscrm_dashboard','admin_kpi_dashboard','admin_achievement_dashboard','admin_dynamic_kpi_dashboard'
        ]);
    }

    // Tab visibility
    get isDashboard() {
        return this.activeTab === TABS.DASHBOARD && this.vis['tab_dashboard'] !== false;
    }
    get isFieldOps() {
        return this.activeTab === TABS.FIELD_OPS && this.vis['tab_field_ops'] !== false;
    }
    get isSales() {
        return this.activeTab === TABS.SALES && this.vis['tab_sales'] !== false;
    }
    get isInventory() {
        return this.activeTab === TABS.INVENTORY && this.vis['tab_inventory'] !== false;
    }
    get isHr() {
        return this.activeTab === TABS.HR && this.vis['tab_hr'] !== false;
    }
    get isAdmin() {
        return this.activeTab === TABS.ADMIN && this.vis['tab_admin'] !== false;
    }

    get visitProgress() {
        if (!this.data || !this.data.todayVisitCount) return 0;
        return Math.round((this.data.completedVisitCount / this.data.todayVisitCount) * 100);
    }

    get visitProgressStyle() {
        return `width: ${this.visitProgress}%`;
    }

    get attendanceBadgeClass() {
        return this.data.isDayStarted ? 'hp-badge hp-badge-success' : 'hp-badge hp-badge-warning';
    }

    _isMobile() {
        return /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
    }

    navigateTo(event) {
        const tabName = event.currentTarget.dataset.target;
        if (!tabName) return;

        const pageRef = {
            type: 'standard__navItemPage',
            attributes: { apiName: tabName }
        };

        if (this._isMobile()) {
            this[NavigationMixin.Navigate](pageRef);
        } else {
            this[NavigationMixin.GenerateUrl](pageRef).then(url => {
                window.open(url, '_blank');
            });
        }
    }

    navigateToObject(event) {
        const objectName = event.currentTarget.dataset.object;
        if (!objectName) return;

        const pageRef = {
            type: 'standard__objectPage',
            attributes: { objectApiName: objectName, actionName: 'list' },
            state: { filterName: 'Recent' }
        };

        if (this._isMobile()) {
            this[NavigationMixin.Navigate](pageRef);
        } else {
            this[NavigationMixin.GenerateUrl](pageRef).then(url => {
                window.open(url, '_blank');
            });
        }
    }

    handleRefresh() {
        this.loadData();
        this.showToast('Refreshed', 'Dashboard data updated', 'success');
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}