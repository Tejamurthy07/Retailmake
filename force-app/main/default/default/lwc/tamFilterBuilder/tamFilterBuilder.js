import { LightningElement, api, track } from 'lwc';

export default class TamFilterBuilder extends LightningElement {

    // From parent — use getter/setter so we can re-process filters when metadata arrives
    _fieldsMetadata = [];

    @api
    get fieldsMetadata() {
        return this._fieldsMetadata;
    }
    set fieldsMetadata(val) {
        this._fieldsMetadata = val || [];

        // If filters are already loaded but were missing metadata, re-process them
        if (this._fieldsMetadata.length > 0 && this.filters.length > 0 && this._needsMetadataRefresh) {
            this._needsMetadataRefresh = false;
            this._refreshFiltersWithMetadata();
        }
    }

    _needsMetadataRefresh = false;

    @track filters = [];
    filterCounter = 1;

    booleanOptions = [
        { label: 'True', value: 'true' },
        { label: 'False', value: 'false' }
    ];

    // Parent can pass existing filters (for edit mode)
    @api
    get value() {
        return this.filters;
    }
    set value(val) {
        if (val && Array.isArray(val) && val.length > 0) {
            const cloned = JSON.parse(JSON.stringify(val));

            // Restore UI state for each filter
            this.filters = cloned.map(f => this._restoreFilterUI(f));

            // Keep filterCounter ahead of existing max id
            const maxId = this.filters.reduce((max, f) => {
                const num = Number(f.id);
                return isNaN(num) ? max : Math.max(max, num);
            }, 0);
            this.filterCounter = maxId + 1;

            // If metadata isn't loaded yet, flag for refresh when it arrives
            if (!this._fieldsMetadata || this._fieldsMetadata.length === 0) {
                this._needsMetadataRefresh = true;
            }
        } else {
            this.filters = [];
            this.filterCounter = 1;
        }
    }

    // Re-process filters when metadata arrives late
    _refreshFiltersWithMetadata() {
        this.filters = this.filters.map(f => this._restoreFilterUI(f));
    }

    // Restore a single filter's UI state from its saved data
    _restoreFilterUI(f) {
        const type = f.type || 'String';

        // Operator options
        f.operatorOptions = this.getOperatorsForType(type);

        // Picklist options + field label from metadata
        f.picklistOptions = [];
        if (this._fieldsMetadata && this._fieldsMetadata.length) {
            const meta = this._fieldsMetadata.find(m => m.apiName === f.field);
            if (meta && meta.picklistValues && meta.picklistValues.length) {
                f.picklistOptions = meta.picklistValues.map(v => ({ label: v, value: v }));
            }
            f.fieldSearchText = meta
                ? `${meta.label} (${meta.apiName})`
                : (f.field || '');
        } else {
            f.fieldSearchText = f.field || '';
        }

        f.showFieldDropdown = false;
        f.filteredFieldOptions = [];

        // Value UI flags
        f.showValue = !!f.field;
        f.isNumber = (type === 'Number' || type === 'Currency' || type === 'Percent');
        f.isString = (type === 'String' || type === 'Id');
        f.isDate = (type === 'Date' || type === 'DateTime');
        f.isBoolean = (type === 'Boolean');
        f.isMultiPicklist = (type === 'MultiPicklist');
        f.isPicklist = false;
        f.isMultiValue = false;

        if (type === 'Picklist') {
            if (f.operator === 'IN' || f.operator === 'NOT IN') {
                f.isMultiPicklist = true;
                f.isMultiValue = true;
            } else {
                f.isPicklist = true;
            }
        }

        if (type !== 'Picklist' && (f.operator === 'IN' || f.operator === 'NOT IN')) {
            f.isMultiValue = true;
        }

        if (f.isMultiPicklist && Array.isArray(f.value)) {
            f.valueArray = f.value;
        } else {
            f.valueArray = [];
        }

        return f;
    }


    // UTIL: icon per field type
    getIconForType(type) {
        switch (type) {
            case 'String': return 'utility:text';
            case 'Number': return 'utility:number_input';
            case 'Currency': return 'utility:money';
            case 'Percent': return 'utility:percent';
            case 'Date': return 'utility:event';
            case 'DateTime': return 'utility:date_time';
            case 'Boolean': return 'utility:check';
            case 'Picklist': return 'utility:list';
            case 'MultiPicklist': return 'utility:choice';
            case 'Reference': return 'utility:record_lookup';
            default: return 'utility:link';
        }
    }

    // Add new filter row
    addFilter() {
        const id = this.filterCounter++;

        const newFilter = {
            id: id,
            label: 'Filter ' + id,
            field: null,
            operator: null,
            value: null,
            type: null,

            operatorOptions: [],
            picklistOptions: [],

            showValue: false,
            isNumber: false,
            isString: false,
            isPicklist: false,
            isMultiPicklist: false,
            isDate: false,
            isMultiValue: false,
            valueArray: [],
            isBoolean: false,       // <-- add this

            fieldSearchText: '',
            showFieldDropdown: false,
            filteredFieldOptions: []
        };

        this.filters = [...this.filters, newFilter];
        this.dispatch();
    }

    deleteFilter(event) {
        const id = Number(event.currentTarget.dataset.id);
        this.filters = this.filters.filter(f => f.id !== id);
        this.dispatch();
    }

    // Add this helper in the same JS file
    isLookupField(meta) {
        // Adjust string if your metadata uses "Lookup" instead of "Reference"
        // If you want to *keep* User lookups, exclude them here using meta.isUserField
        return meta.type === 'Reference' || meta.type === 'Lookup';
    }


    // FIELD SEARCH
    handleFieldSearch(event) {
        const id = Number(event.target.dataset.id);
        const idx = this.filters.findIndex(f => f.id === id);
        if (idx === -1) return;

        const filter = { ...this.filters[idx] };
        const search = (event.target.value || '').toLowerCase();
        filter.fieldSearchText = event.target.value;

        if (!search || this.fieldsMetadata.length === 0) {
            filter.filteredFieldOptions = [];
            filter.showFieldDropdown = false;
            this.filters = [...this.filters.slice(0, idx), filter, ...this.filters.slice(idx + 1)];
            return;
        }

        filter.filteredFieldOptions = this.fieldsMetadata
            .filter(m =>
                !this.isLookupField(m) &&
                (
                    (m.label && m.label.toLowerCase().includes(search)) ||
                    (m.apiName && m.apiName.toLowerCase().includes(search))
                )
            )
            .map(m => ({
                value: m.apiName,
                label: `${m.label} (${m.apiName})`,
                type: m.type,
                icon: this.getIconForType(m.type),
                typeBadgeClass: 'fbe-type fbe-type-' + (m.type || 'string').toLowerCase()
            }));

        filter.showFieldDropdown = filter.filteredFieldOptions.length > 0;
        this.filters = [...this.filters.slice(0, idx), filter, ...this.filters.slice(idx + 1)];
    }


    selectField(event) {
        const id = Number(event.currentTarget.dataset.id);
        const api = event.currentTarget.dataset.value;

        const idx = this.filters.findIndex(f => f.id === id);
        if (idx === -1) return;

        const meta = this.fieldsMetadata.find(m => m.apiName === api);
        if (!meta) return;

        const filter = { ...this.filters[idx] };

        filter.field = api;
        filter.fieldSearchText = `${meta.label} (${meta.apiName})`;
        filter.showFieldDropdown = false;
        filter.type = meta.type;
        filter.operatorOptions = this.getOperatorsForType(meta.type);

        if (meta.picklistValues && meta.picklistValues.length) {
            filter.picklistOptions = meta.picklistValues.map(v => ({ label: v, value: v }));
        } else {
            filter.picklistOptions = [];
        }

        this.initValueUI(filter, meta.type);

        this.filters = [...this.filters.slice(0, idx), filter, ...this.filters.slice(idx + 1)];
        this.dispatch();
    }


    // Determine which operators to show by type
    getOperatorsForType(type) {
        switch (type) {
            case 'String':
                return [
                    { label: '=', value: '=' },
                    { label: '!=', value: '!=' },
                    { label: 'LIKE', value: 'LIKE' },
                    { label: 'NOT LIKE', value: 'NOT LIKE' },
                    { label: 'IN', value: 'IN' },
                    { label: 'NOT IN', value: 'NOT IN' }
                ];
            case 'Number':
            case 'Currency':
            case 'Percent':
                return [
                    { label: '=', value: '=' },
                    { label: '!=', value: '!=' },
                    { label: '>', value: '>' },
                    { label: '<', value: '<' },
                    { label: '>=', value: '>=' },
                    { label: '<=', value: '<=' },
                    { label: 'IN', value: 'IN' },
                    { label: 'NOT IN', value: 'NOT IN' }
                ];
            case 'Picklist':
                return [
                    { label: '=', value: '=' },
                    { label: '!=', value: '!=' },
                    { label: 'IN', value: 'IN' },
                    { label: 'NOT IN', value: 'NOT IN' }
                ];
            case 'MultiPicklist':
                return [
                    { label: 'INCLUDES', value: 'INCLUDES' },
                    { label: 'EXCLUDES', value: 'EXCLUDES' }
                ];
            case 'Boolean':
                return [{ label: '=', value: '=' }];
            case 'Date':
            case 'DateTime':
                return [
                    { label: '=', value: '=' },
                    { label: '!=', value: '!=' },
                    { label: '>', value: '>' },
                    { label: '<', value: '<' },
                    { label: '>=', value: '>=' },
                    { label: '<=', value: '<=' }
                ];
            default:
                return [{ label: '=', value: '=' }];
        }
    }

    // Setup value UI flags based on type
    initValueUI(filter, type) {
        filter.showValue = true;

        // reset all flags first
        filter.isNumber = false;
        filter.isString = false;
        filter.isDate = false;
        filter.isPicklist = false;
        filter.isMultiPicklist = false;
        filter.isMultiValue = false;
        filter.isBoolean = false;

        // numbers
        if (type === 'Number' || type === 'Currency' || type === 'Percent') {
            filter.isNumber = true;
            return;
        }

        // strings / Id
        if (type === 'String' || type === 'Id') {
            filter.isString = true;
            return;
        }

        // dates
        if (type === 'Date' || type === 'DateTime') {
            filter.isDate = true;
            return;
        }

        // boolean
        if (type === 'Boolean') {
            filter.isBoolean = true;
            return;
        }

        // multipicklist
        if (type === 'MultiPicklist') {
            filter.isMultiPicklist = true;
            return;
        }

        // picklist (single or multi depending on operator)
        if (type === 'Picklist') {
            if (filter.operator === 'IN' || filter.operator === 'NOT IN') {
                filter.isPicklist = false;
                filter.isMultiPicklist = true;
            } else {
                filter.isPicklist = true;
                filter.isMultiPicklist = false;
            }
            return;
        }

        // default fallback – treat as string
        filter.isString = true;
    }

    handleOperatorChange(event) {
        const id = Number(event.target.dataset.id);
        const idx = this.filters.findIndex(f => f.id === id);
        if (idx === -1) return;

        const filter = { ...this.filters[idx] };
        filter.operator = event.target.value;

        if (filter.type === 'Boolean') {
            filter.isMultiValue = false;
            filter.isPicklist = false;
            filter.isMultiPicklist = false;
        } else if (filter.type === 'Picklist') {
            if (filter.operator === 'IN' || filter.operator === 'NOT IN') {
                filter.isPicklist = false;
                filter.isMultiPicklist = true;
                filter.isMultiValue = true;
            } else {
                filter.isPicklist = true;
                filter.isMultiPicklist = false;
                filter.isMultiValue = false;
            }
        } else {
            filter.isMultiPicklist = false;
            filter.isPicklist = false;
            filter.isMultiValue = (filter.operator === 'IN' || filter.operator === 'NOT IN');
        }

        this.filters = [...this.filters.slice(0, idx), filter, ...this.filters.slice(idx + 1)];
        this.dispatch();
    }

    handleValueChange(event) {
        const id = Number(event.target.dataset.id);
        const idx = this.filters.findIndex(f => f.id === id);
        if (idx === -1) return;

        const filter = { ...this.filters[idx] };
        filter.value = event.target.value;
        this.filters = [...this.filters.slice(0, idx), filter, ...this.filters.slice(idx + 1)];
        this.dispatch();
    }

    handleMultiValueChange(event) {
        const id = Number(event.target.dataset.id);
        const idx = this.filters.findIndex(f => f.id === id);
        if (idx === -1) return;

        const filter = { ...this.filters[idx] };
        const raw = event.target.value || '';
        filter.value = raw.split(',').map(v => v.trim()).filter(v => v.length);
        this.filters = [...this.filters.slice(0, idx), filter, ...this.filters.slice(idx + 1)];
        this.dispatch();
    }

    handleMultiPicklistChange(event) {
        const id = Number(event.target.dataset.id);
        const idx = this.filters.findIndex(f => f.id === id);
        if (idx === -1) return;

        const filter = { ...this.filters[idx] };
        filter.valueArray = event.detail.value;
        filter.value = filter.valueArray;
        this.filters = [...this.filters.slice(0, idx), filter, ...this.filters.slice(idx + 1)];
        this.dispatch();
    }

    // Notify parent
    dispatch() {
        this.dispatchEvent(
            new CustomEvent('filterchange', { detail: this.filters })
        );
    }
}