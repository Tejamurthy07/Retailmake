import { LightningElement, wire } from 'lwc';
import getDashboard from '@salesforce/apex/DMS_PortalController.getDashboard';
import getInventory from '@salesforce/apex/DMS_PortalController.getInventory';

const INVENTORY_COLUMNS = [
    { label: 'Product', fieldName: 'productName' },
    { label: 'Batch', fieldName: 'Batch_No__c' },
    { label: 'On Hand', fieldName: 'Closing_Stock__c', type: 'number' },
    { label: 'Expiry', fieldName: 'Expiry_Date__c', type: 'date' }
];

export default class DistributorPortalHome extends LightningElement {
    dashboard;
    inventory = [];
    error;
    columns = INVENTORY_COLUMNS;

    @wire(getDashboard)
    wiredDashboard({ data, error }) {
        if (data) {
            this.dashboard = data;
            this.error = undefined;
        } else if (error) {
            this.error = this.reduceError(error);
        }
    }

    @wire(getInventory)
    wiredInventory({ data, error }) {
        if (data) {
            this.inventory = data.map((row) => ({
                ...row,
                productName: row.Product_Ext__r ? row.Product_Ext__r.Name : ''
            }));
            this.error = undefined;
        } else if (error) {
            this.error = this.reduceError(error);
        }
    }

    get hasInventory() {
        return this.inventory && this.inventory.length > 0;
    }

    reduceError(error) {
        return (error && error.body && error.body.message) || 'Unable to load portal data.';
    }
}