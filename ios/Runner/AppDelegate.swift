import Flutter
import UIKit
import CoreBluetooth
import CoreLocation

// ──────────────────────────────────────────────────────────────────────────────
// AppDelegate
// ──────────────────────────────────────────────────────────────────────────────

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

// ──────────────────────────────────────────────────────────────────────────────
// ProxiMeetBeaconPlugin
//
// STRATEGIA ARCHITETTURALE (riscrittura completa, stable build):
//
// 1. UNA SOLA MODALITÀ DI ADVERTISING: iBeacon. Niente switching tra
//    iBeacon e service-data. Lo switching ripetuto è la causa primaria
//    dei crash su iOS 26 — il controller BT entra in stato inconsistente.
//
// 2. NIENTE TIMER PERIODICI CHE TOCCANO IL BT. L'unica eccezione è un
//    timer di stato leggero (solo emit), che non chiama mai start/stop.
//
// 3. STATE GUARDS RIGIDI: isAdvertising e isRanging vengono tracciati
//    esplicitamente. Non chiamiamo mai startAdvertising se già attivo,
//    né stopAdvertising se non attivo. Idem per ranging.
//
// 4. RESUME LIFECYCLE: applicationDidBecomeActive verifica lo stato dei
//    manager e riavvia ranging/advertising solo se necessario. Non fa
//    mai stop+start ravvicinati.
//
// 5. CROSS-PLATFORM:
//    - iOS ↔ iOS: CoreLocation iBeacon ranging (background-capable).
//    - iOS → Android: iOS advertises iBeacon, Android ne legge i raw
//      bytes con parseIBeacon() (foreground iOS necessario — limite
//      Apple invarcabile).
//    - Android → iOS: Android advertises iBeacon, iOS lo riceve via
//      CoreLocation ranging.
//    - Android ↔ Android: già funzionante.
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
  private var rxRegion:          CLBeaconRegion?
  private var txRegion:          CLBeaconRegion?
  private var advertisingPayload: [String: Any]?
  private var eventSink:         FlutterEventSink?

  private var ownMajor:    CLBeaconMajorValue = 0
  private var ownMinor:    CLBeaconMinorValue = 0
  private var currentUuid: UUID?

  /// Top-level "I want to be running" flag set by start(), cleared by stop().
  private var isStarted   = false

  /// Tracks whether iBeacon ranging is actively running. Prevents double-start.
  private var isRanging   = false

  /// Tracks whether iBeacon advertising is actively running. Prevents double-start.
  private var isAdvertising = false

  private let regionIdentifier = "com.ionut.proximeet.proximeeet_app.ibeacon"

  // ── RSSI smoothing (matches Android behavior) ───────────────────────────────
  private var rssiSmoothed:    [String: Double]      = [:]
  private var lastEmitAt:      [String: TimeInterval] = [:]
  private let ewmaAlpha:       Double = 0.25
  private let minEmitInterval: TimeInterval = 0.8
  private let minValidRssi     = -100

  // ── State watchdog (LIGHT — only emits status, never touches BT) ────────────
  private var stateReportTimer: Timer?

  // ────────────────────────────────────────────────────────────────────────────
  // START
  // ────────────────────────────────────────────────────────────────────────────
  func start(uuidString: String, major: Int, minor: Int, result: @escaping FlutterResult) {
    // ── Validate args ─────────────────────────────────────────────────────────
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

    // ── Idempotency: if already started with same params, just resume ─────────
    if isStarted, currentUuid == uuid,
       Int(ownMajor) == major, Int(ownMinor) == minor {
      ensureRangingRunning()
      ensureAdvertisingRunning()
      result(true)
      return
    }

    // ── Clean stop of any previous session ────────────────────────────────────
    stopInternal(keepEventSink: true)

    // ── Set up new state ──────────────────────────────────────────────────────
    isStarted   = true
    currentUuid = uuid
    ownMajor    = CLBeaconMajorValue(major)
    ownMinor    = CLBeaconMinorValue(minor)
    rssiSmoothed.removeAll()
    lastEmitAt.removeAll()

    // ── Allocate location manager (for ranging) ───────────────────────────────
    let manager = CLLocationManager()
    manager.delegate = self
    manager.pausesLocationUpdatesAutomatically = false
    manager.distanceFilter = kCLDistanceFilterNone
    // Background location updates require "location" UIBackgroundMode.
    // Already configured in Info.plist.
    manager.allowsBackgroundLocationUpdates   = true
    manager.showsBackgroundLocationIndicator  = false
    locationManager = manager

    // ── Build rx region (what we listen for) ──────────────────────────────────
    let rx = CLBeaconRegion(uuid: uuid, identifier: regionIdentifier)
    rx.notifyOnEntry             = true
    rx.notifyOnExit              = true
    rx.notifyEntryStateOnDisplay = true
    rxRegion = rx

    // ── Build tx region (what we advertise) and pre-compute payload ───────────
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
            "message": "Cast payload iBeacon fallito (peripheralData non è [String: Any])",
            "platform": "ios"])
    }

    // ── Allocate peripheral manager (for advertising) ─────────────────────────
    // Allocate AFTER setting payload so peripheralManagerDidUpdateState has it.
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)

    // ── Kick off authorization flow → callbacks will start ranging + adv ──────
    let status = currentAuthorizationStatus(for: manager)
    switch status {
    case .notDetermined:
      manager.requestAlwaysAuthorization()
    case .authorizedWhenInUse:
      manager.requestAlwaysAuthorization()
      ensureRangingRunning()
    case .authorizedAlways:
      ensureRangingRunning()
    case .restricted, .denied:
      emit(["type": "locationAuthorization",
            "status": status.rawValue, "platform": "ios"])
    @unknown default:
      emit(["type": "locationAuthorization",
            "status": status.rawValue, "platform": "ios"])
    }

    startStateReportTimer()

    // Native start is asynchronous: BT state and auth callbacks will follow.
    result(true)
  }

  // ────────────────────────────────────────────────────────────────────────────
  // LIFECYCLE — called from applicationDidBecomeActive
  // ────────────────────────────────────────────────────────────────────────────
  func applicationDidBecomeActive() {
    guard isStarted else { return }
    // Just verify and ensure: never blindly stop+start.
    ensureRangingRunning()
    ensureAdvertisingRunning()
  }

  // ────────────────────────────────────────────────────────────────────────────
  // STOP
  // ────────────────────────────────────────────────────────────────────────────
  func stop() {
    stopInternal(keepEventSink: true)
  }

  private func stopInternal(keepEventSink: Bool) {
    stopStateReportTimer()

    // ── Stop advertising idempotently ─────────────────────────────────────────
    if isAdvertising, let pm = peripheralManager {
      pm.stopAdvertising()
    }
    isAdvertising = false
    peripheralManager = nil

    // ── Stop ranging + monitoring idempotently ────────────────────────────────
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
      // Defensive: stop monitoring any leftover regions with our identifier.
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

  // ────────────────────────────────────────────────────────────────────────────
  // ENSURE: idempotent helpers — only act if state requires it
  // ────────────────────────────────────────────────────────────────────────────
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
    // isAdvertising is set to true in didStartAdvertising callback.
  }

  // ────────────────────────────────────────────────────────────────────────────
  // STATE REPORT TIMER (lightweight — only emits status events)
  // ────────────────────────────────────────────────────────────────────────────
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
      // Light self-heal: if state is good but flags say nothing's running,
      // attempt to resume. Does NOT stop+restart anything already running.
      self.ensureRangingRunning()
      self.ensureAdvertisingRunning()
    }
  }

  private func stopStateReportTimer() {
    stateReportTimer?.invalidate()
    stateReportTimer = nil
  }

  // ────────────────────────────────────────────────────────────────────────────
  // CBPeripheralManagerDelegate
  // ────────────────────────────────────────────────────────────────────────────
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      emit(["type": "bluetoothOn", "platform": "ios"])
      ensureAdvertisingRunning()
    case .poweredOff:
      emit(["type": "bluetoothOff", "platform": "ios"])
      // BT off → advertising stops automatically; mirror our flag.
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

  // ────────────────────────────────────────────────────────────────────────────
  // CLLocationManagerDelegate — Authorization
  // ────────────────────────────────────────────────────────────────────────────
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
    case .authorizedAlways:
      ensureRangingRunning()
    case .authorizedWhenInUse:
      manager.requestAlwaysAuthorization()
      ensureRangingRunning()
    case .denied, .restricted:
      isRanging = false
      emit(["type": "locationError", "code": "LOCATION_DENIED",
            "message": "Autorizzazione localizzazione negata o limitata.",
            "platform": "ios"])
    case .notDetermined:
      manager.requestAlwaysAuthorization()
    @unknown default:
      break
    }
  }

  private func currentAuthorizationStatus(for manager: CLLocationManager) -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) { return manager.authorizationStatus }
    return CLLocationManager.authorizationStatus()
  }

  // ────────────────────────────────────────────────────────────────────────────
  // CLLocationManagerDelegate — Errors / state
  // ────────────────────────────────────────────────────────────────────────────
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

  // ────────────────────────────────────────────────────────────────────────────
  // CLLocationManagerDelegate — Ranging callbacks
  // ────────────────────────────────────────────────────────────────────────────
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
      // Ignore self
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

  // ────────────────────────────────────────────────────────────────────────────
  // Emit helper
  // ────────────────────────────────────────────────────────────────────────────
  private func emit(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}
