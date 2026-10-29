import { LightningElement } from 'lwc';

export default class TamLoadingScreen extends LightningElement {

    placeholders = [];

    connectedCallback() {

        this.createPlaceholders(9);
    }

    createPlaceholders(count) {
        const tempPlaceholders = [];
        for (let i = 0; i < count; i++) {
            tempPlaceholders.push({
                id: i,
                titleClass: 'card__title loading',
                descriptionClass: 'card__description loading'
            });
        }
        this.placeholders = tempPlaceholders;
    }
}