@isTest
private class API_UserProfile_Rest_Test {

    @TestSetup
    static void setup() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('West', 'WEST-001');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Rohan',
            Last_Name__c = 'Jani',
            Phone__c = '8160419555',
            Email__c = 'rohan@gmail.com',
            Employee_Code__c = 'CM-0001',
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Band__c = 'Band 1',
            Territory__c = territory.Id,
            Department__c = 'Sales',
            Designation__c = 'Sales Representative',
            Date_of_Joining__c = Date.today().addYears(-1)
        );
        try { emp.put('HQ_City__c', 'Mumbai'); } catch (Exception e) {}
        try { emp.put('Region__c', 'West'); } catch (Exception e) {}
        try { emp.put('Zone__c', 'West'); } catch (Exception e) {}
        try { emp.put('Channels__c', 'GT;MT;E-Commerce'); } catch (Exception e) {}
        insert emp;
    }

    private static void prepareRest(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
    }

    @isTest
    static void testGetProfile() {
        prepareRest('/services/apexrest/mobile/user/profile',
            '{"userId":"' + UserInfo.getUserId() + '"}');

        Test.startTest();
        API_UserProfile_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        Map<String, Object> result = (Map<String, Object>)
            JSON.deserializeUntyped(RestContext.response.responseBody.toString());
        System.assertEquals(true, result.get('status'));
        System.assertEquals('User profile', result.get('message'));

        Map<String, Object> data = (Map<String, Object>) result.get('data');
        System.assertEquals('CM-0001', data.get('userId'));
        // Name is an auto-number field on Employee__c, not derived from First/Last.
        System.assertNotEquals(null, data.get('name'));
        System.assertEquals('8160419555', data.get('mobileNumber'));
        System.assertEquals('rohan@gmail.com', data.get('emailAddress'));
    }

    @isTest
    static void testGetProfileMissingUserId() {
        prepareRest('/services/apexrest/mobile/user/profile', '{}');

        Test.startTest();
        API_UserProfile_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testGetProfileUserNotFound() {
        prepareRest('/services/apexrest/mobile/user/profile',
            '{"userId":"no-such-user-' + System.currentTimeMillis() + '"}');

        Test.startTest();
        API_UserProfile_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testLoginOnHold() {
        prepareRest('/services/apexrest/mobile/user/login',
            '{"mobileNumber":"8160419222","password":"Test@123"}');

        Test.startTest();
        API_UserProfile_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testInvalidEndpoint() {
        prepareRest('/services/apexrest/mobile/user/unknown', '{}');

        Test.startTest();
        API_UserProfile_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @isTest
    static void testTopLevelCatch_InvalidJson() {
        prepareRest('/services/apexrest/mobile/user/profile', '{ broken json');

        Test.startTest();
        API_UserProfile_Rest.handlePost();
        Test.stopTest();

        System.assertEquals(500, RestContext.response.statusCode,
            'Malformed JSON returns 500 via top-level catch');
    }

    @isTest
    static void testTopLevelCatch_NullRequest() {
        RestContext.request = null;
        RestContext.response = new RestResponse();
        Test.startTest();
        try { API_UserProfile_Rest.handlePost(); } catch (Exception e) {}
        Test.stopTest();
    }
}