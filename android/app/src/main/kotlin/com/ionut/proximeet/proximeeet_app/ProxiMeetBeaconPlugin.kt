package com.ionut.proximeet.proximeeet_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
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
import java.util.Locale
import java.util.UUID

/**
 * Plugin che fa da ponte tra Flutter e il BLE nativo Android.
 *
 * Ogni telefono fa due cose contemporaneamente:
 * - GATT server: fa advertising del Service UUID e mette il token in una characteristic leggibile.
 * - GATT client: scansiona, si connette ai peer, legge la loro characteristic e manda il token a Dart.
 *
 * Note importanti rispetto alla versione precedente:
 * - Lo scan Android non usa filtro hardware: molti device rilevano iOS più in fretta senza filtro.
 * - I retry sulla connessione sono controllati: niente loop infinito di connect/discover/close.
 * - Un solo discoverServices per connessione.
 * - Gli eventi diagnostici coprono tutto il percorso fino a tokenReadComplete/gattPeer.
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
    private var gattServer: BluetoothGattServer? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var isAdvertisingStarted: Boolean = false

    private var serviceUuid: UUID = DEFAULT_SERVICE_UUID
    private var tokenCharacteristicUuid: UUID = DEFAULT_TOKEN_CHARACTERISTIC_UUID
    private var currentToken: String = ""
    private var currentTokenBytes: ByteArray = ByteArray(0)
    private var isStarted: Boolean = false

    private val activeGatts = mutableMapOf<String, BluetoothGatt>()
    private val discoveryStarted = mutableSetOf<String>()
    private val resultRssi = mutableMapOf<String, Int>()
    private val lastAttemptAt = mutableMapOf<String, Long>()
    private val lastSuccessAt = mutableMapOf<String, Long>()

    private val connectRetryMs = 2500L
    private val successfulReadThrottleMs = 2500L
    private val scanRestartMs = 15000L

    private val scanRestartRunnable = object : Runnable {
        override fun run() {
            if (!isStarted) return
            restartScanningBestEffort()
            mainHandler.postDelayed(this, scanRestartMs)
        }
    }

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val serviceUuidString = call.argument<String>("serviceUuid") ?: DEFAULT_SERVICE_UUID.toString()
                val characteristicUuidString = call.argument<String>("tokenCharacteristicUuid") ?: DEFAULT_TOKEN_CHARACTERISTIC_UUID.toString()
                val token = call.argument<String>("token")

                if (token.isNullOrBlank()) {
                    result.error("BAD_TOKEN", "token obbligatorio", null)
                    return
                }

                try {
                    start(serviceUuidString, characteristicUuidString, token, result)
                } catch (e: Exception) {
                    result.error("START_FAILED", e.message, null)
                }
            }

            "stop" -> {
                stop()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission")
    private fun start(
        serviceUuidString: String,
        characteristicUuidString: String,
        token: String,
        result: MethodChannel.Result
    ) {
        val bluetoothAdapter = adapter
        if (bluetoothAdapter == null) {
            result.error("NO_BLUETOOTH", "BluetoothAdapter non disponibile", null)
            return
        }
        if (!bluetoothAdapter.isEnabled) {
            result.error("BLUETOOTH_OFF", "Bluetooth spento", null)
            return
        }
        if (!hasScanPermissions()) {
            result.error("MISSING_SCAN_PERMISSION", missingScanPermissionsMessage(), null)
            return
        }
        if (!hasAdvertisePermission()) {
            result.error("MISSING_ADVERTISE_PERMISSION", "BLUETOOTH_ADVERTISE mancante", null)
            return
        }
        if (!hasConnectPermission()) {
            result.error("MISSING_CONNECT_PERMISSION", "BLUETOOTH_CONNECT mancante", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && !isLocationEnabled()) {
            result.error("LOCATION_OFF", "Localizzazione disattivata: richiesta per BLE scan su Android <= 11", null)
            return
        }

        stopInternal(emitStopped = false)

        serviceUuid = UUID.fromString(serviceUuidString)
        tokenCharacteristicUuid = UUID.fromString(characteristicUuidString)
        currentToken = token
        currentTokenBytes = token.toByteArray(Charsets.UTF_8)
        isStarted = true

        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        scanner = bluetoothAdapter.bluetoothLeScanner

        val serverOk = startGattServer()
        // L'advertising parte solo dopo che il GATT service è pronto (callback onServiceAdded).
        // Se partisse prima, un peer potrebbe connettersi prima che il service sia visibile.
        val advOk = false
        val scanOk = startScanning()

        mainHandler.removeCallbacks(scanRestartRunnable)
        mainHandler.postDelayed(scanRestartRunnable, scanRestartMs)

        emit(mapOf(
            "type" to "startRequested",
            "transport" to "ble_gatt",
            "platform" to "android",
            "gattServer" to serverOk,
            "advertising" to advOk,
            "scanning" to scanOk,
            "serviceUuid" to serviceUuid.toString(),
            "characteristicUuid" to tokenCharacteristicUuid.toString(),
            "tokenLength" to token.length
        ))

        result.success(serverOk || advOk || scanOk)
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        stopInternal(emitStopped = true)
    }

    @SuppressLint("MissingPermission")
    private fun stopInternal(emitStopped: Boolean) {
        mainHandler.removeCallbacks(scanRestartRunnable)

        scanCallback?.let { cb ->
            try { scanner?.stopScan(cb) } catch (_: Exception) {}
        }
        scanCallback = null

        advertiseCallback?.let { cb ->
            try { advertiser?.stopAdvertising(cb) } catch (_: Exception) {}
        }
        advertiseCallback = null
        isAdvertisingStarted = false

        activeGatts.values.forEach { gatt ->
            try { gatt.disconnect() } catch (_: Exception) {}
            try { gatt.close() } catch (_: Exception) {}
        }
        activeGatts.clear()
        discoveryStarted.clear()

        try { gattServer?.clearServices() } catch (_: Exception) {}
        try { gattServer?.close() } catch (_: Exception) {}
        gattServer = null

        resultRssi.clear()
        lastAttemptAt.clear()
        lastSuccessAt.clear()
        isStarted = false

        if (emitStopped) emit(mapOf("type" to "stopped", "transport" to "ble_gatt", "platform" to "android"))
    }

    @SuppressLint("MissingPermission")
    private fun startGattServer(): Boolean {
        if (!hasConnectPermission()) return false

        val server = bluetoothManager.openGattServer(activity, gattServerCallback) ?: return false
        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val characteristic = BluetoothGattCharacteristic(
            tokenCharacteristicUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        @Suppress("DEPRECATION")
        characteristic.value = currentTokenBytes

        service.addCharacteristic(characteristic)
        val added = server.addService(service)
        gattServer = server

        emit(mapOf(
            "type" to "gattServerStarted",
            "transport" to "ble_gatt",
            "platform" to "android",
            "addServiceRequested" to added
        ))
        return true
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            val ok = status == BluetoothGatt.GATT_SUCCESS
            emit(mapOf(
                "type" to if (ok) "gattServiceReady" else "gattServiceAddFailed",
                "transport" to "ble_gatt",
                "platform" to "android",
                "status" to status,
                "serviceUuid" to service.uuid.toString()
            ))

            if (ok && service.uuid == serviceUuid) {
                mainHandler.post { startAdvertising() }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid != tokenCharacteristicUuid) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }

            val value = when {
                offset < 0 -> null
                offset > currentTokenBytes.size -> null
                offset == currentTokenBytes.size -> ByteArray(0)
                else -> currentTokenBytes.copyOfRange(offset, currentTokenBytes.size)
            }

            if (value == null) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }

            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            emit(mapOf(
                "type" to "tokenReadServed",
                "transport" to "ble_gatt",
                "platform" to "android",
                "bytes" to currentTokenBytes.size
            ))
        }
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising(): Boolean {
        val adv = advertiser ?: return false
        if (!hasAdvertisePermission()) return false
        if (isAdvertisingStarted || advertiseCallback != null) return true

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                isAdvertisingStarted = true
                emit(mapOf("type" to "advertisingStarted", "transport" to "ble_gatt", "platform" to "android"))
            }

            override fun onStartFailure(errorCode: Int) {
                isAdvertisingStarted = false
                advertiseCallback = null
                emit(mapOf("type" to "advertisingFailed", "transport" to "ble_gatt", "platform" to "android", "errorCode" to errorCode))
            }
        }

        return try {
            adv.startAdvertising(settings, data, advertiseCallback)
            true
        } catch (e: Exception) {
            emit(mapOf("type" to "advertisingException", "platform" to "android", "error" to e.message))
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScanning(): Boolean {
        val bleScanner = scanner ?: return false
        if (!hasScanPermissions()) return false

        val settingsBuilder = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            settingsBuilder
                .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
        }

        scanCallback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) = handleScanResult(result)
            override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { handleScanResult(it) }
            override fun onScanFailed(errorCode: Int) {
                emit(mapOf("type" to "scanFailed", "transport" to "ble_gatt", "platform" to "android", "errorCode" to errorCode))
            }
        }

        return try {
            // Nessun filtro hardware: su molti Android il filtro per UUID 128-bit perde i pacchetti iOS o rallenta.
            // Il filtraggio lo facciamo a mano controllando scanRecord.serviceUuids.
            bleScanner.startScan(null, settingsBuilder.build(), scanCallback)
            emit(mapOf("type" to "scanStarted", "transport" to "ble_gatt", "platform" to "android", "filter" to "manual_service_uuid"))
            true
        } catch (e: Exception) {
            emit(mapOf("type" to "scanException", "platform" to "android", "error" to e.message))
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun restartScanningBestEffort() {
        val cb = scanCallback ?: return
        val bleScanner = scanner ?: return
        try { bleScanner.stopScan(cb) } catch (_: Exception) {}
        try {
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .setReportDelay(0)
                .apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                        setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                        setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
                    }
                }
                .build()
            bleScanner.startScan(null, settings, cb)
            emit(mapOf("type" to "scanRestarted", "transport" to "ble_gatt", "platform" to "android"))
        } catch (e: Exception) {
            emit(mapOf("type" to "scanRestartException", "platform" to "android", "error" to e.message))
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleScanResult(result: ScanResult) {
        if (!isStarted || !hasConnectPermission()) return

        val record = result.scanRecord ?: return
        val advertisedServices = record.serviceUuids?.map { it.uuid } ?: emptyList()
        if (!advertisedServices.contains(serviceUuid)) return

        val device = result.device ?: return
        val address = device.address ?: return
        val now = System.currentTimeMillis()

        if (now - (lastSuccessAt[address] ?: 0L) < successfulReadThrottleMs) return
        if (now - (lastAttemptAt[address] ?: 0L) < connectRetryMs) return
        if (activeGatts.containsKey(address)) return

        resultRssi[address] = result.rssi
        lastAttemptAt[address] = now

        emit(mapOf(
            "type" to "scanMatch",
            "transport" to "ble_gatt",
            "platform" to "android",
            "address" to redactAddress(address),
            "rssi" to result.rssi,
            "services" to advertisedServices.map { it.toString() }
        ))

        try {
            val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(activity, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(activity, false, gattCallback)
            }
            if (gatt != null) activeGatts[address] = gatt
        } catch (e: Exception) {
            emit(mapOf("type" to "connectException", "platform" to "android", "error" to e.message))
            activeGatts.remove(address)
            discoveryStarted.remove(address)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val address = gatt.device.address
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emit(mapOf("type" to "connectionStateFailed", "transport" to "ble_gatt", "platform" to "android", "address" to redactAddress(address), "status" to status, "newState" to newState))
                closeGatt(address, gatt)
                return
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (discoveryStarted.add(address)) {
                    emit(mapOf("type" to "connected", "transport" to "ble_gatt", "platform" to "android", "address" to redactAddress(address)))
                    val started = try { gatt.discoverServices() } catch (_: Exception) { false }
                    emit(mapOf("type" to "discoverServicesStarted", "transport" to "ble_gatt", "platform" to "android", "started" to started, "address" to redactAddress(address)))
                    if (!started) closeGatt(address, gatt)
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                closeGatt(address, gatt)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val address = gatt.device.address
            val services = gatt.services?.map { it.uuid.toString().lowercase(Locale.US) } ?: emptyList()
            emit(mapOf("type" to "servicesDiscovered", "transport" to "ble_gatt", "platform" to "android", "status" to status, "count" to services.size, "services" to services, "address" to redactAddress(address)))

            if (status != BluetoothGatt.GATT_SUCCESS) {
                closeGatt(address, gatt)
                return
            }

            val characteristic = gatt.getService(serviceUuid)?.getCharacteristic(tokenCharacteristicUuid)
            if (characteristic == null) {
                emit(mapOf("type" to "tokenCharacteristicMissing", "transport" to "ble_gatt", "platform" to "android", "address" to redactAddress(address), "serviceUuid" to serviceUuid.toString(), "characteristicUuid" to tokenCharacteristicUuid.toString()))
                closeGatt(address, gatt)
                return
            }

            val started = try { gatt.readCharacteristic(characteristic) } catch (_: Exception) { false }
            emit(mapOf("type" to "tokenReadStarted", "transport" to "ble_gatt", "platform" to "android", "started" to started, "address" to redactAddress(address)))
            if (!started) closeGatt(address, gatt)
        }

        @Deprecated("Deprecated in Android 13, kept for API compatibility")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            handleCharacteristicRead(gatt, characteristic.uuid, characteristic.value, status)
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            handleCharacteristicRead(gatt, characteristic.uuid, value, status)
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleCharacteristicRead(gatt: BluetoothGatt, characteristicUuid: UUID, value: ByteArray?, status: Int) {
        val address = gatt.device.address
        val bytes = value?.size ?: 0
        emit(mapOf("type" to "tokenReadComplete", "transport" to "ble_gatt", "platform" to "android", "status" to status, "bytes" to bytes, "address" to redactAddress(address)))

        if (status == BluetoothGatt.GATT_SUCCESS && characteristicUuid == tokenCharacteristicUuid) {
            val token = if (value != null) String(value, Charsets.UTF_8).trim() else ""
            if (token.isNotEmpty() && token != currentToken) {
                lastSuccessAt[address] = System.currentTimeMillis()
                emit(mapOf(
                    "type" to "gattPeer",
                    "transport" to "ble_gatt",
                    "platform" to "android",
                    "token" to token,
                    "rssi" to (resultRssi[address] ?: -90)
                ))
            } else if (token == currentToken) {
                emit(mapOf("type" to "selfTokenIgnored", "transport" to "ble_gatt", "platform" to "android", "address" to redactAddress(address)))
            }
        }
        closeGatt(address, gatt)
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt(address: String, gatt: BluetoothGatt) {
        activeGatts.remove(address)
        discoveryStarted.remove(address)
        try { gatt.disconnect() } catch (_: Exception) {}
        try { gatt.close() } catch (_: Exception) {}
    }

    private fun emit(payload: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(payload) }
    }

    private fun hasScanPermissions(): Boolean {
        val locationOk = hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPermission(Manifest.permission.BLUETOOTH_SCAN) && hasPermission(Manifest.permission.BLUETOOTH_CONNECT) && locationOk
        } else {
            locationOk
        }
    }

    private fun hasConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || hasPermission(Manifest.permission.BLUETOOTH_CONNECT)

    private fun hasAdvertisePermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || hasPermission(Manifest.permission.BLUETOOTH_ADVERTISE)

    private fun missingScanPermissionsMessage(): String {
        val missing = mutableListOf<String>()
        if (!hasPermission(Manifest.permission.ACCESS_FINE_LOCATION)) missing.add("ACCESS_FINE_LOCATION")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN)) missing.add("BLUETOOTH_SCAN")
            if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) missing.add("BLUETOOTH_CONNECT")
        }
        return "Permessi scan mancanti: ${missing.joinToString(", ")}"
    }

    private fun hasPermission(permission: String): Boolean =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun isLocationEnabled(): Boolean {
        val locationManager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            locationManager.isLocationEnabled
        } else {
            try {
                locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) || locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun redactAddress(address: String?): String {
        if (address.isNullOrBlank()) return "unknown"
        val parts = address.split(":")
        return if (parts.size >= 2) "**:**:**:**:${parts[parts.size - 2]}:${parts.last()}" else "***"
    }

    companion object {
        private const val METHOD_CHANNEL = "proximeet/beacon"
        private const val EVENT_CHANNEL = "proximeet/beacon_events"
        private val DEFAULT_SERVICE_UUID: UUID = UUID.fromString("F2703C30-FA18-4173-8599-016070383C81")
        private val DEFAULT_TOKEN_CHARACTERISTIC_UUID: UUID = UUID.fromString("F2703C31-FA18-4173-8599-016070383C81")
    }
}
