import ActivityKit
import AVFoundation
import Flutter
import NetworkExtension
import Photos
import ReplayKit
import UserNotifications
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let keepAlive = KeepAlive()
  private let sounds = Sounds()
  private let offers = OfferNotifier()
  private let live = LiveTransfers()
  private var ble: SidekickBLE?
  private var p2p: SidekickP2P?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SidekickIOS") {
      let channel = FlutterMethodChannel(name: "sidekick/ios", binaryMessenger: registrar.messenger())
      let keepAlive = self.keepAlive
      let sounds = self.sounds
      let offers = self.offers
      let live = self.live
      offers.attach(channel)
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "setKeepAlive":
          keepAlive.set((call.arguments as? [String: Any])?["on"] as? Bool ?? false)
          result(nil)
        case "playSound":
          // A regular player on the media volume, mixed with whatever else
          // is playing. (A system sound was silent whenever the ring/silent
          // switch was on or the ringer was turned down.) Settings → Sound
          // turns Sidekick's sounds off.
          if let path = (call.arguments as? [String: Any])?["path"] as? String {
            sounds.play(path)
          }
          result(nil)
        case "clipboardState":
          // Noticing copies without reading them (reading asks "Allow
          // Paste?" unless allowed in Settings → Sidekick).
          result(["count": UIPasteboard.general.changeCount, "hasText": UIPasteboard.general.hasStrings])
        case "openSettings":
          // Sidekick's own page in Settings (Paste from Other Apps is there).
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
          result(nil)
        case "loopSound":
          // The Ping ringtone, on repeat until "stopLoop" (Found It).
          if let path = (call.arguments as? [String: Any])?["path"] as? String {
            sounds.loop(path)
          }
          result(nil)
        case "stopLoop":
          sounds.stopLoop()
          result(nil)
        case "saveToGallery":
          // A received photo or video, moved into Photos.
          let args = call.arguments as? [String: Any]
          guard let path = args?["path"] as? String else {
            result(FlutterError(code: "failed", message: "No file", details: nil))
            return
          }
          PhotosSaver.save(path: path, video: args?["video"] as? Bool ?? false, done: result)
        case "requestNotifications":
          offers.requestPermission()
          result(nil)
        case "notifyOffer":
          let args = call.arguments as? [String: Any] ?? [:]
          offers.show(
            id: args["id"] as? String ?? "", title: args["title"] as? String ?? "",
            body: args["body"] as? String ?? "")
          result(nil)
        case "offerDone":
          let args = call.arguments as? [String: Any] ?? [:]
          offers.done(
            id: args["id"] as? String ?? "", title: args["title"] as? String ?? "",
            body: args["body"] as? String ?? "")
          result(nil)
        case "cancelOffer":
          offers.cancel(id: (call.arguments as? [String: Any])?["id"] as? String ?? "")
          result(nil)
        case "offerProgress":
          result(nil)  // iPhone notifications have no progress bar.
        case "openFolder":
          // The Files app at Sidekick's folder (On My iPhone → Sidekick).
          let path = (call.arguments as? [String: Any])?["path"] as? String ?? ""
          let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
          if let url = URL(string: "shareddocuments://\(encoded)") {
            UIApplication.shared.open(url)
          }
          result(nil)
        case "openGallery":
          if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
          }
          result(nil)
        case "liveStart":
          let args = call.arguments as? [String: Any] ?? [:]
          live.start(
            id: args["id"] as? String ?? "", device: args["device"] as? String ?? "",
            incoming: args["incoming"] as? Bool ?? true, title: args["title"] as? String ?? "",
            total: (args["total"] as? NSNumber)?.int64Value ?? 0, status: args["status"] as? String ?? "")
          result(nil)
        case "liveUpdate", "liveEnd":
          let args = call.arguments as? [String: Any] ?? [:]
          live.update(
            id: args["id"] as? String ?? "", done: (args["done"] as? NSNumber)?.int64Value ?? 0,
            total: (args["total"] as? NSNumber)?.int64Value ?? 0, status: args["status"] as? String ?? "",
            end: call.method == "liveEnd", failed: args["failed"] as? Bool ?? false)
          result(nil)
        case "startBroadcast":
          // Screen Mirroring: iOS's "Start Broadcast" sheet for Sidekick's
          // broadcast extension (SidekickMirror), which sends the screen to
          // the app on 127.0.0.1 (lib/platform/screen_source.dart).
          BroadcastPicker.open()
          result(nil)
        case "joinHotspot":
          // Another device's network for a direct link (an Android phone's
          // hotspot, a Windows PC's Wi-Fi Direct network). iOS asks "Join?".
          let args = call.arguments as? [String: Any] ?? [:]
          HotspotJoiner.join(
            ssid: args["ssid"] as? String ?? "", passphrase: args["passphrase"] as? String ?? "", done: result)
        case "leaveHotspot":
          let ssid = (call.arguments as? [String: Any])?["ssid"] as? String ?? ""
          NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SidekickBLE") {
      ble = SidekickBLE.register(messenger: registrar.messenger())
      p2p = SidekickP2P.register(messenger: registrar.messenger())
    }
  }
}

/// Plays Sidekick's sounds (startup, a request arriving, accepted, declined).
final class Sounds {
  /// Held until it finishes: a player that's let go stops at once.
  private var players: [AVAudioPlayer] = []

  func play(_ path: String) {
    let session = AVAudioSession.sharedInstance()
    // Same category as KeepAlive, so the two never fight over the session.
    try? session.setCategory(.playback, options: [.mixWithOthers])
    try? session.setActive(true)
    guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
    players.removeAll { !$0.isPlaying }
    players.append(player)
    player.prepareToPlay()
    player.play()
  }

  /// The Ping ringtone: on repeat, at full volume, through the silent
  /// switch (the playback category), until [stopLoop].
  private var ringtone: AVAudioPlayer?

  func loop(_ path: String) {
    stopLoop()
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, options: [.mixWithOthers])
    try? session.setActive(true)
    guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
    player.numberOfLoops = -1
    player.volume = 1
    player.prepareToPlay()
    player.play()
    ringtone = player
  }

  func stopLoop() {
    ringtone?.stop()
    ringtone = nil
  }
}

/// Keeps Sidekick running while other apps are open, so a paired computer
/// can still reach the iPhone (sending files, browsing, the clipboard). iOS
/// suspends apps in the background otherwise. It plays silence, mixed with
/// other audio, so nothing you listen to is interrupted.
///
/// The silence must never stop: iOS suspends Sidekick seconds after it
/// does. AVAudioEngine stops by itself when the audio route changes
/// (AirPods, a Bluetooth speaker, a car), after a call or Siri, and when
/// the media services reset; each of those restarts it, and a watchdog
/// checks every few seconds for anything else.
final class KeepAlive {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var observers: [NSObjectProtocol] = []
  private var engineObserver: NSObjectProtocol?
  private var watchdog: Timer?
  private var wanted = false
  private var bridge: UIBackgroundTaskIdentifier = .invalid
  var running: Bool { engine?.isRunning == true && player?.isPlaying == true }

  func set(_ on: Bool) {
    wanted = on
    if on {
      observe()
      revive()
      if watchdog == nil {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
          guard let self = self, self.wanted, !self.running else { return }
          self.revive()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
      }
    } else {
      watchdog?.invalidate()
      watchdog = nil
      for o in observers { NotificationCenter.default.removeObserver(o) }
      observers = []
      teardown()
      try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
  }

  /// Starts the silence, or starts it again: a fresh engine every time,
  /// since one that stopped on a route change may have a stale format.
  private func revive() {
    guard wanted else { return }
    teardown()
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, options: [.mixWithOthers])
      try session.setActive(true)
    } catch {
      return
    }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let format = engine.mainMixerNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0,
      let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
    else { return }
    engine.connect(player, to: engine.mainMixerNode, format: format)
    silence.frameLength = silence.frameCapacity  // all zeros
    do {
      try engine.start()
    } catch {
      return
    }
    player.scheduleBuffer(silence, at: nil, options: .loops)
    player.play()
    self.engine = engine
    self.player = player
    // The engine stops itself when the route or hardware format changes.
    engineObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in self?.revive() }
  }

  private func teardown() {
    if let o = engineObserver { NotificationCenter.default.removeObserver(o) }
    engineObserver = nil
    engine?.stop()
    player?.stop()
    player = nil
    engine = nil
  }

  private func observe() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    // A call or Siri interrupts the session; start again when it's over
    // (whether or not iOS says to resume).
    observers.append(
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
        [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else { return }
        self?.revive()
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) {
        [weak self] _ in self?.revive()
      })
    observers.append(
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let self = self, !self.running else { return }
        self.revive()
      })
    // Going to the background: make sure the silence is playing, with a
    // little borrowed time in case it has to be started again.
    observers.append(
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let self = self else { return }
        if self.bridge == .invalid {
          self.bridge = UIApplication.shared.beginBackgroundTask(withName: "sidekick.keepalive") { [weak self] in
            self?.endBridge()
          }
        }
        if !self.running { self.revive() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.endBridge() }
      })
    observers.append(
      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let self = self, !self.running else { return }
        self.revive()
      })
  }

  private func endBridge() {
    guard bridge != .invalid else { return }
    UIApplication.shared.endBackgroundTask(bridge)
    bridge = .invalid
  }
}

/// Moves received photos and videos into the Photos library, like AirDrop.
/// Only asks to add (NSPhotoLibraryAddUsageDescription), never to read.
enum PhotosSaver {
  static func save(path: String, video: Bool, done: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          done(FlutterError(
            code: "denied", message: "allow it in Settings → Sidekick → Photos", details: nil))
        }
        return
      }
      let url = URL(fileURLWithPath: path)
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = url.lastPathComponent
        // Moved, not copied: no second copy left taking up space.
        options.shouldMoveFile = true
        request.addResource(with: video ? .video : .photo, fileURL: url, options: options)
      }) { ok, error in
        if ok { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.main.async {
          if ok {
            done(nil)
          } else {
            done(FlutterError(
              code: "failed", message: error?.localizedDescription ?? "Photos didn't take it", details: nil))
          }
        }
      }
    }
  }
}

/// A file request while Sidekick is in the background: a notification with
/// Accept and Decline. The buttons go back to Dart as `offerAction`.
final class OfferNotifier: NSObject, UNUserNotificationCenterDelegate {
  private weak var channel: FlutterMethodChannel?
  private let center = UNUserNotificationCenter.current()

  func attach(_ channel: FlutterMethodChannel) {
    self.channel = channel
    center.delegate = self
    let accept = UNNotificationAction(identifier: "accept", title: "Accept", options: [])
    let decline = UNNotificationAction(identifier: "decline", title: "Decline", options: [.destructive])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: "offer", actions: [accept, decline], intentIdentifiers: [], options: [])
    ])
  }

  func requestPermission() {
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  private func post(id: String, title: String, body: String, category: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    if let category { content.categoryIdentifier = category }
    center.add(UNNotificationRequest(identifier: "offer-\(id)", content: content, trigger: nil))
  }

  func show(id: String, title: String, body: String) {
    post(id: id, title: title, body: body, category: "offer")
  }

  func done(id: String, title: String, body: String) {
    cancel(id: id)
    post(id: id, title: title, body: body, category: nil)
  }

  func cancel(id: String) {
    center.removeDeliveredNotifications(withIdentifiers: ["offer-\(id)"])
    center.removePendingNotificationRequests(withIdentifiers: ["offer-\(id)"])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let request = response.notification.request.identifier
    if request.hasPrefix("offer-"),
      ["accept", "decline"].contains(response.actionIdentifier)
    {
      let id = String(request.dropFirst("offer-".count))
      channel?.invokeMethod("offerAction", arguments: ["id": id, "action": response.actionIdentifier])
    }
    completionHandler()
  }

  // On screen, the app shows its own card: no banner.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }
}

/// Joins a Wi-Fi network by name and password (NEHotspotConfiguration). It
/// needs Apple's Hotspot Configuration permission, which builds signed by
/// Sidekick's developer account have (TestFlight); without it ("byHand"),
/// Dart asks the user to join in Settings → Wi-Fi instead.
enum HotspotJoiner {
  static func join(ssid: String, passphrase: String, done: @escaping FlutterResult) {
    let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
    // Forgotten again when Sidekick leaves it or goes to the background.
    configuration.joinOnce = true
    NEHotspotConfigurationManager.shared.apply(configuration) { error in
      DispatchQueue.main.async {
        guard let error = error as NSError? else { return done(nil) }
        guard error.domain == NEHotspotConfigurationErrorDomain else {
          return done(FlutterError(code: "byHand", message: error.localizedDescription, details: nil))
        }
        switch NEHotspotConfigurationError(rawValue: error.code) {
        case .alreadyAssociated:
          done(nil)
        case .userDenied:
          done(FlutterError(code: "denied", message: "You chose not to join \(ssid).", details: nil))
        case .invalidSSID, .invalidWPAPassphrase:
          done(FlutterError(code: "invalid", message: "The other device's network looks wrong.", details: nil))
        default:
          done(FlutterError(code: "byHand", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}

/// A transfer's progress on the Lock Screen and in the Dynamic Island (Live
/// Activities, iOS 16.2+; drawn by the SidekickLive extension). Dart starts
/// one per transfer, updates it about once a second, and ends it; a finished
/// one stays a few seconds, then goes.
final class LiveTransfers {
  /// Activity<TransferActivityAttributes> by transfer id (Any: the type
  /// only exists on iOS 16.1+).
  private var activities: [String: Any] = [:]

  func start(id: String, device: String, incoming: Bool, title: String, total: Int64, status: String) {
    guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled, activities[id] == nil else {
      return
    }
    let attributes = TransferActivityAttributes(device: device, incoming: incoming, title: title)
    let state = TransferActivityAttributes.ContentState(
      done: 0, total: total, status: status, finished: false, failed: false)
    do {
      activities[id] = try Activity.request(
        attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
    } catch {
      print("Sidekick: Live Activity: \(error)")
    }
  }

  func update(id: String, done: Int64, total: Int64, status: String, end: Bool, failed: Bool) {
    guard #available(iOS 16.2, *), let activity = activities[id] as? Activity<TransferActivityAttributes> else {
      return
    }
    let state = TransferActivityAttributes.ContentState(
      done: done, total: total, status: status, finished: end, failed: failed)
    let content = ActivityContent(state: state, staleDate: nil)
    if end {
      activities[id] = nil
      Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4))) }
    } else {
      Task { await activity.update(content) }
    }
  }
}

/// Opens iOS's "Start Broadcast" sheet for Sidekick's broadcast extension.
/// iOS only opens it from a tap on its own picker button, so the app adds an
/// invisible picker and taps it.
enum BroadcastPicker {
  private static var picker: RPSystemBroadcastPickerView?

  static func open() {
    DispatchQueue.main.async {
      picker?.removeFromSuperview()
      let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
      view.preferredExtension = (Bundle.main.bundleIdentifier ?? "dev.sidekick.sidekick") + ".Mirror"
      view.showsMicrophoneButton = false
      view.alpha = 0.011
      view.isUserInteractionEnabled = false
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
      window?.addSubview(view)
      picker = view
      for case let button as UIButton in view.subviews {
        button.sendActions(for: .touchUpInside)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        if picker === view {
          view.removeFromSuperview()
          picker = nil
        }
      }
    }
  }
}
