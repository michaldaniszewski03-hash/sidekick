import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let media = IOSMedia()

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
      let media = self.media
      channel.setMethodCallHandler { call, result in media.handle(call, result: result) }
    }
  }
}

/// What a paired computer can do to this iPhone's audio. iOS only lets apps
/// change the system volume and control Apple Music; other apps' playback
/// (YouTube, Spotify…) is off limits.
final class IOSMedia {
  private var mutedFrom: Float?
  private var sessionReady = false

  /// The system volume slider. Setting it is the only way apps may change
  /// the volume; it has to live in a window, so it sits off-screen.
  private lazy var volumeView: MPVolumeView = {
    let view = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 10, height: 10))
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    return view
  }()

  private var player: MPMusicPlayerController { MPMusicPlayerController.systemMusicPlayer }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "mediaStatus":
      result(status())
    case "mediaAction":
      let args = call.arguments as? [String: Any] ?? [:]
      perform(
        args["action"] as? String ?? "",
        positionMs: (args["positionMs"] as? NSNumber)?.doubleValue,
        volume: (args["volume"] as? NSNumber)?.floatValue)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func prepareSession() {
    guard !sessionReady else { return }
    sessionReady = true
    // Ambient + mix: reading the volume never pauses what's playing.
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.ambient, options: [.mixWithOthers])
    try? session.setActive(true)
  }

  private var volume: Float {
    prepareSession()
    return AVAudioSession.sharedInstance().outputVolume
  }

  private func status() -> [String: Any] {
    var s: [String: Any] = [
      "volume": Double(volume),
      "muted": mutedFrom != nil,
      "nowPlaying": true,
      "canSeek": false,
      "canNext": false,
      "canPrevious": false,
      "app": "Music",
    ]
    let auth = MPMediaLibrary.authorizationStatus()
    if auth == .notDetermined { MPMediaLibrary.requestAuthorization { _ in } }
    if auth == .authorized, let item = player.nowPlayingItem {
      s["available"] = true
      s["title"] = item.title ?? ""
      s["artist"] = item.artist ?? ""
      s["status"] = {
        switch player.playbackState {
        case .playing, .seekingForward, .seekingBackward: return "playing"
        case .paused, .interrupted: return "paused"
        case .stopped: return "stopped"
        @unknown default: return "unknown"
        }
      }()
      s["positionMs"] = Int(max(0, player.currentPlaybackTime) * 1000)
      s["durationMs"] = Int(max(0, item.playbackDuration) * 1000)
      s["canSeek"] = true
      s["canNext"] = true
      s["canPrevious"] = true
    } else {
      s["note"] =
        "iOS only lets Sidekick control Apple Music and the volume. Keep Sidekick open on the iPhone "
        + "while you control it."
    }
    return s
  }

  private func perform(_ action: String, positionMs: Double?, volume: Float?) {
    switch action {
    case "playPause": player.playbackState == .playing ? player.pause() : player.play()
    case "play": player.play()
    case "pause": player.pause()
    case "stop": player.stop()
    case "next": player.skipToNextItem()
    case "previous": player.skipToPreviousItem()
    case "seek": if let ms = positionMs { player.currentPlaybackTime = ms / 1000 }
    case "setVolume": if let v = volume { setVolume(v) }
    case "volumeUp": setVolume(self.volume + 1 / 16)
    case "volumeDown": setVolume(self.volume - 1 / 16)
    case "toggleMute":
      if let previous = mutedFrom {
        mutedFrom = nil
        setVolume(previous, keepMute: true)
      } else {
        mutedFrom = self.volume
        setVolume(0, keepMute: true)
      }
    default: break
    }
  }

  private func setVolume(_ value: Float, keepMute: Bool = false) {
    if !keepMute { mutedFrom = nil }
    if volumeView.superview == nil {
      let window = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.windows.first }
        .first
      window?.addSubview(volumeView)
    }
    let target = min(max(value, 0), 1)
    // The slider appears a moment after the view joins a window.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      if let slider = self.volumeView.subviews.compactMap({ $0 as? UISlider }).first {
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
      }
    }
  }
}
