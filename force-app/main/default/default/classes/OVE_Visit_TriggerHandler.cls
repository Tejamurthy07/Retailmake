/**
 * @description Trigger handler for Visit__c. Manages geo-fence validation at
 *              check-in, Day_Attendance__c total updates, status transition
 *              enforcement, and productive call tracking upon visit completion.
 *              All business logic delegates to OVE_Visit_Service and
 *              DFO_DayAttendance_Service.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public class OVE_Visit_TriggerHandler extends TriggerHandler {

    private static final Double DEFAULT_GEOFENCE_RADIUS = 500.0;

    // ── Before Insert ─────────────────────────────────────────────────────────

    protected override void beforeInsert() {
        if (!BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_VISIT_EXECUTION)) {
            return;
        }

        List<Visit__c> newRecords = (List<Visit__c>) Trigger.new;
        setDefaults(newRecords);
        validateGeoFence(newRecords);
    }

    // ── Before Update ─────────────────────────────────────────────────────────

    protected override void beforeUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_VISIT_EXECUTION)) {
            return;
        }

        List<Visit__c> newRecords = (List<Visit__c>) Trigger.new;
        Map<Id, Visit__c> oldMap = (Map<Id, Visit__c>) Trigger.oldMap;

        // Status transition validation disabled per business request — any Visit_Status__c
        // transition (e.g. Planned -> Completed) is now allowed.
        // validateStatusTransitions(newRecords, oldMap);

        // Geo-fence check on check-in: users typically update an existing
        // Planned visit by setting Check_In_Latitude/Longitude, so this MUST
        // run on update too. Filter to only the records where check-in
        // coordinates are being set or changed to avoid re-validating on
        // every field tweak.
        List<Visit__c> toValidate = new List<Visit__c>();
        for (Visit__c rec : newRecords) {
            Visit__c oldRec = oldMap.get(rec.Id);
            Boolean latChanged = rec.Check_In_Latitude__c != null
                && rec.Check_In_Latitude__c != oldRec.Check_In_Latitude__c;
            Boolean lngChanged = rec.Check_In_Longitude__c != null
                && rec.Check_In_Longitude__c != oldRec.Check_In_Longitude__c;
            if (latChanged || lngChanged) {
                toValidate.add(rec);
            }
        }
        if (!toValidate.isEmpty()) {
            validateGeoFence(toValidate);
        }

        calculateDurationOnCompletion(newRecords, oldMap);
    }

    // ── After Insert ──────────────────────────────────────────────────────────

    protected override void afterInsert() {
        if (!BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_VISIT_EXECUTION)) {
            return;
        }

        List<Visit__c> newRecords = (List<Visit__c>) Trigger.new;
        updateDayAttendanceTotals(newRecords);
    }

    // ── After Update ──────────────────────────────────────────────────────────

    protected override void afterUpdate() {
        if (!BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_VISIT_EXECUTION)) {
            return;
        }

        List<Visit__c> newRecords = (List<Visit__c>) Trigger.new;
        Map<Id, Visit__c> oldMap = (Map<Id, Visit__c>) Trigger.oldMap;

        List<Visit__c> completedVisits = new List<Visit__c>();
        List<Visit__c> skippedVisits = new List<Visit__c>();

        for (Visit__c rec : newRecords) {
            Visit__c oldRec = oldMap.get(rec.Id);
            if (rec.Visit_Status__c == 'Completed' && oldRec.Visit_Status__c != 'Completed') {
                completedVisits.add(rec);
            }
            if (rec.Visit_Status__c == 'Skipped' && oldRec.Visit_Status__c != 'Skipped') {
                skippedVisits.add(rec);
            }
        }

        if (!completedVisits.isEmpty()) {
            updateProductiveCallCounts(completedVisits);
            calculateMustSellCompliance(completedVisits);

            // Update Last_Visit_Date__c on Account
            Set<Id> visitAccountIds = new Set<Id>();
            for (Visit__c v : completedVisits) {
                Id acctId = v.Account__c != null ? v.Account__c : v.Outlet__c;
                if (acctId != null) visitAccountIds.add(acctId);
            }
            if (!visitAccountIds.isEmpty()) {
                MDM_Account_TriggerHandler.updateLastVisitDate(visitAccountIds);
            }
        }
        if (!skippedVisits.isEmpty()) {
            updateDayAttendanceTotals(skippedVisits);
        }
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private void setDefaults(List<Visit__c> records) {
        for (Visit__c visit : records) {
            if (visit.Order_Value__c == null) visit.Order_Value__c = 0;
            if (visit.Collection_Amount__c == null) visit.Collection_Amount__c = 0;
            if (visit.Total_Orders_Count__c == null) visit.Total_Orders_Count__c = 0;
            if (visit.Visit_Date__c == null) visit.Visit_Date__c = Date.today();
        }
    }

    private void validateGeoFence(List<Visit__c> records) {
        if (!BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_GEOFENCE)) {
            return;
        }

        Set<Id> outletIds = new Set<Id>();
        for (Visit__c visit : records) {
            Id oid = visit.Outlet__c != null ? visit.Outlet__c : visit.Account__c;
            if (oid != null) outletIds.add(oid);
        }
        if (outletIds.isEmpty()) return;

        Map<Id, Account> outletMap = new Map<Id, Account>([
            SELECT Id, Outlet_Latitude__c, Outlet_Longitude__c, Geofence_Radius__c
            FROM Account WHERE Id IN :outletIds
        ]);

        Double defaultRadius = getConfiguredRadius();
        Boolean allowOverride = DFO_DayAttendance_Service.getConfigBoolean('ALLOW_GEOFENCE_OVERRIDE', true);

        for (Visit__c visit : records) {
            if (visit.Check_In_Latitude__c == null || visit.Check_In_Longitude__c == null) continue;

            Id outletId = visit.Outlet__c != null ? visit.Outlet__c : visit.Account__c;
            Account outlet = outletMap.get(outletId);
            if (outlet == null || outlet.Outlet_Latitude__c == null || outlet.Outlet_Longitude__c == null) continue;

            Double radiusMeters = outlet.Geofence_Radius__c != null ? outlet.Geofence_Radius__c : defaultRadius;

            Double distance = OVE_GeoValidation_Service.calculateDistance(
                (Double) visit.Check_In_Latitude__c, (Double) visit.Check_In_Longitude__c,
                (Double) outlet.Outlet_Latitude__c, (Double) outlet.Outlet_Longitude__c
            );

            visit.Distance_To_Outlet__c = distance;
            visit.Is_Geo_Fenced__c = (distance <= radiusMeters);

            if (!visit.Is_Geo_Fenced__c) {
                if (allowOverride && String.isNotBlank(visit.Geo_Fence_Override_Reason__c)) {
                    continue;
                }
                visit.addError(
                    'Check-in location is ' + String.valueOf(Math.round(distance)) +
                    'm from the outlet, which exceeds the allowed radius of ' +
                    String.valueOf(Math.round(radiusMeters)) + 'm.' +
                    (allowOverride ? ' You may override with a reason.' : '')
                );
            }
        }
    }

    private void validateStatusTransitions(List<Visit__c> newRecords, Map<Id, Visit__c> oldMap) {
        for (Visit__c rec : newRecords) {
            Visit__c oldRec = oldMap.get(rec.Id);
            if (rec.Visit_Status__c != oldRec.Visit_Status__c) {
                if (!DFO_DayAttendance_Service.isValidStatusTransition(
                    'Visit__c', oldRec.Visit_Status__c, rec.Visit_Status__c)) {
                    rec.addError('Invalid status transition from "' +
                        oldRec.Visit_Status__c + '" to "' + rec.Visit_Status__c + '".');
                }
            }
        }
    }

    private void calculateDurationOnCompletion(List<Visit__c> newRecords, Map<Id, Visit__c> oldMap) {
        for (Visit__c rec : newRecords) {
            Visit__c oldRec = oldMap.get(rec.Id);
            if (rec.Visit_Status__c == 'Completed' && oldRec.Visit_Status__c != 'Completed') {
                if (rec.Check_In_Time__c != null && rec.Check_Out_Time__c != null) {
                    Long durationMs = rec.Check_Out_Time__c.getTime() - rec.Check_In_Time__c.getTime();
                    rec.Duration_Minutes__c = (Decimal.valueOf(durationMs) / 60000.0)
                        .setScale(1, RoundingMode.HALF_UP);
                }
            }
        }
    }

    private void updateDayAttendanceTotals(List<Visit__c> visits) {
        Set<Id> attendanceIds = new Set<Id>();
        for (Visit__c visit : visits) {
            if (visit.Day_Attendance__c != null) attendanceIds.add(visit.Day_Attendance__c);
        }
        if (attendanceIds.isEmpty()) return;

        Map<Id, Integer> visitCountByAttendance = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Day_Attendance__c attendanceId, COUNT(Id) visitCount
            FROM Visit__c WHERE Day_Attendance__c IN :attendanceIds
            GROUP BY Day_Attendance__c
        ]) {
            visitCountByAttendance.put((Id) ar.get('attendanceId'), (Integer) ar.get('visitCount'));
        }

        List<Day_Attendance__c> updates = new List<Day_Attendance__c>();
        for (Id attId : attendanceIds) {
            updates.add(new Day_Attendance__c(
                Id = attId,
                Total_Visits__c = visitCountByAttendance.containsKey(attId) ? visitCountByAttendance.get(attId) : 0
            ));
        }

        if (!updates.isEmpty()) {
            TriggerHandler.bypass('DFO_DayAttendance_TriggerHandler');
            try {
                update updates;
            } finally {
                TriggerHandler.clearBypass('DFO_DayAttendance_TriggerHandler');
            }
        }
    }

    private void updateProductiveCallCounts(List<Visit__c> completedVisits) {
        Set<Id> attendanceIds = new Set<Id>();
        for (Visit__c visit : completedVisits) {
            if (visit.Day_Attendance__c != null) attendanceIds.add(visit.Day_Attendance__c);
        }
        if (attendanceIds.isEmpty()) return;

        Map<Id, Integer> productiveMap = new Map<Id, Integer>();
        Map<Id, Integer> nonProductiveMap = new Map<Id, Integer>();
        Map<Id, Decimal> orderValueMap = new Map<Id, Decimal>();
        Map<Id, Decimal> collectionMap = new Map<Id, Decimal>();

        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId, COUNT(Id) cnt,
                   SUM(Order_Value__c) ov, SUM(Collection_Amount__c) cv
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
              AND Visit_Status__c = 'Completed' AND Is_Productive__c = true
            GROUP BY Day_Attendance__c
        ]) {
            Id attId = (Id) ar.get('attId');
            productiveMap.put(attId, (Integer) ar.get('cnt'));
            Decimal ov = (Decimal) ar.get('ov');
            orderValueMap.put(attId, ov != null ? ov : 0);
            Decimal cv = (Decimal) ar.get('cv');
            collectionMap.put(attId, cv != null ? cv : 0);
        }

        for (AggregateResult ar : [
            SELECT Day_Attendance__c attId, COUNT(Id) cnt
            FROM Visit__c
            WHERE Day_Attendance__c IN :attendanceIds
              AND Visit_Status__c = 'Completed' AND Is_Productive__c = false
            GROUP BY Day_Attendance__c
        ]) {
            nonProductiveMap.put((Id) ar.get('attId'), (Integer) ar.get('cnt'));
        }

        List<Day_Attendance__c> updates = new List<Day_Attendance__c>();
        for (Id attId : attendanceIds) {
            Integer prod = productiveMap.containsKey(attId) ? productiveMap.get(attId) : 0;
            Integer nonProd = nonProductiveMap.containsKey(attId) ? nonProductiveMap.get(attId) : 0;
            Integer total = prod + nonProd;
            Decimal pct = total > 0
                ? (Decimal.valueOf(prod) / Decimal.valueOf(total) * 100).setScale(2, RoundingMode.HALF_UP) : 0;

            updates.add(new Day_Attendance__c(
                Id = attId,
                Productive_Calls__c = prod,
                Non_Productive_Visits__c = nonProd,
                Total_Order_Value__c = orderValueMap.containsKey(attId) ? orderValueMap.get(attId) : 0,
                Total_Orders_Value__c = orderValueMap.containsKey(attId) ? orderValueMap.get(attId) : 0,
                Total_Collection__c = collectionMap.containsKey(attId) ? collectionMap.get(attId) : 0,
                Total_Collections__c = collectionMap.containsKey(attId) ? collectionMap.get(attId) : 0,
                Productivity_Percent__c = pct
            ));
        }

        if (!updates.isEmpty()) {
            TriggerHandler.bypass('DFO_DayAttendance_TriggerHandler');
            try {
                update updates;
            } finally {
                TriggerHandler.clearBypass('DFO_DayAttendance_TriggerHandler');
            }
        }
    }

    /**
     * @description Calculates must-sell compliance for completed visits by checking
     *              which must-sell products were ordered during the visit. Updates
     *              Must_Sell_Products_Required__c, Must_Sell_Products_Ordered__c,
     *              and Must_Sell_Compliance__c on the Visit records.
     */
    private void calculateMustSellCompliance(List<Visit__c> completedVisits) {
        Set<Id> visitIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        Set<Id> territoryIds = new Set<Id>();

        for (Visit__c visit : completedVisits) {
            visitIds.add(visit.Id);
            Id outletId = visit.Outlet__c != null ? visit.Outlet__c : visit.Account__c;
            if (outletId != null) accountIds.add(outletId);
        }

        if (accountIds.isEmpty()) return;

        // Get account details for customer type (outlet type) and territory
        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Outlet_Type__c, Territory__c
            FROM Account WHERE Id IN :accountIds
        ]);

        for (Account acct : accountMap.values()) {
            if (acct.Territory__c != null) territoryIds.add(acct.Territory__c);
        }

        // Get active must-sell configs
        Date today = Date.today();
        List<Must_Sell_Config__c> configs = [
            SELECT Id, Product_Ext__c, Territory__c, Channel__c, Customer_Type__c
            FROM Must_Sell_Config__c
            WHERE Is_Active__c = true
              AND (Start_Date__c = null OR Start_Date__c <= :today)
              AND (End_Date__c = null OR End_Date__c >= :today)
        ];

        if (configs.isEmpty()) return;

        // Get orders created during these visits (linked via Account + Visit Date)
        Map<Id, Set<Id>> orderedProductsByVisit = new Map<Id, Set<Id>>();
        for (Order_Line_Item__c li : [
            SELECT Sales_Order__c, Sales_Order__r.Account__c, Product_Ext__c,
                   Sales_Order__r.Visit__c
            FROM Order_Line_Item__c
            WHERE Sales_Order__r.Visit__c IN :visitIds
              AND Product_Ext__c != null
        ]) {
            Id vId = li.Sales_Order__r.Visit__c;
            if (!orderedProductsByVisit.containsKey(vId)) {
                orderedProductsByVisit.put(vId, new Set<Id>());
            }
            orderedProductsByVisit.get(vId).add(li.Product_Ext__c);
        }

        // Calculate compliance per visit
        List<Visit__c> visitsToUpdate = new List<Visit__c>();
        for (Visit__c visit : completedVisits) {
            Id outletId = visit.Outlet__c != null ? visit.Outlet__c : visit.Account__c;
            Account acct = accountMap.get(outletId);
            if (acct == null) continue;

            String customerType = (acct.Outlet_Type__c != null) ? acct.Outlet_Type__c : '';
            Id territoryId = acct.Territory__c;

            // Find applicable must-sell products for this outlet
            Set<Id> requiredProducts = new Set<Id>();
            for (Must_Sell_Config__c config : configs) {
                if (config.Territory__c != null && config.Territory__c != territoryId) continue;
                if (String.isNotBlank(config.Customer_Type__c) && config.Customer_Type__c != customerType) continue;
                requiredProducts.add(config.Product_Ext__c);
            }

            if (requiredProducts.isEmpty()) continue;

            Set<Id> ordered = orderedProductsByVisit.containsKey(visit.Id)
                ? orderedProductsByVisit.get(visit.Id) : new Set<Id>();

            Integer required = requiredProducts.size();
            Integer fulfilled = 0;
            for (Id prodId : requiredProducts) {
                if (ordered.contains(prodId)) fulfilled++;
            }

            Decimal compliance = required > 0
                ? (Decimal.valueOf(fulfilled) / Decimal.valueOf(required) * 100).setScale(1, RoundingMode.HALF_UP)
                : 100;

            visitsToUpdate.add(new Visit__c(
                Id = visit.Id,
                Must_Sell_Products_Required__c = required,
                Must_Sell_Products_Ordered__c = fulfilled,
                Must_Sell_Compliance__c = compliance
            ));
        }

        if (!visitsToUpdate.isEmpty()) {
            TriggerHandler.bypass('OVE_Visit_TriggerHandler');
            try {
                update visitsToUpdate;
            } finally {
                TriggerHandler.clearBypass('OVE_Visit_TriggerHandler');
            }
        }
    }

    private Double getConfiguredRadius() {
        try {
            List<Geo_Config__mdt> configs = [
                SELECT Value__c FROM Geo_Config__mdt
                WHERE DeveloperName = 'Default_Geofence_Radius' LIMIT 1
            ];
            if (!configs.isEmpty() && configs[0].Value__c != null) {
                return Double.valueOf(configs[0].Value__c);
            }
        } catch (Exception e) {
            // Fall back to default
        }
        return DEFAULT_GEOFENCE_RADIUS;
    }

}