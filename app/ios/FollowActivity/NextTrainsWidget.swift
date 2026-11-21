import SwiftUI
import WidgetKit

/// Lo que la app deja en el App Group (lib/widget/next_trains_widget.dart).
struct WidgetTrain: Decodable {
  let line: String
  let color: Int
  let dest: String
  let dep: Double
  let sched: Double
  let delayMin: Int?
  let platform: String?
  let live: Bool
  let canceled: Bool
  let arrival: Double?

  var departure: Date { Date(timeIntervalSince1970: dep) }
}

struct WidgetBoard: Decodable {
  let station: String
  let via: String?
  let trains: [WidgetTrain]
}

private let appGroup = "group.com.jfcaba.proximotren"

private func loadBoard() -> WidgetBoard? {
  guard let json = UserDefaults(suiteName: appGroup)?.string(forKey: "next_trains"),
        let data = json.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(WidgetBoard.self, from: data)
}

struct NextTrainsEntry: TimelineEntry {
  let date: Date
  let board: WidgetBoard?
}

struct NextTrainsProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextTrainsEntry { NextTrainsEntry(date: Date(), board: nil) }

  func getSnapshot(in context: Context, completion: @escaping (NextTrainsEntry) -> Void) {
    completion(NextTrainsEntry(date: Date(), board: loadBoard()))
  }

  /// Una entrada por minuto mientras quede algún tren: la cuenta atrás avanza y los trenes que
  /// salen desaparecen sin que la app tenga que despertar.
  func getTimeline(in context: Context, completion: @escaping (Timeline<NextTrainsEntry>) -> Void) {
    let board = loadBoard()
    let now = Date()
    let last = board?.trains.map(\.departure).max() ?? now
    var entries = [NextTrainsEntry(date: now, board: board)]
    var t = now.addingTimeInterval(60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
    while t <= last.addingTimeInterval(60) && entries.count < 120 {
      entries.append(NextTrainsEntry(date: t, board: board))
      t = t.addingTimeInterval(60)
    }
    completion(Timeline(entries: entries, policy: .never))
  }
}

private extension Color {
  init(argb: Int) {
    self.init(red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
              blue: Double(argb & 0xFF) / 255)
  }
}

private extension Color {
  static var widgetBackground: Color {
    #if os(iOS)
    Color(.systemBackground)
    #else
    Color.white
    #endif
  }
}

private let teal = Color(red: 0.06, green: 0.46, blue: 0.43)
private let amber = Color(red: 0.80, green: 0.45, blue: 0.0)

private func hhmm(_ d: Date) -> String {
  let f = DateFormatter()
  f.dateFormat = "HH:mm"
  f.timeZone = TimeZone(identifier: "Europe/Madrid")
  return f.string(from: d)
}

/// Texto negro o blanco según la luminancia del color de la línea (igual que la app).
private func onColor(_ argb: Int) -> Color {
  func lin(_ c: Int) -> Double {
    let v = Double(c) / 255
    return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
  }
  let l = 0.2126 * lin((argb >> 16) & 0xFF) + 0.7152 * lin((argb >> 8) & 0xFF) + 0.0722 * lin(argb & 0xFF)
  return l > 0.179 ? .black : .white
}

private struct TrainRow: View {
  let train: WidgetTrain
  let now: Date
  let compact: Bool

  private var wait: String {
    if train.canceled { return "Cancelado" }
    let m = Int(train.departure.timeIntervalSince(now) / 60)
    if m <= 0 { return "ahora" }
    return m < 60 ? "\(m) min" : hhmm(train.departure)
  }

  var body: some View {
    HStack(spacing: 6) {
      Text(train.line)
        .font(.caption.weight(.bold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(argb: train.color)))
        .foregroundStyle(onColor(train.color))
      VStack(alignment: .leading, spacing: 0) {
        Text(train.dest).font(.caption).lineLimit(1)
        if let a = train.arrival, !compact {
          Text("llega \(hhmm(Date(timeIntervalSince1970: a)))").font(.caption2).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 2)
      if let p = train.platform, !train.canceled {
        Text(p)
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 4)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(train.live ? teal : Color.clear)
              .overlay(RoundedRectangle(cornerRadius: 4).stroke(teal, lineWidth: train.live ? 0 : 1)))
          .foregroundStyle(train.live ? Color.white : teal)
      }
      Text(wait)
        .font(.caption.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle((train.delayMin ?? 0) >= 3 && !train.canceled ? amber : Color.primary)
    }
    .opacity(train.canceled ? 0.5 : 1)
  }
}

struct NextTrainsView: View {
  @Environment(\.widgetFamily) var family
  let entry: NextTrainsEntry

  var body: some View {
    let max = family == .systemSmall ? 3 : 4
    let trains = (entry.board?.trains ?? []).filter { $0.departure >= entry.date.addingTimeInterval(-60) }
    VStack(alignment: .leading, spacing: 4) {
      if let b = entry.board {
        HStack(spacing: 4) {
          Text(b.station).font(.subheadline.weight(.bold)).lineLimit(1)
          if let v = b.via { Text("→ \(v)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
      }
      if trains.isEmpty {
        Spacer(minLength: 0)
        Text("Abre Andén para ver los próximos trenes").font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      } else {
        ForEach(Array(trains.prefix(max).enumerated()), id: \.offset) { _, t in
          TrainRow(train: t, now: entry.date, compact: family == .systemSmall)
        }
        Spacer(minLength: 0)
      }
    }
    .widgetBackground()
  }
}

private extension View {
  @ViewBuilder func widgetBackground() -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(for: .widget) { Color.widgetBackground }
    } else {
      padding()
    }
  }
}

struct NextTrainsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "NextTrainsWidget", provider: NextTrainsProvider()) { entry in
      NextTrainsView(entry: entry)
    }
    .configurationDisplayName("Próximos trenes")
    .description("Los próximos trenes de la última estación que abriste.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
