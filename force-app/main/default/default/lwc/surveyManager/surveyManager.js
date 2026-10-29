import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import SURVEY_OBJECT from '@salesforce/schema/Survey__c';
import SURVEY_TYPE_FIELD from '@salesforce/schema/Survey__c.Survey_Type__c';

// ── Apex Imports ──────────────────────────────────────────────────────────
import getStats from '@salesforce/apex/SurveyManagerController.getStats';
import getSurveys from '@salesforce/apex/SurveyManagerController.getSurveys';
import saveSurvey from '@salesforce/apex/SurveyManagerController.saveSurvey';
import deleteSurvey from '@salesforce/apex/SurveyManagerController.deleteSurvey';
import getQuestions from '@salesforce/apex/SurveyManagerController.getQuestions';
import saveQuestion from '@salesforce/apex/SurveyManagerController.saveQuestion';
import deleteQuestion from '@salesforce/apex/SurveyManagerController.deleteQuestion';
import getResponses from '@salesforce/apex/SurveyManagerController.getResponses';
import getResponseDetail from '@salesforce/apex/SurveyManagerController.getResponseDetail';

export default class SurveyManager extends NavigationMixin(LightningElement) {

    // ── Navigation State ───────────────────────────────────────────────
    @track currentSection = 'dashboard';
    isLoading = false;
    @track isSaving = false;

    // ── Dashboard ──────────────────────────────────────────────────────
    @track stats = {};

    // ── Surveys ────────────────────────────────────────────────────────
    @track surveys = [];
    @track activeOnly = true;
    @track showSurveyModal = false;
    @track editSurvey = {};
    @track isNewSurvey = false;

    // ── Questions ──────────────────────────────────────────────────────
    @track selectedSurveyId = null;
    @track selectedSurveyName = '';
    @track questions = [];
    @track showQuestionModal = false;
    @track editQuestion = {};
    @track isNewQuestion = false;

    // ── Responses ──────────────────────────────────────────────────────
    @track responses = [];
    @track responseSurveyFilter = '';

    @track showPreviewModal = false;

    // ── Computed Getters: Section Visibility ───────────────────────────

    get showDashboard() { return this.currentSection === 'dashboard'; }
    get showSurveys() { return this.currentSection === 'surveys'; }
    get showQuestions() { return this.currentSection === 'questions'; }
    get showResponses() { return this.currentSection === 'responses'; }

    // ── Computed Getters: Nav Classes ──────────────────────────────────

    get dashboardNavClass() { return 'sidebar-item' + (this.currentSection === 'dashboard' ? ' active' : ''); }
    get surveysNavClass() { return 'sidebar-item' + (this.currentSection === 'surveys' ? ' active' : ''); }
    get questionsNavClass() { return 'sidebar-item' + (this.currentSection === 'questions' ? ' active' : ''); }
    get responsesNavClass() { return 'sidebar-item' + (this.currentSection === 'responses' ? ' active' : ''); }

    // ── Computed Getters: Section Title ────────────────────────────────

    get sectionTitle() {
        const titles = {
            dashboard: 'Dashboard',
            surveys: 'Surveys',
            questions: 'Questions',
            responses: 'Responses'
        };
        return titles[this.currentSection] || 'Survey Manager';
    }

    // ── Computed Getters: Modal Titles ─────────────────────────────────

    get surveyModalTitle() { return this.isNewSurvey ? 'New Survey' : 'Edit Survey'; }
    get questionModalTitle() { return this.isNewQuestion ? 'New Question' : 'Edit Question'; }

    // ── Computed Getters: Has Data ─────────────────────────────────────

    get hasSurveys() { return this.surveys && this.surveys.length > 0; }
    get hasQuestions() { return this.questions && this.questions.length > 0; }
    get hasResponses() { return this.responses && this.responses.length > 0; }
    get hasSelectedSurvey() { return !!this.selectedSurveyId; }
    get selectedSurveyHeading() {
        return this.selectedSurveyName
            ? 'Questions for: ' + this.selectedSurveyName
            : 'Questions';
    }

    // ── Picklist wiring (sourced live from the field, never hardcoded) ──
    @wire(getObjectInfo, { objectApiName: SURVEY_OBJECT })
    surveyObjectInfo;

    @wire(getPicklistValues, {
        recordTypeId: '$surveyObjectInfo.data.defaultRecordTypeId',
        fieldApiName: SURVEY_TYPE_FIELD
    })
    surveyTypePicklist;

    // ── Computed Getters: Picklist Options ─────────────────────────────

    get surveyTypeOptions() {
        const options = [{ label: '-- Select Type --', value: '' }];
        const values = (this.surveyTypePicklist && this.surveyTypePicklist.data)
            ? this.surveyTypePicklist.data.values : [];
        values.forEach(v => options.push({ label: v.label, value: v.value }));
        return options;
    }

    get outletTypeOptions() {
        return [
            { label: '-- None --', value: '' },
            { label: 'Grocery', value: 'Grocery' },
            { label: 'Medical', value: 'Medical' },
            { label: 'Hardware', value: 'Hardware' },
            { label: 'General Store', value: 'General Store' },
            { label: 'Cosmetics', value: 'Cosmetics' },
            { label: 'Pan Shop', value: 'Pan Shop' }
        ];
    }

    get outletTypeMultiOptions() {
        return [
            { label: 'Grocery', value: 'Grocery' },
            { label: 'Medical', value: 'Medical' },
            { label: 'Hardware', value: 'Hardware' },
            { label: 'General Store', value: 'General Store' },
            { label: 'Cosmetics', value: 'Cosmetics' },
            { label: 'Pan Shop', value: 'Pan Shop' }
        ];
    }

    get editSurveyOutletTypes() {
        const val = this.editSurvey?.Outlet_Type__c;
        if (!val) return [];
        return val.split(';').map(s => s.trim()).filter(s => s);
    }

    handleSurveyOutletTypesChange(event) {
        const selected = event.detail.value;
        this.editSurvey = { ...this.editSurvey, Outlet_Type__c: selected.join(';') };
    }

    get questionTypeOptions() {
        return [
            { label: '-- Select Type --', value: '' },
            { label: 'Text', value: 'Text' },
            { label: 'Number', value: 'Number' },
            { label: 'Rating', value: 'Rating' },
            { label: 'Single Choice', value: 'Single Choice' },
            { label: 'Multiple Choice', value: 'Multiple Choice' },
            { label: 'Photo', value: 'Photo' },
            { label: 'Date', value: 'Date' }
        ];
    }

    get isScorableQuestionType() {
        const t = this.editQuestion.Question_Type__c;
        return t === 'Rating' || t === 'Single Choice';
    }

    get responseSurveyFilterOptions() {
        const opts = [{ label: 'All Surveys', value: '' }];
        if (this.surveys && this.surveys.length) {
            this.surveys.forEach(s => {
                opts.push({ label: s.Name, value: s.Id });
            });
        }
        return opts;
    }

    // ── Lifecycle ──────────────────────────────────────────────────────

    connectedCallback() {
        this.loadDashboard();
        this.loadSurveys();
    }

    // ── Navigation ─────────────────────────────────────────────────────

    handleSectionChange(event) {
        const section = event.currentTarget.dataset.section;
        this.currentSection = section;
        this.loadSectionData(section);
    }

    async loadSectionData(section) {
        this.isLoading = true;
        try {
            switch (section) {
                case 'dashboard': await this.loadDashboard(); break;
                case 'surveys': await this.loadSurveys(); break;
                case 'questions':
                    if (this.selectedSurveyId) await this.loadQuestions();
                    break;
                case 'responses':
                    if (!this.surveys || !this.surveys.length) await this.loadSurveys();
                    await this.loadResponses();
                    break;
                default: break;
            }
        } catch (error) {
            this.showError('Error loading data', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    handleStatClick(event) {
        const section = event.currentTarget.dataset.section;
        if (section) {
            this.currentSection = section;
            this.loadSectionData(section);
        }
    }

    // ── Dashboard ──────────────────────────────────────────────────────

    async loadDashboard() {
        this.isLoading = true;
        try {
            this.stats = await getStats();
        } catch (error) {
            this.showError('Error loading dashboard', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    // ── Namespace helper ───────────────────────────────────────────────

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. Recurses into arrays
    // and child relationships. No-op on camelCase maps and wrapper DTOs.
    _stripNs(value) {
        if (Array.isArray(value)) return value.map((v) => this._stripNs(v));
        if (value && typeof value === 'object') {
            const out = {};
            Object.keys(value).forEach((k) => {
                const nk = k.startsWith('ftretailmake__') ? k.slice('ftretailmake__'.length) : k;
                out[nk] = this._stripNs(value[k]);
            });
            return out;
        }
        return value;
    }

    // ── Surveys ────────────────────────────────────────────────────────

    async loadSurveys() {
        try {
            const raw = this._stripNs(await getSurveys({ activeOnly: this.activeOnly }));
            this.surveys = (raw || []).map(s => ({
                ...s,
                questionCount: s.Survey_Questions__r ? s.Survey_Questions__r.length : 0
            }));
        } catch (error) {
            this.showError('Error loading surveys', this.reduceErrors(error));
        }
    }

    handleActiveOnlyChange(event) {
        this.activeOnly = event.target.checked;
        this.loadSurveys();
    }

    handleNewSurvey() {
        this.isNewSurvey = true;
        this.editSurvey = {
            Is_Active__c: true,
            Is_Mandatory__c: false
        };
        this.showSurveyModal = true;
    }

    handleEditSurvey(event) {
        const surveyId = event.currentTarget.dataset.id;
        const survey = this.surveys.find(s => s.Id === surveyId);
        if (survey) {
            this.isNewSurvey = false;
            this.editSurvey = JSON.parse(JSON.stringify(survey));
            this.showSurveyModal = true;
        }
    }

    handleSurveyFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.editSurvey = { ...this.editSurvey, [field]: value };
    }

    async handleSaveSurvey() {
        if (!this.editSurvey.Name) {
            this.showError('Validation Error', 'Please enter a survey name.');
            return;
        }
        if (!this.editSurvey.Survey_Code__c) {
            this.showError('Validation Error', 'Please enter a survey code.');
            return;
        }
        this.isSaving = true;
        try {
            const toSave = { ...this.editSurvey };
            // Strip relationship/computed fields
            delete toSave.Survey_Questions__r;
            delete toSave.questionCount;
            if (toSave.Outlet_Type__c === '') toSave.Outlet_Type__c = null;
            if (toSave.Survey_Type__c === '') toSave.Survey_Type__c = null;
            this._stripNs(await saveSurvey({ surveyJson: JSON.stringify(toSave) }));
            this.showSurveyModal = false;
            this.showSuccess(this.isNewSurvey ? 'Survey created' : 'Survey updated');
            await this.loadSurveys();
        } catch (error) {
            this.showError('Error saving survey', this.reduceErrors(error));
        } finally {
            this.isSaving = false;
        }
    }

    async handleDeleteSurvey(event) {
        const surveyId = event.currentTarget.dataset.id;
        const survey = this.surveys.find(s => s.Id === surveyId);
        if (!survey) return;
        if (!confirm(`Delete survey "${survey.Name}"? This will also delete its questions and responses.`)) return;
        try {
            await deleteSurvey({ surveyId });
            this.showSuccess('Survey deleted');
            if (this.selectedSurveyId === surveyId) {
                this.selectedSurveyId = null;
                this.selectedSurveyName = '';
                this.questions = [];
            }
            await this.loadSurveys();
        } catch (error) {
            this.showError('Error deleting survey', this.reduceErrors(error));
        }
    }

    handleCloseSurveyModal() {
        this.showSurveyModal = false;
    }

    // ── Select Survey for Questions ────────────────────────────────────

    handleSelectSurvey(event) {
        const surveyId = event.currentTarget.dataset.id;
        const survey = this.surveys.find(s => s.Id === surveyId);
        this.selectedSurveyId = surveyId;
        this.selectedSurveyName = survey ? survey.Name : '';
        this.currentSection = 'questions';
        this.loadQuestions();
    }

    // ── Questions ──────────────────────────────────────────────────────

    async loadQuestions() {
        if (!this.selectedSurveyId) {
            this.questions = [];
            return;
        }
        this.isLoading = true;
        try {
            const raw = this._stripNs(await getQuestions({ surveyId: this.selectedSurveyId }));
            this.questions = (raw || []).map(q => ({
                ...q,
                isRequiredLabel: q.Is_Required__c ? 'Yes' : 'No'
            }));
        } catch (error) {
            this.showError('Error loading questions', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    handleNewQuestion() {
        if (!this.selectedSurveyId) {
            this.showError('No Survey Selected', 'Please select a survey first.');
            return;
        }
        this.isNewQuestion = true;
        this.editQuestion = {
            Survey__c: this.selectedSurveyId,
            Is_Required__c: false,
            Sort_Order__c: this.questions.length + 1
        };
        this.showQuestionModal = true;
    }

    handleEditQuestion(event) {
        const qId = event.currentTarget.dataset.id;
        const q = this.questions.find(qq => qq.Id === qId);
        if (q) {
            this.isNewQuestion = false;
            this.editQuestion = JSON.parse(JSON.stringify(q));
            this.showQuestionModal = true;
        }
    }

    handleQuestionFieldChange(event) {
        const field = event.target.dataset.field;
        let value;
        if (event.target.type === 'checkbox') {
            value = event.target.checked;
        } else if (event.target.type === 'number') {
            value = event.target.value === '' ? null : Number(event.target.value);
        } else {
            value = event.target.value;
        }
        this.editQuestion = { ...this.editQuestion, [field]: value };
        if (field === 'Question_Type__c' && value !== 'Rating' && value !== 'Single Choice') {
            this.editQuestion = { ...this.editQuestion, Score_Weight__c: 0 };
        }
    }

    async handleSaveQuestion() {
        if (!this.editQuestion.Question_Text__c) {
            this.showError('Validation Error', 'Please enter question text.');
            return;
        }
        if (!this.editQuestion.Question_Type__c) {
            this.showError('Validation Error', 'Please select a question type.');
            return;
        }
        this.isSaving = true;
        try {
            const toSave = { ...this.editQuestion };
            delete toSave.isRequiredLabel;
            this._stripNs(await saveQuestion({ questionJson: JSON.stringify(toSave) }));
            this.showQuestionModal = false;
            this.showSuccess(this.isNewQuestion ? 'Question created' : 'Question updated');
            await this.loadQuestions();
        } catch (error) {
            this.showError('Error saving question', this.reduceErrors(error));
        } finally {
            this.isSaving = false;
        }
    }

    async handleDeleteQuestion(event) {
        const qId = event.currentTarget.dataset.id;
        const q = this.questions.find(qq => qq.Id === qId);
        if (!q) return;
        if (!confirm('Delete this question?')) return;
        try {
            await deleteQuestion({ questionId: qId });
            this.showSuccess('Question deleted');
            await this.loadQuestions();
        } catch (error) {
            this.showError('Error deleting question', this.reduceErrors(error));
        }
    }

    handleCloseQuestionModal() {
        this.showQuestionModal = false;
    }

    // ── Survey Preview ─────────────────────────────────────────────────

    handlePreviewSurvey() {
        this.showPreviewModal = true;
    }

    handleClosePreview() {
        this.showPreviewModal = false;
    }

    get selectedSurveyName() {
        if (!this.selectedSurveyId || !this.surveys) return '';
        const s = this.surveys.find(sv => sv.Id === this.selectedSurveyId);
        return s ? s.Name : '';
    }

    get previewQuestions() {
        if (!this.questions) return [];
        return [...this.questions]
            .sort((a, b) => (a.Sort_Order__c || 0) - (b.Sort_Order__c || 0))
            .map((q, i) => {
                const type = q.Question_Type__c || '';
                const opts = q.Options__c ? q.Options__c.split(/[,;]/).map(o => o.trim()).filter(o => o) : [];
                const picklistOptions = opts.map(o => ({ label: o, value: o }));
                return {
                    ...q,
                    displayIndex: i + 1,
                    isText: type === 'Text',
                    isNumber: type === 'Number',
                    isRating: type === 'Rating',
                    isYesNo: type === 'Single Choice',
                    isMultiSelect: type === 'Multiple Choice',
                    isPhoto: type === 'Photo',
                    isDate: type === 'Date',
                    optionsList: opts,
                    picklistOptions: picklistOptions.length > 0 ? picklistOptions : [{ label: 'Yes', value: 'Yes' }, { label: 'No', value: 'No' }],
                    yesNoOptions: [{ label: 'Yes', value: 'Yes' }, { label: 'No', value: 'No' }],
                    emptyArray: []
                };
            });
    }

    // ── Responses ──────────────────────────────────────────────────────

    handleResponseSurveyFilter(event) {
        this.responseSurveyFilter = event.detail.value;
        this.loadResponses();
    }

    handleLoadResponses() {
        this.loadResponses();
    }

    async loadResponses() {
        this.isLoading = true;
        try {
            const raw = this._stripNs(await getResponses({ surveyId: this.responseSurveyFilter || null }));
            this.responses = (raw || []).map(r => ({
                ...r,
                surveyName: r.Survey__r ? r.Survey__r.Name : '',
                accountName: r.Account__r ? r.Account__r.Name : '',
                visitName: r.Visit__r ? r.Visit__r.Name : '',
                respondentName: r.Respondent__r ? r.Respondent__r.Name : ''
            }));
        } catch (error) {
            this.showError('Error loading responses', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    @track showResponseDetailModal = false;
    @track responseDetail = null;
    @track responseAnswers = [];

    async handleViewResponse(event) {
        const responseId = event.currentTarget.dataset.id;
        if (!responseId) return;
        this.isLoading = true;
        try {
            const result = await getResponseDetail({ responseId });
            this.responseDetail = {
                ...result.response,
                surveyName: result.response.Survey__r ? result.response.Survey__r.Name : '',
                accountName: result.response.Account__r ? result.response.Account__r.Name : '',
                visitName: result.response.Visit__r ? result.response.Visit__r.Name : '',
                respondentName: result.response.Respondent__r ? result.response.Respondent__r.Name : ''
            };
            this.responseAnswers = result.answers || [];
            this.showResponseDetailModal = true;
        } catch (error) {
            this.showError('Error loading response', this.reduceErrors(error));
        } finally {
            this.isLoading = false;
        }
    }

    handleCloseResponseDetail() {
        this.showResponseDetailModal = false;
        this.responseDetail = null;
        this.responseAnswers = [];
    }

    handlePreviewPhoto(event) {
        event.preventDefault();
        event.stopPropagation();
        const contentDocId = event.currentTarget.dataset.contentId;
        const url = event.currentTarget.dataset.url;
        if (contentDocId) {
            // Preview attached file in Salesforce file preview
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: { pageName: 'filePreview' },
                state: { selectedRecordId: contentDocId }
            });
        } else if (url) {
            window.open(url, '_blank');
        }
    }

    // ── Utility ────────────────────────────────────────────────────────

    showSuccess(message) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Success',
            message,
            variant: 'success'
        }));
    }

    showError(title, message) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message: message || 'An unexpected error occurred',
            variant: 'error'
        }));
    }

    reduceErrors(error) {
        if (!error) return 'Unknown error';
        if (typeof error === 'string') return error;
        if (Array.isArray(error)) {
            return error.map(e => this.reduceErrors(e)).filter(Boolean).join(', ');
        }
        if (error.body && typeof error.body.message === 'string' && error.body.message.trim()) {
            return error.body.message;
        }
        if (error.body && Array.isArray(error.body)) {
            const messages = [];
            error.body.forEach(entry => {
                if (entry && Array.isArray(entry.errors)) {
                    entry.errors.forEach(e => { if (e && e.message) messages.push(e.message); });
                }
                if (entry && Array.isArray(entry.pageErrors)) {
                    entry.pageErrors.forEach(e => { if (e && e.message) messages.push(e.message); });
                }
                if (entry && typeof entry.message === 'string') {
                    messages.push(entry.message);
                }
            });
            if (messages.length) return messages.join(', ');
        }
        if (error.body && Array.isArray(error.body.pageErrors) && error.body.pageErrors.length) {
            return error.body.pageErrors.map(e => e.message).filter(Boolean).join(', ');
        }
        if (error.body && error.body.fieldErrors) {
            const fieldMessages = [];
            Object.keys(error.body.fieldErrors).forEach(field => {
                const entries = error.body.fieldErrors[field] || [];
                entries.forEach(e => { if (e && e.message) fieldMessages.push(e.message); });
            });
            if (fieldMessages.length) return fieldMessages.join(', ');
        }
        if (error.body && error.body.output && Array.isArray(error.body.output.errors)
            && error.body.output.errors.length) {
            return error.body.output.errors.map(e => e.message).filter(Boolean).join(', ');
        }
        if (typeof error.message === 'string' && error.message.trim()) return error.message;
        if (typeof error.statusText === 'string' && error.statusText.trim()) return error.statusText;
        return 'Save failed. Please review the form and try again.';
    }
}