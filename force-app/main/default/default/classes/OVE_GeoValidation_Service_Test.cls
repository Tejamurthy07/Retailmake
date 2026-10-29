/**
 * @description Test class for OVE_GeoValidation_Service.
 *              Validates Haversine distance calculation, proximity checks,
 *              edge cases such as identical coordinates, and boundary conditions.
 * @author  SFA Development Team
 * @date    2024
 */
@isTest
private class OVE_GeoValidation_Service_Test {

    /**
     * @description Tests distance calculation between two well-known coordinate
     *              pairs (Mumbai CST to Mumbai Airport ~22 km).
     */
    @isTest
    static void testDistanceCalculation() {
        // Mumbai CST coordinates
        Double lat1 = 18.9398;
        Double lon1 = 72.8354;

        // Mumbai Airport coordinates
        Double lat2 = 19.0896;
        Double lon2 = 72.8656;

        Test.startTest();
        Double distance = OVE_GeoValidation_Service.calculateDistance(lat1, lon1, lat2, lon2);
        Test.stopTest();

        // Distance between Mumbai CST and Airport is approximately 17-20 km
        System.assertNotEquals(null, distance, 'Distance should not be null');
        System.assert(distance > 10000,
            'Distance between Mumbai CST and Airport should be greater than 10 km, got: ' + distance);
        System.assert(distance < 30000,
            'Distance between Mumbai CST and Airport should be less than 30 km, got: ' + distance);
    }

    /**
     * @description Verifies that a point within the configured geo-fence radius
     *              returns true for proximity validation.
     */
    @isTest
    static void testProximityValid() {
        // Outlet location
        Double outletLat = 19.0760;
        Double outletLon = 72.8777;

        // Check-in location ~50 meters away
        Double checkInLat = 19.0764;
        Double checkInLon = 72.8780;

        // Radius of 200 meters
        Double radiusMeters = 200.0;

        Test.startTest();
        Boolean isWithin = OVE_GeoValidation_Service.validateCheckInProximity(
            checkInLat, checkInLon, outletLat, outletLon, radiusMeters
        );
        Test.stopTest();

        System.assertEquals(true, isWithin,
            'A location ~50m from outlet should be within a 200m radius');
    }

    /**
     * @description Verifies that a point well outside the configured geo-fence
     *              radius returns false for proximity validation.
     */
    @isTest
    static void testProximityInvalid() {
        // Outlet in Mumbai
        Double outletLat = 19.0760;
        Double outletLon = 72.8777;

        // Check-in in Delhi (~1,150 km away)
        Double checkInLat = 28.6139;
        Double checkInLon = 77.2090;

        // Radius of 500 meters
        Double radiusMeters = 500.0;

        Test.startTest();
        Boolean isWithin = OVE_GeoValidation_Service.validateCheckInProximity(
            checkInLat, checkInLon, outletLat, outletLon, radiusMeters
        );
        Test.stopTest();

        System.assertEquals(false, isWithin,
            'A location in Delhi should not be within 500m of a Mumbai outlet');
    }

    /**
     * @description Verifies that identical coordinates return zero distance.
     */
    @isTest
    static void testSameLocation() {
        Double lat = 19.0760;
        Double lon = 72.8777;

        Test.startTest();
        Double distance = OVE_GeoValidation_Service.calculateDistance(lat, lon, lat, lon);
        Test.stopTest();

        System.assertEquals(0, distance,
            'Distance between the same coordinates should be 0');
    }

    /**
     * @description Tests null coordinate handling to ensure the service
     *              gracefully handles missing data.
     */
    @isTest
    static void testNullCoordinates() {
        Test.startTest();
        Double distance = OVE_GeoValidation_Service.calculateDistance((Double)null, (Double)null, (Double)19.0760, (Double)72.8777);
        Test.stopTest();

        // Service should handle nulls gracefully, returning 0 or a default
        System.assertNotEquals(null, distance,
            'Service should return a numeric value even with null inputs');
    }

    /**
     * @description Tests proximity check with null values to verify
     *              graceful degradation.
     */
    @isTest
    static void testProximityWithNulls() {
        Test.startTest();
        Boolean result = OVE_GeoValidation_Service.validateCheckInProximity(
            (Double)null, (Double)null, (Double)19.0760, (Double)72.8777, (Double)500.0
        );
        Test.stopTest();

        System.assertEquals(false, result,
            'Proximity check with null coordinates should return false');
    }
}