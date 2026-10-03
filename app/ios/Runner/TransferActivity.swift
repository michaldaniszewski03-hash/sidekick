// A transfer as a Live Activity: what the Lock Screen and the Dynamic Island
// show while files go to or come from another device. Compiled into both
// the app (Runner: starts and updates it, LiveTransfers in AppDelegate.swift)
// and the SidekickLive widget extension (draws it).

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct TransferActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// Bytes so far, and in all.
    var done: Int64
    var total: Int64
    /// "Receiving…", "Sending…", "Received", "Sent", "Declined"…
    var status: String
    var finished: Bool
    /// It didn't make it (declined, failed): shown in red.
    var failed: Bool
  }

  /// The other device's name.
  var device: String
  /// Coming to this iPhone (true) or going from it.
  var incoming: Bool
  /// "IMG_2041.HEIC", or "3 files".
  var title: String
}
