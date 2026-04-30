import Flutter
import UIKit
import CoreBluetooth

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let registrar = self.registrar(forPlugin: "ProxiMeetBeaconPlugin") {
      ProxiMeetBeaconPlugin.register(with: registrar.messenger())
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    ProxiMeetBeaconPlugin.shared.stop()
    super.applicationWillTerminate(application)
  }
}

/// ProxiMeet BLE GATT bidirezionale.
///
/// Foreground/radar mode:
/// - Peripheral: pubblica un GATT service fisso e una characteristic read-only con token temporaneo.
/// - Central: scansiona lo stesso service, si connette, legge la characteristic e invia gattPeer a Dart.
///
/// Nota critica: su iOS l'advertising parte SOLO dopo il callback didAdd service.
/// Se si avvia l'advertising prima, Android può connettersi quando il service GATT non è ancora pronto
/// e chiudere la connessione senza detection.
final class ProxiMeetBeaconPlugin: NSObject,
                                    FlutterStreamHandler,
                                    CBPeripheralManagerDelegate,
                                    CBCentralManagerDelegate,
                                    CBPeripheralDelegate {
  static let shared = ProxiMeetBeaconPlugin()

  static func register(with messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(name: "proximeet/beacon", binaryMessenger: messenger)
    let eventChannel = FlutterEventChannel(name: "proximeet/beacon_events", binaryMessenger: messenger)

    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "BAD_ARGS", message: "Argomenti mancanti", details: call.arguments))
          return
        }

        let serviceUuid = (args["serviceUuid"] as? String) ?? "F2703C30-FA18-4173-8599-016070383C81"
        let characteristicUuid = (args["tokenCharacteristicUuid"] as? String) ?? "F2703C31-FA18-4173-8599-016070383C81"

        guard let token = args["token"] as? String, !token.isEmpty else {
          result(FlutterError(code: "BAD_TOKEN", message: "token obbligatorio", details: call.arguments))
          return
        }

        ProxiMeetBeaconPlugin.shared.start(
          serviceUuidString: serviceUuid,
          characteristicUuidString: characteristicUuid,
          token: token,
          result: result
        )

      case "stop":
        ProxiMeetBeaconPlugin.shared.stop()
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    eventChannel.setStreamHandler(ProxiMeetBeaconPlugin.shared)
  }

  private var eventSink: FlutterEventSink?

  private var peripheralManager: CBPeripheralManager?
  private var centralManager: CBCentralManager?

  private var serviceUuid: CBUUID?
  private var tokenCharacteristicUuid: CBUUID?
  private var currentTokenData: Data?
  private var isStarted = false
  private var gattServiceAdded = false
  private var isAdvertising = false
  private var isScanning = false

  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var peripheralRssi: [UUID: Int] = [:]
  private var connectionInFlight = Set<UUID>()
  private var lastAttemptAt: [UUID: TimeInterval] = [:]
  private var lastReadAt: [UUID: TimeInterval] = [:]

  private var scanRestartTimer: Timer?

  private let connectRetrySeconds: TimeInterval = 2.0
  private let successfulReadThrottleSeconds: TimeInterval = 2.5
  private let scanRestartSeconds: TimeInterval = 12.0

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func start(
    serviceUuidString: String,
    characteristicUuidString: String,
    token: String,
    result: @escaping FlutterResult
  ) {
    guard UUID(uuidString: serviceUuidString) != nil else {
      result(FlutterError(code: "BAD_SERVICE_UUID", message: "Service UUID non valido", details: serviceUuidString))
      return
    }
    guard UUID(uuidString: characteristicUuidString) != nil else {
      result(FlutterError(code: "BAD_CHARACTERISTIC_UUID", message: "Characteristic UUID non valido", details: characteristicUuidString))
      return
    }
    guard let data = token.data(using: .utf8), data.count > 0, data.count <= 180 else {
      result(FlutterError(code: "BAD_TOKEN", message: "Token non valido o troppo lungo", details: token.count))
      return
    }

    stopInternal(emitStopped: false)

    serviceUuid = CBUUID(string: serviceUuidString)
    tokenCharacteristicUuid = CBUUID(string: characteristicUuidString)
    currentTokenData = data
    isStarted = true
    gattServiceAdded = false
    isAdvertising = false
    isScanning = false

    peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    centralManager = CBCentralManager(delegate: self, queue: .main)

    emit([
      "type": "startRequested",
      "transport": "ble_gatt",
      "platform": "ios",
      "serviceUuid": serviceUuidString,
      "characteristicUuid": characteristicUuidString,
      "tokenLength": token.count
    ])

    result(true)
  }

  func stop() {
    stopInternal(emitStopped: true)
  }

  private func stopInternal(emitStopped: Bool) {
    scanRestartTimer?.invalidate()
    scanRestartTimer = nil

    if let central = centralManager {
      central.stopScan()
      for peripheral in discoveredPeripherals.values {
        central.cancelPeripheralConnection(peripheral)
      }
    }

    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()

    centralManager = nil
    peripheralManager = nil
    discoveredPeripherals.removeAll()
    peripheralRssi.removeAll()
    connectionInFlight.removeAll()
    lastAttemptAt.removeAll()
    lastReadAt.removeAll()
    isStarted = false
    gattServiceAdded = false
    isAdvertising = false
    isScanning = false

    if emitStopped {
      emit(["type": "stopped", "transport": "ble_gatt", "platform": "ios"])
    }
  }

  // MARK: - Peripheral/GATT server

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard isStarted else { return }

    guard peripheral.state == .poweredOn else {
      emit(["type": "peripheralState", "state": stateName(peripheral.state), "platform": "ios"])
      return
    }

    createGattService()
  }

  private func createGattService() {
    guard let peripheralManager = peripheralManager,
          let serviceUuid = serviceUuid,
          let tokenCharacteristicUuid = tokenCharacteristicUuid else { return }

    peripheralManager.stopAdvertising()
    peripheralManager.removeAllServices()
    gattServiceAdded = false
    isAdvertising = false

    let characteristic = CBMutableCharacteristic(
      type: tokenCharacteristicUuid,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )

    let service = CBMutableService(type: serviceUuid, primary: true)
    service.characteristics = [characteristic]
    peripheralManager.add(service)

    emit(["type": "gattServiceAddRequested", "transport": "ble_gatt", "platform": "ios"])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    if let error = error {
      emit(["type": "gattServiceAddFailed", "transport": "ble_gatt", "platform": "ios", "error": error.localizedDescription])
      return
    }

    gattServiceAdded = true
    emit(["type": "gattServiceReady", "transport": "ble_gatt", "platform": "ios", "serviceUuid": service.uuid.uuidString])
    startAdvertisingIfReady()
  }

  private func startAdvertisingIfReady() {
    guard isStarted,
          gattServiceAdded,
          !isAdvertising,
          let peripheralManager = peripheralManager,
          peripheralManager.state == .poweredOn,
          let serviceUuid = serviceUuid else { return }

    // Payload minimale: niente LocalName. Con UUID 128-bit + local name si rischia overflow/scan-response
    // e alcuni Android con scan filter diventano lenti o instabili.
    peripheralManager.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [serviceUuid]
    ])
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      isAdvertising = false
      emit(["type": "advertisingFailed", "transport": "ble_gatt", "platform": "ios", "error": error.localizedDescription])
      return
    }

    isAdvertising = true
    emit(["type": "advertisingStarted", "transport": "ble_gatt", "platform": "ios"])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard let tokenCharacteristicUuid = tokenCharacteristicUuid,
          request.characteristic.uuid == tokenCharacteristicUuid,
          let data = currentTokenData else {
      peripheral.respond(to: request, withResult: .attributeNotFound)
      return
    }

    if request.offset > data.count {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }

    request.value = data.subdata(in: request.offset..<data.count)
    peripheral.respond(to: request, withResult: .success)

    emit(["type": "tokenReadServed", "transport": "ble_gatt", "platform": "ios", "bytes": data.count])
  }

  // MARK: - Central/GATT client

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard isStarted else { return }

    guard central.state == .poweredOn else {
      emit(["type": "centralState", "state": stateName(central.state), "platform": "ios"])
      return
    }

    startScanning()
    startScanRestartTimer()
  }

  private func startScanning() {
    guard let centralManager = centralManager, let serviceUuid = serviceUuid else { return }

    centralManager.stopScan()
    centralManager.scanForPeripherals(
      withServices: [serviceUuid],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )

    isScanning = true
    emit(["type": "scanStarted", "transport": "ble_gatt", "platform": "ios"])
  }

  private func startScanRestartTimer() {
    scanRestartTimer?.invalidate()
    scanRestartTimer = Timer.scheduledTimer(withTimeInterval: scanRestartSeconds, repeats: true) { [weak self] _ in
      guard let self = self, self.isStarted, let central = self.centralManager, central.state == .poweredOn else { return }
      central.stopScan()
      self.isScanning = false
      self.startScanning()
      self.emit(["type": "scanRestarted", "transport": "ble_gatt", "platform": "ios"])
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String : Any],
    rssi RSSI: NSNumber
  ) {
    guard isStarted else { return }

    let rssi = RSSI.intValue
    guard rssi > -100 else { return }

    let id = peripheral.identifier
    let now = Date().timeIntervalSince1970

    if let lastRead = lastReadAt[id], now - lastRead < successfulReadThrottleSeconds { return }
    if let lastAttempt = lastAttemptAt[id], now - lastAttempt < connectRetrySeconds { return }
    if connectionInFlight.contains(id) { return }

    peripheralRssi[id] = rssi
    discoveredPeripherals[id] = peripheral
    peripheral.delegate = self
    connectionInFlight.insert(id)
    lastAttemptAt[id] = now

    emit(["type": "scanMatch", "transport": "ble_gatt", "platform": "ios", "rssi": rssi])

    if peripheral.state == .connected {
      peripheral.discoverServices([serviceUuid].compactMap { $0 })
    } else {
      central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: false])
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    emit(["type": "connected", "transport": "ble_gatt", "platform": "ios"])
    peripheral.discoverServices([serviceUuid].compactMap { $0 })
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    connectionInFlight.remove(peripheral.identifier)
    emit(["type": "connectFailed", "transport": "ble_gatt", "platform": "ios", "error": error?.localizedDescription ?? "unknown"])
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    connectionInFlight.remove(peripheral.identifier)
    if let error = error {
      emit(["type": "disconnected", "transport": "ble_gatt", "platform": "ios", "error": error.localizedDescription])
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
      finishPeripheral(peripheral, event: ["type": "discoverServicesFailed", "transport": "ble_gatt", "platform": "ios", "error": error.localizedDescription])
      return
    }

    guard let tokenCharacteristicUuid = tokenCharacteristicUuid else {
      finishPeripheral(peripheral, event: ["type": "badState", "transport": "ble_gatt", "platform": "ios", "stage": "missingCharacteristicUuid"])
      return
    }

    let services = peripheral.services ?? []
    emit(["type": "servicesDiscovered", "transport": "ble_gatt", "platform": "ios", "count": services.count])

    guard !services.isEmpty else {
      finishPeripheral(peripheral, event: ["type": "serviceMissing", "transport": "ble_gatt", "platform": "ios"])
      return
    }

    for service in services {
      peripheral.discoverCharacteristics([tokenCharacteristicUuid], for: service)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error = error {
      finishPeripheral(peripheral, event: ["type": "discoverCharacteristicsFailed", "transport": "ble_gatt", "platform": "ios", "error": error.localizedDescription])
      return
    }

    guard let tokenCharacteristicUuid = tokenCharacteristicUuid else { return }

    for characteristic in service.characteristics ?? [] where characteristic.uuid == tokenCharacteristicUuid {
      emit(["type": "tokenReadStarted", "transport": "ble_gatt", "platform": "ios"])
      peripheral.readValue(for: characteristic)
      return
    }

    finishPeripheral(peripheral, event: ["type": "tokenCharacteristicMissing", "transport": "ble_gatt", "platform": "ios", "serviceUuid": service.uuid.uuidString])
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error = error {
      finishPeripheral(peripheral, event: ["type": "readFailed", "transport": "ble_gatt", "platform": "ios", "error": error.localizedDescription])
      return
    }

    guard let tokenCharacteristicUuid = tokenCharacteristicUuid,
          characteristic.uuid == tokenCharacteristicUuid,
          let data = characteristic.value,
          let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else {
      finishPeripheral(peripheral, event: ["type": "tokenReadEmpty", "transport": "ble_gatt", "platform": "ios"])
      return
    }

    lastReadAt[peripheral.identifier] = Date().timeIntervalSince1970
    let rssi = peripheralRssi[peripheral.identifier] ?? -90

    emit(["type": "tokenReadComplete", "transport": "ble_gatt", "platform": "ios", "bytes": data.count])

    let myToken = currentTokenData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    if token != myToken {
      emit([
        "type": "gattPeer",
        "transport": "ble_gatt",
        "platform": "ios",
        "token": token,
        "rssi": rssi
      ])
    }

    finishPeripheral(peripheral, event: nil)
  }

  private func finishPeripheral(_ peripheral: CBPeripheral, event: [String: Any]?) {
    if let event = event { emit(event) }
    connectionInFlight.remove(peripheral.identifier)
    if let central = centralManager, peripheral.state == .connected || peripheral.state == .connecting {
      central.cancelPeripheralConnection(peripheral)
    }
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  private func stateName(_ state: CBManagerState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .resetting: return "resetting"
    case .unsupported: return "unsupported"
    case .unauthorized: return "unauthorized"
    case .poweredOff: return "poweredOff"
    case .poweredOn: return "poweredOn"
    @unknown default: return "unknown"
    }
  }
}
