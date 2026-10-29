import { LightningElement, api } from 'lwc';

/** Consistent page title bar with an optional subtitle and an actions slot. */
export default class DmsPageHeader extends LightningElement {
    @api title;
    @api subtitle;
}