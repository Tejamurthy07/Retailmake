import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import Id from '@salesforce/user/Id';

import startDay from '@salesforce/apex/DayAttendanceController.startDay';
import endDay from '@salesforce/apex/DayAttendanceController.endDay';
import getDayStats from '@salesforce/apex/DayAttendanceController.getDayStats';
import getCurrentDayAttendance from '@salesforce/apex/DayAttendanceController.getCurrentDayAttendance';
import logGPS from '@salesforce/apex/DayAttendanceController.logGPS';
import syncOfflineGPSLogs from '@salesforce/apex/DayAttendanceController.syncOfflineGPSLogs';
import getAttendanceConfig from '@salesforce/apex/DayAttendanceController.getAttendanceConfig';
import searchEmployees from '@salesforce/apex/DayAttendanceController.searchEmployees';

/** Local storage key for offline GPS queue */
const GPS_QUEUE_STORAGE_KEY = 'dayStartEnd_offlineGpsQueue';

/** INR currency formatter */
const INR_FORMATTER = new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0
});

export default class DayStartEnd extends LightningElement {
    currentUserId = Id;

    // ── Reactive tracked properties ──────────────────────────────────
    @track dayRecord = null;
    @track isDayActive = false;
    @track isProcessing = false;
    @track showEndDayModal = false;
    @track isOffline = false;
    @track currentTime = new Date();

    // Stats
    @track plannedVisits = 0;
    @track completedVisits = 0;
    @track productiveCalls = 0;
    @track nonProductiveCalls = 0;
    @track ordersToday = 0;
    @track orderValue = 0;
    @track collectionTotal = 0;
    @track distanceCovered = '0.0';
    @track productivityPercent = 0;

    // Device info
    @track batteryLevelDisplay = 'N/A';
    @track networkStatusText = 'Online';
    @track locationLatitude = null;
    @track locationLongitude = null;
    @track locationAccuracy = null;

    // Photos
    @track startSelfiePreview = null;
    @track endSelfiePreview = null;

    // GPS tracking
    @track offlineGpsQueueCount = 0;

    // Odometer
    @track odometerStart = null;
    @track odometerEnd = null;

    // Companion
    @track withCompanion = false;
    @track companionId = null;
    @track companionName = '';
    @track companionSearchTerm = '';
    @track companionSearchResults = [];
    @track showCompanionDropdown = false;

    // ── Non-reactive internal state ──────────────────────────────────
    startSelfieBase64 = null;
    endSelfieBase64 = null;
    endDayRemarks = '';
    dayStartTime = null;
    dayDuration = 0;
    batteryLevelRaw = null;
    deviceInfo = '';
    _companionSearchTimer = null;

    // Configuration (from getAttendanceConfig)
    configSelfieRequired = false;
    configGpsTrackingInterval = 300; // seconds, default 5 min
    configStatsRefreshInterval = 60; // seconds, default 1 min
    configGpsTrackingEnabled = false;

    // Interval references for cleanup
    _clockInterval = null;
    _timerInterval = null;
    _statsInterval = null;
    _gpsInterval = null;

    // GPS offline queue (in-memory mirror of localStorage)
    _offlineGpsQueue = [];

    // ══════════════════════════════════════════════════════════════════
    //  LIFECYCLE
    // ══════════════════════════════════════════════════════════════════

    connectedCallback() {
        this._detectDeviceInfo();
        this._captureLocation();
        this._captureBattery();
        this._initNetworkListeners();
        this._loadOfflineGpsQueue();
        this._loadConfig();
        this._checkExistingAttendance();

        // Live clock: update every second
        this._clockInterval = setInterval(() => {
            this.currentTime = new Date();
            if (this.isDayActive) {
                this.dayDuration = this.dayStartTime
                    ? Math.floor((Date.now() - this.dayStartTime.getTime()) / 1000)
                    : 0;
            }
        }, 1000);
    }

    disconnectedCallback() {
        this._clearAllIntervals();
        window.removeEventListener('online', this._handleOnline);
        window.removeEventListener('offline', this._handleOffline);
    }

    // ══════════════════════════════════════════════════════════════════
    //  COMPUTED GETTERS
    // ══════════════════════════════════════════════════════════════════

    /** Greeting based on time of day */
    get greetingMessage() {
        const hour = new Date().getHours();
        if (hour < 12) return 'Good Morning!';
        if (hour < 17) return 'Good Afternoon!';
        return 'Good Evening!';
    }

    /** Formatted date: "Monday, 02 March 2026" */
    get todayDateDisplay() {
        return new Date().toLocaleDateString('en-IN', {
            weekday: 'long',
            day: '2-digit',
            month: 'long',
            year: 'numeric'
        });
    }

    /** Formatted live clock: "02:35:12 PM" */
    get currentTimeDisplay() {
        return this.currentTime.toLocaleTimeString('en-IN', {
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit',
            hour12: true
        });
    }

    /** Location capture status text */
    get locationStatusText() {
        if (this.locationLatitude && this.locationLongitude) {
            return 'Captured (' +
                this.locationLatitude.toFixed(4) + ', ' +
                this.locationLongitude.toFixed(4) + ')';
        }
        return 'Fetching...';
    }

    /** Network icon: wifi or offline */
    get networkIcon() {
        return this.isOffline ? 'utility:offline' : 'utility:wifi';
    }

    /** Network status CSS class */
    get networkStatusClass() {
        return this.isOffline
            ? 'info-value network-offline'
            : 'info-value network-online';
    }

    /** Day start time formatted */
    get dayStartTimeDisplay() {
        if (!this.dayStartTime) return '';
        return this.dayStartTime.toLocaleTimeString('en-IN', {
            hour: '2-digit',
            minute: '2-digit',
            hour12: true
        });
    }

    /** HH:MM:SS duration display */
    get dayDurationDisplay() {
        const h = Math.floor(this.dayDuration / 3600);
        const m = Math.floor((this.dayDuration % 3600) / 60);
        const s = this.dayDuration % 60;
        return this._padZero(h) + ':' + this._padZero(m) + ':' + this._padZero(s);
    }

    /** INR-formatted order value */
    get orderValueFormatted() {
        return INR_FORMATTER.format(this.orderValue || 0);
    }

    /** INR-formatted collection total */
    get collectionTotalFormatted() {
        return INR_FORMATTER.format(this.collectionTotal || 0);
    }

    /** Visit progress percentage */
    get visitProgressPercent() {
        if (!this.plannedVisits || this.plannedVisits === 0) return 0;
        return Math.min(Math.round((this.completedVisits / this.plannedVisits) * 100), 100);
    }

    /** Progress bar inline style with dynamic color */
    get progressBarStyle() {
        const pct = this.visitProgressPercent;
        let color;
        if (pct >= 80) {
            color = '#2e844a'; // green
        } else if (pct >= 50) {
            color = '#dd7a01'; // amber
        } else {
            color = '#ea001e'; // red
        }
        return 'width:' + pct + '%;background-color:' + color;
    }

    /** Start Day button disabled state */
    get startDayDisabled() {
        if (this.isProcessing) return true;
        if (!this.locationLatitude || !this.locationLongitude) return true;
        if (this.configSelfieRequired && !this.startSelfieBase64) return true;
        return false;
    }

    /** GPS tracking indicator dot class */
    get gpsIndicatorClass() {
        return this.isDayActive && this.configGpsTrackingEnabled
            ? 'gps-indicator gps-indicator-active'
            : 'gps-indicator gps-indicator-inactive';
    }

    /** GPS tracking status label */
    get gpsTrackingStatusText() {
        return this.isDayActive && this.configGpsTrackingEnabled ? 'Active' : 'Inactive';
    }

    // ══════════════════════════════════════════════════════════════════
    //  INITIALIZATION
    // ══════════════════════════════════════════════════════════════════

    /** Load admin configuration from Apex */
    async _loadConfig() {
        try {
            const config = await getAttendanceConfig();
            if (config) {
                this.configSelfieRequired = config.selfieRequired === true;
                this.configGpsTrackingInterval = config.gpsTrackingInterval || 300;
                this.configStatsRefreshInterval = config.statsRefreshInterval || 60;
                this.configGpsTrackingEnabled = config.gpsTrackingEnabled === true;
            }
        } catch (error) {
            console.error('DayStartEnd: Error loading config', error);
        }
    }

    // Strip the managed-package namespace prefix from Apex-returned SObject keys
    // so unqualified `record.Field__c` reads keep working. Recurses into arrays
    // and child relationships. No-op on camelCase maps and wrapper DTOs.
    _stripNs(value) {
        if (Array.isArray(value)) return value.map((v) => this._stripNs(v));
        if (value && typeof value === 'object') {
            const out = {};
            Object.keys(value).forEach((k) => {
                const nk = k.startsWith('ftretailmake__') ? k.slice('ftretailmake__'.length) : k;
                out[nk] = this._stripNs(value[k]);
            });
            return out;
        }
        return value;
    }

    /** Check if user already has an active day attendance */
    async _checkExistingAttendance() {
        try {
            const record = this._stripNs(await getCurrentDayAttendance({ userId: this.currentUserId }));
            if (record && record.Id) {
                this.dayRecord = record;
                this.isDayActive = true;
                this.dayStartTime = new Date(record.Start_Time__c || record.CreatedDate);
                this.dayDuration = Math.floor((Date.now() - this.dayStartTime.getTime()) / 1000);
                this._startActiveIntervals();
                this._loadDayStats();
            }
        } catch (error) {
            console.error('DayStartEnd: Error checking attendance', error);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  DAY START
    // ══════════════════════════════════════════════════════════════════

    async handleStartDay() {
        if (!this.locationLatitude || !this.locationLongitude) {
            this._showToast('Warning', 'Please wait for location to be captured.', 'warning');
            this._captureLocation();
            return;
        }

        if (this.configSelfieRequired && !this.startSelfieBase64) {
            this._showToast('Warning', 'A selfie is required to start the day.', 'warning');
            return;
        }

        this.isProcessing = true;
        try {
            const dayData = {
                startLatitude: this.locationLatitude,
                startLongitude: this.locationLongitude,
                startAccuracy: this.locationAccuracy,
                selfieBase64: this.startSelfieBase64,
                batteryLevel: this.batteryLevelRaw,
                networkStatus: this.networkStatusText,
                deviceInfo: this.deviceInfo,
                odometerStart: this.odometerStart,
                withCompanion: this.withCompanion,
                companionId: this.withCompanion ? this.companionId : null
            };

            const result = this._stripNs(await startDay({ dayJson: JSON.stringify(dayData) }));
            this.dayRecord = result;
            this.isDayActive = true;
            this.dayStartTime = new Date();
            this.dayDuration = 0;

            this._startActiveIntervals();
            this._loadDayStats();

            this._showToast('Success', 'Day started successfully! Have a productive day!', 'success');
        } catch (error) {
            this._showToast('Error', 'Failed to start day: ' + this._reduceErrors(error), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  DAY END
    // ══════════════════════════════════════════════════════════════════

    handleEndDayClick() {
        this._loadDayStats(); // Refresh stats for summary review
        this.showEndDayModal = true;
    }

    closeEndDayModal() {
        this.showEndDayModal = false;
        this.endSelfiePreview = null;
        this.endSelfieBase64 = null;
        this.endDayRemarks = '';
    }

    handleEndRemarksChange(event) {
        this.endDayRemarks = event.target.value;
    }

    async handleEndDay() {
        // Refresh location before ending
        this._captureLocation();

        this.isProcessing = true;
        try {
            const endData = {
                attendanceId: this.dayRecord.Id,
                endLatitude: this.locationLatitude,
                endLongitude: this.locationLongitude,
                endAccuracy: this.locationAccuracy,
                selfieBase64: this.endSelfieBase64,
                remarks: this.endDayRemarks,
                odometerEnd: this.odometerEnd
            };

            this._stripNs(await endDay({ dayJson: JSON.stringify(endData) }));

            // Sync any remaining offline GPS logs before closing out
            await this._syncOfflineGpsQueue();

            this._clearActiveIntervals();
            this.isDayActive = false;
            this.showEndDayModal = false;
            this.dayRecord = null;
            this._resetStats();

            this._showToast('Success', 'Day ended successfully! Great work today!', 'success');
        } catch (error) {
            this._showToast('Error', 'Failed to end day: ' + this._reduceErrors(error), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  STATS
    // ══════════════════════════════════════════════════════════════════

    async _loadDayStats() {
        if (!this.dayRecord || !this.dayRecord.Id) return;
        try {
            const result = await getDayStats({ dayId: this.dayRecord.Id });
            if (result) {
                this.plannedVisits = result.Planned_Visits__c || 0;
                this.completedVisits = result.Completed_Visits__c || 0;
                this.productiveCalls = result.Productive_Calls__c || 0;
                this.nonProductiveCalls = result.Non_Productive_Calls__c || 0;
                this.ordersToday = result.Orders_Today__c || 0;
                this.orderValue = result.Order_Value__c || 0;
                this.collectionTotal = result.Collection_Total__c || 0;
                this.distanceCovered = (result.Distance_Covered__c || 0).toFixed(1);
                this.productivityPercent = result.Productivity_Percent__c != null
                    ? Math.round(result.Productivity_Percent__c)
                    : (this.completedVisits > 0
                        ? Math.round((this.productiveCalls / this.completedVisits) * 100)
                        : 0);
            }
        } catch (error) {
            console.error('DayStartEnd: Error loading stats', error);
        }
    }

    _resetStats() {
        this.plannedVisits = 0;
        this.completedVisits = 0;
        this.productiveCalls = 0;
        this.nonProductiveCalls = 0;
        this.ordersToday = 0;
        this.orderValue = 0;
        this.collectionTotal = 0;
        this.distanceCovered = '0.0';
        this.productivityPercent = 0;
    }

    // ══════════════════════════════════════════════════════════════════
    //  GPS BREADCRUMB TRACKING
    // ══════════════════════════════════════════════════════════════════

    /** Start GPS breadcrumb logging at configured interval */
    _startGpsTracking() {
        if (!this.configGpsTrackingEnabled) return;
        if (this._gpsInterval) clearInterval(this._gpsInterval);

        const intervalMs = (this.configGpsTrackingInterval || 300) * 1000;

        this._gpsInterval = setInterval(() => {
            this._logGpsBreadcrumb();
        }, intervalMs);

        // Log first breadcrumb immediately
        this._logGpsBreadcrumb();
    }

    /** Capture current location and log a GPS breadcrumb */
    _logGpsBreadcrumb() {
        if (!navigator.geolocation) return;

        navigator.geolocation.getCurrentPosition(
            (position) => {
                const gpsLog = {
                    sobjectType: 'GPS_Log__c',
                    Day_Attendance__c: this.dayRecord ? this.dayRecord.Id : null,
                    Latitude__c: position.coords.latitude,
                    Longitude__c: position.coords.longitude,
                    Accuracy__c: position.coords.accuracy,
                    Timestamp__c: new Date().toISOString(),
                    Battery_Level__c: this.batteryLevelRaw
                };

                if (this.isOffline) {
                    this._enqueueOfflineGps(gpsLog);
                } else {
                    this._sendGpsLog(gpsLog);
                }
            },
            (error) => {
                console.warn('DayStartEnd: GPS breadcrumb error', error.message);
            },
            { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
        );
    }

    /** Send a single GPS log to Apex */
    async _sendGpsLog(gpsLog) {
        try {
            this._stripNs(await logGPS({ gpsJson: JSON.stringify(gpsLog) }));
        } catch (error) {
            // If send fails, queue it for offline sync
            console.warn('DayStartEnd: GPS log send failed, queuing offline', error);
            this._enqueueOfflineGps(gpsLog);
        }
    }

    /** Add GPS log to offline queue and persist to localStorage */
    _enqueueOfflineGps(gpsLog) {
        this._offlineGpsQueue.push(gpsLog);
        this.offlineGpsQueueCount = this._offlineGpsQueue.length;
        this._persistOfflineGpsQueue();
    }

    /** Sync offline GPS queue when back online */
    async _syncOfflineGpsQueue() {
        if (this._offlineGpsQueue.length === 0) return;

        try {
            const logsToSync = [...this._offlineGpsQueue];
            this._stripNs(await syncOfflineGPSLogs({ gpsLogsJson: JSON.stringify(logsToSync) }));

            // Clear queue on success
            this._offlineGpsQueue = [];
            this.offlineGpsQueueCount = 0;
            this._persistOfflineGpsQueue();
        } catch (error) {
            console.error('DayStartEnd: Failed to sync offline GPS logs', error);
        }
    }

    /** Load offline queue from localStorage */
    _loadOfflineGpsQueue() {
        try {
            const stored = localStorage.getItem(GPS_QUEUE_STORAGE_KEY);
            if (stored) {
                this._offlineGpsQueue = JSON.parse(stored);
                this.offlineGpsQueueCount = this._offlineGpsQueue.length;
            }
        } catch (error) {
            console.warn('DayStartEnd: Error loading offline GPS queue', error);
            this._offlineGpsQueue = [];
        }
    }

    /** Persist offline queue to localStorage */
    _persistOfflineGpsQueue() {
        try {
            localStorage.setItem(GPS_QUEUE_STORAGE_KEY, JSON.stringify(this._offlineGpsQueue));
        } catch (error) {
            console.warn('DayStartEnd: Error persisting GPS queue', error);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  SELFIE / PHOTO HANDLING
    // ══════════════════════════════════════════════════════════════════

    triggerStartSelfieCapture() {
        const input = this.template.querySelector('input[data-id="startSelfie"]');
        if (input) input.click();
    }

    handleStartSelfieCapture(event) {
        this._processPhoto(event, (dataUrl, base64) => {
            this.startSelfiePreview = dataUrl;
            this.startSelfieBase64 = base64;
        });
    }

    removeStartSelfie() {
        this.startSelfiePreview = null;
        this.startSelfieBase64 = null;
    }

    triggerEndSelfieCapture() {
        const input = this.template.querySelector('input[data-id="endSelfie"]');
        if (input) input.click();
    }

    handleEndSelfieCapture(event) {
        this._processPhoto(event, (dataUrl, base64) => {
            this.endSelfiePreview = dataUrl;
            this.endSelfieBase64 = base64;
        });
    }

    removeEndSelfie() {
        this.endSelfiePreview = null;
        this.endSelfieBase64 = null;
    }

    /** Generic photo processor: reads file, validates size, calls callback */
    _processPhoto(event, callback) {
        const file = event.target.files[0];
        if (!file) return;

        // 10MB hard cap on the raw file — we'll compress this down to ~200KB
        // before sending, but a >10MB photo is almost certainly the wrong
        // input and worth rejecting before we spend the cycles compressing.
        if (file.size > 10 * 1024 * 1024) {
            this._showToast('Error', 'Photo size must be less than 10MB.', 'error');
            return;
        }

        this._compressImage(file, {
            maxDimension: 1280,   // longest side; keeps faces clearly recognisable
            quality: 0.75,        // JPEG quality, good balance of size vs clarity
            maxBytes: 400 * 1024  // hard upper bound — re-encode at lower quality if exceeded
        })
            .then(({ dataUrl, base64 }) => {
                callback(dataUrl, base64);
            })
            .catch(err => {
                // eslint-disable-next-line no-console
                console.warn('Image compression failed, falling back to raw upload', err);
                // Fall back to original behaviour if anything in the canvas
                // pipeline breaks — better a working upload than a hung button.
                const reader = new FileReader();
                reader.onload = () => {
                    const dataUrl = reader.result;
                    const base64 = dataUrl.split(',')[1];
                    callback(dataUrl, base64);
                };
                reader.onerror = () => {
                    this._showToast('Error', 'Failed to read photo file.', 'error');
                };
                reader.readAsDataURL(file);
            });
    }

    /**
     * Compress an image file via canvas before upload. Scales the longest
     * side down to maxDimension px, re-encodes as JPEG at the given quality,
     * and progressively lowers quality if the result still exceeds maxBytes.
     * Returns a { dataUrl, base64 } pair the existing callback expects.
     */
    _compressImage(file, { maxDimension, quality, maxBytes }) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onerror = () => reject(new Error('FileReader error'));
            reader.onload = () => {
                const img = new Image();
                img.onerror = () => reject(new Error('Image decode error'));
                img.onload = () => {
                    try {
                        const { width, height } = this._fitDimensions(
                            img.width, img.height, maxDimension
                        );

                        const canvas = document.createElement('canvas');
                        canvas.width = width;
                        canvas.height = height;
                        const ctx = canvas.getContext('2d');
                        ctx.drawImage(img, 0, 0, width, height);

                        let currentQuality = quality;
                        let dataUrl = canvas.toDataURL('image/jpeg', currentQuality);

                        // If still too large, step quality down. 5 attempts max
                        // so we never spin forever on a pathologically large input.
                        for (let i = 0; i < 5; i++) {
                            const base64Len = dataUrl.length - dataUrl.indexOf(',') - 1;
                            const bytes = Math.floor(base64Len * 0.75);
                            if (bytes <= maxBytes || currentQuality <= 0.4) break;
                            currentQuality -= 0.1;
                            dataUrl = canvas.toDataURL('image/jpeg', currentQuality);
                        }

                        const base64 = dataUrl.split(',')[1];
                        resolve({ dataUrl, base64 });
                    } catch (e) {
                        reject(e);
                    }
                };
                img.src = reader.result;
            };
            reader.readAsDataURL(file);
        });
    }

    _fitDimensions(srcW, srcH, maxDimension) {
        if (srcW <= maxDimension && srcH <= maxDimension) {
            return { width: srcW, height: srcH };
        }
        const ratio = srcW > srcH
            ? maxDimension / srcW
            : maxDimension / srcH;
        return {
            width: Math.round(srcW * ratio),
            height: Math.round(srcH * ratio)
        };
    }

    // ══════════════════════════════════════════════════════════════════
    //  DEVICE INFO & SENSORS
    // ══════════════════════════════════════════════════════════════════

    /** Capture current GPS location */
    _captureLocation() {
        if (!navigator.geolocation) {
            this._showToast('Error', 'Geolocation is not supported on this device.', 'error');
            return;
        }

        navigator.geolocation.getCurrentPosition(
            (position) => {
                this.locationLatitude = position.coords.latitude;
                this.locationLongitude = position.coords.longitude;
                this.locationAccuracy = position.coords.accuracy;
            },
            (error) => {
                console.warn('DayStartEnd: Geolocation error', error.message);
                this._showToast('Warning', 'Unable to get GPS location. Please enable Location Services.', 'warning');
            },
            { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
        );
    }

    /** Read battery level via Battery API */
    async _captureBattery() {
        try {
            if (navigator.getBattery) {
                const battery = await navigator.getBattery();
                this._updateBatteryDisplay(battery);
                battery.addEventListener('levelchange', () => {
                    this._updateBatteryDisplay(battery);
                });
                battery.addEventListener('chargingchange', () => {
                    this._updateBatteryDisplay(battery);
                });
            }
        } catch (error) {
            this.batteryLevelDisplay = 'N/A';
        }
    }

    _updateBatteryDisplay(battery) {
        const level = Math.round(battery.level * 100);
        this.batteryLevelRaw = level;
        this.batteryLevelDisplay = level + '%' + (battery.charging ? ' (Charging)' : '');
    }

    /** Detect device/browser info string */
    _detectDeviceInfo() {
        const ua = navigator.userAgent || '';
        const platform = navigator.platform || '';
        this.deviceInfo = platform + ' | ' + ua.substring(0, 120);
    }

    /** Initialize online/offline listeners */
    _initNetworkListeners() {
        this.isOffline = !navigator.onLine;
        this.networkStatusText = navigator.onLine ? 'Online' : 'Offline';

        this._handleOnline = () => {
            this.isOffline = false;
            this.networkStatusText = 'Online';
            // Attempt to sync offline GPS queue when back online
            if (this.isDayActive) {
                this._syncOfflineGpsQueue();
            }
        };

        this._handleOffline = () => {
            this.isOffline = true;
            this.networkStatusText = 'Offline';
        };

        window.addEventListener('online', this._handleOnline);
        window.addEventListener('offline', this._handleOffline);
    }

    // ══════════════════════════════════════════════════════════════════
    //  ODOMETER & COMPANION HANDLERS
    // ══════════════════════════════════════════════════════════════════

    handleOdometerStartChange(event) {
        this.odometerStart = event.target.value ? Number(event.target.value) : null;
    }

    handleOdometerEndChange(event) {
        this.odometerEnd = event.target.value ? Number(event.target.value) : null;
    }

    handleCompanionToggle(event) {
        this.withCompanion = event.target.checked;
        if (!this.withCompanion) {
            this.companionId = null;
            this.companionName = '';
            this.companionSearchTerm = '';
            this.companionSearchResults = [];
            this.showCompanionDropdown = false;
        }
    }

    handleCompanionSearch(event) {
        const term = event.target.value;
        this.companionSearchTerm = term;

        if (this._companionSearchTimer) {
            clearTimeout(this._companionSearchTimer);
        }

        if (!term || term.length < 2) {
            this.companionSearchResults = [];
            this.showCompanionDropdown = false;
            return;
        }

        // Debounce 300ms
        this._companionSearchTimer = setTimeout(() => {
            this._doCompanionSearch(term);
        }, 300);
    }

    async _doCompanionSearch(term) {
        try {
            const results = this._stripNs(await searchEmployees({ searchTerm: term }));
            this.companionSearchResults = (results || []).map(emp => ({
                id: emp.Id,
                name: [emp.First_Name__c, emp.Last_Name__c].filter(Boolean).join(' '),
                subtitle: [emp.Employee_Code__c, emp.Designation__c].filter(Boolean).join(' - ')
            }));
            this.showCompanionDropdown = this.companionSearchResults.length > 0;
        } catch (error) {
            console.error('DayStartEnd: Companion search error', error);
            this.companionSearchResults = [];
            this.showCompanionDropdown = false;
        }
    }

    handleCompanionSelect(event) {
        const selectedId = event.currentTarget.dataset.id;
        const selected = this.companionSearchResults.find(e => e.id === selectedId);
        if (selected) {
            this.companionId = selected.id;
            this.companionName = selected.name;
            this.companionSearchTerm = selected.name;
            this.showCompanionDropdown = false;
        }
    }

    clearCompanion() {
        this.companionId = null;
        this.companionName = '';
        this.companionSearchTerm = '';
        this.companionSearchResults = [];
        this.showCompanionDropdown = false;
    }

    // ══════════════════════════════════════════════════════════════════
    //  INTERVAL MANAGEMENT
    // ══════════════════════════════════════════════════════════════════

    /** Start all active-day intervals: timer, stats polling, GPS tracking */
    _startActiveIntervals() {
        // Duration timer is handled in the clock interval for efficiency.
        // Stats polling
        const statsMs = (this.configStatsRefreshInterval || 60) * 1000;
        if (this._statsInterval) clearInterval(this._statsInterval);
        this._statsInterval = setInterval(() => {
            this._loadDayStats();
        }, statsMs);

        // GPS breadcrumb tracking
        this._startGpsTracking();
    }

    /** Clear only active-day intervals (timer/stats/gps), keep clock */
    _clearActiveIntervals() {
        if (this._statsInterval) {
            clearInterval(this._statsInterval);
            this._statsInterval = null;
        }
        if (this._gpsInterval) {
            clearInterval(this._gpsInterval);
            this._gpsInterval = null;
        }
    }

    /** Clear all intervals (for disconnectedCallback) */
    _clearAllIntervals() {
        if (this._clockInterval) {
            clearInterval(this._clockInterval);
            this._clockInterval = null;
        }
        this._clearActiveIntervals();
    }

    // ══════════════════════════════════════════════════════════════════
    //  UTILITIES
    // ══════════════════════════════════════════════════════════════════

    _padZero(num) {
        return num < 10 ? '0' + num : '' + num;
    }

    _showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    /** Extract user-facing message from Apex/LDS errors */
    _reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error.body && error.body.message) return error.body.message;
        if (error.body && error.body.fieldErrors) {
            const fieldMsgs = Object.values(error.body.fieldErrors)
                .flat()
                .map(e => e.message);
            if (fieldMsgs.length) return fieldMsgs.join('; ');
        }
        if (error.body && error.body.pageErrors) {
            const pageMsgs = error.body.pageErrors.map(e => e.message);
            if (pageMsgs.length) return pageMsgs.join('; ');
        }
        if (error.message) return error.message;
        if (Array.isArray(error)) {
            return error.map(e => this._reduceErrors(e)).join('; ');
        }
        return 'An unknown error occurred.';
    }
}