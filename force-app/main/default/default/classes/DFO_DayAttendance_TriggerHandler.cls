/**
 * @description Trigger handler for Day_Attendance__c. Enforces data integrity rules:
 *              duplicate prevention, status transition validation, default field
 *              population, day summary calculation, and finalization.
 *              All business logic is delegated to DFO_DayAttendance_Service.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public class DFO_DayAttendance_TriggerHandler extends TriggerHandler {

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        if (!BPM_FeatureToggle_Util.isEnabled(DFO_DayAttendance_Service.FEATURE_ATTENDANCE)) {
            return;
        }

        List<Day_Attendance__c> newRecords = (List<Day_Attendance__c>) Trigger.new;
        validateNoDuplicateDayStart(newRecords);
        setDefaults(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled(DFO_DayAttendance_Service.FEATURE_ATTENDANCE)) {
            return;
        }

        List<Day_Attendance__c> newRecords = (List<Day_Attendance__c>) Trigger.new;
        Map<Id, Day_Attendance__c> oldMap = (Map<Id, Day_Attendance__c>) Trigger.oldMap;

        validateStatusTransitions(newRecords, oldMap);

        // Calculate summary when day is ending
        List<Day_Attendance__c> dayEnding = new List<Day_Attendance__c>();
        for (Day_Attendance__c rec : newRecords) {
            Day_Attendance__c oldRec = oldMap.get(rec.Id);
            if (rec.End_Time__c != null && oldRec.End_Time__c == null) {
                dayEnding.add(rec);
            }
        }

        if (!dayEnding.isEmpty()) {
            calculateDaySummary(dayEnding);
        }
    }

    // ── After Update ──────────────────────────────────────────────────────────

    protected override void afterUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled(DFO_DayAttendance_Service.FEATURE_ATTENDANCE)) {
            return;
        }

        List<Day_Attendance__c> newRecords = (List<Day_Attendance__c>) Trigger.new;
        Map<Id, Day_Attendance__c> oldMap = (Map<Id, Day_Attendance__c>) Trigger.oldMap;

        List<Day_Attendance__c> endedRecords = new List<Day_Attendance__c>();
        for (Day_Attendance__c rec : newRecords) {
            Day_Attendance__c oldRec = oldMap.get(rec.Id);
            Boolean justEnded = (rec.Status__c == 'Ended' || rec.Status__c == 'Auto-Closed')
                && oldRec.Status__c != 'Ended' && oldRec.Status__c != 'Auto-Closed';
            if (justEnded) {
                endedRecords.add(rec);
            }
        }

        if (!endedRecords.isEmpty()) {
            finalizeDailySummary(endedRecords);
        }
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    /**
     * @description Validates uniqueness of user + date combinations. Prevents
     *              a salesperson from having multiple day starts for the same date.
     */
    private void validateNoDuplicateDayStart(List<Day_Attendance__c> records) {
        Set<Id> userIds = new Set<Id>();
        Set<Date> attendanceDates = new Set<Date>();

        for (Day_Attendance__c rec : records) {
            if (rec.User__c != null) {
                userIds.add(rec.User__c);
            }
            if (rec.Attendance_Date__c != null) {
                attendanceDates.add(rec.Attendance_Date__c);
            }
        }

        if (userIds.isEmpty() || attendanceDates.isEmpty()) {
            return;
        }

        Set<String> existingKeys = new Set<String>();
        for (Day_Attendance__c existing : [
            SELECT User__c, Attendance_Date__c
            FROM Day_Attendance__c
            WHERE User__c IN :userIds
              AND Attendance_Date__c IN :attendanceDates
              AND Status__c NOT IN ('Cancelled', 'Auto-Closed')
        ]) {
            existingKeys.add(buildKey(existing.User__c, existing.Attendance_Date__c));
        }

        Set<String> batchKeys = new Set<String>();
        for (Day_Attendance__c rec : records) {
            if (rec.User__c == null || rec.Attendance_Date__c == null) {
                continue;
            }
            String key = buildKey(rec.User__c, rec.Attendance_Date__c);

            if (existingKeys.contains(key)) {
                rec.addError('A day attendance record already exists for this user on ' +
                    String.valueOf(rec.Attendance_Date__c) +
                    '. Only one active day is allowed per user per date.');
            } else if (batchKeys.contains(key)) {
                rec.addError('Duplicate day attendance found within the same batch for ' +
                    String.valueOf(rec.Attendance_Date__c) + '.');
            }
            batchKeys.add(key);
        }
    }

    /**
     * @description Sets default field values on new records.
     */
    private void setDefaults(List<Day_Attendance__c> records) {
        for (Day_Attendance__c rec : records) {
            // Set day of week
            if (rec.Attendance_Date__c != null && String.isBlank(rec.Week_Day__c)) {
                DateTime dt = DateTime.newInstance(rec.Attendance_Date__c, Time.newInstance(0, 0, 0, 0));
                rec.Week_Day__c = dt.format('EEEE');
            }

            // Initialize counters
            if (rec.Total_Visits__c == null)          rec.Total_Visits__c = 0;
            if (rec.Productive_Calls__c == null)      rec.Productive_Calls__c = 0;
            if (rec.Non_Productive_Visits__c == null)  rec.Non_Productive_Visits__c = 0;
            if (rec.Total_Orders__c == null)           rec.Total_Orders__c = 0;
            if (rec.Total_Order_Value__c == null)      rec.Total_Order_Value__c = 0;
            if (rec.Total_Collection__c == null)       rec.Total_Collection__c = 0;
            if (rec.Total_Distance__c == null)         rec.Total_Distance__c = 0;
            if (rec.Productivity_Percent__c == null)   rec.Productivity_Percent__c = 0;
        }
    }

    /**
     * @description Validates status transitions using Status_Transition__mdt.
     */
    private void validateStatusTransitions(
        List<Day_Attendance__c> newRecords,
        Map<Id, Day_Attendance__c> oldMap
    ) {
        for (Day_Attendance__c rec : newRecords) {
            Day_Attendance__c oldRec = oldMap.get(rec.Id);
            if (rec.Status__c != oldRec.Status__c) {
                if (!DFO_DayAttendance_Service.isValidStatusTransition(
                    'Day_Attendance__c', oldRec.Status__c, rec.Status__c)) {
                    rec.addError('Invalid status transition from "' +
                        oldRec.Status__c + '" to "' + rec.Status__c + '".');
                }
            }
        }
    }

    /**
     * @description Calculates daily summary metrics by aggregating visit data.
     */
    private void calculateDaySummary(List<Day_Attendance__c> records) {
        Set<Id> attendanceIds = new Set<Id>();
        for (Day_Attendance__c rec : records) {
            attendanceIds.add(rec.Id);
        }

        // Aggregate visit metrics
        Map<Id, Integer> totalVisitCounts = new Map<Id, Integer>();
        Map<Id, Decimal> totalOrderValues = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId,
                   COUNT(Id) totalVisits,
                   SUM(Order_Value__c) totalOrderValue
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
            GROUP BY Day_Attendance__c
        ]) {
            Id attId = (Id) ar.get('attId');
            totalVisitCounts.put(attId, (Integer) ar.get('totalVisits'));
            Decimal ov = (Decimal) ar.get('totalOrderValue');
            totalOrderValues.put(attId, ov != null ? ov : 0);
        }

        // Productive visit counts
        Map<Id, Integer> productiveVisitCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId, COUNT(Id) cnt
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
              AND Is_Productive__c = true
              AND Visit_Status__c = 'Completed'
            GROUP BY Day_Attendance__c
        ]) {
            productiveVisitCounts.put((Id) ar.get('attId'), (Integer) ar.get('cnt'));
        }

        // Non-productive visit counts
        Map<Id, Integer> nonProductiveVisitCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId, COUNT(Id) cnt
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
              AND Is_Productive__c = false
              AND Visit_Status__c = 'Completed'
            GROUP BY Day_Attendance__c
        ]) {
            nonProductiveVisitCounts.put((Id) ar.get('attId'), (Integer) ar.get('cnt'));
        }

        // Collection totals
        Map<Id, Decimal> collectionTotals = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Visit__r.Day_Attendance__c attId, SUM(Amount__c) totalCollected
            FROM Collection__c
            WHERE Visit__r.Day_Attendance__c IN :attendanceIds
              AND Status__c NOT IN ('Cancelled', 'Bounced')
            GROUP BY Visit__r.Day_Attendance__c
        ]) {
            Id attId = (Id) ar.get('attId');
            Decimal total = (Decimal) ar.get('totalCollected');
            collectionTotals.put(attId, total != null ? total : 0);
        }

        // Apply to records (before update context)
        for (Day_Attendance__c rec : records) {
            Integer visits = totalVisitCounts.containsKey(rec.Id) ? totalVisitCounts.get(rec.Id) : 0;
            Integer productive = productiveVisitCounts.containsKey(rec.Id) ? productiveVisitCounts.get(rec.Id) : 0;
            Integer nonProductive = nonProductiveVisitCounts.containsKey(rec.Id) ? nonProductiveVisitCounts.get(rec.Id) : 0;

            rec.Total_Visits__c = visits;
            rec.Productive_Calls__c = productive;
            rec.Non_Productive_Visits__c = nonProductive;
            rec.Total_Order_Value__c = totalOrderValues.containsKey(rec.Id) ? totalOrderValues.get(rec.Id) : 0;
            rec.Total_Orders_Value__c = rec.Total_Order_Value__c;
            rec.Total_Collection__c = collectionTotals.containsKey(rec.Id) ? collectionTotals.get(rec.Id) : 0;
            rec.Total_Collections__c = rec.Total_Collection__c;

            // Calculate productivity %
            if (visits > 0) {
                rec.Productivity_Percent__c = (Decimal.valueOf(productive) / Decimal.valueOf(visits) * 100)
                    .setScale(2, RoundingMode.HALF_UP);
            } else {
                rec.Productivity_Percent__c = 0;
            }

            // Calculate hours worked
            if (rec.Start_Time__c != null && rec.End_Time__c != null) {
                Long millisWorked = rec.End_Time__c.getTime() - rec.Start_Time__c.getTime();
                rec.Hours_Worked__c = (Decimal.valueOf(millisWorked) / 3600000.0)
                    .setScale(2, RoundingMode.HALF_UP);
            }
        }
    }

    /**
     * @description Finalises ended records: calculates total distance and marks as finalized.
     */
    private void finalizeDailySummary(List<Day_Attendance__c> endedRecords) {
        Set<Id> attendanceIds = new Set<Id>();
        for (Day_Attendance__c rec : endedRecords) {
            attendanceIds.add(rec.Id);
        }

        Map<Id, Decimal> distanceByAttendance = calculateDistanceTravelled(attendanceIds);

        List<Day_Attendance__c> toUpdate = new List<Day_Attendance__c>();
        for (Day_Attendance__c rec : endedRecords) {
            Day_Attendance__c updateRec = new Day_Attendance__c(
                Id = rec.Id,
                Is_Finalized__c = true
            );
            Decimal distKm = distanceByAttendance.containsKey(rec.Id) ? distanceByAttendance.get(rec.Id) : 0;
            updateRec.Distance_Traveled_Km__c = distKm;
            updateRec.Total_Distance__c = distKm;
            toUpdate.add(updateRec);
        }

        if (!toUpdate.isEmpty()) {
            TriggerHandler.bypass('DFO_DayAttendance_TriggerHandler');
            try {
                update toUpdate;
            } finally {
                TriggerHandler.clearBypass('DFO_DayAttendance_TriggerHandler');
            }
        }
    }

    /**
     * @description Calculates total distance from GPS breadcrumbs in kilometres.
     */
    private Map<Id, Decimal> calculateDistanceTravelled(Set<Id> attendanceIds) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();

        Map<Id, List<GPS_Log__c>> logsByAttendance = new Map<Id, List<GPS_Log__c>>();
        for (GPS_Log__c gps : [
            SELECT Day_Attendance__c, Latitude__c, Longitude__c
            FROM GPS_Log__c
            WHERE Day_Attendance__c IN :attendanceIds
              AND Latitude__c != null AND Longitude__c != null
            ORDER BY Captured_At__c ASC
        ]) {
            if (!logsByAttendance.containsKey(gps.Day_Attendance__c)) {
                logsByAttendance.put(gps.Day_Attendance__c, new List<GPS_Log__c>());
            }
            logsByAttendance.get(gps.Day_Attendance__c).add(gps);
        }

        for (Id attId : attendanceIds) {
            Decimal totalMeters = 0;
            List<GPS_Log__c> logs = logsByAttendance.get(attId);
            if (logs != null && logs.size() > 1) {
                for (Integer i = 1; i < logs.size(); i++) {
                    GPS_Log__c prev = logs[i - 1];
                    GPS_Log__c curr = logs[i];
                    totalMeters += (Decimal) OVE_GeoValidation_Service.calculateDistance(
                        (Double) prev.Latitude__c, (Double) prev.Longitude__c,
                        (Double) curr.Latitude__c, (Double) curr.Longitude__c
                    );
                }
            }
            result.put(attId, (totalMeters / 1000).setScale(2, RoundingMode.HALF_UP));
        }

        return result;
    }

    private String buildKey(Id userId, Date attendanceDate) {
        return String.valueOf(userId) + '|' + String.valueOf(attendanceDate);
    }
}