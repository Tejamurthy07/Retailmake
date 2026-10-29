import { LightningElement, api } from 'lwc';

/**
 * Modal dialog for saving/editing a Dynamic KPI Dashboard view.
 * Fires `save` or `cancel` custom events.
 */
export default class DkdSaveViewModal extends LightningElement {
    @api viewName = '';
    @api viewDescription = '';
    @api isShared = false;
    @api isEdit = false;
    @api isSaving = false;

    _localName = '';
    _localDescription = '';
    _localIsShared = false;

    connectedCallback() {
        this._localName = this.viewName || '';
        this._localDescription = this.viewDescription || '';
        this._localIsShared = this.isShared === true;
    }

    get modalTitle() {
        return this.isEdit ? 'Update Dashboard View' : 'Save New Dashboard View';
    }

    get saveButtonLabel() {
        return this.isEdit ? 'Update View' : 'Save View';
    }

    get isSaveDisabled() {
        return !this._localName || !this._localName.trim() || this.isSaving;
    }

    handleNameChange(e) { this._localName = e.detail.value; }
    handleDescriptionChange(e) { this._localDescription = e.detail.value; }
    handleSharedChange(e) { this._localIsShared = e.target.checked; }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    handleSave() {
        if (!this._localName || !this._localName.trim()) return;
        this.dispatchEvent(new CustomEvent('save', {
            detail: {
                name: this._localName.trim(),
                description: this._localDescription,
                isShared: this._localIsShared
            }
        }));
    }
}