// Sidekick's Bluetooth on iPhone and Mac, written directly on CoreBluetooth.
// The same file is in ios/Runner and macos/Runner; keep them identical.
//
// Dart (lib/core/ble_backend.dart, AppleBleBackend) talks to it over the
// `sidekick/ble` method channel and gets events on `sidekick/ble/events`:
//   state        {central, peripheral}: "on" | "off" | "unauthorized" | "unsupported" | "unknown"
//   discovered   {id, rssi, sidekick, name}
//   notified     {id, data}          a peripheral we opened sent a response chunk
//   disconnected {id}                a peripheral we connected to went away
//   written      {central, data}     a central wrote a request chunk to us
//   centralGone  {central}
//   log          {message}

import CoreBluetooth

#if os(iOS)
  import Flutter
  import UIKit
#else
  import AppKit
  import FlutterMacOS
#endif

final class SidekickBLE: NSObject, FlutterStreamHandler, CBCentralManagerDelegate,
  CBPeripheralManagerDelegate, CBPeripheralDelegate
{
  static let serviceID = CBUUID(string: "7C3E9A52-8B1F-4C2D-9E6A-3F5D1B2C4A00")
  static let rxID = CBUUID(string: "7C3E9A52-8B1F-4C2D-9E6A-3F5D1B2C4A01")
  static let txID = CBUUID(string: "7C3E9A52-8B1F-4C2D-9E6A-3F5D1B2C4A02")
  static let infoID = CBUUID(string: "7C3E9A52-8B1F-4C2D-9E6A-3F5D1B2C4A03")
  static let advertisedName = "Sidekick"

  private var central: CBCentralManager?
  private var manager: CBPeripheralManager?
  private var sink: FlutterEventSink?

  /// This device's info JSON, served to anyone reading the info characteristic.
  private var info = Data()

  // Being found (peripheral role).
  private var wantAdvertising = false
  private var serviceAdded = false
  private var addingService = false
  private var advertiseResult: FlutterResult?
  private var txCharacteristic: CBMutableCharacteristic?
  private var subscribers: [String: CBCentral] = [:]
  private var pendingNotifications: [(CBCentral, Data, FlutterResult)] = []

  // Finding others (central role).
  private var scanFiltered = true
  private var peripherals: [String: CBPeripheral] = [:]
  private var characteristics: [String: [CBUUID: CBCharacteristic]] = [:]
  private var identifyResults: [String: FlutterResult] = [:]
  private var openResults: [String: FlutterResult] = [:]
  // CoreBluetooth answers reads and writes in order, so queue the callers.
  private var readResults: [String: [FlutterResult]] = [:]
  private var writeResults: [String: [FlutterResult]] = [:]
  private var openLinks: Set<String> = []

  @discardableResult
  static func register(messenger: FlutterBinaryMessenger) -> SidekickBLE {
    let ble = SidekickBLE()
    let methods = FlutterMethodChannel(name: "sidekick/ble", binaryMessenger: messenger)
    methods.setMethodCallHandler { call, result in ble.handle(call, result: result) }
    FlutterEventChannel(name: "sidekick/ble/events", binaryMessenger: messenger).setStreamHandler(ble)
    return ble
  }

  // MARK: Events

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    sendState()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ event: [String: Any]) { sink?(event) }
  private func log(_ message: String) { emit(["type": "log", "message": message]) }

  private func stateName(_ state: CBManagerState?) -> String {
    switch state ?? .unknown {
    case .poweredOn: return "on"
    case .poweredOff: return "off"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    default: return "unknown"
    }
  }

  private func sendState() {
    emit(["type": "state", "central": stateName(central?.state), "peripheral": stateName(manager?.state)])
  }

  private func error(_ message: String) -> FlutterError {
    FlutterError(code: "ble", message: message, details: nil)
  }

  // MARK: Methods

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? ""
    switch call.method {
    case "start":
      // Creating the managers shows the Bluetooth permission prompt once.
      if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
      if manager == nil { manager = CBPeripheralManager(delegate: self, queue: nil) }
      sendState()
      result(nil)
    case "state":
      result(["central": stateName(central?.state), "peripheral": stateName(manager?.state)])
    case "setInfo":
      info = (args["data"] as? FlutterStandardTypedData)?.data ?? Data()
      result(nil)
    case "advertise":
      wantAdvertising = true
      guard manager?.state == .poweredOn else {
        result(error("Bluetooth isn't on"))
        return
      }
      if manager?.isAdvertising == true && serviceAdded {
        result(nil)
        return
      }
      advertiseResult?(error("Replaced by a newer request"))
      advertiseResult = result
      startAdvertisingIfReady()
    case "stopAdvertising":
      wantAdvertising = false
      manager?.stopAdvertising()
      result(nil)
    case "scan":
      guard let central = central, central.state == .poweredOn else {
        result(error("Bluetooth isn't on"))
        return
      }
      scanFiltered = args["filtered"] as? Bool ?? true
      central.scanForPeripherals(
        withServices: scanFiltered ? [SidekickBLE.serviceID] : nil,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
      result(nil)
    case "stopScan":
      central?.stopScan()
      result(nil)
    case "identify":
      connect(id, link: false, result: result)
    case "open":
      connect(id, link: true, result: result)
    case "readInfo":
      guard let p = peripherals[id], let c = characteristics[id]?[SidekickBLE.infoID] else {
        result(error("Not connected"))
        return
      }
      readResults[id, default: []].append(result)
      p.readValue(for: c)
    case "write":
      guard let p = peripherals[id], let c = characteristics[id]?[SidekickBLE.rxID],
        let data = (args["data"] as? FlutterStandardTypedData)?.data
      else {
        result(error("Not connected"))
        return
      }
      writeResults[id, default: []].append(result)
      p.writeValue(data, for: c, type: .withResponse)
    case "close":
      openLinks.remove(id)
      if let p = peripherals[id] { central?.cancelPeripheralConnection(p) }
      result(nil)
    case "notify":
      let centralID = args["central"] as? String ?? ""
      guard let subscriber = subscribers[centralID], let data = (args["data"] as? FlutterStandardTypedData)?.data
      else {
        result(error("That device isn't listening"))
        return
      }
      notify(subscriber, data, result)
    case "maxNotify":
      let centralID = args["central"] as? String ?? ""
      result(subscribers[centralID]?.maximumUpdateValueLength ?? 20)
    case "openSettings":
      #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
          NSWorkspace.shared.open(url)
        }
      #endif
      result(nil)
    case "openBluetoothSettings":
      #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
          NSWorkspace.shared.open(url)
        }
      #endif
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Being found

  private func startAdvertisingIfReady() {
    guard wantAdvertising, let manager = manager, manager.state == .poweredOn else { return }
    if !serviceAdded {
      guard !addingService else { return }
      addingService = true
      let infoCharacteristic = CBMutableCharacteristic(
        type: SidekickBLE.infoID, properties: [.read], value: nil, permissions: [.readable])
      let rx = CBMutableCharacteristic(
        type: SidekickBLE.rxID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
      let tx = CBMutableCharacteristic(type: SidekickBLE.txID, properties: [.notify], value: nil, permissions: [.readable])
      txCharacteristic = tx
      let service = CBMutableService(type: SidekickBLE.serviceID, primary: true)
      service.characteristics = [infoCharacteristic, rx, tx]
      manager.removeAllServices()
      manager.add(service)
      return
    }
    if manager.isAdvertising {
      advertiseResult?(nil)
      advertiseResult = nil
      return
    }
    manager.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [SidekickBLE.serviceID],
      CBAdvertisementDataLocalNameKey: SidekickBLE.advertisedName,
    ])
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    sendState()
    if peripheral.state == .poweredOn {
      startAdvertisingIfReady()
    } else {
      // Services are gone after Bluetooth turns off; add them again later.
      serviceAdded = false
      addingService = false
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    addingService = false
    if let error = error {
      log("Couldn't add the Sidekick service: \(error.localizedDescription)")
      advertiseResult?(self.error(error.localizedDescription))
      advertiseResult = nil
      return
    }
    serviceAdded = true
    startAdvertisingIfReady()
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      log("Couldn't start advertising: \(error.localizedDescription)")
      advertiseResult?(self.error(error.localizedDescription))
    } else {
      advertiseResult?(nil)
    }
    advertiseResult = nil
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == SidekickBLE.infoID else {
      peripheral.respond(to: request, withResult: .readNotPermitted)
      return
    }
    guard request.offset <= info.count else {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    request.value = info.subdata(in: request.offset..<info.count)
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    guard requests.allSatisfy({ $0.characteristic.uuid == SidekickBLE.rxID }) else {
      peripheral.respond(to: first, withResult: .writeNotPermitted)
      return
    }
    // A long write arrives as pieces with offsets; put the chunk back together.
    var chunk = Data()
    for request in requests.sorted(by: { $0.offset < $1.offset }) { chunk.append(request.value ?? Data()) }
    let centralID = first.central.identifier.uuidString
    subscribers[centralID] = subscribers[centralID] ?? first.central
    peripheral.respond(to: first, withResult: .success)
    emit(["type": "written", "central": centralID, "data": FlutterStandardTypedData(bytes: chunk)])
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
  ) {
    subscribers[central.identifier.uuidString] = central
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
  ) {
    let id = central.identifier.uuidString
    subscribers.removeValue(forKey: id)
    emit(["type": "centralGone", "central": id])
  }

  private func notify(_ subscriber: CBCentral, _ data: Data, _ result: @escaping FlutterResult) {
    guard let manager = manager, let tx = txCharacteristic else {
      result(error("Not advertising"))
      return
    }
    // Keep order: queue behind anything already waiting.
    if pendingNotifications.isEmpty && manager.updateValue(data, for: tx, onSubscribedCentrals: [subscriber]) {
      result(nil)
    } else {
      pendingNotifications.append((subscriber, data, result))
    }
  }

  func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
    guard let tx = txCharacteristic else { return }
    while let next = pendingNotifications.first {
      let (subscriber, data, result) = next
      guard peripheral.updateValue(data, for: tx, onSubscribedCentrals: [subscriber]) else { return }
      pendingNotifications.removeFirst()
      result(nil)
    }
  }

  // MARK: Finding others

  /// The most one write carries in a single packet. Writes are sent with a
  /// response, but a longer one would become a "long write" in pieces,
  /// which Android and Windows hand over separately.
  static func packetLength(_ peripheral: CBPeripheral) -> Int {
    peripheral.maximumWriteValueLength(for: .withoutResponse)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    sendState()
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let id = peripheral.identifier.uuidString
    peripherals[id] = peripheral
    let primary = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    // "strong": it really advertises Sidekick. Apps in the background put
    // their service ids into a shared bitmask ("overflow") instead, where
    // any Apple device with an overlapping bit matches too, and a filtered
    // scan reports those as well. They're only worth a quiet look.
    let strong = primary.contains(SidekickBLE.serviceID) || name == SidekickBLE.advertisedName
    let sidekick = strong || overflow.contains(SidekickBLE.serviceID) || scanFiltered
    emit([
      "type": "discovered", "id": id, "rssi": RSSI.intValue, "sidekick": sidekick, "strong": strong,
      "name": name ?? peripheral.name ?? "",
    ])
  }

  private func connect(_ id: String, link: Bool, result: @escaping FlutterResult) {
    guard let central = central, central.state == .poweredOn else {
      result(error("Bluetooth isn't on"))
      return
    }
    var peripheral = peripherals[id]
    if peripheral == nil, let uuid = UUID(uuidString: id) {
      peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
      if let p = peripheral { peripherals[id] = p }
    }
    guard let p = peripheral else {
      result(error("That device is out of range"))
      return
    }
    p.delegate = self
    let ready = p.state == .connected && characteristics[id]?[SidekickBLE.rxID] != nil
    if link {
      openLinks.insert(id)
      if ready, characteristics[id]?[SidekickBLE.txID]?.isNotifying == true {
        result(SidekickBLE.packetLength(p))
        return
      }
      openResults[id]?(error("Replaced by a newer request"))
      openResults[id] = result
    } else {
      identifyResults[id]?(error("Replaced by a newer request"))
      identifyResults[id] = result
    }
    if ready {
      continueSetup(p)
    } else if p.state == .connected {
      p.discoverServices([SidekickBLE.serviceID])
    } else if p.state != .connecting {
      central.connect(p, options: nil)
    }
  }

  static func short(_ id: String) -> String { String(id.prefix(4)) }

  /// A Bluetooth error for Dart. An old system-level Bluetooth pairing that
  /// only one side still remembers gets its own code, since the fix is in
  /// Bluetooth settings.
  private func failure(_ error: Error?, _ fallback: String) -> FlutterError {
    if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation {
      return FlutterError(code: "stalePairing", message: cb.localizedDescription, details: nil)
    }
    if let att = error as? CBATTError,
      att.code == .insufficientEncryption || att.code == .insufficientAuthentication
    {
      return FlutterError(code: "stalePairing", message: att.localizedDescription, details: nil)
    }
    return self.error(error?.localizedDescription ?? fallback)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.delegate = self
    log("Connected to \(SidekickBLE.short(peripheral.identifier.uuidString)), looking for Sidekick on it")
    peripheral.discoverServices([SidekickBLE.serviceID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    let id = peripheral.identifier.uuidString
    log("Couldn't connect to \(SidekickBLE.short(id)): \(error?.localizedDescription ?? "no reason given")")
    fail(id, failure(error, "Couldn't connect"))
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    characteristics.removeValue(forKey: id)
    if let error = error { log("\(SidekickBLE.short(id)) disconnected: \(error.localizedDescription)") }
    fail(id, failure(error, "Disconnected"))
    if openLinks.remove(id) != nil { emit(["type": "disconnected", "id": id]) }
  }

  private func fail(_ id: String, _ message: String) { fail(id, error(message)) }

  private func fail(_ id: String, _ failure: FlutterError) {
    identifyResults.removeValue(forKey: id)?(failure)
    openResults.removeValue(forKey: id)?(failure)
    for r in readResults.removeValue(forKey: id) ?? [] { r(failure) }
    for r in writeResults.removeValue(forKey: id) ?? [] { r(failure) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let id = peripheral.identifier.uuidString
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == SidekickBLE.serviceID }) else {
      if error == nil { log("\(SidekickBLE.short(id)) isn't running Sidekick") }
      fail(id, failure(error, "It has no Sidekick service"))
      return
    }
    peripheral.discoverCharacteristics(
      [SidekickBLE.rxID, SidekickBLE.txID, SidekickBLE.infoID], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let id = peripheral.identifier.uuidString
    guard error == nil else {
      fail(id, failure(error, "Couldn't read its services"))
      return
    }
    var found: [CBUUID: CBCharacteristic] = [:]
    for c in service.characteristics ?? [] { found[c.uuid] = c }
    characteristics[id] = found
    continueSetup(peripheral)
  }

  /// After services are known: read the name (identify) and/or listen for
  /// responses (open).
  private func continueSetup(_ peripheral: CBPeripheral) {
    let id = peripheral.identifier.uuidString
    let found = characteristics[id] ?? [:]
    if identifyResults[id] != nil {
      guard let infoCharacteristic = found[SidekickBLE.infoID] else {
        identifyResults.removeValue(forKey: id)?(error("It has no info characteristic"))
        return
      }
      peripheral.readValue(for: infoCharacteristic)
    }
    if openResults[id] != nil {
      guard let tx = found[SidekickBLE.txID], found[SidekickBLE.rxID] != nil else {
        openResults.removeValue(forKey: id)?(error("It has no request characteristics"))
        return
      }
      if tx.isNotifying {
        openResults.removeValue(forKey: id)?(SidekickBLE.packetLength(peripheral))
      } else {
        peripheral.setNotifyValue(true, for: tx)
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
  ) {
    let id = peripheral.identifier.uuidString
    guard characteristic.uuid == SidekickBLE.txID, let result = openResults.removeValue(forKey: id) else { return }
    if let error = error {
      result(failure(error, "Couldn't listen for answers"))
    } else {
      result(SidekickBLE.packetLength(peripheral))
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    let id = peripheral.identifier.uuidString
    let data = characteristic.value ?? Data()
    if characteristic.uuid == SidekickBLE.txID {
      emit(["type": "notified", "id": id, "data": FlutterStandardTypedData(bytes: data)])
      return
    }
    guard characteristic.uuid == SidekickBLE.infoID else { return }
    let value: Any
    if let error = error {
      value = failure(error, "Couldn't read its name")
    } else {
      value = FlutterStandardTypedData(bytes: data)
    }
    if let result = identifyResults.removeValue(forKey: id) {
      result(value)
      // Don't hold a connection just for a name, unless a link is open.
      if !openLinks.contains(id) && openResults[id] == nil { central?.cancelPeripheralConnection(peripheral) }
    } else if var waiting = readResults[id], !waiting.isEmpty {
      let result = waiting.removeFirst()
      readResults[id] = waiting
      result(value)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    let id = peripheral.identifier.uuidString
    guard var waiting = writeResults[id], !waiting.isEmpty else { return }
    let result = waiting.removeFirst()
    writeResults[id] = waiting
    if let error = error {
      result(failure(error, "Couldn't send"))
    } else {
      result(nil)
    }
  }
}
