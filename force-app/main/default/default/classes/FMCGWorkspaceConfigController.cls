/**
 * Controls visibility of FMCG Workspace components per Salesforce Profile.
 *
 * Two surfaces:
 *  - End users hit `getMyVisibleComponents()` to learn what to render
 *  - Admins hit `getAllProfiles`, `getComponentMaster`, `getConfigForProfile`,
 *    `saveConfig` to manage the mapping
 *
 * Default behavior: when a profile has NO config rows at all, every component
 * is shown. This keeps existing users unaffected until admin opts in to
 * restricting them.
 */
public with sharing class FMCGWorkspaceConfigController {

    // ── Component master list (source of truth) ──
    public class Component {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String tab;
        @AuraEnabled public String section;
        @AuraEnabled public String icon;   // SLDS icon e.g. utility:checkin
        @AuraEnabled public String color;  // theme: blue/green/orange/purple/red/teal
        public Component(String k, String l, String t, String s, String i, String c) {
            this.key = k; this.label = l; this.tab = t; this.section = s;
            this.icon = i; this.color = c;
        }
    }

    private static final List<Component> MASTER = new List<Component>{
        // Tabs themselves can be hidden too
        new Component('tab_dashboard',     'Dashboard',       'tab', 'Tabs', 'standard:home',         'blue'),
        new Component('tab_field_ops',     'Field Ops',       'tab', 'Tabs', 'standard:address',      'green'),
        new Component('tab_sales',         'Sales',           'tab', 'Tabs', 'standard:opportunity',  'orange'),
        new Component('tab_inventory',     'Inventory',       'tab', 'Tabs', 'standard:product',      'purple'),
        new Component('tab_hr',            'HR & Expense',    'tab', 'Tabs', 'standard:people',       'teal'),
        new Component('tab_admin',         'Admin',           'tab', 'Tabs', 'standard:settings',     'red'),

        // Dashboard — Today's Overview cards
        new Component('card_day_status',           'Day Status',           'dashboard', 'Today\'s Overview', 'standard:log_a_call',  'blue'),
        new Component('card_visits_completed',     'Visits Completed',     'dashboard', 'Today\'s Overview', 'standard:address',     'green'),
        new Component('card_pending_orders',       'Pending Orders',       'dashboard', 'Today\'s Overview', 'standard:orders',      'orange'),
        new Component('card_pending_collections',  'Pending Collections',  'dashboard', 'Today\'s Overview', 'standard:currency',    'purple'),
        new Component('card_open_tickets',         'Open Tickets',         'dashboard', 'Today\'s Overview', 'standard:case',        'red'),
        new Component('card_active_schemes',       'Active Schemes',       'dashboard', 'Today\'s Overview', 'standard:reward',      'teal'),
        new Component('card_pending_returns',      'Pending Returns',      'dashboard', 'Today\'s Overview', 'standard:return_order','orange'),
        new Component('card_low_stock_alerts',     'Low Stock Alerts',     'dashboard', 'Today\'s Overview', 'utility:warning',      'red'),
        new Component('card_near_expiry_batches',  'Near Expiry Batches',  'dashboard', 'Today\'s Overview', 'utility:clock',        'orange'),

        // Dashboard — Quick Actions
        new Component('qa_start_day',      'Start Day',     'dashboard', 'Quick Actions', 'utility:checkin',            'blue'),
        new Component('qa_visit_board',    'Visit Board',   'dashboard', 'Quick Actions', 'utility:location',           'green'),
        new Component('qa_beat_plan',      'Beat Plan',     'dashboard', 'Quick Actions', 'utility:routing_offline',    'orange'),
        new Component('qa_new_order',      'New Order',     'dashboard', 'Quick Actions', 'utility:cart',               'purple'),
        new Component('qa_collections',    'Collections',   'dashboard', 'Quick Actions', 'utility:money',              'teal'),
        new Component('qa_catalog',        'Catalog',       'dashboard', 'Quick Actions', 'utility:product_consumed',   'red'),
        new Component('qa_kpi_dashboard',  'KPI Dashboard', 'dashboard', 'Quick Actions', 'utility:chart',              'blue'),

        // Dashboard — Analytics & Insights
        new Component('ai_dynamic_kpi',           'Dynamic KPI Dashboard',  'dashboard', 'Analytics & Insights', 'standard:dashboard',   'blue'),
        new Component('ai_achievement_dashboard', 'Achievement Dashboard',  'dashboard', 'Analytics & Insights', 'standard:performance', 'teal'),
        new Component('ai_kpi_metric_manager',    'KPI Metric Manager',     'dashboard', 'Analytics & Insights', 'custom:custom25',      'orange'),

        // Field Ops — Setup
        new Component('fo_beat_manager',          'Beat Manager',          'field_ops', 'Setup: Territory & Beats', 'standard:shift',         'orange'),
        new Component('fo_beat_calendar',         'Beat Plan Calendar',    'field_ops', 'Setup: Territory & Beats', 'standard:event',         'green'),
        new Component('fo_journey_plans',         'Journey Plans',         'field_ops', 'Setup: Territory & Beats', 'standard:travel_mode',   'blue'),
        // Field Ops — Daily Operations
        new Component('fo_visit_manager',         'Visit Manager',         'field_ops', 'Daily Operations',         'standard:address',       'blue'),
        new Component('fo_team_visit_dashboard',  'Team Visit Dashboard',  'field_ops', 'Daily Operations',         'standard:dashboard',     'purple'),
        new Component('fo_visit_records',         'Visit Records',         'field_ops', 'Daily Operations',         'standard:record',        'teal'),

        // Sales — Setup
        new Component('sales_accounts',           'Accounts / Outlets',    'sales', 'Setup: Accounts & Schemes', 'standard:account',         'teal'),
        new Component('sales_scheme_manager',     'Scheme Manager',        'sales', 'Setup: Accounts & Schemes', 'standard:reward',          'purple'),
        new Component('sales_competitors',        'Competitors',           'sales', 'Setup: Accounts & Schemes', 'standard:swarm_session',   'orange'),
        // Sales — Order Management
        new Component('sales_orders',             'Sales Orders',          'sales', 'Order Management', 'standard:orders',        'blue'),
        new Component('sales_collections',        'Collections',           'sales', 'Order Management', 'standard:currency',      'green'),
        new Component('sales_invoices',           'Invoices',              'sales', 'Order Management', 'standard:contract',      'orange'),
        new Component('sales_returns',            'Return Orders',         'sales', 'Order Management', 'standard:return_order',  'red'),
        // Sales — Targets & Incentives
        new Component('sales_target_periods',     'Target Periods',            'sales', 'Targets & Incentives', 'standard:date_input', 'orange'),
        new Component('sales_target_criteria',    'Target Criteria Manager',   'sales', 'Targets & Incentives', 'standard:filter',     'blue'),
        new Component('sales_target_allocation',  'Target Allocation',         'sales', 'Targets & Incentives', 'standard:goals',      'green'),
        new Component('sales_incentive_slabs',    'Incentive Slab Manager',    'sales', 'Targets & Incentives', 'standard:slider',     'orange'),
        new Component('sales_incentive_dashboard','Incentive Dashboard',       'sales', 'Targets & Incentives', 'standard:reward',     'purple'),

        // Inventory — Setup
        new Component('inv_product_hub',          'Product Management Hub', 'inventory', 'Setup: Products & Warehouses', 'standard:product_workspace', 'orange'),
        new Component('inv_uom_conversions',      'UOM & Conversions',      'inventory', 'Setup: Products & Warehouses', 'standard:data_transforms',   'red'),
        new Component('inv_warehouses_setup',     'Warehouses',             'inventory', 'Setup: Products & Warehouses', 'standard:location',          'teal'),
        // Inventory — Stock Operations
        new Component('inv_stock_dashboard',      'Stock Dashboard',        'inventory', 'Stock Operations', 'standard:product_item', 'blue'),
        new Component('inv_warehouse_dashboard',  'Warehouse Dashboard',    'inventory', 'Stock Operations', 'standard:location',     'green'),
        new Component('inv_stock_transfers',      'Stock Transfers',        'inventory', 'Stock Operations', 'standard:asset_action', 'teal'),
        new Component('inv_product_catalog',      'Product Catalog',        'inventory', 'Stock Operations', 'standard:product',      'purple'),

        // HR — Setup
        new Component('hr_employee_manager',      'Employee Manager',       'hr', 'Setup: Employees & Policies', 'standard:people',       'blue'),
        new Component('hr_leave_policies',        'Leave Policies',         'hr', 'Setup: Employees & Policies', 'standard:entitlement',  'purple'),
        new Component('hr_holiday_manager',       'Holiday Manager',        'hr', 'Setup: Employees & Policies', 'standard:today',        'teal'),
        new Component('hr_expense_eligibility',   'Expense Eligibility',    'hr', 'Setup: Employees & Policies', 'standard:settings',     'blue'),
        // HR — Leave Management
        new Component('hr_leave_manager',         'Leave Manager',          'hr', 'Leave Management', 'standard:event',     'orange'),
        new Component('hr_leave_approval',        'Leave Approval',         'hr', 'Leave Management', 'standard:approval',  'purple'),
        new Component('hr_leave_balances',        'Leave Balances',         'hr', 'Leave Management', 'standard:timesheet', 'teal'),
        // HR — Attendance & Expenses
        new Component('hr_team_attendance',       'Team Attendance',        'hr', 'Attendance & Expenses', 'standard:date_input', 'green'),
        new Component('hr_expense_manager',       'Expense Manager',        'hr', 'Attendance & Expenses', 'standard:expense',    'red'),

        // Admin — Master Data
        new Component('admin_territory_master',     'Territory Master',         'admin', 'Master Data', 'standard:address',  'green'),
        new Component('admin_warehouses',           'Warehouses',               'admin', 'Master Data', 'standard:location', 'red'),
        // Admin — Mappings & Configuration
        new Component('admin_category_mapping',     'Category Mapping',         'admin', 'Mappings & Configuration', 'standard:hierarchy', 'purple'),
        new Component('admin_kpi_metric_manager',   'KPI Metric Manager',       'admin', 'Mappings & Configuration', 'custom:custom25',    'orange'),
        new Component('admin_survey_manager',       'Survey Manager',           'admin', 'Mappings & Configuration', 'standard:survey',    'purple'),
        // Admin — Dashboards & Analytics
        new Component('admin_fscrm_dashboard',      'CRM Dashboard',            'admin', 'Dashboards & Analytics', 'standard:dashboard',   'blue'),
        new Component('admin_kpi_dashboard',        'KPI Dashboard',            'admin', 'Dashboards & Analytics', 'standard:performance', 'green'),
        new Component('admin_achievement_dashboard','Achievement Dashboard',    'admin', 'Dashboards & Analytics', 'standard:performance', 'teal'),
        new Component('admin_dynamic_kpi_dashboard','Dynamic KPI Dashboard',    'admin', 'Dashboards & Analytics', 'standard:dashboard',   'blue')
    };

    private static Set<String> allKeys() {
        Set<String> keys = new Set<String>();
        for (Component c : MASTER) keys.add(c.key);
        return keys;
    }

    // ─────────────────────────────────────────────────────────────
    // END-USER METHOD
    // ─────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Map<String, Boolean> getMyVisibleComponents() {
        String profileName = currentUserProfileName();
        return resolveVisibility(profileName);
    }

    // ─────────────────────────────────────────────────────────────
    // ADMIN METHODS
    // ─────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Component> getComponentMaster() {
        return MASTER;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getAllProfiles() {
        List<Map<String, String>> result = new List<Map<String, String>>();
        for (Profile p : [SELECT Id, Name FROM Profile ORDER BY Name ASC]) {
            result.add(new Map<String, String>{ 'id' => p.Id, 'name' => p.Name });
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Boolean> getConfigForProfile(String profileName) {
        if (String.isBlank(profileName)) {
            throw new AuraHandledException('Profile name is required.');
        }
        return resolveVisibility(profileName);
    }

    @AuraEnabled
    public static void saveConfig(String profileName, List<String> visibleKeys) {
        if (String.isBlank(profileName)) {
            throw new AuraHandledException('Profile name is required.');
        }
        if (visibleKeys == null) visibleKeys = new List<String>();
        Set<String> visibleSet = new Set<String>(visibleKeys);

        List<FMCG_Workspace_Visibility__c> existing = [
            SELECT Id, Component_Key__c
            FROM FMCG_Workspace_Visibility__c
            WHERE Profile_Name__c = :profileName
        ];
        Map<String, FMCG_Workspace_Visibility__c> byKey = new Map<String, FMCG_Workspace_Visibility__c>();
        for (FMCG_Workspace_Visibility__c v : existing) byKey.put(v.Component_Key__c, v);

        List<FMCG_Workspace_Visibility__c> upserts = new List<FMCG_Workspace_Visibility__c>();
        for (String key : allKeys()) {
            FMCG_Workspace_Visibility__c row = byKey.get(key);
            if (row == null) {
                row = new FMCG_Workspace_Visibility__c(
                    Profile_Name__c = profileName,
                    Component_Key__c = key
                );
            }
            row.Is_Visible__c = visibleSet.contains(key);
            upserts.add(row);
        }
        upsert upserts;
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    private static String currentUserProfileName() {
        return [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1].Profile.Name;
    }

    private static Map<String, Boolean> resolveVisibility(String profileName) {
        Map<String, Boolean> result = new Map<String, Boolean>();
        List<FMCG_Workspace_Visibility__c> rows = [
            SELECT Component_Key__c, Is_Visible__c
            FROM FMCG_Workspace_Visibility__c
            WHERE Profile_Name__c = :profileName
        ];
        if (rows.isEmpty()) {
            for (String key : allKeys()) result.put(key, true);
            return result;
        }
        Map<String, Boolean> byKey = new Map<String, Boolean>();
        for (FMCG_Workspace_Visibility__c r : rows) byKey.put(r.Component_Key__c, r.Is_Visible__c);
        for (String key : allKeys()) {
            result.put(key, byKey.containsKey(key) ? byKey.get(key) : true);
        }
        return result;
    }
}