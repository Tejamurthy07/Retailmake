import { LightningElement, api } from 'lwc';

export default class EmployeeHierarchyNode extends LightningElement {
    @api node;
    @api highlightedId;

    _expanded = true;

    get isExpanded() {
        return this._expanded;
    }

    get hasChildren() {
        return this.node && this.node.children && this.node.children.length > 0;
    }

    get children() {
        return this.node ? this.node.children || [] : [];
    }

    get nodeClass() {
        let cls = 'hierarchy-node';
        if (this.node && this.node.id === this.highlightedId) {
            cls += ' hierarchy-node-highlighted';
        }
        return cls;
    }

    get toggleIcon() {
        return this._expanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get designationLabel() {
        return this.node ? this.node.designation || '' : '';
    }

    get territoryLabel() {
        return this.node && this.node.territory ? this.node.territory : '';
    }

    get childCountLabel() {
        if (!this.hasChildren) return '';
        return this.node.children.length + ' report' + (this.node.children.length > 1 ? 's' : '');
    }

    get initials() {
        if (!this.node || !this.node.name) return '?';
        const parts = this.node.name.trim().split(' ');
        if (parts.length >= 2) {
            return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
        }
        return parts[0][0].toUpperCase();
    }

    get levelClass() {
        const level = this.node ? this.node.level || 0 : 0;
        return 'hierarchy-card hierarchy-level-' + Math.min(level, 4);
    }

    handleToggle() {
        this._expanded = !this._expanded;
    }

    handleNodeClick() {
        this.dispatchEvent(new CustomEvent('employeeclick', {
            detail: { employeeId: this.node.id },
            bubbles: true,
            composed: true
        }));
    }
}