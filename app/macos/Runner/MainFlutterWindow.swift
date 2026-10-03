import AVFoundation
import ApplicationServices
import Cocoa
import QuartzCore
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let native = SidekickNative()
  private var ble: SidekickBLE?
  private var p2p: SidekickP2P?

  /// Closing hides the window to the menu bar (set from Dart once the
  /// menu-bar icon is up). Done here, not by window_manager: its window
  /// delegate never got the close on the Mac, so the red button quit.
  var keepInMenuBar = false
  private var inMenuBar = false

  // The red button and Command-W.
  override func performClose(_ sender: Any?) {
    guard keepInMenuBar else { return super.performClose(sender) }
    inMenuBar = true
    orderOut(nil)
    native.channel?.invokeMethod("closedToMenuBar", arguments: nil)
  }

  // Back on screen (the menu bar's Open Sidekick, or a click on the Dock).
  override func makeKeyAndOrderFront(_ sender: Any?) {
    if inMenuBar {
      inMenuBar = false
      native.channel?.invokeMethod("openedFromMenuBar", arguments: nil)
    }
    super.makeKeyAndOrderFront(sender)
  }

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
    native.window = self
    native.channel = channel
    channel.setMethodCallHandler { call, result in native.handle(call, result: result) }
    ble = SidekickBLE.register(messenger: flutterViewController.engine.binaryMessenger)
    p2p = SidekickP2P.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// The Mac side of the `sidekick/macos` channel: remote mouse/keyboard input
/// (needs the Accessibility permission).
final class SidekickNative {
  private let input = MacInput()
  /// Sidekick's window, for the tray: shown as the corner pop-up without
  /// taking the focus from whatever you're doing.
  weak var window: NSWindow?
  /// For telling Dart the window went to / came back from the menu bar.
  var channel: FlutterMethodChannel?
  /// Held until they finish: a player that's let go stops at once.
  private var players: [AVAudioPlayer] = []
  private var sound: NSSound?

  /// Sidekick's sounds: AVAudioPlayer, or NSSound if that can't open the file.
  private func play(_ path: String) -> Bool {
    players.removeAll { !$0.isPlaying }
    if let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) {
      players.append(player)
      player.prepareToPlay()
      if player.play() { return true }
    }
    guard let sound = NSSound(contentsOfFile: path, byReference: false) else { return false }
    self.sound?.stop()
    self.sound = sound
    return sound.play()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "permissions":
      result(["accessibility": AXIsProcessTrusted()])
    case "requestAccessibility":
      let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      {
        NSWorkspace.shared.open(url)
      }
      result(nil)
    case "playSound":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(false)
        return
      }
      result(play(path))
    case "input":
      if let msg = call.arguments as? [String: Any] { input.handle(msg) }
      result(AXIsProcessTrusted())
    case "setKeepInMenuBar":
      // The menu-bar icon is up: the red button hides the window instead
      // of quitting (Sidekick keeps running, and stays in the Dock).
      (window as? MainFlutterWindow)?.keepInMenuBar =
        (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      result(nil)
    case "showPopup":
      // In front of everything, without activating Sidekick: it fades in,
      // rising a little into its corner.
      guard let window else { return result(nil) }
      let target = window.frame
      window.alphaValue = 0
      window.setFrame(target.offsetBy(dx: 0, dy: -18), display: false)
      window.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.28
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 1
        window.animator().setFrame(target, display: true)
      }
      result(nil)
    case "hidePopup":
      // Fades out, then hides (ready to come back at full opacity).
      guard let window else { return result(nil) }
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        window.animator().alphaValue = 0
      }, completionHandler: {
        window.orderOut(nil)
        window.alphaValue = 1
        result(nil)
      })
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

  // Separate down/up presses (e.g. dragging with Hold) must
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
