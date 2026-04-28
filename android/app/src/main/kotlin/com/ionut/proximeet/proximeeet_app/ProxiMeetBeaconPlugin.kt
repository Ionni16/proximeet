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
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.UUID
import kotlin.random.Random

/**
 * Production-oriented BLE beacon bridge for Flutter.
 *
 * What this class does well:
 * - Scans iBeacon packets from iOS and Android devices.
 * - Advertises iBeacon packets from Android when the chipset supports BLE advertising.
 * - Periodically switches to a small Android service-data advertisement as a fallback for Android peers.
 * - Emits structured status/error events instead of failing silently.
 * - Applies RSSI smoothing, rate limiting, self-beacon filtering, and scan watchdog diagnostics.
 *
 * Important platform limit:
 * Android background reliability still requires a ForegroundService owned by the app layer.
 * A MethodChannel plugin alone cannot guarantee scanning/advertising after the app is backgrounded,
 * killed, battery-optimized, or placed in Doze by the OEM.
 */
class ProxiMeetBeaconPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bluetoothManager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
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
    private var advertiseMode: String = "stopped"

    private var rawCallbacksInWindow: Int = 0
    private var iBeaconCandidatesInWindow: Int = 0
    private var matchingBeaconsInWindow: Int = 0
    private var androidServiceCandidatesInWindow: Int = 0

    private var advertisePulseRunnable: Runnable? = null
    private var watchdogRunnable: Runnable? = null
    private val random = Random(System.nanoTime())

    private val rssiSmoothed = mutableMapOf<String, Float>()
    private val lastEmitAt = mutableMapOf<String, Long>()
    private var lastPurgeAt = 0L

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

    private fun start(uuidString: String, major: Int, minor: Int, result: MethodChannel.Result) {
        if (major !in 0..65535 || minor !in 0..65535) {
            result.error("BAD_MAJOR_MINOR", "major/minor devono essere compresi tra 0 e 65535", null)
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

        if (!hasRequiredPermissions()) {
            result.error("NO_PERMISSION", missingPermissionsMessage(), null)
            return
        }

        if (!isLocationEnabled()) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                result.error("LOCATION_OFF", "Attiva la geolocalizzazione di sistema.", null)
                return
            }
            emit(
                mapOf(
                    "type" to "locationOffWarning",
                    "message" to "Geolocalizzazione disattivata: su Android 12+ provo comunque BLE scan/advertising.",
                    "platform" to "android"
                )
            )
        }

        stop()

        expectedUuid = parsedUuid
        myMajor = major
        myMinor = minor
        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        scanner = bluetoothAdapter.bluetoothLeScanner

        if (scanner == null) {
            stop()
            result.error("SCANNER_NULL", "BLE scanner non disponibile", null)
            return
        }

        if (!startScanning(parsedUuid)) {
            stop()
            result.error("SCAN_START_FALSE", "Lo scan BLE non è partito", null)
            return
        }

        if (bluetoothAdapter.isMultipleAdvertisementSupported && advertiser != null) {
            startAdvertising(parsedUuid, major, minor, AdvertiseKind.IBEACON)
            scheduleAdvertisePulses(parsedUuid, major, minor)
        } else {
            emit(
                mapOf(
                    "type" to "advertiseError",
                    "code" to "ADV_UNSUPPORTED",
                    "message" to "Questo dispositivo Android non supporta BLE advertising multiplo.",
                    "platform" to "android"
                )
            )
        }

        scheduleWatchdog(parsedUuid)

        result.success(true)
    }

    private fun hasRequiredPermissions(): Boolean {
        val fineLocationOk = hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            fineLocationOk &&
                hasPermission(Manifest.permission.BLUETOOTH_SCAN) &&
                hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE) &&
                hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            fineLocationOk
        }
    }

    private fun missingPermissionsMessage(): String {
        val missing = mutableListOf<String>()
        if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)) missing.add("ACCESS_FINE_LOCATION")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) missing.add("BLUETOOTH_SCAN")
            if (!hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE)) missing.add("BLUETOOTH_ADVERTISE")
            if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) missing.add("BLUETOOTH_CONNECT")
        }
        return "Permessi mancanti: ${missing.joinToString(", ")}"
    }

    private fun hasPermission(permission: String): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun isLocationEnabled(): Boolean {
        val locationManager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
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
    private fun startScanning(uuid: UUID): Boolean {
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

        rawCallbacksInWindow = 0
        iBeaconCandidatesInWindow = 0
        matchingBeaconsInWindow = 0
        androidServiceCandidatesInWindow = 0
        scanMode = "unfiltered"

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                rawCallbacksInWindow++
                handleScanResult(result, uuid)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                rawCallbacksInWindow += results.size
                results.forEach { handleScanResult(it, uuid) }
            }

            override fun onScanFailed(errorCode: Int) {
                scanMode = "stopped"
                emit(
                    mapOf(
                        "type" to "scanError",
                        "code" to scanErrorName(errorCode),
                        "rawCode" to errorCode,
                        "platform" to "android"
                    )
                )
            }
        }

        return try {
            scanner?.startScan(null, settings, scanCallback)
            emit(mapOf("type" to "scanStarted", "mode" to scanMode, "platform" to "android"))
            true
        } catch (e: Exception) {
            scanMode = "stopped"
            emit(
                mapOf(
                    "type" to "scanError",
                    "code" to "EXCEPTION",
                    "message" to (e.message ?: e.javaClass.simpleName),
                    "platform" to "android"
                )
            )
            false
        }
    }

    private fun handleScanResult(result: ScanResult, uuid: UUID) {
        val beacon = parseIBeacon(result, uuid) ?: parseAndroidServiceBeacon(result)
        if (beacon != null) emit(beacon)
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising(uuid: UUID, major: Int, minor: Int, kind: AdvertiseKind) {
        stopAdvertisingOnly()

        val a = advertiser ?: run {
            advertiseMode = "stopped"
            emit(
                mapOf(
                    "type" to "advertiseError",
                    "code" to "ADVERTISER_NULL",
                    "mode" to kind.value,
                    "platform" to "android"
                )
            )
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .setTimeout(0)
            .build()

        val data = when (kind) {
            AdvertiseKind.ANDROID_SERVICE -> AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceUuid(ANDROID_SERVICE_UUID)
                .addServiceData(ANDROID_SERVICE_UUID, buildAndroidServicePayload(major, minor))
                .build()

            AdvertiseKind.IBEACON -> AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addManufacturerData(APPLE_COMPANY_ID, buildIBeaconPayload(uuid, major, minor, DEFAULT_TX_POWER))
                .build()
        }

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                advertiseMode = kind.value
                emit(mapOf("type" to "advertiseStarted", "mode" to kind.value, "platform" to "android"))
            }

            override fun onStartFailure(errorCode: Int) {
                advertiseMode = "stopped"
                emit(
                    mapOf(
                        "type" to "advertiseError",
                        "code" to advertiseErrorName(errorCode),
                        "rawCode" to errorCode,
                        "mode" to kind.value,
                        "platform" to "android"
                    )
                )
            }
        }

        advertiseCallback = callback

        try {
            a.startAdvertising(settings, data, callback)
        } catch (e: Exception) {
            advertiseMode = "stopped"
            emit(
                mapOf(
                    "type" to "advertiseError",
                    "code" to "EXCEPTION",
                    "mode" to kind.value,
                    "message" to (e.message ?: e.javaClass.simpleName),
                    "platform" to "android"
                )
            )
        }
    }

    private fun scheduleAdvertisePulses(uuid: UUID, major: Int, minor: Int) {
        advertisePulseRunnable?.let { mainHandler.removeCallbacks(it) }

        val runnable = object : Runnable {
            override fun run() {
                if (expectedUuid == null) return

                ensureScanning(uuid)

                // Keep iBeacon as the dominant mode for iOS compatibility, but periodically
                // expose Android service-data packets so Android peers can still identify us
                // on devices/ROMs that handle manufacturer data poorly.
                startAdvertising(uuid, major, minor, AdvertiseKind.ANDROID_SERVICE)

                mainHandler.postDelayed({
                    if (expectedUuid != null) {
                        startAdvertising(uuid, major, minor, AdvertiseKind.IBEACON)
                    }
                }, ANDROID_SERVICE_PULSE_MS)

                val nextDelay = random.nextLong(ADVERTISE_INTERVAL_MIN_MS, ADVERTISE_INTERVAL_MAX_MS)
                mainHandler.postDelayed(this, nextDelay)
            }
        }

        advertisePulseRunnable = runnable
        mainHandler.postDelayed(runnable, random.nextLong(INITIAL_ADVERTISE_MIN_DELAY_MS, INITIAL_ADVERTISE_MAX_DELAY_MS))
    }

    private fun ensureScanning(uuid: UUID) {
        if (scanCallback == null || scanMode == "stopped") {
            startScanning(uuid)
        }
    }

    private fun scheduleWatchdog(uuid: UUID) {
        watchdogRunnable?.let { mainHandler.removeCallbacks(it) }

        val runnable = object : Runnable {
            override fun run() {
                if (expectedUuid == null) return

                emit(
                    mapOf(
                        "type" to "scanWatchdog",
                        "scanMode" to scanMode,
                        "advertiseMode" to advertiseMode,
                        "rawCallbacks" to rawCallbacksInWindow,
                        "iBeaconCandidates" to iBeaconCandidatesInWindow,
                        "matchingBeacons" to matchingBeaconsInWindow,
                        "androidServiceCandidates" to androidServiceCandidatesInWindow,
                        "platform" to "android"
                    )
                )

                if (scanMode == "stopped" || scanCallback == null) {
                    startScanning(uuid)
                } else {
                    rawCallbacksInWindow = 0
                    iBeaconCandidatesInWindow = 0
                    matchingBeaconsInWindow = 0
                    androidServiceCandidatesInWindow = 0
                }

                purgeOldRssiState()
                mainHandler.postDelayed(this, WATCHDOG_MS)
            }
        }

        watchdogRunnable = runnable
        mainHandler.postDelayed(runnable, WATCHDOG_MS)
    }

    private fun parseAndroidServiceBeacon(result: ScanResult): Map<String, Any>? {
        val bytes = result.scanRecord?.getServiceData(ANDROID_SERVICE_UUID) ?: return null
        androidServiceCandidatesInWindow++
        if (bytes.size < ANDROID_SERVICE_PAYLOAD_LENGTH) return null

        val major = ((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)
        val minor = ((bytes[2].toInt() and 0xFF) shl 8) or (bytes[3].toInt() and 0xFF)

        val rawRssi = result.rssi
        if (rawRssi == 0 || rawRssi < MIN_VALID_RSSI) return null

        return buildBeaconEvent(major, minor, rawRssi, "android_service")
    }

    private fun parseIBeacon(result: ScanResult, expectedUuid: UUID): Map<String, Any>? {
        val rawBytes = result.scanRecord?.bytes
        var iBeaconData: ByteArray? = null

        if (rawBytes != null && rawBytes.size >= IBEACON_PAYLOAD_LENGTH + 2) {
            for (i in 0..rawBytes.size - 25) {
                if (rawBytes[i] == 0x4C.toByte() &&
                    rawBytes[i + 1] == 0x00.toByte() &&
                    rawBytes[i + 2] == 0x02.toByte() &&
                    rawBytes[i + 3] == 0x15.toByte()
                ) {
                    iBeaconData = rawBytes.copyOfRange(i + 2, i + 25)
                    break
                }
            }
        }

        val bytes = iBeaconData ?: result.scanRecord?.getManufacturerSpecificData(APPLE_COMPANY_ID) ?: return null

        if (bytes.size < IBEACON_PAYLOAD_LENGTH) return null
        if (bytes[0] != 0x02.toByte() || bytes[1] != 0x15.toByte()) return null

        iBeaconCandidatesInWindow++

        val uuidBuffer = ByteBuffer.wrap(bytes, 2, 16)
        val foundUuid = UUID(uuidBuffer.long, uuidBuffer.long)
        if (foundUuid != expectedUuid) return null

        matchingBeaconsInWindow++

        val major = ((bytes[18].toInt() and 0xFF) shl 8) or (bytes[19].toInt() and 0xFF)
        val minor = ((bytes[20].toInt() and 0xFF) shl 8) or (bytes[21].toInt() and 0xFF)

        val rawRssi = result.rssi
        if (rawRssi == 0 || rawRssi < MIN_VALID_RSSI) return null

        return buildBeaconEvent(major, minor, rawRssi, "ibeacon")
    }

    private fun buildBeaconEvent(major: Int, minor: Int, rawRssi: Int, source: String): Map<String, Any>? {
        if (major == myMajor && minor == myMinor) return null

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
            "source" to source,
            "platform" to "android"
        )
    }

    private fun purgeOldRssiState() {
        val now = System.currentTimeMillis()
        if (now - lastPurgeAt < RSSI_PURGE_INTERVAL_MS) return
        lastPurgeAt = now

        val staleKeys = lastEmitAt
            .filterValues { now - it > RSSI_STATE_TTL_MS }
            .keys
            .toList()

        staleKeys.forEach {
            lastEmitAt.remove(it)
            rssiSmoothed.remove(it)
        }
    }

    private fun buildAndroidServicePayload(major: Int, minor: Int): ByteArray = byteArrayOf(
        ((major shr 8) and 0xFF).toByte(),
        (major and 0xFF).toByte(),
        ((minor shr 8) and 0xFF).toByte(),
        (minor and 0xFF).toByte()
    )

    private fun buildIBeaconPayload(uuid: UUID, major: Int, minor: Int, txPower: Int): ByteArray {
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
            // stopScan may throw if Bluetooth state changed during shutdown.
        }
        scanCallback = null
        scanMode = "stopped"
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertisingOnly() {
        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (_: Exception) {
            // stopAdvertising may throw if Bluetooth state changed during shutdown.
        }
        advertiseCallback = null
        advertiseMode = "stopped"
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        advertisePulseRunnable?.let { mainHandler.removeCallbacks(it) }
        watchdogRunnable?.let { mainHandler.removeCallbacks(it) }
        advertisePulseRunnable = null
        watchdogRunnable = null

        stopAdvertisingOnly()
        stopScanningOnly()

        advertiser = null
        scanner = null
        expectedUuid = null
        myMajor = -1
        myMinor = -1
        rawCallbacksInWindow = 0
        iBeaconCandidatesInWindow = 0
        matchingBeaconsInWindow = 0
        androidServiceCandidatesInWindow = 0
        rssiSmoothed.clear()
        lastEmitAt.clear()
    }

    private fun emit(payload: Map<String, Any>) {
        mainHandler.post {
            eventSink?.success(payload)
        }
    }

    private fun scanErrorName(code: Int): String = when (code) {
        ScanCallback.SCAN_FAILED_ALREADY_STARTED -> "SCAN_FAILED_ALREADY_STARTED"
        ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "SCAN_FAILED_APPLICATION_REGISTRATION_FAILED"
        ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED -> "SCAN_FAILED_FEATURE_UNSUPPORTED"
        ScanCallback.SCAN_FAILED_INTERNAL_ERROR -> "SCAN_FAILED_INTERNAL_ERROR"
        else -> "SCAN_FAILED_UNKNOWN"
    }

    private fun advertiseErrorName(code: Int): String = when (code) {
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "ADVERTISE_FAILED_ALREADY_STARTED"
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "ADVERTISE_FAILED_DATA_TOO_LARGE"
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "ADVERTISE_FAILED_FEATURE_UNSUPPORTED"
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "ADVERTISE_FAILED_INTERNAL_ERROR"
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "ADVERTISE_FAILED_TOO_MANY_ADVERTISERS"
        else -> "ADVERTISE_FAILED_UNKNOWN"
    }

    private enum class AdvertiseKind(val value: String) {
        IBEACON("ibeacon"),
        ANDROID_SERVICE("android_service")
    }

    companion object {
        private const val METHOD_CHANNEL = "proximeet/beacon"
        private const val EVENT_CHANNEL = "proximeet/beacon_events"

        private const val APPLE_COMPANY_ID = 0x004C
        private val ANDROID_SERVICE_UUID = ParcelUuid(UUID.fromString("0000ABCD-0000-1000-8000-00805F9B34FB"))

        private const val IBEACON_PAYLOAD_LENGTH = 23
        private const val ANDROID_SERVICE_PAYLOAD_LENGTH = 4
        private const val DEFAULT_TX_POWER = -59
        private const val MIN_VALID_RSSI = -105

        private const val EWMA_ALPHA = 0.25f
        private const val MIN_EMIT_INTERVAL_MS = 800L
        private const val RSSI_STATE_TTL_MS = 60_000L
        private const val RSSI_PURGE_INTERVAL_MS = 15_000L

        private const val WATCHDOG_MS = 5_000L
        private const val INITIAL_ADVERTISE_MIN_DELAY_MS = 1_200L
        private const val INITIAL_ADVERTISE_MAX_DELAY_MS = 3_500L
        private const val ADVERTISE_INTERVAL_MIN_MS = 6_000L
        private const val ADVERTISE_INTERVAL_MAX_MS = 11_000L
        private const val ANDROID_SERVICE_PULSE_MS = 900L
    }
}
