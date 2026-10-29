public with sharing class SurveyManagerController {

    @AuraEnabled
    public static Map<String, Object> getStats() {
        Map<String, Object> stats = new Map<String, Object>();
        stats.put('totalSurveys', [SELECT COUNT() FROM Survey__c]);
        stats.put('activeSurveys', [SELECT COUNT() FROM Survey__c WHERE Is_Active__c = true]);
        stats.put('totalQuestions', [SELECT COUNT() FROM Survey_Question__c]);
        stats.put('totalResponses', [SELECT COUNT() FROM Survey_Response__c]);
        return stats;
    }

    @AuraEnabled
    public static List<Survey__c> getSurveys(Boolean activeOnly) {
        if (activeOnly == true) {
            return [
                SELECT Id, Name, Survey_Code__c, Survey_Type__c, Outlet_Type__c,
                       Is_Active__c, Is_Mandatory__c, Effective_From__c, Effective_To__c,
                       Description__c, (SELECT Id FROM Survey_Questions__r)
                FROM Survey__c
                WHERE Is_Active__c = true
                ORDER BY Name
            ];
        }
        return [
            SELECT Id, Name, Survey_Code__c, Survey_Type__c, Outlet_Type__c,
                   Is_Active__c, Is_Mandatory__c, Effective_From__c, Effective_To__c,
                   Description__c, (SELECT Id FROM Survey_Questions__r)
            FROM Survey__c
            ORDER BY Name
        ];
    }

    @AuraEnabled
    public static Survey__c saveSurvey(String surveyJson) {
        // JSON (not a typed SObject) so unqualified field keys survive the hop —
        // an SObject param drops any value whose key lacks the ftretailmake__ prefix.
        if (String.isBlank(surveyJson)) throw new AuraHandledException('Survey is required.');
        Survey__c survey = (Survey__c) buildSObject(
            Survey__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(surveyJson));
        return saveSurveyInternal(survey);
    }

    public static Survey__c saveSurveyInternal(Survey__c survey) {
        upsert survey;
        return [
            SELECT Id, Name, Survey_Code__c, Survey_Type__c, Outlet_Type__c,
                   Is_Active__c, Is_Mandatory__c, Effective_From__c, Effective_To__c, Description__c
            FROM Survey__c WHERE Id = :survey.Id
        ];
    }

    @AuraEnabled
    public static void deleteSurvey(Id surveyId) {
        delete [SELECT Id FROM Survey__c WHERE Id = :surveyId];
    }

    @AuraEnabled
    public static List<Survey_Question__c> getQuestions(Id surveyId) {
        return [
            SELECT Id, Name, Question_Text__c, Question_Type__c, Options__c,
                   Is_Required__c, Sort_Order__c, Validation_Rule__c, Score_Weight__c, Survey__c
            FROM Survey_Question__c
            WHERE Survey__c = :surveyId
            ORDER BY Sort_Order__c, Name
        ];
    }

    @AuraEnabled
    public static Survey_Question__c saveQuestion(String questionJson) {
        if (String.isBlank(questionJson)) throw new AuraHandledException('Question is required.');
        Survey_Question__c question = (Survey_Question__c) buildSObject(
            Survey_Question__c.SObjectType, (Map<String, Object>) JSON.deserializeUntyped(questionJson));
        return saveQuestionInternal(question);
    }

    public static Survey_Question__c saveQuestionInternal(Survey_Question__c question) {
        upsert question;
        return [
            SELECT Id, Name, Question_Text__c, Question_Type__c, Options__c,
                   Is_Required__c, Sort_Order__c, Validation_Rule__c, Score_Weight__c, Survey__c
            FROM Survey_Question__c WHERE Id = :question.Id
        ];
    }

    @AuraEnabled
    public static void deleteQuestion(Id questionId) {
        delete [SELECT Id FROM Survey_Question__c WHERE Id = :questionId];
    }

    @AuraEnabled
    public static List<Survey_Response__c> getResponses(Id surveyId) {
        if (surveyId != null) {
            return [
                SELECT Id, Name, Survey__c, Survey__r.Name, Account__c, Account__r.Name,
                       Visit__c, Visit__r.Name, Respondent__c, Respondent__r.Name,
                       Response_Date__c, Status__c, Total_Score__c, Max_Possible_Score__c, Score_Percentage__c
                FROM Survey_Response__c
                WHERE Survey__c = :surveyId
                ORDER BY Response_Date__c DESC
                LIMIT 200
            ];
        }
        return [
            SELECT Id, Name, Survey__c, Survey__r.Name, Account__c, Account__r.Name,
                   Visit__c, Visit__r.Name, Respondent__c, Respondent__r.Name,
                   Response_Date__c, Status__c, Total_Score__c, Max_Possible_Score__c, Score_Percentage__c
            FROM Survey_Response__c
            ORDER BY Response_Date__c DESC
            LIMIT 200
        ];
    }

    @AuraEnabled
    public static Map<String, Object> getResponseDetail(Id responseId) {
        Survey_Response__c response = [
            SELECT Id, Name, Survey__c, Survey__r.Name, Account__c, Account__r.Name,
                   Visit__c, Visit__r.Name, Respondent__c, Respondent__r.Name,
                   Response_Date__c, Status__c, Total_Score__c, Max_Possible_Score__c, Score_Percentage__c
            FROM Survey_Response__c WHERE Id = :responseId LIMIT 1
        ];

        List<Survey_Answer__c> answers = [
            SELECT Id, Name, Survey_Question__c,
                   Survey_Question__r.Question_Text__c,
                   Survey_Question__r.Question_Type__c,
                   Survey_Question__r.Sort_Order__c,
                   Answer_Text__c, Answer_Choice__c, Answer_Number__c,
                   Rating_Value__c, Photo_URL__c
            FROM Survey_Answer__c
            WHERE Survey_Response__c = :responseId
            ORDER BY Survey_Question__r.Sort_Order__c, Name
        ];

        // Resolve photo attachments via ContentDocumentLink
        Set<Id> answerIds = new Set<Id>();
        for (Survey_Answer__c a : answers) answerIds.add(a.Id);
        Map<Id, Id> answerToContentDocId = new Map<Id, Id>();
        if (!answerIds.isEmpty()) {
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId, LinkedEntityId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :answerIds
            ]) {
                answerToContentDocId.put(cdl.LinkedEntityId, cdl.ContentDocumentId);
            }
        }

        List<Map<String, Object>> answerRows = new List<Map<String, Object>>();
        for (Survey_Answer__c a : answers) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', a.Id);
            row.put('questionText', a.Survey_Question__r != null ? a.Survey_Question__r.Question_Text__c : '');
            row.put('questionType', a.Survey_Question__r != null ? a.Survey_Question__r.Question_Type__c : '');
            String displayValue = '';
            if (a.Answer_Text__c != null) displayValue = a.Answer_Text__c;
            else if (a.Answer_Choice__c != null) displayValue = a.Answer_Choice__c;
            else if (a.Rating_Value__c != null) displayValue = String.valueOf(a.Rating_Value__c.intValue()) + ' / 5';
            else if (a.Answer_Number__c != null) displayValue = String.valueOf(a.Answer_Number__c);
            row.put('displayValue', displayValue);
            row.put('photoUrl', a.Photo_URL__c);
            // Add ContentDocumentId (file attachment) if present
            Id contentDocId = answerToContentDocId.get(a.Id);
            row.put('contentDocumentId', contentDocId);
            row.put('hasPhoto', contentDocId != null || String.isNotBlank(a.Photo_URL__c));
            answerRows.add(row);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('response', response);
        result.put('answers', answerRows);
        return result;
    }

    // ── Namespace-tolerant SObject building (see saveSurvey/saveQuestion) ─
    private static SObject buildSObject(Schema.SObjectType t, Map<String, Object> m) {
        SObject rec = t.newSObject();
        if (m == null) return rec;
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();
        for (String key : m.keySet()) {
            if (key == 'sobjectType' || key == 'attributes' || m.get(key) == null) continue;
            Schema.SObjectField sf = resolveField(fmap, key);
            if (sf == null) continue; // unknown field or relationship (__r) — skip
            Schema.DescribeFieldResult dfr = sf.getDescribe();
            try { rec.put(dfr.getName(), coerceValue(dfr.getType(), m.get(key))); }
            catch (Exception e) { /* skip un-coercible value rather than fail the save */ }
        }
        return rec;
    }

    private static Schema.SObjectField resolveField(Map<String, Schema.SObjectField> fmap, String name) {
        if (String.isBlank(name) || fmap == null) return null;
        Schema.SObjectField f = fmap.get(name);
        if (f != null) return f;
        String bare = unqualify(name);
        for (String key : fmap.keySet()) {
            if (unqualify(key).equalsIgnoreCase(bare)) return fmap.get(key);
        }
        return null;
    }

    private static String unqualify(String api) {
        if (String.isBlank(api)) return api;
        if (api.endsWithIgnoreCase('__c') && api.split('__').size() >= 3) {
            return api.substringAfter('__');
        }
        return api;
    }

    private static Object coerceValue(Schema.DisplayType t, Object val) {
        if (val == null) return null;
        String s = String.valueOf(val);
        if (String.isBlank(s)) return null;
        if (t == Schema.DisplayType.Boolean) return (val instanceof Boolean) ? val : Boolean.valueOf(s);
        if (t == Schema.DisplayType.Date) return Date.valueOf(s.substring(0, 10));
        if (t == Schema.DisplayType.DateTime) return Datetime.valueOf(s.replace('T', ' ').replace('Z', ''));
        if (t == Schema.DisplayType.Double || t == Schema.DisplayType.Currency
            || t == Schema.DisplayType.Percent) return Decimal.valueOf(s);
        if (t == Schema.DisplayType.Integer) return Integer.valueOf(s);
        if (t == Schema.DisplayType.Reference || t == Schema.DisplayType.Id) return (Id) s;
        return s;
    }
}