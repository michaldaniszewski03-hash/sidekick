import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let keepAlive = KeepAlive()
  private var ble: SidekickBLE?

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
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "setKeepAlive":
          keepAlive.set((call.arguments as? [String: Any])?["on"] as? Bool ?? false)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SidekickBLE") {
      ble = SidekickBLE.register(messenger: registrar.messenger())
    }
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
