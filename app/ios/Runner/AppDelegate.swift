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
    // On screen but invisible: newer iOS ignores volume views placed
    // outside the window.
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    view.alpha = 0.001
    view.isUserInteractionEnabled = false
    return view
  }()

  private var player: MPMusicPlayerController { MPMusicPlayerController.systemMusicPlayer }

  private let keepAlive = KeepAlive()

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setKeepAlive":
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      keepAlive.set(on)
      if !on { sessionReady = false }
      result(nil)
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
    // The keep-alive session already reports the volume.
    guard !sessionReady, !keepAlive.running else { return }
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
    prepareSession()
    if volumeView.superview == nil {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
      window?.addSubview(volumeView)
    }
    apply(min(max(value, 0), 1), attempt: 0)
  }

  /// The slider inside the volume view only exists once the view has been
  /// laid out in a window, so retry briefly until it's there.
  private func apply(_ target: Float, attempt: Int) {
    if let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
      slider.setValue(target, animated: false)
      slider.sendActions(for: .valueChanged)
      slider.sendActions(for: .touchUpInside)
      return
    }
    guard attempt < 10 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.apply(target, attempt: attempt + 1) }
  }
}

/// Keeps Sidekick running while other apps are open, so a paired computer
/// can still reach the iPhone (volume, Apple Music, sending files). iOS
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
