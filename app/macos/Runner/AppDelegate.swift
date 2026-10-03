import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // With the menu-bar icon up, closing the window never quits Sidekick:
  // only Quit Sidekick there (or Command-Q) does.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !sender.windows.contains { ($0 as? MainFlutterWindow)?.keepInMenuBar == true }
  }

  // Closed to the menu bar, a click on the Dock icon brings the window back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows {
        window.makeKeyAndOrderFront(self)
      }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
