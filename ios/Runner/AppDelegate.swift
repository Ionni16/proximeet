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

/// BLE GATT bidirezionale:
/// - Peripheral/GATT server: pubblica un Service UUID fisso e una characteristic leggibile con token temporaneo.
/// - Central/GATT client: scansiona lo stesso Service UUID, si connette e legge la characteristic token.
final class ProxiMeetBeaconPlugin: NSObject,
                                    FlutterStreamHandler,
                                    CBPeripheralManagerDelegate,
                                    CBCentralManagerDelegate,
                                    CBPeripheralDelegate {
  static let shared = ProxiMeetBeaconPlugin()

  static func register(with messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "proximeet/beacon",
      binaryMessenger: messenger
    )

    let eventChannel = FlutterEventChannel(
      name: "proximeet/beacon_events",
      binaryMessenger: messenger
    )

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

  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var peripheralRssi: [UUID: Int] = [:]
  private var lastReadAt: [UUID: TimeInterval] = [:]

  private let readThrottleSeconds: TimeInterval = 3.0

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
    guard let data = token.data(using: .utf8), data.count <= 180 else {
      result(FlutterError(code: "BAD_TOKEN", message: "Token non valido o troppo lungo", details: token.count))
      return
    }

    stopInternal(emitStopped: false)

    serviceUuid = CBUUID(string: serviceUuidString)
    tokenCharacteristicUuid = CBUUID(string: characteristicUuidString)
    currentTokenData = data
    isStarted = true

    peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    centralManager = CBCentralManager(delegate: self, queue: .main)

    emit([
      "type": "startRequested",
      "transport": "ble_gatt",
      "platform": "ios",
      "serviceUuid": serviceUuidString,
      "tokenLength": token.count
    ])

    result(true)
  }

  func stop() {
    stopInternal(emitStopped: true)
  }

  private func stopInternal(emitStopped: Bool) {
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
    lastReadAt.removeAll()
    isStarted = false

    if emitStopped {
      emit(["type": "stopped", "transport": "ble_gatt", "platform": "ios"])
    }
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard isStarted else { return }

    guard peripheral.state == .poweredOn else {
      emit(["type": "peripheralState", "state": stateName(peripheral.state), "platform": "ios"])
      return
    }

    startGattServerAndAdvertising()
  }

  private func startGattServerAndAdvertising() {
    guard let peripheralManager = peripheralManager,
          let serviceUuid = serviceUuid,
          let tokenCharacteristicUuid = tokenCharacteristicUuid else { return }

    peripheralManager.removeAllServices()

    let characteristic = CBMutableCharacteristic(
      type: tokenCharacteristicUuid,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )

    let service = CBMutableService(type: serviceUuid, primary: true)
    service.characteristics = [characteristic]
    peripheralManager.add(service)

    peripheralManager.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [serviceUuid],
      CBAdvertisementDataLocalNameKey: "ProxiMeet"
    ])

    emit(["type": "advertisingStarted", "transport": "ble_gatt", "platform": "ios"])
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard let tokenCharacteristicUuid = tokenCharacteristicUuid,
          request.characteristic.uuid == tokenCharacteristicUuid,
          let data = currentTokenData else {
      peripheral.respond(to: request, withResult: .attributeNotFound)
      return
    }

    request.value = data
    peripheral.respond(to: request, withResult: .success)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard isStarted else { return }

    guard central.state == .poweredOn else {
      emit(["type": "centralState", "state": stateName(central.state), "platform": "ios"])
      return
    }

    startScanning()
  }

  private func startScanning() {
    guard let centralManager = centralManager, let serviceUuid = serviceUuid else { return }

    centralManager.stopScan()
    centralManager.scanForPeripherals(
      withServices: [serviceUuid],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )

    emit(["type": "scanStarted", "transport": "ble_gatt", "platform": "ios"])
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

    peripheralRssi[peripheral.identifier] = rssi

    let now = Date().timeIntervalSince1970
    if let last = lastReadAt[peripheral.identifier], now - last < readThrottleSeconds {
      return
    }

    discoveredPeripherals[peripheral.identifier] = peripheral
    peripheral.delegate = self

    if peripheral.state == .connected {
      peripheral.discoverServices([serviceUuid].compactMap { $0 })
    } else {
      central.connect(peripheral, options: nil)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([serviceUuid].compactMap { $0 })
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    emit(["type": "connectFailed", "platform": "ios", "error": error?.localizedDescription ?? "unknown"])
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
      emit(["type": "discoverServicesFailed", "platform": "ios", "error": error.localizedDescription])
      return
    }

    guard let tokenCharacteristicUuid = tokenCharacteristicUuid else { return }

    for service in peripheral.services ?? [] {
      peripheral.discoverCharacteristics([tokenCharacteristicUuid], for: service)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error = error {
      emit(["type": "discoverCharacteristicsFailed", "platform": "ios", "error": error.localizedDescription])
      return
    }

    guard let tokenCharacteristicUuid = tokenCharacteristicUuid else { return }

    for characteristic in service.characteristics ?? [] where characteristic.uuid == tokenCharacteristicUuid {
      peripheral.readValue(for: characteristic)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error = error {
      emit(["type": "readFailed", "platform": "ios", "error": error.localizedDescription])
      return
    }

    guard let tokenCharacteristicUuid = tokenCharacteristicUuid,
          characteristic.uuid == tokenCharacteristicUuid,
          let data = characteristic.value,
          let token = String(data: data, encoding: .utf8),
          !token.isEmpty else { return }

    lastReadAt[peripheral.identifier] = Date().timeIntervalSince1970
    let rssi = peripheralRssi[peripheral.identifier] ?? -90

    emit([
      "type": "gattPeer",
      "transport": "ble_gatt",
      "platform": "ios",
      "token": token,
      "rssi": rssi
    ])

    if let central = centralManager {
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
