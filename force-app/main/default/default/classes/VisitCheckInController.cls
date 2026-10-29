/**
 * @description Controller for the Visit Check-In / Check-Out LWC components.
 *              Thin @AuraEnabled wrapper that delegates all business logic
 *              to OVE_Visit_Service.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class VisitCheckInController {

    /**
     * @description Creates a new visit (check-in).
     * @param visitJson JSON string with CheckInRequest fields.
     * @return The created Visit__c record.
     */
    @AuraEnabled
    public static Visit__c createVisit(String visitJson) {
        try {
            OVE_Visit_Service.CheckInRequest request =
                (OVE_Visit_Service.CheckInRequest)
                JSON.deserialize(visitJson, OVE_Visit_Service.CheckInRequest.class);
            return OVE_Visit_Service.checkIn(request);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Completes a visit (check-out).
     * @param visitJson JSON string with CheckOutRequest fields.
     * @return The updated Visit__c record.
     */
    @AuraEnabled
    public static Visit__c completeVisit(String visitJson) {
        try {
            OVE_Visit_Service.CheckOutRequest request =
                (OVE_Visit_Service.CheckOutRequest)
                JSON.deserialize(visitJson, OVE_Visit_Service.CheckOutRequest.class);
            return OVE_Visit_Service.checkOut(request);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Skips a planned visit.
     * @param visitId The Visit__c Id to skip.
     * @param skipReason The reason for skipping.
     * @return The updated Visit__c record.
     */
    @AuraEnabled
    public static Visit__c skipVisit(Id visitId, String skipReason) {
        try {
            return OVE_Visit_Service.skipVisit(visitId, skipReason);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets outlet 360 summary.
     * @param accountId The Account Id.
     * @return Map of outlet summary data.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getOutletSummary(Id accountId) {
        try {
            return OVE_Visit_Service.getOutletSummary(accountId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets today's visits for the current user.
     * @param userId Optional User Id.
     * @return List of Visit__c records.
     */
    @AuraEnabled(cacheable=true)
    public static List<Visit__c> getTodaysVisits(Id userId) {
        try {
            return OVE_Visit_Service.getTodaysVisits(userId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets planned visits from today's journey plan.
     * @param userId The User Id.
     * @param visitDate The date.
     * @return List of planned visit maps.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getPlannedVisits(Id userId, Date visitDate) {
        try {
            return OVE_Visit_Service.getPlannedVisits(userId, visitDate);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Validates geo-fence for an outlet.
     * @param latitude Check-in latitude.
     * @param longitude Check-in longitude.
     * @param accountId The Account Id.
     * @return GeoValidationResult DTO.
     */
    @AuraEnabled
    public static OVE_Visit_Service.GeoValidationResult validateGeoFence(
        Decimal latitude, Decimal longitude, Id accountId
    ) {
        try {
            return OVE_Visit_Service.validateGeoFence(latitude, longitude, accountId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets configurable visit activities list.
     * @return List of activity definitions.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getVisitActivities() {
        try {
            return OVE_Visit_Service.getVisitActivities(null);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets visit completion summary with orders and collections.
     * @param visitId The Visit__c Id.
     * @return Map of completion data.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getVisitCompletionSummary(Id visitId) {
        try {
            return OVE_Visit_Service.getVisitCompletionSummary(visitId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets team visits for the current manager.
     * @param visitDate The date to query.
     * @return List of team visit summary maps.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getTeamVisits(Date visitDate) {
        try {
            return OVE_Visit_Service.getTeamVisits(UserInfo.getUserId(), visitDate);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Gets visit configuration for the LWC.
     * @return Map of config key-value pairs relevant to OVE module.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getVisitConfig() {
        try {
            Map<String, Object> config = new Map<String, Object>();
            config.put('requirePhotoCheckIn', DFO_DayAttendance_Service.getConfigBoolean('REQUIRE_PHOTO_CHECKIN', false));
            config.put('allowGeofenceOverride', DFO_DayAttendance_Service.getConfigBoolean('ALLOW_GEOFENCE_OVERRIDE', true));
            config.put('minVisitDurationSec', DFO_DayAttendance_Service.getConfigInteger('MIN_VISIT_DURATION_SEC', 60));
            config.put('maxVisitsPerDay', DFO_DayAttendance_Service.getConfigInteger('MAX_VISITS_PER_DAY', 30));
            config.put('geofenceEnabled', BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_GEOFENCE));
            config.put('adHocVisitsEnabled', BPM_FeatureToggle_Util.isEnabled(OVE_Visit_Service.FEATURE_AD_HOC_VISITS));
            return config;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Searches outlet accounts for ad-hoc visit creation.
     * @param searchTerm The search string to match against account names.
     * @return List of matching Account records.
     */
    @AuraEnabled
    public static List<Account> searchOutlets(String searchTerm) {
        try {
            if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
                return new List<Account>();
            }
            String searchPattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';

            // MDM-003: filter by current user's authorized channels (if any)
            Set<String> userChannels = MDM_ChannelMapping_Service.getCurrentUserChannels();
            List<String> channelList = new List<String>(userChannels);
            Boolean filterByChannel = BPM_FeatureToggle_Util.isEnabled('MDM-003') && !channelList.isEmpty();

            if (filterByChannel) {
                return [
                    SELECT Id, Name, BillingStreet, BillingCity, AccountNumber,
                           Outlet_Type__c, Outlet_Class__c, Channel__c
                    FROM Account
                    WHERE (Name LIKE :searchPattern
                           OR AccountNumber LIKE :searchPattern)
                      AND Is_Active__c = true
                      AND Type IN ('Retailer', 'Distributor', 'Super Stockist', 'Modern Trade')
                      AND Channel__c IN :channelList
                    ORDER BY Name ASC
                    LIMIT 20
                ];
            }

            // No channel restriction (feature off or employee has no channel assigned)
            return [
                SELECT Id, Name, BillingStreet, BillingCity, AccountNumber,
                       Outlet_Type__c, Outlet_Class__c, Channel__c
                FROM Account
                WHERE (Name LIKE :searchPattern
                       OR AccountNumber LIKE :searchPattern)
                  AND Is_Active__c = true
                  AND Type IN ('Retailer', 'Distributor', 'Super Stockist', 'Modern Trade')
                ORDER BY Name ASC
                LIMIT 20
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}