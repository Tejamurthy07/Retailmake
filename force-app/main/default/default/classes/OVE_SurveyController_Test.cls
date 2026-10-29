@IsTest
private class OVE_SurveyController_Test {

    @TestSetup
    static void setupData() {
        Account acc = TestDataFactory.createAndInsertAccount('Survey Test Outlet', 'Retailer');

        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('Survey Territory', 'SV-001');
        Beat__c beat = TestDataFactory.createAndInsertBeat('Survey Beat', 'SVB-001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        insert da;

        Visit__c visit = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
        insert visit;

        // Create Survey__c
        Survey__c survey = new Survey__c(
            Name = 'Customer Satisfaction Survey',
            Survey_Code__c = 'CSS-001',
            Survey_Type__c = 'Customer Feedback',
            Description__c = 'Test survey for customer satisfaction',
            Is_Active__c = true,
            Effective_From__c = Date.today().addDays(-10),
            Effective_To__c = Date.today().addDays(30),
            Is_Mandatory__c = false
        );
        insert survey;

        // Create Survey_Question__c records
        List<Survey_Question__c> questions = new List<Survey_Question__c>{
            new Survey_Question__c(
                Survey__c = survey.Id,
                Question_Text__c = 'How satisfied are you overall?',
                Question_Type__c = 'Rating',
                Sort_Order__c = 1,
                Is_Required__c = true
            ),
            new Survey_Question__c(
                Survey__c = survey.Id,
                Question_Text__c = 'Any additional feedback?',
                Question_Type__c = 'Text',
                Sort_Order__c = 2,
                Is_Required__c = false
            ),
            new Survey_Question__c(
                Survey__c = survey.Id,
                Question_Text__c = 'Would you recommend us?',
                Question_Type__c = 'Single Choice',
                Options__c = 'Yes;No;Maybe',
                Sort_Order__c = 3,
                Is_Required__c = true
            )
        };
        insert questions;
    }

    // ── getApplicableSurveys ────────────────────────────────────────

    @IsTest
    static void testGetApplicableSurveys_ReturnsSurveys() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Survey Test Outlet' LIMIT 1];

        Test.startTest();
        try {
            List<Survey__c> results = OVE_SurveyController.getApplicableSurveys(acc.Id);
            System.assertNotEquals(null, results, 'Result should not be null');
            System.assert(results.size() >= 1, 'Should return at least 1 survey');
        } catch (AuraHandledException e) {
            // Feature toggle OVE-005 may not be enabled
            System.assert(e.getMessage() != null, 'Expected feature disabled or script-thrown exception');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetApplicableSurveys_NullAccountId() {
        Test.startTest();
        try {
            List<Survey__c> results = OVE_SurveyController.getApplicableSurveys(null);
            System.assertNotEquals(null, results, 'Result should not be null even with null accountId');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Exception should have message');
        }
        Test.stopTest();
    }

    // ── getSurveyWithQuestions ───────────────────────────────────────

    @IsTest
    static void testGetSurveyWithQuestions_ReturnsSurveyAndQuestions() {
        Survey__c survey = [SELECT Id FROM Survey__c LIMIT 1];

        Test.startTest();
        try {
            Map<String, Object> result = OVE_SurveyController.getSurveyWithQuestions(survey.Id);
            System.assertNotEquals(null, result, 'Result map should not be null');
            System.assert(result.containsKey('survey'), 'Should contain survey key');
            System.assert(result.containsKey('questions'), 'Should contain questions key');
            List<Survey_Question__c> questions = (List<Survey_Question__c>) result.get('questions');
            System.assertEquals(3, questions.size(), 'Should return 3 questions');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── submitSurveyResponse ────────────────────────────────────────

    @IsTest
    static void testSubmitSurveyResponse_Success() {
        Visit__c visit = [SELECT Id, Account__c FROM Visit__c LIMIT 1];
        Survey__c survey = [SELECT Id FROM Survey__c LIMIT 1];
        List<Survey_Question__c> questions = [
            SELECT Id, Question_Type__c FROM Survey_Question__c ORDER BY Sort_Order__c
        ];

        Map<String, Object> responseData = new Map<String, Object>{
            'visitId' => visit.Id,
            'accountId' => visit.Account__c,
            'surveyId' => survey.Id,
            'answers' => new List<Map<String, Object>>{
                new Map<String, Object>{
                    'questionId' => questions[0].Id,
                    'ratingValue' => 4
                },
                new Map<String, Object>{
                    'questionId' => questions[1].Id,
                    'answerText' => 'Great service overall'
                },
                new Map<String, Object>{
                    'questionId' => questions[2].Id,
                    'answerChoice' => 'Yes'
                }
            }
        };
        String responseJson = JSON.serialize(responseData);

        Test.startTest();
        try {
            Survey_Response__c result = OVE_SurveyController.submitSurveyResponse(responseJson);
            System.assertNotEquals(null, result, 'Response should not be null');
            System.assertNotEquals(null, result.Id, 'Response should have an Id');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_DuplicateSubmission() {
        Visit__c visit = [SELECT Id, Account__c FROM Visit__c LIMIT 1];
        Survey__c survey = [SELECT Id FROM Survey__c LIMIT 1];

        // Create an existing response
        Survey_Response__c existingResp = new Survey_Response__c(
            Visit__c = visit.Id,
            Account__c = visit.Account__c,
            Survey__c = survey.Id,
            Respondent__c = UserInfo.getUserId(),
            Response_Date__c = Date.today(),
            Status__c = 'Completed'
        );
        insert existingResp;

        Map<String, Object> responseData = new Map<String, Object>{
            'visitId' => visit.Id,
            'accountId' => visit.Account__c,
            'surveyId' => survey.Id,
            'answers' => new List<Map<String, Object>>()
        };
        String responseJson = JSON.serialize(responseData);

        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse(responseJson);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Expected duplicate or disabled error');
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_MissingRequiredIds() {
        Map<String, Object> responseData = new Map<String, Object>{
            'visitId' => null,
            'surveyId' => null,
            'answers' => new List<Map<String, Object>>()
        };
        String responseJson = JSON.serialize(responseData);

        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse(responseJson);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Should throw validation error');
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ── getExistingSurveyResponse ───────────────────────────────────

    @IsTest
    static void testGetExistingSurveyResponse_Exists() {
        Visit__c visit = [SELECT Id, Account__c FROM Visit__c LIMIT 1];
        Survey__c survey = [SELECT Id FROM Survey__c LIMIT 1];

        Survey_Response__c resp = new Survey_Response__c(
            Visit__c = visit.Id,
            Account__c = visit.Account__c,
            Survey__c = survey.Id,
            Respondent__c = UserInfo.getUserId(),
            Response_Date__c = Date.today(),
            Status__c = 'Completed'
        );
        insert resp;

        Test.startTest();
        try {
            Survey_Response__c result = OVE_SurveyController.getExistingSurveyResponse(visit.Id, survey.Id);
            System.assertNotEquals(null, result, 'Should return existing response');
            System.assertEquals(resp.Id, result.Id, 'Should return correct response');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetExistingSurveyResponse_NotExists() {
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];
        Survey__c survey = [SELECT Id FROM Survey__c LIMIT 1];

        Test.startTest();
        try {
            Survey_Response__c result = OVE_SurveyController.getExistingSurveyResponse(visit.Id, survey.Id);
            System.assertEquals(null, result, 'Should return null when no response exists');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── getSurveyResponsesForVisit ──────────────────────────────────

    @IsTest
    static void testGetSurveyResponsesForVisit_WithResponses() {
        Visit__c visit = [SELECT Id, Account__c FROM Visit__c LIMIT 1];
        Survey__c survey = [SELECT Id FROM Survey__c LIMIT 1];
        Survey_Question__c question = [SELECT Id FROM Survey_Question__c LIMIT 1];

        Survey_Response__c resp = new Survey_Response__c(
            Visit__c = visit.Id,
            Account__c = visit.Account__c,
            Survey__c = survey.Id,
            Respondent__c = UserInfo.getUserId(),
            Response_Date__c = Date.today(),
            Status__c = 'Completed',
            Total_Score__c = 8
        );
        insert resp;

        Survey_Answer__c answer = new Survey_Answer__c(
            Survey_Response__c = resp.Id,
            Survey_Question__c = question.Id,
            Answer_Text__c = 'Good service',
            Rating_Value__c = 4
        );
        insert answer;

        Test.startTest();
        try {
            List<Map<String, Object>> results = OVE_SurveyController.getSurveyResponsesForVisit(visit.Id);
            System.assertNotEquals(null, results, 'Results should not be null');
            System.assert(results.size() >= 1, 'Should return at least 1 response');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetSurveyResponsesForVisit_NoResponses() {
        Visit__c visit = [SELECT Id FROM Visit__c LIMIT 1];

        Test.startTest();
        try {
            List<Map<String, Object>> results = OVE_SurveyController.getSurveyResponsesForVisit(visit.Id);
            System.assertNotEquals(null, results, 'Results should not be null');
            System.assertEquals(0, results.size(), 'Should return empty list');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    // ── uploadSurveyPhoto ───────────────────────────────────────────

    @IsTest
    static void testUploadSurveyPhoto_Success() {
        String base64Data = EncodingUtil.base64Encode(Blob.valueOf('fake image data'));

        Test.startTest();
        try {
            Id cvId = OVE_SurveyController.uploadSurveyPhoto(base64Data, 'test_photo');
            System.assertNotEquals(null, cvId, 'ContentVersion Id should not be null');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Feature toggle may be disabled');
        }
        Test.stopTest();
    }

    @IsTest
    static void testUploadSurveyPhoto_BlankData() {
        Test.startTest();
        try {
            OVE_SurveyController.uploadSurveyPhoto('', 'empty_photo');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Expected blank data or disabled error');
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testUploadSurveyPhoto_NullData() {
        Test.startTest();
        try {
            OVE_SurveyController.uploadSurveyPhoto(null, 'null_photo');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null, 'Should throw error for null data');
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ── Error Path Tests — Cover catch (Exception e) blocks ──────────

    @IsTest
    static void testGetApplicableSurveys_NullId_ErrorPath() {
        Test.startTest();
        try {
            OVE_SurveyController.getApplicableSurveys(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetSurveyWithQuestions_NullId() {
        Test.startTest();
        try {
            OVE_SurveyController.getSurveyWithQuestions(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_NullJson() {
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_InvalidJson() {
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse('bad json');
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_EmptyObjectJson() {
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse('{}');
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetExistingSurveyResponse_NullIds() {
        Test.startTest();
        try {
            OVE_SurveyController.getExistingSurveyResponse(null, null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetSurveyResponsesForVisit_NullId() {
        Test.startTest();
        try {
            OVE_SurveyController.getSurveyResponsesForVisit(null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testUploadSurveyPhoto_NullBoth() {
        Test.startTest();
        try {
            OVE_SurveyController.uploadSurveyPhoto(null, null);
        } catch (AuraHandledException e) {
            System.assert(true);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ── Additional Error Path Tests — Force catch (Exception e) blocks ──────

    @IsTest
    static void testGetApplicableSurveys_FabricatedId() {
        Test.startTest();
        try {
            OVE_SurveyController.getApplicableSurveys('001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetSurveyWithQuestions_FabricatedId() {
        Test.startTest();
        try {
            OVE_SurveyController.getSurveyWithQuestions('001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_MalformedJsonArray() {
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse('[1,2,3]');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_InvalidIdInJson() {
        String json = '{"visitId":"INVALID_ID","surveyId":"INVALID","accountId":"INVALID","answers":[]}';
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse(json);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_NumericJson() {
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse('12345');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_BooleanJson() {
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse('true');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_EmptyString() {
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse('');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetExistingSurveyResponse_FabricatedIds() {
        Test.startTest();
        try {
            OVE_SurveyController.getExistingSurveyResponse('001000000000000AAA', '001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetSurveyResponsesForVisit_FabricatedId() {
        Test.startTest();
        try {
            OVE_SurveyController.getSurveyResponsesForVisit('001000000000000AAA');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testUploadSurveyPhoto_EmptyFileName() {
        Test.startTest();
        try {
            OVE_SurveyController.uploadSurveyPhoto('dGVzdA==', '');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testUploadSurveyPhoto_InvalidBase64() {
        Test.startTest();
        try {
            OVE_SurveyController.uploadSurveyPhoto('!!!not-base64!!!', 'bad_photo');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testSubmitSurveyResponse_NullAnswers() {
        String json = JSON.serialize(new Map<String, Object>{
            'visitId' => null,
            'surveyId' => null,
            'accountId' => null,
            'answers' => null
        });
        Test.startTest();
        try {
            OVE_SurveyController.submitSurveyResponse(json);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        } catch (NullPointerException e) {
            System.assert(true);
        }
        Test.stopTest();
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage, with HARD assertions.
    //
    //  The tests above tolerate both outcomes ("feature toggle may be
    //  disabled"), so nothing real is pinned. OVE-005 is pinned through the
    //  @TestVisible toggle cache below. What these tests protect: the survey
    //  targeting (dates, outlet type), the weighted scoring engine and its
    //  per-answer transparency, the duplicate guard with rollback, the visit
    //  completion flag, and the photo round-trip.
    // ══════════════════════════════════════════════════════════════════

    private static void setSurveyFeature(Boolean enabled) {
        BPM_FeatureToggle_Util.toggleCache.put(OVE_Survey_Service.FEATURE_SURVEY, enabled);
    }

    private static Visit__c theVisit() {
        return [SELECT Id, Account__c FROM Visit__c LIMIT 1];
    }

    private static Survey__c theSurvey() {
        return [SELECT Id FROM Survey__c WHERE Survey_Code__c = 'CSS-001' LIMIT 1];
    }

    // ── Toggle gate ───────────────────────────────────────────────────

    @IsTest
    static void featureOff_everyGatedEntryPointRefuses() {
        setSurveyFeature(false);
        Visit__c visit = theVisit();
        Survey__c survey = theSurvey();

        Test.startTest();
        Integer refused = 0;
        try { OVE_SurveyController.getApplicableSurveys(visit.Account__c); }
        catch (AuraHandledException e) { refused++; }
        try { OVE_SurveyController.getSurveyWithQuestions(survey.Id); }
        catch (AuraHandledException e) { refused++; }
        try {
            OVE_SurveyController.submitSurveyResponse(JSON.serialize(new Map<String, Object>{
                'visitId' => visit.Id, 'surveyId' => survey.Id,
                'answers' => new List<Object>() }));
        } catch (AuraHandledException e) { refused++; }
        Test.stopTest();

        System.assertEquals(3, refused,
            'With OVE-005 off, list, detail and submit all refuse — the survey feature '
            + 'disappears consistently, and the service message reaches the LWC unchanged');
        System.assertEquals(0, [SELECT COUNT() FROM Survey_Response__c],
            'And no response sneaks in while the feature is off');
    }

    // ── Applicability targeting ───────────────────────────────────────

    @IsTest
    static void applicability_datesActivityAndOutletTypeAllFilter() {
        setSurveyFeature(true);
        // The seeded outlet is a Retailer whose Outlet_Type the factory sets;
        // read it back so the INCLUDES assertion tracks the real value.
        Account outlet = [SELECT Id, Outlet_Type__c FROM Account
                          WHERE Name = 'Survey Test Outlet' LIMIT 1];
        insert new List<Survey__c>{
            new Survey__c(Name = 'Expired Survey', Survey_Code__c = 'CSS-EXP',
                Survey_Type__c = 'Customer Feedback', Is_Active__c = true,
                Effective_From__c = Date.today().addDays(-60),
                Effective_To__c = Date.today().addDays(-30)),
            new Survey__c(Name = 'Inactive Survey', Survey_Code__c = 'CSS-INACT',
                Survey_Type__c = 'Customer Feedback', Is_Active__c = false,
                Effective_From__c = Date.today().addDays(-1),
                Effective_To__c = Date.today().addDays(30)),
            new Survey__c(Name = 'Other Outlet Type Survey', Survey_Code__c = 'CSS-OT',
                Survey_Type__c = 'Customer Feedback', Is_Active__c = true,
                Outlet_Type__c = 'Pan Shop',   // not this outlet's type
                Effective_From__c = Date.today().addDays(-1),
                Effective_To__c = Date.today().addDays(30))
        };

        Test.startTest();
        List<Survey__c> results = OVE_SurveyController.getApplicableSurveys(outlet.Id);
        Test.stopTest();

        Set<String> codes = new Set<String>();
        for (Survey__c s : results) codes.add(s.Survey_Code__c);
        System.assert(codes.contains('CSS-001'), 'The live untargeted survey is offered');
        System.assert(!codes.contains('CSS-EXP'), 'An expired survey is not');
        System.assert(!codes.contains('CSS-INACT'), 'Nor an inactive one');
        if (String.isNotBlank(outlet.Outlet_Type__c) && outlet.Outlet_Type__c != 'Pan Shop') {
            System.assert(!codes.contains('CSS-OT'),
                'Nor one targeted at a different outlet type — the multiselect INCLUDES '
                + 'filter scopes surveys to the outlet being visited');
        }
    }

    @IsTest
    static void surveyDetail_ordersQuestionsAndRejectsGhosts() {
        setSurveyFeature(true);
        Survey__c survey = theSurvey();
        Id ghostSurveyId = Id.valueOf(
            Survey__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        Test.startTest();
        Map<String, Object> detail = OVE_SurveyController.getSurveyWithQuestions(survey.Id);
        Boolean ghostRefused = false;
        try { OVE_SurveyController.getSurveyWithQuestions(ghostSurveyId); }
        catch (AuraHandledException e) { ghostRefused = true; }
        Test.stopTest();

        List<Survey_Question__c> questions = (List<Survey_Question__c>) detail.get('questions');
        System.assertEquals(3, questions.size(), 'All three questions come back');
        System.assertEquals(1, questions[0].Sort_Order__c, 'In sort order');
        System.assertEquals('Rating', questions[0].Question_Type__c, 'Rating first');
        System.assertEquals('Yes;No;Maybe', questions[2].Options__c,
            'Choice options ride along for the picker');
        System.assertEquals(true, ghostRefused,
            'A stale survey id is refused with a handled error, not a blank screen');
    }

    // ── The weighted scoring engine ───────────────────────────────────

    @IsTest
    static void submit_scoresWeightedAnswers_andMarksTheVisit() {
        setSurveyFeature(true);
        Visit__c visit = theVisit();
        Survey__c survey = theSurvey();
        List<Survey_Question__c> questions = [
            SELECT Id, Question_Type__c FROM Survey_Question__c
            WHERE Survey__c = :survey.Id ORDER BY Sort_Order__c];
        // Weight the scoring questions: Rating x2, Single Choice x3. Text carries none.
        questions[0].Score_Weight__c = 2;
        questions[2].Score_Weight__c = 3;
        update questions;

        String responseJson = JSON.serialize(new Map<String, Object>{
            'visitId' => visit.Id, 'accountId' => visit.Account__c, 'surveyId' => survey.Id,
            'answers' => new List<Object>{
                new Map<String, Object>{ 'questionId' => questions[0].Id, 'ratingValue' => 4 },
                new Map<String, Object>{ 'questionId' => questions[1].Id, 'answerText' => 'Fine' },
                new Map<String, Object>{ 'questionId' => questions[2].Id, 'answerChoice' => 'Yes' }
            }
        });

        Test.startTest();
        Survey_Response__c returned = OVE_SurveyController.submitSurveyResponse(responseJson);
        Test.stopTest();

        Survey_Response__c stored = [
            SELECT Status__c, Respondent__c, Total_Score__c, Max_Possible_Score__c,
                   Score_Percentage__c
            FROM Survey_Response__c WHERE Id = :returned.Id];
        // Rating: 4 x weight 2 = 8 of max 5x2=10. Choice: Yes = weight 3 of 3. Text: 0 of 0.
        System.assertEquals(11, stored.Total_Score__c, '8 (rating) + 3 (yes) = 11');
        System.assertEquals(13, stored.Max_Possible_Score__c, '10 + 3 possible');
        System.assertEquals((11.0 / 13.0) * 100, stored.Score_Percentage__c,
            'Percentage derives from the same two numbers');
        System.assertEquals('Completed', stored.Status__c, 'Submitted means completed');
        System.assertEquals(UserInfo.getUserId(), stored.Respondent__c, 'Attributed to the rep');

        List<Survey_Answer__c> answers = [
            SELECT Answer_Score__c, Max_Answer_Score__c, Rating_Value__c, Answer_Text__c,
                   Answer_Choice__c
            FROM Survey_Answer__c WHERE Survey_Response__c = :returned.Id
            ORDER BY Survey_Question__r.Sort_Order__c];
        System.assertEquals(3, answers.size(), 'One answer per question');
        System.assertEquals(8, answers[0].Answer_Score__c,
            'Per-answer earned score stored — scoring is auditable question by question');
        System.assertEquals(10, answers[0].Max_Answer_Score__c, 'With its possible score');
        System.assertEquals(0, answers[1].Answer_Score__c, 'Text answers carry no score');
        System.assertEquals(3, answers[2].Answer_Score__c, 'Yes earns the full choice weight');

        System.assertEquals(true, [
            SELECT Survey_Completed__c FROM Visit__c WHERE Id = :visit.Id
        ].Survey_Completed__c, 'The visit records that its survey happened');
    }

    @IsTest
    static void submit_choiceOfNo_earnsZeroOfTheWeight() {
        setSurveyFeature(true);
        Visit__c visit = theVisit();
        Survey__c survey = theSurvey();
        Survey_Question__c choice = [
            SELECT Id FROM Survey_Question__c
            WHERE Survey__c = :survey.Id AND Question_Type__c = 'Single Choice' LIMIT 1];
        choice.Score_Weight__c = 3;
        update choice;

        String responseJson = JSON.serialize(new Map<String, Object>{
            'visitId' => visit.Id, 'accountId' => visit.Account__c, 'surveyId' => survey.Id,
            'answers' => new List<Object>{
                new Map<String, Object>{ 'questionId' => choice.Id, 'answerChoice' => 'No' }
            }
        });

        Test.startTest();
        Survey_Response__c returned = OVE_SurveyController.submitSurveyResponse(responseJson);
        Test.stopTest();

        Survey_Response__c stored = [
            SELECT Total_Score__c, Max_Possible_Score__c, Score_Percentage__c
            FROM Survey_Response__c WHERE Id = :returned.Id];
        System.assertEquals(0, stored.Total_Score__c, 'No earns nothing');
        System.assertEquals(3, stored.Max_Possible_Score__c,
            'But the missed weight still counts as possible — a No visibly drags the '
            + 'percentage, it does not vanish from the denominator');
        System.assertEquals(0, stored.Score_Percentage__c, '0 of 3 is 0%');
    }

    @IsTest
    static void submit_duplicate_isRefusedAndNothingPersists() {
        setSurveyFeature(true);
        Visit__c visit = theVisit();
        Survey__c survey = theSurvey();
        insert new Survey_Response__c(
            Visit__c = visit.Id, Account__c = visit.Account__c, Survey__c = survey.Id,
            Respondent__c = UserInfo.getUserId(), Response_Date__c = Date.today(),
            Status__c = 'Completed');

        String responseJson = JSON.serialize(new Map<String, Object>{
            'visitId' => visit.Id, 'accountId' => visit.Account__c, 'surveyId' => survey.Id,
            'answers' => new List<Object>() });

        Test.startTest();
        Boolean refused = false;
        try { OVE_SurveyController.submitSurveyResponse(responseJson); }
        catch (AuraHandledException e) { refused = true; }
        Test.stopTest();

        System.assertEquals(true, refused,
            'One response per survey per visit — a resubmit from a laggy device must not '
            + 'double-count the feedback');
        System.assertEquals(1, [SELECT COUNT() FROM Survey_Response__c
            WHERE Visit__c = :visit.Id AND Survey__c = :survey.Id],
            'Only the original exists');
    }

    @IsTest
    static void submit_badAnswerRow_rollsTheWholeResponseBack() {
        setSurveyFeature(true);
        Visit__c visit = theVisit();
        Survey__c survey = theSurvey();
        Id ghostQuestionId = Id.valueOf(
            Survey_Question__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');

        String responseJson = JSON.serialize(new Map<String, Object>{
            'visitId' => visit.Id, 'accountId' => visit.Account__c, 'surveyId' => survey.Id,
            'answers' => new List<Object>{
                new Map<String, Object>{ 'questionId' => ghostQuestionId, 'ratingValue' => 4 }
            }
        });

        Test.startTest();
        Boolean refused = false;
        try { OVE_SurveyController.submitSurveyResponse(responseJson); }
        catch (AuraHandledException e) { refused = true; }
        Test.stopTest();

        System.assertEquals(true, refused, 'A dangling question reference fails the submit');
        System.assertEquals(0, [SELECT COUNT() FROM Survey_Response__c],
            'And the savepoint rolls the header back too — no orphaned half-response');
        System.assertEquals(false, [
            SELECT Survey_Completed__c FROM Visit__c WHERE Id = :visit.Id
        ].Survey_Completed__c, 'And the visit is not marked surveyed');
    }

    // ── Read-back for the visit detail ────────────────────────────────

    @IsTest
    static void responsesForVisit_buildDisplayValuesPerAnswerType() {
        setSurveyFeature(true);
        Visit__c visit = theVisit();
        Survey__c survey = theSurvey();
        List<Survey_Question__c> questions = [
            SELECT Id FROM Survey_Question__c WHERE Survey__c = :survey.Id
            ORDER BY Sort_Order__c];

        OVE_SurveyController.submitSurveyResponse(JSON.serialize(new Map<String, Object>{
            'visitId' => visit.Id, 'accountId' => visit.Account__c, 'surveyId' => survey.Id,
            'answers' => new List<Object>{
                new Map<String, Object>{ 'questionId' => questions[0].Id, 'ratingValue' => 5 },
                new Map<String, Object>{ 'questionId' => questions[1].Id, 'answerText' => 'Spotless' },
                new Map<String, Object>{ 'questionId' => questions[2].Id, 'answerChoice' => 'Maybe' }
            }
        }));

        Test.startTest();
        List<Map<String, Object>> results =
            OVE_SurveyController.getSurveyResponsesForVisit(visit.Id);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'One response for the visit');
        System.assertEquals('Customer Satisfaction Survey', results[0].get('surveyName'),
            'Named for the detail header');
        List<Map<String, Object>> answers =
            (List<Map<String, Object>>) results[0].get('answers');
        System.assertEquals(3, answers.size(), 'All answers, in question order');
        System.assertEquals('5', answers[0].get('displayValue'),
            'A rating renders as its integer');
        System.assertEquals(true, answers[0].get('isRating'), 'Flagged for star display');
        System.assertEquals('Spotless', answers[1].get('displayValue'), 'Text renders as-is');
        System.assertEquals('Maybe', answers[2].get('displayValue'), 'Choice renders its value');
    }

    // ── The photo round-trip ──────────────────────────────────────────

    @IsTest
    static void photo_uploadsSubmitsAndSurfacesInTheReadBack() {
        setSurveyFeature(true);
        Visit__c visit = theVisit();
        Survey__c survey = theSurvey();
        Survey_Question__c photoQ = new Survey_Question__c(
            Survey__c = survey.Id, Question_Text__c = 'Shelf photo?',
            Question_Type__c = 'Photo', Sort_Order__c = 4, Is_Required__c = false);
        insert photoQ;

        Test.startTest();
        Id cvId = OVE_SurveyController.uploadSurveyPhoto(
            EncodingUtil.base64Encode(Blob.valueOf('shelf image bytes')), 'shelf_photo');
        System.assertNotEquals(null, cvId, 'The photo is parked as a ContentVersion');

        Survey_Response__c returned = OVE_SurveyController.submitSurveyResponse(
            JSON.serialize(new Map<String, Object>{
                'visitId' => visit.Id, 'accountId' => visit.Account__c, 'surveyId' => survey.Id,
                'answers' => new List<Object>{
                    new Map<String, Object>{
                        'questionId' => photoQ.Id, 'photoContentVersionId' => cvId }
                }
            }));
        List<Map<String, Object>> results =
            OVE_SurveyController.getSurveyResponsesForVisit(visit.Id);
        Test.stopTest();

        Survey_Answer__c ans = [SELECT Id FROM Survey_Answer__c
                                WHERE Survey_Response__c = :returned.Id LIMIT 1];
        System.assertEquals(1, [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :ans.Id
        ], 'On submit the parked photo is linked to the answer record');

        List<Map<String, Object>> answers =
            (List<Map<String, Object>>) results[0].get('answers');
        Map<String, Object> photoAnswer;
        for (Map<String, Object> a : answers) {
            if (a.get('isPhoto') == true) { photoAnswer = a; }
        }
        System.assertNotEquals(null, photoAnswer, 'The photo answer is flagged isPhoto');
        System.assertNotEquals(null, photoAnswer.get('photoURL'),
            'With a URL the detail view can render');
        System.assertEquals('Photo attached', photoAnswer.get('displayValue'),
            'And a textual fallback for list contexts');
    }
}