package com.ionut.proximeet.proximeeet_app

import android.Manifest
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
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.UUID

class ProxiMeetBeaconPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)

    private var eventSink: EventChannel.EventSink? = null

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

    // ── EWMA RSSI smoothing ──────────────────────────────────────────────────
    // Chiave: "major_minor", valore: RSSI smoothed (float per precisione).
    // alpha=0.25 → 25% peso al nuovo valore, 75% all'EWMA precedente.
    // Stabilizza il segnale senza introdurre troppa latenza alla risposta.
    private val rssiSmoothed = mutableMapOf<String, Float>()
    private val EWMA_ALPHA = 0.25f

    // Rate-limit emit: non inviare lo stesso beacon a Flutter più di
    // una volta ogni MIN_EMIT_INTERVAL_MS (evita flood UI inutile).
    private val lastEmitAt = mutableMapOf<String, Long>()
    private val MIN_EMIT_INTERVAL_MS = 800L

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

        if (!hasRequiredPermissions()) {
            result.error("NO_PERMISSION", "Permessi Bluetooth/Location mancanti", null)
            return
        }

        val bluetoothAdapter = adapter
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            result.error("BT_OFF", "Bluetooth spento o non disponibile", null)
            return
        }

        if (!bluetoothAdapter.isMultipleAdvertisementSupported) {
            result.error("ADV_UNSUPPORTED", "BLE advertising non supportato su questo dispositivo", null)
            return
        }

        stop()

        expectedUuid = parsedUuid
        myMajor = major
        myMinor = minor
        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        scanner = bluetoothAdapter.bluetoothLeScanner

        startAdvertising(parsedUuid, major, minor)
        startScanning(parsedUuid)

        result.success(true)
    }

    private fun hasRequiredPermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_SCAN) &&
                hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE) &&
                hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun startAdvertising(uuid: UUID, major: Int, minor: Int) {
        val payload = buildIBeaconPayload(
            uuid = uuid,
            major = major,
            minor = minor,
            txPower = DEFAULT_TX_POWER
        )

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
                eventSink?.success(
                    mapOf(
                        "type" to "advertiseStarted",
                        "platform" to "android"
                    )
                )
            }

            override fun onStartFailure(errorCode: Int) {
                eventSink?.success(
                    mapOf(
                        "type" to "advertiseError",
                        "code" to errorCode,
                        "platform" to "android"
                    )
                )
            }
        }

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private fun startScanning(uuid: UUID) {
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)
            .build()

        // ── FIX CRITICO: NESSUN ScanFilter ─────────────────────────────────
        //
        // BUG ORIGINALE: usare ScanFilter.setManufacturerData(APPLE_COMPANY_ID, ...)
        // causa un problema documentato e diffuso su Android: molti OEM
        // (Xiaomi, Samsung, Huawei, OnePlus, Motorola...) filtrano o bloccano
        // a livello di driver BLE i pacchetti con manufacturer company ID Apple
        // (0x004C), probabilmente per evitare che app di terze parti
        // intercettino traffico AirDrop/AirPods. Il risultato è che lo scan
        // non restituisce nessun risultato anche quando ci sono beacon vicini,
        // e il bug si manifesta in modo asimmetrico: un device vede l'altro
        // ma non viceversa, a seconda del modello del telefono.
        //
        // FIX: scan senza filtri HW (emptyList()). Tutti i pacchetti BLE
        // arrivano al callback e parseIBeacon filtra per UUID → corretto
        // e sicuro. L'impatto sulla batteria è trascurabile per un'app
        // di networking in foreground.
        // ────────────────────────────────────────────────────────────────────
        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                parseIBeacon(result, uuid)?.let { eventSink?.success(it) }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { scanResult ->
                    parseIBeacon(scanResult, uuid)?.let { eventSink?.success(it) }
                }
            }

            override fun onScanFailed(errorCode: Int) {
                eventSink?.success(
                    mapOf(
                        "type" to "scanError",
                        "code" to errorCode,
                        "platform" to "android"
                    )
                )
            }
        }

        scanner?.startScan(emptyList(), settings, scanCallback)
    }

    private fun parseIBeacon(result: ScanResult, expectedUuid: UUID): Map<String, Any>? {
        val bytes = result.scanRecord?.getManufacturerSpecificData(APPLE_COMPANY_ID) ?: return null

        if (bytes.size < IBEACON_PAYLOAD_LENGTH) return null
        if (bytes[0] != 0x02.toByte() || bytes[1] != 0x15.toByte()) return null

        val uuidBuffer = ByteBuffer.wrap(bytes, 2, 16)
        val foundUuid = UUID(uuidBuffer.long, uuidBuffer.long)
        if (foundUuid != expectedUuid) return null

        val major = ((bytes[18].toInt() and 0xFF) shl 8) or
            (bytes[19].toInt() and 0xFF)
        val minor = ((bytes[20].toInt() and 0xFF) shl 8) or
            (bytes[21].toInt() and 0xFF)

        // Evita di rilevare sé stessi.
        if (major == myMajor && minor == myMinor) return null

        // Scarta RSSI non validi (0 = non disponibile, < -100 = rumore puro).
        val rawRssi = result.rssi
        if (rawRssi == 0 || rawRssi < -100) return null

        // ── EWMA smoothing ──────────────────────────────────────────────────
        // Ogni packet BLE ha RSSI variabile (±10-20 dBm è normale).
        // L'EWMA stabilizza la distanza percepita senza latenza eccessiva.
        val key = "${major}_${minor}"
        val prev = rssiSmoothed[key]
        val smoothed: Float = if (prev == null) {
            rawRssi.toFloat()
        } else {
            EWMA_ALPHA * rawRssi.toFloat() + (1f - EWMA_ALPHA) * prev
        }
        rssiSmoothed[key] = smoothed
        // ────────────────────────────────────────────────────────────────────

        // Rate-limit emit: un beacon attivo può inviare ogni 100-300ms.
        // Limitare a MAX 1 evento/800ms per evitare flood alla UI Flutter.
        val now = System.currentTimeMillis()
        val last = lastEmitAt[key] ?: 0L
        if (now - last < MIN_EMIT_INTERVAL_MS) return null
        lastEmitAt[key] = now

        return mapOf(
            "type" to "beacon",
            "major" to major,
            "minor" to minor,
            "rssi" to smoothed.toInt(),
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

    fun stop() {
        try {
            advertiseCallback?.let { callback ->
                advertiser?.stopAdvertising(callback)
            }
        } catch (_: Exception) {
        }

        try {
            scanCallback?.let { callback ->
                scanner?.stopScan(callback)
            }
        } catch (_: Exception) {
        }

        advertiseCallback = null
        scanCallback = null
        advertiser = null
        scanner = null
        expectedUuid = null
        myMajor = -1
        myMinor = -1
        rssiSmoothed.clear()
        lastEmitAt.clear()
    }

    companion object {
        private const val METHOD_CHANNEL = "proximeet/beacon"
        private const val EVENT_CHANNEL = "proximeet/beacon_events"
        private const val APPLE_COMPANY_ID = 0x004C
        private const val IBEACON_PAYLOAD_LENGTH = 23
        private const val DEFAULT_TX_POWER = -59
    }
}
