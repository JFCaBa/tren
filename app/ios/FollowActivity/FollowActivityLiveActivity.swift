import ActivityKit
import SwiftUI
import WidgetKit

/// Cuenta atrás hasta la salida, dibujada por iOS sin pushes. Solo con una hora futura: un rango
/// invertido haría fallar el widget.
@available(iOS 16.1, *)
private struct Countdown: View {
  let state: TrainActivityAttributes.ContentState
  var body: some View {
    if state.cancelled {
      Text("Cancelado").foregroundStyle(.red)
    } else if let d = state.departure, d > Date() {
      Text(timerInterval: Date()...d, countsDown: true).monospacedDigit()
    } else if state.departure != nil {
      Text("Ahora")
    } else {
      Text(state.status.isEmpty ? "Sin hora" : state.status).foregroundStyle(.orange)
    }
  }
}

@available(iOS 16.1, *)
private struct PlatformTile: View {
  let platform: String?
  let usual: Bool
  var body: some View {
    VStack(spacing: 0) {
      Text(usual ? "Vía habitual" : "Vía").font(.caption2)
      Text(platform ?? "–").font(.system(size: 30, weight: .heavy)).minimumScaleFactor(0.5)
    }
    .frame(minWidth: 70)
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(platform == nil || usual ? Color.gray.opacity(0.35) : Color(red: 0.06, green: 0.46, blue: 0.43)))
    .foregroundStyle(.white)
  }
}

@available(iOS 16.1, *)
struct FollowActivityLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TrainActivityAttributes.self) { context in
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(context.attributes.title).font(.headline).lineLimit(1)
          Countdown(state: context.state).font(.system(size: 28, weight: .heavy))
            .frame(maxWidth: .infinity, alignment: .leading)
          if !context.state.status.isEmpty && !context.state.cancelled {
            Text(context.state.status).font(.subheadline).foregroundStyle(.secondary)
          }
          if let w = context.state.where {
            Label(w, systemImage: "tram.fill").font(.caption).lineLimit(2)
          }
        }
        PlatformTile(platform: context.state.platform, usual: context.state.usual ?? false)
      }
      .padding(14)
      .activityBackgroundTint(Color.black.opacity(0.75))
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.title).font(.caption).lineLimit(2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          PlatformTile(platform: context.state.platform, usual: context.state.usual ?? false)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 2) {
            Countdown(state: context.state).font(.title2.bold())
            if let w = context.state.where {
              Text(w).font(.caption).lineLimit(1)
            }
          }
        }
      } compactLeading: {
        Text(context.state.platform.map { "V\($0)" } ?? "V–").bold()
      } compactTrailing: {
        Countdown(state: context.state).frame(maxWidth: 56)
      } minimal: {
        Text(context.state.platform ?? "–").bold()
      }
    }
  }
}
