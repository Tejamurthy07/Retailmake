import { LightningElement, api, track } from 'lwc';

export default class SearchableCombobox extends LightningElement {
    @api label = '';
    @api placeholder = 'Search...';
    @api required = false;
    @api variant = 'standard'; // 'standard' or 'label-hidden'
    @api disabled = false;

    @track searchTerm = '';
    @track isDropdownOpen = false;
    @track highlightedIndex = -1;

    _options = [];
    _value = '';
    _selectedLabel = '';

    @api
    get options() {
        return this._options;
    }
    set options(val) {
        this._options = val || [];
        this.updateSelectedLabel();
    }

    @api
    get value() {
        return this._value;
    }
    set value(val) {
        this._value = val || '';
        this.updateSelectedLabel();
    }

    get showLabel() {
        return this.variant !== 'label-hidden' && this.label;
    }

    get computedPlaceholder() {
        if (this._selectedLabel && !this.isDropdownOpen) {
            return this._selectedLabel;
        }
        return this.placeholder;
    }

    get hasSelection() {
        return !!this._value;
    }

    get filteredOptions() {
        const term = this.searchTerm.toLowerCase().trim();
        let opts = this._options;
        if (term) {
            opts = opts.filter(o => o.label && o.label.toLowerCase().includes(term));
        }
        return opts.map((o, idx) => ({
            ...o,
            isSelected: o.value === this._value,
            itemClass: 'dropdown-item' +
                (o.value === this._value ? ' dropdown-item-selected' : '') +
                (idx === this.highlightedIndex ? ' dropdown-item-highlighted' : '')
        }));
    }

    get hasFilteredOptions() {
        return this.filteredOptions.length > 0;
    }

    updateSelectedLabel() {
        if (this._value && this._options.length > 0) {
            const match = this._options.find(o => o.value === this._value);
            this._selectedLabel = match ? match.label : '';
        } else {
            this._selectedLabel = '';
        }
    }

    handleFocus() {
        if (this.disabled) return;
        this.isDropdownOpen = true;
        this.highlightedIndex = -1;
        if (this._selectedLabel) {
            this.searchTerm = this._selectedLabel;
            // Select all text on focus for easy replacement
            requestAnimationFrame(() => {
                const input = this.template.querySelector('.combobox-input');
                if (input) {
                    input.select();
                }
            });
        }
    }

    handleBlur() {
        // Delay to allow click events on dropdown items
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.isDropdownOpen = false;
            this.searchTerm = '';
            this.highlightedIndex = -1;
        }, 200);
    }

    handleSearchInput(event) {
        this.searchTerm = event.target.value;
        this.highlightedIndex = -1;
        if (!this.isDropdownOpen) {
            this.isDropdownOpen = true;
        }
    }

    handleKeyDown(event) {
        const opts = this.filteredOptions;
        if (event.key === 'ArrowDown') {
            event.preventDefault();
            if (this.highlightedIndex < opts.length - 1) {
                this.highlightedIndex++;
            }
            this.scrollToHighlighted();
        } else if (event.key === 'ArrowUp') {
            event.preventDefault();
            if (this.highlightedIndex > 0) {
                this.highlightedIndex--;
            }
            this.scrollToHighlighted();
        } else if (event.key === 'Enter') {
            event.preventDefault();
            if (this.highlightedIndex >= 0 && this.highlightedIndex < opts.length) {
                this.selectOption(opts[this.highlightedIndex].value);
            }
        } else if (event.key === 'Escape') {
            this.isDropdownOpen = false;
            this.searchTerm = '';
            this.highlightedIndex = -1;
        }
    }

    scrollToHighlighted() {
        requestAnimationFrame(() => {
            const list = this.template.querySelector('.dropdown-list');
            const highlighted = this.template.querySelector('.dropdown-item-highlighted');
            if (list && highlighted) {
                const listRect = list.getBoundingClientRect();
                const itemRect = highlighted.getBoundingClientRect();
                if (itemRect.bottom > listRect.bottom) {
                    list.scrollTop += itemRect.bottom - listRect.bottom;
                } else if (itemRect.top < listRect.top) {
                    list.scrollTop -= listRect.top - itemRect.top;
                }
            }
        });
    }

    handleOptionSelect(event) {
        const val = event.currentTarget.dataset.value;
        this.selectOption(val);
    }

    handleOptionHover(event) {
        const val = event.currentTarget.dataset.value;
        const opts = this.filteredOptions;
        const idx = opts.findIndex(o => o.value === val);
        if (idx >= 0) {
            this.highlightedIndex = idx;
        }
    }

    selectOption(val) {
        this._value = val;
        this.updateSelectedLabel();
        this.searchTerm = '';
        this.isDropdownOpen = false;
        this.highlightedIndex = -1;
        this.dispatchEvent(new CustomEvent('change', {
            detail: { value: val }
        }));
    }

    handleClear(event) {
        event.stopPropagation();
        this._value = '';
        this._selectedLabel = '';
        this.searchTerm = '';
        this.isDropdownOpen = false;
        this.highlightedIndex = -1;
        this.dispatchEvent(new CustomEvent('change', {
            detail: { value: '' }
        }));
    }
}