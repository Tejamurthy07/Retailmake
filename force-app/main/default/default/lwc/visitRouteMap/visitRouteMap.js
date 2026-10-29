import { LightningElement, api, wire } from 'lwc';
import { loadScript, loadStyle } from 'lightning/platformResourceLoader';
import LEAFLET from '@salesforce/resourceUrl/Leaflet';
import getRouteForDay from '@salesforce/apex/VisitRouteMapController.getRouteForDay';

export default class VisitRouteMap extends LightningElement {
    @api recordId;

    leafletReady = false;
    isLoading = true;
    errorMessage;
    routeData;
    map;
    layerGroup;
    roadDistanceKm = null;

    // Null means "today for the current user" — resolved server-side
    get dayAttendanceId() {
        return this.recordId || null;
    }

    @wire(getRouteForDay, { dayAttendanceId: '$dayAttendanceId' })
    wiredRoute({ data, error }) {
        if (data) {
            this.routeData = data;
            this.errorMessage = undefined;
            this.tryRender();
        } else if (error) {
            this.isLoading = false;
            this.errorMessage = this.extractError(error);
        }
    }

    renderedCallback() {
        if (this.leafletReady) return;
        this.leafletReady = true;
        Promise.all([
            loadScript(this, LEAFLET + '/leaflet.js'),
            loadStyle(this, LEAFLET + '/leaflet.css')
        ])
            .then(() => this.tryRender())
            .catch((e) => {
                this.isLoading = false;
                this.errorMessage = 'Failed to load map library: ' + (e && e.message ? e.message : e);
            });
    }

    tryRender() {
        if (!this.routeData || typeof window.L === 'undefined') return;
        this.isLoading = false;
        if (!this.routeData.hasData) return;
        this.renderMap();
    }

    renderMap() {
        const container = this.template.querySelector('.map-container');
        if (!container) return;

        const L = window.L;
        const points = this.collectPoints();
        if (points.length === 0) return;

        if (!this.map) {
            this.map = L.map(container, { zoomControl: true, scrollWheelZoom: false });
            L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                attribution: '© OpenStreetMap contributors',
                maxZoom: 19
            }).addTo(this.map);
        }

        if (this.layerGroup) this.layerGroup.clearLayers();
        this.layerGroup = L.layerGroup().addTo(this.map);
        this._placedMarkers = [];
        this.roadDistanceKm = null;

        const att = this.routeData.attendance || {};

        // Start marker — with permanent "START" label
        if (att.startLatitude != null && att.startLongitude != null) {
            const m = this.addMarker(L, [att.startLatitude, att.startLongitude], 'S', 'start-marker', `
                <div class="popup-title">🟢 Day Start</div>
                <div class="popup-row"><span class="label">Time</span> ${this.formatDateTime(att.dayStartTime)}</div>
                ${att.salespersonName ? `<div class="popup-row"><span class="label">Rep</span> ${this.escape(att.salespersonName)}</div>` : ''}
            `);
            if (m) {
                m.bindTooltip('START', {
                    permanent: true,
                    direction: 'top',
                    offset: [0, -18],
                    className: 'route-label start-label'
                });
            }
        }

        // Visit markers
        (this.routeData.visits || []).forEach((v) => {
            const statusBadge = v.visitStatus
                ? `<span class="popup-badge">${this.escape(v.visitStatus)}</span>`
                : '';
            this.addMarker(L, [v.latitude, v.longitude], String(v.sequence), 'visit-marker', `
                <div class="popup-title">📍 ${this.escape(v.accountName) || this.escape(v.label)}</div>
                <div class="popup-row"><span class="label">Check-in</span> ${this.formatDateTime(v.checkInTime)}</div>
                <div class="popup-row"><span class="label">Check-out</span> ${this.formatDateTime(v.checkOutTime)}</div>
                ${statusBadge ? `<div class="popup-row"><span class="label">Status</span> ${statusBadge}</div>` : ''}
            `);
        });

        // End marker — with permanent "END" label
        if (att.endLatitude != null && att.endLongitude != null) {
            const m = this.addMarker(L, [att.endLatitude, att.endLongitude], 'E', 'end-marker', `
                <div class="popup-title">🔴 Day End</div>
                <div class="popup-row"><span class="label">Time</span> ${this.formatDateTime(att.dayEndTime)}</div>
                ${att.distanceTraveledKm != null ? `<div class="popup-row"><span class="label">Distance</span> ${Number(att.distanceTraveledKm).toFixed(1)} km</div>` : ''}
            `);
            if (m) {
                m.bindTooltip('END', {
                    permanent: true,
                    direction: 'top',
                    offset: [0, -18],
                    className: 'route-label end-label'
                });
            }
        }

        // Polyline (straight, drawn immediately so the map never looks empty)
        const glow = L.polyline(points, {
            color: '#5a3fd6',
            weight: 10,
            opacity: 0.18,
            lineCap: 'round',
            lineJoin: 'round',
            interactive: false
        });
        glow.addTo(this.layerGroup);

        const line = L.polyline(points, {
            color: '#1589ee',
            weight: 4,
            opacity: 0.95,
            lineCap: 'round',
            lineJoin: 'round',
            className: 'route-line'
        });
        line.addTo(this.layerGroup);

        this.map.fitBounds(line.getBounds(), { padding: [40, 40] });
        setTimeout(() => this.map && this.map.invalidateSize(), 200);

        // Then try to upgrade to a road-snapped route in the background
        this.upgradeToRoadRoute(L, points, glow, line);
    }

    upgradeToRoadRoute(L, points, glow, straightLine) {
        if (!points || points.length < 2) return;

        // OSRM expects lng,lat pairs, semicolon-separated, max ~100 points
        const coords = points
            .slice(0, 100)
            .map((p) => `${p[1]},${p[0]}`)
            .join(';');
        const url =
            'https://router.project-osrm.org/route/v1/driving/' +
            coords +
            '?overview=full&geometries=geojson';

        fetch(url, { method: 'GET' })
            .then((res) => (res.ok ? res.json() : Promise.reject(res.statusText)))
            .then((data) => {
                if (!data || !data.routes || data.routes.length === 0) return;
                const route = data.routes[0];
                const geom = route.geometry; // GeoJSON LineString, lng/lat
                if (!geom || !geom.coordinates) return;
                const latlngs = geom.coordinates.map((c) => [c[1], c[0]]);
                if (route.distance != null) {
                    this.roadDistanceKm = route.distance / 1000;
                }

                // Replace the straight line with the road-snapped one
                this.layerGroup.removeLayer(glow);
                this.layerGroup.removeLayer(straightLine);

                const newGlow = L.polyline(latlngs, {
                    color: '#5a3fd6',
                    weight: 10,
                    opacity: 0.22,
                    lineCap: 'round',
                    lineJoin: 'round',
                    interactive: false
                });
                newGlow.addTo(this.layerGroup);

                const newLine = L.polyline(latlngs, {
                    color: '#1589ee',
                    weight: 4,
                    opacity: 0.95,
                    lineCap: 'round',
                    lineJoin: 'round',
                    className: 'route-line'
                });
                newLine.addTo(this.layerGroup);

                // Re-add markers above the line (Leaflet z-order)
                this.layerGroup.eachLayer((layer) => {
                    if (layer.options && layer.options.icon) {
                        layer.bringToFront();
                    }
                });

                this.map.fitBounds(newLine.getBounds(), { padding: [40, 40] });
            })
            .catch(() => {
                // Silent fallback — keep the straight line if OSRM fails
            });
    }

    /**
     * Coerces a [lat, lng] pair to real numbers, returning null for anything
     * that isn't a finite coordinate.
     *
     * Coordinates can reach the component as strings (a geolocation captured at
     * full browser precision, a text-typed field, wire serialization). Leaflet
     * demands numbers, and the overlap-offset maths below adds to them — and in
     * JavaScript "12.89..." + 0.0001 concatenates into "12.89...0.0001", a value
     * with two decimal points that Leaflet rejects with "Invalid LatLng object".
     * Normalising here makes every downstream consumer safe and drops junk
     * coordinates rather than letting one break the whole map.
     */
    _coordPair(pair) {
        if (!pair) return null;
        const lat = Number(pair[0]);
        const lng = Number(pair[1]);
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
        return [lat, lng];
    }

    collectPoints() {
        const pts = [];
        const att = this.routeData.attendance || {};
        const push = (a, b) => {
            const c = this._coordPair([a, b]);
            if (c) pts.push(c);
        };
        if (att.startLatitude != null && att.startLongitude != null) {
            push(att.startLatitude, att.startLongitude);
        }
        (this.routeData.visits || []).forEach((v) => {
            if (v.latitude != null && v.longitude != null) push(v.latitude, v.longitude);
        });
        if (att.endLatitude != null && att.endLongitude != null) {
            push(att.endLatitude, att.endLongitude);
        }
        return pts;
    }

    addMarker(L, latlng, label, cssClass, popupHtml) {
        // Normalise first: string coordinates would otherwise concatenate rather
        // than add in _offsetIfOverlap, and Leaflet rejects non-numeric latlngs.
        const coord = this._coordPair(latlng);
        if (!coord) return null;

        const isEndpoint = cssClass !== 'visit-marker';
        const size = isEndpoint ? 38 : 30;
        const anchor = size / 2;

        // Auto-offset if this position collides with a previously placed marker
        // so overlapping pins (e.g., rep starts day AT the first outlet) all stay visible.
        const placedLatlng = this._offsetIfOverlap(coord);

        const icon = L.divIcon({
            className: '',
            html: `<div class="${cssClass}">${label}</div>`,
            iconSize: [size, size],
            iconAnchor: [anchor, anchor]
        });
        const m = L.marker(placedLatlng, {
            icon,
            // Visit pins sit above S/E so they're never hidden by overlapping endpoints
            zIndexOffset: isEndpoint ? 100 : 500
        }).addTo(this.layerGroup);
        m.bindPopup(popupHtml, { className: 'visit-route-popup', maxWidth: 280 });

        this._placedMarkers = this._placedMarkers || [];
        this._placedMarkers.push(placedLatlng);
        return m;
    }

    _offsetIfOverlap(latlng) {
        const COLLISION_M = 25;
        const OFFSET_M = 40;
        const placed = this._placedMarkers || [];
        let collisions = 0;
        for (const p of placed) {
            if (this._distanceMeters(latlng, p) < COLLISION_M) collisions++;
        }
        if (collisions === 0) return latlng;
        // Rotate offsets around a circle so multiple overlapping pins fan out
        const angle = (collisions * 72) * Math.PI / 180;
        const dLat = (OFFSET_M / 111320) * Math.cos(angle);
        const dLng = (OFFSET_M / (111320 * Math.cos((latlng[0] * Math.PI) / 180))) * Math.sin(angle);
        return [latlng[0] + dLat, latlng[1] + dLng];
    }

    _distanceMeters(a, b) {
        const R = 6371000;
        const toRad = d => (d * Math.PI) / 180;
        const dLat = toRad(b[0] - a[0]);
        const dLng = toRad(b[1] - a[1]);
        const x = Math.sin(dLat / 2) ** 2
            + Math.cos(toRad(a[0])) * Math.cos(toRad(b[0])) * Math.sin(dLng / 2) ** 2;
        return R * 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
    }

    formatDateTime(value) {
        if (!value) return '—';
        try {
            return new Date(value).toLocaleString();
        } catch (e) {
            return value;
        }
    }

    formatDate(value) {
        if (!value) return '';
        try {
            const d = new Date(value);
            return d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
        } catch (e) {
            return String(value);
        }
    }

    escape(s) {
        if (s == null) return '';
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    extractError(error) {
        if (!error) return 'Unknown error';
        if (Array.isArray(error.body)) return error.body.map((e) => e.message).join(', ');
        if (error.body && error.body.message) return error.body.message;
        if (error.message) return error.message;
        return JSON.stringify(error);
    }

    /* ---------- Getters for header / footer ---------- */
    get hasData() {
        return !!(this.routeData && this.routeData.hasData);
    }

    get showEmptyState() {
        return !this.isLoading && !this.errorMessage && this.routeData && !this.routeData.hasData;
    }

    get attendance() {
        return (this.routeData && this.routeData.attendance) || {};
    }

    get subtitleText() {
        const att = this.attendance;
        const dateStr = this.formatDate(att.attendanceDate);
        const who = att.salespersonName || '';
        if (dateStr && who) return `${who} • ${dateStr}`;
        return dateStr || who || 'No attendance data';
    }

    get totalVisitsDisplay() {
        const n = (this.routeData && this.routeData.totalVisits) || 0;
        return String(n);
    }

    get distanceDisplay() {
        const km = this.attendance.distanceTraveledKm;
        if (km == null) return '—';
        return `${Number(km).toFixed(1)} km`;
    }

    get hasRoadDistance() {
        return this.roadDistanceKm != null;
    }

    get roadDistanceDisplay() {
        if (this.roadDistanceKm == null) return '—';
        return `${this.roadDistanceKm.toFixed(1)} km`;
    }

    get sfDistanceKm() {
        const km = this.attendance.distanceTraveledKm;
        return km != null ? Number(km) : null;
    }

    get hasDistanceComparison() {
        return this.roadDistanceKm != null && this.sfDistanceKm != null;
    }

    get distanceComparisonText() {
        if (!this.hasDistanceComparison) return '';
        const diff = this.roadDistanceKm - this.sfDistanceKm;
        const absDiff = Math.abs(diff);
        if (absDiff < 0.1) return 'Map matches system';
        const sign = diff > 0 ? '+' : '−';
        const verb = diff > 0 ? 'longer' : 'shorter';
        return `Map route ${sign}${absDiff.toFixed(1)} km ${verb} than system`;
    }

    get distanceComparisonClass() {
        if (!this.hasDistanceComparison) return 'comparison';
        const diff = Math.abs(this.roadDistanceKm - this.sfDistanceKm);
        if (diff < 0.5) return 'comparison comparison-match';
        if (diff < 2) return 'comparison comparison-minor';
        return 'comparison comparison-major';
    }

    get productiveDisplay() {
        const pct = this.attendance.productivityPercent;
        const prod = this.attendance.productiveCalls;
        if (pct != null) return `${Number(pct).toFixed(0)}%`;
        if (prod != null) return String(prod);
        return '—';
    }

    get hoursDisplay() {
        const h = this.attendance.hoursWorked;
        if (h == null) return '—';
        return `${Number(h).toFixed(1)} h`;
    }

    get metaText() {
        const att = this.attendance;
        const orders = att.totalOrders;
        const value = att.totalOrderValue;
        const bits = [];
        if (orders != null) bits.push(`${orders} orders`);
        if (value != null) bits.push(`₹${Number(value).toLocaleString()}`);
        return bits.join(' • ');
    }
}