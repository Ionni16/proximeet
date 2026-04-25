import CoreBluetooth
import CoreLocation
import Flutter
import UIKit

final class ProxiMeetBeaconPlugin: NSObject, FlutterStreamHandler, CLLocationManagerDelegate, CBPeripheralManagerDelegate {
  static let shared = ProxiMeetBeaconPlugin()

  private var locationManager: CLLocationManager?
  private var peripheralManager: CBPeripheralManager?
  private var txRegion: CLBeaconRegion?
  private var rxRegion: CLBeaconRegion?
  private var eventSink: FlutterEventSink?
  private var beaconUUID: UUID?
  private var major: CLBeaconMajorValue = 0
  private var minor: CLBeaconMinorValue = 0
  private let regionIdentifier = "com.proximeet.ibeacon"

  static func register(with messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(name: "proximeet/beacon", binaryMessenger: messenger)
    let eventChannel = FlutterEventChannel(name: "proximeet/beacon_events", binaryMessenger: messenger)

    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        guard
          let args = call.arguments as? [String: Any],
          let uuidString = args["uuid"] as? String,
          let major = args["major"] as? Int,
          let minor = args["minor"] as? Int
        else {
          result(FlutterError(code: "BAD_ARGS", message: "uuid/major/minor mancanti", details: nil))
          return
        }

        ProxiMeetBeaconPlugin.shared.start(uuidString: uuidString, major: major, minor: minor, result: result)

      case "stop":
        ProxiMeetBeaconPlugin.shared.stop()
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    eventChannel.setStreamHandler(ProxiMeetBeaconPlugin.shared)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func start(uuidString: String, major: Int, minor: Int, result: @escaping FlutterResult) {
    guard let uuid = UUID(uuidString: uuidString) else {
      result(FlutterError(code: "BAD_UUID", message: "UUID iBeacon non valido", details: uuidString))
      return
    }
    guard major >= 0 && major <= 65535 && minor >= 0 && minor <= 65535 else {
      result(FlutterError(code: "BAD_MAJOR_MINOR", message: "major/minor devono essere 0...65535", details: nil))
      return
    }

    stop()

    self.beaconUUID = uuid
    self.major = CLBeaconMajorValue(major)
    self.minor = CLBeaconMinorValue(minor)

    let lm = CLLocationManager()
    lm.delegate = self
    lm.pausesLocationUpdatesAutomatically = false
    if Bundle.main.object(forInfoDictionaryKey: "NSLocationAlwaysAndWhenInUseUsageDescription") != nil {
      lm.requestAlwaysAuthorization()
    } else {
      lm.requestWhenInUseAuthorization()
    }
    self.locationManager = lm

    let rx = CLBeaconRegion(uuid: uuid, identifier: regionIdentifier)
    rx.notifyOnEntry = true
    rx.notifyOnExit = true
    rx.notifyEntryStateOnDisplay = true
    self.rxRegion = rx

    lm.startMonitoring(for: rx)
    lm.startRangingBeacons(satisfying: rx.beaconIdentityConstraint)

    self.txRegion = CLBeaconRegion(uuid: uuid, major: self.major, minor: self.minor, identifier: regionIdentifier + ".tx")
    self.peripheralManager = CBPeripheralManager(delegate: self, queue: nil)

    result(true)
  }

  private func startAdvertisingIfPossible() {
    guard let pm = peripheralManager, pm.state == .poweredOn, let tx = txRegion else { return }
    pm.stopAdvertising()
    let data = tx.peripheralData(withMeasuredPower: nil) as NSDictionary
    pm.startAdvertising(data as? [String: Any])
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    if peripheral.state == .poweredOn {
      startAdvertisingIfPossible()
    } else {
      eventSink?(["type": "state", "platform": "ios", "bluetoothState": peripheral.state.rawValue])
    }
  }

  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    guard let rx = rxRegion else { return }
    if status == .authorizedAlways || status == .authorizedWhenInUse {
      manager.startMonitoring(for: rx)
      manager.startRangingBeacons(satisfying: rx.beaconIdentityConstraint)
    }
  }

  func locationManager(
    _ manager: CLLocationManager,
    didRange beacons: [CLBeacon],
    satisfying beaconConstraint: CLBeaconIdentityConstraint
  ) {
    for beacon in beacons where beacon.rssi != 0 {
      eventSink?([
        "major": beacon.major.intValue,
        "minor": beacon.minor.intValue,
        "rssi": beacon.rssi,
        "accuracy": beacon.accuracy,
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
        lm.stopRangingBeacons(satisfying: rx.beaconIdentityConstraint)
      }
    }

    locationManager = nil
    txRegion = nil
    rxRegion = nil
    beaconUUID = nil
  }
}
