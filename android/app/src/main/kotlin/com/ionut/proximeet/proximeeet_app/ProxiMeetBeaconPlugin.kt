package com.ionut.proximeet.proximeeet_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

class ProxiMeetBeaconPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bluetoothManager =
        activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

    private val adapter: BluetoothAdapter?
        get() = bluetoothManager.adapter

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null

    private var expectedUuid: UUID? = null
    private var myMajor: Int = -1
    private var myMinor: Int = -1

    private var scanMode: String = "stopped"
    private var rawCallbacksInWindow: Int = 0
    private var iBeaconCandidatesInWindow: Int = 0
    private var matchingBeaconsInWindow: Int = 0

    // Log diagnostici extra
    private var appleManufacturerInWindow: Int = 0
    private var iBeaconPrefixInWindow: Int = 0
    private var malformedAppleInWindow: Int = 0
    private val manufacturerIdsInWindow = mutableMapOf<Int, Int>()

    private var filteredScanFailedOnce: Boolean = false
    private var zeroCallbackWindows: Int = 0
    private var useFilteredScan: Boolean = true

    private var cycleRunnable: Runnable? = null
    private var watchdogRunnable: Runnable? = null

    private val rssiSmoothed = mutableMapOf<String, Float>()
    private val lastEmitAt = mutableMapOf<String, Long>()

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val uuidString = call.argument<String>("uuid")
                val major = call.argument<Int>("major")
                val minor = call.argument<Int>("minor")

                if (uuidString.isNullOrBlank() || major == null || minor == null) {
                    result.error("BAD_ARGS", "uuid, major e minor sono obbligatori", null)
                    return
                }

                start(uuidString, major, minor, result)
            }

            "stop" -> {
                stop()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun start(
        uuidString: String,
        major: Int,
        minor: Int,
        result: MethodChannel.Result
    ) {
        if (major !in 0..65535 || minor !in 0..65535) {
            result.error(
                "BAD_MAJOR_MINOR",
                "major/minor devono essere compresi tra 0 e 65535",
                null
            )
            return
        }

        val parsedUuid = try {
            UUID.fromString(uuidString)
        } catch (_: Exception) {
            null
        }

        if (parsedUuid == null) {
            result.error("BAD_UUID", "UUID iBeacon non valido: $uuidString", null)
            return
        }

        val bluetoothAdapter = adapter
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth spento o non disponibile", null)
            return
        }

        if (!hasScanPermissions()) {
            result.error("NO_SCAN_PERMISSION", missingScanPermissionsMessage(), null)
            return
        }

        if (!isLocationEnabled()) {
            result.error(
                "LOCATION_OFF",
                "Attiva la geolocalizzazione di sistema: Android la richiede per lo scan BLE/iBeacon",
                null
            )
            return
        }

        stop()

        useFilteredScan = true
        expectedUuid = parsedUuid
        myMajor = major
        myMinor = minor

        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        scanner = bluetoothAdapter.bluetoothLeScanner

        emit(
            mapOf(
                "type" to "startRequested",
                "uuid" to parsedUuid.toString(),
                "major" to major,
                "minor" to minor,
                "btEnabled" to bluetoothAdapter.isEnabled,
                "multipleAdvertisementSupported" to bluetoothAdapter.isMultipleAdvertisementSupported,
                "hasAdvertiser" to (advertiser != null),
                "hasScanner" to (scanner != null),
                "locationEnabled" to isLocationEnabled(),
                "platform" to "android"
            )
        )

        if (scanner == null) {
            result.error("SCANNER_NULL", "BLE scanner non disponibile su questo dispositivo", null)
            return
        }

        val canAdvertise =
            bluetoothAdapter.isMultipleAdvertisementSupported &&
                advertiser != null &&
                hasAdvertisePermission()

        if (!canAdvertise) {
            emit(
                mapOf(
                    "type" to "advertiseUnavailable",
                    "reason" to advertiseUnavailableReason(bluetoothAdapter),
                    "platform" to "android"
                )
            )
        }

        val scanOk = startScanning(parsedUuid, filtered = true)
        if (!scanOk) {
            result.error("SCAN_START_FALSE", "Lo scan BLE non è partito", null)
            return
        }

        scheduleWatchdog(parsedUuid)

        if (canAdvertise) {
            scheduleAdvertisePulses(parsedUuid, major, minor)
        } else {
            emit(
                mapOf(
                    "type" to "androidBleMode",
                    "mode" to "scanOnly",
                    "platform" to "android"
                )
            )
        }

        result.success(true)
    }

    private fun hasScanPermissions(): Boolean {
        val fineLocationOk = hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            fineLocationOk &&
                hasPermission(Manifest.permission.BLUETOOTH_SCAN) &&
                hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            fineLocationOk
        }
    }

    private fun hasAdvertisePermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE)
    }

    private fun missingScanPermissionsMessage(): String {
        val missing = mutableListOf<String>()

        if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)) {
            missing.add("ACCESS_FINE_LOCATION")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) {
                missing.add("BLUETOOTH_SCAN")
            }
            if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
                missing.add("BLUETOOTH_CONNECT")
            }
        }

        return "Permessi scan mancanti: ${missing.joinToString(", ")}"
    }

    private fun advertiseUnavailableReason(bluetoothAdapter: BluetoothAdapter): String {
        return when {
            !hasAdvertisePermission() -> "BLUETOOTH_ADVERTISE permission missing"
            advertiser == null -> "BluetoothLeAdvertiser null"
            !bluetoothAdapter.isMultipleAdvertisementSupported -> "multiple advertisement unsupported"
            else -> "unknown"
        }
    }

    private fun hasPermission(permission: String): Boolean =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun isLocationEnabled(): Boolean {
        val locationManager =
            activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locationManager.isLocationEnabled
        } else {
            try {
                locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            } catch (_: Exception) {
                false
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScanning(uuid: UUID, filtered: Boolean): Boolean {
        stopScanningOnly()

        val settingsBuilder = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            settingsBuilder
                .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            settingsBuilder.setLegacy(true)
        }

        val settings = settingsBuilder.build()

        val filters: List<ScanFilter>? = if (filtered) {
            listOf(
                ScanFilter.Builder()
                    .setManufacturerData(
                        APPLE_COMPANY_ID,
                        byteArrayOf(0x02, 0x15),
                        byteArrayOf(0xFF.toByte(), 0xFF.toByte())
                    )
                    .build()
            )
        } else {
            null
        }

        resetWindowCounters()
        scanMode = if (filtered) "filtered" else "unfiltered"

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                rawCallbacksInWindow++
                parseIBeacon(result, uuid)?.let { emit(it) }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                rawCallbacksInWindow += results.size
                results.forEach { result ->
                    parseIBeacon(result, uuid)?.let { emit(it) }
                }
            }

            override fun onScanFailed(errorCode: Int) {
                emit(
                    mapOf(
                        "type" to "scanError",
                        "code" to errorCode,
                        "mode" to scanMode,
                        "platform" to "android"
                    )
                )

                if (scanMode == "filtered" && !filteredScanFailedOnce) {
                    filteredScanFailedOnce = true
                    useFilteredScan = false

                    emit(
                        mapOf(
                            "type" to "scanFallback",
                            "reason" to "scanFailed",
                            "from" to "filtered",
                            "to" to "unfiltered",
                            "platform" to "android"
                        )
                    )

                    startScanning(uuid, filtered = false)
                }
            }
        }

        return try {
            scanner?.startScan(filters, settings, scanCallback)

            emit(
                mapOf(
                    "type" to "scanStarted",
                    "mode" to scanMode,
                    "filter" to if (filtered) "appleIBeaconPrefix" else "none",
                    "platform" to "android"
                )
            )

            true
        } catch (e: Exception) {
            emit(
                mapOf(
                    "type" to "scanError",
                    "code" to "EXCEPTION",
                    "message" to (e.message ?: e.javaClass.simpleName),
                    "mode" to scanMode,
                    "platform" to "android"
                )
            )

            scanMode = "stopped"
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising(uuid: UUID, major: Int, minor: Int) {
        stopAdvertisingOnly()

        if (!hasAdvertisePermission()) {
            emit(
                mapOf(
                    "type" to "advertiseError",
                    "code" to "NO_ADVERTISE_PERMISSION",
                    "platform" to "android"
                )
            )
            return
        }

        val a = advertiser
        if (a == null) {
            emit(
                mapOf(
                    "type" to "advertiseError",
                    "code" to "ADVERTISER_NULL",
                    "platform" to "android"
                )
            )
            return
        }

        val payload = buildIBeaconPayload(uuid, major, minor, DEFAULT_TX_POWER)

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .setTimeout(0)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addManufacturerData(APPLE_COMPANY_ID, payload)
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                emit(
                    mapOf(
                        "type" to "advertiseStarted",
                        "mode" to "pulse",
                        "uuid" to uuid.toString(),
                        "major" to major,
                        "minor" to minor,
                        "payloadHex" to payload.toHex(),
                        "platform" to "android"
                    )
                )
            }

            override fun onStartFailure(errorCode: Int) {
                emit(
                    mapOf(
                        "type" to "advertiseError",
                        "code" to errorCode,
                        "platform" to "android"
                    )
                )
            }
        }

        try {
            a.startAdvertising(settings, data, advertiseCallback)
        } catch (e: Exception) {
            emit(
                mapOf(
                    "type" to "advertiseError",
                    "code" to "EXCEPTION",
                    "message" to (e.message ?: e.javaClass.simpleName),
                    "platform" to "android"
                )
            )
        }
    }

    private fun scheduleAdvertisePulses(uuid: UUID, major: Int, minor: Int) {
        cycleRunnable?.let { mainHandler.removeCallbacks(it) }

        val offset = computeDeterministicOffsetMs(major, minor)

        val runnable = object : Runnable {
            override fun run() {
                if (expectedUuid == null) return

                startAdvertising(uuid, major, minor)

                mainHandler.postDelayed({
                    stopAdvertisingOnly()
                }, ADVERTISE_PULSE_MS)

                mainHandler.postDelayed(this, ANDROID_CYCLE_MS)
            }
        }

        cycleRunnable = runnable
        mainHandler.postDelayed(runnable, offset)

        emit(
            mapOf(
                "type" to "androidBleMode",
                "mode" to "continuousScanWithAdvertisePulses",
                "cycleMs" to ANDROID_CYCLE_MS,
                "advertisePulseMs" to ADVERTISE_PULSE_MS,
                "firstAdvertiseOffsetMs" to offset,
                "platform" to "android"
            )
        )
    }

    private fun scheduleWatchdog(uuid: UUID) {
        watchdogRunnable?.let { mainHandler.removeCallbacks(it) }

        val runnable = object : Runnable {
            override fun run() {
                if (expectedUuid == null) return

                emit(
                    mapOf(
                        "type" to "scanWatchdog",
                        "mode" to scanMode,
                        "rawCallbacks" to rawCallbacksInWindow,
                        "iBeaconCandidates" to iBeaconCandidatesInWindow,
                        "matchingBeacons" to matchingBeaconsInWindow,
                        "appleManufacturer" to appleManufacturerInWindow,
                        "iBeaconPrefix" to iBeaconPrefixInWindow,
                        "malformedApple" to malformedAppleInWindow,
                        "manufacturerIds" to manufacturerIdsSummary(),
                        "useFilteredScan" to useFilteredScan,
                        "zeroCallbackWindows" to zeroCallbackWindows,
                        "platform" to "android"
                    )
                )

                if (rawCallbacksInWindow == 0) {
                    zeroCallbackWindows++

                    if (
                        scanMode == "filtered" &&
                        zeroCallbackWindows >= 2 &&
                        !filteredScanFailedOnce
                    ) {
                        filteredScanFailedOnce = true
                        useFilteredScan = false

                        emit(
                            mapOf(
                                "type" to "scanFallback",
                                "reason" to "filteredNoCallbacks",
                                "from" to "filtered",
                                "to" to "unfiltered",
                                "platform" to "android"
                            )
                        )

                        startScanning(uuid, filtered = false)
                    } else {
                        emit(
                            mapOf(
                                "type" to "scanRestart",
                                "reason" to "noCallbacks",
                                "nextFiltered" to useFilteredScan,
                                "platform" to "android"
                            )
                        )

                        startScanning(uuid, filtered = useFilteredScan)
                    }
                } else {
                    zeroCallbackWindows = 0
                    resetWindowCounters()
                }

                mainHandler.postDelayed(this, WATCHDOG_MS)
            }
        }

        watchdogRunnable = runnable
        mainHandler.postDelayed(runnable, WATCHDOG_MS)
    }

    private fun computeDeterministicOffsetMs(major: Int, minor: Int): Long {
        val maxOffset = max(0L, ANDROID_CYCLE_MS - ADVERTISE_PULSE_MS - 500L)
        val hash = ((major * 1103515245L) + minor + 12345L).let {
            if (it < 0) -it else it
        }
        return min(maxOffset, hash % max(1L, maxOffset))
    }

    private fun extractIBeaconBytes(result: ScanResult): ByteArray? {
        val rawBytes = result.scanRecord?.bytes ?: return null
        var offset = 0

        while (offset < rawBytes.size) {
            val length = rawBytes[offset].toInt() and 0xFF
            if (length == 0) break
            if (offset + length >= rawBytes.size) break

            val adType = rawBytes[offset + 1].toInt() and 0xFF

            if (adType == 0xFF && length >= 5) {
                val companyIdLow = rawBytes[offset + 2].toInt() and 0xFF
                val companyIdHigh = rawBytes[offset + 3].toInt() and 0xFF
                val companyId = (companyIdHigh shl 8) or companyIdLow

                manufacturerIdsInWindow[companyId] =
                    (manufacturerIdsInWindow[companyId] ?: 0) + 1

                val dataStart = offset + 4
                val dataLength = length - 3

                if (companyId == APPLE_COMPANY_ID) {
                    appleManufacturerInWindow++

                    if (
                        dataLength >= 2 &&
                        rawBytes[dataStart] == 0x02.toByte() &&
                        rawBytes[dataStart + 1] == 0x15.toByte()
                    ) {
                        iBeaconPrefixInWindow++

                        if (dataLength >= IBEACON_PAYLOAD_LENGTH) {
                            return rawBytes.copyOfRange(
                                dataStart,
                                dataStart + IBEACON_PAYLOAD_LENGTH
                            )
                        } else {
                            malformedAppleInWindow++
                        }
                    } else {
                        malformedAppleInWindow++
                    }
                }
            }

            offset += length + 1
        }

        return null
    }

    private fun parseIBeacon(result: ScanResult, expectedUuid: UUID): Map<String, Any>? {
        val bytes = extractIBeaconBytes(result) ?: return null

        iBeaconCandidatesInWindow++

        val uuidBuffer = ByteBuffer.wrap(bytes, 2, 16)
        val foundUuid = UUID(uuidBuffer.long, uuidBuffer.long)

        val major = ((bytes[18].toInt() and 0xFF) shl 8) or
            (bytes[19].toInt() and 0xFF)

        val minor = ((bytes[20].toInt() and 0xFF) shl 8) or
            (bytes[21].toInt() and 0xFF)

        val rawRssi = result.rssi

        if (foundUuid != expectedUuid) {
            emit(
                mapOf(
                    "type" to "iBeaconUuidMismatch",
                    "foundUuid" to foundUuid.toString(),
                    "expectedUuid" to expectedUuid.toString(),
                    "major" to major,
                    "minor" to minor,
                    "rssi" to rawRssi,
                    "platform" to "android"
                )
            )
            return null
        }

        matchingBeaconsInWindow++

        if (rawRssi == 0 || rawRssi < -105) {
            emit(
                mapOf(
                    "type" to "iBeaconIgnoredByRssi",
                    "major" to major,
                    "minor" to minor,
                    "rssi" to rawRssi,
                    "platform" to "android"
                )
            )
            return null
        }

        val key = "${major}_${minor}"
        val previous = rssiSmoothed[key]

        val smoothed = if (previous == null) {
            rawRssi.toFloat()
        } else {
            EWMA_ALPHA * rawRssi.toFloat() + (1f - EWMA_ALPHA) * previous
        }

        rssiSmoothed[key] = smoothed

        val now = System.currentTimeMillis()
        val last = lastEmitAt[key] ?: 0L

        if (now - last < MIN_EMIT_INTERVAL_MS) return null

        lastEmitAt[key] = now

        return mapOf(
            "type" to "beacon",
            "major" to major,
            "minor" to minor,
            "rssi" to smoothed.toInt(),
            "rawRssi" to rawRssi,
            "uuid" to foundUuid.toString(),
            "platform" to "android"
        )
    }

    private fun buildIBeaconPayload(
        uuid: UUID,
        major: Int,
        minor: Int,
        txPower: Int
    ): ByteArray {
        val buffer = ByteBuffer.allocate(IBEACON_PAYLOAD_LENGTH)

        buffer.put(0x02.toByte())
        buffer.put(0x15.toByte())
        buffer.putLong(uuid.mostSignificantBits)
        buffer.putLong(uuid.leastSignificantBits)
        buffer.put(((major shr 8) and 0xFF).toByte())
        buffer.put((major and 0xFF).toByte())
        buffer.put(((minor shr 8) and 0xFF).toByte())
        buffer.put((minor and 0xFF).toByte())
        buffer.put(txPower.toByte())

        return buffer.array()
    }

    @SuppressLint("MissingPermission")
    private fun stopScanningOnly() {
        try {
            scanCallback?.let { scanner?.stopScan(it) }
        } catch (_: Exception) {
        }

        scanCallback = null
        scanMode = "stopped"
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertisingOnly() {
        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (_: Exception) {
        }

        advertiseCallback = null
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        cycleRunnable?.let { mainHandler.removeCallbacks(it) }
        watchdogRunnable?.let { mainHandler.removeCallbacks(it) }

        cycleRunnable = null
        watchdogRunnable = null

        stopAdvertisingOnly()
        stopScanningOnly()

        advertiser = null
        scanner = null

        expectedUuid = null
        myMajor = -1
        myMinor = -1

        filteredScanFailedOnce = false
        zeroCallbackWindows = 0
        useFilteredScan = true

        resetWindowCounters()

        rssiSmoothed.clear()
        lastEmitAt.clear()
    }

    private fun resetWindowCounters() {
        rawCallbacksInWindow = 0
        iBeaconCandidatesInWindow = 0
        matchingBeaconsInWindow = 0

        appleManufacturerInWindow = 0
        iBeaconPrefixInWindow = 0
        malformedAppleInWindow = 0
        manufacturerIdsInWindow.clear()
    }

    private fun manufacturerIdsSummary(): String {
        return manufacturerIdsInWindow
            .entries
            .sortedByDescending { it.value }
            .take(10)
            .joinToString(",") {
                "0x${it.key.toString(16).padStart(4, '0')}:${it.value}"
            }
    }

    private fun ByteArray.toHex(): String {
        return joinToString("") {
            "%02x".format(it.toInt() and 0xFF)
        }
    }

    private fun emit(payload: Map<String, Any>) {
        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "proximeet/beacon"
        private const val EVENT_CHANNEL = "proximeet/beacon_events"

        private const val APPLE_COMPANY_ID = 0x004C
        private const val IBEACON_PAYLOAD_LENGTH = 23
        private const val DEFAULT_TX_POWER = -59

        private const val EWMA_ALPHA = 0.25f
        private const val MIN_EMIT_INTERVAL_MS = 800L

        private const val WATCHDOG_MS = 5000L
        private const val ANDROID_CYCLE_MS = 6000L
        private const val ADVERTISE_PULSE_MS = 1000L
    }
}