import { LightningElement, api, track } from 'lwc';
import processVoice from '@salesforce/apex/SFAVoiceProxy.processVoice';
import realtimeSession from '@salesforce/apex/SFAVoiceProxy.realtimeSession';
import speak from '@salesforce/apex/SFAVoiceProxy.speak';
import sarvamLiveToken from '@salesforce/apex/SFAVoiceProxy.sarvamLiveToken';
import geminiLiveToken from '@salesforce/apex/SFAVoiceProxy.geminiLiveToken';

/**
 * voiceOrderAgent — the SFA voice order agent, ported from the Flutter app.
 *
 * Two modes share one mic UI:
 *   • Push-to-talk  — tap to record, /sfa/voice/process returns cart
 *     operations + a spoken reply. (Flutter: VoiceRecorder + IntentDispatcher.)
 *   • Live (realtime) — WebRTC straight to OpenAI; the model calls cart tools
 *     over the data channel. (Flutter: RealtimeClient + RealtimeToolDispatcher.)
 *
 * This component owns NO cart state. It reads the catalog + cart from the
 * parent (orderEntryForm) via @api props and emits `voicecartop` events the
 * parent applies to the real cart. A local working copy of the cart (qty by
 * id) is kept only to build spoken replies with live totals — exactly as the
 * Flutter CartProvider did. It re-syncs from the authoritative @api cart each
 * render.
 *
 * Never breaks the page: every failure degrades to a spoken/inline error and
 * the rep keeps using the screen by hand.
 */
export default class VoiceOrderAgent extends LightningElement {
    // ── inputs from the parent (orderEntryForm) ───────────────────────────────
    /** [{id, name, brand, category, price, unit, minOrderQty}] */
    @api
    get catalog() { return this._catalog; }
    set catalog(v) { this._catalog = Array.isArray(v) ? v : []; this._indexCatalog(); }
    _catalog = [];

    /** [{productId, qty}] — authoritative cart from the parent. */
    @api
    get cart() { return this._cartIn; }
    set cart(v) {
        const incoming = Array.isArray(v) ? v : [];
        // A manual edit during a live session changes the cart WITHOUT the agent's
        // tool call — the agent's own edits already updated _workingCart, so only a
        // hand edit will differ. Tell the model about those so it stays in sync.
        const manual = this.rtActive && this._cartDiffersFromWorking(incoming);
        this._cartIn = incoming;
        // capture each line's serial number + unit price for "item N" answers
        // and per-item subtotals.
        this._cartSerials = {};
        this._cartUnitPrice = {};
        incoming.forEach(l => {
            if (l && l.productId) {
                if (l.serialNumber !== undefined && l.serialNumber !== null) {
                    this._cartSerials[l.productId] = l.serialNumber;
                }
                if (l.unitPrice !== undefined && l.unitPrice !== null) {
                    this._cartUnitPrice[l.productId] = Number(l.unitPrice) || 0;
                }
            }
        });
        this._syncWorkingCart();
        if (manual) {
            this._scheduleManualEditReport();   // OpenAI realtime path
            this._svSyncCart();                 // Sarvam live path (no-op if not active)
        }
    }
    _cartIn = [];

    @api outletName;
    @api availableCredit;          // Number or null/undefined = unlimited
    @api minOrderValue = 500;
    @api voice = 'alloy';
    @api language = 'en';
    @api disabled = false;
    // Live-voice provider: 'openai' (default — OpenAI Realtime/WebRTC) or
    // 'sarvam' (experimental Sarvam streaming pipeline over our backend WS).
    // The OpenAI path is untouched; set to 'sarvam' only to run the experiment.
    @api liveProvider = 'openai';
    /** [{name, text}] active order-level offers (real scheme data). */
    @api
    get offers() { return this._offers; }
    set offers(v) { this._offers = Array.isArray(v) ? v : []; }
    _offers = [];

    /** [{label, value}] real category picklist options. */
    @api
    get categories() { return this._categories; }
    set categories(v) { this._categories = Array.isArray(v) ? v : []; }
    _categories = [];

    // ── reactive UI state ─────────────────────────────────────────────────────
    @track isRecording = false;
    @track isThinking = false;       // backend turn in flight
    @track isSpeaking = false;
    @track statusText = '';
    @track lastTranscript = '';
    @track rtActive = false;
    @track rtStarting = false;
    @track rtStatus = '';
    @track candidates = [];          // disambiguation options on screen
    @track panelOpen = true;         // floating panel expanded vs collapsed FAB
    @track expanded = false;         // larger panel for a bigger transcript
    @track youSaid = '';             // live transcript — the rep's words
    @track agentSaid = '';           // live transcript — the agent's words
    @track lang = 'en';              // 'auto' | en | hi | ta | te | kn | ml (default English = predictable)
    @track suggestOffers = true;     // proactively mention offers on add
    @track handsFree = false;        // hands-free auto-turn (VAD) session active
    @track showCaptions = true;      // live captions on/off (settings toggle)
    @track settingsOpen = false;     // settings dropdown open/closed

    // ── internal (non-reactive) ───────────────────────────────────────────────
    _catalogById = {};
    _workingCart = {};               // productId -> qty (mirror for spoken totals)
    _cartSerials = {};               // productId -> serial number (cart line position)
    _cartUnitPrice = {};             // productId -> unit price (authoritative line rate)
    _lastTouchedProductId = null;
    _pendingDisambig = null;         // { op | toolCall, qty, source }

    // recorder
    _mediaStream = null;
    _mediaRecorder = null;
    _audioChunks = [];
    _recMime = '';
    _recTimeoutId = null;
    _MAX_REC_MS = 20000;

    // hands-free (auto-turn) — one persistent mic stream + a VAD that segments
    // utterances by silence. Same Whisper + GPT-4o-mini backend as push-to-talk.
    _hfStream = null;
    _hfAudioCtx = null;
    _hfAnalyser = null;
    _hfData = null;
    _hfRecorder = null;
    _hfChunks = [];
    _hfTimer = null;
    _hfCapturing = false;            // currently recording an utterance
    _hfStart = 0;
    _hfLastVoice = 0;
    _HF_THRESHOLD = 0.02;            // RMS above this = speech
    _HF_SILENCE_MS = 900;            // this much silence ends an utterance
    _HF_MIN_MS = 350;                // shorter than this = noise, ignore
    _HF_MAX_MS = 15000;              // force-send a very long utterance

    // realtime
    _rtPc = null;
    _rtDc = null;
    _rtMicStream = null;
    _rtCapTimer = null;
    _RT_MAX_MS = 3600000;            // 60-min cap (OpenAI's own realtime max is also 60 min)
    _rtPendingCalls = {};            // item_id -> {callId, name, argsBuffer}
    _rtResponseActive = false;
    _rtToolOutputPending = false;
    _rtLastTouchedId = null;
    _manualEditTimer = null;         // debounces manual-edit notices to the model

    // sarvam live voice (WebSocket → our backend orchestrator)
    _svWs = null;
    _svMicStream = null;
    _svCapCtx = null;                // mic-capture AudioContext
    _svSource = null;                // mic source node
    _svProcessor = null;            // ScriptProcessor capturing PCM
    _svPlayCtx = null;               // playback AudioContext
    _svPlaySource = null;            // current TTS playback node
    _svAudioChunks = [];             // accumulated TTS bytes for the current reply
    _svCapTimer = null;

    // gemini live voice (WebSocket → our backend → Gemini Live)
    _gmWs = null;
    _gmMicStream = null;
    _gmCapCtx = null;
    _gmSource = null;
    _gmProcessor = null;
    _gmPlayCtx = null;               // playback context (raw PCM 24k)
    _gmPlayTime = 0;                 // next scheduled chunk start (gap-free playback)
    _gmSources = [];                 // scheduled playback nodes (for barge-in stop)
    _gmCapTimer = null;

    // languages the realtime transcription model accepts as a hint
    // (en/hi/ta/kn ok; te/ml NOT supported — omit the hint for those).
    _TR_SUPPORTED = ['en', 'hi', 'ta', 'kn'];

    // tts
    _audioCtx = null;
    _ttsSource = null;

    // drag + live speech recognition (push-to-talk interim transcript)
    _dragging = false;
    _dragOffX = 0;
    _dragOffY = 0;
    _moveH = null;
    _upH = null;
    _sr = null;

    // ── derived ───────────────────────────────────────────────────────────────
    get hasCandidates() { return this.candidates && this.candidates.length > 0; }
    get isEmptyTranscript() { return !this.youSaid && !this.agentSaid && !this.statusText; }
    get fabClass() {
        return 'voa-fab' + (this.rtActive ? ' voa-fab_live' : '')
            + (this.isThinking || this.isRecording ? ' voa-fab_busy' : '');
    }
    togglePanel() { this.panelOpen = !this.panelOpen; }
    toggleExpand() { this.expanded = !this.expanded; }

    // ── language ──────────────────────────────────────────────────────────────
    get langOptions() {
        return [
            { value: 'auto', label: '🌐 Auto' },
            { value: 'en', label: 'English' },
            { value: 'hi', label: 'हिन्दी' },
            { value: 'ta', label: 'தமிழ்' },
            { value: 'te', label: 'తెలుగు' },
            { value: 'kn', label: 'ಕನ್ನಡ' },
            { value: 'ml', label: 'മലയാളം' },
            { value: 'gu', label: 'ગુજરાતી' }
        ].map(o => ({ ...o, selected: o.value === this.lang }));
    }
    handleLangChange(event) {
        this.lang = event.target.value;
        // if a live session is running, tell the model to switch now
        if (this.rtActive) {
            this._rtSend({ type: 'conversation.item.create', item: { type: 'message', role: 'user',
                content: [{ type: 'input_text', text: this._langDirective() }] } });
            this._rtSend({ type: 'response.create' });
        }
    }
    _langName(code) {
        return { en: 'English', hi: 'Hindi', ta: 'Tamil', te: 'Telugu', kn: 'Kannada', ml: 'Malayalam', gu: 'Gujarati' }[code] || 'English';
    }
    _langDirective() {
        // The catalog + product search are in ENGLISH, so product names passed to
        // tools must always be English even when the rep speaks another language.
        const toolRule = ' TOOL ARGUMENTS RULE: the catalog and product search are in ENGLISH. '
            + 'Whenever you pass a product to ANY tool (add_to_cart, change_quantity, remove_from_cart, '
            + 'search_products), give the product name in ENGLISH as written in the catalog — translate '
            + 'the rep\'s words if they spoke another language. Numbers/quantities as digits. ONLY your '
            + 'spoken reply uses the rep\'s language; tool arguments are always English.';
        const opsRule = ' OPERATIONS IN ANY LANGUAGE: understand and carry out EVERY kind of request — '
            + 'add an item, increase or decrease quantity, set an exact quantity, remove an item, clear '
            + 'the cart, search or browse products, pick a category, ask for the running total or a '
            + 'summary, ask about offers/schemes — no matter which language the rep speaks (English, '
            + 'Hindi, Tamil, Telugu, Kannada, Malayalam, Gujarati or any other), including mixed '
            + 'language. Convert quantities spoken in ANY language into plain digits for the tool call '
            + '(e.g. "saat"/"ஏழு"/"saatএকটা" → 7). Never refuse a request just because it was not in '
            + 'English.';
        const pronounceRule = ' PRONUNCIATION (HARD RULE, EVERY LANGUAGE): Speak the sentence FLUENTLY in '
            + 'the rep\'s language, but ALWAYS say these parts in ENGLISH: every number (quantity, count, '
            + 'amount, price, total) AND every product / item name. Code-switch SMOOTHLY and naturally — '
            + 'exactly like an Indian salesperson who talks in Hindi/Telugu/Tamil/Kannada/etc. but says '
            + 'the product names and numbers in English, with no awkward pause around them. NEVER '
            + 'translate or transliterate a number or an item name into the local language or script. '
            + 'Examples — Hindi: "छह Groundnut Oil डाल दिया, total 540 rupees." Telugu: "ఆరు Groundnut '
            + 'Oil add chesanu, total 540 rupees." Tamil: "ஆறு Groundnut Oil சேர்த்துட்டேன், total 540 '
            + 'rupees." This applies in EVERY language, every time.';
        if (this.lang === 'auto' || !this.lang) {
            return 'LANGUAGE: Respond in the SAME language the rep speaks. If they speak '
                + 'Hindi, Tamil, Telugu, Kannada, Malayalam or any language, reply in THAT '
                + 'language. If they struggle in English, switch to their language. Always '
                + 'match the rep.' + toolRule + opsRule + pronounceRule;
        }
        return 'LANGUAGE: Always respond ONLY in ' + this._langName(this.lang)
            + ', regardless of the language the rep uses. Still UNDERSTAND the rep whatever '
            + 'language they speak in.' + toolRule + opsRule + pronounceRule;
    }
    /** BCP-47 tag for browser TTS / speech recognition. */
    _bcp47() {
        return { en: 'en-IN', hi: 'hi-IN', ta: 'ta-IN', te: 'te-IN', kn: 'kn-IN', ml: 'ml-IN', gu: 'gu-IN' }[this.lang] || 'en-IN';
    }
    /** Language code sent to the push-to-talk backend (Whisper). */
    _sttLang() { return this.lang === 'auto' ? 'en' : this.lang; }

    // ── offers / schemes (live voice, quoted from real data) ──────────────────
    toggleOffers() {
        this.suggestOffers = !this.suggestOffers;
        if (this.rtActive) {
            const msg = this.suggestOffers
                ? 'The rep just turned offers ON. From now on, when you add a product that has an '
                  + 'offer, briefly suggest it. Also, right now, if any item ALREADY in the cart has '
                  + 'an offer in your list, mention it in one short line.'
                : 'The rep turned offers OFF. Stop suggesting offers and schemes for the rest of '
                  + 'this session.';
            this._rtSend({ type: 'conversation.item.create', item: { type: 'message', role: 'user',
                content: [{ type: 'input_text', text: msg }] } });
            this._rtSend({ type: 'response.create' });
        }
    }
    get offersLabel() { return this.suggestOffers ? '💡 Offers: on' : '💡 Offers: off'; }
    get offersBtnClass() { return 'voa-offers-btn' + (this.suggestOffers ? ' voa-offers-btn_on' : ''); }
    toggleSettings() { this.settingsOpen = !this.settingsOpen; }
    toggleCaptions() { this.showCaptions = !this.showCaptions; }

    /** Build the offers section of the live-voice prompt from REAL data only.
     *  The data is ALWAYS injected (so the rep can turn offers on mid-session);
     *  only the rule line flips with the toggle. */
    _offersDirective() {
        const prod = (this._catalog || [])
            .filter(p => p && p.offers)
            .slice(0, 60)
            .map(p => '  - ' + p.name + ': ' + this._rs(p.offers));
        const order = (this._offers || [])
            .slice(0, 12)
            .map(o => '  - ' + o.name + (o.text ? ' — ' + this._rs(o.text) : ''));
        let block = 'OFFERS & SCHEMES (quote ONLY from this list — never invent an offer):\n';
        block += 'Product offers:\n' + (prod.length ? prod.join('\n') : '  (none)') + '\n';
        block += 'Order-level offers:\n' + (order.length ? order.join('\n') : '  (none)') + '\n\n';
        if (this.suggestOffers) {
            block += 'OFFER RULE: When you ADD a product that has an offer above (match by product '
                + 'name), mention it in ONE short, friendly line (e.g. "added 6 — and it\'s buy 6 get '
                + '1 free"). Mention only the ONE most relevant offer, never a list. For order-level '
                + 'offers, only nudge if the cart is near the threshold. NEVER state an offer not in '
                + 'the list. If the rep says "don\'t suggest" / "I\'ll add myself", STOP proactively '
                + 'suggesting for the rest of the session.';
        } else {
            block += 'OFFER RULE: Do NOT proactively mention offers or schemes.';
        }
        block += ' BUT if the rep EXPLICITLY asks about offers/schemes (e.g. "what offers are there", '
            + '"any scheme on this", "is there a discount"), ALWAYS explain the relevant offers from '
            + 'the list above in full detail — even when proactive suggestions are off.';
        return block;
    }
    get panelClass() { return 'voa-panel' + (this.expanded ? ' voa-panel_expanded' : ''); }
    get expandLabel() { return this.expanded ? 'Shrink' : 'Expand'; }

    // The agent NEVER saves or places orders — it has no place_order tool and no
    // confirm card. The rep reviews the cart on screen and taps Place Order.

    // ── drag the floating widget anywhere (mouse + touch) ─────────────────────
    startDrag(event) {
        const pt = event.touches ? event.touches[0] : event;
        const wrap = this.template.querySelector('.voa-fab-wrap');
        if (!wrap) return;
        const rect = wrap.getBoundingClientRect();
        this._dragOffX = pt.clientX - rect.left;
        this._dragOffY = pt.clientY - rect.top;
        this._dragging = true;
        this._moveH = (e) => this._onDragMove(e);
        this._upH = () => this._onDragEnd();
        document.addEventListener('mousemove', this._moveH);
        document.addEventListener('mouseup', this._upH);
        document.addEventListener('touchmove', this._moveH, { passive: false });
        document.addEventListener('touchend', this._upH);
    }
    _onDragMove(event) {
        if (!this._dragging) return;
        if (event.cancelable) event.preventDefault();
        const pt = event.touches ? event.touches[0] : event;
        const wrap = this.template.querySelector('.voa-fab-wrap');
        if (!wrap) return;
        const r = wrap.getBoundingClientRect();
        let x = pt.clientX - this._dragOffX;
        let y = pt.clientY - this._dragOffY;
        // keep the WHOLE widget on screen (never push any edge off)
        x = Math.max(0, Math.min(x, window.innerWidth - r.width));
        y = Math.max(0, Math.min(y, window.innerHeight - r.height));
        wrap.style.left = x + 'px';
        wrap.style.top = y + 'px';
        wrap.style.right = 'auto';
        wrap.style.bottom = 'auto';
    }
    _onDragEnd() {
        this._dragging = false;
        document.removeEventListener('mousemove', this._moveH);
        document.removeEventListener('mouseup', this._upH);
        document.removeEventListener('touchmove', this._moveH);
        document.removeEventListener('touchend', this._upH);
    }

    // ── free resize (drag the bottom-right corner to any size) ────────────────
    startResize(event) {
        event.stopPropagation();          // don't start a drag
        const pt = event.touches ? event.touches[0] : event;
        const panel = this.template.querySelector('.voa-panel');
        const tr = this.template.querySelector('.voa-transcript');
        if (!panel) return;
        this._rsX = pt.clientX;
        this._rsY = pt.clientY;
        this._rsW = panel.getBoundingClientRect().width;
        this._rsH = tr ? tr.getBoundingClientRect().height : 190;
        this._rMoveH = (e) => this._onResizeMove(e);
        this._rUpH = () => this._onResizeEnd();
        document.addEventListener('mousemove', this._rMoveH);
        document.addEventListener('mouseup', this._rUpH);
        document.addEventListener('touchmove', this._rMoveH, { passive: false });
        document.addEventListener('touchend', this._rUpH);
    }
    _onResizeMove(event) {
        if (event.cancelable) event.preventDefault();
        const pt = event.touches ? event.touches[0] : event;
        const panel = this.template.querySelector('.voa-panel');
        const tr = this.template.querySelector('.voa-transcript');
        if (!panel) return;
        const w = Math.max(280, Math.min(this._rsW + (pt.clientX - this._rsX), window.innerWidth - 40));
        const h = Math.max(120, Math.min(this._rsH + (pt.clientY - this._rsY), window.innerHeight - 160));
        panel.style.width = w + 'px';
        if (tr) tr.style.maxHeight = h + 'px';
    }
    _onResizeEnd() {
        document.removeEventListener('mousemove', this._rMoveH);
        document.removeEventListener('mouseup', this._rUpH);
        document.removeEventListener('touchmove', this._rMoveH);
        document.removeEventListener('touchend', this._rUpH);
        this._clampIntoView();
    }

    /** If the widget ends up partly off-screen (after resize / window resize),
     *  nudge it fully back into view. */
    _clampIntoView() {
        const wrap = this.template.querySelector('.voa-fab-wrap');
        if (!wrap) return;
        const r = wrap.getBoundingClientRect();
        if (r.left < 0 || r.top < 0 || r.right > window.innerWidth || r.bottom > window.innerHeight) {
            const x = Math.max(0, Math.min(r.left, window.innerWidth - r.width));
            const y = Math.max(0, Math.min(r.top, window.innerHeight - r.height));
            wrap.style.left = x + 'px';
            wrap.style.top = y + 'px';
            wrap.style.right = 'auto';
            wrap.style.bottom = 'auto';
        }
    }

    // ── live interim transcript for tap-and-speak (browser recognizer, display
    //    only — Whisper still does the authoritative transcription on stop) ────
    _startLiveSTT() {
        const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
        if (!SR) return;
        try {
            const r = new SR();
            r.continuous = true;
            r.interimResults = true;
            r.lang = this._bcp47();
            r.onresult = (ev) => {
                let t = '';
                for (let i = 0; i < ev.results.length; i++) t += ev.results[i][0].transcript;
                this.youSaid = t.trim();
            };
            r.onerror = () => { /* display-only; ignore */ };
            this._sr = r;
            r.start();
        } catch (e) { /* unsupported / mic busy — fall back to post-Whisper text */ }
    }
    _stopLiveSTT() {
        if (this._sr) { try { this._sr.stop(); } catch (e) { /* */ } this._sr = null; }
    }

    get micDisabled() { return this.disabled || this.isThinking || this.rtStarting || this.rtActive || this.handsFree; }
    get liveDisabled() { return this.disabled || this.isRecording || this.isThinking || this.rtStarting || this.handsFree; }
    get handsFreeClass() { return 'voa-hf' + (this.handsFree ? ' voa-hf_on' : ''); }
    get handsFreeLabel() { return this.handsFree ? 'Stop' : 'Hands-free'; }
    get handsFreeDisabled() { return this.disabled || this.isRecording || this.rtStarting || this.rtActive; }
    get micClass() {
        return 'voa-mic' + (this.isRecording ? ' voa-mic_recording' : '')
            + (this.isThinking ? ' voa-mic_thinking' : '');
    }
    get liveClass() {
        return 'voa-live' + (this.rtActive ? ' voa-live_on' : '');
    }
    get liveLabel() {
        if (this.rtStarting) return 'Connecting…';
        return this.rtActive ? 'Stop' : 'Live voice';
    }
    get micLabel() {
        if (this.isThinking) return 'Working…';
        return this.isRecording ? 'Listening — tap to send' : 'Tap & speak';
    }

    // ── lifecycle ──────────────────────────────────────────────────────────────
    connectedCallback() {
        this._winResizeH = () => this._clampIntoView();
        window.addEventListener('resize', this._winResizeH);
    }
    disconnectedCallback() {
        this._stopRecording();
        this._stopSpeaking();
        this._rtCleanup();
        this._svCleanup();
        this._gmCleanup();
        this._hfCleanup();
        this._onDragEnd();
        this._onResizeEnd();
        if (this._winResizeH) window.removeEventListener('resize', this._winResizeH);
    }

    // ── catalog / cart bookkeeping ──────────────────────────────────────────────
    _indexCatalog() {
        const m = {};
        for (const p of this._catalog) {
            if (p && p.id) m[p.id] = p;
        }
        this._catalogById = m;
    }
    _syncWorkingCart() {
        const w = {};
        for (const line of this._cartIn) {
            if (line && line.productId) w[line.productId] = Number(line.qty) || 0;
        }
        this._workingCart = w;
    }

    /** True if the incoming cart differs from the agent's working cart (i.e. a
     *  hand edit the agent didn't make). */
    _cartDiffersFromWorking(incoming) {
        const inc = {};
        incoming.forEach(l => { if (l && l.productId) inc[l.productId] = Number(l.qty) || 0; });
        const ids = new Set([...Object.keys(inc), ...Object.keys(this._workingCart)]);
        for (const id of ids) {
            if ((inc[id] || 0) !== (this._qtyOf(id) || 0)) return true;
        }
        return false;
    }

    /** Debounce a flurry of manual +/- taps into one "cart changed" note. */
    _scheduleManualEditReport() {
        clearTimeout(this._manualEditTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._manualEditTimer = setTimeout(() => this._reportManualEdit(), 1200);
    }
    _reportManualEdit() {
        if (!this.rtActive) return;
        const summary = this._buildSummary();
        // silent context update — NO response.create, so it doesn't interrupt.
        this._rtSend({ type: 'conversation.item.create', item: { type: 'message', role: 'user',
            content: [{ type: 'input_text', text: 'NOTE: the rep just edited the cart by hand on '
                + 'screen. The cart is now: ' + summary + ' Treat this as the current, authoritative '
                + 'cart — do not re-add or re-announce these items. Continue from here.' }] } });
    }
    _nameOf(id) {
        const p = this._catalogById[id];
        return (p && p.name) ? p.name : 'product';
    }
    _priceOf(id) {
        // prefer the cart line's actual unit price (matches the order); fall back
        // to the catalog price for products not yet in the cart.
        if (this._cartUnitPrice && this._cartUnitPrice[id] !== undefined) {
            return Number(this._cartUnitPrice[id]) || 0;
        }
        const p = this._catalogById[id];
        return p ? (Number(p.price) || 0) : 0;
    }
    _serialOf(id) { return this._cartSerials ? this._cartSerials[id] : undefined; }
    _minQtyOf(id) {
        const p = this._catalogById[id];
        return p ? (Number(p.minOrderQty) || 0) : 0;
    }
    _qtyOf(id) { return Number(this._workingCart[id]) || 0; }
    _total() {
        let t = 0;
        for (const id in this._workingCart) {
            t += this._qtyOf(id) * this._priceOf(id);
        }
        return t;
    }
    _creditFinite() {
        return this.availableCredit !== null && this.availableCredit !== undefined
            && isFinite(Number(this.availableCredit));
    }

    /** Emit a cart op to the parent AND mirror it locally for spoken totals. */
    _emit(action, productId, quantity, delta) {
        this.dispatchEvent(new CustomEvent('voicecartop', {
            detail: { action, productId, quantity, delta }
        }));
        // mirror
        if (action === 'add' || action === 'set_qty') {
            this._workingCart[productId] = Number(quantity) || 0;
        } else if (action === 'increment') {
            this._workingCart[productId] = this._qtyOf(productId) + (Number(delta) || 1);
        } else if (action === 'decrement') {
            this._workingCart[productId] = Math.max(0, this._qtyOf(productId) - (Number(delta) || 1));
        } else if (action === 'remove') {
            delete this._workingCart[productId];
        } else if (action === 'clear_cart') {
            this._workingCart = {};
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  PUSH-TO-TALK
    // ════════════════════════════════════════════════════════════════════════════
    async handleMicClick() {
        if (this.micDisabled) return;
        if (this.isRecording) { this._stopRecording(); return; }
        this._stopSpeaking();
        await this._startRecording();
    }

    async _startRecording() {
        if (!navigator.mediaDevices || !window.MediaRecorder) {
            this.statusText = 'Voice input is not available in this browser.';
            return;
        }
        try {
            this._mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });
        } catch (e) {
            this.statusText = 'Please allow microphone access and try again.';
            return;
        }
        this._audioChunks = [];
        this._recMime = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4']
            .find(t => window.MediaRecorder.isTypeSupported(t)) || '';
        const opts = this._recMime ? { mimeType: this._recMime } : undefined;
        this._mediaRecorder = new MediaRecorder(this._mediaStream, opts);
        this._mediaRecorder.ondataavailable = (ev) => {
            if (ev.data && ev.data.size > 0) this._audioChunks.push(ev.data);
        };
        this._mediaRecorder.onstop = () => this._onRecordingStopped();
        this._mediaRecorder.start();
        this.isRecording = true;
        this.statusText = 'Listening…';
        this.youSaid = '';
        this.agentSaid = '';
        this._startLiveSTT();           // live interim transcript while recording
        this._playTone(440, 760, 130);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._recTimeoutId = setTimeout(() => {
            if (this.isRecording) this._stopRecording();
        }, this._MAX_REC_MS);
    }

    _stopRecording() {
        if (this.isRecording) this._playTone(760, 340, 150);
        this._stopLiveSTT();
        if (this._recTimeoutId) { clearTimeout(this._recTimeoutId); this._recTimeoutId = null; }
        if (this._mediaRecorder && this._mediaRecorder.state !== 'inactive') {
            try { this._mediaRecorder.stop(); } catch (e) { /* */ }
        }
        if (this._mediaStream) {
            this._mediaStream.getTracks().forEach(t => t.stop());
            this._mediaStream = null;
        }
        this.isRecording = false;
    }

    async _onRecordingStopped() {
        const blob = new Blob(this._audioChunks, { type: this._recMime || 'audio/webm' });
        this._audioChunks = [];
        await this._processVoiceBlob(blob, this._recMime, true);
    }

    /** Shared: send one recorded utterance to the backend (Whisper + GPT-4o-mini),
     *  apply the cart ops, speak the reply. Used by push-to-talk AND hands-free.
     *  `speakErrors` is false in hands-free so stray noise doesn't make it chatter. */
    async _processVoiceBlob(blob, mime, speakErrors) {
        if (!blob || !blob.size) return;
        this._stopSpeaking();
        this.isThinking = true;
        this.statusText = 'Understanding…';
        try {
            const audioBase64 = await this._blobToBase64(blob);
            const result = await processVoice({
                audioBase64,
                contentType: mime || 'audio/webm',
                language: this._sttLang(),
                catalogJson: JSON.stringify(this._backendCatalog()),
                cartJson: JSON.stringify(this._backendCart()),
                availableCredit: this._creditFinite() ? Number(this.availableCredit) : null,
                minOrderValue: Number(this.minOrderValue) || 500,
                lastTouchedProductId: this._lastTouchedProductId
            });
            this.isThinking = false;

            if (!result || !result.isSuccess) {
                const msg = (result && result.errorMessage) || 'Could not understand that. Try again.';
                this.statusText = msg;
                if (speakErrors) await this._speak(msg);
                return;
            }
            this.lastTranscript = (result.transcript || '').trim();
            this.youSaid = this.lastTranscript;
            let operations = [];
            try { operations = JSON.parse(result.operationsJson || '[]'); } catch (e) { operations = []; }
            const reply = this._applyOperations(operations, result.spokenReply || '');
            this.statusText = '';
            this.agentSaid = reply;
            if (reply) await this._speak(reply);
        } catch (e) {
            this.isThinking = false;
            this.statusText = 'Voice failed — please try again.';
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  HANDS-FREE (auto-turn) — Whisper + GPT-4o-mini, no tapping. A VAD watches
    //  the mic level, auto-records each utterance, and sends it when the rep stops
    //  talking, then listens again. Same cheap backend as push-to-talk.
    // ════════════════════════════════════════════════════════════════════════════
    async handleHandsFreeToggle() {
        if (this.handsFree) { this._stopHandsFree(); return; }
        await this._startHandsFree();
    }

    async _startHandsFree() {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia || !window.MediaRecorder) {
            this.statusText = 'Voice input is not available in this browser.';
            return;
        }
        this._stopSpeaking();
        try {
            this._hfStream = await navigator.mediaDevices.getUserMedia({
                audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
            });
        } catch (e) {
            this.statusText = this._micErrorMessage(e);
            return;
        }
        this._recMime = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4']
            .find(t => window.MediaRecorder.isTypeSupported(t)) || '';
        try {
            const Ctx = window.AudioContext || window.webkitAudioContext;
            this._hfAudioCtx = new Ctx();
            const src = this._hfAudioCtx.createMediaStreamSource(this._hfStream);
            this._hfAnalyser = this._hfAudioCtx.createAnalyser();
            this._hfAnalyser.fftSize = 1024;
            this._hfData = new Uint8Array(this._hfAnalyser.fftSize);
            src.connect(this._hfAnalyser);     // no destination → rep doesn't hear themselves
        } catch (e) {
            this._stopHandsFree();
            this.statusText = 'Could not start hands-free.';
            return;
        }
        this.handsFree = true;
        this._hfCapturing = false;
        this.youSaid = '';
        this.agentSaid = '';
        this.statusText = 'Hands-free on — just speak.';
        this._playTone(440, 760, 130);         // chirp + unlocks audio for TTS
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._hfTimer = setInterval(() => this._hfTick(), 100);
    }

    _hfTick() {
        if (!this.handsFree) return;
        // pause while the agent is thinking/speaking — don't capture its own voice
        if (this.isThinking || this.isSpeaking) {
            if (this._hfCapturing) this._hfAbortUtterance();
            return;
        }
        const vol = this._hfVolume();
        const now = Date.now();
        if (vol > this._HF_THRESHOLD) {
            if (!this._hfCapturing) {
                this._hfCapturing = true;
                this._hfStart = now;
                this._hfStartUtterance();
            }
            this._hfLastVoice = now;
            if (now - this._hfStart > this._HF_MAX_MS) this._hfEndUtterance(now - this._hfStart);
        } else if (this._hfCapturing && (now - this._hfLastVoice) > this._HF_SILENCE_MS) {
            this._hfEndUtterance(now - this._hfStart);
        }
    }

    _hfVolume() {
        if (!this._hfAnalyser) return 0;
        this._hfAnalyser.getByteTimeDomainData(this._hfData);
        let sum = 0;
        for (let i = 0; i < this._hfData.length; i++) {
            const v = (this._hfData[i] - 128) / 128;
            sum += v * v;
        }
        return Math.sqrt(sum / this._hfData.length);
    }

    _hfStartUtterance() {
        this._hfChunks = [];
        const opts = this._recMime ? { mimeType: this._recMime } : undefined;
        try { this._hfRecorder = new MediaRecorder(this._hfStream, opts); }
        catch (e) {
            try { this._hfRecorder = new MediaRecorder(this._hfStream); }
            catch (e2) { this._hfRecorder = null; return; }
        }
        this._hfRecorder.ondataavailable = (ev) => { if (ev.data && ev.data.size) this._hfChunks.push(ev.data); };
        this._hfRecorder.start();
        this.youSaid = '';
        this.statusText = 'Listening…';
    }

    _hfEndUtterance(durMs) {
        this._hfCapturing = false;
        const rec = this._hfRecorder;
        this._hfRecorder = null;
        if (!rec) return;
        const mime = this._recMime || 'audio/webm';
        rec.onstop = () => {
            const blob = new Blob(this._hfChunks, { type: mime });
            this._hfChunks = [];
            // ignore blips too short to be a real command
            if (durMs < this._HF_MIN_MS || blob.size < 1200) {
                if (this.handsFree) this.statusText = 'Hands-free on — just speak.';
                return;
            }
            this._processVoiceBlob(blob, mime, false);
        };
        try { rec.stop(); } catch (e) { /* */ }
    }

    /** Drop the current capture without sending (e.g. the agent started speaking). */
    _hfAbortUtterance() {
        this._hfCapturing = false;
        const rec = this._hfRecorder;
        this._hfRecorder = null;
        if (rec) {
            rec.onstop = () => { this._hfChunks = []; };
            try { rec.stop(); } catch (e) { /* */ }
        }
    }

    _stopHandsFree() { this._hfCleanup(); }

    _hfCleanup() {
        if (this._hfTimer) { clearInterval(this._hfTimer); this._hfTimer = null; }
        if (this._hfRecorder) {
            try { this._hfRecorder.onstop = null; this._hfRecorder.stop(); } catch (e) { /* */ }
            this._hfRecorder = null;
        }
        this._hfChunks = [];
        this._hfCapturing = false;
        if (this._hfStream) {
            try { this._hfStream.getTracks().forEach(t => t.stop()); } catch (e) { /* */ }
            this._hfStream = null;
        }
        if (this._hfAudioCtx) { try { this._hfAudioCtx.close(); } catch (e) { /* */ } this._hfAudioCtx = null; }
        this._hfAnalyser = null;
        if (this.handsFree) this.statusText = '';
        this.handsFree = false;
    }

    // ── port of Flutter IntentDispatcher.dispatch ─────────────────────────────
    _applyOperations(operations, backendSpoken) {
        if (!operations || operations.length === 0) {
            return backendSpoken || 'I did not catch that — say again?';
        }

        const applied = [];
        for (const op of operations) {
            const action = op.action;
            if (action === 'clear_cart') {
                this._emit('clear_cart');
                this._lastTouchedProductId = null;
                applied.push('cleared the cart');
                continue;
            }
            if (action === 'show_summary') return this._buildSummary();
            if (action === 'place_order') {
                // The agent cannot place/save orders. Tell the rep to do it on screen.
                return 'I cannot place the order — please review the cart and tap the Place Order button on screen.';
            }
            if (action === 'unknown') {
                return backendSpoken || 'I did not catch that — say again?';
            }

            // product-specific
            const targetId = this._resolveTarget(op);
            if (targetId === null && op.candidates && op.candidates.length > 0) {
                // ambiguous — surface picker, defer remaining ops to next turn
                this._pendingDisambig = { op, source: 'process' };
                this._showCandidates(op.candidates, op.product_query, op.quantity);
                return this._appliedSentence(applied);
            }
            if (targetId === null) {
                const q = op.product_query ? op.product_query : 'that product';
                return 'Could not find ' + q + '. Try a different name.';
            }
            const desc = this._applyOneOp(op, targetId);
            if (desc) { applied.push(desc); this._lastTouchedProductId = targetId; }
        }
        const sentence = this._appliedSentence(applied);
        return sentence || backendSpoken || 'Done.';
    }

    _resolveTarget(op) {
        const ids = op.resolved_product_ids || [];
        if (ids.length === 1) return ids[0];
        if (op.references_last_touched) return this._lastTouchedProductId;
        return null;
    }

    _applyOneOp(op, productId) {
        const name = this._nameOf(productId);
        switch (op.action) {
            case 'add': {
                let qty = (op.quantity !== null && op.quantity !== undefined)
                    ? Number(op.quantity)
                    : Math.max(1, this._minQtyOf(productId));
                this._emit('add', productId, qty);
                return this._fmtQty(qty) + ' ' + name;
            }
            case 'increment': {
                const delta = Number(op.delta || op.quantity || 1);
                this._emit('increment', productId, null, delta);
                return '+' + this._fmtQty(delta) + ' ' + name;
            }
            case 'decrement': {
                const delta = Number(op.delta || op.quantity || 1);
                if (this._qtyOf(productId) <= 0) return null;
                this._emit('decrement', productId, null, delta);
                return '-' + this._fmtQty(delta) + ' ' + name;
            }
            case 'set_qty': {
                if (op.quantity === null || op.quantity === undefined) return null;
                const qty = Number(op.quantity);
                this._emit('set_qty', productId, qty);
                return name + ' to ' + this._fmtQty(qty);
            }
            case 'remove': {
                if (this._qtyOf(productId) <= 0) return null;
                this._emit('remove', productId);
                return 'removed ' + name;
            }
            default: return null;
        }
    }

    _appliedSentence(descriptions) {
        if (!descriptions.length) return '';
        const body = this._capitalize(descriptions.join(', '));
        const total = this._total();
        if (total <= 0) return body + '.';
        let remain = '';
        if (this._creditFinite()) {
            remain = ' Credit remaining ' + this._money(Number(this.availableCredit) - total) + '.';
        }
        return body + '. Total ' + this._money(total) + '.' + remain;
    }

    _buildSummary() {
        const ids = Object.keys(this._workingCart).filter(id => this._qtyOf(id) > 0);
        if (!ids.length) return 'Cart is empty.';
        // order by serial number so "item N" is consistent
        ids.sort((a, b) => (this._serialOf(a) || 9999) - (this._serialOf(b) || 9999));
        const parts = ids.map(id => {
            const sn = this._serialOf(id);
            const qty = this._qtyOf(id);
            const unit = this._priceOf(id);
            return 'Item ' + (sn !== undefined ? sn : '?') + ': ' + this._fmtQty(qty) + ' '
                + this._nameOf(id) + ', unit price ' + this._money(unit)
                + ', subtotal ' + this._money(qty * unit);
        });
        return parts.join('. ') + '. Total ' + this._money(this._total()) + '.';
    }

    // ── disambiguation picker ──────────────────────────────────────────────────
    _showCandidates(candidates, query, defaultQty) {
        this.candidates = candidates.map(c => {
            const pid = c.product_id || c.productId;
            const min = Math.max(1, this._minQtyOf(pid));
            const want = Number(defaultQty) > 0 ? Number(defaultQty) : 0;
            const dq = Math.max(want, min);     // never pre-fill below the product minimum
            return {
                productId: pid,
                name: c.name,
                unit: c.unit || '',
                label: c.name + (c.unit ? ' (' + c.unit + ')' : '') + ' — ₹' + Math.round(Number(c.price) || 0),
                qty: dq,
                selected: false
            };
        });
        this._disambigQuery = query || '';
        this.panelOpen = true;     // make sure the on-screen picker is visible
        this.statusText = 'Pick one or more, set qty, then tap Done.';
    }

    handleCandidateToggle(event) {
        const id = event.target.dataset.id;
        const on = event.target.checked;
        this.candidates = this.candidates.map(c => c.productId === id ? { ...c, selected: on } : c);
    }
    handleCandidateQty(event) {
        const id = event.target.dataset.id;
        const v = parseFloat(event.target.value);
        this.candidates = this.candidates.map(c =>
            c.productId === id ? { ...c, qty: isNaN(v) ? c.qty : v, selected: true } : c);
    }

    /** Apply every ticked candidate at its quantity — handles "pick one OR more".
     *  Quantities below a product's minimum are raised to the minimum (hard rule). */
    handleAddSelected() {
        const picks = this.candidates.filter(c => c.selected && Number(c.qty) > 0);
        const source = this._pendingDisambig && this._pendingDisambig.source;
        this.candidates = [];
        this._pendingDisambig = null;
        if (!picks.length) { this.statusText = ''; return; }
        const parts = [];
        const bumped = [];
        for (const c of picks) {
            let qty = Number(c.qty);
            const min = this._minQtyOf(c.productId);
            if (min > 0 && qty < min) { qty = min; bumped.push(this._nameOf(c.productId)); }
            this._emit('add', c.productId, qty);
            this._lastTouchedProductId = c.productId;
            this._rtLastTouchedId = c.productId;
            parts.push(this._fmtQty(qty) + ' ' + this._nameOf(c.productId));
        }
        const sentence = this._appliedSentence(parts);
        this.statusText = bumped.length
            ? 'Raised ' + bumped.join(', ') + ' to the minimum quantity.' : '';
        this.agentSaid = sentence;
        if (source === 'realtime') {
            // tell the model so it acknowledges and stays in sync
            this._rtSend({ type: 'conversation.item.create', item: { type: 'message', role: 'user',
                content: [{ type: 'input_text', text: parts.join(', ') + ' now in the cart (total ' + this._money(this._total()) + '). Acknowledge briefly; do not re-add.' }] } });
            this._rtSend({ type: 'response.create' });
        } else if (source === 'sarvam') {
            this._svSyncCart();   // keep the backend's cart authoritative; it won't re-add
        } else {
            this._speak(sentence);
        }
    }

    /** Long tail: hand off to the order form's existing product search. */
    handleSearchAll() {
        const q = this._disambigQuery || '';
        this.candidates = [];
        this._pendingDisambig = null;
        this.statusText = 'Opening product search…';
        this.dispatchEvent(new CustomEvent('voicesearch', { detail: { query: q } }));
    }

    handleCancelPicker() {
        this.candidates = [];
        this._pendingDisambig = null;
        this.statusText = '';
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  REALTIME (WebRTC → OpenAI)  — port of RealtimeClient + RealtimeToolDispatcher
    // ════════════════════════════════════════════════════════════════════════════
    async handleLiveToggle() {
        if (this.rtStarting) return;
        const provider = this.liveProvider;
        if (this.rtActive) {
            if (provider === 'sarvam') this._stopSarvamLive();
            else if (provider === 'gemini') this._stopGeminiLive();
            else this._stopRealtime();
            return;
        }
        if (provider === 'sarvam') await this._startSarvamLive();
        else if (provider === 'gemini') await this._startGeminiLive();
        else await this._startRealtime();
    }

    async _startRealtime() {
        if (!window.RTCPeerConnection || !navigator.mediaDevices
            || !navigator.mediaDevices.getUserMedia) {
            this.statusText = 'Live voice needs microphone access, which this app/browser does not '
                + 'allow here. Open this page in the mobile app with microphone permission enabled.';
            return;
        }
        this._stopSpeaking();
        this.rtStarting = true;
        this.rtStatus = 'Connecting…';
        this.statusText = '';
        this.youSaid = '';
        this.agentSaid = '';
        try {
            const sess = await realtimeSession({
                outletName: this.outletName || null,
                catalogJson: JSON.stringify(this._backendCatalog()),
                cartJson: JSON.stringify(this._backendCart()),
                availableCredit: this._creditFinite() ? Number(this.availableCredit) : null,
                minOrderValue: Number(this.minOrderValue) || 500,
                voice: this.voice || null
            });
            if (!sess || !sess.isSuccess || !sess.clientSecret) {
                throw new Error((sess && sess.errorMessage) || 'Could not start the voice session.');
            }

            try {
                this._rtMicStream = await navigator.mediaDevices.getUserMedia({
                    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
                });
            } catch (micErr) {
                throw new Error(this._micErrorMessage(micErr));
            }
            const pc = new RTCPeerConnection();
            this._rtPc = pc;

            pc.ontrack = (ev) => {
                const el = this.template.querySelector('.voa-rt-audio');
                if (el && ev.streams && ev.streams[0]) {
                    el.srcObject = ev.streams[0];
                    const p = el.play();
                    if (p && p.catch) p.catch(() => { /* autoplay race */ });
                }
            };
            this._rtMicStream.getTracks().forEach(t => pc.addTrack(t, this._rtMicStream));

            this._rtDc = pc.createDataChannel('oai-events');
            this._rtDc.onmessage = (e) => this._onRealtimeEvent(e);
            this._rtDc.onopen = () => {
                try {
                    if (sess.sessionConfig) {
                        const cfg = JSON.parse(sess.sessionConfig);
                        // multilingual + offers + search, appended to the persona
                        cfg.instructions = (cfg.instructions ? cfg.instructions + '\n\n' : '')
                            + this._langDirective() + '\n\n' + this._offersDirective()
                            + '\n\n' + this._searchDirective() + '\n\n' + this._categoriesDirective()
                            + '\n\n' + this._cartInfoDirective()
                            + '\n\nCURRENCY: All prices and totals are in Indian Rupees (INR, the ₹ '
                            + 'symbol). ALWAYS say "rupees" — NEVER "dollars". Read "₹940" as "940 '
                            + 'rupees". This is India; the currency is always rupees.'
                            + '\n\nMIN QUANTITY (HARD RULE): every product has a minimum quantity in '
                            + 'the catalog. NEVER add or set a product below its minimum. If the rep '
                            + 'asks for less, REFUSE and tell them — in their language — that you '
                            + 'cannot add below the minimum, and ask if they want the minimum instead.'
                            + '\n\nPLACING ORDERS (HARD RULE): You CANNOT place, submit, save or '
                            + 'confirm an order — you have NO tool for it. NEVER say an order is '
                            + 'placed, saved or confirmed. When the rep is finished, tell them — in '
                            + 'their language — to review the cart on screen and tap the Place Order '
                            + 'button themselves. You only help build the cart.';
                        // strip any place_order tool (the agent must never save an order) and give
                        // it the search_products tool (full catalog → on-screen grid).
                        cfg.tools = (Array.isArray(cfg.tools) ? cfg.tools : [])
                            .filter(t => t && t.name !== 'place_order');
                        if (!cfg.tools.some(t => t && t.name === 'search_products')) {
                            cfg.tools.push({
                                type: 'function',
                                name: 'search_products',
                                description: 'Search the FULL product catalog and/or filter by '
                                    + 'category, showing matches on the rep\'s screen to tap. Use for '
                                    + 'ambiguous products or when the rep names a category.',
                                parameters: {
                                    type: 'object',
                                    properties: {
                                        query: { type: 'string', description: 'Product words the rep said (English). Optional if filtering by category only.' },
                                        category: { type: 'string', description: 'Optional: the EXACT category value from the category picklist to select the dropdown and filter.' }
                                    },
                                    required: []
                                }
                            });
                        }
                        // caption accuracy: a language HINT (the real win) on the
                        // server-default model — don't override the model (an
                        // unsupported id would make the whole session.update fail).
                        try {
                            cfg.audio = cfg.audio || {};
                            cfg.audio.input = cfg.audio.input || {};
                            const tr = cfg.audio.input.transcription || {};
                            // Ensure the rep's live caption transcription is ON with a
                            // known-valid multilingual model (whisper-1 transcribes any
                            // language). Only set if the server didn't already pick one.
                            if (!tr.model) tr.model = 'whisper-1';
                            // Language hint only for codes the model accepts — an unsupported
                            // code (te/ml/gu) makes the whole session.update fail, so for those
                            // (and Auto) we leave it to AUTO-DETECT, which handles any language.
                            if (this.lang && this.lang !== 'auto' && this._TR_SUPPORTED.includes(this.lang)) {
                                tr.language = this.lang;
                            } else {
                                delete tr.language;   // auto-detect whatever is actually spoken
                            }
                            cfg.audio.input.transcription = tr;
                        } catch (e) { /* keep server default */ }
                        // eslint-disable-next-line no-console
                        console.log('[voa] live session.update — offers on?', this.suggestOffers,
                            '| products w/ offers:', (this._catalog || []).filter(p => p && p.offers).length,
                            '| order offers:', (this._offers || []).length,
                            '| lang:', this.lang);
                        this._rtSend({ type: 'session.update', session: cfg });
                    }
                } catch (e) { /* basic session still works */ }
            };

            pc.onconnectionstatechange = () => {
                const st = pc.connectionState;
                if (st === 'connected') { this.rtStatus = 'Listening…'; }
                else if (st === 'failed' || st === 'disconnected' || st === 'closed') {
                    if (this.rtActive) this._stopRealtime();
                }
            };

            const offer = await pc.createOffer();
            await pc.setLocalDescription(offer);
            const model = encodeURIComponent(sess.model || 'gpt-realtime');
            const resp = await fetch('https://api.openai.com/v1/realtime/calls?model=' + model, {
                method: 'POST',
                body: offer.sdp,
                headers: { Authorization: 'Bearer ' + sess.clientSecret, 'Content-Type': 'application/sdp' }
            });
            if (!resp.ok) throw new Error('Voice handshake failed.');
            const answer = await resp.text();
            await pc.setRemoteDescription({ type: 'answer', sdp: answer });

            this.rtActive = true;
            this.rtStatus = 'Listening…';
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._rtCapTimer = setTimeout(() => {
                if (this.rtActive) {
                    this._stopRealtime();
                    this.statusText = 'Live voice ended after 1 hour — tap Live voice to resume.';
                }
            }, this._RT_MAX_MS);
        } catch (e) {
            this._rtCleanup();
            this.statusText = (e && e.message) ? e.message : 'Could not start live voice.';
        } finally {
            this.rtStarting = false;
        }
    }

    _rtSend(obj) {
        try {
            if (this._rtDc && this._rtDc.readyState === 'open') {
                this._rtDc.send(JSON.stringify(obj));
            }
        } catch (e) { /* channel gone */ }
    }

    // event loop — mirrors RealtimeSessionProvider._onEvent (batches tool
    // outputs, defers response.create until response.done).
    _onRealtimeEvent(evt) {
        let msg;
        try { msg = JSON.parse(evt.data); } catch (e) { return; }
        if (!msg) return;
        const type = msg.type || '';
        switch (type) {
            case 'response.created':
                this._rtResponseActive = true;
                this.agentSaid = '';     // new agent turn
                break;

            // ── live transcript: the rep's speech ──
            case 'input_audio_buffer.speech_started':
                this.youSaid = '';       // new rep utterance
                break;
            case 'conversation.item.input_audio_transcription.delta':
                this.youSaid = (this.youSaid || '') + (msg.delta || '');
                break;
            case 'conversation.item.input_audio_transcription.completed':
                this.youSaid = (msg.transcript || this.youSaid || '').trim();
                break;

            // ── live transcript: the agent's speech ──
            case 'response.audio_transcript.delta':
                this.agentSaid = (this.agentSaid || '') + (msg.delta || '');
                break;
            case 'response.audio_transcript.done':
                this.agentSaid = (msg.transcript || this.agentSaid || '').trim();
                break;
            case 'response.output_item.added': {
                const item = msg.item;
                if (item && item.type === 'function_call' && item.id) {
                    this._rtPendingCalls[item.id] = {
                        callId: item.call_id || '', name: item.name || '', argsBuffer: ''
                    };
                }
                break;
            }
            case 'response.function_call_arguments.delta': {
                const p = this._rtPendingCalls[msg.item_id];
                if (p) p.argsBuffer += (msg.delta || '');
                break;
            }
            case 'response.function_call_arguments.done': {
                const p = this._rtPendingCalls[msg.item_id];
                delete this._rtPendingCalls[msg.item_id];
                const rawArgs = msg.arguments || (p && p.argsBuffer) || '{}';
                const callId = msg.call_id || (p && p.callId) || '';
                const name = msg.name || (p && p.name) || '';
                if (!callId || !name) break;
                this._executeToolCall(callId, name, rawArgs);
                break;
            }
            case 'response.done':
                this._rtResponseActive = false;
                if (this._rtToolOutputPending) {
                    this._rtToolOutputPending = false;
                    this._rtSend({ type: 'response.create' });
                }
                break;
            case 'error':
                // surface but don't kill — fall back to push-to-talk
                this.rtStatus = (msg.error && msg.error.message) || 'Live voice error';
                break;
            default: break;
        }
    }

    _executeToolCall(callId, name, rawArgs) {
        let args = {};
        try { const parsed = JSON.parse(rawArgs); if (parsed && typeof parsed === 'object') args = parsed; }
        catch (e) { /* dispatcher decides */ }
        const result = this._dispatchTool(callId, name, args);
        // post output now; defer response.create if a response is active
        this._rtSend({
            type: 'conversation.item.create',
            item: { type: 'function_call_output', call_id: callId, output: result }
        });
        if (this._rtResponseActive) this._rtToolOutputPending = true;
        else this._rtSend({ type: 'response.create' });
    }

    // port of RealtimeToolDispatcher.dispatch
    _dispatchTool(callId, name, args) {
        switch (name) {
            case 'add_to_cart': return this._rtAdd(args);
            case 'change_quantity': return this._rtChange(args);
            case 'remove_from_cart': return this._rtRemove(args);
            case 'clear_cart': return this._rtClear();
            case 'show_summary': return this._buildSummary();
            case 'place_order': return 'You CANNOT place or save orders. Tell the rep — in their '
                + 'language — to review the cart on screen and tap the Place Order button themselves.';
            case 'search_products': return this._rtSearch(args);
            default: return 'Unknown tool "' + name + '". Ignored.';
        }
    }

    _searchDirective() {
        return 'SEARCH: You have a search_products tool that searches the FULL catalog and shows '
            + 'matches on the rep\'s screen to tap. The app already auto-searches when an add matches '
            + 'more than one product, so you usually just call add_to_cart with the English product '
            + 'name. Call search_products yourself when the rep asks to browse or names a category.';
    }

    /** Tell the agent the REAL category picklist + that names are English. */
    _categoriesDirective() {
        let s = 'PRODUCT NAMES: the rep always says product names in ENGLISH — match those against '
            + 'the catalog directly.';
        const cats = (this._categories || []).filter(c => c && c.value);
        if (cats.length) {
            s += ' CATEGORY PICKLIST: when the rep asks for a category (e.g. "show me the oils"), call '
                + 'search_products and set "category" to the EXACT value from this list (do not invent '
                + 'one). That selects the category dropdown and filters the grid. Categories '
                + '(label = value): ' + cats.slice(0, 40).map(c => c.label + ' = ' + c.value).join('; ') + '.';
        }
        return s;
    }

    /** Teach the agent about cart serial numbers + per-item subtotals. */
    _cartInfoDirective() {
        return 'CART ITEMS, SERIAL NUMBERS & SUBTOTALS: every item in the cart has a SERIAL NUMBER — '
            + 'its position in the list (1, 2, 3 …). When the rep refers to an item by its number — '
            + '"what is item 3", "tell me item 2", "item 4 details", "subtotal of item 1", "remove item 3", '
            + '"change item 2 to 10" — FIRST call the show_summary tool. It returns each line as '
            + '"Item N: <quantity> <name>, unit price <X> rupees, subtotal <X> rupees" plus the order total. '
            + 'Use it to map the serial number to that exact line, then answer with that item\'s name, '
            + 'quantity, unit price and subtotal — and if the rep asked to change/remove it, act on it using '
            + 'the product NAME (the cart tools take names, not numbers). Each item\'s SUBTOTAL = its '
            + 'quantity × unit price; ALWAYS read the subtotal and total from show_summary — never calculate '
            + 'them yourself. (Keep numbers and product names in English when you speak.)';
    }

    _rtSearch(args) {
        const q = (args.query || '').toString().trim();
        const cat = (args.category || '').toString().trim();
        if (!q && !cat) return 'No search term or category — ask the rep what to look for.';
        this.dispatchEvent(new CustomEvent('voicesearch', { detail: { query: q, category: cat } }));
        const what = cat ? 'that category' : '"' + q + '"';
        return 'I searched ' + what + ' and the matching products are now on the rep\'s screen. '
            + 'Tell the rep to tap the one they want. Do not guess which one and do not add anything yet.';
    }

    _rtAdd(args) {
        const query = (args.product_query || '').toString().trim();
        const qty = this._asNum(args.quantity);
        if (qty === null || qty <= 0) return 'Quantity missing or invalid; ask the rep again.';
        const match = this._resolveProduct(query);
        // 2+ near-identical matches (e.g. same product, different size) → show them
        // ON SCREEN as a tick-list so the rep can pick one OR several, set the
        // quantity on each, and tap Done. The agent never guesses between them.
        if (match && match.ambiguous) {
            this._pendingDisambig = { source: 'realtime', qty };
            this._showCandidates(match.candidates, query, qty);
            return '"' + query + '" matches more than one product, so I put the options on the rep\'s '
                + 'screen. Ask the rep to tick the one(s) they want, set the quantity, and tap Done. '
                + 'Do NOT guess and do NOT add anything yourself.';
        }
        // nothing matched the loaded catalog → search the FULL catalog on screen.
        if (!match) {
            this._clearPicker();
            this.dispatchEvent(new CustomEvent('voicesearch', { detail: { query } }));
            return '"' + query + '" needs a search, so I searched it — the matches are now on the rep\'s '
                + 'screen. Ask the rep to tap the one they want (quantity ' + this._fmtQty(qty)
                + '). Do NOT guess and do NOT add anything yourself.';
        }
        // HARD min-quantity block (deterministic, every language)
        const min = this._minQtyOf(match.id);
        if (min > 0 && qty < min) {
            return 'DO NOT add it. Tell the rep IN THEIR LANGUAGE: you cannot add ' + match.name
                + ' below its minimum quantity of ' + min + '. Ask if they want ' + min + ' instead. '
                + 'Do not add any quantity below ' + min + '.';
        }
        this._clearPicker();
        this._emit('add', match.id, qty);
        this._rtLastTouchedId = match.id;
        this._lastTouchedProductId = match.id;
        return 'Added ' + this._fmtQty(qty) + ' ' + match.name + '. Cart total ' + this._money(this._total()) + '.';
    }

    _rtChange(args) {
        const query = (args.product_query || '').toString().trim();
        const qty = this._asNum(args.new_quantity);
        if (qty === null || qty <= 0) return 'new_quantity missing or invalid.';
        const id = query === '' ? this._rtLastTouchedId : this._resolveSingle(query);
        if (!id) return 'Could not resolve "' + query + '"; ask the rep which product.';
        // HARD min-quantity block (deterministic, every language)
        const min = this._minQtyOf(id);
        if (min > 0 && qty < min) {
            return 'DO NOT change it. Tell the rep IN THEIR LANGUAGE: ' + this._nameOf(id)
                + ' cannot go below its minimum quantity of ' + min + '. Keep it at least ' + min + '.';
        }
        this._emit('set_qty', id, qty);
        this._rtLastTouchedId = id;
        this._lastTouchedProductId = id;
        return 'Set ' + this._nameOf(id) + ' to ' + this._fmtQty(qty)
            + '. Cart total ' + this._money(this._total()) + '.';
    }

    _rtRemove(args) {
        const query = (args.product_query || '').toString().trim();
        const id = query === '' ? this._rtLastTouchedId : this._resolveSingle(query);
        if (!id) return 'No product matched.';
        if (this._qtyOf(id) <= 0) return this._nameOf(id) + ' is not in the cart.';
        this._emit('remove', id);
        this._rtLastTouchedId = null;
        return 'Removed ' + this._nameOf(id) + '.';
    }

    _rtClear() {
        const count = Object.keys(this._workingCart).filter(id => this._qtyOf(id) > 0).length;
        this._emit('clear_cart');
        this._rtLastTouchedId = null;
        return 'Cleared ' + count + ' line' + (count === 1 ? '' : 's') + ' from the cart.';
    }

    _applyRealtimePick(pending, productId) {
        // rep tapped a candidate for an ambiguous realtime add
        const qty = pending.qty || Math.max(1, this._minQtyOf(productId));
        this._emit('add', productId, qty);
        this._rtLastTouchedId = productId;
        this._lastTouchedProductId = productId;
        const msg = this._fmtQty(qty) + ' ' + this._nameOf(productId) + ' now in the cart (total ' + this._money(this._total()) + '). Acknowledge briefly — do NOT add these again.';
        // tell the model so it speaks an acknowledgement and stays in sync
        this._rtSend({
            type: 'conversation.item.create',
            item: { type: 'message', role: 'user', content: [{ type: 'input_text', text: msg }] }
        });
        this._rtSend({ type: 'response.create' });
    }

    _clearPicker() { this.candidates = []; if (this._pendingDisambig && this._pendingDisambig.source === 'realtime') this._pendingDisambig = null; }

    _stopRealtime() { this._rtCleanup(); }

    _rtCleanup() {
        if (this._rtCapTimer) { clearTimeout(this._rtCapTimer); this._rtCapTimer = null; }
        if (this._manualEditTimer) { clearTimeout(this._manualEditTimer); this._manualEditTimer = null; }
        try { if (this._rtDc) this._rtDc.close(); } catch (e) { /* */ }
        this._rtDc = null;
        try {
            if (this._rtMicStream) this._rtMicStream.getTracks().forEach(t => t.stop());
        } catch (e) { /* */ }
        this._rtMicStream = null;
        try { if (this._rtPc) this._rtPc.close(); } catch (e) { /* */ }
        this._rtPc = null;
        this._rtPendingCalls = {};
        this._rtResponseActive = false;
        this._rtToolOutputPending = false;
        this.rtActive = false;
        this.rtStarting = false;
        this.rtStatus = '';
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  SARVAM LIVE VOICE (experimental) — WebSocket to our backend orchestrator.
    //  Sarvam has no single realtime endpoint, so the backend bridges
    //  STT → intent → TTS. Here we stream the mic up, apply the cart ops it
    //  returns, and play the spoken reply it streams back. Reuses rtActive/
    //  rtStarting/rtStatus/youSaid/agentSaid so the existing UI just works.
    // ════════════════════════════════════════════════════════════════════════════
    async _startSarvamLive() {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia
            || !window.WebSocket) {
            this.statusText = 'Live voice needs microphone access, which this app/browser '
                + 'does not allow here.';
            return;
        }
        this._stopSpeaking();
        this.rtStarting = true;
        this.rtStatus = 'Connecting…';
        this.statusText = '';
        this.youSaid = '';
        this.agentSaid = '';
        try {
            const tok = await sarvamLiveToken();
            if (!tok || !tok.isSuccess || !tok.token || !tok.wsUrl) {
                throw new Error((tok && tok.errorMessage) || 'Could not start live voice.');
            }
            try {
                this._svMicStream = await navigator.mediaDevices.getUserMedia({
                    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
                });
            } catch (micErr) {
                throw new Error(this._micErrorMessage(micErr));
            }
            const url = tok.wsUrl + '?token=' + encodeURIComponent(tok.token);
            const ws = new WebSocket(url);
            this._svWs = ws;
            ws.onopen = () => this._svOnOpen();
            ws.onmessage = (e) => this._svOnMessage(e);
            ws.onerror = () => { this.rtStatus = 'Live voice error'; };
            ws.onclose = () => { if (this.rtActive || this.rtStarting) this._stopSarvamLive(); };
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._svCapTimer = setTimeout(() => {
                if (this.rtActive) {
                    this._stopSarvamLive();
                    this.statusText = 'Live voice ended after 1 hour — tap Live voice to resume.';
                }
            }, this._RT_MAX_MS);
        } catch (e) {
            this._svCleanup();
            this.statusText = (e && e.message) ? e.message : 'Could not start live voice.';
        } finally {
            this.rtStarting = false;
        }
    }

    _svOnOpen() {
        this.rtActive = true;
        this.rtStatus = 'Listening…';
        this._svSend({
            type: 'init',
            catalog: this._backendCatalog(),
            cart: this._backendCart(),
            language: this.lang === 'auto' ? 'en' : this.lang,
            min_order_value: Number(this.minOrderValue) || 500,
            available_credit: this._creditFinite() ? Number(this.availableCredit) : null,
            outlet: this.outletName || null
        });
        this._svStartCapture();
    }

    _svStartCapture() {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        if (!Ctx || !this._svMicStream) return;
        const ctx = new Ctx();
        this._svCapCtx = ctx;
        const source = ctx.createMediaStreamSource(this._svMicStream);
        this._svSource = source;
        const proc = ctx.createScriptProcessor(4096, 1, 1);
        this._svProcessor = proc;
        const srcRate = ctx.sampleRate;
        proc.onaudioprocess = (ev) => {
            if (!this.rtActive || !this._svWs || this._svWs.readyState !== 1) return;
            const input = ev.inputBuffer.getChannelData(0);
            const pcm16 = this._downsampleTo16k(input, srcRate);
            if (pcm16 && pcm16.length) {
                this._svSend({ type: 'audio',
                    data: this._b64FromBytes(new Uint8Array(pcm16.buffer)) });
            }
        };
        source.connect(proc);
        // route through a muted gain to destination so onaudioprocess fires
        // without the rep hearing their own mic.
        const sink = ctx.createGain();
        sink.gain.value = 0;
        proc.connect(sink);
        sink.connect(ctx.destination);
    }

    _svOnMessage(e) {
        let msg;
        try { msg = JSON.parse(e.data); } catch (err) { return; }
        if (!msg) return;
        switch (msg.type) {
            case 'ready': this.rtStatus = 'Listening…'; break;
            case 'speech_started': this.youSaid = ''; this._svStopPlayback(); break;
            case 'barge_in': this._svStopPlayback(); break;
            case 'transcript': this.youSaid = msg.text || ''; break;
            case 'reply': this.agentSaid = msg.text || ''; break;
            case 'ops': this._svApplyOps(msg.operations || []); break;
            case 'audio': this._svQueueAudio(msg.data); break;
            case 'audio_done': this._svPlayQueued(); break;
            case 'error': this.rtStatus = msg.error || 'Live voice error'; break;
            default: break;
        }
    }

    _svApplyOps(operations) {
        for (const op of operations) {
            const action = op.action;
            if (action === 'clear_cart') {
                this._emit('clear_cart'); this._lastTouchedProductId = null; continue;
            }
            if (action === 'show_summary' || action === 'place_order' || action === 'unknown') {
                continue;   // the backend's spoken reply already covers these
            }
            let ids = op.resolved_product_ids || [];
            // "make it 10" / "remove it" / "increase it" — no product named, the
            // intent flags references_last_touched; apply to the last item.
            if (!ids.length && op.references_last_touched && this._lastTouchedProductId) {
                ids = [this._lastTouchedProductId];
            }
            if (ids.length === 1) {
                this._svApplyOneOp(op, ids[0]);
            } else if (op.candidates && op.candidates.length > 0) {
                // ambiguous → show the on-screen picker (multi-select + qty + Done)
                this._pendingDisambig = { source: 'sarvam', qty: op.quantity };
                this._showCandidates(op.candidates, op.product_query, op.quantity);
            }
            // 0 matches → ignore; the spoken reply explains it
        }
        this._svSyncCart();    // keep the backend's cart authoritative
    }

    _svApplyOneOp(op, productId) {
        const min = this._minQtyOf(productId);
        switch (op.action) {
            case 'add': {
                let qty = (op.quantity !== null && op.quantity !== undefined)
                    ? Number(op.quantity) : Math.max(1, min);
                if (min > 0 && qty < min) qty = min;     // hard min-qty rule
                this._emit('add', productId, qty); break;
            }
            case 'set_qty': {
                if (op.quantity === null || op.quantity === undefined) return;
                let qty = Number(op.quantity);
                if (min > 0 && qty < min) qty = min;
                this._emit('set_qty', productId, qty); break;
            }
            case 'increment':
                this._emit('increment', productId, null, Number(op.delta || op.quantity || 1));
                break;
            case 'decrement':
                this._emit('decrement', productId, null, Number(op.delta || op.quantity || 1));
                break;
            case 'remove':
                if (this._qtyOf(productId) <= 0) return;
                this._emit('remove', productId); break;
            default: return;
        }
        this._lastTouchedProductId = productId;
    }

    _svSyncCart() {
        if (this._svWs && this._svWs.readyState === 1) {
            this._svSend({ type: 'cart', cart: this._backendCart() });
        }
    }

    _svQueueAudio(b64) {
        if (!b64) return;
        try {
            const bin = atob(b64);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            this._svAudioChunks.push(bytes);
        } catch (e) { /* skip bad chunk */ }
    }

    async _svPlayQueued() {
        const chunks = this._svAudioChunks;
        this._svAudioChunks = [];
        if (!chunks.length) return;
        let total = 0;
        chunks.forEach(c => { total += c.length; });
        const all = new Uint8Array(total);
        let off = 0;
        chunks.forEach(c => { all.set(c, off); off += c.length; });
        try {
            const Ctx = window.AudioContext || window.webkitAudioContext;
            if (!Ctx) return;
            if (!this._svPlayCtx) this._svPlayCtx = new Ctx();
            const ctx = this._svPlayCtx;
            if (ctx.state === 'suspended') { try { await ctx.resume(); } catch (e) { /* */ } }
            const buf = await new Promise((resolve, reject) => {
                const p = ctx.decodeAudioData(all.buffer, resolve, reject);
                if (p && typeof p.then === 'function') p.then(resolve, reject);
            });
            this._svStopPlayback();
            const src = ctx.createBufferSource();
            src.buffer = buf;
            src.connect(ctx.destination);
            src.onended = () => { if (this._svPlaySource === src) this._svPlaySource = null; };
            this._svPlaySource = src;
            src.start(0);
        } catch (e) { /* decode failed — cart still updated, just no audio */ }
    }

    _svStopPlayback() {
        if (this._svPlaySource) {
            try { this._svPlaySource.stop(0); } catch (e) { /* */ }
            this._svPlaySource = null;
        }
        this._svAudioChunks = [];
    }

    _svSend(obj) {
        try {
            if (this._svWs && this._svWs.readyState === 1) this._svWs.send(JSON.stringify(obj));
        } catch (e) { /* socket gone */ }
    }

    _stopSarvamLive() { this._svCleanup(); }

    _svCleanup() {
        if (this._svCapTimer) { clearTimeout(this._svCapTimer); this._svCapTimer = null; }
        try { if (this._svWs && this._svWs.readyState === 1) this._svSend({ type: 'stop' }); } catch (e) { /* */ }
        try { if (this._svWs) this._svWs.close(); } catch (e) { /* */ }
        this._svWs = null;
        this._svStopPlayback();
        if (this._svProcessor) {
            try { this._svProcessor.disconnect(); } catch (e) { /* */ }
            this._svProcessor.onaudioprocess = null;
            this._svProcessor = null;
        }
        if (this._svSource) { try { this._svSource.disconnect(); } catch (e) { /* */ } this._svSource = null; }
        if (this._svMicStream) {
            try { this._svMicStream.getTracks().forEach(t => t.stop()); } catch (e) { /* */ }
            this._svMicStream = null;
        }
        if (this._svCapCtx) { try { this._svCapCtx.close(); } catch (e) { /* */ } this._svCapCtx = null; }
        this.rtActive = false;
        this.rtStarting = false;
        this.rtStatus = '';
    }

    /** Downsample Float32 mic samples (at srcRate) to 16 kHz Int16 PCM. */
    _downsampleTo16k(input, srcRate) {
        const target = 16000;
        if (srcRate <= target) return this._floatToInt16(input);
        const ratio = srcRate / target;
        const newLen = Math.floor(input.length / ratio);
        const out = new Int16Array(newLen);
        let pos = 0;
        for (let i = 0; i < newLen; i++) {
            let s = input[Math.floor(pos)] || 0;
            s = Math.max(-1, Math.min(1, s));
            out[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
            pos += ratio;
        }
        return out;
    }
    _floatToInt16(input) {
        const out = new Int16Array(input.length);
        for (let i = 0; i < input.length; i++) {
            let s = Math.max(-1, Math.min(1, input[i]));
            out[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
        }
        return out;
    }
    _b64FromBytes(bytes) {
        let bin = '';
        const chunk = 0x8000;
        for (let i = 0; i < bytes.length; i += chunk) {
            bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
        }
        return btoa(bin);
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  GEMINI LIVE (experimental) — WebSocket to our backend, which bridges to
    //  Gemini Live (native audio: reasons + speaks + calls the cart tools).
    //  Reuses the Sarvam audio capture + the realtime tool dispatcher; the one new
    //  piece is raw-PCM-24k streaming playback (Gemini sends raw PCM, not mp3).
    // ════════════════════════════════════════════════════════════════════════════
    _gmLastRole = '';

    async _startGeminiLive() {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia
            || !window.WebSocket) {
            this.statusText = 'Live voice needs microphone access, which this app/browser '
                + 'does not allow here.';
            return;
        }
        this._stopSpeaking();
        this.rtStarting = true;
        this.rtStatus = 'Connecting…';
        this.statusText = '';
        this.youSaid = '';
        this.agentSaid = '';
        try {
            const tok = await geminiLiveToken();
            if (!tok || !tok.isSuccess || !tok.token || !tok.wsUrl) {
                throw new Error((tok && tok.errorMessage) || 'Could not start live voice.');
            }
            try {
                this._gmMicStream = await navigator.mediaDevices.getUserMedia({
                    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
                });
            } catch (micErr) {
                throw new Error(this._micErrorMessage(micErr));
            }
            const url = tok.wsUrl + '?token=' + encodeURIComponent(tok.token);
            const ws = new WebSocket(url);
            this._gmWs = ws;
            ws.onopen = () => this._gmOnOpen();
            ws.onmessage = (e) => this._gmOnMessage(e);
            ws.onerror = () => { this.rtStatus = 'Live voice error'; };
            ws.onclose = () => { if (this.rtActive || this.rtStarting) this._stopGeminiLive(); };
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._gmCapTimer = setTimeout(() => {
                if (this.rtActive) {
                    this._stopGeminiLive();
                    this.statusText = 'Live voice ended after the time limit — tap Live voice to resume.';
                }
            }, this._RT_MAX_MS);
        } catch (e) {
            this._gmCleanup();
            this.statusText = (e && e.message) ? e.message : 'Could not start live voice.';
        } finally {
            this.rtStarting = false;
        }
    }

    _gmOnOpen() {
        this.rtActive = true;
        this.rtStatus = 'Listening…';
        this._gmSend({
            type: 'init',
            catalog: this._backendCatalog(),
            cart: this._backendCart(),
            system_instruction: this._buildSystemInstruction(),
            language: this.lang === 'auto' ? 'en' : this.lang,
            voice: 'Kore'
        });
        this._gmStartCapture();
    }

    _gmStartCapture() {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        if (!Ctx || !this._gmMicStream) return;
        const ctx = new Ctx();
        this._gmCapCtx = ctx;
        const source = ctx.createMediaStreamSource(this._gmMicStream);
        this._gmSource = source;
        const proc = ctx.createScriptProcessor(4096, 1, 1);
        this._gmProcessor = proc;
        const srcRate = ctx.sampleRate;
        proc.onaudioprocess = (ev) => {
            if (!this.rtActive || !this._gmWs || this._gmWs.readyState !== 1) return;
            const input = ev.inputBuffer.getChannelData(0);
            const pcm16 = this._downsampleTo16k(input, srcRate);
            if (pcm16 && pcm16.length) {
                this._gmSend({ type: 'audio',
                    data: this._b64FromBytes(new Uint8Array(pcm16.buffer)) });
            }
        };
        source.connect(proc);
        const sink = ctx.createGain();
        sink.gain.value = 0;
        proc.connect(sink);
        sink.connect(ctx.destination);
    }

    _gmOnMessage(e) {
        let msg;
        try { msg = JSON.parse(e.data); } catch (err) { return; }
        if (!msg) return;
        switch (msg.type) {
            case 'ready': this.rtStatus = 'Listening…'; break;
            case 'audio': this._gmQueuePcm(msg.data); break;
            case 'tool_call': this._gmDispatchToolCall(msg.id, msg.name, msg.args || {}); break;
            case 'transcript': {
                const role = msg.role;
                if (role !== this._gmLastRole) {
                    if (role === 'user') this.youSaid = ''; else this.agentSaid = '';
                }
                this._gmLastRole = role;
                if (role === 'agent') this.agentSaid = (this.agentSaid || '') + (msg.text || '');
                else this.youSaid = (this.youSaid || '') + (msg.text || '');
                break;
            }
            case 'barge_in': this._gmStopPlayback(); break;
            case 'turn_complete': break;
            case 'error': this.rtStatus = msg.error || 'Live voice error'; break;
            default: break;
        }
    }

    _gmDispatchToolCall(id, name, args) {
        let result;
        try { result = this._dispatchTool(id, name, args || {}); }
        catch (e) { result = 'error'; }
        this._gmSend({ type: 'tool_result', id, name, result });
    }

    /** Decode + schedule a raw PCM16 24kHz chunk for gap-free playback. */
    _gmQueuePcm(b64) {
        if (!b64) return;
        try {
            const Ctx = window.AudioContext || window.webkitAudioContext;
            if (!Ctx) return;
            if (!this._gmPlayCtx) { this._gmPlayCtx = new Ctx(); this._gmPlayTime = 0; }
            const ctx = this._gmPlayCtx;
            if (ctx.state === 'suspended') { try { ctx.resume(); } catch (e) { /* */ } }
            const bin = atob(b64);
            const len = bin.length >> 1;       // 16-bit samples
            const f32 = new Float32Array(len);
            for (let i = 0; i < len; i++) {
                const lo = bin.charCodeAt(i * 2);
                const hi = bin.charCodeAt(i * 2 + 1);
                let s = (hi << 8) | lo;
                if (s >= 0x8000) s -= 0x10000;
                f32[i] = s / 0x8000;
            }
            const buf = ctx.createBuffer(1, len, 24000);
            buf.getChannelData(0).set(f32);
            const src = ctx.createBufferSource();
            src.buffer = buf;
            src.connect(ctx.destination);
            const start = Math.max(ctx.currentTime, this._gmPlayTime);
            src.start(start);
            this._gmPlayTime = start + buf.duration;
            this._gmSources.push(src);
            src.onended = () => {
                const i = this._gmSources.indexOf(src);
                if (i >= 0) this._gmSources.splice(i, 1);
            };
        } catch (e) { /* skip bad chunk */ }
    }

    _gmStopPlayback() {
        (this._gmSources || []).forEach(s => { try { s.stop(0); } catch (e) { /* */ } });
        this._gmSources = [];
        if (this._gmPlayCtx) this._gmPlayTime = this._gmPlayCtx.currentTime;
    }

    _gmSend(obj) {
        try {
            if (this._gmWs && this._gmWs.readyState === 1) this._gmWs.send(JSON.stringify(obj));
        } catch (e) { /* socket gone */ }
    }

    _stopGeminiLive() { this._gmCleanup(); }

    _gmCleanup() {
        if (this._gmCapTimer) { clearTimeout(this._gmCapTimer); this._gmCapTimer = null; }
        try { if (this._gmWs && this._gmWs.readyState === 1) this._gmSend({ type: 'stop' }); } catch (e) { /* */ }
        try { if (this._gmWs) this._gmWs.close(); } catch (e) { /* */ }
        this._gmWs = null;
        this._gmStopPlayback();
        if (this._gmProcessor) {
            try { this._gmProcessor.disconnect(); } catch (e) { /* */ }
            this._gmProcessor.onaudioprocess = null;
            this._gmProcessor = null;
        }
        if (this._gmSource) { try { this._gmSource.disconnect(); } catch (e) { /* */ } this._gmSource = null; }
        if (this._gmMicStream) {
            try { this._gmMicStream.getTracks().forEach(t => t.stop()); } catch (e) { /* */ }
            this._gmMicStream = null;
        }
        if (this._gmCapCtx) { try { this._gmCapCtx.close(); } catch (e) { /* */ } this._gmCapCtx = null; }
        if (this._gmPlayCtx) { try { this._gmPlayCtx.close(); } catch (e) { /* */ } this._gmPlayCtx = null; }
        this._gmSources = [];
        this.rtActive = false;
        this.rtStarting = false;
        this.rtStatus = '';
    }

    /** Build the full Gemini system instruction (persona + catalog + all the same
     *  rules the OpenAI path injects). Gemini has no backend base prompt, so we
     *  assemble everything here. */
    _buildSystemInstruction() {
        const outlet = this.outletName || 'this outlet';
        const cat = (this._catalog || []).slice(0, 80).map(p =>
            '  - ' + p.name + (p.category ? ' [' + p.category + ']' : '') + ': '
            + this._money(p.price) + (p.minOrderQty ? ', min ' + p.minOrderQty : '')
        ).join('\n');
        const persona = 'You are a fast, friendly VOICE order-taking assistant helping a field '
            + 'sales rep take an order at ' + outlet + '. Build the order ONLY by calling the tools '
            + '(add_to_cart, change_quantity, remove_from_cart, clear_cart, show_summary, '
            + 'search_products). After each tool result, confirm briefly in ONE short line. Never '
            + 'read long lists aloud.\n\nPRODUCT CATALOG (match the rep\'s words to these EXACT '
            + 'names; pass the English name to tools):\n' + (cat || '  (none loaded)') + '\n\n';
        const placing = 'PLACING ORDERS (HARD RULE): you CANNOT place, save or submit the order — '
            + 'you have no tool for it. Never say it is placed. When the rep is done, tell them to '
            + 'review the cart and tap the Place Order button on screen.\n\n';
        const currency = 'CURRENCY: all prices are Indian Rupees; always say "rupees", never '
            + '"dollars".\n\n';
        const minqty = 'MIN QUANTITY (HARD RULE): never add or set a product below its catalog '
            + 'minimum; if asked for less, refuse in the rep\'s language and offer the minimum.\n\n';
        return persona + placing + currency + minqty
            + this._langDirective() + '\n\n' + this._offersDirective() + '\n\n'
            + this._searchDirective() + '\n\n' + this._categoriesDirective() + '\n\n'
            + this._cartInfoDirective();
    }

    // ── fuzzy product resolution (port of matcher.tokenSetRatio path) ──────────
    _resolveSingle(query) {
        const r = this._resolveProduct(query);
        if (!r || r.ambiguous) return null;
        return r.id;
    }

    _resolveProduct(query) {
        const q = (query || '').trim();
        if (!q) return null;
        const FLOOR = 65, GAP = 10;
        const scored = [];
        for (const p of this._catalog) {
            if (!p || !p.id || !p.name) continue;
            const corpus = [p.name, p.brand || '', p.category || ''].join(' ');
            const score = this._tokenSetRatio(q, corpus);
            if (score >= FLOOR) scored.push({ id: p.id, name: p.name, price: Number(p.price) || 0, unit: p.unit || '', score });
        }
        if (!scored.length) return null;
        scored.sort((a, b) => b.score - a.score);
        const top = scored[0];
        if (scored.length === 1 || scored[1].score + GAP <= top.score) {
            return { ambiguous: false, id: top.id, name: top.name };
        }
        return {
            ambiguous: true,
            candidates: scored.slice(0, 4).map(c => ({ product_id: c.id, name: c.name, price: c.price, unit: c.unit }))
        };
    }

    _tokenSetRatio(query, choice) {
        const tok = (s) => Array.from(new Set((s.toLowerCase().match(/[\w]+/g) || []))).sort();
        const t1 = tok(query), t2 = tok(choice);
        const inter = t1.filter(x => t2.includes(x));
        const diff1 = t1.filter(x => !t2.includes(x));
        const diff2 = t2.filter(x => !t1.includes(x));
        const interStr = inter.join(' ');
        const s1 = (interStr + ' ' + diff1.join(' ')).trim();
        const s2 = (interStr + ' ' + diff2.join(' ')).trim();
        return Math.max(
            this._ratio(interStr, s1),
            this._ratio(interStr, s2),
            this._ratio(s1, s2)
        );
    }

    _ratio(a, b) {
        if (a === b) return a.length === 0 ? 0 : 100;
        if (!a.length || !b.length) return 0;
        const d = this._levenshtein(a, b);
        const maxLen = Math.max(a.length, b.length);
        return Math.round((1 - d / maxLen) * 100);
    }

    _levenshtein(a, b) {
        const m = a.length, n = b.length;
        if (!m) return n; if (!n) return m;
        let prev = new Array(n + 1);
        for (let j = 0; j <= n; j++) prev[j] = j;
        for (let i = 1; i <= m; i++) {
            let cur = [i];
            for (let j = 1; j <= n; j++) {
                const cost = a[i - 1] === b[j - 1] ? 0 : 1;
                cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
            }
            prev = cur;
        }
        return prev[n];
    }

    // ════════════════════════════════════════════════════════════════════════════
    //  TTS  — browser SpeechSynthesis (matches Flutter's on-device flutter_tts),
    //  backend /speak as fallback.
    // ════════════════════════════════════════════════════════════════════════════
    async _speak(text) {
        if (!text) return;
        this._stopSpeaking();
        // Primary: on-device speech synthesis (no cost, no latency).
        if (window.speechSynthesis && window.SpeechSynthesisUtterance) {
            try {
                const u = new SpeechSynthesisUtterance(text);
                // Push-to-talk / hands-free replies are generated in English
                // (prices, quantities, product names all English), so speak with
                // an English voice for clean pronunciation of numbers + names.
                u.lang = 'en-IN';
                u.rate = 1.0;
                u.onend = () => { this.isSpeaking = false; };
                this.isSpeaking = true;
                window.speechSynthesis.speak(u);
                return;
            } catch (e) { /* fall through to backend */ }
        }
        await this._speakBackend(text);
    }

    async _speakBackend(text) {
        try {
            const res = await speak({ text });
            if (!res || !res.isSuccess || !res.audioBase64) return;
            const Ctx = window.AudioContext || window.webkitAudioContext;
            if (!Ctx) return;
            if (!this._audioCtx) this._audioCtx = new Ctx();
            const ctx = this._audioCtx;
            if (ctx.state === 'suspended') { try { await ctx.resume(); } catch (e) { /* */ } }
            const bin = atob(res.audioBase64);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            const buf = await new Promise((resolve, reject) => {
                const p = ctx.decodeAudioData(bytes.buffer, resolve, reject);
                if (p && typeof p.then === 'function') p.then(resolve, reject);
            });
            const src = ctx.createBufferSource();
            src.buffer = buf;
            src.connect(ctx.destination);
            src.onended = () => { this.isSpeaking = false; this._ttsSource = null; };
            this._ttsSource = src;
            this.isSpeaking = true;
            src.start(0);
        } catch (e) { this.isSpeaking = false; this._ttsSource = null; }
    }

    _stopSpeaking() {
        try { if (window.speechSynthesis) window.speechSynthesis.cancel(); } catch (e) { /* */ }
        if (this._ttsSource) { try { this._ttsSource.stop(0); } catch (e) { /* */ } this._ttsSource = null; }
        this.isSpeaking = false;
    }

    // ── small helpers ───────────────────────────────────────────────────────────
    _backendCatalog() {
        // shape the backend (CatalogProduct) expects
        return this._catalog.map(p => ({
            id: p.id,
            name: p.name,
            brand: p.brand || null,
            category: p.category || null,
            price: Number(p.price) || 0,
            unit: p.unit || null,
            min_order_qty: Number(p.minOrderQty) || 0
        }));
    }
    _backendCart() {
        return Object.keys(this._workingCart)
            .filter(id => this._qtyOf(id) > 0)
            .map(id => ({ product_id: id, qty: this._qtyOf(id) }));
    }
    _asNum(v) {
        if (typeof v === 'number') return v;
        if (typeof v === 'string') { const n = parseFloat(v); return isNaN(n) ? null : n; }
        return null;
    }
    _rs(t) { return (t || '').replace(/₹\s*(\d[\d,]*)/g, '$1 rupees'); }
    _money(n) { return Math.round(Number(n) || 0) + ' rupees'; }
    /** Turn a getUserMedia error into a clear, mobile-friendly instruction. */
    _micErrorMessage(err) {
        const n = (err && err.name) || '';
        if (n === 'NotAllowedError' || n === 'SecurityError') {
            return 'Microphone blocked. Allow microphone access for this app in your phone Settings '
                + '(Settings → the Salesforce app → Microphone), then tap Live voice again.';
        }
        if (n === 'NotFoundError' || n === 'OverconstrainedError') {
            return 'No microphone was found on this device.';
        }
        if (n === 'NotReadableError') {
            return 'The microphone is in use by another app. Close it and tap Live voice again.';
        }
        return 'Could not access the microphone. Allow mic access for this app and try again.';
    }
    _fmtQty(q) {
        const n = Number(q);
        return n === Math.trunc(n) ? String(Math.trunc(n)) : n.toFixed(1);
    }
    _capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

    async _blobToBase64(blob) {
        const buf = await blob.arrayBuffer();
        const bytes = new Uint8Array(buf);
        let bin = '';
        const chunk = 0x8000;
        for (let i = 0; i < bytes.length; i += chunk) {
            bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
        }
        return btoa(bin);
    }

    // little audio chirp that also unlocks the AudioContext for TTS
    _playTone(from, to, ms) {
        try {
            const Ctx = window.AudioContext || window.webkitAudioContext;
            if (!Ctx) return;
            if (!this._audioCtx) this._audioCtx = new Ctx();
            const ctx = this._audioCtx;
            if (ctx.state === 'suspended') { ctx.resume(); }
            const osc = ctx.createOscillator();
            const gain = ctx.createGain();
            osc.frequency.setValueAtTime(from, ctx.currentTime);
            osc.frequency.linearRampToValueAtTime(to, ctx.currentTime + ms / 1000);
            gain.gain.setValueAtTime(0.06, ctx.currentTime);
            gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + ms / 1000);
            osc.connect(gain); gain.connect(ctx.destination);
            osc.start(); osc.stop(ctx.currentTime + ms / 1000);
        } catch (e) { /* non-critical */ }
    }
}