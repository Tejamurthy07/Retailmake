public with sharing class VisitRouteMapController {

    public class RoutePoint {
        @AuraEnabled public String id;
        @AuraEnabled public String label;
        @AuraEnabled public String accountName;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public Datetime checkInTime;
        @AuraEnabled public Datetime checkOutTime;
        @AuraEnabled public String visitStatus;
        @AuraEnabled public Integer sequence;
    }

    public class DayInfo {
        @AuraEnabled public String id;
        @AuraEnabled public Date attendanceDate;
        @AuraEnabled public Decimal startLatitude;
        @AuraEnabled public Decimal startLongitude;
        @AuraEnabled public Decimal endLatitude;
        @AuraEnabled public Decimal endLongitude;
        @AuraEnabled public Datetime dayStartTime;
        @AuraEnabled public Datetime dayEndTime;
        @AuraEnabled public Decimal distanceTraveledKm;
        @AuraEnabled public String salespersonName;
        @AuraEnabled public Decimal totalVisitsField;
        @AuraEnabled public Decimal productiveCalls;
        @AuraEnabled public Decimal nonProductiveVisits;
        @AuraEnabled public Decimal productivityPercent;
        @AuraEnabled public Decimal hoursWorked;
        @AuraEnabled public Decimal totalOrders;
        @AuraEnabled public Decimal totalOrderValue;
    }

    public class RouteResponse {
        @AuraEnabled public DayInfo attendance;
        @AuraEnabled public List<RoutePoint> visits;
        @AuraEnabled public Integer totalVisits;
        @AuraEnabled public Boolean hasData;
    }

    @AuraEnabled(cacheable=true)
    public static RouteResponse getRouteForDay(Id dayAttendanceId) {
        RouteResponse response = new RouteResponse();
        response.visits = new List<RoutePoint>();
        response.totalVisits = 0;
        response.hasData = false;

        // When called with no id (standalone tab), resolve today's attendance for the current user
        if (dayAttendanceId == null) {
            List<Day_Attendance__c> todays = [
                SELECT Id FROM Day_Attendance__c
                WHERE Salesperson__c = :UserInfo.getUserId()
                  AND Attendance_Date__c = :Date.today()
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (todays.isEmpty()) return response;
            dayAttendanceId = todays[0].Id;
        }

        List<Day_Attendance__c> dayList = [
            SELECT Id, Attendance_Date__c,
                   Start_Location_Lat__c, Start_Location_Long__c,
                   End_Location_Lat__c, End_Location_Long__c,
                   Day_Start_Time__c, Day_End_Time__c,
                   Distance_Traveled_Km__c,
                   Total_Visits__c, Productive_Calls__c, Non_Productive_Visits__c,
                   Productivity_Percent__c, Hours_Worked__c,
                   Total_Orders__c, Total_Order_Value__c,
                   Salesperson__r.Name
            FROM Day_Attendance__c
            WHERE Id = :dayAttendanceId
            LIMIT 1
        ];

        if (dayList.isEmpty()) {
            return response;
        }

        Day_Attendance__c day = dayList[0];
        DayInfo info = new DayInfo();
        info.id = day.Id;
        info.attendanceDate = day.Attendance_Date__c;
        info.startLatitude = day.Start_Location_Lat__c;
        info.startLongitude = day.Start_Location_Long__c;
        info.endLatitude = day.End_Location_Lat__c;
        info.endLongitude = day.End_Location_Long__c;
        info.dayStartTime = day.Day_Start_Time__c;
        info.dayEndTime = day.Day_End_Time__c;
        info.distanceTraveledKm = day.Distance_Traveled_Km__c;
        info.totalVisitsField = day.Total_Visits__c;
        info.productiveCalls = day.Productive_Calls__c;
        info.nonProductiveVisits = day.Non_Productive_Visits__c;
        info.productivityPercent = day.Productivity_Percent__c;
        info.hoursWorked = day.Hours_Worked__c;
        info.totalOrders = day.Total_Orders__c;
        info.totalOrderValue = day.Total_Order_Value__c;
        info.salespersonName = day.Salesperson__r != null ? day.Salesperson__r.Name : null;
        response.attendance = info;

        List<Visit__c> visits = [
            SELECT Id, Name,
                   Check_In_Latitude__c, Check_In_Longitude__c,
                   Check_Out_Lat__c, Check_Out_Long__c,
                   Check_In_Time__c, Check_Out_Time__c,
                   Visit_Status__c,
                   Account__r.Name
            FROM Visit__c
            WHERE Day_Attendance__c = :dayAttendanceId
              AND Check_In_Latitude__c != null
              AND Check_In_Longitude__c != null
            ORDER BY Check_In_Time__c ASC NULLS LAST, CreatedDate ASC
        ];

        Integer seq = 1;
        for (Visit__c v : visits) {
            RoutePoint p = new RoutePoint();
            p.id = v.Id;
            p.label = v.Name;
            p.accountName = v.Account__r != null ? v.Account__r.Name : null;
            p.latitude = v.Check_In_Latitude__c;
            p.longitude = v.Check_In_Longitude__c;
            p.checkInTime = v.Check_In_Time__c;
            p.checkOutTime = v.Check_Out_Time__c;
            p.visitStatus = v.Visit_Status__c;
            p.sequence = seq++;
            response.visits.add(p);
        }

        response.totalVisits = response.visits.size();
        response.hasData = response.totalVisits > 0
            || (info.startLatitude != null && info.startLongitude != null)
            || (info.endLatitude != null && info.endLongitude != null);

        return response;
    }
}