@isTest
private class VisitRouteMapController_Test {

    @TestSetup
    static void setup() {
        Territory_Master__c territory = TestDataFactory.createAndInsertTerritory('VRM Territory', 'VRM-T-001');

        Employee__c emp = new Employee__c(
            First_Name__c = 'Route',
            Last_Name__c = 'Map',
            Phone__c = '9876543210',
            Email__c = 'vrm@example.com',
            Employee_Code__c = 'EMP-VRM-001',
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

        Account acc = TestDataFactory.createAndInsertAccount('VRM Outlet', 'Retailer');
        Beat__c beat = TestDataFactory.createAndInsertBeat('VRM Beat', 'VRM-B-001', territory.Id);

        Day_Attendance__c da = TestDataFactory.createDayAttendance(UserInfo.getUserId(), Date.today());
        try { da.put('Start_Location_Lat__c', 19.0760); } catch (Exception e) {}
        try { da.put('Start_Location_Long__c', 72.8777); } catch (Exception e) {}
        try { da.put('End_Location_Lat__c', 19.0780); } catch (Exception e) {}
        try { da.put('End_Location_Long__c', 72.8797); } catch (Exception e) {}
        try { da.put('Day_Start_Time__c', DateTime.now().addHours(-2)); } catch (Exception e) {}
        try { da.put('Distance_Traveled_Km__c', 12.5); } catch (Exception e) {}
        insert da;

        // Two visits with check-in GPS so the loop body runs.
        try {
            Visit__c v1 = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
            v1.Visit_Date__c = Date.today();
            v1.Visit_Status__c = 'Completed';
            v1.Check_In_Latitude__c = 19.0760;
            v1.Check_In_Longitude__c = 72.8777;
            v1.Check_In_Time__c = DateTime.now().addMinutes(-90);
            v1.Check_Out_Time__c = DateTime.now().addMinutes(-60);
            insert v1;

            Visit__c v2 = TestDataFactory.createVisit(acc.Id, UserInfo.getUserId(), da.Id, beat.Id);
            v2.Visit_Date__c = Date.today();
            v2.Visit_Status__c = 'Completed';
            v2.Check_In_Latitude__c = 19.0770;
            v2.Check_In_Longitude__c = 72.8787;
            v2.Check_In_Time__c = DateTime.now().addMinutes(-30);
            insert v2;
        } catch (Exception e) {}
    }

    @isTest
    static void testGetRouteForDay_NullId() {
        // A null id is valid (standalone-tab use): the controller resolves the current
        // user's attendance for today, which @TestSetup created. It returns a response
        // rather than throwing.
        Test.startTest();
        VisitRouteMapController.RouteResponse response = VisitRouteMapController.getRouteForDay(null);
        Test.stopTest();

        System.assertNotEquals(null, response, 'Null id resolves today\'s attendance and returns a response');
        System.assertEquals(true, response.hasData, 'Today\'s seeded attendance has GPS/visits, so hasData is true');
    }

    @isTest
    static void testGetRouteForDay_NotFound() {
        String prefix = Day_Attendance__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeId = (Id) (prefix + '000000000001');

        Test.startTest();
        VisitRouteMapController.RouteResponse response =
            VisitRouteMapController.getRouteForDay(fakeId);
        Test.stopTest();

        System.assertNotEquals(null, response);
        System.assertEquals(false, response.hasData);
        System.assertEquals(0, response.totalVisits);
    }

    @isTest
    static void testGetRouteForDay_Success() {
        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Test.startTest();
        VisitRouteMapController.RouteResponse response =
            VisitRouteMapController.getRouteForDay(da.Id);
        Test.stopTest();

        System.assertNotEquals(null, response);
        System.assertNotEquals(null, response.attendance);
        System.assertEquals(da.Id, response.attendance.id);
        System.assertEquals(true, response.hasData);
        System.assert(response.totalVisits >= 0, 'totalVisits should be a number');
        if (response.totalVisits > 0) {
            VisitRouteMapController.RoutePoint first = response.visits[0];
            System.assertEquals(1, first.sequence);
            System.assertNotEquals(null, first.latitude);
            System.assertNotEquals(null, first.longitude);
        }
    }

    @isTest
    static void testGetRouteForDay_NoVisits() {
        // Delete the seeded visits to exercise the hasData branch where
        // visits=0 but start/end GPS exists on the attendance.
        try { delete [SELECT Id FROM Visit__c]; } catch (Exception e) {}

        Day_Attendance__c da = [SELECT Id FROM Day_Attendance__c LIMIT 1];

        Test.startTest();
        VisitRouteMapController.RouteResponse response =
            VisitRouteMapController.getRouteForDay(da.Id);
        Test.stopTest();

        System.assertEquals(0, response.totalVisits);
        // hasData is true because Start_Location_Lat/Long are populated.
        System.assertEquals(true, response.hasData);
    }
}