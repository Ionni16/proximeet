import Flutter
import UIKit
import CoreBluetooth
import CoreLocation

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

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    ProxiMeetBeaconPlugin.shared.applicationDidBecomeActive()
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    ProxiMeetBeaconPlugin.shared.stop()
    super.applicationWillTerminate(application)
  }
}

final class ProxiMeetBeaconPlugin: NSObject, FlutterStreamHandler,
                                    CLLocationManagerDelegate, CBPeripheralManagerDelegate {

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
        guard
          let args = call.arguments as? [String: Any],
          let uuidString = args["uuid"] as? String,
          let major = args["major"] as? Int,
          let minor = args["minor"] as? Int
        else {
          result(FlutterError(code: "BAD_ARGS",
                              message: "uuid, major e minor sono obbligatori",
                              details: call.arguments))
          return
        }
        ProxiMeetBeaconPlugin.shared.start(uuidString: uuidString,
                                            major: major,
                                            minor: minor,
                                            result: result)
      case "stop":
        ProxiMeetBeaconPlugin.shared.stop()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    eventChannel.setStreamHandler(ProxiMeetBeaconPlugin.shared)
  }

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private var locationManager:   CLLocationManager?
  private var peripheralManager: CBPeripheralManager?
  private var rxRegion:          CLBeaconRegion?
  private var txRegion:          CLBeaconRegion?
  private var advertisingPayload: [String: Any]?
  private var eventSink:         FlutterEventSink?

  private var ownMajor:    CLBeaconMajorValue = 0
  private var ownMinor:    CLBeaconMinorValue = 0
  private var currentUuid: UUID?

  private var isStarted   = false
  private var isRanging   = false
  private var isAdvertising = false

  private let regionIdentifier = "com.ionut.proximeet.proximeeet_app.ibeacon"

  private var rssiSmoothed:    [String: Double]      = [:]
  private var lastEmitAt:      [String: TimeInterval] = [:]
  private let ewmaAlpha:       Double = 0.25
  private let minEmitInterval: TimeInterval = 0.8
  private let minValidRssi     = -100

  private var stateReportTimer: Timer?

  func start(uuidString: String, major: Int, minor: Int, result: @escaping FlutterResult) {
    guard let uuid = UUID(uuidString: uuidString) else {
      result(FlutterError(code: "BAD_UUID",
                          message: "UUID iBeacon non valido",
                          details: uuidString))
      return
    }
    guard (0...65535).contains(major), (0...65535).contains(minor) else {
      result(FlutterError(code: "BAD_MAJOR_MINOR",
                          message: "major/minor devono essere 0...65535",
                          details: ["major": major, "minor": minor]))
      return
    }
    guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else {
      result(FlutterError(code: "BEACON_UNSUPPORTED",
                          message: "Dispositivo non supporta iBeacon monitoring.",
                          details: nil))
      return
    }

    guard CLLocationManager.locationServicesEnabled() else {
      result(FlutterError(code: "LOCATION_SERVICES_OFF",
                          message: "Servizi di localizzazione disattivati a livello di sistema.",
                          details: nil))
      return
    }

    if isStarted, currentUuid == uuid,
       Int(ownMajor) == major, Int(ownMinor) == minor {
      ensureRangingRunning()
      ensureAdvertisingRunning()
      result(true)
      return
    }

    stopInternal(keepEventSink: true)

    isStarted   = true
    currentUuid = uuid
    ownMajor    = CLBeaconMajorValue(major)
    ownMinor    = CLBeaconMinorValue(minor)
    rssiSmoothed.removeAll()
    lastEmitAt.removeAll()

    let manager = CLLocationManager()
    manager.delegate = self
    manager.pausesLocationUpdatesAutomatically = false
    manager.distanceFilter = kCLDistanceFilterNone
    manager.allowsBackgroundLocationUpdates   = false
    manager.showsBackgroundLocationIndicator  = false
    locationManager = manager

    let rx = CLBeaconRegion(uuid: uuid, identifier: regionIdentifier)
    rx.notifyOnEntry             = true
    rx.notifyOnExit              = true
    rx.notifyEntryStateOnDisplay = true
    rxRegion = rx

    let tx = CLBeaconRegion(uuid: uuid,
                            major: ownMajor,
                            minor: ownMinor,
                            identifier: regionIdentifier + ".tx")
    txRegion = tx

    if let payload = tx.peripheralData(withMeasuredPower: nil) as? [String: Any] {
      advertisingPayload = payload
    } else {
      advertisingPayload = nil
      emit(["type": "advertiseError",
            "message": "Cast payload iBeacon fallito",
            "platform": "ios"])
    }

    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)

    // FIX AUTORIZZAZIONI FOREGROUND/BACKGROUND
    let status = currentAuthorizationStatus(for: manager)
    switch status {
    case .notDetermined:
      manager.requestWhenInUseAuthorization() // Richiesta robusta per iOS 14+
    case .authorizedWhenInUse, .authorizedAlways:
      ensureRangingRunning()
    case .restricted, .denied:
      emit(["type": "locationAuthorization",
            "status": status.rawValue, "platform": "ios"])
      result(FlutterError(code: "LOCATION_DENIED",
                          message: "Autorizzazione localizzazione negata o limitata.",
                          details: ["status": status.rawValue]))
      return
    @unknown default:
      emit(["type": "locationAuthorization",
            "status": status.rawValue, "platform": "ios"])
      result(FlutterError(code: "LOCATION_UNKNOWN_STATUS",
                          message: "Stato autorizzazione localizzazione non gestito.",
                          details: ["status": status.rawValue]))
      return
    }

    startStateReportTimer()
    result(true)
  }

  func applicationDidBecomeActive() {
    guard isStarted else { return }
    ensureRangingRunning()
    ensureAdvertisingRunning()
  }

  func stop() {
    stopInternal(keepEventSink: true)
  }

  private func stopInternal(keepEventSink: Bool) {
    stopStateReportTimer()

    if isAdvertising, let pm = peripheralManager {
      pm.stopAdvertising()
    }
    isAdvertising = false
    peripheralManager = nil

    if let manager = locationManager {
      if let rx = rxRegion {
        if isRanging {
          if #available(iOS 13.0, *) {
            manager.stopRangingBeacons(satisfying: rx.beaconIdentityConstraint)
          } else {
            manager.stopRangingBeacons(in: rx)
          }
        }
        manager.stopMonitoring(for: rx)
      }
      for region in manager.monitoredRegions
          where region.identifier.hasPrefix(regionIdentifier) {
        manager.stopMonitoring(for: region)
      }
      manager.delegate = nil
    }
    isRanging        = false
    locationManager  = nil

    rxRegion           = nil
    txRegion           = nil
    advertisingPayload = nil
    currentUuid        = nil
    isStarted          = false

    rssiSmoothed.removeAll()
    lastEmitAt.removeAll()

    if !keepEventSink { eventSink = nil }
  }

  private func ensureRangingRunning() {
    guard isStarted, !isRanging,
          let manager = locationManager,
          let rx = rxRegion else { return }

    let status = currentAuthorizationStatus(for: manager)
    guard status == .authorizedAlways || status == .authorizedWhenInUse else {
      emit(["type": "locationAuthorization",
            "status": status.rawValue, "platform": "ios"])
      return
    }

    manager.startMonitoring(for: rx)
    manager.requestState(for: rx)
    if #available(iOS 13.0, *) {
      manager.startRangingBeacons(satisfying: rx.beaconIdentityConstraint)
    } else {
      manager.startRangingBeacons(in: rx)
    }
    isRanging = true
    emit(["type": "scanStarted", "mode": "ibeacon_ranging", "platform": "ios"])
  }

  private func ensureAdvertisingRunning() {
    guard isStarted, !isAdvertising,
          let pm = peripheralManager,
          pm.state == .poweredOn,
          let payload = advertisingPayload else { return }

    pm.startAdvertising(payload)
  }

  private func startStateReportTimer() {
    stopStateReportTimer()
    stateReportTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) {
      [weak self] _ in
      guard let self, self.isStarted else { return }
      self.emit([
        "type": "stateWatchdog",
        "bluetoothState":  self.peripheralManager?.state.rawValue ?? -1,
        "locationStatus":  self.locationManager.map {
          self.currentAuthorizationStatus(for: $0).rawValue
        } ?? -1,
        "isRanging":     self.isRanging,
        "isAdvertising": self.isAdvertising,
        "platform": "ios"
      ])
      self.ensureRangingRunning()
      self.ensureAdvertisingRunning()
    }
  }

  private func stopStateReportTimer() {
    stateReportTimer?.invalidate()
    stateReportTimer = nil
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      emit(["type": "bluetoothOn", "platform": "ios"])
      ensureAdvertisingRunning()
    case .poweredOff:
      emit(["type": "bluetoothOff", "platform": "ios"])
      isAdvertising = false
    case .unauthorized:
      emit(["type": "bluetoothUnauthorized", "platform": "ios"])
      isAdvertising = false
    case .unsupported:
      emit(["type": "bluetoothUnsupported", "platform": "ios"])
      isAdvertising = false
    case .resetting:
      emit(["type": "bluetoothResetting", "platform": "ios"])
      isAdvertising = false
    default:
      emit(["type": "bluetoothState",
            "state": peripheral.state.rawValue, "platform": "ios"])
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager,
                         didStartAdvertising error: Error?) {
    if let error = error {
      isAdvertising = false
      emit(["type": "advertiseError",
            "message": error.localizedDescription, "platform": "ios"])
    } else {
      isAdvertising = true
      emit(["type": "advertiseStarted", "mode": "ibeacon", "platform": "ios"])
    }
  }

  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    handleAuthorization(currentAuthorizationStatus(for: manager), manager: manager)
  }

  func locationManager(_ manager: CLLocationManager,
                       didChangeAuthorization status: CLAuthorizationStatus) {
    handleAuthorization(status, manager: manager)
  }

  private func handleAuthorization(_ status: CLAuthorizationStatus,
                                    manager: CLLocationManager) {
    emit(["type": "locationAuthorization",
          "status": status.rawValue, "platform": "ios"])
    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      ensureRangingRunning()
    case .denied, .restricted:
      isRanging = false
      emit(["type": "locationError", "code": "LOCATION_DENIED",
            "message": "Autorizzazione localizzazione negata o limitata.",
            "platform": "ios"])
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    @unknown default:
      break
    }
  }

  private func currentAuthorizationStatus(for manager: CLLocationManager) -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) { return manager.authorizationStatus }
    return CLLocationManager.authorizationStatus()
  }

  func locationManager(_ manager: CLLocationManager,
                       didDetermineState state: CLRegionState,
                       for region: CLRegion) {
    emit(["type": "regionState", "state": state.rawValue,
          "identifier": region.identifier, "platform": "ios"])
  }

  func locationManager(_ manager: CLLocationManager,
                       monitoringDidFailFor region: CLRegion?,
                       withError error: Error) {
    isRanging = false
    emit(["type": "monitoringError",
          "identifier": region?.identifier ?? "unknown",
          "message": error.localizedDescription, "platform": "ios"])
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    emit(["type": "locationError",
          "message": error.localizedDescription, "platform": "ios"])
  }

  @available(iOS 13.0, *)
  func locationManager(_ manager: CLLocationManager,
                       didRange beacons: [CLBeacon],
                       satisfying beaconConstraint: CLBeaconIdentityConstraint) {
    handleRangedBeacons(beacons)
  }

  func locationManager(_ manager: CLLocationManager,
                       didRangeBeacons beacons: [CLBeacon],
                       in region: CLBeaconRegion) {
    handleRangedBeacons(beacons)
  }

  private func handleRangedBeacons(_ beacons: [CLBeacon]) {
    let now = Date().timeIntervalSince1970
    for beacon in beacons {
      guard beacon.rssi != 0, beacon.rssi > minValidRssi else { continue }

      let foundMajor = beacon.major.intValue
      let foundMinor = beacon.minor.intValue
      if foundMajor == Int(ownMajor) && foundMinor == Int(ownMinor) { continue }

      let key = "\(foundMajor)_\(foundMinor)"
      let rawRssi = Double(beacon.rssi)
      let smoothed: Double
      if let prev = rssiSmoothed[key] {
        smoothed = ewmaAlpha * rawRssi + (1.0 - ewmaAlpha) * prev
      } else {
        smoothed = rawRssi
      }
      rssiSmoothed[key] = smoothed

      let last = lastEmitAt[key] ?? 0.0
      if now - last < minEmitInterval { continue }
      lastEmitAt[key] = now

      emit(["type": "beacon",
            "major": foundMajor, "minor": foundMinor,
            "rssi": Int(smoothed),
            "source": "ibeacon", "platform": "ios"])
    }
    purgeOldRssiState(now: now)
  }

  private func purgeOldRssiState(now: TimeInterval) {
    let stale = lastEmitAt.filter { now - $0.value > 60.0 }.map { $0.key }
    for key in stale {
      lastEmitAt.removeValue(forKey: key)
      rssiSmoothed.removeValue(forKey: key)
    }
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}