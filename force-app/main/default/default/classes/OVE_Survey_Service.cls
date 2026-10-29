/**
 * @description Service class for Survey / Feedback during outlet visits.
 *              Handles survey applicability, question retrieval, response
 *              submission, and duplicate-check logic.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public without sharing class OVE_Survey_Service {

    // ── Feature Codes ───────────────────────────────────────────────────────
    public static final String FEATURE_SURVEY = 'OVE-005';

    // ── Survey Applicability ────────────────────────────────────────────────

    /**
     * @description Returns active surveys whose date range covers today.
     *              Optionally filters by Outlet_Type__c matching the account.
     * @param accountId The outlet Account Id (used for Outlet_Type matching).
     * @return List of applicable Survey__c records.
     */
    public static List<Survey__c> getApplicableSurveys(Id accountId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_SURVEY)) {
            throw new AuraHandledException('Survey feature is currently disabled.');
        }

        Date today = Date.today();

        // Determine outlet type from the account for filtering
        String outletType = null;
        if (accountId != null) {
            List<Account> accounts = [
                SELECT Id, Outlet_Type__c FROM Account WHERE Id = :accountId LIMIT 1
            ];
            if (!accounts.isEmpty()) {
                outletType = accounts[0].Outlet_Type__c;
            }
        }

        String query = 'SELECT Id, Name, Survey_Code__c, Survey_Type__c, Description__c, ' +
                       'Outlet_Type__c, Effective_From__c, Effective_To__c, Is_Mandatory__c ' +
                       'FROM Survey__c ' +
                       'WHERE Is_Active__c = true ' +
                       'AND (Effective_From__c = null OR Effective_From__c <= :today) ' +
                       'AND (Effective_To__c = null OR Effective_To__c >= :today)';

        if (String.isNotBlank(outletType)) {
            // Outlet_Type__c on Survey__c is a MultiselectPicklist — use INCLUDES
            // to match any survey where the outlet's type is one of the selected values
            query += ' AND (Outlet_Type__c = null OR Outlet_Type__c INCLUDES (:outletType))';
        }

        query += ' ORDER BY Name ASC';

        return Database.query(query);
    }

    // ── Survey With Questions ───────────────────────────────────────────────

    /**
     * @description Returns survey details along with ordered questions.
     * @param surveyId The Survey__c Id.
     * @return Map containing 'survey' (Survey__c) and 'questions' (List of Survey_Question__c).
     */
    public static Map<String, Object> getSurveyWithQuestions(Id surveyId) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_SURVEY)) {
            throw new AuraHandledException('Survey feature is currently disabled.');
        }

        Map<String, Object> result = new Map<String, Object>();

        List<Survey__c> surveys = [
            SELECT Id, Name, Survey_Code__c, Survey_Type__c, Description__c,
                   Outlet_Type__c, Effective_From__c, Effective_To__c, Is_Mandatory__c
            FROM Survey__c
            WHERE Id = :surveyId
            LIMIT 1
        ];

        if (surveys.isEmpty()) {
            throw new AuraHandledException('Survey not found.');
        }

        result.put('survey', surveys[0]);

        List<Survey_Question__c> questions = [
            SELECT Id, Name, Question_Text__c, Question_Type__c, Options__c,
                   Sort_Order__c, Is_Required__c, Validation_Rule__c, Score_Weight__c, Survey__c
            FROM Survey_Question__c
            WHERE Survey__c = :surveyId
            ORDER BY Sort_Order__c ASC NULLS LAST
        ];

        result.put('questions', questions);

        return result;
    }

    // ── Submit Survey Response ──────────────────────────────────────────────

    /**
     * @description Inner class for deserialising individual answer entries.
     */
    public class SurveyAnswerInput {
        public Id      questionId;
        public String  answerText;
        public String  answerChoice;
        public Decimal answerNumber;
        public Decimal ratingValue;
        public Id      photoContentVersionId;
    }

    /**
     * @description Inner class for deserialising the full response payload.
     */
    public class SurveyResponseInput {
        public Id                     visitId;
        public Id                     accountId;
        public Id                     surveyId;
        public List<SurveyAnswerInput> answers;
    }

    /**
     * @description Creates a Survey_Response__c with child Survey_Answer__c records
     *              and marks the visit's Survey_Completed__c flag.
     * @param responseJson JSON string matching SurveyResponseInput structure.
     * @return The created Survey_Response__c record.
     */
    public static Survey_Response__c submitSurveyResponse(String responseJson) {
        if (!BPM_FeatureToggle_Util.isEnabled(FEATURE_SURVEY)) {
            throw new AuraHandledException('Survey feature is currently disabled.');
        }

        SurveyResponseInput input = (SurveyResponseInput)
            JSON.deserialize(responseJson, SurveyResponseInput.class);

        if (input.surveyId == null || input.visitId == null) {
            throw new AuraHandledException('Survey Id and Visit Id are required.');
        }

        // Check for duplicate submission
        List<Survey_Response__c> existing = [
            SELECT Id FROM Survey_Response__c
            WHERE Visit__c = :input.visitId
              AND Survey__c = :input.surveyId
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            throw new AuraHandledException('A response for this survey has already been submitted for this visit.');
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // Create response header
            Survey_Response__c response = new Survey_Response__c();
            response.Visit__c        = input.visitId;
            response.Account__c      = input.accountId;
            response.Survey__c       = input.surveyId;
            response.Respondent__c   = UserInfo.getUserId();
            response.Response_Date__c = Date.today();
            response.Status__c       = 'Completed';
            insert response;

            // Create answer records
            Decimal totalScore = 0;
            Decimal maxPossibleScore = 0;

            // Build question map for weight lookup
            Map<Id, Survey_Question__c> questionMap = new Map<Id, Survey_Question__c>();
            for (Survey_Question__c sq : [
                SELECT Id, Question_Type__c, Score_Weight__c
                FROM Survey_Question__c
                WHERE Survey__c = :input.surveyId
            ]) {
                questionMap.put(sq.Id, sq);
            }

            if (input.answers != null && !input.answers.isEmpty()) {
                List<Survey_Answer__c> answers = new List<Survey_Answer__c>();
                Map<Integer, Id> photoIndexMap = new Map<Integer, Id>();
                Integer idx = 0;
                for (SurveyAnswerInput ans : input.answers) {
                    Survey_Answer__c a = new Survey_Answer__c();
                    a.Survey_Response__c = response.Id;
                    a.Survey_Question__c = ans.questionId;
                    a.Answer_Text__c     = ans.answerText;
                    a.Answer_Choice__c   = ans.answerChoice;
                    a.Answer_Number__c   = ans.answerNumber;
                    a.Rating_Value__c    = ans.ratingValue;
                    answers.add(a);
                    if (ans.photoContentVersionId != null) {
                        photoIndexMap.put(idx, ans.photoContentVersionId);
                    }

                    // Weight-based scoring: only Rating and Single Choice
                    // contribute. Compute the per-answer earned/max and store it
                    // ON the answer so scoring is transparent per question, then
                    // roll the same numbers up to the response total.
                    Survey_Question__c q = questionMap.get(ans.questionId);
                    Decimal weight = (q != null && q.Score_Weight__c != null) ? q.Score_Weight__c : 0;
                    Decimal answerScore = 0;
                    Decimal answerMax = 0;
                    if (weight > 0 && q != null) {
                        String qType = q.Question_Type__c;
                        if (qType == 'Rating' && ans.ratingValue != null) {
                            answerScore = ans.ratingValue * weight;
                            answerMax = 5 * weight; // Rating max is 5
                        } else if (qType == 'Single Choice' && ans.answerChoice != null) {
                            answerScore = ans.answerChoice.equalsIgnoreCase('Yes') ? weight : 0;
                            answerMax = weight;
                        }
                    }
                    a.Answer_Score__c = answerScore;
                    a.Max_Answer_Score__c = answerMax;
                    totalScore += answerScore;
                    maxPossibleScore += answerMax;

                    idx++;
                }
                insert answers;

                // Link photo attachments to answer records
                for (Integer i : photoIndexMap.keySet()) {
                    FileAttachment_Util.linkFileToParent(photoIndexMap.get(i), answers[i].Id);
                }

                // Update response with calculated scores
                response.Total_Score__c = totalScore;
                response.Max_Possible_Score__c = maxPossibleScore;
                response.Score_Percentage__c = maxPossibleScore > 0
                    ? (totalScore / maxPossibleScore) * 100 : 0;
                update response;
            }

            // Mark visit as survey completed
            Visit__c visit = new Visit__c(Id = input.visitId);
            visit.Survey_Completed__c = true;
            update visit;

            return response;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException('Failed to submit survey response: ' + e.getMessage());
        }
    }

    // ── Existing Response Check ─────────────────────────────────────────────

    /**
     * @description Checks whether a survey response already exists for the
     *              given visit and survey combination.
     * @param visitId  The Visit__c Id.
     * @param surveyId The Survey__c Id.
     * @return The existing Survey_Response__c record, or null if none exists.
     */
    public static Survey_Response__c getExistingSurveyResponse(Id visitId, Id surveyId) {
        List<Survey_Response__c> responses = [
            SELECT Id, Name, Survey__c, Visit__c, Account__c,
                   Respondent__c, Response_Date__c, Status__c, Total_Score__c
            FROM Survey_Response__c
            WHERE Visit__c = :visitId
              AND Survey__c = :surveyId
            LIMIT 1
        ];
        return responses.isEmpty() ? null : responses[0];
    }

    // ── Survey Responses for Visit ───────────────────────────────────────

    /**
     * @description Returns all survey responses for a visit with their answers
     *              and question text for display in completed visit detail.
     * @param visitId The Visit__c Id.
     * @return List of maps with response header and answers.
     */
    public static List<Map<String, Object>> getSurveyResponsesForVisit(Id visitId) {
        List<Survey_Response__c> responses = [
            SELECT Id, Name, Survey__c, Survey__r.Name, Response_Date__c,
                   Status__c, Total_Score__c,
                   (SELECT Id, Survey_Question__c, Survey_Question__r.Question_Text__c,
                           Survey_Question__r.Question_Type__c, Survey_Question__r.Sort_Order__c,
                           Answer_Text__c, Answer_Choice__c, Answer_Number__c,
                           Rating_Value__c
                    FROM Survey_Answers__r
                    ORDER BY Survey_Question__r.Sort_Order__c ASC NULLS LAST)
            FROM Survey_Response__c
            WHERE Visit__c = :visitId
            ORDER BY Response_Date__c DESC
        ];

        // Collect all answer Ids to look up photo attachments
        Set<Id> answerIds = new Set<Id>();
        for (Survey_Response__c resp : responses) {
            if (resp.Survey_Answers__r != null) {
                for (Survey_Answer__c ans : resp.Survey_Answers__r) {
                    answerIds.add(ans.Id);
                }
            }
        }
        Map<Id, String> photoUrlMap = FileAttachment_Util.getAttachmentUrls(answerIds);

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Survey_Response__c resp : responses) {
            Map<String, Object> item = new Map<String, Object>();
            item.put('id', resp.Id);
            item.put('name', resp.Name);
            item.put('surveyName', resp.Survey__r.Name);
            item.put('responseDate', resp.Response_Date__c);
            item.put('status', resp.Status__c);
            item.put('totalScore', resp.Total_Score__c);

            List<Map<String, Object>> answers = new List<Map<String, Object>>();
            if (resp.Survey_Answers__r != null) {
                for (Survey_Answer__c ans : resp.Survey_Answers__r) {
                    Map<String, Object> a = new Map<String, Object>();
                    a.put('id', ans.Id);
                    a.put('questionText', ans.Survey_Question__r.Question_Text__c);
                    a.put('questionType', ans.Survey_Question__r.Question_Type__c);
                    String photoURL = photoUrlMap.get(ans.Id);
                    // Build display value based on question type
                    String displayValue = '';
                    if (ans.Answer_Text__c != null) displayValue = ans.Answer_Text__c;
                    else if (ans.Answer_Choice__c != null) displayValue = ans.Answer_Choice__c;
                    else if (ans.Rating_Value__c != null) displayValue = String.valueOf(ans.Rating_Value__c.intValue());
                    else if (ans.Answer_Number__c != null) displayValue = String.valueOf(ans.Answer_Number__c);
                    else if (photoURL != null) displayValue = 'Photo attached';
                    a.put('displayValue', displayValue);
                    a.put('ratingValue', ans.Rating_Value__c);
                    a.put('isRating', ans.Survey_Question__r.Question_Type__c == 'Rating');
                    a.put('isPhoto', ans.Survey_Question__r.Question_Type__c == 'Photo');
                    a.put('photoURL', photoURL);
                    answers.add(a);
                }
            }
            item.put('answers', answers);
            result.add(item);
        }
        return result;
    }

    // ── Survey Photo Upload ──────────────────────────────────────────────

    /**
     * @description Uploads a survey answer photo as a standalone ContentVersion.
     *              The file will be linked to the Survey_Answer__c record when
     *              the survey is submitted.
     * @param base64Data Base64-encoded image data.
     * @param fileName   Desired file name (without extension).
     * @return The ContentVersion Id (used to link to the answer record on submit).
     */
    public static Id uploadSurveyPhoto(String base64Data, String fileName) {
        if (String.isBlank(base64Data)) {
            throw new AuraHandledException('No photo data provided.');
        }
        try {
            return FileAttachment_Util.saveFileStandalone(base64Data, fileName);
        } catch (Exception e) {
            throw new AuraHandledException('Failed to upload photo: ' + e.getMessage());
        }
    }
}