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

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    ProxiMeetBeaconPlugin.register(with: controller.binaryMessenger)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

final class ProxiMeetBeaconPlugin: NSObject, FlutterStreamHandler, CLLocationManagerDelegate, CBPeripheralManagerDelegate {
  static let shared = ProxiMeetBeaconPlugin()

  private var locationManager: CLLocationManager?
  private var peripheralManager: CBPeripheralManager?
  private var txRegion: CLBeaconRegion?
  private var rxRegion: CLBeaconRegion?
  private var eventSink: FlutterEventSink?

  private var major: CLBeaconMajorValue = 0
  private var minor: CLBeaconMinorValue = 0

  private let regionIdentifier = "com.ionut.proximeet.proximeeet_app.ibeacon"

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
          result(FlutterError(
            code: "BAD_ARGS",
            message: "uuid, major e minor sono obbligatori",
            details: call.arguments
          ))
          return
        }

        ProxiMeetBeaconPlugin.shared.start(
          uuidString: uuidString,
          major: major,
          minor: minor,
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

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func start(
    uuidString: String,
    major: Int,
    minor: Int,
    result: @escaping FlutterResult
  ) {
    guard let uuid = UUID(uuidString: uuidString) else {
      result(FlutterError(
        code: "BAD_UUID",
        message: "UUID iBeacon non valido",
        details: uuidString
      ))
      return
    }

    guard major >= 0 && major <= 65535 && minor >= 0 && minor <= 65535 else {
      result(FlutterError(
        code: "BAD_MAJOR_MINOR",
        message: "major/minor devono essere 0...65535",
        details: ["major": major, "minor": minor]
      ))
      return
    }

    stop()

    self.major = CLBeaconMajorValue(major)
    self.minor = CLBeaconMinorValue(minor)

    let lm = CLLocationManager()
    lm.delegate = self
    lm.pausesLocationUpdatesAutomatically = false

    if Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") != nil {
      lm.allowsBackgroundLocationUpdates = true
    }

    locationManager = lm

    let rx = CLBeaconRegion(uuid: uuid, identifier: regionIdentifier)
    rx.notifyOnEntry = true
    rx.notifyOnExit = true
    rx.notifyEntryStateOnDisplay = true
    rxRegion = rx

    txRegion = CLBeaconRegion(
      uuid: uuid,
      major: self.major,
      minor: self.minor,
      identifier: regionIdentifier + ".tx"
    )

    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)

    let status: CLAuthorizationStatus
    if #available(iOS 14.0, *) {
      status = lm.authorizationStatus
    } else {
      status = CLLocationManager.authorizationStatus()
    }

    if status == .notDetermined {
      // Foreground ranging funziona con When In Use. Always è utile solo per background.
      lm.requestWhenInUseAuthorization()
    } else {
      handleAuthorizationStatus(status, manager: lm)
    }

    // Il join Dart non deve restare bloccato in attesa dei permessi.
    result(true)
  }

  private func startRangingIfPossible(manager: CLLocationManager) {
    guard let rx = rxRegion else { return }

    manager.startMonitoring(for: rx)

    if #available(iOS 13.0, *) {
      manager.startRangingBeacons(satisfying: rx.beaconIdentityConstraint)
    } else {
      manager.startRangingBeacons(in: rx)
    }
  }

  private func startAdvertisingIfPossible() {
    guard
      let pm = peripheralManager,
      pm.state == .poweredOn,
      let tx = txRegion
    else { return }

    pm.stopAdvertising()
    let data = tx.peripheralData(withMeasuredPower: nil) as NSDictionary
    pm.startAdvertising(data as? [String: Any])

    eventSink?([
      "type": "advertiseStarted",
      "platform": "ios"
    ])
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    switch peripheral.state {
    case .poweredOn:
      startAdvertisingIfPossible()

    case .poweredOff:
      eventSink?(["type": "bluetoothOff", "platform": "ios"])

    case .unauthorized:
      eventSink?(["type": "bluetoothUnauthorized", "platform": "ios"])

    default:
      eventSink?([
        "type": "bluetoothState",
        "state": peripheral.state.rawValue,
        "platform": "ios"
      ])
    }
  }

  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    handleAuthorizationStatus(manager.authorizationStatus, manager: manager)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didChangeAuthorization status: CLAuthorizationStatus
  ) {
    handleAuthorizationStatus(status, manager: manager)
  }

  private func handleAuthorizationStatus(
    _ status: CLAuthorizationStatus,
    manager: CLLocationManager
  ) {
    eventSink?([
      "type": "locationAuthorization",
      "status": status.rawValue,
      "platform": "ios"
    ])

    if status == .authorizedAlways || status == .authorizedWhenInUse {
      startRangingIfPossible(manager: manager)
    }
  }

  func locationManager(
    _ manager: CLLocationManager,
    didRange beacons: [CLBeacon],
    satisfying beaconConstraint: CLBeaconIdentityConstraint
  ) {
    handleRangedBeacons(beacons)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didRangeBeacons beacons: [CLBeacon],
    in region: CLBeaconRegion
  ) {
    handleRangedBeacons(beacons)
  }

  private func handleRangedBeacons(_ beacons: [CLBeacon]) {
    for beacon in beacons where beacon.rssi != 0 {
      let foundMajor = beacon.major.intValue
      let foundMinor = beacon.minor.intValue

      if foundMajor == Int(major) && foundMinor == Int(minor) {
        continue
      }

      eventSink?([
        "type": "beacon",
        "major": foundMajor,
        "minor": foundMinor,
        "rssi": beacon.rssi,
        "accuracy": beacon.accuracy,
        "platform": "ios"
      ])
    }
  }

  func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    eventSink?([
      "type": "locationError",
      "message": error.localizedDescription,
      "platform": "ios"
    ])
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didStartAdvertising error: Error?
  ) {
    if let error {
      eventSink?([
        "type": "advertiseError",
        "message": error.localizedDescription,
        "platform": "ios"
      ])
    }
  }

  private func stop() {
    peripheralManager?.stopAdvertising()
    peripheralManager = nil

    if let lm = locationManager {
      for region in lm.monitoredRegions {
        if region.identifier == regionIdentifier || region.identifier == regionIdentifier + ".tx" {
          lm.stopMonitoring(for: region)
        }
      }

      if let rx = rxRegion {
        if #available(iOS 13.0, *) {
          lm.stopRangingBeacons(satisfying: rx.beaconIdentityConstraint)
        } else {
          lm.stopRangingBeacons(in: rx)
        }
      }
    }

    locationManager = nil
    txRegion = nil
    rxRegion = nil
  }
}
