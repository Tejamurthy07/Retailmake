/**
 * @description Distributor portal / oversight API (Experience Cloud + internal).
 *
 *              DUAL-MODE access:
 *              - **Portal / community users** are strictly scoped to their own
 *                distributor Account (resolved via Contact.AccountId). They can
 *                never see or write another distributor's records.
 *              - **Internal / admin users** (standard Salesforce users) see ALL
 *                distributors' data (governed by their normal record access), so
 *                staff can oversee every distributor from the same screens.
 *
 *              Runs `without sharing` BY DESIGN: portal row-level isolation is
 *              enforced explicitly in every query (each account-scoped SOQL adds
 *              `AND Account__c = :acctId`, resolved from the portal user's
 *              Contact.AccountId via scopeAccountId/requireAccountId). This means
 *              the portal works WITHOUT sharing sets / sharing rules — a portal
 *              user can only ever read or write their own distributor's records
 *              because the controller is the sole entry point and always filters
 *              by their account. Global catalog data (active products, schemes) is
 *              intentionally visible to all. Gated by the DMS master + portal toggles.
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class DMS_PortalController {

    /** Test hook: set a context account without a community user (forces scoped mode). */
    @TestVisible
    private static Id testAccountIdOverride;

    // ── Context & guards ──────────────────────────────────────────────────

    private static Boolean isInternalUser() {
        return UserInfo.getUserType() == 'Standard';
    }

    /**
     * @description The account to scope to: null = internal/admin (see ALL data);
     *              otherwise the portal user's own Account (scoped). Throws only
     *              when a portal user has no linked distributor account.
     */
    @TestVisible
    private static Id scopeAccountId() {
        if (testAccountIdOverride != null) {
            return testAccountIdOverride;
        }
        if (isInternalUser()) {
            return null; // internal/admin → all distributors
        }
        List<User> users = [
            SELECT Contact.AccountId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
        ];
        Id accountId = (users.isEmpty() || users[0].Contact == null)
            ? null : users[0].Contact.AccountId;
        if (accountId == null) {
            throw new AuraHandledException('No distributor account is linked to this user.');
        }
        return accountId;
    }

    /** For write actions that require a specific distributor context. */
    private static Id requireAccountId() {
        Id a = scopeAccountId();
        if (a == null) {
            throw new AuraHandledException(
                'No distributor context. Create these records from the internal DMS app on behalf of a specific distributor.');
        }
        return a;
    }

    private static void ensureEnabled() {
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
            !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_PORTAL)) {
            throw new AuraHandledException('The distributor portal is not enabled.');
        }
    }

    private static Decimal nz(Decimal v) { return v == null ? 0 : v; }

    // ── Portal configuration (tier-aware + config-driven nav) ──────────────
    @AuraEnabled(cacheable=true)
    public static Boolean isThreeTier() {
        return DMS_Config.isThreeTier();
    }

    public class PortalTab {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
    }
    public class PortalConfig {
        @AuraEnabled public Boolean threeTier = true;
        @AuraEnabled public String tierModel;
        @AuraEnabled public List<PortalTab> tabs = new List<PortalTab>();
    }

    @AuraEnabled(cacheable=true)
    public static PortalConfig getPortalConfig() {
        ensureEnabled();
        PortalConfig cfg = new PortalConfig();
        cfg.threeTier = DMS_Config.isThreeTier();
        cfg.tierModel = DMS_Config.tierModel();

        for (DMS_Portal_Tab__mdt t : [
            SELECT Tab_Key__c, Label__c, Sort_Order__c, Feature_Code__c, Min_Tier__c
            FROM DMS_Portal_Tab__mdt
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            if (String.isNotBlank(t.Feature_Code__c) && !BPM_FeatureToggle_Util.isEnabled(t.Feature_Code__c)) { continue; }
            if (t.Min_Tier__c == 'THREE_TIER' && !cfg.threeTier) { continue; }
            PortalTab pt = new PortalTab();
            pt.key = t.Tab_Key__c;
            pt.label = t.Label__c;
            cfg.tabs.add(pt);
        }
        // Fallback to a sane default set if no tab metadata is configured.
        if (cfg.tabs.isEmpty()) {
            for (List<String> d : new List<List<String>>{
                new List<String>{ 'home', 'Home' }, new List<String>{ 'products', 'Products' },
                new List<String>{ 'orders', 'Orders' }, new List<String>{ 'invoices', 'Invoices' },
                new List<String>{ 'inventory', 'Inventory' }, new List<String>{ 'ledger', 'Ledger' },
                new List<String>{ 'claims', 'Claims' }, new List<String>{ 'customers', 'Customers' },
                new List<String>{ 'support', 'Support' }
            }) {
                PortalTab pt = new PortalTab();
                pt.key = d[0];
                pt.label = d[1];
                cfg.tabs.add(pt);
            }
        }
        return cfg;
    }

    // ── Dashboard ─────────────────────────────────────────────────────────

    public class Dashboard {
        @AuraEnabled public Decimal outstanding;
        @AuraEnabled public Decimal creditLimit;
        @AuraEnabled public Decimal creditAvailable;
        @AuraEnabled public Decimal onHandUnits;
        @AuraEnabled public Integer openIndents;
        @AuraEnabled public Integer nearExpiryBatches;
    }

    @AuraEnabled(cacheable=true)
    public static Dashboard getDashboard() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Dashboard d = new Dashboard();

        if (acctId == null) {
            // Internal/admin: org-wide across all distributors.
            for (AggregateResult ar : [
                SELECT SUM(Outstanding_Balance__c) o, SUM(Credit_Limit__c) c
                FROM Account WHERE Type = 'Distributor'
            ]) {
                d.outstanding = nz((Decimal) ar.get('o'));
                d.creditLimit = nz((Decimal) ar.get('c'));
            }
            for (AggregateResult ar : [
                SELECT SUM(Closing_Stock__c) total FROM Distributor_Stock__c WHERE Is_Current__c = true
            ]) {
                d.onHandUnits = nz((Decimal) ar.get('total'));
            }
            d.openIndents = [
                SELECT COUNT() FROM Primary_Order__c WHERE Status__c IN ('Draft', 'Submitted', 'Approved')
            ];
            d.nearExpiryBatches = [
                SELECT COUNT() FROM Distributor_Stock__c
                WHERE Is_Current__c = true AND Closing_Stock__c > 0
                  AND Expiry_Date__c != null AND Expiry_Date__c <= :nearExpiryCutoff()
            ];
            d.creditAvailable = d.creditLimit - d.outstanding;
            return d;
        }

        // Portal user: scoped to own account.
        Account acct = [SELECT Outstanding_Balance__c, Credit_Limit__c FROM Account WHERE Id = :acctId];
        d.outstanding = nz(acct.Outstanding_Balance__c);
        d.creditLimit = nz(acct.Credit_Limit__c);
        d.creditAvailable = d.creditLimit - d.outstanding;
        for (AggregateResult ar : [
            SELECT SUM(Closing_Stock__c) total FROM Distributor_Stock__c
            WHERE Account__c = :acctId AND Is_Current__c = true
        ]) {
            d.onHandUnits = nz((Decimal) ar.get('total'));
        }
        d.openIndents = [
            SELECT COUNT() FROM Primary_Order__c
            WHERE Account__c = :acctId AND Status__c IN ('Draft', 'Submitted', 'Approved')
        ];
        d.nearExpiryBatches = [
            SELECT COUNT() FROM Distributor_Stock__c
            WHERE Account__c = :acctId AND Is_Current__c = true AND Closing_Stock__c > 0
              AND Expiry_Date__c != null AND Expiry_Date__c <= :nearExpiryCutoff()
        ];
        return d;
    }

    // ── Read screens (account filter applied only for portal users) ────────

    @AuraEnabled(cacheable=true)
    public static List<Distributor_Stock__c> getInventory() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Account__r.Name, Product_Ext__r.Name, Batch_No__c, Closing_Stock__c, Expiry_Date__c '
            + 'FROM Distributor_Stock__c WHERE Is_Current__c = true AND Closing_Stock__c > 0';
        if (acctId != null) { q += ' AND Account__c = :acctId'; }
        q += ' ORDER BY Expiry_Date__c ASC NULLS LAST LIMIT 2000';
        return Database.query(q);
    }

    // ── Inventory summary (on-hand + near-expiry + replenishment) ──────────
    public class InventoryRow {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String brand;
        @AuraEnabled public Decimal onHand = 0;
        // Units already promised to approved-but-unbilled secondary orders. Physical stock does
        // not move until billing, so on-hand alone overstates what is actually sellable.
        @AuraEnabled public Decimal committed = 0;
        @AuraEnabled public Decimal available = 0;
        @AuraEnabled public Integer batches = 0;
        @AuraEnabled public Date nearestExpiry;
        @AuraEnabled public Decimal nearExpiryQty = 0;
        @AuraEnabled public Decimal reorderLevel;
        @AuraEnabled public Decimal suggestedQty = 0;
        @AuraEnabled public Decimal stockValue = 0;
        @AuraEnabled public String status;
        @AuraEnabled public List<BatchRow> batchDetail = new List<BatchRow>();
        // transient (not exposed): max level for suggestion math
        public Decimal maxLevel;
    }
    /** One current batch of a product's on-hand stock, for the FEFO / expiry drill-down. */
    public class BatchRow implements Comparable {
        @AuraEnabled public String batchNo;
        @AuraEnabled public Decimal qty = 0;
        @AuraEnabled public Date expiryDate;
        @AuraEnabled public Boolean nearExpiry = false;
        // FEFO: earliest expiry first; batches with no expiry sort last.
        public Integer compareTo(Object other) {
            Date b = ((BatchRow) other).expiryDate;
            if (this.expiryDate == b) { return 0; }
            if (this.expiryDate == null) { return 1; }
            if (b == null) { return -1; }
            return this.expiryDate < b ? -1 : 1;
        }
    }
    public class InventorySummary {
        @AuraEnabled public Integer skuCount = 0;
        @AuraEnabled public Decimal totalUnits = 0;
        @AuraEnabled public Decimal stockValue = 0;
        @AuraEnabled public Integer nearExpirySkus = 0;
        @AuraEnabled public Integer belowReorderSkus = 0;
        @AuraEnabled public List<InventoryRow> rows = new List<InventoryRow>();
    }

    @AuraEnabled(cacheable=true)
    public static InventorySummary getInventorySummary() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Date nearCut = nearExpiryCutoff();
        InventorySummary s = new InventorySummary();

        String w = 'Is_Current__c = true AND Closing_Stock__c > 0 AND Product_Ext__c != null'
            + (acctId == null ? '' : ' AND Account__c = :acctId');
        Map<Id, InventoryRow> byProduct = new Map<Id, InventoryRow>();
        for (Distributor_Stock__c ds : Database.query(
            'SELECT Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.Brand__c, Product_Ext__r.Unit_Price__c, '
            + 'Batch_No__c, Closing_Stock__c, Expiry_Date__c FROM Distributor_Stock__c WHERE ' + w
            + ' LIMIT 5000')) {
            InventoryRow r = byProduct.get(ds.Product_Ext__c);
            if (r == null) {
                r = new InventoryRow();
                r.productId = ds.Product_Ext__c;
                r.name = ds.Product_Ext__r.Name;
                r.brand = ds.Product_Ext__r.Brand__c;
                byProduct.put(ds.Product_Ext__c, r);
            }
            Decimal qty = nz(ds.Closing_Stock__c);
            r.onHand += qty;
            r.batches += 1;
            r.stockValue += qty * nz(ds.Product_Ext__r.Unit_Price__c);
            if (ds.Expiry_Date__c != null && (r.nearestExpiry == null || ds.Expiry_Date__c < r.nearestExpiry)) {
                r.nearestExpiry = ds.Expiry_Date__c;
            }
            Boolean isNear = ds.Expiry_Date__c != null && ds.Expiry_Date__c <= nearCut;
            if (isNear) {
                r.nearExpiryQty += qty;
            }
            BatchRow br = new BatchRow();
            br.batchNo = ds.Batch_No__c;
            br.qty = qty;
            br.expiryDate = ds.Expiry_Date__c;
            br.nearExpiry = isNear;
            r.batchDetail.add(br);
        }

        // Norm-based reorder levels + suggested order quantity (distributor context).
        if (acctId != null && !byProduct.isEmpty()) {
            for (Distributor_Stock_Norm__c n : [
                SELECT Product_Ext__c, Reorder_Level__c, Max_Stock_Level__c
                FROM Distributor_Stock_Norm__c
                WHERE Account__c = :acctId AND Product_Ext__c IN :byProduct.keySet() AND Is_Active__c = true
            ]) {
                InventoryRow r = byProduct.get(n.Product_Ext__c);
                if (r != null) {
                    r.reorderLevel = n.Reorder_Level__c;
                    r.maxLevel = n.Max_Stock_Level__c;
                }
            }
        }

        // Demand already committed by approved-but-unbilled orders this distributor has to serve.
        // Billing is what moves the stock, so until then these units are spoken for even though
        // they still show as on-hand — without this the distributor cannot see that a product is
        // effectively sold out and keeps promising it.
        if (acctId != null && !byProduct.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Product_Ext__c pid, SUM(Quantity__c) qty
                FROM Order_Line_Item__c
                WHERE Product_Ext__c IN :byProduct.keySet()
                  AND Sales_Order__r.Sold_From_Distributor__c = :acctId
                  AND Sales_Order__r.Invoice__c = null
                  AND Sales_Order__r.Status__c IN ('Submitted', 'Approved')
                GROUP BY Product_Ext__c
            ]) {
                InventoryRow r = byProduct.get((Id) ar.get('pid'));
                if (r != null) { r.committed = nz((Decimal) ar.get('qty')); }
            }
        }

        for (InventoryRow r : byProduct.values()) {
            r.available = r.onHand - r.committed;
            if (r.available < 0) { r.available = 0; }
            if (r.onHand <= 0) {
                r.status = 'Out';
            } else if (r.committed > 0 && r.available <= 0) {
                // Physically present but every unit is already promised.
                r.status = 'Committed';
            } else if (r.reorderLevel != null && r.onHand <= r.reorderLevel) {
                r.status = 'Reorder';
            } else if (r.onHand < DMS_Config.lowStockThreshold()) {
                r.status = 'Low';
            } else {
                r.status = 'In Stock';
            }
            if (r.reorderLevel != null && r.onHand <= r.reorderLevel && r.maxLevel != null && r.maxLevel > r.onHand) {
                r.suggestedQty = r.maxLevel - r.onHand;
            }
            r.batchDetail.sort(); // FEFO: earliest-expiry batch first
            s.totalUnits += r.onHand;
            s.stockValue += r.stockValue;
            if (r.nearExpiryQty > 0) { s.nearExpirySkus++; }
            if (r.status == 'Reorder' || r.status == 'Out') { s.belowReorderSkus++; }
            s.rows.add(r);
        }
        s.skuCount = s.rows.size();
        return s;
    }

    // ── Customers (downline retailers) ─────────────────────────────────────
    public class CustomerRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String city;
        @AuraEnabled public String outletType;
        @AuraEnabled public String custType;      // 'Retailer' | 'Sub-Distributor'
        @AuraEnabled public Decimal creditLimit;
        @AuraEnabled public Decimal outstanding;
        @AuraEnabled public Boolean active = false;
    }

    @AuraEnabled(cacheable=true)
    public static List<CustomerRow> getCustomers() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String otSecondary = DMS_Constants.ORDER_TYPE_SECONDARY;

        // Customers that have transacted (secondary invoices) -> "active".
        Set<Id> activeIds = new Set<Id>();
        for (AggregateResult ar : Database.query(
            'SELECT Account__c a FROM Invoice__c WHERE Order_Type__c = :otSecondary'
            + (acctId == null ? '' : ' AND Sold_From_Distributor__c = :acctId')
            + ' GROUP BY Account__c')) {
            activeIds.add((Id) ar.get('a'));
        }

        // Every account this distributor has billed on ANY invoice — the real
        // downline, regardless of order-type value or a missing ParentId link.
        Set<Id> billedIds = new Set<Id>();
        if (acctId != null) {
            for (AggregateResult ar : [
                SELECT Account__c a FROM Invoice__c
                WHERE Sold_From_Distributor__c = :acctId AND Account__c != null
                GROUP BY Account__c
            ]) {
                billedIds.add((Id) ar.get('a'));
            }
        }

        String cols = 'SELECT Id, Name, BillingCity, Outlet_Type__c, Credit_Limit__c, '
            + 'Outstanding_Balance__c, RecordType.DeveloperName FROM Account WHERE ';
        List<Account> accts;
        if (acctId == null) {
            // Internal/admin: all downline-type accounts.
            accts = Database.query(cols
                + 'RecordType.DeveloperName IN (\'Retailer\', \'Modern_Trade\', \'Distributor\', \'Super_Stockist\') '
                + 'ORDER BY Name LIMIT 2000');
        } else {
            // A distributor's customers = the union of:
            //   1) accounts whose Parent Account is this distributor, and
            //   2) accounts this distributor has already billed on a secondary
            //      invoice (Sold_From_Distributor__c) — the real "downline" even
            //      when the ParentId link was never set.
            Set<Id> custIds = new Set<Id>(billedIds);
            for (Account c : Database.query('SELECT Id FROM Account WHERE ParentId = :acctId LIMIT 2000')) {
                custIds.add(c.Id);
            }
            // No territory fallback. Territory is geographic and shared by competing
            // distributors, so falling back to it showed a distributor another
            // distributor's retailers — including their credit limits and outstanding
            // balances. An unlinked distributor now correctly sees nothing.
            accts = custIds.isEmpty()
                ? new List<Account>()
                : Database.query(cols + 'Id IN :custIds ORDER BY Name LIMIT 2000');
        }

        List<CustomerRow> rows = new List<CustomerRow>();
        for (Account a : accts) {
            CustomerRow r = new CustomerRow();
            r.id = a.Id;
            r.name = a.Name;
            r.city = a.BillingCity;
            r.outletType = a.Outlet_Type__c;
            String rt = a.RecordType.DeveloperName;
            r.custType = (rt == DMS_Constants.RT_DISTRIBUTOR || rt == DMS_Constants.RT_SUPER_STOCKIST)
                ? 'Sub-Distributor' : 'Retailer';
            r.creditLimit = a.Credit_Limit__c;
            r.outstanding = a.Outstanding_Balance__c;
            r.active = activeIds.contains(a.Id);
            rows.add(r);
        }
        return rows;
    }

    /**
     * @description One-click replenishment: creates a draft P1 indent for every
     *              product currently at/below its reorder level, using the
     *              norm-based suggested quantity (top up to max stock level).
     * @return The created Primary_Order__c id.
     */
    @AuraEnabled
    public static Id placeReplenishmentIndent() {
        ensureEnabled();
        requireAccountId();
        InventorySummary s = getInventorySummary();
        List<IndentLineInput> lines = new List<IndentLineInput>();
        for (InventoryRow r : s.rows) {
            if (r.suggestedQty != null && r.suggestedQty > 0) {
                IndentLineInput li = new IndentLineInput();
                li.productId = String.valueOf(r.productId);
                li.quantity = r.suggestedQty;
                lines.add(li);
            }
        }
        if (lines.isEmpty()) {
            throw new AuraHandledException('Nothing to replenish — no products are at or below their reorder level.');
        }
        return createIndent(lines);
    }

    // ── Distributor stock adjustment (portal-scoped) ───────────────────────
    private static final Set<String> ADJ_TYPES = new Set<String>{
        'Physical_Count', 'Damage', 'Expiry_Write_Off', 'Correction_Add', 'Correction_Deduct'
    };

    // ── Demo tooling (gated, ships OFF) ────────────────────────────────────

    /** What the UI needs to know before offering a demo helper. */
    public class DemoContext {
        @AuraEnabled public Boolean enabled = false;
        /** True when the running user has no distributor of their own and must pick one. */
        @AuraEnabled public Boolean needsDistributor = false;
        @AuraEnabled public List<Map<String, String>> distributors = new List<Map<String, String>>();
    }

    /**
     * Drives whether the UI offers a demo helper, and whether it must ask which
     * distributor to act as.
     *
     * These components are exposed on lightning__AppPage as well as community
     * pages, so an internal user sees them with no distributor context at all —
     * scopeAccountId() returns null for them by design, and every write action
     * throws "No distributor context". A demo button that silently assumed a
     * portal user therefore did nothing when clicked from the internal app.
     */
    @AuraEnabled(cacheable=true)
    public static DemoContext getDemoContext() {
        DemoContext ctx = new DemoContext();
        ctx.enabled = BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_DEMO_TOOLS);
        if (!ctx.enabled) { return ctx; }

        Id acctId;
        try {
            acctId = scopeAccountId();
        } catch (Exception e) {
            // A portal user with no linked account — nothing sensible to offer.
            ctx.enabled = false;
            return ctx;
        }
        if (acctId != null) {
            // A distributor portal user cannot generate a dispatch, and should not
            // be able to. Dispatching is the company's half of the transaction:
            // it approves the order, raises the primary invoice and deducts
            // warehouse stock. The portal profile grants Primary_Order__c create
            // but NOT edit, no create on Invoice__c, and no access to Warehouse__c
            // at all — so the attempt died on a cross-reference access check.
            // Offering the button here and letting it fail was the wrong answer, so
            // it is simply withheld. The distributor's own flow is unaffected: they
            // receive the dispatch as a GRN once the company raises it.
            ctx.enabled = false;
            return ctx;
        }

        ctx.needsDistributor = true;
        for (Account a : [
            SELECT Id, Name FROM Account
            WHERE RecordType.DeveloperName IN ('Distributor', 'Super_Stockist')
            ORDER BY Name LIMIT 200
        ]) {
            ctx.distributors.add(new Map<String, String>{
                'label' => a.Name, 'value' => a.Id
            });
        }
        return ctx;
    }

    /**
     * Raises and dispatches a mock primary order so a GRN can be practised.
     *
     * Deliberately goes through the REAL path — insert the order, approve it, let
     * Primary_Order_Trigger hand off to DMS_PrimaryOrderFulfillment_Service —
     * rather than hand-crafting an Invoice__c. Records fabricated by a shortcut
     * tend to be subtly wrong (no GST split, no warehouse deduction, invoice lines
     * with no product) and then behave differently from real ones, which is
     * exactly the class of demo data that has already made the GRN screen look
     * broken here.
     *
     * Gated on TOGGLE_DEMO_TOOLS, which ships disabled. A distributor able to
     * raise their own inbound dispatch could otherwise create stock from nothing.
     *
     * @param distributorId only honoured for internal users; portal users are
     *                      always pinned to their own account.
     * @return A short summary for the toast.
     */
    @AuraEnabled
    public static String createMockDispatch(Id distributorId) {
        ensureEnabled();
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_DEMO_TOOLS)) {
            throw new AuraHandledException(
                'Demo tools are disabled. Enable the DMS-015 feature toggle to use this.');
        }

        // A portal user can only ever act as themselves; the parameter exists so an
        // internal admin can drive the same helper while previewing.
        Id acctId = scopeAccountId();
        if (acctId == null) { acctId = distributorId; }
        if (acctId == null) {
            throw new AuraHandledException(
                'Choose which distributor to dispatch to. You are signed in as an internal '
                + 'user, so there is no distributor context to infer.');
        }

        // Source warehouse: reuse whichever the distributor was last served from,
        // so the mock dispatch looks like their real supply chain.
        Id warehouseId;
        for (Primary_Order__c prev : [
            SELECT Warehouse__c FROM Primary_Order__c
            WHERE Account__c = :acctId AND Warehouse__c != null
            ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            warehouseId = prev.Warehouse__c;
        }
        if (warehouseId == null) {
            for (Warehouse_Stock__c ws : [
                SELECT Warehouse__c FROM Warehouse_Stock__c
                WHERE Qty_On_Hand__c > 0 LIMIT 1
            ]) {
                warehouseId = ws.Warehouse__c;
            }
        }
        if (warehouseId == null) {
            throw new AuraHandledException('No warehouse with stock is available to dispatch from.');
        }

        // Only products the warehouse can actually ship — otherwise fulfilment
        // short-ships and the GRN is meaningless.
        final Decimal MOCK_QTY = 10;
        List<Warehouse_Stock__c> supply = [
            SELECT Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.Unit_Price__c
            FROM Warehouse_Stock__c
            WHERE Warehouse__c = :warehouseId
              AND Product_Ext__c != null
              AND Qty_On_Hand__c >= :MOCK_QTY
              AND (Expiry_Date__c = null OR Expiry_Date__c > TODAY)
            ORDER BY Product_Ext__r.Name
            LIMIT 4
        ];
        if (supply.isEmpty()) {
            throw new AuraHandledException(
                'That warehouse has no product with at least ' + MOCK_QTY + ' units to dispatch.');
        }

        Primary_Order__c po = new Primary_Order__c(
            Account__c    = acctId,
            Warehouse__c  = warehouseId,
            Order_Date__c = Date.today(),
            Order_Type__c = 'Regular',
            Status__c     = 'Submitted',
            Notes__c      = 'Mock dispatch generated from the GRN screen (demo tools).'
        );
        insert po;

        List<Primary_Order_Line__c> lines = new List<Primary_Order_Line__c>();
        Decimal headerTotal = 0;
        for (Warehouse_Stock__c ws : supply) {
            Decimal price = nz(ws.Product_Ext__r.Unit_Price__c);
            if (price <= 0) { price = 100; }
            headerTotal += MOCK_QTY * price;
            lines.add(new Primary_Order_Line__c(
                Primary_Order__c = po.Id,
                Product_Ext__c   = ws.Product_Ext__c,
                Quantity__c      = MOCK_QTY,
                Unit_Price__c    = price
            ));
        }
        insert lines;

        // Stamp the header total from the lines. Credit enforcement reads this
        // field in preference to summing the lines, so leaving it stale would let
        // the order slip past the distributor's credit limit.
        update new Primary_Order__c(Id = po.Id, Total_Amount__c = headerTotal);

        // Approving is what triggers fulfilment: primary invoice + warehouse deduction.
        try {
            update new Primary_Order__c(Id = po.Id, Status__c = DMS_Constants.INDENT_APPROVED);
        } catch (DmlException e) {
            String msg = e.getDmlMessage(0);
            throw new AuraHandledException(
                'Could not dispatch the mock order: ' + (String.isBlank(msg) ? e.getMessage() : msg));
        }

        Primary_Order__c done = [
            SELECT Name, Status__c, Invoice__c, Invoice__r.Invoice_Number__c
            FROM Primary_Order__c WHERE Id = :po.Id
        ];
        if (done.Invoice__c == null) {
            return 'Order ' + done.Name + ' was approved but produced no dispatch invoice — '
                 + 'check that primary fulfilment (DMS-003) is enabled.';
        }
        return 'Dispatched ' + done.Invoice__r.Invoice_Number__c + ' with ' + lines.size()
             + ' product(s). It is now waiting in Awaiting GRN.';
    }

    /** One selectable catalogue product for the stock-adjustment picker. */
    public class ProductOption {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String code;
        @AuraEnabled public Decimal onHand = 0;
    }

    /**
     * Products a distributor can adjust stock for — the whole sellable catalogue,
     * NOT just what they already hold.
     *
     * The adjustment form used to build its picker from the inventory rows, which
     * only contain products with Closing_Stock__c > 0. That made it impossible to
     * enter opening stock for a SKU the distributor had never carried: the product
     * could not appear in the list until it already had stock, and it could not get
     * stock without being in the list. With a 96-product catalogue and 2 SKUs on
     * hand, the picker offered 2 items.
     *
     * @param searchTerm optional filter on name or SKU code; blank returns the first page.
     */
    @AuraEnabled(cacheable=true)
    public static List<ProductOption> getAdjustableProducts(String searchTerm) {
        ensureEnabled();
        Id acctId = scopeAccountId();

        // What the distributor currently holds, so the picker can show it inline.
        Map<Id, Decimal> onHandByProduct = new Map<Id, Decimal>();
        if (acctId != null) {
            for (AggregateResult ar : [
                SELECT Product_Ext__c pid, SUM(Closing_Stock__c) qty
                FROM Distributor_Stock__c
                WHERE Account__c = :acctId AND Is_Current__c = true AND Product_Ext__c != null
                GROUP BY Product_Ext__c
            ]) {
                onHandByProduct.put((Id) ar.get('pid'), nz((Decimal) ar.get('qty')));
            }
        }

        String term = String.isBlank(searchTerm)
            ? null : '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';

        List<Product_Extension__c> prods = (term == null)
            ? [SELECT Id, Name, SKU_Code__c FROM Product_Extension__c ORDER BY Name LIMIT 200]
            : [SELECT Id, Name, SKU_Code__c FROM Product_Extension__c
               WHERE Name LIKE :term OR SKU_Code__c LIKE :term
               ORDER BY Name LIMIT 200];

        List<ProductOption> out = new List<ProductOption>();
        for (Product_Extension__c p : prods) {
            ProductOption o = new ProductOption();
            o.productId = p.Id;
            o.name = p.Name;
            o.code = p.SKU_Code__c;
            o.onHand = onHandByProduct.containsKey(p.Id) ? onHandByProduct.get(p.Id) : 0;
            out.add(o);
        }
        return out;
    }

    /**
     * @description Records a stock adjustment against the distributor's OWN on-hand and applies it
     *              immediately. Creates the Stock_Adjustment as Distributor-located, scoped to the
     *              portal user's account, then moves it Draft -> Approved so the DMS adjustment
     *              trigger writes the new stock snapshot + the movement-ledger entry. There is no
     *              separate approval screen in the portal, so a plain Draft would never move stock.
     *
     *              `quantity` meaning depends on `adjustmentType`:
     *                - Physical_Count -> the counted quantity; delta = counted - system on-hand
     *                - Correction_Add -> units to add (delta = +quantity)
     *                - Damage / Expiry_Write_Off / Correction_Deduct -> units to remove (delta = -quantity)
     * @return The created Stock_Adjustment__c id.
     */
    @AuraEnabled
    public static Id saveDistributorAdjustment(
        Id productId, String batchNumber, String adjustmentType, Decimal quantity, String reason
    ) {
        ensureEnabled();
        Id acctId = requireAccountId();

        // Applying an adjustment needs the DMS stock engine; without it the record would be approved
        // but move no stock (silent no-op). Fail clearly instead of pretending it worked.
        if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_STOCK_ACTIVITIES)) {
            throw new AuraHandledException('Stock activities are not enabled for your organisation.');
        }
        if (productId == null) {
            throw new AuraHandledException('Please choose a product.');
        }
        if (!ADJ_TYPES.contains(adjustmentType)) {
            throw new AuraHandledException('Please choose a valid adjustment type.');
        }
        if (String.isBlank(reason)) {
            throw new AuraHandledException('A reason is required for every adjustment.');
        }
        Decimal qty = nz(quantity);
        if (qty < 0) {
            throw new AuraHandledException('Quantity cannot be negative.');
        }

        Decimal systemQty = currentClosing(acctId, productId, batchNumber);

        Decimal delta;
        Decimal countedQty = null;
        if (adjustmentType == 'Physical_Count') {
            countedQty = qty;
            delta = qty - systemQty;
        } else if (adjustmentType == 'Correction_Add') {
            delta = qty;
        } else {
            delta = -qty; // Damage, Expiry_Write_Off, Correction_Deduct
        }

        if (delta == 0) {
            throw new AuraHandledException('This adjustment does not change the on-hand quantity.');
        }
        if (delta < 0 && (systemQty + delta) < 0) {
            throw new AuraHandledException(
                'Cannot remove ' + String.valueOf(qty) + ' — only ' + String.valueOf(systemQty)
                + ' on hand for this product/batch.');
        }

        Stock_Adjustment__c adj = new Stock_Adjustment__c(
            Location_Type__c   = DMS_Constants.LOCATION_DISTRIBUTOR,
            Account__c         = acctId,
            Product_Ext__c     = productId,
            Batch_Number__c    = String.isBlank(batchNumber) ? null : batchNumber,
            Adjustment_Type__c = adjustmentType,
            System_Qty__c      = systemQty,
            Actual_Qty__c      = countedQty,
            Adjustment_Qty__c  = delta,
            Reason__c          = reason,
            Adjustment_Date__c = Date.today(),
            Status__c          = 'Draft'
        );
        insert adj;
        update new Stock_Adjustment__c(Id = adj.Id, Status__c = DMS_Constants.ADJ_APPROVED);
        return adj.Id;
    }

    /** Current closing stock for one account|product|batch (0 if no current snapshot). */
    private static Decimal currentClosing(Id acctId, Id productId, String batch) {
        String w = 'Account__c = :acctId AND Product_Ext__c = :productId AND Is_Current__c = true';
        w += String.isBlank(batch) ? ' AND Batch_No__c = null' : ' AND Batch_No__c = :batch';
        List<Distributor_Stock__c> rows = Database.query(
            'SELECT Closing_Stock__c FROM Distributor_Stock__c WHERE ' + w + ' LIMIT 1');
        return rows.isEmpty() ? 0 : nz(rows[0].Closing_Stock__c);
    }

    // ── Stock movement history (distributor stock ledger) ──────────────────
    public class MovementRow {
        @AuraEnabled public Datetime txnDate;
        @AuraEnabled public String txnType;
        @AuraEnabled public String direction;   // In | Out
        @AuraEnabled public String product;
        @AuraEnabled public String batch;
        @AuraEnabled public Decimal quantity = 0;
        @AuraEnabled public String reference;    // GRN | Invoice | Return_Order | Stock_Adjustment
    }

    /**
     * @description The distributor's own stock ledger: every movement into or out of their on-hand —
     *              GRN receipts (In), secondary sales (Out), returns, and adjustments — newest first.
     *              Scoped to the portal user's account; warehouse-only transactions (which carry a
     *              Warehouse, not an Account) are naturally excluded.
     */
    @AuraEnabled(cacheable=true)
    public static List<MovementRow> getStockMovements(Integer rowLimit) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Integer lim = (rowLimit == null || rowLimit <= 0 || rowLimit > 500) ? 100 : rowLimit;

        String q = 'SELECT Transaction_Date__c, Transaction_Type__c, Direction__c, Product_Ext__r.Name, '
            + 'Batch_Number__c, Quantity__c, Reference_Type__c, CreatedDate '
            + 'FROM Stock_Transaction__c WHERE Product_Ext__c != null';
        // Portal: only this distributor. Internal/admin: all distributor movements (never warehouse).
        q += acctId != null ? ' AND Account__c = :acctId' : ' AND Account__c != null';
        q += ' ORDER BY Transaction_Date__c DESC NULLS LAST, CreatedDate DESC LIMIT ' + lim;

        List<MovementRow> rows = new List<MovementRow>();
        for (Stock_Transaction__c t : Database.query(q)) {
            MovementRow m = new MovementRow();
            m.txnDate = t.Transaction_Date__c != null ? t.Transaction_Date__c : t.CreatedDate;
            m.txnType = t.Transaction_Type__c;
            m.direction = t.Direction__c;
            m.product = t.Product_Ext__r != null ? t.Product_Ext__r.Name : '';
            m.batch = t.Batch_Number__c;
            m.quantity = nz(t.Quantity__c);
            m.reference = t.Reference_Type__c;
            rows.add(m);
        }
        return rows;
    }

    /**
     * Submit one of the distributor's own DRAFT primary orders (Draft -> Submitted).
     *
     * The nightly replenishment scheduler materialises its suggestions as DRAFT
     * Primary_Order__c records, but nothing could ever act on them: no portal action moved an
     * order out of Draft, so a suggested replenishment was visible and permanently inert.
     * This is the review-and-send step that makes those suggestions actionable.
     */
    @AuraEnabled
    public static void submitOrder(Id orderId) {
        ensureEnabled();
        Id acctId = scopeAccountId();

        String w = 'Id = :orderId' + (acctId == null ? '' : ' AND Account__c = :acctId');
        List<Primary_Order__c> orders = Database.query(
            'SELECT Id, Status__c FROM Primary_Order__c WHERE ' + w + ' LIMIT 1');
        if (orders.isEmpty()) {
            throw new AuraHandledException('Order not found.');
        }
        if (orders[0].Status__c != DMS_Constants.INDENT_DRAFT) {
            throw new AuraHandledException(
                'Only a draft order can be submitted. This order is ' + orders[0].Status__c + '.');
        }
        update new Primary_Order__c(Id = orders[0].Id, Status__c = DMS_Constants.INDENT_SUBMITTED);
    }

    // (Removed getIndents(): it read the legacy Indent__c object, which nothing writes any more —
    // the live primary-order path is Primary_Order__c — and no LWC called it. Primary_Order__c is
    // the single source of truth for primary orders.)

    // ── Tier orders (P1 primary orders / P2 + Secondary invoices) ─────────
    public class OrderRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public Date orderDate;
        @AuraEnabled public String party;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal balance;
        @AuraEnabled public String status;
    }

    @AuraEnabled(cacheable=true)
    public static List<OrderRow> getTierOrders(String tier) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        List<OrderRow> rows = new List<OrderRow>();

        if (tier == 'P1') {
            String q = 'SELECT Id, Name, Order_Date__c, Status__c, Total_Amount__c, Warehouse__r.Name '
                + 'FROM Primary_Order__c'
                + (acctId == null ? '' : ' WHERE Account__c = :acctId')
                + ' ORDER BY Order_Date__c DESC LIMIT 2000';
            for (Primary_Order__c i : Database.query(q)) {
                OrderRow r = new OrderRow();
                r.id = i.Id;
                r.orderNumber = i.Name;
                r.orderDate = i.Order_Date__c;
                r.party = i.Warehouse__r != null ? i.Warehouse__r.Name : 'Company';
                r.amount = i.Total_Amount__c;
                r.status = i.Status__c;
                rows.add(r);
            }
        } else {
            String ot = (tier == 'P2') ? DMS_Constants.ORDER_TYPE_P2 : DMS_Constants.ORDER_TYPE_SECONDARY;
            String scope = (acctId == null) ? '' :
                (tier == 'P2'
                    ? ' AND (Account__c = :acctId OR Sold_From_Distributor__c = :acctId)'
                    : ' AND (Sold_From_Distributor__c = :acctId OR Account__c = :acctId)');
            String q = 'SELECT Id, Invoice_Number__c, Invoice_Date__c, Account__r.Name, Total_Amount__c, '
                + 'Balance_Due__c, Status__c FROM Invoice__c WHERE Order_Type__c = :ot' + scope
                + ' ORDER BY Invoice_Date__c DESC LIMIT 2000';
            for (Invoice__c inv : Database.query(q)) {
                OrderRow r = new OrderRow();
                r.id = inv.Id;
                r.orderNumber = inv.Invoice_Number__c;
                r.orderDate = inv.Invoice_Date__c;
                r.party = inv.Account__r != null ? inv.Account__r.Name : '';
                r.amount = inv.Total_Amount__c;
                r.balance = inv.Balance_Due__c;
                r.status = inv.Status__c;
                rows.add(r);
            }
        }
        return rows;
    }

    // ── Secondary orders (Sales_Order__c from SFA Visit Manager) ──────────
    // The distributor VIEWS the retailer sales orders booked by field reps; it
    // does not create them. Scoped to retailers parented to this distributor.
    public class SalesOrderRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String retailer;
        @AuraEnabled public Date orderDate;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal total;
        @AuraEnabled public Decimal items;
        @AuraEnabled public Boolean invoiced = false;
        /** Booked in the field, supplied from this distributor's stock, not yet billed by them. */
        @AuraEnabled public Boolean awaitingBilling = false;
    }

    @AuraEnabled(cacheable=true)
    public static List<SalesOrderRow> getSecondaryOrders() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        // Orders the field team booked at this distributor's retailers. Sold_From_Distributor__c
        // is stamped by the SFA->DMS bridge when the order is created; the ParentId arm keeps
        // orders raised before the bridge (unstamped) visible.
        String q = 'SELECT Id, Name, Account__r.Name, Order_Date__c, Status__c, '
            + 'Total_Net_Amount__c, Total_Amount__c, Total_Items__c, Invoice__c FROM Sales_Order__c';
        if (acctId != null) {
            q += ' WHERE (Sold_From_Distributor__c = :acctId OR Account__r.ParentId = :acctId)';
        }
        q += ' ORDER BY Order_Date__c DESC LIMIT 2000';

        List<SalesOrderRow> rows = new List<SalesOrderRow>();
        for (Sales_Order__c so : Database.query(q)) {
            SalesOrderRow r = new SalesOrderRow();
            r.id = so.Id;
            r.name = so.Name;
            r.retailer = so.Account__r != null ? so.Account__r.Name : '';
            r.orderDate = so.Order_Date__c;
            r.status = so.Status__c;
            r.total = (so.Total_Net_Amount__c != null) ? so.Total_Net_Amount__c : nz(so.Total_Amount__c);
            r.items = nz(so.Total_Items__c);
            // Awaiting the distributor's invoice: approved in the field, not yet billed.
            r.awaitingBilling = (so.Invoice__c == null)
                && so.Status__c != 'Cancelled' && so.Status__c != 'Rejected' && so.Status__c != 'Draft';
            rows.add(r);
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static List<Order_Line_Item__c> getSalesOrderLines(Id salesOrderId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        // Confirm the sales order belongs to one of the distributor's retailers.
        String w = 'Id = :salesOrderId'
            + (acctId == null ? '' : ' AND Account__r.ParentId = :acctId');
        List<Sales_Order__c> so = Database.query('SELECT Id FROM Sales_Order__c WHERE ' + w + ' LIMIT 1');
        if (so.isEmpty()) { return new List<Order_Line_Item__c>(); }
        return [
            SELECT Id, Product_Ext__r.Name, Quantity__c, Free_Quantity__c, Unit_Price__c,
                   Net_Amount__c, Line_Amount__c
            FROM Order_Line_Item__c WHERE Sales_Order__c = :salesOrderId ORDER BY Name
        ];
    }

    // ── Secondary invoicing from Sales Orders ─────────────────────────────
    public class SalesOrderLineInfo {
        @AuraEnabled public String productId;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal qty;
        @AuraEnabled public Decimal rate;
    }
    public class SalesOrderOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Date orderDate;
        @AuraEnabled public Integer productCount = 0;
        @AuraEnabled public String productsLabel;
        @AuraEnabled public Decimal amount = 0;
        @AuraEnabled public List<SalesOrderLineInfo> lines = new List<SalesOrderLineInfo>();
    }

    /**
     * Is this retailer served by the given distributor? The Parent Account is the
     * AUTHORITATIVE link; prior billing is kept because it is a fact (we invoiced them).
     *
     * The territory match was removed: a Territory_Master__c is purely geographic and has
     * no distributor field, so competing distributors share one. Matching on it let a
     * distributor read — and bill — retailers they do not serve.
     */
    private static Boolean isMyCustomer(Id acctId, Id customerId) {
        if (acctId == null || customerId == null) { return false; }
        if ([SELECT COUNT() FROM Account WHERE Id = :customerId AND ParentId = :acctId] > 0) { return true; }
        return [SELECT COUNT() FROM Invoice__c
                WHERE Sold_From_Distributor__c = :acctId AND Account__c = :customerId] > 0;
    }

    /**
     * True only when every one of these sales orders belongs to a retailer this
     * distributor serves. buildQuote does not scope by account, so callers must gate
     * on this before exposing or billing order lines.
     */
    private static Boolean ownsSalesOrders(Id acctId, Set<Id> soIds) {
        if (acctId == null || soIds == null || soIds.isEmpty()) { return false; }
        Set<Id> retailerIds = new Set<Id>();
        for (Sales_Order__c so : [SELECT Account__c FROM Sales_Order__c WHERE Id IN :soIds]) {
            if (so.Account__c != null) { retailerIds.add(so.Account__c); }
        }
        if (retailerIds.isEmpty()) { return false; }
        Set<Id> mine = new Set<Id>();
        for (Account a : [SELECT Id FROM Account WHERE Id IN :retailerIds AND ParentId = :acctId]) {
            mine.add(a.Id);
        }
        for (AggregateResult ar : [
            SELECT Account__c a FROM Invoice__c
            WHERE Sold_From_Distributor__c = :acctId AND Account__c IN :retailerIds
            GROUP BY Account__c
        ]) {
            mine.add((Id) ar.get('a'));
        }
        return mine.containsAll(retailerIds);
    }

    /**
     * Open (not-yet-invoiced) sales orders for a retailer, so a distributor can
     * bill them. Scoped to the distributor's own customers.
     */
    @AuraEnabled(cacheable=true)
    public static List<SalesOrderOption> getOpenSalesOrders(Id customerId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        List<SalesOrderOption> out = new List<SalesOrderOption>();
        if (customerId == null) { return out; }
        if (acctId != null && !isMyCustomer(acctId, customerId)) { return out; }

        for (Sales_Order__c so : [
            SELECT Id, Name, Order_Date__c, Total_Net_Amount__c, Total_Amount__c,
                   (SELECT Product_Ext__c, Product_Ext__r.Name, Quantity__c, Unit_Price__c
                    FROM Order_Line_Items__r ORDER BY Name)
            FROM Sales_Order__c
            WHERE Account__c = :customerId AND Invoice__c = null
              AND Status__c NOT IN ('Cancelled', 'Rejected')
              AND (Sold_From_Distributor__c = :acctId OR Sold_From_Distributor__c = null)
            ORDER BY Order_Date__c DESC LIMIT 200
        ]) {
            SalesOrderOption o = new SalesOrderOption();
            o.id = so.Id;
            o.name = so.Name;
            o.orderDate = so.Order_Date__c;
            o.amount = (so.Total_Net_Amount__c != null) ? so.Total_Net_Amount__c : nz(so.Total_Amount__c);
            List<String> names = new List<String>();
            for (Order_Line_Item__c li : so.Order_Line_Items__r) {
                if (li.Product_Ext__c == null || nz(li.Quantity__c) <= 0) { continue; }
                SalesOrderLineInfo info = new SalesOrderLineInfo();
                info.productId = li.Product_Ext__c;
                info.productName = li.Product_Ext__r != null ? li.Product_Ext__r.Name : '';
                info.qty = li.Quantity__c;
                info.rate = nz(li.Unit_Price__c);
                o.lines.add(info);
                names.add(info.productName);
            }
            o.productCount = o.lines.size();
            o.productsLabel = String.join(names, ', ');
            if (!o.lines.isEmpty()) { out.add(o); }
        }
        return out;
    }

    // Invoice preview shown in the wizard — computed by the SAME code that
    // creates the invoice, so the numbers are identical.
    public class InvoiceQuoteLine {
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal ordered;
        @AuraEnabled public Decimal qty;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal discount;
        @AuraEnabled public Decimal taxRate;
        @AuraEnabled public Decimal tax;
        @AuraEnabled public Decimal freeQty;
        @AuraEnabled public Decimal gross;
        @AuraEnabled public Decimal net;
    }
    public class InvoiceQuote {
        @AuraEnabled public List<InvoiceQuoteLine> lines = new List<InvoiceQuoteLine>();
        @AuraEnabled public Decimal subtotal = 0;
        @AuraEnabled public Decimal discount = 0;
        @AuraEnabled public Decimal tax = 0;
        @AuraEnabled public Decimal net = 0;
        @AuraEnabled public Decimal freeTotal = 0;
        @AuraEnabled public Integer itemCount = 0;
    }

    private static Set<Id> parseIdSet(String idsJson) {
        Set<Id> ids = new Set<Id>();
        if (String.isBlank(idsJson)) { return ids; }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(idsJson)) {
                if (o != null) { ids.add(Id.valueOf(String.valueOf(o))); }
            }
        } catch (Exception ignored) { /* malformed */ }
        return ids;
    }

    /**
     * Build the faithful quote from the selected sales-order lines. The invoice
     * reproduces each order line's commercial terms (unit price, discount,
     * scheme discount, GST split, free goods); when the billed quantity is less
     * than the ordered quantity the line's amounts are prorated.
     */
    private static List<DMS_SecondaryBilling_Service.QuoteLine> buildQuote(
        Set<Id> soIds, Map<Id, Decimal> billedByProduct
    ) {
        List<DMS_SecondaryBilling_Service.QuoteLine> out =
            new List<DMS_SecondaryBilling_Service.QuoteLine>();
        if (soIds.isEmpty()) { return out; }

        // Remaining quantity to bill per product (defaults to nothing unless requested).
        Map<Id, Decimal> remaining = new Map<Id, Decimal>();
        for (Id pid : billedByProduct.keySet()) { remaining.put(pid, nz(billedByProduct.get(pid))); }

        for (Order_Line_Item__c oli : [
            SELECT Id, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.HSN_SAC_Code__c,
                   Quantity__c, Unit_Price__c, Discount_Amount__c, Scheme_Discount__c,
                   Tax_Rate__c, Tax_Amount__c, CGST__c, SGST__c, IGST__c, Free_Quantity__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :soIds AND Product_Ext__c != null AND Quantity__c > 0
            ORDER BY Product_Ext__c, Sales_Order__c
        ]) {
            Id pid = oli.Product_Ext__c;
            Decimal rem = remaining.containsKey(pid) ? remaining.get(pid) : 0;
            if (rem <= 0) { continue; }
            Decimal ordered = oli.Quantity__c;
            Decimal billed = (rem >= ordered) ? ordered : rem;
            Decimal ratio = (ordered > 0) ? (billed / ordered) : 0;

            DMS_SecondaryBilling_Service.QuoteLine q = new DMS_SecondaryBilling_Service.QuoteLine();
            q.productId = pid;
            q.orderLineId = oli.Id;
            q.productName = oli.Product_Ext__r != null ? oli.Product_Ext__r.Name : '';
            q.hsn = oli.Product_Ext__r != null ? oli.Product_Ext__r.HSN_SAC_Code__c : null;
            q.qty = billed;
            q.unitPrice = nz(oli.Unit_Price__c);
            q.schemeDiscount = (nz(oli.Discount_Amount__c) + nz(oli.Scheme_Discount__c)) * ratio;
            q.discount = q.schemeDiscount;
            q.taxRate = nz(oli.Tax_Rate__c);
            q.tax = (nz(oli.Tax_Amount__c) * ratio).setScale(2, System.RoundingMode.HALF_UP);
            q.cgst = (nz(oli.CGST__c) * ratio).setScale(2, System.RoundingMode.HALF_UP);
            q.sgst = (nz(oli.SGST__c) * ratio).setScale(2, System.RoundingMode.HALF_UP);
            q.igst = (nz(oli.IGST__c) * ratio).setScale(2, System.RoundingMode.HALF_UP);
            q.freeQty = Math.floor(nz(oli.Free_Quantity__c) * ratio);
            q.discount = q.discount.setScale(2, System.RoundingMode.HALF_UP);
            q.gross = (billed * q.unitPrice).setScale(2, System.RoundingMode.HALF_UP);
            q.net = (q.gross - q.discount + q.tax).setScale(2, System.RoundingMode.HALF_UP);
            out.add(q);

            remaining.put(pid, rem - billed);
        }
        return out;
    }

    /** Ordered quantity per product across a set of sales orders (for the wizard's max/defaults). */
    private static Map<Id, Decimal> orderedByProduct(Set<Id> soIds) {
        Map<Id, Decimal> m = new Map<Id, Decimal>();
        if (soIds.isEmpty()) { return m; }
        for (AggregateResult ar : [
            SELECT Product_Ext__c pid, SUM(Quantity__c) q FROM Order_Line_Item__c
            WHERE Sales_Order__c IN :soIds AND Product_Ext__c != null GROUP BY Product_Ext__c
        ]) {
            m.put((Id) ar.get('pid'), toDecimal(ar.get('q')));
        }
        return m;
    }

    /**
     * Returns the exact invoice the wizard would generate for the selected
     * sales orders + billed quantities — same computation as the create path.
     */
    @AuraEnabled
    public static InvoiceQuote previewInvoiceFromOrders(String salesOrderIdsJson, String linesJson) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Set<Id> soIds = parseIdSet(salesOrderIdsJson);
        Map<Id, Decimal> billedByProduct = new Map<Id, Decimal>();
        for (IndentLineInput li : toLineInputs(linesJson)) {
            if (String.isNotBlank(li.productId) && li.quantity != null && li.quantity > 0) {
                billedByProduct.put(Id.valueOf(li.productId), li.quantity);
            }
        }
        InvoiceQuote quote = new InvoiceQuote();
        if (soIds.isEmpty() || billedByProduct.isEmpty()) { return quote; }
        // Ownership gate: acctId was previously resolved and never used, so any portal
        // user could read line-level pricing, discounts and scheme terms for ANY
        // distributor's sales orders.
        if (acctId != null && !ownsSalesOrders(acctId, soIds)) {
            throw new AuraHandledException('These orders are not yours to invoice.');
        }

        Map<Id, Decimal> ordered = orderedByProduct(soIds);
        for (DMS_SecondaryBilling_Service.QuoteLine q : buildQuote(soIds, billedByProduct)) {
            InvoiceQuoteLine l = new InvoiceQuoteLine();
            l.productId = q.productId;
            l.productName = q.productName;
            l.ordered = ordered.containsKey(q.productId) ? ordered.get(q.productId) : q.qty;
            l.qty = q.qty;
            l.unitPrice = q.unitPrice;
            l.discount = q.discount;
            l.taxRate = q.taxRate;
            l.tax = q.tax;
            l.freeQty = q.freeQty;
            l.gross = q.gross;
            l.net = q.net;
            quote.lines.add(l);
            quote.subtotal += q.gross;
            quote.discount += q.discount;
            quote.tax += q.tax;
            quote.net += q.net;
            quote.freeTotal += q.freeQty;
        }
        quote.itemCount = quote.lines.size();
        return quote;
    }

    /**
     * Creates a secondary invoice for the given retailer that faithfully
     * reproduces the selected sales-order lines (prorated to the billed qty),
     * allocates the stock FEFO, then links the source orders as invoiced.
     */
    @AuraEnabled
    public static Id createSecondaryInvoiceFromOrders(Id retailerId, String linesJson, String salesOrderIdsJson) {
        ensureEnabled();
        Id distributorId = requireAccountId();
        Set<Id> soIds = parseIdSet(salesOrderIdsJson);
        Map<Id, Decimal> billedByProduct = new Map<Id, Decimal>();
        for (IndentLineInput li : toLineInputs(linesJson)) {
            if (String.isNotBlank(li.productId) && li.quantity != null && li.quantity > 0) {
                billedByProduct.put(Id.valueOf(li.productId), li.quantity);
            }
        }
        if (retailerId == null || soIds.isEmpty() || billedByProduct.isEmpty()) {
            throw new AuraHandledException('Select a retailer and at least one order line.');
        }
        // You may only bill a retailer you serve.
        if (!isMyCustomer(distributorId, retailerId)) {
            throw new AuraHandledException('This retailer is not one of your customers.');
        }
        // Every selected order must belong to THIS retailer. buildQuote filters only on
        // the supplied ids, so unscoped ids would bill another retailer's lines onto
        // this invoice (and the back-link below would then silently skip them, leaving
        // those orders re-billable).
        if ([SELECT COUNT() FROM Sales_Order__c
             WHERE Id IN :soIds AND Account__c = :retailerId] != soIds.size()) {
            throw new AuraHandledException('One or more selected orders do not belong to this retailer.');
        }
        List<DMS_SecondaryBilling_Service.QuoteLine> quote = buildQuote(soIds, billedByProduct);
        if (quote.isEmpty()) { throw new AuraHandledException('No valid order lines.'); }

        Id invoiceId;
        try {
            invoiceId = DMS_SecondaryBilling_Service.createInvoiceFromQuote(distributorId, retailerId, quote);
        } catch (DMS_SecondaryBillingException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not create invoice: ' + e.getMessage());
        }

        // Link the source sales orders to this invoice (mark them billed).
        List<Sales_Order__c> sos = [
            SELECT Id FROM Sales_Order__c
            WHERE Id IN :soIds AND Account__c = :retailerId AND Invoice__c = null
        ];
        for (Sales_Order__c so : sos) { so.Invoice__c = invoiceId; }
        if (!sos.isEmpty()) { update sos; }
        return invoiceId;
    }

    /** Lines for one primary order, scoped to the distributor's account. */
    @AuraEnabled(cacheable=true)
    // Named getPrimaryOrderLines (was getIndentLines): despite the old name it always queried
    // Primary_Order_Line__c — the live path — never the legacy Indent_Line__c.
    public static List<Primary_Order_Line__c> getPrimaryOrderLines(Id primaryOrderId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String w = 'Id = :primaryOrderId' + (acctId == null ? '' : ' AND Account__c = :acctId');
        List<Primary_Order__c> ord = Database.query('SELECT Id FROM Primary_Order__c WHERE ' + w + ' LIMIT 1');
        if (ord.isEmpty()) { return new List<Primary_Order_Line__c>(); }
        return [
            SELECT Id, Product_Ext__r.Name, UOM__c, Quantity__c, Base_Quantity__c,
                   Unit_Price__c, MRP__c, Scheme__r.Name, Free_Quantity__c,
                   Discount_Amount__c, Tax_Rate__c, Tax_Amount__c, Line_Total__c
            FROM Primary_Order_Line__c WHERE Primary_Order__c = :primaryOrderId ORDER BY Name
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Invoice__c> getInvoices() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Invoice_Number__c, Account__r.Name, Invoice_Date__c, Order_Type__c, '
            + 'Total_Amount__c, Balance_Due__c, Status__c FROM Invoice__c';
        if (acctId != null) {
            q += ' WHERE (Account__c = :acctId OR Sold_From_Distributor__c = :acctId OR Account__r.ParentId = :acctId)';
        }
        q += ' ORDER BY Invoice_Date__c DESC LIMIT 2000';
        return Database.query(q);
    }

    // ── Invoices view (KPIs + decorated rows + line detail) ───────────────
    public class InvoiceRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public String party;
        @AuraEnabled public Date invoiceDate;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public String orderType;
        @AuraEnabled public Decimal total;
        @AuraEnabled public Decimal balance;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean overdue = false;
        @AuraEnabled public Boolean grnDone = false;     // primary: goods received
        @AuraEnabled public String supplier;             // primary: source warehouse/company
        @AuraEnabled public String customerType;         // secondary: Retailer / Sub-Dist.
        @AuraEnabled public String orderRef;             // secondary: source sales order number(s)
        @AuraEnabled public String irn;                  // e-invoice IRN (blank if none)
        @AuraEnabled public String eInvoiceStatus;       // Not Generated / Generated / Cancelled
        @AuraEnabled public Boolean canGenerateEInvoice = false;
    }
    public class InvoiceSummary {
        @AuraEnabled public Decimal totalInvoiced = 0;
        @AuraEnabled public Decimal outstanding = 0;
        @AuraEnabled public Decimal paid = 0;
        @AuraEnabled public Integer count = 0;
        @AuraEnabled public Integer overdueCount = 0;
        @AuraEnabled public Decimal overdueValue = 0;
        @AuraEnabled public List<InvoiceRow> rows = new List<InvoiceRow>();
    }

    @AuraEnabled(cacheable=true)
    public static InvoiceSummary getInvoiceSummary() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Date today = Date.today();
        InvoiceSummary s = new InvoiceSummary();

        String q = 'SELECT Id, Invoice_Number__c, Account__r.Name, Account__r.RecordType.DeveloperName, '
            + 'Account__r.ParentId, Warehouse__r.Name, Invoice_Date__c, Due_Date__c, Order_Type__c, Total_Amount__c, '
            + 'Balance_Due__c, Status__c, Sold_From_Distributor__c, E_Invoice_IRN__c, E_Invoice_Status__c, '
            + '(SELECT Name FROM Sales_Orders__r) FROM Invoice__c';
        if (acctId != null) {
            q += ' WHERE (Account__c = :acctId OR Sold_From_Distributor__c = :acctId OR Account__r.ParentId = :acctId)';
        }
        q += ' ORDER BY Invoice_Date__c DESC LIMIT 2000';

        List<Invoice__c> invoices = Database.query(q);

        // Which primary invoices have a received GRN.
        Set<Id> primaryIds = new Set<Id>();
        for (Invoice__c inv : invoices) {
            if (inv.Order_Type__c == DMS_Constants.ORDER_TYPE_PRIMARY) { primaryIds.add(inv.Id); }
        }
        Set<Id> grnReceived = new Set<Id>();
        if (!primaryIds.isEmpty()) {
            for (GRN__c g : [SELECT Invoice__c FROM GRN__c
                             WHERE Invoice__c IN :primaryIds AND Status__c IN ('Received', 'Completed', 'Partial')]) {
                grnReceived.add(g.Invoice__c);
            }
        }

        for (Invoice__c inv : invoices) {
            InvoiceRow r = new InvoiceRow();
            r.id = inv.Id;
            r.invoiceNumber = inv.Invoice_Number__c;
            r.party = inv.Account__r != null ? inv.Account__r.Name : '';
            r.invoiceDate = inv.Invoice_Date__c;
            r.dueDate = inv.Due_Date__c;
            r.orderType = inv.Order_Type__c;
            r.total = nz(inv.Total_Amount__c);
            r.balance = nz(inv.Balance_Due__c);
            r.status = inv.Status__c;
            Date due = inv.Due_Date__c != null ? inv.Due_Date__c : inv.Invoice_Date__c;
            r.overdue = (r.balance > 0 && due != null && due < today);
            r.grnDone = grnReceived.contains(inv.Id);
            r.supplier = (inv.Warehouse__r != null && inv.Warehouse__r.Name != null) ? inv.Warehouse__r.Name : 'Company';
            String rt = inv.Account__r != null ? inv.Account__r.RecordType.DeveloperName : null;
            r.customerType = (rt == DMS_Constants.RT_RETAILER) ? 'Retailer' : 'Sub-Dist.';
            if (inv.Sales_Orders__r != null && !inv.Sales_Orders__r.isEmpty()) {
                List<String> soNames = new List<String>();
                for (Sales_Order__c so : inv.Sales_Orders__r) { soNames.add(so.Name); }
                r.orderRef = String.join(soNames, ', ');
            }
            // E-invoice state. The distributor may generate for the secondary sales
            // they issued (they are the supplier); primary IRNs are view-only.
            r.irn = inv.E_Invoice_IRN__c;
            r.eInvoiceStatus = String.isNotBlank(inv.E_Invoice_IRN__c)
                ? (String.isNotBlank(inv.E_Invoice_Status__c) ? inv.E_Invoice_Status__c : 'Generated')
                : 'Not Generated';
            // Only the distributor who ISSUED the invoice is its supplier. The parent-account
            // disjunct was removed: it let a parent distributor file a GST IRN against an
            // invoice another distributor raised — irreversible, and filed under the wrong
            // supplier with the tax authority.
            Boolean isSeller = (acctId == null) || (inv.Sold_From_Distributor__c == acctId);
            r.canGenerateEInvoice = isSeller && String.isBlank(inv.E_Invoice_IRN__c)
                && inv.Order_Type__c == DMS_Constants.ORDER_TYPE_SECONDARY && inv.Status__c != 'Cancelled';
            s.rows.add(r);

            s.totalInvoiced += r.total;
            s.outstanding += r.balance;
            s.count++;
            if (r.overdue) { s.overdueCount++; s.overdueValue += r.balance; }
        }
        s.paid = s.totalInvoiced - s.outstanding;
        return s;
    }

    @AuraEnabled(cacheable=true)
    public static List<Invoice_Line__c> getInvoiceLines(Id invoiceId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        // Confirm the invoice is in scope before returning its lines.
        String w = 'Id = :invoiceId'
            + (acctId == null ? '' : ' AND (Account__c = :acctId OR Sold_From_Distributor__c = :acctId OR Account__r.ParentId = :acctId)');
        List<Invoice__c> inv = Database.query('SELECT Id FROM Invoice__c WHERE ' + w + ' LIMIT 1');
        if (inv.isEmpty()) { return new List<Invoice_Line__c>(); }
        return [
            SELECT Id, Line_Number__c, Product_Ext__r.Name, Batch_No__c, Quantity__c,
                   Unit_Price__c, Total_Amount__c, Tax_Amount__c
            FROM Invoice_Line__c WHERE Invoice__c = :invoiceId ORDER BY Line_Number__c
        ];
    }

    // ── E-invoicing (portal) ──────────────────────────────────────────────
    /**
     * Read the e-invoice state for an in-scope invoice (view for the flyout).
     * Built here rather than delegating to EInvoiceController: that class is
     * `with sharing`, and a distributor has no record-level access to a secondary
     * invoice (its Account is the retailer), so the read would come back empty.
     * This class is `without sharing` and enforces its own account scoping.
     */
    @AuraEnabled(cacheable=true)
    public static EInvoiceController.EInvoiceView getEInvoiceDetail(Id invoiceId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String w = 'Id = :invoiceId'
            + (acctId == null ? '' : ' AND (Account__c = :acctId OR Sold_From_Distributor__c = :acctId OR Account__r.ParentId = :acctId)');
        List<Invoice__c> rows = Database.query(
            'SELECT Id, Invoice_Number__c, Total_Amount__c, E_Invoice_IRN__c, E_Invoice_QR__c, '
            + 'E_Invoice_Ack_No__c, E_Invoice_Ack_Date__c, E_Invoice_Status__c, '
            + 'E_Way_Bill_No__c, E_Way_Bill_Date__c, E_Way_Bill_Valid_Until__c '
            + 'FROM Invoice__c WHERE ' + w + ' LIMIT 1');
        if (rows.isEmpty()) { throw new AuraHandledException('Invoice not in scope.'); }

        Invoice__c inv = rows[0];
        EInvoiceController.EInvoiceView v = new EInvoiceController.EInvoiceView();
        v.invoiceId = inv.Id;
        v.invoiceNumber = inv.Invoice_Number__c;
        v.totalAmount = inv.Total_Amount__c;
        v.irn = inv.E_Invoice_IRN__c;
        v.signedQr = inv.E_Invoice_QR__c;
        v.ackNo = inv.E_Invoice_Ack_No__c;
        v.ackDate = inv.E_Invoice_Ack_Date__c;
        v.status = inv.E_Invoice_Status__c;
        v.ewbNo = inv.E_Way_Bill_No__c;
        v.ewbDate = inv.E_Way_Bill_Date__c;
        v.ewbValidUntil = inv.E_Way_Bill_Valid_Until__c;
        v.generated = String.isNotBlank(inv.E_Invoice_IRN__c);
        v.enabled = EInvoice_Service.isEnabled();
        return v;
    }

    /** Register the GST e-invoice for a secondary sale the distributor issued. */
    @AuraEnabled
    public static EInvoice_Models.Result generateEInvoice(Id invoiceId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String w = 'Id = :invoiceId AND Order_Type__c = \'' + DMS_Constants.ORDER_TYPE_SECONDARY + '\'';
        // Strictly the issuing distributor — filing an IRN is irreversible and identifies
        // the supplier to the GST portal, so a parent must not file for its child's sale.
        if (acctId != null) { w += ' AND Sold_From_Distributor__c = :acctId'; }
        List<Invoice__c> inv = Database.query('SELECT Id FROM Invoice__c WHERE ' + w + ' LIMIT 1');
        if (inv.isEmpty()) { throw new AuraHandledException('This invoice is not yours to e-invoice.'); }
        return EInvoice_Service.generateOne(invoiceId);
    }

    // ── GRN (goods receipt against primary dispatches) ────────────────────
    public class GrnRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public Id invoiceId;
        @AuraEnabled public Date grnDate;
        @AuraEnabled public String status;
        @AuraEnabled public String receivedBy;
        @AuraEnabled public Integer skuCount = 0;
        @AuraEnabled public Decimal dispatchedQty = 0;
        @AuraEnabled public Decimal receivedQty = 0;
        @AuraEnabled public Decimal damagedQty = 0;
        @AuraEnabled public Decimal shortQty = 0;
    }
    public class DispatchLine {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String sku;
        @AuraEnabled public Decimal dispatchedQty = 0;
    }
    public class PendingDispatch {
        @AuraEnabled public Id id;
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public Date invoiceDate;
        @AuraEnabled public Decimal amount = 0;
        @AuraEnabled public String supplier;
        @AuraEnabled public List<DispatchLine> lines = new List<DispatchLine>();
    }

    /** The distributor's goods-receipt notes, with per-line rollups. */
    @AuraEnabled(cacheable=true)
    public static List<GrnRow> getGrns() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Name, Invoice__c, Invoice__r.Invoice_Number__c, GRN_Date__c, '
            + 'Status__c, Received_By__c FROM GRN__c';
        if (acctId != null) { q += ' WHERE Account__c = :acctId'; }
        q += ' ORDER BY GRN_Date__c DESC NULLS LAST LIMIT 2000';

        List<GrnRow> rows = new List<GrnRow>();
        Map<Id, GrnRow> byId = new Map<Id, GrnRow>();
        for (GRN__c g : Database.query(q)) {
            GrnRow r = new GrnRow();
            r.id = g.Id;
            r.name = g.Name;
            r.invoiceId = g.Invoice__c;
            r.invoiceNumber = g.Invoice__r != null ? g.Invoice__r.Invoice_Number__c : null;
            r.grnDate = g.GRN_Date__c;
            r.status = g.Status__c;
            r.receivedBy = g.Received_By__c;
            rows.add(r);
            byId.put(g.Id, r);
        }
        if (!byId.isEmpty()) {
            for (AggregateResult ar : [
                SELECT GRN__c gid, COUNT(Id) c, SUM(Dispatched_Qty__c) d, SUM(Received_Qty__c) rq,
                       SUM(Damaged_Qty__c) dm, SUM(Short_Qty__c) s
                FROM GRN_Line__c WHERE GRN__c IN :byId.keySet() GROUP BY GRN__c
            ]) {
                GrnRow r = byId.get((Id) ar.get('gid'));
                if (r == null) { continue; }
                r.skuCount = (Integer) ar.get('c');
                r.dispatchedQty = toDecimal(ar.get('d'));
                r.receivedQty = toDecimal(ar.get('rq'));
                r.damagedQty = toDecimal(ar.get('dm'));
                r.shortQty = toDecimal(ar.get('s'));
            }
        }
        return rows;
    }

    /** Primary dispatch invoices for this distributor that don't yet have a GRN. */
    @AuraEnabled(cacheable=true)
    public static List<PendingDispatch> getPendingGrnInvoices() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String otPrimary = DMS_Constants.ORDER_TYPE_PRIMARY;
        String w = 'Order_Type__c = :otPrimary' + (acctId == null ? '' : ' AND Account__c = :acctId');
        List<Invoice__c> invs = Database.query(
            'SELECT Id, Invoice_Number__c, Invoice_Date__c, Total_Amount__c, Warehouse__r.Name '
            + 'FROM Invoice__c WHERE ' + w + ' ORDER BY Invoice_Date__c DESC LIMIT 500');
        if (invs.isEmpty()) { return new List<PendingDispatch>(); }

        Set<Id> invIds = new Map<Id, Invoice__c>(invs).keySet();
        Set<Id> withGrn = new Set<Id>();
        for (GRN__c g : [SELECT Invoice__c FROM GRN__c WHERE Invoice__c IN :invIds AND Invoice__c != null]) {
            withGrn.add(g.Invoice__c);
        }
        Map<Id, List<DispatchLine>> linesByInv = new Map<Id, List<DispatchLine>>();
        for (Invoice_Line__c il : [
            SELECT Invoice__c, Product_Ext__c, Product_Ext__r.Name, Product_Ext__r.SKU_Code__c, Quantity__c
            FROM Invoice_Line__c WHERE Invoice__c IN :invIds AND Product_Ext__c != null
            ORDER BY Line_Number__c
        ]) {
            if (!linesByInv.containsKey(il.Invoice__c)) { linesByInv.put(il.Invoice__c, new List<DispatchLine>()); }
            DispatchLine dl = new DispatchLine();
            dl.productId = il.Product_Ext__c;
            dl.name = il.Product_Ext__r != null ? il.Product_Ext__r.Name : '';
            dl.sku = il.Product_Ext__r != null ? il.Product_Ext__r.SKU_Code__c : '';
            dl.dispatchedQty = nz(il.Quantity__c);
            linesByInv.get(il.Invoice__c).add(dl);
        }

        List<PendingDispatch> out = new List<PendingDispatch>();
        for (Invoice__c inv : invs) {
            if (withGrn.contains(inv.Id) || !linesByInv.containsKey(inv.Id)) { continue; }
            PendingDispatch p = new PendingDispatch();
            p.id = inv.Id;
            p.invoiceNumber = inv.Invoice_Number__c;
            p.invoiceDate = inv.Invoice_Date__c;
            p.amount = nz(inv.Total_Amount__c);
            p.supplier = (inv.Warehouse__r != null && inv.Warehouse__r.Name != null) ? inv.Warehouse__r.Name : 'Company';
            p.lines = linesByInv.get(inv.Id);
            out.add(p);
        }
        return out;
    }

    /**
     * Creates GRNs (one per dispatch invoice) recording received / damaged / short
     * quantities and batch / expiry per line, then confirms them so the posting
     * handler moves usable stock into Distributor_Stock and advances the indent.
     * Payload: [{ invoiceId, notes, lines:[{ productId, dispatchedQty, receivedQty,
     *             damagedQty, batchNo, expiryDate }] }]
     */
    public class GrnResult {
        @AuraEnabled public Integer grnCount = 0;
        @AuraEnabled public Integer returnCount = 0;
        @AuraEnabled public Decimal returnValue = 0;
    }

    @AuraEnabled
    public static GrnResult createGrns(String grnsJson) {
        ensureEnabled();
        Id acctId = requireAccountId();
        List<Object> parsed;
        try {
            parsed = (List<Object>) JSON.deserializeUntyped(grnsJson);
        } catch (Exception e) {
            throw new AuraHandledException('Could not read the GRN details.');
        }
        if (parsed == null || parsed.isEmpty()) {
            throw new AuraHandledException('Select at least one dispatch to receive.');
        }

        // Collect requested invoice ids and validate they are this distributor's
        // primary invoices without an existing GRN.
        Map<Id, Map<String, Object>> byInvoice = new Map<Id, Map<String, Object>>();
        for (Object o : parsed) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> m = (Map<String, Object>) o;
            Object inv = m.get('invoiceId');
            if (inv == null) { continue; }
            byInvoice.put(Id.valueOf(String.valueOf(inv)), m);
        }
        if (byInvoice.isEmpty()) { throw new AuraHandledException('No valid dispatch selected.'); }

        Set<Id> validInv = new Set<Id>();
        for (Invoice__c inv : [
            SELECT Id FROM Invoice__c
            WHERE Id IN :byInvoice.keySet() AND Order_Type__c = :DMS_Constants.ORDER_TYPE_PRIMARY
              AND Account__c = :acctId
        ]) {
            validInv.add(inv.Id);
        }
        Set<Id> already = new Set<Id>();
        for (GRN__c g : [SELECT Invoice__c FROM GRN__c WHERE Invoice__c IN :validInv]) {
            already.add(g.Invoice__c);
        }

        List<GRN__c> grns = new List<GRN__c>();
        Map<Integer, List<Map<String, Object>>> lineDataByIdx = new Map<Integer, List<Map<String, Object>>>();
        for (Id invId : byInvoice.keySet()) {
            if (!validInv.contains(invId) || already.contains(invId)) { continue; }
            Map<String, Object> m = byInvoice.get(invId);
            Object rawLines = m.get('lines');
            if (!(rawLines instanceof List<Object>)) { continue; }
            List<Map<String, Object>> lines = new List<Map<String, Object>>();
            for (Object lo : (List<Object>) rawLines) {
                if (lo instanceof Map<String, Object>) { lines.add((Map<String, Object>) lo); }
            }
            if (lines.isEmpty()) { continue; }
            GRN__c grn = new GRN__c(
                Account__c = acctId,
                Invoice__c = invId,
                GRN_Date__c = Date.today(),
                Received_By__c = UserInfo.getName(),
                Status__c = 'Pending',
                Notes__c = m.get('notes') == null ? null : String.valueOf(m.get('notes'))
            );
            lineDataByIdx.put(grns.size(), lines);
            grns.add(grn);
        }
        if (grns.isEmpty()) {
            throw new AuraHandledException('These dispatches are already received or not available.');
        }
        insert grns;

        List<GRN_Line__c> grnLines = new List<GRN_Line__c>();
        // Damaged lines per GRN → a Primary damaged-goods return is auto-created.
        Map<Id, List<GRN_Line__c>> damagedByGrn = new Map<Id, List<GRN_Line__c>>();
        for (Integer i = 0; i < grns.size(); i++) {
            Decimal hdrDamaged = 0, hdrShort = 0;
            for (Map<String, Object> l : lineDataByIdx.get(i)) {
                Object pid = l.get('productId');
                if (pid == null) { continue; }
                Decimal disp = toDecimal(l.get('dispatchedQty'));
                Decimal recvd = toDecimal(l.get('receivedQty'));
                Decimal dmg = toDecimal(l.get('damagedQty'));
                Decimal shortQ = disp - recvd;
                if (shortQ < 0) { shortQ = 0; }
                GRN_Line__c gl = new GRN_Line__c(
                    GRN__c = grns[i].Id,
                    Product_Ext__c = Id.valueOf(String.valueOf(pid)),
                    Dispatched_Qty__c = disp,
                    Received_Qty__c = recvd,
                    Damaged_Qty__c = dmg,
                    Short_Qty__c = shortQ,
                    Batch_No__c = l.get('batchNo') == null ? null : String.valueOf(l.get('batchNo')),
                    Expiry_Date__c = parseDate(l.get('expiryDate'))
                );
                grnLines.add(gl);
                if (dmg > 0) {
                    if (!damagedByGrn.containsKey(grns[i].Id)) { damagedByGrn.put(grns[i].Id, new List<GRN_Line__c>()); }
                    damagedByGrn.get(grns[i].Id).add(gl);
                }
                hdrDamaged += dmg; hdrShort += shortQ;
            }
            grns[i].Damaged_Qty__c = hdrDamaged;
            grns[i].Short_Qty__c = hdrShort;
            // Received in full → Received; otherwise Partial. Confirming (status
            // change from Pending) fires DMS_GRN_TriggerHandler to post stock.
            grns[i].Status__c = (hdrShort > 0) ? 'Partial' : 'Received';
        }
        insert grnLines;
        update grns; // Pending -> Received/Partial triggers stock posting.

        GrnResult res = new GrnResult();
        res.grnCount = grns.size();
        // Damaged-goods return is best-effort: a failure here must not undo the
        // GRN + stock posting that already succeeded.
        System.Savepoint sp = Database.setSavepoint();
        try {
            createDamageReturns(acctId, grns, damagedByGrn, res);
        } catch (Exception e) {
            Database.rollback(sp);
            res.returnCount = 0;
            res.returnValue = 0;
        }
        return res;
    }

    /** Auto-creates a Primary (distributor→company) return for damaged GRN units. */
    private static void createDamageReturns(
        Id acctId, List<GRN__c> grns, Map<Id, List<GRN_Line__c>> damagedByGrn, GrnResult res
    ) {
        if (damagedByGrn.isEmpty()) { return; }

        // Dispatch unit price per (invoice, product) for the return value.
        Map<Id, Id> invoiceByGrn = new Map<Id, Id>();
        Set<Id> invIds = new Set<Id>();
        for (GRN__c g : grns) { invoiceByGrn.put(g.Id, g.Invoice__c); invIds.add(g.Invoice__c); }
        Map<String, Decimal> priceByInvProd = new Map<String, Decimal>();
        for (Invoice_Line__c il : [
            SELECT Invoice__c, Product_Ext__c, Unit_Price__c
            FROM Invoice_Line__c WHERE Invoice__c IN :invIds
        ]) {
            priceByInvProd.put(il.Invoice__c + '|' + il.Product_Ext__c, nz(il.Unit_Price__c));
        }

        List<Return_Order__c> returns = new List<Return_Order__c>();
        Map<Integer, List<GRN_Line__c>> linesByReturnIdx = new Map<Integer, List<GRN_Line__c>>();
        Map<Integer, Id> invByReturnIdx = new Map<Integer, Id>();
        for (Id grnId : damagedByGrn.keySet()) {
            Id invId = invoiceByGrn.get(grnId);
            linesByReturnIdx.put(returns.size(), damagedByGrn.get(grnId));
            invByReturnIdx.put(returns.size(), invId);
            returns.add(new Return_Order__c(
                Account__c = acctId,
                Invoice__c = invId,
                Original_Invoice__c = invId,
                Return_Type__c = 'Primary',
                Return_Reason__c = 'Damaged',
                Return_Date__c = Date.today(),
                Status__c = 'Draft',
                Notes__c = 'Auto-created for damaged units on goods receipt.'
            ));
        }
        insert returns;

        List<Return_Line__c> retLines = new List<Return_Line__c>();
        for (Integer i = 0; i < returns.size(); i++) {
            Id invId = invByReturnIdx.get(i);
            Decimal totalQty = 0, totalVal = 0;
            for (GRN_Line__c gl : linesByReturnIdx.get(i)) {
                Decimal price = priceByInvProd.containsKey(invId + '|' + gl.Product_Ext__c)
                    ? priceByInvProd.get(invId + '|' + gl.Product_Ext__c) : 0;
                Decimal lineVal = (nz(gl.Damaged_Qty__c) * price).setScale(2, System.RoundingMode.HALF_UP);
                retLines.add(new Return_Line__c(
                    Return_Order__c = returns[i].Id,
                    Product_Ext__c = gl.Product_Ext__c,
                    Return_Quantity__c = gl.Damaged_Qty__c,
                    Quantity__c = gl.Damaged_Qty__c,
                    Unit_Price__c = price,
                    Return_Reason__c = 'Damaged',
                    Batch_No__c = gl.Batch_No__c,
                    Expiry_Date__c = gl.Expiry_Date__c,
                    Line_Total__c = lineVal,
                    Net_Amount__c = lineVal
                ));
                totalQty += nz(gl.Damaged_Qty__c);
                totalVal += lineVal;
            }
            returns[i].Return_Quantity__c = totalQty;
            returns[i].Total_Items__c = linesByReturnIdx.get(i).size();
            returns[i].Total_Return_Value__c = totalVal;
            returns[i].Return_Amount__c = totalVal;
            res.returnValue += totalVal;
        }
        insert retLines;
        update returns;
        res.returnCount = returns.size();
    }

    /** Lines of one GRN, scoped to the distributor. */
    @AuraEnabled(cacheable=true)
    public static List<GRN_Line__c> getGrnLines(Id grnId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String w = 'Id = :grnId' + (acctId == null ? '' : ' AND Account__c = :acctId');
        List<GRN__c> g = Database.query('SELECT Id FROM GRN__c WHERE ' + w + ' LIMIT 1');
        if (g.isEmpty()) { return new List<GRN_Line__c>(); }
        return [
            SELECT Id, Product_Ext__r.Name, Dispatched_Qty__c, Received_Qty__c,
                   Damaged_Qty__c, Short_Qty__c, Batch_No__c, Expiry_Date__c
            FROM GRN_Line__c WHERE GRN__c = :grnId ORDER BY Name
        ];
    }

    private static Date parseDate(Object o) {
        if (o == null) { return null; }
        String s = String.valueOf(o);
        if (String.isBlank(s)) { return null; }
        try { return Date.valueOf(s); } catch (Exception e) { return null; }
    }

    // Default company/source warehouse a portal primary order dispatches from.
    private static Boolean whResolved = false;
    private static Id whCache;
    private static Id defaultSourceWarehouseId() {
        if (whResolved) { return whCache; }
        whResolved = true;
        List<Warehouse__c> whs = [
            SELECT Id FROM Warehouse__c WHERE Is_Active__c = true
            ORDER BY Warehouse_Type__c NULLS LAST, Name LIMIT 1
        ];
        whCache = whs.isEmpty() ? null : whs[0].Id;
        return whCache;
    }

    @AuraEnabled(cacheable=true)
    public static List<Ledger_Entry__c> getLedger() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Account__r.Name, Entry_Date__c, Entry_Type__c, Amount__c, '
            + 'Reference_Number__c, Description__c FROM Ledger_Entry__c';
        if (acctId != null) { q += ' WHERE Account__c = :acctId'; }
        q += ' ORDER BY Entry_Date__c DESC LIMIT 2000';
        return Database.query(q);
    }

    // ── Statement of account (ledger with running balance) ────────────────
    public class LedgerRow implements Comparable {
        @AuraEnabled public Date entryDate;
        @AuraEnabled public String type;
        @AuraEnabled public String particulars;
        @AuraEnabled public String reference;
        @AuraEnabled public Decimal debit = 0;
        @AuraEnabled public Decimal credit = 0;
        @AuraEnabled public Decimal balance = 0;
        @AuraEnabled public Integer sortSeq = 0; // debits (invoices) before credits on the same day

        public Integer compareTo(Object o) {
            LedgerRow other = (LedgerRow) o;
            if (entryDate == null && other.entryDate == null) { return sortSeq - other.sortSeq; }
            if (entryDate == null) { return 1; }
            if (other.entryDate == null) { return -1; }
            if (entryDate < other.entryDate) { return -1; }
            if (entryDate > other.entryDate) { return 1; }
            return sortSeq - other.sortSeq;
        }
    }
    public class LedgerStatement {
        @AuraEnabled public String accountName;
        @AuraEnabled public Date fromDate;
        @AuraEnabled public Date toDate;
        @AuraEnabled public Decimal openingBalance = 0;
        @AuraEnabled public Decimal closingBalance = 0;
        @AuraEnabled public Decimal totalDebit = 0;
        @AuraEnabled public Decimal totalCredit = 0;
        @AuraEnabled public List<LedgerRow> rows = new List<LedgerRow>();
    }

    // Resolve a ledger entry to [debit, credit], tolerating data that uses only
    // Amount__c (sign inferred from the entry type) instead of the split fields.
    private static Decimal[] resolveDebitCredit(Ledger_Entry__c e) {
        Decimal debit = nz(e.Debit_Amount__c);
        Decimal credit = nz(e.Credit_Amount__c);
        if (debit == 0 && credit == 0 && e.Amount__c != null && e.Amount__c != 0) {
            String t = e.Entry_Type__c;
            Boolean isCredit = (t == 'Payment' || t == 'Collection' || t == 'Credit' || t == 'Credit Note');
            if (isCredit) { credit = Math.abs(e.Amount__c); } else { debit = Math.abs(e.Amount__c); }
        }
        return new Decimal[]{ debit, credit };
    }

    /**
     * Statement of account for a date range (defaults to the current month).
     *
     * A distributor's receivable is driven by TWO record types, so the statement
     * merges both — otherwise it contradicts the aging (which reads invoices):
     *   • Invoices (Total_Amount__c) are DEBITS — they create the receivable, but
     *     are never posted to Ledger_Entry__c, so we read them directly here.
     *   • Ledger_Entry__c rows (payments, collections, credit notes) are CREDITS
     *     that reduce it. Applied payments also lower the invoice's Balance_Due,
     *     which is why invoices are posted at their FULL value here — the payment
     *     credit is the offsetting entry, so there is no double count.
     *
     * Opening balance = net of all invoices + ledger entries before fromDate;
     * each period row carries a recomputed running balance; closing balance nets
     * the period. Scoped to the distributor's own account (matches getAging).
     */
    @AuraEnabled
    public static LedgerStatement getLedgerStatement(Date fromDate, Date toDate) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        LedgerStatement s = new LedgerStatement();
        s.fromDate = (fromDate != null) ? fromDate : Date.today().toStartOfMonth();
        s.toDate = (toDate != null) ? toDate : Date.today();
        if (s.toDate < s.fromDate) { Date t = s.fromDate; s.fromDate = s.toDate; s.toDate = t; }

        if (acctId != null) {
            List<Account> a = [SELECT Name FROM Account WHERE Id = :acctId];
            s.accountName = a.isEmpty() ? '' : a[0].Name;
        } else {
            s.accountName = 'All Accounts';
        }

        Date fromD = s.fromDate, toD = s.toDate;
        String scope = (acctId == null) ? '' : ' AND Account__c = :acctId';

        // Invoices already posted to the ledger as 'Invoice' debit entries (Option A
        // — DMS_InvoiceLedger_Service) are counted via the ledger queries below.
        // Exclude them from the direct invoice read so they're never double-counted;
        // invoices with no ledger entry (posting off / pre-backfill) are still read
        // directly, so the statement is complete in every state.
        Set<Id> postedInvIds = new Set<Id>();
        for (Ledger_Entry__c e : Database.query(
            'SELECT Invoice__c FROM Ledger_Entry__c '
            + 'WHERE Entry_Type__c = \'Invoice\' AND Invoice__c != null' + scope + ' LIMIT 50000')) {
            postedInvIds.add((Id) e.get('Invoice__c'));
        }

        // ── Opening balance: invoices (debit) + ledger entries (credit) before fromDate.
        for (Ledger_Entry__c e : Database.query(
            'SELECT Entry_Type__c, Amount__c, Debit_Amount__c, Credit_Amount__c FROM Ledger_Entry__c '
            + 'WHERE Entry_Date__c < :fromD' + scope + ' LIMIT 20000')) {
            Decimal[] dc = resolveDebitCredit(e);
            s.openingBalance += dc[0] - dc[1];
        }
        for (AggregateResult ar : Database.query(
            'SELECT SUM(Total_Amount__c) t FROM Invoice__c '
            + 'WHERE Invoice_Date__c < :fromD AND Status__c != \'Cancelled\' '
            + 'AND Id NOT IN :postedInvIds' + scope)) {
            s.openingBalance += (ar.get('t') != null) ? (Decimal) ar.get('t') : 0;
        }

        // ── Period rows: invoices (debit) + ledger entries (credit), merged by date.
        List<LedgerRow> rows = new List<LedgerRow>();
        for (Invoice__c inv : Database.query(
            'SELECT Invoice_Number__c, Invoice_Date__c, Total_Amount__c, Order_Type__c FROM Invoice__c '
            + 'WHERE Invoice_Date__c >= :fromD AND Invoice_Date__c <= :toD AND Status__c != \'Cancelled\' '
            + 'AND Id NOT IN :postedInvIds'
            + scope + ' ORDER BY Invoice_Date__c ASC LIMIT 5000')) {
            LedgerRow r = new LedgerRow();
            r.entryDate = inv.Invoice_Date__c;
            r.type = 'Invoice';
            r.particulars = (String.isNotBlank(inv.Order_Type__c) ? inv.Order_Type__c + ' invoice' : 'Invoice');
            r.reference = inv.Invoice_Number__c;
            r.debit = nz(inv.Total_Amount__c);
            r.credit = 0;
            r.sortSeq = 0; // debits first within a day
            rows.add(r);
        }
        for (Ledger_Entry__c e : Database.query(
            'SELECT Entry_Date__c, Entry_Type__c, Amount__c, Debit_Amount__c, Credit_Amount__c, '
            + 'Description__c, Reference_Number__c, Reference_Type__c FROM Ledger_Entry__c '
            + 'WHERE Entry_Date__c >= :fromD AND Entry_Date__c <= :toD' + scope
            + ' ORDER BY Entry_Date__c ASC, CreatedDate ASC LIMIT 5000')) {
            Decimal[] dc = resolveDebitCredit(e);
            LedgerRow r = new LedgerRow();
            r.entryDate = e.Entry_Date__c;
            r.type = e.Entry_Type__c;
            r.particulars = String.isNotBlank(e.Description__c)
                ? e.Description__c
                : (String.isNotBlank(e.Entry_Type__c) ? e.Entry_Type__c : 'Entry')
                    + (String.isNotBlank(e.Reference_Number__c) ? ' ' + e.Reference_Number__c : '');
            r.reference = e.Reference_Number__c;
            r.debit = dc[0];
            r.credit = dc[1];
            r.sortSeq = 1; // credits after same-day debits
            rows.add(r);
        }
        rows.sort();

        Decimal running = s.openingBalance;
        for (LedgerRow r : rows) {
            running += r.debit - r.credit;
            r.balance = running;
            s.totalDebit += r.debit;
            s.totalCredit += r.credit;
        }
        s.rows = rows;
        s.closingBalance = running;
        return s;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Decimal> getAging() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        return acctId == null ? DMS_Ledger_Service.getAgingAll() : DMS_Ledger_Service.getAging(acctId);
    }

    @AuraEnabled(cacheable=true)
    public static List<Claim__c> getClaims() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Name, Account__r.Name, Claim_Type__c, Scheme__r.Name, Claim_Date__c, '
            + 'Total_Amount__c, Approved_Amount__c, Status__c, Credit_Note_Number__c, Notes__c FROM Claim__c';
        if (acctId != null) { q += ' WHERE Account__c = :acctId'; }
        q += ' ORDER BY Claim_Date__c DESC LIMIT 2000';
        return Database.query(q);
    }

    /** Active schemes for the New Claim dropdown ({id,name}). */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getClaimSchemes() {
        ensureEnabled();
        List<Map<String, String>> out = new List<Map<String, String>>();
        for (Scheme__c s : [
            SELECT Id, Name FROM Scheme__c WHERE Is_Active__c = true ORDER BY Name LIMIT 500
        ]) {
            out.add(new Map<String, String>{ 'id' => s.Id, 'name' => s.Name });
        }
        return out;
    }

    public class ClaimLineRow {
        @AuraEnabled public String productName;
        @AuraEnabled public String batch;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal claimedAmount;
        @AuraEnabled public Decimal approvedAmount;
        @AuraEnabled public String reason;
    }

    /** The line items of one of the distributor's claims (for the detail view). */
    @AuraEnabled
    public static List<ClaimLineRow> getClaimLines(String claimId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Id cid = toId(claimId);
        if (cid == null) { return new List<ClaimLineRow>(); }
        if (acctId != null) {
            List<Claim__c> owned = [SELECT Id FROM Claim__c WHERE Id = :cid AND Account__c = :acctId LIMIT 1];
            if (owned.isEmpty()) { throw new AuraHandledException('Claim not found.'); }
        }
        List<ClaimLineRow> rows = new List<ClaimLineRow>();
        for (Claim_Line__c l : [
            SELECT Product_Ext__r.Name, Batch_No__c, Quantity__c, Claimed_Amount__c, Approved_Amount__c, Reason__c
            FROM Claim_Line__c WHERE Claim__c = :cid ORDER BY Product_Ext__r.Name
        ]) {
            ClaimLineRow r = new ClaimLineRow();
            r.productName = l.Product_Ext__r != null ? l.Product_Ext__r.Name : null;
            r.batch = l.Batch_No__c;
            r.quantity = l.Quantity__c;
            r.claimedAmount = l.Claimed_Amount__c;
            r.approvedAmount = l.Approved_Amount__c;
            r.reason = l.Reason__c;
            rows.add(r);
        }
        return rows;
    }

    @AuraEnabled(cacheable=true)
    public static List<Ticket__c> getTickets() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Account__r.Name, Subject__c, Category__c, Priority__c, Status__c, '
            + 'Ticket_Date__c FROM Ticket__c';
        if (acctId != null) { q += ' WHERE Account__c = :acctId'; }
        q += ' ORDER BY Ticket_Date__c DESC LIMIT 2000';
        return Database.query(q);
    }

    // ── Self-service actions (require a specific distributor context) ──────

    // Internal DTO. NOTE: we do NOT expose this as an @AuraEnabled method
    // parameter type, nor accept List<Object> — neither Apex inner-class nor
    // untyped-list marshalling from LWC imperative calls is reliable (fields
    // arrive null, or the list arrives empty). Public entry points accept the
    // lines as a JSON string and we deserialize them ourselves.
    public class IndentLineInput {
        public String productId;
        public Decimal quantity;          // quantity in the selected UOM
        public String uom;                // 'Pieces' | 'Cases'
        public Decimal conversionFactor;  // units per selected UOM (case size for Cases)
        public String schemeId;
        public String schemeName;
        public Decimal discountAmount;    // client-computed scheme discount (bounded server-side)
        public Decimal freeQty;
    }

    /**
     * @description Parse the order lines JSON sent from LWC into typed inputs.
     *              We JSON.deserializeUntyped the string and read the keys
     *              directly, so we never depend on Aura/LWC parameter
     *              marshalling into Apex objects or lists.
     */
    private static List<IndentLineInput> toLineInputs(String linesJson) {
        List<IndentLineInput> out = new List<IndentLineInput>();
        if (String.isBlank(linesJson)) { return out; }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(linesJson);
        } catch (Exception e) {
            return out;
        }
        if (!(parsed instanceof List<Object>)) { return out; }
        for (Object o : (List<Object>) parsed) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> m = (Map<String, Object>) o;
            IndentLineInput li = new IndentLineInput();
            Object pid = m.get('productId');
            li.productId = (pid == null) ? null : String.valueOf(pid);
            li.quantity = toDecimal(m.get('quantity'));
            li.uom = m.get('uom') == null ? 'Pieces' : String.valueOf(m.get('uom'));
            li.conversionFactor = toDecimal(m.get('conversionFactor'));
            Object sid = m.get('schemeId');
            li.schemeId = (sid == null) ? null : String.valueOf(sid);
            li.schemeName = m.get('schemeName') == null ? null : String.valueOf(m.get('schemeName'));
            li.discountAmount = toDecimal(m.get('discountAmount'));
            li.freeQty = toDecimal(m.get('freeQty'));
            out.add(li);
        }
        return out;
    }

    // Parse any string to an Id, returning null instead of throwing on a bad value.
    private static Id toId(String v) {
        if (String.isBlank(v)) { return null; }
        try { return Id.valueOf(v); } catch (Exception e) { return null; }
    }

    // A scheme reference that is a valid Scheme__c Id, else null (the payload
    // sometimes carries a scheme name, which must not break order placement).
    private static Id asSchemeId(String v) {
        Id parsed = toId(v);
        if (parsed == null) { return null; }
        try {
            return (parsed.getSObjectType() == Scheme__c.SObjectType) ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }

    @AuraEnabled
    public static Id placeIndent(String linesJson, String note) {
        try {
            return createIndent(toLineInputs(linesJson), note);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            // Surface the real cause (DML/validation) instead of a generic error.
            throw new AuraHandledException('Could not place order: ' + e.getMessage());
        }
    }

    /**
     * Shared indent-creation logic (used by the portal entry point and the
     * one-click replenishment action). Authoritatively re-prices each line
     * from the product master / price list (qty-tier aware), computes
     * line-level gross/discount/tax/net and rolls them up onto the header so
     * the Indent and its lines carry complete amounts — not just quantities.
     */
    private static Id createIndent(List<IndentLineInput> lines) {
        return createIndent(lines, null);
    }

    private static Id createIndent(List<IndentLineInput> lines, String note) {
        ensureEnabled();
        Id acctId = requireAccountId();
        if (lines == null || lines.isEmpty()) {
            throw new AuraHandledException('At least one product line is required.');
        }

        // Price the lines + apply schemes with the shared logic (same result the
        // on-screen preview shows). Lines come back finalised but un-inserted.
        List<Primary_Order_Line__c> orderLines = buildPricedPrimaryLines(acctId, lines);
        if (orderLines.isEmpty()) {
            throw new AuraHandledException('No valid product lines provided.');
        }

        String notes = 'Placed via distributor portal';
        if (String.isNotBlank(note)) { notes += '\n' + note; }
        // Primary order lives on Primary_Order__c (Sales-Order-shaped). Routed to a
        // source Warehouse so it can be dispatched once approved.
        // Submitted, not Draft. A distributor placing an order in the portal IS the request to
        // the company — but this created the order as Draft and nothing anywhere ever set
        // Submitted (the status existed in the picklist and as a constant, and was written by
        // no code at all). Fulfilment fires on Approved, which is reached from Submitted, so a
        // portal order could never reach the company: it sat in Draft forever. System-generated
        // replenishment suggestions stay Draft on purpose — see submitOrder().
        Primary_Order__c order = new Primary_Order__c(
            Account__c = acctId,
            Order_Date__c = Date.today(),
            Status__c = DMS_Constants.INDENT_SUBMITTED,
            Warehouse__c = defaultSourceWarehouseId(),
            Notes__c = notes.abbreviate(255)
        );
        insert order;

        Decimal hdrGross = 0, hdrDiscount = 0, hdrTax = 0, hdrNet = 0;
        for (Primary_Order_Line__c ol : orderLines) {
            ol.Primary_Order__c = order.Id;
            hdrGross += nz(ol.Line_Amount__c);
            hdrDiscount += nz(ol.Scheme_Discount__c);
            hdrTax += nz(ol.Tax_Amount__c);
            hdrNet += nz(ol.Total_Amount__c);
        }
        insert orderLines;

        order.Total_Gross_Amount__c = hdrGross;
        order.Total_Discount__c = hdrDiscount;
        order.Total_Tax__c = hdrTax;
        order.Total_Net_Amount__c = hdrNet;
        order.Total_Amount__c = hdrNet;
        update order;
        return order.Id;
    }

    /**
     * Prices a set of portal order lines into finalised (but un-inserted)
     * Primary_Order_Line__c records: qty-tier pricing from the master / price
     * list, promotional schemes via the shared SFA engine, then per-line tax and
     * net. Used by BOTH order placement and the on-screen preview so the two can
     * never diverge.
     */
    private static List<Primary_Order_Line__c> buildPricedPrimaryLines(
        Id acctId, List<IndentLineInput> lines
    ) {
        List<Primary_Order_Line__c> orderLines = new List<Primary_Order_Line__c>();
        if (lines == null || lines.isEmpty()) { return orderLines; }

        // Resolve product master data + base-quantity-aware pricing up front.
        Set<Id> productIds = new Set<Id>();
        Map<Id, Decimal> baseQtyByProduct = new Map<Id, Decimal>();
        for (IndentLineInput li : lines) {
            if (String.isBlank(li.productId) || li.quantity == null || li.quantity <= 0) { continue; }
            Id pid = toId(li.productId);
            if (pid == null) { continue; }
            Decimal cf = (li.conversionFactor != null && li.conversionFactor > 0) ? li.conversionFactor : 1;
            productIds.add(pid);
            baseQtyByProduct.put(pid, li.quantity * cf);
        }
        if (productIds.isEmpty()) { return orderLines; }

        Map<Id, Product_Extension__c> productById = new Map<Id, Product_Extension__c>([
            SELECT Id, Name, Unit_Price__c, MRP__c, GST_Rate__c, Case_Size__c
            FROM Product_Extension__c WHERE Id IN :productIds
        ]);
        Map<Id, Decimal> unitPriceByProduct = DMS_Pricing_Service.priceForLines(baseQtyByProduct, acctId);

        for (IndentLineInput li : lines) {
            if (String.isBlank(li.productId) || li.quantity == null || li.quantity <= 0) { continue; }
            Id pid = toId(li.productId);
            if (pid == null) { continue; }
            Product_Extension__c p = productById.get(pid);
            if (p == null) { continue; }

            Decimal cf = (li.conversionFactor != null && li.conversionFactor > 0) ? li.conversionFactor : 1;
            Decimal baseQty = li.quantity * cf;
            Decimal unitPrice = unitPriceByProduct.containsKey(pid) && unitPriceByProduct.get(pid) != null
                ? unitPriceByProduct.get(pid) : nz(p.Unit_Price__c);
            Decimal gross = (baseQty * unitPrice).setScale(2, System.RoundingMode.HALF_UP);

            // Gross only — scheme discounts / free goods / tax are applied below.
            orderLines.add(new Primary_Order_Line__c(
                Product_Ext__c = pid,
                Quantity__c = li.quantity,
                UOM__c = String.isNotBlank(li.uom) ? li.uom : 'Pieces',
                Conversion_Factor__c = cf,
                Base_Quantity__c = baseQty,
                Unit_Price__c = unitPrice,
                MRP__c = p.MRP__c,
                Tax_Rate__c = nz(p.GST_Rate__c),
                Line_Amount__c = gross,
                Scheme_Discount__c = 0,
                Free_Quantity__c = 0
            ));
        }
        if (orderLines.isEmpty()) { return orderLines; }

        // Promotional schemes via the shared SFA engine (eligibility-aware).
        applyPrimaryOrderSchemes(acctId, orderLines, Date.today());

        // Finalise per-line amounts against the post-scheme taxable value.
        for (Primary_Order_Line__c ol : orderLines) {
            Decimal gross = nz(ol.Line_Amount__c);
            Decimal discount = nz(ol.Scheme_Discount__c);
            if (discount < 0) { discount = 0; }
            if (discount > gross) { discount = gross; }
            ol.Scheme_Discount__c = discount;
            ol.Discount_Amount__c = discount;
            Decimal taxable = gross - discount;
            Decimal taxRate = nz(ol.Tax_Rate__c);
            Decimal tax = (taxable * taxRate / 100).setScale(2, System.RoundingMode.HALF_UP);
            ol.Tax_Amount__c = tax;
            ol.Net_Amount__c = taxable + tax;
            ol.Line_Total__c = taxable + tax;
            ol.Total_Amount__c = taxable + tax;
        }
        return orderLines;
    }

    /**
     * Server-authoritative preview of a primary order: prices + applies schemes
     * with the SAME logic used at placement, so the on-screen summary matches the
     * order that will be created. Read-only and never throws — returns an empty
     * preview (ok=false) on any issue so the LWC can fall back to a local estimate.
     */
    @AuraEnabled
    public static OrderPreview previewPrimaryOrder(String linesJson) {
        OrderPreview pv = new OrderPreview();
        try {
            if (!BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_MASTER) ||
                !BPM_FeatureToggle_Util.isEnabled(DMS_Constants.TOGGLE_PORTAL)) {
                return pv;
            }
            Id acctId = scopeAccountId();
            if (acctId == null) { return pv; } // internal user → no distributor context
            for (Primary_Order_Line__c ol : buildPricedPrimaryLines(acctId, toLineInputs(linesJson))) {
                OrderPreviewLine pl = new OrderPreviewLine();
                pl.productId = ol.Product_Ext__c;
                pl.gross = nz(ol.Line_Amount__c);
                pl.discount = nz(ol.Scheme_Discount__c);
                pl.tax = nz(ol.Tax_Amount__c);
                pl.net = nz(ol.Total_Amount__c);
                pl.freeQty = nz(ol.Free_Quantity__c);
                pl.schemeId = ol.Scheme__c;
                pv.lines.add(pl);
                pv.gross += pl.gross;
                pv.discount += pl.discount;
                pv.tax += pl.tax;
                pv.net += pl.net;
                pv.freeQty += pl.freeQty;
            }
            pv.ok = true;
        } catch (Exception e) {
            // Preview must never break the screen — return whatever we have.
            System.debug(LoggingLevel.WARN, '[DMS] order preview failed: ' + e.getMessage());
        }
        return pv;
    }

    public class OrderPreview {
        @AuraEnabled public Boolean ok = false;
        @AuraEnabled public Decimal gross = 0;
        @AuraEnabled public Decimal discount = 0;
        @AuraEnabled public Decimal tax = 0;
        @AuraEnabled public Decimal net = 0;
        @AuraEnabled public Decimal freeQty = 0;
        @AuraEnabled public List<OrderPreviewLine> lines = new List<OrderPreviewLine>();
    }
    public class OrderPreviewLine {
        @AuraEnabled public Id productId;
        @AuraEnabled public Decimal gross = 0;
        @AuraEnabled public Decimal discount = 0;
        @AuraEnabled public Decimal tax = 0;
        @AuraEnabled public Decimal net = 0;
        @AuraEnabled public Decimal freeQty = 0;
        @AuraEnabled public Id schemeId;
    }

    /**
     * Applies promotional schemes to a set of in-memory Primary_Order_Line__c
     * records using the shared SFA scheme engine (SPM_SchemeEngine_Service) — the
     * same evaluator the SFA order-entry runs on Order_Line_Item__c. This keeps
     * DMS primary orders behaviourally identical to SFA (eligibility via
     * Scheme_Mapping__c, slabs, same-product / assorted / invoice-level types)
     * rather than re-implementing a subset in the browser.
     *
     * The engine operates on Order_Line_Item__c and keys its per-line discount
     * map by record Id, so we build throwaway shadow line items (never inserted)
     * with synthetic Ids and map the results back onto the primary-order lines.
     * Schemes are additive, so any engine failure is swallowed and the order is
     * still placed at list price.
     */
    private static void applyPrimaryOrderSchemes(
        Id accountId, List<Primary_Order_Line__c> lines, Date orderDate
    ) {
        if (accountId == null || lines == null || lines.isEmpty()) { return; }
        Date evalDate = orderDate != null ? orderDate : Date.today();
        try {
            String prefix = Order_Line_Item__c.SObjectType.getDescribe().getKeyPrefix();
            List<Order_Line_Item__c> shadow = new List<Order_Line_Item__c>();
            Map<Id, Primary_Order_Line__c> lineByShadowId = new Map<Id, Primary_Order_Line__c>();
            Integer i = 0;
            for (Primary_Order_Line__c ol : lines) {
                if (ol.Product_Ext__c == null) { continue; }
                String num = String.valueOf(i++);
                Id shadowId = Id.valueOf(prefix + '000000000000'.substring(0, 12 - num.length()) + num);
                Decimal baseQty = ol.Base_Quantity__c != null ? ol.Base_Quantity__c
                    : (ol.Quantity__c != null ? ol.Quantity__c : 0);
                Decimal gross = nz(ol.Line_Amount__c);
                // Quantity is already in base units; leave UOM blank so the engine
                // evaluates it as-is instead of re-converting it.
                shadow.add(new Order_Line_Item__c(
                    Id = shadowId,
                    Product_Ext__c = ol.Product_Ext__c,
                    Quantity__c = baseQty,
                    Unit_Price__c = ol.Unit_Price__c,
                    Line_Amount__c = gross,
                    Net_Amount__c = gross
                ));
                lineByShadowId.put(shadowId, ol);
            }
            if (shadow.isEmpty()) { return; }

            List<SPM_SchemeEngine_Service.SchemeResult> results =
                SPM_SchemeEngine_Service.getApplicableSchemes(accountId, shadow, evalDate);
            if (results == null || results.isEmpty()) { return; }

            // Buy products for the applied schemes, so a free-goods / reward-only
            // benefit (which carries no per-line discount) can be attached to a
            // qualifying line.
            Set<Id> schemeIds = new Set<Id>();
            for (SPM_SchemeEngine_Service.SchemeResult sr : results) {
                if (sr.schemeId != null) { schemeIds.add(sr.schemeId); }
            }
            Map<Id, Set<Id>> buyProductsByScheme = new Map<Id, Set<Id>>();
            if (!schemeIds.isEmpty()) {
                for (Scheme_Product__c sp : [
                    SELECT Scheme__c, Product_Ext__c FROM Scheme_Product__c
                    WHERE Scheme__c IN :schemeIds AND Is_Buy_Product__c = true AND Product_Ext__c != null
                ]) {
                    if (!buyProductsByScheme.containsKey(sp.Scheme__c)) {
                        buyProductsByScheme.put(sp.Scheme__c, new Set<Id>());
                    }
                    buyProductsByScheme.get(sp.Scheme__c).add(sp.Product_Ext__c);
                }
            }

            Decimal totalNet = 0;
            for (Order_Line_Item__c s : shadow) { totalNet += nz(s.Net_Amount__c); }

            for (SPM_SchemeEngine_Service.SchemeResult sr : results) {
                Boolean targeted = sr.lineItemDiscounts != null && !sr.lineItemDiscounts.isEmpty();
                if (targeted) {
                    // Product/category-targeted discount: add to each named line.
                    for (Id sid : sr.lineItemDiscounts.keySet()) {
                        Primary_Order_Line__c ol = lineByShadowId.get(sid);
                        if (ol == null) { continue; }
                        ol.Scheme_Discount__c = nz(ol.Scheme_Discount__c) + nz(sr.lineItemDiscounts.get(sid));
                        stampScheme(ol, sr);
                    }
                } else if (sr.discountAmount != null && sr.discountAmount > 0 && totalNet > 0) {
                    // Order-level discount: distribute proportionally by line value.
                    for (Order_Line_Item__c s : shadow) {
                        Primary_Order_Line__c ol = lineByShadowId.get(s.Id);
                        if (ol == null) { continue; }
                        Decimal add = (sr.discountAmount * (nz(s.Net_Amount__c) / totalNet))
                            .setScale(2, System.RoundingMode.HALF_UP);
                        ol.Scheme_Discount__c = nz(ol.Scheme_Discount__c) + add;
                    }
                }

                // Free goods / reward points (e.g. 'Free Products' schemes carry no
                // monetary discount) — attach to the first qualifying buy line.
                Boolean hasFree = sr.freeQty != null && sr.freeQty > 0;
                Boolean hasPoints = sr.rewardPoints != null && sr.rewardPoints > 0;
                if (hasFree || hasPoints) {
                    Primary_Order_Line__c target = firstQualifyingLine(
                        lines, buyProductsByScheme.get(sr.schemeId), lineByShadowId, sr
                    );
                    if (target != null) {
                        if (hasFree) { target.Free_Quantity__c = nz(target.Free_Quantity__c) + sr.freeQty; }
                        if (hasPoints) { target.Reward_Points__c = nz(target.Reward_Points__c) + sr.rewardPoints; }
                        stampScheme(target, sr);
                    }
                }
            }
        } catch (Exception e) {
            // Schemes are additive — never block order placement on a scheme error.
            System.debug(LoggingLevel.WARN, '[DMS] scheme application skipped: ' + e.getMessage());
        }
    }

    /** Stamps the scheme attribution onto a line (first scheme wins the lookup). */
    private static void stampScheme(Primary_Order_Line__c ol, SPM_SchemeEngine_Service.SchemeResult sr) {
        if (ol != null && ol.Scheme__c == null && sr.schemeId != null) {
            ol.Scheme__c = sr.schemeId;
            ol.Scheme_Applied__c = sr.schemeId;
            ol.Scheme_Category__c = sr.schemeCategory;
        }
    }

    /** Finds the line a scheme's free goods / reward points should attach to. */
    private static Primary_Order_Line__c firstQualifyingLine(
        List<Primary_Order_Line__c> lines, Set<Id> buyProducts,
        Map<Id, Primary_Order_Line__c> lineByShadowId, SPM_SchemeEngine_Service.SchemeResult sr
    ) {
        // Prefer a line whose product is a buy product of the scheme.
        if (buyProducts != null && !buyProducts.isEmpty()) {
            for (Primary_Order_Line__c ol : lines) {
                if (ol.Product_Ext__c != null && buyProducts.contains(ol.Product_Ext__c)) { return ol; }
            }
        }
        // Otherwise fall back to the first line the scheme targeted with a discount.
        if (sr.lineItemDiscounts != null) {
            for (Id sid : sr.lineItemDiscounts.keySet()) {
                Primary_Order_Line__c ol = lineByShadowId.get(sid);
                if (ol != null) { return ol; }
            }
        }
        return null;
    }

    @AuraEnabled
    public static Id submitClaim(String claimType, String schemeId, Decimal amount, String notes) {
        ensureEnabled();
        Id acctId = requireAccountId();
        if (amount == null || amount <= 0) {
            throw new AuraHandledException('Enter a claim amount greater than zero.');
        }
        Claim__c claim = new Claim__c(
            Account__c = acctId,
            Claim_Type__c = String.isNotBlank(claimType) ? claimType : 'Other',
            Scheme__c = toId(schemeId),
            Claim_Date__c = Date.today(),
            Total_Amount__c = amount,
            Notes__c = notes,
            Status__c = 'Submitted'
        );
        insert claim;
        return claim.Id;
    }

    @AuraEnabled
    public static Id raiseTicket(String subject, String description, String category, String priority) {
        ensureEnabled();
        Id acctId = requireAccountId();
        Ticket__c ticket = new Ticket__c(
            Account__c = acctId,
            Subject__c = subject,
            Description__c = description,
            Category__c = category,
            Priority__c = String.isNotBlank(priority) ? priority : 'Medium',
            Status__c = 'Open',
            Ticket_Date__c = Date.today()
        );
        insert ticket;
        return ticket.Id;
    }

    // ── Returns (distributor self-service) ────────────────────────────────

    public class ReturnRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String returnType;
        @AuraEnabled public Date returnDate;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String status;
        @AuraEnabled public String creditNote;
        @AuraEnabled public String reason;
        @AuraEnabled public String counterparty;
    }

    public class ReturnableLine {
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public String batch;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
    }

    public class ReturnableInvoice {
        @AuraEnabled public Id id;
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public Date invoiceDate;
        @AuraEnabled public String orderType;
        @AuraEnabled public Decimal total;
        @AuraEnabled public List<ReturnableLine> lines = new List<ReturnableLine>();
    }

    /** The distributor's own return orders (returns it raised, or received from its retailers). */
    @AuraEnabled(cacheable=true)
    public static List<ReturnRow> getReturns() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Name, Return_Type__c, Return_Date__c, Return_Quantity__c, '
            + 'Return_Amount__c, Status__c, Credit_Note_Number__c, Return_Reason__c, Account__r.Name '
            + 'FROM Return_Order__c';
        if (acctId != null) {
            q += ' WHERE Account__c = :acctId OR Returned_To_Distributor__c = :acctId';
        }
        q += ' ORDER BY Return_Date__c DESC NULLS LAST LIMIT 2000';
        List<ReturnRow> rows = new List<ReturnRow>();
        for (Return_Order__c r : Database.query(q)) {
            ReturnRow row = new ReturnRow();
            row.id = r.Id;
            row.name = r.Name;
            row.returnType = r.Return_Type__c;
            row.returnDate = r.Return_Date__c;
            row.quantity = r.Return_Quantity__c;
            row.amount = r.Return_Amount__c;
            row.status = r.Status__c;
            row.creditNote = r.Credit_Note_Number__c;
            row.reason = r.Return_Reason__c;
            row.counterparty = r.Account__r != null ? r.Account__r.Name : null;
            rows.add(row);
        }
        return rows;
    }

    /** Invoices the distributor can raise a return against (primary billed to it +
     *  secondary it sold), each with its returnable lines. */
    @AuraEnabled(cacheable=true)
    public static List<ReturnableInvoice> getReturnableInvoices() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Invoice_Number__c, Invoice_Date__c, Order_Type__c, Total_Amount__c, '
            + '(SELECT Id, Product_Ext__c, Product_Ext__r.Name, Batch_No__c, Quantity__c, Unit_Price__c '
            + 'FROM Invoice_Lines__r) FROM Invoice__c WHERE Status__c != \'Cancelled\'';
        if (acctId != null) {
            q += ' AND (Account__c = :acctId OR Sold_From_Distributor__c = :acctId)';
        }
        q += ' ORDER BY Invoice_Date__c DESC NULLS LAST LIMIT 200';
        List<ReturnableInvoice> out = new List<ReturnableInvoice>();
        for (Invoice__c inv : Database.query(q)) {
            if (inv.Invoice_Lines__r == null || inv.Invoice_Lines__r.isEmpty()) { continue; }
            ReturnableInvoice ri = new ReturnableInvoice();
            ri.id = inv.Id;
            ri.invoiceNumber = inv.Invoice_Number__c;
            ri.invoiceDate = inv.Invoice_Date__c;
            ri.orderType = inv.Order_Type__c;
            ri.total = inv.Total_Amount__c;
            for (Invoice_Line__c il : inv.Invoice_Lines__r) {
                if (il.Product_Ext__c == null) { continue; }
                ReturnableLine rl = new ReturnableLine();
                rl.productId = il.Product_Ext__c;
                rl.productName = il.Product_Ext__r != null ? il.Product_Ext__r.Name : null;
                rl.batch = il.Batch_No__c;
                rl.quantity = il.Quantity__c;
                rl.unitPrice = il.Unit_Price__c;
                ri.lines.add(rl);
            }
            if (!ri.lines.isEmpty()) { out.add(ri); }
        }
        return out;
    }

    /**
     * @description Raises a Draft return against one of the distributor's invoices.
     *              A primary invoice yields a PRIMARY return (distributor → company);
     *              a secondary invoice yields a SECONDARY return (retailer → distributor).
     * @param invoiceId The source invoice.
     * @param linesJson JSON array of {productId, batch, quantity}.
     * @param reason    Return reason (header).
     * @return The created Return_Order id.
     */
    @AuraEnabled
    public static Id placeReturn(String invoiceId, String linesJson, String reason) {
        ensureEnabled();
        Id acctId = requireAccountId();
        Id invId = toId(invoiceId);
        if (invId == null) {
            throw new AuraHandledException('Select an invoice to return against.');
        }
        List<Invoice__c> invs = [
            SELECT Id, Account__c, Order_Type__c, Sold_From_Distributor__c
            FROM Invoice__c WHERE Id = :invId LIMIT 1
        ];
        if (invs.isEmpty()) {
            throw new AuraHandledException('Invoice not found.');
        }
        Invoice__c inv = invs[0];
        // Ownership: the invoice must belong to this distributor's context.
        if (inv.Account__c != acctId && inv.Sold_From_Distributor__c != acctId) {
            throw new AuraHandledException('You can only return against your own invoices.');
        }
        Boolean isSecondary = (inv.Order_Type__c == DMS_Constants.ORDER_TYPE_SECONDARY);

        // Unit price per product from the invoice lines (to value the return).
        Map<Id, Decimal> priceByProduct = new Map<Id, Decimal>();
        for (Invoice_Line__c il : [
            SELECT Product_Ext__c, Unit_Price__c FROM Invoice_Line__c WHERE Invoice__c = :invId
        ]) {
            if (il.Product_Ext__c != null) {
                priceByProduct.put(il.Product_Ext__c, nz(il.Unit_Price__c));
            }
        }

        List<Object> raw;
        try {
            raw = (List<Object>) JSON.deserializeUntyped(String.isBlank(linesJson) ? '[]' : linesJson);
        } catch (Exception e) {
            raw = new List<Object>();
        }
        List<Return_Line__c> retLines = new List<Return_Line__c>();
        Decimal totalQty = 0, totalAmount = 0;
        for (Object o : raw) {
            if (!(o instanceof Map<String, Object>)) { continue; }
            Map<String, Object> m = (Map<String, Object>) o;
            Id pid = toId(String.valueOf(m.get('productId')));
            Decimal q = toDecimal(m.get('quantity'));
            if (pid == null || q == null || q <= 0) { continue; }
            String batch = m.get('batch') == null ? null : String.valueOf(m.get('batch'));
            // Per-line reason (Return_Line__c.Return_Reason__c); fall back to the header reason.
            String lineReason = m.get('reason') == null ? reason : String.valueOf(m.get('reason'));
            retLines.add(new Return_Line__c(
                Product_Ext__c = pid, Return_Quantity__c = q, Batch_No__c = batch,
                Return_Reason__c = lineReason
            ));
            totalQty += q;
            totalAmount += q * (priceByProduct.containsKey(pid) ? priceByProduct.get(pid) : 0);
        }
        if (retLines.isEmpty()) {
            throw new AuraHandledException('Enter a return quantity for at least one product.');
        }

        Return_Order__c ro = new Return_Order__c(
            Account__c = isSecondary ? inv.Account__c : acctId,
            Returned_To_Distributor__c = isSecondary ? acctId : null,
            Return_Type__c = isSecondary ? DMS_Constants.RETURN_TYPE_SECONDARY : DMS_Constants.RETURN_TYPE_PRIMARY,
            Invoice__c = inv.Id,
            Return_Date__c = Date.today(),
            Return_Quantity__c = totalQty,
            Return_Amount__c = totalAmount,
            Return_Reason__c = reason,
            Status__c = 'Draft'
        );
        insert ro;
        for (Return_Line__c rl : retLines) { rl.Return_Order__c = ro.Id; }
        insert retLines;
        return ro.Id;
    }

    public class ReturnLineRow {
        @AuraEnabled public String productName;
        @AuraEnabled public String batch;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public String reason;
    }

    /** The line items of one of the distributor's return orders (for the detail view). */
    @AuraEnabled
    public static List<ReturnLineRow> getReturnLines(String returnId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Id rid = toId(returnId);
        if (rid == null) { return new List<ReturnLineRow>(); }
        // Ownership: a portal user can only open their own returns.
        if (acctId != null) {
            List<Return_Order__c> owned = [
                SELECT Id FROM Return_Order__c
                WHERE Id = :rid AND (Account__c = :acctId OR Returned_To_Distributor__c = :acctId)
                LIMIT 1
            ];
            if (owned.isEmpty()) {
                throw new AuraHandledException('Return not found.');
            }
        }
        List<ReturnLineRow> rows = new List<ReturnLineRow>();
        for (Return_Line__c l : [
            SELECT Product_Ext__r.Name, Batch_No__c, Return_Quantity__c, Quantity__c, Return_Reason__c
            FROM Return_Line__c WHERE Return_Order__c = :rid ORDER BY Product_Ext__r.Name
        ]) {
            ReturnLineRow r = new ReturnLineRow();
            r.productName = l.Product_Ext__r != null ? l.Product_Ext__r.Name : null;
            r.batch = l.Batch_No__c;
            r.quantity = (l.Return_Quantity__c != null && l.Return_Quantity__c > 0)
                ? l.Return_Quantity__c : l.Quantity__c;
            r.reason = l.Return_Reason__c;
            rows.add(r);
        }
        return rows;
    }

    // ── Collection (distributor records payments against outstanding invoices) ──

    public class CollectionRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Date collectionDate;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String paymentMode;
        @AuraEnabled public String status;
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public String payer;
    }

    public class CollectibleInvoice {
        @AuraEnabled public Id id;
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public Date invoiceDate;
        @AuraEnabled public String orderType;
        @AuraEnabled public String party;
        @AuraEnabled public Decimal balanceDue;
    }

    @AuraEnabled(cacheable=true)
    public static List<CollectionRow> getCollections() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Name, Collection_Date__c, Amount__c, Payment_Mode__c, Status__c, '
            + 'Invoice__r.Invoice_Number__c, Account__r.Name FROM Collection__c';
        if (acctId != null) {
            q += ' WHERE Account__c = :acctId OR Invoice__r.Sold_From_Distributor__c = :acctId';
        }
        q += ' ORDER BY Collection_Date__c DESC NULLS LAST LIMIT 2000';
        List<CollectionRow> rows = new List<CollectionRow>();
        for (Collection__c c : Database.query(q)) {
            CollectionRow row = new CollectionRow();
            row.id = c.Id;
            row.name = c.Name;
            row.collectionDate = c.Collection_Date__c;
            row.amount = c.Amount__c;
            row.paymentMode = c.Payment_Mode__c;
            row.status = c.Status__c;
            row.invoiceNumber = c.Invoice__r != null ? c.Invoice__r.Invoice_Number__c : null;
            row.payer = c.Account__r != null ? c.Account__r.Name : null;
            rows.add(row);
        }
        return rows;
    }

    /** Outstanding invoices the distributor can collect against (primary it owes +
     *  secondary its retailers owe it). */
    @AuraEnabled(cacheable=true)
    public static List<CollectibleInvoice> getCollectibleInvoices() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String q = 'SELECT Id, Invoice_Number__c, Invoice_Date__c, Order_Type__c, Account__r.Name, Balance_Due__c '
            + 'FROM Invoice__c WHERE Balance_Due__c > 0 AND Status__c != \'Cancelled\'';
        if (acctId != null) {
            q += ' AND (Account__c = :acctId OR Sold_From_Distributor__c = :acctId)';
        }
        q += ' ORDER BY Invoice_Date__c ASC NULLS LAST LIMIT 500';
        List<CollectibleInvoice> out = new List<CollectibleInvoice>();
        for (Invoice__c inv : Database.query(q)) {
            CollectibleInvoice ci = new CollectibleInvoice();
            ci.id = inv.Id;
            ci.invoiceNumber = inv.Invoice_Number__c;
            ci.invoiceDate = inv.Invoice_Date__c;
            ci.orderType = inv.Order_Type__c;
            ci.party = inv.Account__r != null ? inv.Account__r.Name : null;
            ci.balanceDue = inv.Balance_Due__c;
            out.add(ci);
        }
        return out;
    }

    /**
     * @description Records a payment against an outstanding invoice in the
     *              distributor's context. The Collection trigger posts the ledger
     *              entry and reduces the invoice balance (single writer).
     * @param invoiceId   Optional invoice to allocate against (blank = on-account).
     * @param amount      Payment amount (> 0).
     * @param paymentMode Cash / Cheque / UPI / NEFT / RTGS / Online.
     * @param reference   Optional transaction/cheque/UPI reference.
     * @return The created Collection id.
     */
    @AuraEnabled
    public static Id recordCollection(String invoiceId, Decimal amount, String paymentMode, String reference) {
        ensureEnabled();
        Id acctId = requireAccountId();
        if (amount == null || amount <= 0) {
            throw new AuraHandledException('Enter a collection amount greater than zero.');
        }
        Collection__c coll = new Collection__c(
            Amount__c = amount,
            Collection_Date__c = Date.today(),
            Payment_Mode__c = String.isNotBlank(paymentMode) ? paymentMode : 'Cash',
            Status__c = 'Collected'
        );
        Id invId = toId(invoiceId);
        if (invId != null) {
            List<Invoice__c> invs = [
                SELECT Id, Account__c, Sold_From_Distributor__c, Balance_Due__c
                FROM Invoice__c WHERE Id = :invId LIMIT 1
            ];
            if (invs.isEmpty()) {
                throw new AuraHandledException('Invoice not found.');
            }
            Invoice__c inv = invs[0];
            if (inv.Account__c != acctId && inv.Sold_From_Distributor__c != acctId) {
                throw new AuraHandledException('You can only record collections against your own invoices.');
            }
            if (amount > nz(inv.Balance_Due__c)) {
                throw new AuraHandledException('Amount exceeds the invoice balance (' + nz(inv.Balance_Due__c) + ').');
            }
            coll.Invoice__c = inv.Id;
            coll.Account__c = inv.Account__c; // the debtor on the invoice
        } else {
            coll.Account__c = acctId; // on-account payment
            coll.Is_On_Account__c = true;
        }
        if (String.isNotBlank(reference)) {
            coll.Transaction_Reference__c = reference;
        }
        insert coll;
        return coll.Id;
    }

    // ── Secondary sale (distributor → retailer) ───────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<Account> getRetailers() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        if (acctId == null) {
            // Internal/admin: all retailers.
            return [
                SELECT Id, Name, BillingCity, Outstanding_Balance__c
                FROM Account WHERE Type = 'Retailer' AND Is_Active__c = true
                ORDER BY Name LIMIT 500
            ];
        }
        // A distributor's retailers are the ones parented to them, plus any they have
        // actually billed. The territory / org-wide fallbacks were removed: territory is
        // geographic and shared, so they offered up retailers served by other
        // distributors — and placeSecondarySale would then bill them.
        Set<Id> mine = new Set<Id>();
        for (AggregateResult ar : [
            SELECT Account__c a FROM Invoice__c
            WHERE Sold_From_Distributor__c = :acctId AND Account__c != null GROUP BY Account__c
        ]) {
            mine.add((Id) ar.get('a'));
        }
        return [
            SELECT Id, Name, BillingCity, Outstanding_Balance__c
            FROM Account
            WHERE Type = 'Retailer' AND Is_Active__c = true
              AND (ParentId = :acctId OR Id IN :mine)
            ORDER BY Name LIMIT 500
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Product_Extension__c> getProducts() {
        ensureEnabled();
        return [
            SELECT Id, Name, SKU_Code__c, Unit_Price__c, GST_Rate__c
            FROM Product_Extension__c
            WHERE Is_Active__c = true
            ORDER BY Name
            LIMIT 500
        ];
    }

    /**
     * @description Places a secondary sale (FEFO) from the running distributor's
     *              own stock to one of their retailers. Distributor = context
     *              account; never accepts a distributor id from the client.
     */
    @AuraEnabled
    public static Id placeSecondarySale(Id retailerId, String linesJson) {
        ensureEnabled();
        Id distributorId = requireAccountId();
        List<IndentLineInput> lines = toLineInputs(linesJson);
        if (retailerId == null || lines.isEmpty()) {
            throw new AuraHandledException('Select a retailer and at least one product.');
        }
        // You may only sell to a retailer you serve. Without this any portal distributor
        // could bill any retailer in the org out of their own stock.
        if (!isMyCustomer(distributorId, retailerId)) {
            throw new AuraHandledException('This retailer is not one of your customers.');
        }
        List<DMS_SecondaryBilling_Service.LineRequest> reqs =
            new List<DMS_SecondaryBilling_Service.LineRequest>();
        for (IndentLineInput li : lines) {
            if (String.isNotBlank(li.productId) && li.quantity != null && li.quantity > 0) {
                // Unit price null → service falls back to product master price.
                reqs.add(new DMS_SecondaryBilling_Service.LineRequest(Id.valueOf(li.productId), li.quantity, null));
            }
        }
        if (reqs.isEmpty()) {
            throw new AuraHandledException('No valid product lines.');
        }
        try {
            return DMS_SecondaryBilling_Service.createSecondaryInvoice(distributorId, retailerId, reqs);
        } catch (DMS_SecondaryBillingException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            // Surface the real cause (DML/validation) instead of a generic error.
            throw new AuraHandledException('Could not create invoice: ' + e.getMessage());
        }
    }

    /** The upstream supplier (parent Super Stockist) a P2 order would be placed on. */
    public class SupplierInfo {
        @AuraEnabled public Id supplierId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public String supplierTier;
        @AuraEnabled public Boolean canOrder = false;
    }

    @AuraEnabled(cacheable=true)
    public static SupplierInfo getSupplier() {
        ensureEnabled();
        SupplierInfo si = new SupplierInfo();
        Id acctId = scopeAccountId();
        if (acctId == null) {
            return si; // admin/internal: no single context account.
        }
        Account me = [
            SELECT ParentId, Parent.Name, Parent.Account_Tier__c
            FROM Account WHERE Id = :acctId
        ];
        if (me.ParentId != null) {
            si.supplierId = me.ParentId;
            si.supplierName = me.Parent.Name;
            si.supplierTier = me.Parent.Account_Tier__c;
            si.canOrder = true;
        }
        return si;
    }

    /**
     * @description Places a P2 order: the logged-in distributor buys from its parent
     *              Super Stockist's stock (FEFO), creating a P2 invoice and receiving
     *              the goods into the distributor's own stock.
     */
    @AuraEnabled
    public static Id placeP2Order(String linesJson) {
        ensureEnabled();
        Id distributorId = requireAccountId();
        List<IndentLineInput> lines = toLineInputs(linesJson);
        if (lines.isEmpty()) {
            throw new AuraHandledException('Select at least one product.');
        }
        Account me = [SELECT ParentId FROM Account WHERE Id = :distributorId];
        if (me.ParentId == null) {
            throw new AuraHandledException('No supplier (Super Stockist) is linked to your account.');
        }
        List<DMS_P2Fulfillment_Service.LineRequest> reqs = new List<DMS_P2Fulfillment_Service.LineRequest>();
        for (IndentLineInput li : lines) {
            if (String.isNotBlank(li.productId) && li.quantity != null && li.quantity > 0) {
                reqs.add(new DMS_P2Fulfillment_Service.LineRequest(Id.valueOf(li.productId), li.quantity, null));
            }
        }
        if (reqs.isEmpty()) {
            throw new AuraHandledException('No valid product lines.');
        }
        try {
            return DMS_P2Fulfillment_Service.createP2Invoice(me.ParentId, distributorId, reqs);
        } catch (DMS_SecondaryBillingException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Could not create P2 order: ' + e.getMessage());
        }
    }

    // ── Home dashboard (primary + secondary summary) ──────────────────────

    public class BrandStat {
        @AuraEnabled public String brand;
        @AuraEnabled public Decimal value;
        @AuraEnabled public Integer pct;
    }
    public class SchemeBanner {
        @AuraEnabled public String name;
        @AuraEnabled public String description;
        @AuraEnabled public String category;
    }
    public class HomeSummary {
        @AuraEnabled public Decimal purchased = 0;
        @AuraEnabled public Integer pendingOrders = 0;
        @AuraEnabled public Integer pendingGRN = 0;
        @AuraEnabled public Integer returnsCount = 0;
        @AuraEnabled public Integer claimsCount = 0;
        @AuraEnabled public List<BrandStat> brandStock = new List<BrandStat>();
        @AuraEnabled public Integer secondaryOrders = 0;
        @AuraEnabled public Integer secondaryPendingOrders = 0;
        @AuraEnabled public Integer secondaryReturns = 0;
        @AuraEnabled public Decimal collectionValue = 0;
        @AuraEnabled public Integer activeCustomers = 0;
        @AuraEnabled public List<BrandStat> brandSecondarySales = new List<BrandStat>();
        @AuraEnabled public List<SchemeBanner> schemes = new List<SchemeBanner>();
    }

    @AuraEnabled(cacheable=true)
    public static HomeSummary getHomeSummary(String period) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Date startDate = periodStart(period);
        String otPrimary = DMS_Constants.ORDER_TYPE_PRIMARY;
        String otSecondary = DMS_Constants.ORDER_TYPE_SECONDARY;
        String rtSecondary = DMS_Constants.RETURN_TYPE_SECONDARY;
        List<String> openStatuses = new List<String>{ 'Draft', 'Submitted', 'Approved' };
        Date nearCut = nearExpiryCutoff();

        HomeSummary s = new HomeSummary();

        // Primary purchased.
        String w = 'Order_Type__c = :otPrimary AND Invoice_Date__c >= :startDate'
            + (acctId == null ? '' : ' AND Account__c = :acctId');
        for (AggregateResult ar : Database.query('SELECT SUM(Total_Amount__c) t FROM Invoice__c WHERE ' + w)) {
            s.purchased = nz((Decimal) ar.get('t'));
        }

        s.pendingOrders = Database.countQuery('SELECT COUNT() FROM Primary_Order__c WHERE Status__c IN :openStatuses'
            + (acctId == null ? '' : ' AND Account__c = :acctId'));
        s.pendingGRN = Database.countQuery('SELECT COUNT() FROM GRN__c WHERE Status__c IN (\'Pending\',\'Partial\')'
            + (acctId == null ? '' : ' AND Account__c = :acctId'));
        s.returnsCount = Database.countQuery('SELECT COUNT() FROM Return_Order__c'
            + (acctId == null ? '' : ' WHERE (Account__c = :acctId OR Returned_To_Distributor__c = :acctId)'));
        s.claimsCount = Database.countQuery('SELECT COUNT() FROM Claim__c'
            + (acctId == null ? '' : ' WHERE Account__c = :acctId'));

        // Brand-wise stock (current snapshots).
        String bw = 'Is_Current__c = true AND Closing_Stock__c > 0 AND Product_Ext__r.Brand__c != null'
            + (acctId == null ? '' : ' AND Account__c = :acctId');
        s.brandStock = toBrandStats(Database.query(
            'SELECT Product_Ext__r.Brand__c b, SUM(Closing_Stock__c) v FROM Distributor_Stock__c WHERE '
            + bw + ' GROUP BY Product_Ext__r.Brand__c ORDER BY SUM(Closing_Stock__c) DESC'), 'v');

        // Secondary metrics.
        String sw = 'Order_Type__c = :otSecondary AND Invoice_Date__c >= :startDate'
            + (acctId == null ? '' : ' AND Sold_From_Distributor__c = :acctId');
        s.secondaryOrders = Database.countQuery('SELECT COUNT() FROM Invoice__c WHERE ' + sw);
        s.secondaryPendingOrders = Database.countQuery(
            'SELECT COUNT() FROM Invoice__c WHERE Order_Type__c = :otSecondary AND Status__c = \'Draft\''
            + (acctId == null ? '' : ' AND Sold_From_Distributor__c = :acctId'));
        s.secondaryReturns = Database.countQuery('SELECT COUNT() FROM Return_Order__c WHERE Return_Type__c = :rtSecondary'
            + (acctId == null ? '' : ' AND Returned_To_Distributor__c = :acctId'));

        for (AggregateResult ar : Database.query(
            'SELECT SUM(Amount__c) t FROM Collection__c WHERE Collection_Date__c >= :startDate'
            + (acctId == null ? '' : ' AND Account__c = :acctId'))) {
            s.collectionValue = nz((Decimal) ar.get('t'));
        }
        for (AggregateResult ar : Database.query(
            'SELECT COUNT_DISTINCT(Account__c) c FROM Invoice__c WHERE Order_Type__c = :otSecondary'
            + (acctId == null ? '' : ' AND Sold_From_Distributor__c = :acctId'))) {
            s.activeCustomers = (Integer) ar.get('c');
        }

        // Brand-wise secondary sales value.
        String bsw = 'Invoice__r.Order_Type__c = :otSecondary AND Invoice__r.Invoice_Date__c >= :startDate '
            + 'AND Product_Ext__r.Brand__c != null'
            + (acctId == null ? '' : ' AND Invoice__r.Sold_From_Distributor__c = :acctId');
        s.brandSecondarySales = toBrandStats(Database.query(
            'SELECT Product_Ext__r.Brand__c b, SUM(Total_Amount__c) v FROM Invoice_Line__c WHERE '
            + bsw + ' GROUP BY Product_Ext__r.Brand__c ORDER BY SUM(Total_Amount__c) DESC'), 'v');

        // Active schemes for the hero banner.
        for (Scheme__c sch : [
            SELECT Name, Description__c, Scheme_Category__c FROM Scheme__c
            WHERE Is_Active__c = true ORDER BY Start_Date__c DESC LIMIT 5
        ]) {
            SchemeBanner b = new SchemeBanner();
            b.name = sch.Name;
            b.description = sch.Description__c;
            b.category = sch.Scheme_Category__c;
            s.schemes.add(b);
        }
        return s;
    }

    // ── Tier dashboards (P1 / P2 / Secondary) ─────────────────────────────
    // Uniform KPI shape per distribution tier, scoped to the logged-in account
    // (admin/internal sees all). P1 = inbound from company, P2 = the super-stockist
    // <-> distributor middle tier, Secondary = distributor -> retailer.
    public class TierDashboard {
        @AuraEnabled public String tier;
        @AuraEnabled public Decimal orderValue = 0;     // net (subtotal)
        @AuraEnabled public Decimal invoiceValue = 0;   // gross (total)
        @AuraEnabled public Integer orderCount = 0;
        @AuraEnabled public Integer grnPending = 0;
        @AuraEnabled public Integer invoiceCount = 0;
        @AuraEnabled public Integer returnsCount = 0;
        // Secondary KPI strip
        @AuraEnabled public Decimal avgOrderValue = 0;
        @AuraEnabled public Decimal outstanding = 0;
        @AuraEnabled public Decimal collectionValue = 0;
        @AuraEnabled public Decimal stockValue = 0;
        @AuraEnabled public Integer nearExpirySkus = 0;
        @AuraEnabled public Decimal creditLimit = 0;
        @AuraEnabled public Decimal creditAvailable = 0;
        @AuraEnabled public Integer activeParties = 0;
        @AuraEnabled public Integer claimsOpen = 0;
        // Charts + detail
        @AuraEnabled public List<BrandStat> brandOrders = new List<BrandStat>();
        @AuraEnabled public List<BrandStat> brandValue = new List<BrandStat>();
        @AuraEnabled public Map<String, Decimal> aging;
        @AuraEnabled public List<ProductStat> topProducts = new List<ProductStat>();
        @AuraEnabled public List<RecentInvoice> recentInvoices = new List<RecentInvoice>();
    }
    public class ProductStat {
        @AuraEnabled public String name;
        @AuraEnabled public String brand;
        @AuraEnabled public Decimal qty;
        @AuraEnabled public Decimal value;
        @AuraEnabled public Integer pct;
    }
    public class RecentInvoice {
        @AuraEnabled public String invoiceNumber;
        @AuraEnabled public Date invoiceDate;
        @AuraEnabled public String party;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal balance;
        @AuraEnabled public String status;
    }

    @AuraEnabled(cacheable=true)
    public static TierDashboard getTierDashboard(String tier, String period, String dim) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Date startDate = periodStart(period);

        // Tier is expressed in our real Order_Type vocabulary: 'Primary' / 'Secondary'.
        // 'P2' is still honoured for a 3-tier (super-stockist) org; any other value
        // (incl. the legacy 'P1' alias) is treated as Primary.
        Boolean isSecondary = (tier == DMS_Constants.ORDER_TYPE_SECONDARY);
        Boolean isP2 = (tier == DMS_Constants.ORDER_TYPE_P2);
        Boolean isPrimary = !isSecondary && !isP2;

        // Order-analysis grouping dimension, whitelisted to our own product fields.
        String dimPath =
            (dim == 'category')      ? 'Product_Ext__r.Product_Category__r.Name'
            : (dim == 'subcategory') ? 'Product_Ext__r.Sub_Category__r.Name'
            : 'Product_Ext__r.Brand__c';

        TierDashboard d = new TierDashboard();
        d.tier = tier;

        // Order_Type + account scoping clause for this tier's invoices.
        String ot;
        String acctClause;
        if (isP2) {
            ot = DMS_Constants.ORDER_TYPE_P2;
            acctClause = (acctId == null ? '' : ' AND (Account__c = :acctId OR Sold_From_Distributor__c = :acctId)');
        } else if (isSecondary) {
            ot = DMS_Constants.ORDER_TYPE_SECONDARY;
            acctClause = (acctId == null ? '' : ' AND (Sold_From_Distributor__c = :acctId OR Account__c = :acctId)');
        } else {
            ot = DMS_Constants.ORDER_TYPE_PRIMARY;
            acctClause = (acctId == null ? '' : ' AND Account__c = :acctId');
        }

        // Invoice value + count + open balance.
        for (AggregateResult ar : Database.query(
            'SELECT SUM(Subtotal__c) sub, SUM(Total_Amount__c) tot, SUM(Balance_Due__c) bal, COUNT(Id) c FROM Invoice__c '
            + 'WHERE Order_Type__c = :ot AND Invoice_Date__c >= :startDate' + acctClause)) {
            d.orderValue = nz((Decimal) ar.get('sub'));
            d.invoiceValue = nz((Decimal) ar.get('tot'));
            d.outstanding = nz((Decimal) ar.get('bal'));
            d.invoiceCount = (Integer) ar.get('c');
        }
        d.avgOrderValue = (d.invoiceCount > 0) ? (d.invoiceValue / d.invoiceCount).setScale(2) : 0;

        // Order count: primary orders for Primary/P2, invoices for Secondary.
        if (isSecondary) {
            d.orderCount = d.invoiceCount;
            d.returnsCount = Database.countQuery(
                'SELECT COUNT() FROM Return_Order__c WHERE Return_Type__c = \'' + DMS_Constants.RETURN_TYPE_SECONDARY + '\''
                + (acctId == null ? '' : ' AND (Returned_To_Distributor__c = :acctId OR Account__c = :acctId)'));
        } else if (isP2) {
            d.orderCount = Database.countQuery('SELECT COUNT() FROM Invoice__c WHERE Order_Type__c = \'P2\''
                + (acctId == null ? '' : ' AND (Account__c = :acctId OR Sold_From_Distributor__c = :acctId)'));
        } else {
            d.orderCount = Database.countQuery(
                'SELECT COUNT() FROM Primary_Order__c'
                + (acctId == null ? '' : ' WHERE Account__c = :acctId'));
            d.returnsCount = Database.countQuery(
                'SELECT COUNT() FROM Return_Order__c WHERE Return_Type__c = \'' + DMS_Constants.RETURN_TYPE_PRIMARY + '\''
                + (acctId == null ? '' : ' AND Account__c = :acctId'));
        }

        // GRN pending against this tier's invoices (none for Secondary).
        if (!isSecondary) {
            d.grnPending = Database.countQuery(
                'SELECT COUNT() FROM GRN__c WHERE Status__c IN (\'Pending\',\'Partial\') '
                + 'AND Invoice__r.Order_Type__c = :ot'
                + (acctId == null ? '' : ' AND Account__c = :acctId'));
        }

        // Counterparties active in this tier (customers for Secondary, distributors for P2).
        for (AggregateResult ar : Database.query(
            'SELECT COUNT_DISTINCT(Account__c) c FROM Invoice__c WHERE Order_Type__c = :ot '
            + 'AND Invoice_Date__c >= :startDate' + acctClause)) {
            d.activeParties = (Integer) ar.get('c');
        }

        // Period collections + open claims (account context).
        for (AggregateResult ar : Database.query(
            'SELECT SUM(Amount__c) t FROM Collection__c WHERE Collection_Date__c >= :startDate'
            + (acctId == null ? '' : ' AND Account__c = :acctId'))) {
            d.collectionValue = nz((Decimal) ar.get('t'));
        }
        d.claimsOpen = Database.countQuery('SELECT COUNT() FROM Claim__c WHERE Status__c NOT IN (\'Settled\',\'Rejected\',\'Cancelled\')'
            + (acctId == null ? '' : ' AND Account__c = :acctId'));

        // My current stock value + near-expiry SKUs (inventory health).
        Date nearCut = nearExpiryCutoff();
        Map<Id, Decimal> stockByProd = new Map<Id, Decimal>();
        Set<Id> nearExpiryProds = new Set<Id>();
        String sw = 'Is_Current__c = true AND Closing_Stock__c > 0 AND Product_Ext__c != null'
            + (acctId == null ? '' : ' AND Account__c = :acctId');
        for (Distributor_Stock__c ds : Database.query(
            'SELECT Product_Ext__c, Closing_Stock__c, Expiry_Date__c, Product_Ext__r.Unit_Price__c '
            + 'FROM Distributor_Stock__c WHERE ' + sw + ' LIMIT 5000')) {
            d.stockValue += nz(ds.Closing_Stock__c) * nz(ds.Product_Ext__r.Unit_Price__c);
            if (ds.Expiry_Date__c != null && ds.Expiry_Date__c <= nearCut) {
                nearExpiryProds.add(ds.Product_Ext__c);
            }
        }
        d.nearExpirySkus = nearExpiryProds.size();

        // Credit position (distributor context).
        if (acctId != null) {
            Account me = [SELECT Credit_Limit__c, Outstanding_Balance__c FROM Account WHERE Id = :acctId];
            d.creditLimit = nz(me.Credit_Limit__c);
            d.creditAvailable = d.creditLimit - nz(me.Outstanding_Balance__c);
        }

        // AR aging across this tier's open invoices.
        d.aging = new Map<String, Decimal>{ 'Current' => 0, '1-30' => 0, '31-60' => 0, '61-90' => 0, '90+' => 0 };
        Date today = Date.today();
        for (Invoice__c inv : Database.query(
            'SELECT Balance_Due__c, Due_Date__c, Invoice_Date__c FROM Invoice__c '
            + 'WHERE Order_Type__c = :ot AND Balance_Due__c > 0' + acctClause + ' LIMIT 5000')) {
            Date due = inv.Due_Date__c != null ? inv.Due_Date__c : inv.Invoice_Date__c;
            Integer od = (due == null) ? 0 : due.daysBetween(today);
            String b = od <= 0 ? 'Current' : od <= 30 ? '1-30' : od <= 60 ? '31-60' : od <= 90 ? '61-90' : '90+';
            d.aging.put(b, d.aging.get(b) + nz(inv.Balance_Due__c));
        }

        // Dimension-wise order count + value, and top products, from this tier's invoice lines.
        String blScope = (acctId == null) ? '' :
            (isPrimary ? ' AND Invoice__r.Account__c = :acctId'
             : ' AND (Invoice__r.Sold_From_Distributor__c = :acctId OR Invoice__r.Account__c = :acctId)');
        List<AggregateResult> brandRows = Database.query(
            'SELECT ' + dimPath + ' b, COUNT_DISTINCT(Invoice__c) c, SUM(Total_Amount__c) v '
            + 'FROM Invoice_Line__c WHERE Invoice__r.Order_Type__c = :ot '
            + 'AND Invoice__r.Invoice_Date__c >= :startDate AND ' + dimPath + ' != null'
            + blScope + ' GROUP BY ' + dimPath + ' ORDER BY SUM(Total_Amount__c) DESC');
        d.brandOrders = toBrandStats(brandRows, 'c');
        d.brandValue = toBrandStats(brandRows, 'v');

        List<AggregateResult> prodRows = Database.query(
            'SELECT Product_Ext__r.Name n, Product_Ext__r.Brand__c b, SUM(Quantity__c) q, SUM(Total_Amount__c) v '
            + 'FROM Invoice_Line__c WHERE Invoice__r.Order_Type__c = :ot '
            + 'AND Invoice__r.Invoice_Date__c >= :startDate AND Product_Ext__c != null'
            + blScope + ' GROUP BY Product_Ext__r.Name, Product_Ext__r.Brand__c '
            + 'ORDER BY SUM(Total_Amount__c) DESC LIMIT 5');
        Decimal topMax = 0;
        for (AggregateResult ar : prodRows) { if (toDecimal(ar.get('v')) > topMax) { topMax = toDecimal(ar.get('v')); } }
        for (AggregateResult ar : prodRows) {
            ProductStat ps = new ProductStat();
            ps.name = (String) ar.get('n');
            ps.brand = (String) ar.get('b');
            ps.qty = toDecimal(ar.get('q'));
            ps.value = toDecimal(ar.get('v'));
            ps.pct = (topMax > 0) ? (Integer) ((ps.value / topMax) * 100).round() : 0;
            d.topProducts.add(ps);
        }

        // Recent invoices for this tier.
        for (Invoice__c inv : Database.query(
            'SELECT Invoice_Number__c, Invoice_Date__c, Account__r.Name, Total_Amount__c, Balance_Due__c, Status__c '
            + 'FROM Invoice__c WHERE Order_Type__c = :ot' + acctClause
            + ' ORDER BY Invoice_Date__c DESC LIMIT 6')) {
            RecentInvoice ri = new RecentInvoice();
            ri.invoiceNumber = inv.Invoice_Number__c;
            ri.invoiceDate = inv.Invoice_Date__c;
            ri.party = inv.Account__r != null ? inv.Account__r.Name : '';
            ri.amount = inv.Total_Amount__c;
            ri.balance = inv.Balance_Due__c;
            ri.status = inv.Status__c;
            d.recentInvoices.add(ri);
        }
        return d;
    }

    private static List<BrandStat> toBrandStats(List<AggregateResult> rows, String valAlias) {
        List<BrandStat> stats = new List<BrandStat>();
        Decimal maxVal = 0;
        for (AggregateResult ar : rows) {
            Decimal v = toDecimal(ar.get(valAlias));
            if (v > maxVal) { maxVal = v; }
        }
        for (AggregateResult ar : rows) {
            BrandStat bs = new BrandStat();
            bs.brand = (String) ar.get('b');
            bs.value = toDecimal(ar.get(valAlias));
            bs.pct = (maxVal > 0) ? (Integer) ((bs.value / maxVal) * 100).round() : 0;
            stats.add(bs);
        }
        return stats;
    }

    // Safe Object->Decimal (AggregateResult SUM is Decimal, COUNT_DISTINCT is Integer).
    private static Decimal toDecimal(Object o) {
        return o == null ? 0 : Decimal.valueOf(String.valueOf(o));
    }

    // Stock near-expiry cutoff date (admin-configurable via DMS_Config).
    private static Date nearExpiryCutoff() { return Date.today().addDays(DMS_Config.nearExpiryDays()); }

    private static Date periodStart(String period) {
        Date today = Date.today();
        if (period == 'THIS_WEEK') { return today.toStartOfWeek(); }
        if (period == 'LAST_WEEK') { return today.toStartOfWeek().addDays(-7); }
        if (period == 'THIS_QUARTER') {
            Integer q = (today.month() - 1) / 3;
            return Date.newInstance(today.year(), q * 3 + 1, 1);
        }
        if (period == 'THIS_YEAR') { return Date.newInstance(today.year(), 1, 1); }
        if (period == 'LAST_JC') { return today.toStartOfMonth().addMonths(-1); }
        return today.toStartOfMonth(); // THIS_JC default
    }

    // ── Products catalog + Schemes & Offers ───────────────────────────────

    public class ProductRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String sku;
        @AuraEnabled public String name;
        @AuraEnabled public String brand;
        @AuraEnabled public String category;
        @AuraEnabled public String packSize;
        @AuraEnabled public Decimal mrp;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal gstRate;
        @AuraEnabled public Decimal caseSize;
        @AuraEnabled public String baseUomCode;
        @AuraEnabled public String baseUomName;
        @AuraEnabled public String caseUomCode;
        @AuraEnabled public String caseUomName;
        @AuraEnabled public Decimal unitsPerCase;   // base units per case (0 = no case pack)
        @AuraEnabled public Decimal distPriceCase;
        @AuraEnabled public Decimal onHand;
        @AuraEnabled public String stockStatus;
        @AuraEnabled public String imageUrl;
        @AuraEnabled public String hsnCode;
        @AuraEnabled public String ean;
        @AuraEnabled public Decimal minOrderQty;
        @AuraEnabled public Boolean fromPriceList = false;
        @AuraEnabled public List<DMS_Pricing_Service.PriceTier> priceTiers;
    }

    @AuraEnabled(cacheable=true)
    public static List<ProductRow> getProductCatalog() {
        ensureEnabled();
        Id acctId = scopeAccountId();

        // Current distributor on-hand per product (scoped or org-wide).
        Map<Id, Decimal> onHand = new Map<Id, Decimal>();
        String w = 'Is_Current__c = true AND Product_Ext__c != null'
            + (acctId == null ? '' : ' AND Account__c = :acctId');
        for (AggregateResult ar : Database.query(
            'SELECT Product_Ext__c p, SUM(Closing_Stock__c) s FROM Distributor_Stock__c WHERE '
            + w + ' GROUP BY Product_Ext__c')) {
            onHand.put((Id) ar.get('p'), (Decimal) ar.get('s'));
        }

        List<Product_Extension__c> products = [
            SELECT Id, Name, SKU_Code__c, Brand__c, Product_Category__r.Name, Weight__c, Weight_Unit__c,
                   Case_Size__c, MRP__c, Unit_Price__c, GST_Rate__c, Product_Image_URL__c,
                   HSN_SAC_Code__c, Barcode_EAN__c, Min_Order_Qty__c,
                   Base_UOM__c, Base_UOM__r.UOM_Code__c, Base_UOM__r.Name,
                   Secondary_UOM__c, Secondary_UOM__r.UOM_Code__c, Secondary_UOM__r.Name
            FROM Product_Extension__c
            WHERE Is_Active__c = true
            ORDER BY Brand__c NULLS LAST, Name
            LIMIT 2000
        ];
        // Resolve distributor-specific price-list pricing (with qty tiers); falls back to master.
        Map<Id, DMS_Pricing_Service.ProductPrice> priced =
            DMS_Pricing_Service.resolve(new Map<Id, Product_Extension__c>(products).keySet(), acctId);

        List<ProductRow> rows = new List<ProductRow>();
        for (Product_Extension__c p : products) {
            ProductRow r = new ProductRow();
            r.id = p.Id;
            r.sku = p.SKU_Code__c;
            r.name = p.Name;
            r.brand = p.Brand__c;
            r.category = p.Product_Category__r != null ? p.Product_Category__r.Name : null;
            r.packSize = p.Weight__c != null ? String.valueOf(p.Weight__c) + (p.Weight_Unit__c != null ? p.Weight_Unit__c : '') : null;
            r.mrp = p.MRP__c;
            DMS_Pricing_Service.ProductPrice pp = priced.get(p.Id);
            Decimal effPrice = (pp != null) ? pp.listPrice : p.Unit_Price__c;
            r.unitPrice = effPrice;
            r.fromPriceList = (pp != null) && pp.fromPriceList;
            r.priceTiers = (pp != null) ? pp.tiers : null;
            r.gstRate = p.GST_Rate__c;
            r.caseSize = p.Case_Size__c;
            // ── Real UOM model: base unit + case pack via the conversion master ──
            r.baseUomCode = (p.Base_UOM__c != null && String.isNotBlank(p.Base_UOM__r.UOM_Code__c))
                ? p.Base_UOM__r.UOM_Code__c : 'PCS';
            r.baseUomName = (p.Base_UOM__c != null && String.isNotBlank(p.Base_UOM__r.Name))
                ? p.Base_UOM__r.Name : 'Piece';
            r.caseUomCode = (p.Secondary_UOM__c != null && String.isNotBlank(p.Secondary_UOM__r.UOM_Code__c))
                ? p.Secondary_UOM__r.UOM_Code__c : 'CS';
            r.caseUomName = (p.Secondary_UOM__c != null && String.isNotBlank(p.Secondary_UOM__r.Name))
                ? p.Secondary_UOM__r.Name : 'Case';
            // Units of the base UOM contained in one case (case → base conversion).
            // Prefer the UOM_Conversion master; fall back to Case_Size__c.
            Decimal upc = UOM_Conversion_Service.getConversionFactor(p.Id, r.caseUomCode, r.baseUomCode);
            if (upc == null || upc <= 1) { upc = nz(p.Case_Size__c); }
            r.unitsPerCase = (upc != null && upc > 1) ? upc : 0; // 0 → no case option, pieces only
            r.distPriceCase = nz(effPrice) * r.unitsPerCase;
            r.onHand = onHand.containsKey(p.Id) ? onHand.get(p.Id) : 0;
            r.stockStatus = r.onHand <= 0 ? 'Out of Stock' : (r.onHand < DMS_Config.lowStockThreshold() ? 'Low' : 'In Stock');
            r.imageUrl = p.Product_Image_URL__c;
            r.hsnCode = p.HSN_SAC_Code__c;
            r.ean = p.Barcode_EAN__c;
            r.minOrderQty = p.Min_Order_Qty__c;
            rows.add(r);
        }
        return rows;
    }

    public class ProductClassInfo {
        @AuraEnabled public Id productId;
        @AuraEnabled public String classification;   // 'Must Sell' | 'Focused Sell'
        @AuraEnabled public Decimal minQty = 0;
    }

    /**
     * Product priority classification (Must Sell / Focused Sell) + minimum quantity
     * for the logged-in distributor, so the order screen can badge products, auto-add
     * must-sell items and enforce minimums — like the SFA order form.
     * Sources: Must_Sell_Config__c (targeted by the distributor's territory / channel /
     * outlet type) and Scheme_Product__c.Product_Classification__c on active schemes.
     * Must Sell takes precedence over Focused Sell; the larger min qty is kept.
     */
    @AuraEnabled(cacheable=true)
    public static List<ProductClassInfo> getProductClassifications() {
        ensureEnabled();
        Id acctId = scopeAccountId();
        Map<Id, ProductClassInfo> byProduct = new Map<Id, ProductClassInfo>();
        Date today = Date.today();

        String channel = '', custType = '';
        Id terr = null;
        if (acctId != null) {
            List<Account> a = [SELECT Channel__c, Outlet_Type__c, Territory__c FROM Account WHERE Id = :acctId];
            if (!a.isEmpty()) {
                channel = a[0].Channel__c != null ? a[0].Channel__c : '';
                custType = a[0].Outlet_Type__c != null ? a[0].Outlet_Type__c : '';
                terr = a[0].Territory__c;
            }
        }

        // 1. Account-targeted Must-Sell configuration.
        for (Must_Sell_Config__c cfg : [
            SELECT Product_Ext__c, Classification__c, Min_Qty__c, Territory__c, Channel__c, Customer_Type__c
            FROM Must_Sell_Config__c
            WHERE Is_Active__c = true AND Start_Date__c <= :today AND End_Date__c >= :today
              AND Product_Ext__c != null
        ]) {
            if (cfg.Territory__c != null && cfg.Territory__c != terr) { continue; }
            if (String.isNotBlank(cfg.Channel__c) && cfg.Channel__c != channel) { continue; }
            if (String.isNotBlank(cfg.Customer_Type__c) && cfg.Customer_Type__c != custType) { continue; }
            applyClass(byProduct, cfg.Product_Ext__c, cfg.Classification__c, cfg.Min_Qty__c);
        }

        // 2. Scheme-driven product classification (active schemes).
        for (Scheme_Product__c sp : [
            SELECT Product_Ext__c, Product_Classification__c, Min_Quantity__c
            FROM Scheme_Product__c
            WHERE Product_Classification__c IN ('Must Sell', 'Focused Sell')
              AND Product_Ext__c != null AND Scheme__r.Is_Active__c = true
        ]) {
            applyClass(byProduct, sp.Product_Ext__c, sp.Product_Classification__c, sp.Min_Quantity__c);
        }
        return byProduct.values();
    }

    /** Assign a classification (Must Sell wins) and keep the larger min qty. */
    private static void applyClass(Map<Id, ProductClassInfo> m, Id pid, String cls, Decimal minQty) {
        if (pid == null || String.isBlank(cls)) { return; }
        ProductClassInfo info = m.get(pid);
        if (info == null) {
            info = new ProductClassInfo();
            info.productId = pid;
            info.classification = cls;
            info.minQty = nz(minQty);
            m.put(pid, info);
            return;
        }
        if (cls == 'Must Sell') { info.classification = 'Must Sell'; }
        if (nz(minQty) > nz(info.minQty)) { info.minQty = nz(minQty); }
    }

    @AuraEnabled(cacheable=true)
    public static List<Distributor_Stock__c> getProductStock(Id productId) {
        ensureEnabled();
        Id acctId = scopeAccountId();
        String w = 'Product_Ext__c = :productId AND Is_Current__c = true AND Closing_Stock__c > 0'
            + (acctId == null ? '' : ' AND Account__c = :acctId');
        return Database.query(
            'SELECT Id, Account__r.Name, Batch_No__c, Closing_Stock__c, Expiry_Date__c '
            + 'FROM Distributor_Stock__c WHERE ' + w + ' ORDER BY Expiry_Date__c ASC NULLS LAST');
    }

    public class SchemeRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String code;
        @AuraEnabled public String category;       // Scheme_Category__c (for colour badge)
        @AuraEnabled public String schemeType;     // Scheme_Type__c
        @AuraEnabled public String description;
        @AuraEnabled public String status;         // portal lifecycle: Active / Expiring Soon / Upcoming / Expired
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public String channel;
        @AuraEnabled public Decimal priority;
        @AuraEnabled public String benefitSummary;
        @AuraEnabled public String triggerSummary;
        @AuraEnabled public Decimal budgetAmount;
        @AuraEnabled public List<String> products = new List<String>();
        // Numeric benefit data so the order-entry UI can compute a header-level
        // discount / free quantity for a line.
        @AuraEnabled public Decimal discountPercent;
        @AuraEnabled public Decimal discountValue;   // Price_Discount__c or Discount_Amount__c
        @AuraEnabled public Decimal freeQty;          // Free_Quantity__c per buy-set
        @AuraEnabled public Decimal buyQty;           // Min_Quantity__c (Buy X)
        @AuraEnabled public Decimal minValue;         // MOV__c (min order value)
        @AuraEnabled public String freeProductName;
    }
    public class SchemeList {
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer active = 0;
        @AuraEnabled public Integer expiringSoon = 0;
        @AuraEnabled public Integer upcoming = 0;
        @AuraEnabled public Decimal activeBudget = 0;
        @AuraEnabled public List<SchemeRow> schemes = new List<SchemeRow>();
    }

    @AuraEnabled(cacheable=true)
    public static SchemeList getSchemes() {
        ensureEnabled();
        Date today = Date.today();
        Date soon = today.addDays(30);
        SchemeList sl = new SchemeList();

        for (Scheme__c s : [
            SELECT Id, Name, Scheme_Code__c, Scheme_Category__c, Scheme_Type__c, Description__c,
                   Start_Date__c, End_Date__c, Is_Active__c, Priority__c, Applicable_Channel__c,
                   Budget_Amount__c, Free_Quantity__c, Free_Product_Ext__r.Name,
                   Discount_Percent__c, Price_Discount__c, Discount_Amount__c, Reward_Points__c,
                   Min_Quantity__c, MOV__c, Invoice_Qty_Threshold__c, Invoice_Val_Threshold__c,
                   (SELECT Product_Ext__r.Name FROM Scheme_Products__r WHERE Is_Buy_Product__c = true LIMIT 3)
            FROM Scheme__c
            ORDER BY End_Date__c NULLS LAST
        ]) {
            SchemeRow r = new SchemeRow();
            r.id = s.Id;
            r.name = s.Name;
            r.code = s.Scheme_Code__c;
            r.category = s.Scheme_Category__c;
            r.schemeType = s.Scheme_Type__c;
            r.description = s.Description__c;
            r.startDate = s.Start_Date__c;
            r.endDate = s.End_Date__c;
            r.channel = String.isNotBlank(s.Applicable_Channel__c) ? s.Applicable_Channel__c : 'All';
            r.priority = s.Priority__c;
            r.budgetAmount = s.Budget_Amount__c;
            r.benefitSummary = schemeBenefit(s);
            r.triggerSummary = schemeTrigger(s);
            r.discountPercent = s.Discount_Percent__c;
            r.discountValue = s.Price_Discount__c != null ? s.Price_Discount__c : s.Discount_Amount__c;
            r.freeQty = s.Free_Quantity__c;
            r.buyQty = s.Min_Quantity__c;
            r.minValue = s.MOV__c;
            r.freeProductName = s.Free_Product_Ext__r != null ? s.Free_Product_Ext__r.Name : null;
            if (s.Scheme_Products__r != null) {
                for (Scheme_Product__c sp : s.Scheme_Products__r) {
                    if (sp.Product_Ext__r != null) { r.products.add(sp.Product_Ext__r.Name); }
                }
            }

            if (s.Start_Date__c != null && s.Start_Date__c > today) {
                r.status = 'Upcoming';
                sl.upcoming++;
            } else if (s.Is_Active__c) {
                sl.active++;
                sl.activeBudget += nz(s.Budget_Amount__c);
                if (s.End_Date__c != null && s.End_Date__c <= soon) {
                    r.status = 'Expiring Soon';
                    sl.expiringSoon++;
                } else {
                    r.status = 'Active';
                }
            } else {
                r.status = 'Expired';
            }
            sl.schemes.add(r);
            sl.total++;
        }
        return sl;
    }

    private static String money(Decimal v) {
        return '₹' + String.valueOf(nz(v).setScale(0, System.RoundingMode.HALF_UP));
    }

    private static String schemeBenefit(Scheme__c s) {
        String cat = s.Scheme_Category__c;
        if (cat == 'Free Products') {
            String nm = s.Free_Product_Ext__r != null ? s.Free_Product_Ext__r.Name : 'product';
            return 'Get ' + String.valueOf((Integer) nz(s.Free_Quantity__c)) + ' ' + nm + ' free';
        } else if (cat == 'Discount in %') {
            return String.valueOf(nz(s.Discount_Percent__c)) + '% discount';
        } else if (cat == 'Discount in Value') {
            Decimal off = s.Price_Discount__c != null ? s.Price_Discount__c : s.Discount_Amount__c;
            return money(off) + ' off';
        } else if (cat == 'Reward Points') {
            return String.valueOf((Integer) nz(s.Reward_Points__c)) + ' reward points';
        }
        return '';
    }

    private static String schemeTrigger(Scheme__c s) {
        String t = s.Scheme_Type__c;
        if (t == 'Same Product (QTY)') { return 'Min ' + String.valueOf((Integer) nz(s.Min_Quantity__c)) + ' qty'; }
        if (t == 'Same Product (VAL)') { return 'MOV ' + money(s.MOV__c); }
        if (t == 'Assorted Product (QTY)') { return 'Assorted (qty)'; }
        if (t == 'Assorted Product (VAL)') { return 'Assorted (val)'; }
        if (t == 'Invoice Qty Based') { return 'Inv qty ' + String.valueOf((Integer) nz(s.Invoice_Qty_Threshold__c)); }
        if (t == 'Invoice Val Based') { return 'Inv val ' + money(s.Invoice_Val_Threshold__c); }
        return t != null ? t : '';
    }
}