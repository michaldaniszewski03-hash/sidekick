// The SidekickLive widget extension: a transfer's Live Activity on the Lock
// Screen and in the Dynamic Island (TransferActivityAttributes, shared with
// the app). The app starts, updates and ends it.

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SidekickLiveBundle: WidgetBundle {
  var body: some Widget {
    TransferLiveActivity()
  }
}

/// Sidekick's purple, and the colors that go with it.
private let accent = Color(red: 0.56, green: 0.40, blue: 0.98)
private let accent2 = Color(red: 0.93, green: 0.42, blue: 0.67)
private let failure = Color(red: 1.0, green: 0.42, blue: 0.42)

private typealias Context = ActivityViewContext<TransferActivityAttributes>

private func fraction(_ s: TransferActivityAttributes.ContentState) -> Double {
  if s.finished && !s.failed { return 1 }
  guard s.total > 0 else { return 0 }
  return min(max(Double(s.done) / Double(s.total), 0), 1)
}

private func bytes(_ n: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

private func symbol(_ c: Context) -> String {
  if c.state.failed { return "xmark" }
  if c.state.finished { return "checkmark" }
  return c.attributes.incoming ? "arrow.down" : "arrow.up"
}

private func tint(_ c: Context) -> Color { c.state.failed ? failure : accent }

/// The arrow (or check) in a gradient circle, like the app's badge.
private struct Badge: View {
  let context: Context
  var size: CGFloat = 44

  var body: some View {
    ZStack {
      Circle()
        .fill(
          context.state.failed
            ? AnyShapeStyle(failure)
            : AnyShapeStyle(LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
      Image(systemName: symbol(context))
        .font(.system(size: size * 0.42, weight: .bold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
  }
}

/// "Receiving from Mac · 12 MB of 44 MB"
private func detail(_ c: Context) -> String {
  let who = c.attributes.incoming ? "from \(c.attributes.device)" : "to \(c.attributes.device)"
  if c.state.finished { return "\(c.state.status) \(who)" }
  let amount = c.state.total > 0 ? " · \(bytes(c.state.done)) of \(bytes(c.state.total))" : ""
  return "\(c.state.status) \(who)\(amount)"
}

private func percent(_ c: Context) -> String {
  if c.state.failed { return "" }
  return "\(Int((fraction(c.state) * 100).rounded()))%"
}

struct TransferLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TransferActivityAttributes.self) { context in
      // The Lock Screen, and the banner on iPhones without a Dynamic Island.
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          Badge(context: context)
          VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.title)
              .font(.headline)
              .lineLimit(1)
            Text(detail(context))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Text(percent(context))
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint(context))
        }
        ProgressView(value: fraction(context.state))
          .tint(tint(context))
      }
      .padding(16)
      .activitySystemActionForegroundColor(accent)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Badge(context: context, size: 38)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(percent(context))
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint(context))
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.attributes.title)
            .font(.headline)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: fraction(context.state))
              .tint(tint(context))
            Text(detail(context))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .padding(.horizontal, 4)
        }
      } compactLeading: {
        Image(systemName: symbol(context))
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(tint(context))
      } compactTrailing: {
        ProgressView(value: fraction(context.state))
          .progressViewStyle(.circular)
          .tint(tint(context))
          .frame(width: 18, height: 18)
      } minimal: {
        ProgressView(value: fraction(context.state))
          .progressViewStyle(.circular)
          .tint(tint(context))
      }
      .keylineTint(accent)
    }
  }
}
