/**
 * @description Controller for the Survey LWC components.
 *              Thin @AuraEnabled wrapper that delegates all business logic
 *              to OVE_Survey_Service.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class OVE_SurveyController {

    /**
     * @description Gets active surveys applicable to an outlet.
     * @param accountId The outlet Account Id.
     * @return List of applicable Survey__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Survey__c> getApplicableSurveys(Id accountId) {
        try {
            return OVE_Survey_Service.getApplicableSurveys(accountId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets a survey with its ordered questions.
     * @param surveyId The Survey__c Id.
     * @return Map containing survey info and questions list.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSurveyWithQuestions(Id surveyId) {
        try {
            return OVE_Survey_Service.getSurveyWithQuestions(surveyId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Submits a survey response with answers.
     * @param responseJson JSON string with visit, survey, and answer data.
     * @return The created Survey_Response__c record.
     */
    @AuraEnabled
    public static Survey_Response__c submitSurveyResponse(String responseJson) {
        try {
            return OVE_Survey_Service.submitSurveyResponse(responseJson);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Checks if a survey response already exists for a visit.
     * @param visitId  The Visit__c Id.
     * @param surveyId The Survey__c Id.
     * @return The existing Survey_Response__c or null.
     */
    @AuraEnabled(cacheable=true)
    public static Survey_Response__c getExistingSurveyResponse(Id visitId, Id surveyId) {
        try {
            return OVE_Survey_Service.getExistingSurveyResponse(visitId, surveyId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets all survey responses with answers for a visit.
     * @param visitId The Visit__c Id.
     * @return List of survey response maps with nested answers.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getSurveyResponsesForVisit(Id visitId) {
        try {
            return OVE_Survey_Service.getSurveyResponsesForVisit(visitId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Uploads a survey photo as a standalone file and returns the
     *              ContentVersion Id for later linking to the answer record.
     * @param base64Data Base64-encoded image data.
     * @param fileName   Desired file name.
     * @return The ContentVersion Id.
     */
    @AuraEnabled
    public static Id uploadSurveyPhoto(String base64Data, String fileName) {
        try {
            return OVE_Survey_Service.uploadSurveyPhoto(base64Data, fileName);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}