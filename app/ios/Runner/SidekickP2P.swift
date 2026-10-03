// Apple's peer-to-peer Wi-Fi (AWDL, the link AirDrop uses) between iPhones
// and Macs: no router, no shared network, no Bluetooth. The same file is in
// ios/Runner and macos/Runner; keep them identical.
//
// Sidekick's own encrypted HTTPS goes through it untouched:
//   - Every device advertises `_sidekick-p2p._tcp` (named after its device
//     id) and hands each connection that arrives to its own Sidekick server
//     on 127.0.0.1.
//   - To reach another device, Dart asks for a local port (`connect`); each
//     connection to 127.0.0.1:<that port> is carried to that device.
//
// Dart (lib/platform/apple_p2p.dart) talks to it over `sidekick/p2p`:
//   start {id, port}   advertise this device; its server is on `port`
//   browse {on}        look for other devices (costs some Wi-Fi time, so
//                      only while a paired device is out of the network)
//   connect {id}       -> a local port that leads to that device, or nil
//   stop
// and hears `peers` [ids] whenever the devices in reach change.

import Foundation
import Network

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

final class SidekickP2P {
  static let serviceType = "_sidekick-p2p._tcp"

  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "sidekick.p2p")
  private var myId = ""
  private var serverPort: UInt16 = 0
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var wantBrowsing = false
  /// Devices in reach, by device id.
  private var peers: [String: NWEndpoint] = [:]
  /// Local listeners leading to each device, and their ports.
  private var bridges: [String: NWListener] = [:]
  private var bridgePorts: [String: UInt16] = [:]

  static func register(messenger: FlutterBinaryMessenger) -> SidekickP2P {
    let p2p = SidekickP2P(channel: FlutterMethodChannel(name: "sidekick/p2p", binaryMessenger: messenger))
    p2p.channel.setMethodCallHandler { call, result in p2p.handle(call, result: result) }
    return p2p
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      let id = args["id"] as? String ?? ""
      let port = (args["port"] as? NSNumber)?.uint16Value ?? 0
      queue.async {
        self.advertise(id: id, port: port)
        DispatchQueue.main.async { result(nil) }
      }
    case "browse":
      let on = args["on"] as? Bool ?? false
      queue.async {
        if on {
          self.startBrowsing()
        } else {
          self.stopBrowsing()
        }
        DispatchQueue.main.async { result(nil) }
      }
    case "connect":
      let id = args["id"] as? String ?? ""
      queue.async { self.bridge(to: id) { port in DispatchQueue.main.async { result(port.map { Int($0) }) } } }
    case "stop":
      queue.async {
        self.listener?.cancel()
        self.listener = nil
        self.myId = ""
        self.stopBrowsing()
        DispatchQueue.main.async { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// TCP that may use the peer-to-peer link as well as any network.
  private func peerToPeer() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    return parameters
  }

  // MARK: Being found

  private func advertise(id: String, port: UInt16) {
    if id == myId, port == serverPort, listener != nil { return }
    listener?.cancel()
    listener = nil
    myId = id
    serverPort = port
    guard !id.isEmpty, port != 0, let listener = try? NWListener(using: peerToPeer()) else { return }
    listener.service = NWListener.Service(name: id, type: SidekickP2P.serviceType)
    listener.newConnectionHandler = { [weak self] incoming in
      guard let self, let local = NWEndpoint.Port(rawValue: self.serverPort) else { return incoming.cancel() }
      let server = NWConnection(host: .ipv4(.loopback), port: local, using: .tcp)
      self.relay(incoming, server)
    }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      // Wi-Fi turned off and on again, for one: start over.
      guard case .failed = state, let self, let listener, self.listener === listener else { return }
      listener.cancel()
      self.listener = nil
      self.queue.asyncAfter(deadline: .now() + 5) {
        if self.listener == nil { self.advertise(id: self.myId, port: self.serverPort) }
      }
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  // MARK: Finding others

  private func startBrowsing() {
    wantBrowsing = true
    if browser != nil { return }
    let browser = NWBrowser(for: .bonjour(type: SidekickP2P.serviceType, domain: nil), using: peerToPeer())
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self else { return }
      var found: [String: NWEndpoint] = [:]
      for result in results {
        if case let .service(name, _, _, _) = result.endpoint, name != self.myId { found[name] = result.endpoint }
      }
      // Gone: its local port leads nowhere now.
      for id in self.peers.keys where found[id] == nil {
        self.bridges.removeValue(forKey: id)?.cancel()
        self.bridgePorts.removeValue(forKey: id)
      }
      self.peers = found
      self.sendPeers()
    }
    browser.stateUpdateHandler = { [weak self, weak browser] state in
      guard case .failed = state, let self, let browser, self.browser === browser else { return }
      browser.cancel()
      self.browser = nil
      self.queue.asyncAfter(deadline: .now() + 5) {
        if self.wantBrowsing { self.startBrowsing() }
      }
    }
    self.browser = browser
    browser.start(queue: queue)
  }

  private func stopBrowsing() {
    wantBrowsing = false
    browser?.cancel()
    browser = nil
    for bridge in bridges.values { bridge.cancel() }
    bridges.removeAll()
    bridgePorts.removeAll()
    if !peers.isEmpty {
      peers.removeAll()
      sendPeers()
    }
  }

  private func sendPeers() {
    let ids = Array(peers.keys)
    DispatchQueue.main.async { self.channel.invokeMethod("peers", arguments: ids) }
  }

  // MARK: Reaching others

  /// A port on 127.0.0.1 whose connections lead to device [id].
  private func bridge(to id: String, done: @escaping (UInt16?) -> Void) {
    if let port = bridgePorts[id] { return done(port) }
    guard peers[id] != nil else { return done(nil) }
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    guard let bridge = try? NWListener(using: parameters) else { return done(nil) }
    var answered = false
    bridge.newConnectionHandler = { [weak self] local in
      guard let self, let endpoint = self.peers[id] else { return local.cancel() }
      self.relay(local, NWConnection(to: endpoint, using: self.peerToPeer()))
    }
    bridge.stateUpdateHandler = { [weak self, weak bridge] state in
      guard let self, let bridge else { return }
      switch state {
      case .ready:
        guard !answered, let port = bridge.port?.rawValue else { return }
        answered = true
        self.bridgePorts[id] = port
        done(port)
      case .failed:
        bridge.cancel()
        if self.bridges[id] === bridge {
          self.bridges.removeValue(forKey: id)
          self.bridgePorts.removeValue(forKey: id)
        }
        if !answered {
          answered = true
          done(nil)
        }
      default:
        break
      }
    }
    bridges[id] = bridge
    bridge.start(queue: queue)
  }

  // MARK: Relaying

  /// Carries bytes both ways between [a] and [b] until either side ends.
  private func relay(_ a: NWConnection, _ b: NWConnection) {
    var closed = false
    let close: () -> Void = {
      if closed { return }
      closed = true
      a.cancel()
      b.cancel()
    }
    for connection in [a, b] {
      connection.stateUpdateHandler = { state in
        switch state {
        case .failed, .cancelled: close()
        default: break
        }
      }
      connection.start(queue: queue)
    }
    pump(from: a, to: b, close: close)
    pump(from: b, to: a, close: close)
  }

  private func pump(from: NWConnection, to: NWConnection, close: @escaping () -> Void) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return close() }
      let ended = isComplete || error != nil
      if let data, !data.isEmpty {
        to.send(
          content: data,
          completion: .contentProcessed { [weak self] sendError in
            guard let self, sendError == nil else { return close() }
            if ended {
              self.finish(to, close: close)
            } else {
              self.pump(from: from, to: to, close: close)
            }
          })
      } else if ended {
        self.finish(to, close: close)
      } else {
        self.pump(from: from, to: to, close: close)
      }
    }
  }

  /// One side is done: let the other get everything sent, then close both.
  private func finish(_ connection: NWConnection, close: @escaping () -> Void) {
    connection.send(
      content: nil, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { _ in close() })
  }
}
