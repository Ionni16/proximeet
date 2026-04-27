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
    private val rssiSmoothed = mutableMapOf<String, Float>()
    private val EWMA_ALPHA = 0.25f

    // Rate-limit emit: max 1 evento ogni MIN_EMIT_INTERVAL_MS per beacon.
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

    private fun start(uuidString: String, major: Int, minor: Int, result: MethodChannel.Result) {
        if (major !in 0..65535 || minor !in 0..65535) {
            result.error("BAD_MAJOR_MINOR", "major/minor devono essere compresi tra 0 e 65535", null)
            return
        }

        val parsedUuid = try { UUID.fromString(uuidString) } catch (_: Exception) { null }
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

    private fun hasPermission(permission: String): Boolean =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun startAdvertising(uuid: UUID, major: Int, minor: Int) {
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
                eventSink?.success(mapOf("type" to "advertiseStarted", "platform" to "android"))
            }
            override fun onStartFailure(errorCode: Int) {
                eventSink?.success(mapOf("type" to "advertiseError", "code" to errorCode, "platform" to "android"))
            }
        }

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private fun startScanning(uuid: UUID) {
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)
            .build()

        // ── FIX: scan senza ScanFilter ────────────────────────────────────────
        // ScanFilter.setManufacturerData(APPLE_COMPANY_ID, ...) viene silenziosamente
        // ignorato/bloccato su Xiaomi, Samsung, Huawei, OnePlus ecc.
        // Scan senza filtri → parseIBeacon filtra per UUID (sicuro).
        // ─────────────────────────────────────────────────────────────────────
        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                parseIBeacon(result, uuid)?.let { eventSink?.success(it) }
            }
            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { parseIBeacon(it, uuid)?.let { ev -> eventSink?.success(ev) } }
            }
            override fun onScanFailed(errorCode: Int) {
                eventSink?.success(mapOf("type" to "scanError", "code" to errorCode, "platform" to "android"))
            }
        }

        scanner?.startScan(emptyList(), settings, scanCallback)
    }

    private fun parseIBeacon(result: ScanResult, expectedUuid: UUID): Map<String, Any>? {
        // ── Tentativo 1: API standard ─────────────────────────────────────────
        // getManufacturerSpecificData restituisce null su alcuni OEM Android
        // che strippano i dati Apple a livello di driver BLE.
        val bytes = result.scanRecord?.getManufacturerSpecificData(APPLE_COMPANY_ID)
        // ── Tentativo 2: parsing raw bytes ────────────────────────────────────
        // Leggiamo direttamente i byte grezzi del pacchetto BLE advertisement.
        // Questo bypassa il filtro OEM e funziona anche quando l'API restituisce null.
            ?: parseManufacturerDataFromRawBytes(result)
            ?: return null

        // Valida formato iBeacon
        if (bytes.size < IBEACON_PAYLOAD_LENGTH) return null
        if (bytes[0] != 0x02.toByte() || bytes[1] != 0x15.toByte()) return null

        // Valida UUID
        val uuidBuffer = ByteBuffer.wrap(bytes, 2, 16)
        val foundUuid = UUID(uuidBuffer.long, uuidBuffer.long)
        if (foundUuid != expectedUuid) return null

        val major = ((bytes[18].toInt() and 0xFF) shl 8) or (bytes[19].toInt() and 0xFF)
        val minor = ((bytes[20].toInt() and 0xFF) shl 8) or (bytes[21].toInt() and 0xFF)

        if (major == myMajor && minor == myMinor) return null

        val rawRssi = result.rssi
        if (rawRssi == 0 || rawRssi < -100) return null

        // ── EWMA smoothing ──────────────────────────────────────────────────
        val key = "${major}_${minor}"
        val prev = rssiSmoothed[key]
        val smoothed = if (prev == null) rawRssi.toFloat()
                       else EWMA_ALPHA * rawRssi.toFloat() + (1f - EWMA_ALPHA) * prev
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
            "platform" to "android"
        )
    }

    /**
     * Parsing manuale dei byte grezzi dell'advertisement BLE.
     *
     * Struttura AD (Advertising Data):
     *   [length][type][data...]  ripetuto per ogni record
     *
     * Per Manufacturer Specific Data (type = 0xFF):
     *   [length][0xFF][company_id_low][company_id_high][data...]
     *
     * Restituisce i byte DOPO company_id (stessa struttura di
     * getManufacturerSpecificData), o null se non trovato.
     */
    private fun parseManufacturerDataFromRawBytes(result: ScanResult): ByteArray? {
        val rawBytes = result.scanRecord?.bytes ?: return null
        var offset = 0

        while (offset < rawBytes.size) {
            val length = rawBytes[offset].toInt() and 0xFF
            if (length == 0) break
            if (offset + length >= rawBytes.size) break

            val adType = rawBytes[offset + 1].toInt() and 0xFF

            // 0xFF = Manufacturer Specific Data
            if (adType == 0xFF && length >= 3) {
                val companyIdLow  = rawBytes[offset + 2].toInt() and 0xFF
                val companyIdHigh = rawBytes[offset + 3].toInt() and 0xFF
                val companyId = (companyIdHigh shl 8) or companyIdLow

                if (companyId == APPLE_COMPANY_ID) {
                    // I dati iniziano dopo i 2 byte company_id.
                    // length comprende il byte type (0xFF) e i 2 byte company_id,
                    // quindi i dati utili sono (length - 3) byte.
                    val dataStart = offset + 4
                    val dataLength = length - 3
                    if (dataLength > 0 && dataStart + dataLength <= rawBytes.size) {
                        return rawBytes.copyOfRange(dataStart, dataStart + dataLength)
                    }
                }
            }

            offset += length + 1
        }

        return null
    }

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

    fun stop() {
        try { advertiseCallback?.let { advertiser?.stopAdvertising(it) } } catch (_: Exception) {}
        try { scanCallback?.let { scanner?.stopScan(it) } } catch (_: Exception) {}
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
