/**
 * Coverage + contract tests for SFAVoiceProxy. Uses HttpCalloutMock so no
 * real callout happens. Verifies the three entry points map the backend
 * envelope correctly and that failures degrade to isSuccess=false (never throw).
 */
@IsTest
private class SFAVoiceProxy_Test {

    private class VoiceMock implements HttpCalloutMock {
        private Integer code;
        private String  bodyJson;
        VoiceMock(Integer code, String bodyJson) {
            this.code = code;
            this.bodyJson = bodyJson;
        }
        public HttpResponse respond(HttpRequest req) {
            // sanity: the proxy must set a bearer JWT + JSON content type
            System.assert(req.getHeader('Authorization').startsWith('Bearer '),
                'proxy must send a bearer JWT');
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(code);
            res.setBody(bodyJson);
            return res;
        }
    }

    private static final String CATALOG =
        '[{"id":"p1","name":"Sunflower Oil","price":100,"min_order_qty":6}]';
    private static final String CART = '[{"product_id":"p1","qty":6}]';

    @IsTest
    static void processVoice_ok() {
        String body = JSON.serialize(new Map<String, Object>{
            'ok' => true,
            'transcript' => 'add six sunflower oil',
            'spoken_reply' => 'Added 6 Sunflower Oil.',
            'operations' => new List<Object>{
                new Map<String, Object>{
                    'action' => 'add', 'product_query' => 'sunflower oil',
                    'quantity' => 6, 'resolved_product_ids' => new List<String>{'p1'}
                }
            }
        });
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200, body));

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', CATALOG, CART, 5000, 500, null
        );
        Test.stopTest();

        System.assert(r.isSuccess, 'expected success');
        System.assertEquals('add six sunflower oil', r.transcript);
        System.assert(r.operationsJson.contains('p1'), 'operations passed through');
    }

    @IsTest
    static void processVoice_blankAudio_failsClean() {
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            '', 'audio/webm', 'en', CATALOG, CART, null, 500, null
        );
        System.assert(!r.isSuccess);
        System.assertNotEquals(null, r.errorMessage);
    }

    @IsTest
    static void processVoice_backendError_failsClean() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(500, '{"ok":false,"error":"boom"}'));
        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', CATALOG, CART, null, 500, 'p1'
        );
        Test.stopTest();
        System.assert(!r.isSuccess, 'non-2xx must fail clean');
        System.assertNotEquals(null, r.errorMessage);
    }

    @IsTest
    static void realtimeSession_ok() {
        String body = JSON.serialize(new Map<String, Object>{
            'ok' => true,
            'client_secret' => 'ek_test_123',
            'expires_at' => 1900000000,
            'model' => 'gpt-realtime',
            'voice' => 'alloy',
            'session_config' => new Map<String, Object>{ 'type' => 'realtime' }
        });
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200, body));

        Test.startTest();
        SFAVoiceProxy.RealtimeSessionResult r = SFAVoiceProxy.realtimeSession(
            'Sri Outlet', CATALOG, CART, 5000, 500, 'alloy'
        );
        Test.stopTest();

        System.assert(r.isSuccess);
        System.assertEquals('ek_test_123', r.clientSecret);
        System.assertEquals('gpt-realtime', r.model);
        System.assert(r.sessionConfig.contains('realtime'));
    }

    @IsTest
    static void realtimeSession_noSecret_failsClean() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200, '{"ok":false,"error":"nope"}'));
        Test.startTest();
        SFAVoiceProxy.RealtimeSessionResult r = SFAVoiceProxy.realtimeSession(
            null, CATALOG, CART, null, 500, null
        );
        Test.stopTest();
        System.assert(!r.isSuccess);
        System.assertEquals('nope', r.errorMessage);
    }

    @IsTest
    static void speak_ok() {
        Test.setMock(HttpCalloutMock.class,
            new VoiceMock(200, '{"ok":true,"audio_base64":"QUJD","content_type":"audio/mpeg"}'));
        Test.startTest();
        SFAVoiceProxy.SpeakResult s = SFAVoiceProxy.speak('Added six sunflower oil');
        Test.stopTest();
        System.assert(s.isSuccess);
        System.assertEquals('QUJD', s.audioBase64);
        System.assertEquals('audio/mpeg', s.contentType);
    }

    @IsTest
    static void speak_blank_failsClean() {
        SFAVoiceProxy.SpeakResult s = SFAVoiceProxy.speak('');
        System.assert(!s.isSuccess);
    }

    @IsTest
    static void sarvamLiveToken_ok() {
        // No callout — just mints the JWT (mocked to 'test.jwt.token' in tests)
        // and returns the wss endpoint URL for the browser to open.
        Test.startTest();
        SFAVoiceProxy.SarvamLiveTokenResult r = SFAVoiceProxy.sarvamLiveToken();
        Test.stopTest();
        System.assert(r.isSuccess, 'token should mint');
        System.assertEquals('test.jwt.token', r.token);
        System.assert(r.wsUrl.startsWith('wss://'), 'wss url returned');
        System.assert(r.wsUrl.endsWith('/sfa/voice/sarvam-live'), 'correct path');
    }

    @IsTest
    static void isVoiceAgentEnabled_runs() {
        // Custom metadata is visible in tests; just exercise the path (the value
        // depends on the deployed VOICE-001 toggle record).
        Test.startTest();
        Boolean enabled = SFAVoiceProxy.isVoiceAgentEnabled();
        Test.stopTest();
        System.assertNotEquals(null, enabled, 'returns a boolean');
    }

    @IsTest
    static void geminiLiveToken_ok() {
        Test.startTest();
        SFAVoiceProxy.SarvamLiveTokenResult r = SFAVoiceProxy.geminiLiveToken();
        Test.stopTest();
        System.assert(r.isSuccess, 'token should mint');
        System.assertEquals('test.jwt.token', r.token);
        System.assert(r.wsUrl.endsWith('/sfa/voice/gemini-live'), 'correct path');
    }

    // ══════════════════════════════════════════════════════════════════
    //  Extended coverage: the failure branches.
    //
    //  The class promises it NEVER throws to the LWC — every failure comes back
    //  as isSuccess=false with a friendly message. That promise is only worth
    //  anything if each failure mode is actually exercised, so the tests below
    //  drive a dead network, a non-JSON reply, a 200 carrying ok=false with no
    //  message, and malformed catalog/cart payloads.
    // ══════════════════════════════════════════════════════════════════

    /** Simulates the backend being unreachable. */
    private class DeadNetworkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new System.CalloutException('Unable to tunnel through proxy');
        }
    }

    /** A 200 whose body is valid JSON but not an object. */
    private class NonObjectMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('["unexpected","array"]');
            return res;
        }
    }

    // ── Unreachable backend ───────────────────────────────────────────

    @IsTest
    static void processVoice_whenTheServiceIsDown_saysSoWithoutThrowing() {
        Test.setMock(HttpCalloutMock.class, new DeadNetworkMock());

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', CATALOG, CART, null, 500, null
        );
        Test.stopTest();

        System.assert(!r.isSuccess, 'A dead network is a failure, not a silent success');
        System.assertEquals('Voice service is unreachable right now.', r.errorMessage,
            'The rep is told the service is down, so they know to key the order by hand');
    }

    @IsTest
    static void realtimeSession_whenTheServiceIsDown_saysSoWithoutThrowing() {
        Test.setMock(HttpCalloutMock.class, new DeadNetworkMock());

        Test.startTest();
        SFAVoiceProxy.RealtimeSessionResult r = SFAVoiceProxy.realtimeSession(
            'Sri Outlet', CATALOG, CART, 5000, 500, 'alloy'
        );
        Test.stopTest();

        System.assert(!r.isSuccess, 'No session when the backend cannot be reached');
        System.assertEquals('Voice service is unreachable right now.', r.errorMessage,
            'And the same wording as the push-to-talk path, so the UI reads consistently');
        System.assertEquals(null, r.clientSecret, 'With no half-built session handed back');
    }

    @IsTest
    static void speak_whenTheServiceIsDown_staysSilentWithoutThrowing() {
        Test.setMock(HttpCalloutMock.class, new DeadNetworkMock());

        Test.startTest();
        SFAVoiceProxy.SpeakResult s = SFAVoiceProxy.speak('Added six sunflower oil');
        Test.stopTest();

        System.assert(!s.isSuccess,
            'TTS failing must not throw — the cart has already been updated and the agent '
            + 'simply stays quiet');
        System.assertEquals('Voice service is unreachable right now.', s.errorMessage);
    }

    // ── Malformed backend replies ─────────────────────────────────────

    @IsTest
    static void processVoice_whenTheReplyIsNotAnObject_failsClean() {
        Test.setMock(HttpCalloutMock.class, new NonObjectMock());

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', CATALOG, CART, null, 500, null
        );
        Test.stopTest();

        System.assert(!r.isSuccess,
            'A JSON array where an envelope was expected is rejected rather than parsed '
            + 'into a half-populated result');
        System.assertEquals('Could not process the audio. Please try again.', r.errorMessage);
    }

    @IsTest
    static void processVoice_when200CarriesOkFalse_usesTheBackendMessage() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":false,"transcript":"mumble","error":"Could not hear you clearly."}'));

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', CATALOG, CART, null, 500, null
        );
        Test.stopTest();

        System.assert(!r.isSuccess, 'ok=false is a failure even on a 200');
        System.assertEquals('Could not hear you clearly.', r.errorMessage,
            'The backend explanation is passed through verbatim — it is more specific than '
            + 'anything this class could invent');
        System.assertEquals('mumble', r.transcript,
            'And the partial transcript still comes back, so the rep can see what was heard');
    }

    @IsTest
    static void processVoice_whenOkFalseCarriesNoMessage_fallsBackToAFriendlyOne() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200, '{"ok":false}'));

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', CATALOG, CART, null, 500, null
        );
        Test.stopTest();

        System.assert(!r.isSuccess, 'Still a failure');
        System.assertEquals('Could not understand the audio. Please try again.', r.errorMessage,
            'A silent failure would leave the LWC with nothing to show, so a default message '
            + 'is substituted');
    }

    @IsTest
    static void realtimeSession_whenOkFalseCarriesNoMessage_fallsBackToAFriendlyOne() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200, '{"ok":false}'));

        Test.startTest();
        SFAVoiceProxy.RealtimeSessionResult r = SFAVoiceProxy.realtimeSession(
            null, CATALOG, CART, null, 500, null
        );
        Test.stopTest();

        System.assert(!r.isSuccess, 'No session');
        System.assertEquals('Voice agent unavailable.', r.errorMessage, 'With a default message');
    }

    @IsTest
    static void realtimeSession_whenOkButNoSecret_isTreatedAsFailure() {
        // A 200 with ok=true but no client_secret would otherwise hand the LWC a
        // session it cannot open.
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":true,"model":"gpt-realtime","voice":"alloy"}'));

        Test.startTest();
        SFAVoiceProxy.RealtimeSessionResult r = SFAVoiceProxy.realtimeSession(
            'Sri Outlet', CATALOG, CART, 5000, 500, 'alloy'
        );
        Test.stopTest();

        System.assert(!r.isSuccess,
            'Without an ephemeral secret there is nothing for the browser to connect with, '
            + 'so ok=true alone is not enough');
        System.assertEquals(null, r.clientSecret, 'And no secret is reported');
    }

    @IsTest
    static void realtimeSession_withoutExpiryOrConfig_stillSucceeds() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":true,"client_secret":"ek_minimal","model":"gpt-realtime"}'));

        Test.startTest();
        SFAVoiceProxy.RealtimeSessionResult r = SFAVoiceProxy.realtimeSession(
            null, CATALOG, CART, null, null, null
        );
        Test.stopTest();

        System.assert(r.isSuccess, 'The secret is the only mandatory part of the envelope');
        System.assertEquals('ek_minimal', r.clientSecret, 'And it is returned');
        System.assertEquals(null, r.expiresAt, 'A missing expiry is left null, not defaulted');
        System.assertEquals(null, r.sessionConfig, 'Same for a missing session config');
    }

    @IsTest
    static void speak_whenOkFalse_reportsTheBackendMessage() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":false,"error":"TTS quota exceeded."}'));

        Test.startTest();
        SFAVoiceProxy.SpeakResult s = SFAVoiceProxy.speak('Anything');
        Test.stopTest();

        System.assert(!s.isSuccess, 'ok=false is a failure');
        System.assertEquals('TTS quota exceeded.', s.errorMessage, 'With the backend reason');
    }

    @IsTest
    static void speak_whenAudioIsMissing_failsCleanWithADefaultMessage() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200, '{"ok":true}'));

        Test.startTest();
        SFAVoiceProxy.SpeakResult s = SFAVoiceProxy.speak('Anything');
        Test.stopTest();

        System.assert(!s.isSuccess,
            'ok=true with no audio is still nothing to play, so it is reported as a failure');
        System.assertEquals('Voice unavailable.', s.errorMessage, 'With a default message');
    }

    @IsTest
    static void speak_withoutAContentType_defaultsToMpeg() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":true,"audio_base64":"QUJD"}'));

        Test.startTest();
        SFAVoiceProxy.SpeakResult s = SFAVoiceProxy.speak('Anything');
        Test.stopTest();

        System.assert(s.isSuccess, 'Audio came back, so the call succeeded');
        System.assertEquals('audio/mpeg', s.contentType,
            'The browser needs a MIME type to play the clip, so one is assumed when the '
            + 'backend omits it');
    }

    // ── Request shaping ───────────────────────────────────────────────

    @IsTest
    static void processVoice_withBlankOptionals_appliesDefaults() {
        // Blank content type, blank language, null minimum order value — the
        // proxy fills all three before calling out.
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":true,"transcript":"hello","spoken_reply":"Hi"}'));

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', '', '', CATALOG, CART, null, null, ''
        );
        Test.stopTest();

        System.assert(r.isSuccess,
            'A caller that omits the optional parameters still gets a working turn');
        System.assertEquals('hello', r.transcript, 'And the reply is mapped as usual');
    }

    @IsTest
    static void processVoice_withUnparseableCatalogAndCart_stillCallsOut() {
        // parseArray swallows bad JSON and sends an empty list — the backend
        // decides what to do about an empty catalog, not this class.
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":true,"transcript":"add oil","spoken_reply":"Which oil?"}'));

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', 'not-json-at-all', '{"not":"an array"}', null, 500, null
        );
        Test.stopTest();

        System.assert(r.isSuccess,
            'A malformed catalog degrades to an empty one rather than throwing at the rep');
        System.assertEquals('add oil', r.transcript, 'The turn still completes');
    }

    @IsTest
    static void processVoice_withNoCatalogOrCart_stillCallsOut() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":true,"transcript":"hello","spoken_reply":"Hi"}'));

        Test.startTest();
        SFAVoiceProxy.VoiceProcessResult r = SFAVoiceProxy.processVoice(
            'AAAA', 'audio/webm', 'en', null, null, null, 500, null
        );
        Test.stopTest();

        System.assert(r.isSuccess, 'Null catalog and cart are sent as empty arrays');
    }

    @IsTest
    static void realtimeSession_withUnparseableCatalog_stillCallsOut() {
        Test.setMock(HttpCalloutMock.class, new VoiceMock(200,
            '{"ok":true,"client_secret":"ek_x","model":"gpt-realtime"}'));

        Test.startTest();
        SFAVoiceProxy.RealtimeSessionResult r = SFAVoiceProxy.realtimeSession(
            'Sri Outlet', '{{{bad', 'also bad', 5000, 500, 'alloy'
        );
        Test.stopTest();

        System.assert(r.isSuccess,
            'The session mints regardless — the catalog is the backend problem to validate');
    }
}