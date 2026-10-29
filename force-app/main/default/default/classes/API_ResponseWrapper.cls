/**
 * @description Shared utility class for building standard REST API responses.
 *              All mobile app API endpoints use this to ensure consistent
 *              JSON response format: { "status": true/false, "message": "...", "data": ... }
 *
 * @author  SFA Development Team
 * @date    2026
 */
public class API_ResponseWrapper {

    /**
     * @description Builds a success response JSON string.
     * @param message The success message.
     * @param data    The response data object (will be serialized).
     * @return JSON string with status=true.
     */
    public static String success(String message, Object data) {
        Map<String, Object> response = new Map<String, Object>();
        response.put('status', true);
        response.put('message', message);
        if (data != null) {
            response.put('data', data);
        }
        return JSON.serialize(response);
    }

    /**
     * @description Builds an error response JSON string.
     * @param message The error message.
     * @return JSON string with status=false.
     */
    public static String error(String message) {
        Map<String, Object> response = new Map<String, Object>();
        response.put('status', false);
        response.put('message', message);
        return JSON.serialize(response);
    }

    /**
     * @description Sets standard JSON response headers and status code on RestContext.response.
     * @param statusCode HTTP status code (200, 400, 500, etc.).
     * @param body       The JSON response body.
     */
    public static void sendResponse(Integer statusCode, String body) {
        RestResponse res = RestContext.response;
        if (res == null) {
            res = new RestResponse();
            RestContext.response = res;
        }
        res.statusCode = statusCode;
        res.addHeader('Content-Type', 'application/json');
        res.responseBody = Blob.valueOf(body);
    }

    /**
     * @description Convenience: send a 200 success response.
     */
    public static void sendSuccess(String message, Object data) {
        sendResponse(200, success(message, data));
    }

    /**
     * @description Convenience: send a 400 error response.
     */
    public static void sendError(String message) {
        sendResponse(400, error(message));
    }

    /**
     * @description Convenience: send a 500 server error response.
     */
    public static void sendServerError(String message) {
        sendResponse(500, error(message));
    }
}