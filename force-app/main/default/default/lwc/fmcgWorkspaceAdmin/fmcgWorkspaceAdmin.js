import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAllProfiles from '@salesforce/apex/FMCGWorkspaceConfigController.getAllProfiles';
import getComponentMaster from '@salesforce/apex/FMCGWorkspaceConfigController.getComponentMaster';
import getConfigForProfile from '@salesforce/apex/FMCGWorkspaceConfigController.getConfigForProfile';
import saveConfig from '@salesforce/apex/FMCGWorkspaceConfigController.saveConfig';

const ALL_TABS = 'all';

export default class FmcgWorkspaceAdmin extends LightningElement {
    @track profiles = [];
    @track selectedProfile = '';
    @track master = [];
    @track visibility = {};
    @track isLoading = true;
    @track isSaving = false;
    @track searchTerm = '';
    @track activeTabFilter = ALL_TABS;

    connectedCallback() {
        this.bootstrap();
    }

    async bootstrap() {
        this.isLoading = true;
        try {
            const [profiles, master] = await Promise.all([
                getAllProfiles(),
                getComponentMaster()
            ]);
            this.profiles = (profiles || []).map(p => ({ label: p.name, value: p.name }));
            this.master = master || [];
            if (this.profiles.length > 0) {
                this.selectedProfile = this.profiles[0].value;
                await this.loadProfileConfig();
            }
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isLoading = false;
    }

    async handleProfileChange(event) {
        this.selectedProfile = event.detail.value;
        await this.loadProfileConfig();
    }

    async loadProfileConfig() {
        if (!this.selectedProfile) return;
        this.isLoading = true;
        try {
            this.visibility = await getConfigForProfile({ profileName: this.selectedProfile }) || {};
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isLoading = false;
    }

    handleSearch(event) {
        this.searchTerm = (event.target.value || '').toLowerCase();
    }

    handleTabFilterClick(event) {
        this.activeTabFilter = event.currentTarget.dataset.tab;
    }

    handleToggleCard(event) {
        const key = event.currentTarget.dataset.key;
        const next = { ...this.visibility };
        next[key] = !next[key];
        this.visibility = next;
    }

    handleSectionAddAll(event) {
        event.stopPropagation();
        const tab = event.currentTarget.dataset.tab;
        const section = event.currentTarget.dataset.section;
        const next = { ...this.visibility };
        this.master.forEach(c => {
            if (c.tab === tab && c.section === section) next[c.key] = true;
        });
        this.visibility = next;
    }

    handleSectionClear(event) {
        event.stopPropagation();
        const tab = event.currentTarget.dataset.tab;
        const section = event.currentTarget.dataset.section;
        const next = { ...this.visibility };
        this.master.forEach(c => {
            if (c.tab === tab && c.section === section) next[c.key] = false;
        });
        this.visibility = next;
    }

    handleSelectAll() {
        const next = {};
        this.master.forEach(c => { next[c.key] = true; });
        this.visibility = next;
    }

    handleClearAll() {
        const next = {};
        this.master.forEach(c => { next[c.key] = false; });
        this.visibility = next;
    }

    async handleSave() {
        if (!this.selectedProfile) {
            this.toast('Pick a profile', 'Select a profile before saving.', 'warning');
            return;
        }
        const visibleKeys = this.master.filter(c => this.visibility[c.key]).map(c => c.key);
        this.isSaving = true;
        try {
            await saveConfig({ profileName: this.selectedProfile, visibleKeys });
            this.toast('Saved', `Configuration saved for ${this.selectedProfile}.`, 'success');
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        }
        this.isSaving = false;
    }

    // ── Tab filter pills ──
    get tabFilterPills() {
        const tabs = [
            { key: ALL_TABS,    label: 'All',           dotColor: 'gray'   },
            { key: 'tab',       label: 'Tabs',          dotColor: 'gray'   },
            { key: 'dashboard', label: 'Dashboard',     dotColor: 'blue'   },
            { key: 'field_ops', label: 'Field Ops',     dotColor: 'green'  },
            { key: 'sales',     label: 'Sales',         dotColor: 'orange' },
            { key: 'inventory', label: 'Inventory',     dotColor: 'purple' },
            { key: 'hr',        label: 'HR & Expense',  dotColor: 'teal'   },
            { key: 'admin',     label: 'Admin',         dotColor: 'red'    }
        ];
        return tabs.map(t => ({
            key: t.key,
            label: t.label,
            cssClass: 'fw-tab-item' + (t.key === this.activeTabFilter ? ' fw-tab-active' : ''),
            dotClass: 'fw-tab-dot fw-tab-dot-' + t.dotColor
        }));
    }

    // ── Grouped sections for rendering ──
    get groupedSections() {
        const tabOrder = ['tab', 'dashboard', 'field_ops', 'sales', 'inventory', 'hr', 'admin'];
        const tabLabel = {
            tab: 'Tabs (sub-tab visibility)',
            dashboard: 'Dashboard',
            field_ops: 'Field Ops',
            sales: 'Sales',
            inventory: 'Inventory',
            hr: 'HR & Expense',
            admin: 'Admin'
        };
        const groups = {};
        for (const c of this.master) {
            // Filter by active tab
            if (this.activeTabFilter !== ALL_TABS && c.tab !== this.activeTabFilter) continue;
            // Filter by search
            if (this.searchTerm && !c.label.toLowerCase().includes(this.searchTerm)) continue;

            if (!groups[c.tab]) {
                groups[c.tab] = { tab: c.tab, tabLabel: tabLabel[c.tab] || c.tab, sections: {} };
            }
            if (!groups[c.tab].sections[c.section]) {
                groups[c.tab].sections[c.section] = {
                    sectionKey: c.tab + '_' + c.section,
                    sectionLabel: c.section,
                    tab: c.tab,
                    section: c.section,
                    items: [],
                    selectedCount: 0,
                    totalCount: 0
                };
            }
            const isSelected = !!this.visibility[c.key];
            groups[c.tab].sections[c.section].totalCount++;
            if (isSelected) groups[c.tab].sections[c.section].selectedCount++;
            groups[c.tab].sections[c.section].items.push({
                ...c,
                isSelected,
                cardClass: 'fw-card fw-card-' + c.color + (isSelected ? ' fw-card-selected' : ''),
                iconCircleClass: 'fw-icon fw-icon-' + c.color,
                actionBtnClass: 'fw-action-btn' + (isSelected ? ' fw-action-btn-added' : ''),
                actionIconName: isSelected ? 'utility:check' : 'utility:add'
            });
        }
        // Add section count badges
        const result = [];
        for (const t of tabOrder) {
            if (!groups[t]) continue;
            const sections = Object.values(groups[t].sections).map(s => ({
                ...s,
                countBadge: s.selectedCount + '/' + s.totalCount,
                countBadgeClass: 'fw-section-badge' +
                    (s.selectedCount === s.totalCount ? ' fw-section-badge-full' :
                     s.selectedCount === 0 ? ' fw-section-badge-empty' : '')
            }));
            result.push({ tab: t, tabLabel: groups[t].tabLabel, sections });
        }
        return result;
    }

    get saveDisabled() { return this.isSaving || !this.selectedProfile; }
    get hasProfile() { return !!this.selectedProfile; }

    get selectedCount() {
        return this.master.filter(c => this.visibility[c.key]).length;
    }
    get totalCount() {
        return this.master.length;
    }
    get summaryText() {
        return `${this.selectedCount} of ${this.totalCount} components selected`;
    }
    get summaryPercent() {
        if (this.totalCount === 0) return 0;
        return Math.round((this.selectedCount / this.totalCount) * 100);
    }
    get summaryBarStyle() {
        return 'width: ' + this.summaryPercent + '%';
    }

    get noResults() {
        return this.hasProfile && this.groupedSections.length === 0;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    errMsg(e) {
        if (!e) return 'Unknown error';
        if (e.body && e.body.message) return e.body.message;
        if (e.message) return e.message;
        return JSON.stringify(e);
    }
}