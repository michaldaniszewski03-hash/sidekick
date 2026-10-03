import AVFoundation
import Flutter
import Photos
import UserNotifications
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let keepAlive = KeepAlive()
  private let sounds = Sounds()
  private let offers = OfferNotifier()
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
}

/// Keeps Sidekick running while other apps are open, so a paired computer
/// can still reach the iPhone (sending files, browsing). iOS
/// suspends apps in the background otherwise. It plays silence, mixed with
/// other audio, so nothing you listen to is interrupted.
final class KeepAlive {
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var observer: NSObjectProtocol?
  var running: Bool { engine != nil }

  func set(_ on: Bool) {
    if on { start() } else { stop() }
  }

  private func start() {
    guard engine == nil else { return }
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
    engine.connect(player, to: engine.mainMixerNode, format: format)
    guard format.sampleRate > 0,
      let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))
    else { return }
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
    // A phone call or Siri interrupts the session; pick up again after.
    observer = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self,
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        AVAudioSession.InterruptionType(rawValue: raw) == .ended
      else { return }
      try? AVAudioSession.sharedInstance().setActive(true)
      try? self.engine?.start()
      self.player?.play()
    }
  }

  private func stop() {
    if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
