/**
 * SFAVoiceProxy
 * ─────────────────────────────────────────────────────────────────────────────
 * Transport from the Salesforce LWC voice order agent to the Ai_sf2 FastAPI
 * backend (the same SFA voice endpoints the Flutter app used).
 *
 * Mirrors SFChatbotProxy's security model: the LWC never holds an API key or
 * talks to the backend directly. This class mints a short-lived RS256 JWT
 * (signed by the org's self-signed cert) and calls the backend through a
 * Named Credential. The rep's User Id rides in the JWT `sub`.
 *
 * Three methods, one per Flutter voice feature:
 *   - processVoice       → POST /sfa/voice/process        (push-to-talk turn)
 *   - realtimeSession    → POST /sfa/voice/realtime/session (mint OpenAI token)
 *   - speak              → POST /speak                     (optional TTS reply)
 *
 * The catalog + cart are sent from the LWC as JSON (every turn, stateless) and
 * passed straight through — the backend resolves products against them exactly
 * as it did for Flutter. NEVER throws to the LWC: every failure comes back as
 * isSuccess=false + a friendly errorMessage so the rep can retry by hand.
 * ─────────────────────────────────────────────────────────────────────────────
 */
public with sharing class SFAVoiceProxy {

    private static final String NAMED_CREDENTIAL = 'callout:SFAVoiceAPI';
    private static final String CERT_NAME        = 'SFAVoiceSigningKey';
    private static final String JWT_ISSUER       = 'mobileapp-voice-agent';
    private static final String JWT_AUDIENCE     = 'sfa-voice-api';
    // wss host of the backend (same host as the SFAVoiceAPI Named Credential).
    // Used ONLY by the experimental Sarvam live-voice WebSocket.
    private static final String WS_BASE          = 'wss://sfmobile.fingertipplus.com';

    // ── push-to-talk ─────────────────────────────────────────────────────────

    public class VoiceProcessResult {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String  transcript;
        @AuraEnabled public String  operationsJson;  // JSON array of Operation
        @AuraEnabled public String  spokenReply;
        @AuraEnabled public String  errorMessage;
    }

    /**
     * One push-to-talk turn. `catalogJson` / `cartJson` are the LWC's product
     * list + current cart (already JSON-encoded). Returns the resolved cart
     * operations for the LWC to apply + the sentence to speak.
     */
    @AuraEnabled
    public static VoiceProcessResult processVoice(
        String audioBase64, String contentType, String language,
        String catalogJson, String cartJson,
        Decimal availableCredit, Decimal minOrderValue,
        String lastTouchedProductId
    ) {
        VoiceProcessResult r = new VoiceProcessResult();
        r.isSuccess = false;
        try {
            if (String.isBlank(audioBase64)) {
                r.errorMessage = 'No audio captured.';
                return r;
            }
            Map<String, Object> body = new Map<String, Object>{
                'audio_base64'   => audioBase64,
                'content_type'   => String.isBlank(contentType) ? 'audio/webm' : contentType,
                'language'       => String.isBlank(language) ? 'en' : language,
                'catalog'        => parseArray(catalogJson),
                'cart'           => parseArray(cartJson),
                'min_order_value'=> minOrderValue == null ? 500 : minOrderValue
            };
            if (availableCredit != null) {
                body.put('available_credit', availableCredit);
            }
            if (String.isNotBlank(lastTouchedProductId)) {
                body.put('last_touched_product_id', lastTouchedProductId);
            }

            Map<String, Object> resp = callJson('/sfa/voice/process', JSON.serialize(body));

            Boolean ok = resp != null && resp.get('ok') == true;
            r.transcript = stringOf(resp, 'transcript');
            r.spokenReply = stringOf(resp, 'spoken_reply');
            if (resp != null && resp.get('operations') != null) {
                r.operationsJson = JSON.serialize(resp.get('operations'));
            }
            if (ok) {
                r.isSuccess = true;
                return r;
            }
            r.errorMessage = stringOf(resp, 'error');
            if (String.isBlank(r.errorMessage)) {
                r.errorMessage = 'Could not understand the audio. Please try again.';
            }
            return r;

        } catch (System.CalloutException e) {
            r.errorMessage = 'Voice service is unreachable right now.';
        } catch (Exception e) {
            r.errorMessage = 'Could not process the audio. Please try again.';
        }
        return r;
    }

    // ── realtime ("Siri-like") ─────────────────────────────────────────────────

    public class RealtimeSessionResult {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String  clientSecret;   // ephemeral, ~60s
        @AuraEnabled public Long    expiresAt;
        @AuraEnabled public String  model;
        @AuraEnabled public String  voice;
        @AuraEnabled public String  sessionConfig;   // session.update JSON
        @AuraEnabled public String  errorMessage;
    }

    /**
     * Mint an ephemeral OpenAI Realtime token + the SFA session config (cart
     * tools + persona + the rep's catalog/cart inlined). The LWC opens WebRTC
     * straight to OpenAI with the returned clientSecret — the real OpenAI key
     * never reaches the browser.
     */
    @AuraEnabled
    public static RealtimeSessionResult realtimeSession(
        String outletName, String catalogJson, String cartJson,
        Decimal availableCredit, Decimal minOrderValue, String voice
    ) {
        RealtimeSessionResult r = new RealtimeSessionResult();
        r.isSuccess = false;
        try {
            Map<String, Object> body = new Map<String, Object>{
                'catalog'         => parseArray(catalogJson),
                'cart'            => parseArray(cartJson),
                'min_order_value' => minOrderValue == null ? 500 : minOrderValue
            };
            if (String.isNotBlank(outletName))  body.put('outlet_name', outletName);
            if (availableCredit != null)        body.put('available_credit', availableCredit);
            if (String.isNotBlank(voice))       body.put('voice', voice);

            Map<String, Object> resp =
                callJson('/sfa/voice/realtime/session', JSON.serialize(body));

            Boolean ok = resp != null && resp.get('ok') == true;
            String secret = stringOf(resp, 'client_secret');
            if (ok && String.isNotBlank(secret)) {
                r.isSuccess    = true;
                r.clientSecret = secret;
                r.model        = stringOf(resp, 'model');
                r.voice        = stringOf(resp, 'voice');
                if (resp.get('expires_at') != null) {
                    r.expiresAt = Long.valueOf(String.valueOf(resp.get('expires_at')));
                }
                Object cfg = resp.get('session_config');
                if (cfg != null) {
                    r.sessionConfig = JSON.serialize(cfg);
                }
                return r;
            }
            r.errorMessage = stringOf(resp, 'error');
            if (String.isBlank(r.errorMessage)) {
                r.errorMessage = 'Voice agent unavailable.';
            }
            return r;

        } catch (System.CalloutException e) {
            r.errorMessage = 'Voice service is unreachable right now.';
        } catch (Exception e) {
            r.errorMessage = 'Could not start the voice agent.';
        }
        return r;
    }

    // ── optional TTS (spoken reply) ────────────────────────────────────────────

    public class SpeakResult {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String  audioBase64;
        @AuraEnabled public String  contentType;
        @AuraEnabled public String  errorMessage;
    }

    /**
     * Backend TTS for a spoken reply (used when the device's built-in
     * SpeechSynthesis is unavailable). Returns base64 mp3. Never throws —
     * on failure the agent simply stays silent (the cart already updated).
     */
    @AuraEnabled
    public static SpeakResult speak(String text) {
        SpeakResult s = new SpeakResult();
        s.isSuccess = false;
        try {
            if (String.isBlank(text)) {
                s.errorMessage = 'Nothing to speak.';
                return s;
            }
            Map<String, Object> resp = callJson(
                '/speak', JSON.serialize(new Map<String, Object>{ 'text' => text })
            );
            Boolean ok = resp != null && resp.get('ok') == true;
            String audio = stringOf(resp, 'audio_base64');
            if (ok && String.isNotBlank(audio)) {
                s.isSuccess   = true;
                s.audioBase64 = audio;
                s.contentType = String.isNotBlank(stringOf(resp, 'content_type'))
                    ? stringOf(resp, 'content_type') : 'audio/mpeg';
                return s;
            }
            s.errorMessage = String.isNotBlank(stringOf(resp, 'error'))
                ? stringOf(resp, 'error') : 'Voice unavailable.';
            return s;

        } catch (System.CalloutException e) {
            s.errorMessage = 'Voice service is unreachable right now.';
        } catch (Exception e) {
            s.errorMessage = 'Could not generate speech.';
        }
        return s;
    }

    // ── experimental: Sarvam live voice (WebSocket token) ──────────────────────

    public class SarvamLiveTokenResult {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String  token;        // short-lived JWT (~5 min)
        @AuraEnabled public String  wsUrl;        // wss endpoint to open
        @AuraEnabled public String  errorMessage;
    }

    /**
     * Mint a short-lived JWT the browser uses to open the EXPERIMENTAL Sarvam
     * live-voice WebSocket directly (browsers can't set a WS Authorization
     * header, so the token rides as a ?token= query param). Same RS256 JWT as
     * every other call (sub = running user, 5-min validity). The backend gates
     * the socket behind VOICE_REALTIME_PROVIDER=sarvam; default OpenAI live
     * voice never touches this path. NEVER throws.
     */
    @AuraEnabled
    public static SarvamLiveTokenResult sarvamLiveToken() {
        SarvamLiveTokenResult r = new SarvamLiveTokenResult();
        r.isSuccess = false;
        try {
            r.token = mintJwt();
            r.wsUrl = WS_BASE + '/sfa/voice/sarvam-live';
            r.isSuccess = String.isNotBlank(r.token);
            if (!r.isSuccess) {
                r.errorMessage = 'Could not start live voice.';
            }
        } catch (Exception e) {
            r.errorMessage = 'Could not start live voice.';
        }
        return r;
    }

    /**
     * Mint a short-lived JWT for the EXPERIMENTAL Gemini Live WebSocket. Same
     * token/transport as Sarvam live; only the ws path differs. Gated server-side
     * by VOICE_REALTIME_PROVIDER=gemini; default OpenAI never touches this.
     */
    @AuraEnabled
    public static SarvamLiveTokenResult geminiLiveToken() {
        SarvamLiveTokenResult r = new SarvamLiveTokenResult();
        r.isSuccess = false;
        try {
            r.token = mintJwt();
            r.wsUrl = WS_BASE + '/sfa/voice/gemini-live';
            r.isSuccess = String.isNotBlank(r.token);
            if (!r.isSuccess) {
                r.errorMessage = 'Could not start live voice.';
            }
        } catch (Exception e) {
            r.errorMessage = 'Could not start live voice.';
        }
        return r;
    }

    // ── feature toggle (gate the whole voice agent) ────────────────────────────

    /**
     * Whether the voice order agent is enabled, via the org's Feature_Toggle__mdt
     * (Feature_Code__c = 'VOICE-001'). orderEntryForm only renders the voice agent
     * when this is true, so an admin can turn the feature on/off from
     * Setup → Custom Metadata Types → Feature Toggle, with no code deploy.
     * Fails safe (hidden) if the toggle can't be read.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isVoiceAgentEnabled() {
        try {
            return BPM_FeatureToggle_Util.isEnabled('VOICE-001');
        } catch (Exception e) {
            return false;
        }
    }

    // ── transport ──────────────────────────────────────────────────────────────

    @TestVisible
    private static Map<String, Object> callJson(String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + mintJwt());
        req.setTimeout(120000);
        req.setBody(body);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() >= 300) {
            throw new VoiceException(
                'API error ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }
        Object parsed = JSON.deserializeUntyped(res.getBody());
        if (!(parsed instanceof Map<String, Object>)) {
            throw new VoiceException('Unexpected response from backend.');
        }
        return (Map<String, Object>) parsed;
    }

    // RS256 JWT, sub = running user, signed by the org's self-signed cert.
    private static String mintJwt() {
        // Crypto needs the SFAVoiceSigningKey cert to exist; don't couple test
        // coverage to cert-provisioning order. Real callouts still mint a real JWT.
        if (Test.isRunningTest()) return 'test.jwt.token';
        Auth.JWT jwt = new Auth.JWT();
        jwt.setIss(JWT_ISSUER);
        jwt.setAud(JWT_AUDIENCE);
        jwt.setSub(UserInfo.getUserId());
        jwt.setValidityLength(300);
        Auth.JWS jws = new Auth.JWS(jwt, CERT_NAME);
        return jws.getCompactSerialization();
    }

    /** Parse a JSON array string into a List the body map can re-serialize as
     *  a JSON array. Blank / malformed → empty list (the backend handles it). */
    private static List<Object> parseArray(String jsonStr) {
        if (String.isBlank(jsonStr)) return new List<Object>();
        try {
            Object parsed = JSON.deserializeUntyped(jsonStr);
            if (parsed instanceof List<Object>) return (List<Object>) parsed;
        } catch (Exception e) {
            // fall through
        }
        return new List<Object>();
    }

    private static String stringOf(Map<String, Object> m, String key) {
        if (m == null || m.get(key) == null) return null;
        return String.valueOf(m.get(key));
    }

    public class VoiceException extends Exception {}
}