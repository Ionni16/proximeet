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
    ProxiMeetBeaconPlugin.shared.resume()
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    ProxiMeetBeaconPlugin.shared.stop()
    super.applicationWillTerminate(application)
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// ProxiMeetBeaconPlugin
//
// CROSS-PLATFORM STRATEGY (iOS ↔ Android):
//
// iOS → detect Android:
//   CLLocationManager ranges iBeacon packets (manufacturer data 0x004C).
//   Android advertises proper iBeacon format → iOS detects it reliably. ✓
//
// Android → detect iOS:
//   Android scans for both:
//     1. iBeacon manufacturer data (0x004C) — works when iOS is in foreground.
//     2. Custom service data (UUID 0000ABCD-...) — works always.
//   iOS advertises BOTH:
//     a. iBeacon via CLBeaconRegion.peripheralData() (foreground, detected by Android).
//     b. A periodic 1-second pulse of custom service data (ANDROID_COMPAT_UUID)
//        containing [major_hi, major_lo, minor_hi, minor_lo].
//        This pulse repeats every SERVICE_PULSE_INTERVAL_S seconds.
//        Android's parseAndroidServiceBeacon() picks this up regardless of state.
// ──────────────────────────────────────────────────────────────────────────────
final class ProxiMeetBeaconPlugin: NSObject, FlutterStreamHandler,
                                    CLLocationManagerDelegate, CBPeripheralManagerDelegate {

  static let shared = ProxiMeetBeaconPlugin()

  // ── Channels ────────────────────────────────────────────────────────────────
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
          let major    = args["major"] as? Int,
          let minor    = args["minor"] as? Int
        else {
          result(FlutterError(code: "BAD_ARGS",
                              message: "uuid, major e minor sono obbligatori",
                              details: call.arguments))
          return
        }
        ProxiMeetBeaconPlugin.shared.start(
          uuidString: uuidString, major: major, minor: minor, result: result)

      case "stop":
        ProxiMeetBeaconPlugin.shared.stop()
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    eventChannel.setStreamHandler(ProxiMeetBeaconPlugin.shared)
  }

  // ── FlutterStreamHandler ─────────────────────────────────────────────────────
  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // ── State ────────────────────────────────────────────────────────────────────
  private var locationManager:   CLLocationManager?
  private var peripheralManager: CBPeripheralManager?
  private var txRegion:          CLBeaconRegion?
  private var rxRegion:          CLBeaconRegion?
  private var eventSink:         FlutterEventSink?

  private var ownMajor:    CLBeaconMajorValue = 0
  private var ownMinor:    CLBeaconMinorValue = 0
  private var currentUuid: UUID?
  private var isStarted  = false

  private let regionIdentifier = "com.ionut.proximeet.proximeeet_app.ibeacon"

  // RSSI smoothing
  private var rssiSmoothed:  [String: Double]       = [:]
  private var lastEmitAt:    [String: TimeInterval]  = [:]
  private let ewmaAlpha:     Double  = 0.25
  private let minEmitInterval: TimeInterval = 0.8
  private let minValidRssi = -100

  // Timers
  private var rangingRestartTimer: Timer?
  private var stateReportTimer:    Timer?

  /// Cross-platform pulse timer: periodically advertises service data so
  /// Android devices can detect this iOS device regardless of iOS state.
  private var servicePulseTimer: DispatchSourceTimer?

  // ── Service UUID for cross-platform detection ─────────────────────────────────
  // Must match Android's ANDROID_SERVICE_UUID = "0000ABCD-0000-1000-8000-00805F9B34FB"
  private let androidCompatServiceUUID = CBUUID(string: "0000ABCD-0000-1000-8000-00805F9B34FB")

  // Pulse config
  private let SERVICE_PULSE_INTERVAL_S: TimeInterval = 8.0
  private let SERVICE_PULSE_DURATION_S: TimeInterval = 1.2

  // ── Start ─────────────────────────────────────────────────────────────────────
  func start(uuidString: String, major: Int, minor: Int, result: @escaping FlutterResult) {
    guard let uuid = UUID(uuidString: uuidString) else {
      result(FlutterError(code: "BAD_UUID", message: "UUID iBeacon non valido", details: uuidString))
      return
    }
    guard (0...65535).contains(major) && (0...65535).contains(minor) else {
      result(FlutterError(code: "BAD_MAJOR_MINOR",
                          message: "major/minor devono essere 0...65535",
                          details: ["major": major, "minor": minor]))
      return
    }
    guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else {
      result(FlutterError(code: "BEACON_UNSUPPORTED",
                          message: "Dispositivo non supporta iBeacon monitoring.", details: nil))
      return
    }

    stopInternal(keepEventSink: true)

    isStarted  = true
    currentUuid = uuid
    ownMajor   = CLBeaconMajorValue(major)
    ownMinor   = CLBeaconMinorValue(minor)
    rssiSmoothed.removeAll()
    lastEmitAt.removeAll()

    // Location manager (iBeacon ranging — iOS ← Android)
    let manager = CLLocationManager()
    manager.delegate                       = self
    manager.pausesLocationUpdatesAutomatically = false
    manager.distanceFilter                 = kCLDistanceFilterNone
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = false
    locationManager = manager

    let rx = CLBeaconRegion(uuid: uuid, identifier: regionIdentifier)
    rx.notifyOnEntry              = true
    rx.notifyOnExit               = true
    rx.notifyEntryStateOnDisplay  = true
    rxRegion = rx

    txRegion = CLBeaconRegion(
      uuid: uuid, major: ownMajor, minor: ownMinor,
      identifier: regionIdentifier + ".tx"
    )

    // Peripheral manager (iBeacon advertising + service-data pulse — Android ← iOS)
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)

    let status = authorizationStatus(for: manager)
    switch status {
    case .notDetermined:
      manager.requestAlwaysAuthorization()
    case .authorizedWhenInUse:
      manager.requestAlwaysAuthorization()
      startMonitoringAndRangingIfPossible(manager: manager)
    case .authorizedAlways:
      startMonitoringAndRangingIfPossible(manager: manager)
    case .restricted, .denied:
      emit(["type": "locationAuthorization", "status": status.rawValue, "platform": "ios"])
    @unknown default:
      emit(["type": "locationAuthorization", "status": status.rawValue, "platform": "ios"])
    }

    startMaintenanceTimers()

    // Start service-data pulse timer (Android cross-detection)
    startServicePulseTimer(major: major, minor: minor)

    result(true)
  }

  func resume() {
    guard isStarted, let manager = locationManager else { return }
    startMonitoringAndRangingIfPossible(manager: manager)
    startAdvertisingIfPossible()
    startMaintenanceTimers()
    if let major = Int(exactly: ownMajor), let minor = Int(exactly: ownMinor) {
      startServicePulseTimer(major: major, minor: minor)
    }
  }

  func stop() {
    stopInternal(keepEventSink: true)
  }

  private func stopInternal(keepEventSink: Bool) {
    rangingRestartTimer?.invalidate()
    rangingRestartTimer = nil
    stateReportTimer?.invalidate()
    stateReportTimer = nil

    servicePulseTimer?.cancel()
    servicePulseTimer = nil

    peripheralManager?.stopAdvertising()
    peripheralManager = nil

    if let manager = locationManager {
      if let rx = rxRegion {
        if #available(iOS 13.0, *) {
          manager.stopRangingBeacons(satisfying: rx.beaconIdentityConstraint)
        } else {
          manager.stopRangingBeacons(in: rx)
        }
        manager.stopMonitoring(for: rx)
      }
      for region in manager.monitoredRegions
        where region.identifier == regionIdentifier
           || region.identifier == regionIdentifier + ".tx" {
        manager.stopMonitoring(for: region)
      }
    }

    locationManager = nil
    txRegion        = nil
    rxRegion        = nil
    currentUuid     = nil
    isStarted       = false
    rssiSmoothed.removeAll()
    lastEmitAt.removeAll()

    if !keepEventSink { eventSink = nil }
  }

  // ── Maintenance timers ───────────────────────────────────────────────────────
  private func startMaintenanceTimers() {
    rangingRestartTimer?.invalidate()
    rangingRestartTimer = Timer.scheduledTimer(
      withTimeInterval: 30.0, repeats: true
    ) { [weak self] _ in
      guard let self, let manager = self.locationManager, self.isStarted else { return }
      self.startMonitoringAndRangingIfPossible(manager: manager)
    }

    stateReportTimer?.invalidate()
    stateReportTimer = Timer.scheduledTimer(
      withTimeInterval: 10.0, repeats: true
    ) { [weak self] _ in
      guard let self, self.isStarted else { return }
      self.emit([
        "type": "stateWatchdog",
        "bluetoothState":  self.peripheralManager?.state.rawValue ?? -1,
        "locationStatus":  self.locationManager.map {
          self.authorizationStatus(for: $0).rawValue } ?? -1,
        "platform": "ios"
      ])
    }
  }

  // ── Cross-platform service data pulse (Android ← iOS) ───────────────────────
  /// Every SERVICE_PULSE_INTERVAL_S seconds:
  ///   1. Stop iBeacon advertising
  ///   2. Advertise service data with major/minor for SERVICE_PULSE_DURATION_S
  ///   3. Resume iBeacon advertising
  ///
  /// Android's parseAndroidServiceBeacon() picks up the service data packet,
  /// allowing Android to detect this iOS device regardless of iOS background state.
  private func startServicePulseTimer(major: Int, minor: Int) {
    servicePulseTimer?.cancel()

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + SERVICE_PULSE_INTERVAL_S,
                   repeating: SERVICE_PULSE_INTERVAL_S)
    timer.setEventHandler { [weak self] in
      self?.emitServiceDataPulse(major: major, minor: minor)
    }
    timer.resume()
    servicePulseTimer = timer
  }

  private func emitServiceDataPulse(major: Int, minor: Int) {
    guard isStarted, let pm = peripheralManager, pm.state == .poweredOn else { return }

    // Build 4-byte payload: [major_hi, major_lo, minor_hi, minor_lo]
    let payload = Data([
      UInt8((major >> 8) & 0xFF),
      UInt8(major & 0xFF),
      UInt8((minor >> 8) & 0xFF),
      UInt8(minor & 0xFF)
    ])

    // 1. Switch to service data advertisement
    pm.stopAdvertising()
    pm.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [androidCompatServiceUUID],
      CBAdvertisementDataServiceDataKey:  [androidCompatServiceUUID: payload]
    ])

    emit(["type": "servicePulse", "major": major, "minor": minor, "platform": "ios"])

    // 2. After pulse duration, revert to iBeacon
    DispatchQueue.main.asyncAfter(deadline: .now() + SERVICE_PULSE_DURATION_S) { [weak self] in
      guard let self, self.isStarted else { return }
      self.startAdvertisingIfPossible()
    }
  }

  // ── iBeacon advertising ──────────────────────────────────────────────────────
  private func startAdvertisingIfPossible() {
    guard isStarted, let pm = peripheralManager, pm.state == .poweredOn,
          let txRegion = txRegion else { return }

    let beaconData = txRegion.peripheralData(withMeasuredPower: nil)
    guard let payload = beaconData as? [String: Any] else {
      emit(["type": "advertiseError", "message": "Cast payload iBeacon fallito", "platform": "ios"])
      return
    }

    pm.stopAdvertising()
    pm.startAdvertising(payload)
  }

  // ── CLLocationManager setup ──────────────────────────────────────────────────
  private func startMonitoringAndRangingIfPossible(manager: CLLocationManager) {
    guard isStarted, let rx = rxRegion else { return }

    let status = authorizationStatus(for: manager)
    guard status == .authorizedAlways || status == .authorizedWhenInUse else {
      emit(["type": "locationAuthorization", "status": status.rawValue, "platform": "ios"])
      return
    }

    manager.startMonitoring(for: rx)
    manager.requestState(for: rx)

    if #available(iOS 13.0, *) {
      manager.startRangingBeacons(satisfying: rx.beaconIdentityConstraint)
    } else {
      manager.startRangingBeacons(in: rx)
    }

    emit(["type": "scanStarted", "mode": "ibeacon_ranging", "platform": "ios"])
  }

  private func authorizationStatus(for manager: CLLocationManager) -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) { return manager.authorizationStatus }
    return CLLocationManager.authorizationStatus()
  }

  // ── CBPeripheralManagerDelegate ──────────────────────────────────────────────
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      emit(["type": "bluetoothOn", "platform": "ios"])
      startAdvertisingIfPossible()
    case .poweredOff:
      emit(["type": "bluetoothOff", "platform": "ios"])
    case .unauthorized:
      emit(["type": "bluetoothUnauthorized", "platform": "ios"])
    case .unsupported:
      emit(["type": "bluetoothUnsupported", "platform": "ios"])
    default:
      emit(["type": "bluetoothState", "state": peripheral.state.rawValue, "platform": "ios"])
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didStartAdvertising error: Error?) {
    if let error = error {
      emit(["type": "advertiseError", "message": error.localizedDescription, "platform": "ios"])
    } else {
      emit(["type": "advertiseStarted", "mode": "ibeacon", "platform": "ios"])
    }
  }

  // ── CLLocationManagerDelegate ────────────────────────────────────────────────
  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    handleAuthorizationStatus(authorizationStatus(for: manager), manager: manager)
  }

  func locationManager(_ manager: CLLocationManager,
                       didChangeAuthorization status: CLAuthorizationStatus) {
    handleAuthorizationStatus(status, manager: manager)
  }

  private func handleAuthorizationStatus(_ status: CLAuthorizationStatus,
                                          manager: CLLocationManager) {
    emit(["type": "locationAuthorization", "status": status.rawValue, "platform": "ios"])
    switch status {
    case .authorizedAlways:
      startMonitoringAndRangingIfPossible(manager: manager)
    case .authorizedWhenInUse:
      manager.requestAlwaysAuthorization()
      startMonitoringAndRangingIfPossible(manager: manager)
    case .denied, .restricted:
      emit(["type": "locationError", "code": "LOCATION_DENIED",
            "message": "Autorizzazione localizzazione negata o limitata.", "platform": "ios"])
    case .notDetermined:
      manager.requestAlwaysAuthorization()
    @unknown default:
      break
    }
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
    emit(["type": "monitoringError", "identifier": region?.identifier ?? "unknown",
          "message": error.localizedDescription, "platform": "ios"])
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    emit(["type": "locationError", "message": error.localizedDescription, "platform": "ios"])
  }

  // ── iBeacon ranging callbacks ────────────────────────────────────────────────
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
      guard beacon.rssi != 0 && beacon.rssi > minValidRssi else { continue }

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

      emit(["type": "beacon", "major": foundMajor, "minor": foundMinor,
            "rssi": Int(smoothed), "source": "ibeacon", "platform": "ios"])
    }
    purgeOldRssiState(now: now)
  }

  private func purgeOldRssiState(now: TimeInterval) {
    let stale = lastEmitAt.filter { now - $0.value > 60.0 }.map { $0.key }
    stale.forEach {
      lastEmitAt.removeValue(forKey: $0)
      rssiSmoothed.removeValue(forKey: $0)
    }
  }

  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.eventSink?(payload) }
  }
}
