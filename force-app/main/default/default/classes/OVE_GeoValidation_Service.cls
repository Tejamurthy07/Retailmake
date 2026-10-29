/**
 * @description Service class for geographic validation operations. Provides
 *              Haversine-formula-based distance calculation between two GPS
 *              coordinate pairs and proximity validation for outlet check-ins.
 *
 * @author  SFA Development Team
 * @date    2024
 */
public without sharing class OVE_GeoValidation_Service {

    /** Mean radius of the Earth in meters. */
    private static final Double EARTH_RADIUS_METERS = 6371000.0;

    /**
     * @description Validates whether a check-in location is within the specified
     *              radius of an outlet's registered location.
     *
     * @param visitLat      Latitude of the check-in (visit) location.
     * @param visitLong     Longitude of the check-in (visit) location.
     * @param outletLat     Latitude of the outlet's registered location.
     * @param outletLong    Longitude of the outlet's registered location.
     * @param radiusMeters  The maximum allowed distance in meters.
     * @return True if the check-in is within the specified radius; false otherwise.
     */
    public static Boolean validateCheckInProximity(
        Double visitLat,
        Double visitLong,
        Double outletLat,
        Double outletLong,
        Double radiusMeters
    ) {
        if (visitLat == null || visitLong == null ||
            outletLat == null || outletLong == null ||
            radiusMeters == null) {
            return false;
        }

        Double distance = calculateDistance(visitLat, visitLong, outletLat, outletLong);
        return distance <= radiusMeters;
    }

    /**
     * @description Calculates the great-circle distance between two points on
     *              the Earth's surface using the Haversine formula.
     *
     *              The Haversine formula:
     *                a = sin^2(dlat/2) + cos(lat1) * cos(lat2) * sin^2(dlon/2)
     *                c = 2 * atan2(sqrt(a), sqrt(1-a))
     *                d = R * c
     *
     * @param lat1  Latitude of the first point in decimal degrees.
     * @param lon1  Longitude of the first point in decimal degrees.
     * @param lat2  Latitude of the second point in decimal degrees.
     * @param lon2  Longitude of the second point in decimal degrees.
     * @return The distance between the two points in meters.
     */
    public static Double calculateDistance(
        Double lat1,
        Double lon1,
        Double lat2,
        Double lon2
    ) {
        if (lat1 == null || lon1 == null || lat2 == null || lon2 == null) {
            return 0;
        }

        // Convert decimal degrees to radians
        Double lat1Rad = toRadians(lat1);
        Double lat2Rad = toRadians(lat2);
        Double dLatRad = toRadians(lat2 - lat1);
        Double dLonRad = toRadians(lon2 - lon1);

        // Haversine formula
        Double a = Math.sin(dLatRad / 2) * Math.sin(dLatRad / 2) +
                   Math.cos(lat1Rad) * Math.cos(lat2Rad) *
                   Math.sin(dLonRad / 2) * Math.sin(dLonRad / 2);

        Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

        return EARTH_RADIUS_METERS * c;
    }

    /**
     * @description Converts an angle from degrees to radians.
     * @param degrees The angle in decimal degrees.
     * @return The angle in radians.
     */
    private static Double toRadians(Double degrees) {
        return degrees * Math.PI / 180.0;
    }
}