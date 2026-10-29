/**
 * @description Controller for capturing and managing geolocation on Account
 *              (outlet) records. Used by:
 *                - accountGeolocationButton: single-record capture from the
 *                  customer's physical location (via browser geolocation)
 *                - bulkGeolocateAccounts: bulk-copy from BillingLatitude/
 *                  BillingLongitude fields where present
 *
 *              Geo-fencing during visit check-in compares the Salesperson's
 *              current location against Outlet_Latitude__c / Outlet_Longitude__c
 *              within Geofence_Radius__c metres.
 *
 * @author  SFA Development Team
 * @date    2026
 */
public with sharing class AccountGeolocation_Controller {

    private static final Decimal DEFAULT_RADIUS_METERS = 100;

    /**
     * @description Saves a captured GPS location to a single account.
     */
    @AuraEnabled
    public static Account saveAccountLocation(
        Id accountId,
        Decimal latitude,
        Decimal longitude,
        Decimal accuracy,
        Decimal radiusMeters
    ) {
        if (accountId == null) {
            throw new AuraHandledException('Account Id is required.');
        }
        if (latitude == null || longitude == null) {
            throw new AuraHandledException('Latitude and longitude are required.');
        }
        if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
            throw new AuraHandledException('Latitude or longitude out of range.');
        }
        try {
            Account acc = new Account(
                Id = accountId,
                Outlet_Latitude__c = latitude,
                Outlet_Longitude__c = longitude
            );
            if (radiusMeters != null && radiusMeters > 0) {
                acc.Geofence_Radius__c = radiusMeters;
            } else {
                acc.Geofence_Radius__c = DEFAULT_RADIUS_METERS;
            }
            update acc;
            return [
                SELECT Id, Name, Outlet_Latitude__c, Outlet_Longitude__c,
                       Geofence_Radius__c, BillingStreet, BillingCity, BillingState
                FROM Account
                WHERE Id = :accountId
                LIMIT 1
            ];
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save location: ' + e.getMessage());
        }
    }

    /**
     * @description Returns the current geolocation status of an account.
     */
    @AuraEnabled(cacheable=true)
    public static Account getAccountLocation(Id accountId) {
        if (accountId == null) return null;
        List<Account> accts = [
            SELECT Id, Name, Outlet_Latitude__c, Outlet_Longitude__c,
                   Geofence_Radius__c, BillingStreet, BillingCity,
                   BillingState, BillingPostalCode, BillingCountry,
                   BillingLatitude, BillingLongitude
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        return accts.isEmpty() ? null : accts[0];
    }

    /**
     * @description Returns counts of accounts with/without geolocation, scoped
     *              by territory if provided.
     */
    @AuraEnabled
    public static Map<String, Integer> getGeolocationStats(Id territoryId) {
        Integer total;
        Integer withLocation;
        Integer withBilling;

        if (territoryId == null) {
            total = [SELECT COUNT() FROM Account WHERE Is_Active__c = true];
            withLocation = [
                SELECT COUNT() FROM Account
                WHERE Is_Active__c = true
                  AND Outlet_Latitude__c != null
                  AND Outlet_Longitude__c != null
            ];
            withBilling = [
                SELECT COUNT() FROM Account
                WHERE Is_Active__c = true
                  AND BillingLatitude != null
                  AND BillingLongitude != null
                  AND (Outlet_Latitude__c = null OR Outlet_Longitude__c = null)
            ];
        } else {
            total = [SELECT COUNT() FROM Account WHERE Is_Active__c = true AND Territory__c = :territoryId];
            withLocation = [
                SELECT COUNT() FROM Account
                WHERE Is_Active__c = true
                  AND Territory__c = :territoryId
                  AND Outlet_Latitude__c != null
                  AND Outlet_Longitude__c != null
            ];
            withBilling = [
                SELECT COUNT() FROM Account
                WHERE Is_Active__c = true
                  AND Territory__c = :territoryId
                  AND BillingLatitude != null
                  AND BillingLongitude != null
                  AND (Outlet_Latitude__c = null OR Outlet_Longitude__c = null)
            ];
        }

        Map<String, Integer> stats = new Map<String, Integer>();
        stats.put('total', total);
        stats.put('withLocation', withLocation);
        stats.put('withBilling', withBilling);
        stats.put('missing', total - withLocation);
        return stats;
    }

    /**
     * @description Bulk-copies BillingLatitude/BillingLongitude into
     *              Outlet_Latitude__c/Outlet_Longitude__c for all accounts
     *              in scope that have billing geocodes but no outlet geocodes.
     *              Useful when Salesforce Address Geocoder has populated the
     *              standard billing geocodes via standard data.com or batch.
     *
     * @param territoryId Optional territory filter.
     * @return Number of accounts updated.
     */
    @AuraEnabled
    public static Integer bulkCopyFromBillingAddress(Id territoryId, Decimal radiusMeters) {
        Decimal radius = (radiusMeters != null && radiusMeters > 0) ? radiusMeters : DEFAULT_RADIUS_METERS;

        List<Account> toUpdate;
        if (territoryId == null) {
            toUpdate = [
                SELECT Id, BillingLatitude, BillingLongitude, Geofence_Radius__c
                FROM Account
                WHERE Is_Active__c = true
                  AND BillingLatitude != null
                  AND BillingLongitude != null
                  AND (Outlet_Latitude__c = null OR Outlet_Longitude__c = null)
                LIMIT 200
            ];
        } else {
            toUpdate = [
                SELECT Id, BillingLatitude, BillingLongitude, Geofence_Radius__c
                FROM Account
                WHERE Is_Active__c = true
                  AND Territory__c = :territoryId
                  AND BillingLatitude != null
                  AND BillingLongitude != null
                  AND (Outlet_Latitude__c = null OR Outlet_Longitude__c = null)
                LIMIT 200
            ];
        }

        if (toUpdate.isEmpty()) return 0;

        for (Account a : toUpdate) {
            a.Outlet_Latitude__c = a.BillingLatitude;
            a.Outlet_Longitude__c = a.BillingLongitude;
            if (a.Geofence_Radius__c == null || a.Geofence_Radius__c == 0) {
                a.Geofence_Radius__c = radius;
            }
        }

        try {
            update toUpdate;
            return toUpdate.size();
        } catch (Exception e) {
            throw new AuraHandledException('Bulk copy failed: ' + e.getMessage());
        }
    }

    /**
     * @description Clears geolocation on a single account.
     */
    @AuraEnabled
    public static void clearAccountLocation(Id accountId) {
        if (accountId == null) return;
        try {
            Account acc = new Account(
                Id = accountId,
                Outlet_Latitude__c = null,
                Outlet_Longitude__c = null
            );
            update acc;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to clear location: ' + e.getMessage());
        }
    }

    /**
     * @description Validates whether the salesperson's current location is
     *              inside the outlet's geo-fence radius. Returns a result
     *              structure that the LWC uses to display a warning (not a
     *              hard block) when the user is outside the fence.
     *
     * @param accountId     The outlet being visited.
     * @param currentLat    Salesperson's current GPS latitude.
     * @param currentLng    Salesperson's current GPS longitude.
     * @return Map with: hasFence, withinFence, distanceMeters,
     *         radiusMeters, outletLat, outletLng, message.
     */
    @AuraEnabled
    public static Map<String, Object> checkGeofence(
        Id accountId,
        Decimal currentLat,
        Decimal currentLng
    ) {
        Map<String, Object> result = new Map<String, Object>();
        result.put('hasFence', false);
        result.put('withinFence', true);
        result.put('distanceMeters', null);
        result.put('radiusMeters', null);
        result.put('outletLat', null);
        result.put('outletLng', null);
        result.put('message', '');

        if (accountId == null || currentLat == null || currentLng == null) {
            result.put('message', 'Missing account or location.');
            return result;
        }

        List<Account> accts = [
            SELECT Id, Name, Outlet_Latitude__c, Outlet_Longitude__c, Geofence_Radius__c
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        if (accts.isEmpty()) {
            result.put('message', 'Outlet not found.');
            return result;
        }
        Account acc = accts[0];
        if (acc.Outlet_Latitude__c == null || acc.Outlet_Longitude__c == null) {
            // No geofence configured — always within "fence"
            result.put('message', 'No geo-fence configured for this outlet.');
            return result;
        }

        result.put('hasFence', true);
        result.put('outletLat', acc.Outlet_Latitude__c);
        result.put('outletLng', acc.Outlet_Longitude__c);

        Decimal radius = (acc.Geofence_Radius__c != null && acc.Geofence_Radius__c > 0)
            ? acc.Geofence_Radius__c : 100;
        result.put('radiusMeters', radius);

        Decimal distance = haversineMeters(
            acc.Outlet_Latitude__c, acc.Outlet_Longitude__c,
            currentLat, currentLng
        );
        result.put('distanceMeters', distance.setScale(0));

        Boolean within = distance <= radius;
        result.put('withinFence', within);

        if (within) {
            result.put('message', 'You are ' + distance.setScale(0) + ' m from the outlet (within ' +
                       radius.setScale(0) + ' m geofence).');
        } else {
            Decimal over = distance - radius;
            result.put('message', 'You are ' + distance.setScale(0) + ' m from ' + acc.Name +
                       ' — ' + over.setScale(0) + ' m outside the ' + radius.setScale(0) +
                       ' m geofence.');
        }
        return result;
    }

    /**
     * @description Haversine formula to compute distance between two
     *              lat/lng points in metres.
     */
    private static Decimal haversineMeters(
        Decimal lat1, Decimal lng1,
        Decimal lat2, Decimal lng2
    ) {
        Double EARTH_RADIUS_M = 6371000;
        Double dLat = toRadians(lat2.doubleValue() - lat1.doubleValue());
        Double dLng = toRadians(lng2.doubleValue() - lng1.doubleValue());
        Double l1 = toRadians(lat1.doubleValue());
        Double l2 = toRadians(lat2.doubleValue());

        Double a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                   Math.cos(l1) * Math.cos(l2) *
                   Math.sin(dLng / 2) * Math.sin(dLng / 2);
        Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return Decimal.valueOf(EARTH_RADIUS_M * c);
    }

    private static Double toRadians(Double degrees) {
        return degrees * Math.PI / 180;
    }
}