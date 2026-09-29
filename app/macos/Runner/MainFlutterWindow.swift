import ApplicationServices
import Cocoa
import CoreImage
import FlutterMacOS
import ScreenCaptureKit

class MainFlutterWindow: NSWindow {
  private let native = SidekickNative()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 420, height: 560)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "sidekick/macos", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let native = self.native
    channel.setMethodCallHandler { call, result in native.handle(call, result: result) }

    super.awakeFromNib()
  }
}

/// The Mac side of the `sidekick/macos` channel: remote mouse/keyboard input
/// (needs the Accessibility permission), media keys and system volume.
final class SidekickNative {
  private let input = MacInput()
  private let media = MacMedia()
  private let screen = ScreenStreamer()

  /// Screen sharing for a paired device that views this Mac.
  private func handleScreen(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let maxWidth = (args["maxWidth"] as? NSNumber)?.intValue ?? 1600
    switch call.method {
    case "screenStart":
      screen.start(maxWidth: maxWidth) { error in
        result(error.map { FlutterError(code: "screen", message: $0, details: nil) })
      }
    case "screenFrame":
      let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 60
      screen.frame(quality: quality / 100) { data, error in
        if let error = error {
          result(FlutterError(code: "screen", message: error, details: nil))
        } else {
          result(data.map { FlutterStandardTypedData(bytes: $0) })
        }
      }
    default:
      screen.stop()
      result(nil)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "permissions":
      result(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()])
    case "requestScreenRecording":
      if !CGRequestScreenCaptureAccess(),
        let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
      {
        NSWorkspace.shared.open(url)
      }
      result(nil)
    case "requestAccessibility":
      let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      {
        NSWorkspace.shared.open(url)
      }
      result(nil)
    case "input":
      if let msg = call.arguments as? [String: Any] { input.handle(msg) }
      result(AXIsProcessTrusted())
    case "screenStart", "screenFrame", "screenStop":
      handleScreen(call, result: result)
    case "mediaStatus":
      result(media.status())
    case "mediaAction":
      let args = call.arguments as? [String: Any] ?? [:]
      media.perform(args["action"] as? String ?? "", volume: (args["volume"] as? NSNumber)?.doubleValue)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Turns Sidekick's input messages into CGEvents. Same JSON shape as the
/// network protocol: {"t":"move","dx":3,"dy":-2}, {"t":"key","k":"c","mods":["ctrl"]}…
///
/// Keys arrive with Windows habits, so "ctrl" and "win" mean Command here and
/// a few shortcuts are translated (Alt+Tab → Cmd+Tab, Win+L → lock screen).
final class MacInput {
  private let source = CGEventSource(stateID: .hidSystemState)
  private var held: CGMouseButton?

  private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

  func handle(_ msg: [String: Any]) {
    func num(_ key: String) -> Double { (msg[key] as? NSNumber)?.doubleValue ?? 0 }
    switch msg["t"] as? String {
    case "move": move(dx: num("dx"), dy: num("dy"))
    case "moveTo": moveTo(x: num("x"), y: num("y"))
    case "click": click(button(msg["b"]), count: max(1, min(3, Int(num("n")))))
    case "down": press(button(msg["b"]), down: true)
    case "up": press(button(msg["b"]), down: false)
    case "scroll": scroll(dx: num("dx"), dy: num("dy"))
    case "key": key((msg["k"] as? String ?? "").lowercased(), mods: msg["mods"] as? [String] ?? [])
    case "text": type(msg["s"] as? String ?? "")
    default: break
    }
  }

  // MARK: Pointer

  private func button(_ value: Any?) -> CGMouseButton {
    switch value as? String {
    case "right": return .right
    case "middle": return .center
    default: return .left
    }
  }

  private func mouseTypes(_ b: CGMouseButton) -> (down: CGEventType, up: CGEventType) {
    switch b {
    case .right: return (.rightMouseDown, .rightMouseUp)
    case .center: return (.otherMouseDown, .otherMouseUp)
    default: return (.leftMouseDown, .leftMouseUp)
    }
  }

  private func move(dx: Double, dy: Double) {
    var p = cursor
    p.x += dx
    p.y += dy
    post(at: clampToDisplays(p))
  }

  /// [x] and [y] are fractions (0–1) of the main display, the one that's
  /// shared when a peer views this screen.
  private func moveTo(x: Double, y: Double) {
    let b = CGDisplayBounds(CGMainDisplayID())
    let p = CGPoint(
      x: b.minX + min(max(x, 0), 1) * (b.width - 1),
      y: b.minY + min(max(y, 0), 1) * (b.height - 1))
    post(at: p)
  }

  private func post(at p: CGPoint) {
    let type: CGEventType
    switch held {
    case .some(.left): type = .leftMouseDragged
    case .some(.right): type = .rightMouseDragged
    case .some(.center): type = .otherMouseDragged
    default: type = .mouseMoved
    }
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: held ?? .left)?
      .post(tap: .cghidEventTap)
  }

  /// Keeps the pointer on a screen (CG coordinates, all active displays).
  private func clampToDisplays(_ p: CGPoint) -> CGPoint {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return p }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var found: UInt32 = 0
    guard CGGetActiveDisplayList(count, &ids, &found) == .success else { return p }
    let screens = ids.prefix(Int(found)).map { CGDisplayBounds($0) }
    if screens.contains(where: { $0.contains(p) }) { return p }
    var best = p
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for s in screens {
      let q = CGPoint(x: min(max(p.x, s.minX), s.maxX - 1), y: min(max(p.y, s.minY), s.maxY - 1))
      let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
      if d < bestDistance {
        bestDistance = d
        best = q
      }
    }
    return best
  }

  // Separate down/up presses (dragging, or clicking on a shared screen) must
  // carry a click count, or macOS never sees a double-click.
  private var lastDown = Date.distantPast
  private var lastDownPoint = CGPoint.zero
  private var clickCount = 1

  private func press(_ b: CGMouseButton, down: Bool) {
    let types = mouseTypes(b)
    held = down ? b : nil
    let p = cursor
    if down {
      let quick = Date().timeIntervalSince(lastDown) < NSEvent.doubleClickInterval
      let near = hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 5
      clickCount = quick && near ? min(clickCount + 1, 3) : 1
      lastDown = Date()
      lastDownPoint = p
    }
    let event = CGEvent(
      mouseEventSource: source, mouseType: down ? types.down : types.up, mouseCursorPosition: p,
      mouseButton: b)
    event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    event?.post(tap: .cghidEventTap)
  }

  private func click(_ b: CGMouseButton, count: Int) {
    let types = mouseTypes(b)
    let p = cursor
    for i in 1...count {
      for t in [types.down, types.up] {
        let event = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: b)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        event?.post(tap: .cghidEventTap)
      }
    }
  }

  /// Sidekick sends Windows wheel units (120 per notch); positive = up/right.
  private func scroll(dx: Double, dy: Double) {
    CGEvent(
      scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
      wheel1: Int32(dy / 2), wheel2: Int32(-dx / 2), wheel3: 0)?
      .post(tap: .cghidEventTap)
  }

  // MARK: Keyboard

  private static let codes: [String: CGKeyCode] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19,
    "7": 0x1A, "8": 0x1C, "0": 0x1D, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25,
    "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
    "enter": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33, "esc": 0x35, "delete": 0x75,
    "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
    "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
  ]

  private func flags(_ mods: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in mods {
      switch m {
      case "ctrl", "win", "cmd": f.insert(.maskCommand)
      case "alt": f.insert(.maskAlternate)
      case "shift": f.insert(.maskShift)
      case "macctrl": f.insert(.maskControl)
      default: break
      }
    }
    return f
  }

  private func key(_ k: String, mods: [String]) {
    // Windows shortcuts people reach for, translated to their Mac versions.
    let m = Set(mods)
    if k == "win" && m.isEmpty { return tap(0x31, flags: .maskCommand) }  // Start menu → Spotlight
    if k == "tab" && m == ["alt"] { return tap(0x30, flags: .maskCommand) }  // Alt+Tab → Cmd+Tab
    if k == "f4" && m == ["alt"] { return tap(0x0D, flags: .maskCommand) }  // Alt+F4 → Cmd+W
    if k == "l" && m == ["win"] { return tap(0x0C, flags: [.maskCommand, .maskControl]) }  // lock
    if k == "d" && m == ["win"] { return tap(0x67, flags: []) }  // show desktop (F11)
    guard let code = MacInput.codes[k] else { return }
    tap(code, flags: flags(mods))
  }

  private func tap(_ code: CGKeyCode, flags: CGEventFlags) {
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }

  private func type(_ text: String) {
    for ch in text {
      if ch == "\n" {
        tap(0x24, flags: [])
        continue
      }
      var units = Array(String(ch).utf16)
      for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
        event?.flags = []
        event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        event?.post(tap: .cghidEventTap)
      }
    }
  }
}

/// Media keys and system volume. macOS doesn't let apps read other apps'
/// now-playing info any more, so status reports volume only.
final class MacMedia {
  // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
  private let play: Int32 = 16
  private let next: Int32 = 17
  private let previous: Int32 = 18

  func status() -> [String: Any] {
    var out: [String: Any] = ["ok": true, "available": false, "nowPlaying": false, "muted": muted()]
    if let v = volume() { out["volume"] = v }
    return out
  }

  func perform(_ action: String, volume v: Double?) {
    switch action {
    case "playPause", "play", "pause": mediaKey(play)
    case "next": mediaKey(next)
    case "previous": mediaKey(previous)
    case "setVolume":
      if let v = v { setVolume(v) }
    case "volumeUp": setVolume((volume() ?? 0.5) + 0.06)
    case "volumeDown": setVolume((volume() ?? 0.5) - 0.06)
    case "toggleMute":
      _ = script("set volume output muted (not (output muted of (get volume settings)))")
    default: break
    }
  }

  private func mediaKey(_ key: Int32) {
    for down in [true, false] {
      let state: Int32 = down ? 0xA : 0xB
      let event = NSEvent.otherEvent(
        with: .systemDefined, location: .zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8), timestamp: 0,
        windowNumber: 0, context: nil, subtype: 8,
        data1: Int((key << 16) | (state << 8)), data2: -1)
      event?.cgEvent?.post(tap: .cghidEventTap)
    }
  }

  @discardableResult
  private func script(_ source: String) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    return NSAppleScript(source: source)?.executeAndReturnError(&error)
  }

  private func volume() -> Double? {
    guard let d = script("output volume of (get volume settings)") else { return nil }
    return Double(d.int32Value) / 100
  }

  private func muted() -> Bool {
    script("output muted of (get volume settings)")?.booleanValue ?? false
  }

  private func setVolume(_ v: Double) {
    script("set volume output volume \(Int((min(max(v, 0), 1) * 100).rounded()))")
  }
}

/// Streams the main display with ScreenCaptureKit and hands out the newest
/// frame as JPEG. Needs the Screen Recording permission.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
  private var stream: SCStream?
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var fresh = false
  private var failure: String?
  private let captureQueue = DispatchQueue(label: "dev.sidekick.screen.capture")
  private let encodeQueue = DispatchQueue(label: "dev.sidekick.screen.encode", qos: .userInitiated)
  private let context = CIContext()

  static let permissionMessage =
    "Allow Sidekick in System Settings → Privacy & Security → Screen Recording on the Mac, then quit and "
    + "reopen Sidekick there. (If it's already on, remove it with − and add it again.)"

  /// Calls [completion] on the main thread with nil once frames flow, or
  /// with a message for the viewer.
  func start(maxWidth: Int, completion: @escaping (String?) -> Void) {
    if stream != nil {
      completion(nil)
      return
    }
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      completion(ScreenStreamer.permissionMessage)
      return
    }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
      DispatchQueue.main.async {
        guard let content = content,
          let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else {
          completion(error?.localizedDescription ?? ScreenStreamer.permissionMessage)
          return
        }
        let config = SCStreamConfiguration()
        // SCDisplay sizes are in points; capture sharp on Retina, up to maxWidth.
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        var width = Double(display.width) * scale
        var height = Double(display.height) * scale
        if width > Double(maxWidth) {
          height = height * Double(maxWidth) / width
          width = Double(maxWidth)
        }
        config.width = Int(width)
        config.height = Int(height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3

        let stream = SCStream(
          filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        do {
          try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
        } catch {
          completion(error.localizedDescription)
          return
        }
        self.lock.lock()
        self.failure = nil
        self.lock.unlock()
        stream.startCapture { error in
          DispatchQueue.main.async {
            if let error = error {
              completion(error.localizedDescription)
            } else {
              self.stream = stream
              completion(nil)
            }
          }
        }
      }
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
    // Idle frames (nothing changed) carry no new picture.
    if let infos = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]],
      let raw = infos.first?[SCStreamFrameInfo.status] as? Int,
      let status = SCFrameStatus(rawValue: raw), status != .complete
    {
      return
    }
    lock.lock()
    latest = buffer
    fresh = true
    lock.unlock()
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock()
    latest = nil
    failure = error.localizedDescription
    lock.unlock()
    DispatchQueue.main.async { self.stream = nil }
  }

  /// The newest frame as JPEG, or nil data if the screen hasn't changed.
  /// Calls [completion] on the main thread.
  func frame(quality: Double, completion: @escaping (Data?, String?) -> Void) {
    lock.lock()
    let buffer = fresh ? latest : nil
    fresh = false
    let failure = self.failure
    lock.unlock()
    if let failure = failure {
      completion(nil, failure)
      return
    }
    guard let buffer = buffer else {
      completion(nil, nil)
      return
    }
    encodeQueue.async {
      let image = CIImage(cvPixelBuffer: buffer)
      let options = [
        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
      ]
      let data = self.context.jpegRepresentation(
        of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options)
      DispatchQueue.main.async { completion(data, nil) }
    }
  }

  func stop() {
    stream?.stopCapture { _ in }
    stream = nil
    lock.lock()
    latest = nil
    fresh = false
    lock.unlock()
  }
}
