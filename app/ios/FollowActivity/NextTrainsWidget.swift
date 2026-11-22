import SwiftUI
import WidgetKit

struct NextTrainsEntry: TimelineEntry {
  let date: Date
  let board: WidgetBoard?
  let rt: RtCache?

  /// Los trenes a la hora de esta entrada, con el retraso que aún vale a esa hora.
  var trains: [ShownTrain] {
    guard let board else { return [] }
    return resolve(board, rt: rt, at: date).filter { $0.departure >= date.addingTimeInterval(-60) }
  }
}

struct NextTrainsProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextTrainsEntry {
    NextTrainsEntry(date: Date(), board: sampleBoard(now: Date()), rt: nil)
  }

  /// En la galería: los trenes reales si los hay, si no un ejemplo.
  func getSnapshot(in context: Context, completion: @escaping (NextTrainsEntry) -> Void) {
    let now = Date()
    let real = NextTrainsEntry(date: now, board: loadBoard(), rt: loadRt())
    completion(context.isPreview && real.trains.isEmpty ? NextTrainsEntry(date: now, board: sampleBoard(now: now), rt: nil) : real)
  }

  /// Descarga el tiempo real de Renfe y deja una entrada por minuto: la cuenta atrás avanza, los
  /// trenes que salen desaparecen y los retrasos caducan solos si iOS tarda en volver a pedirla.
  /// Pide volver en 15 min (iOS decide cuándo, como con Tiempo o Bolsa).
  func getTimeline(in context: Context, completion: @escaping (Timeline<NextTrainsEntry>) -> Void) {
    refreshRt { rt in
      let board = loadBoard()
      let now = Date()
      var entries = [NextTrainsEntry(date: now, board: board, rt: rt)]
      var t = now.addingTimeInterval(60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
      while entries.count < 120 {
        entries.append(NextTrainsEntry(date: t, board: board, rt: rt))
        t = t.addingTimeInterval(60)
      }
      completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
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
  let train: ShownTrain
  let now: Date
  let compact: Bool

  private var wait: String {
    if train.canceled { return "Cancelado" }
    let m = Int(train.departure.timeIntervalSince(now) / 60)
    if m <= 0 { return "ahora" }
    return m < 60 ? "\(m) min" : hhmm(train.departure)
  }

  private var late: Bool { (train.delayMin ?? 0) >= 3 && !train.canceled }

  private var badge: some View {
    Text(train.line)
      .font(.caption.weight(.bold))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(RoundedRectangle(cornerRadius: 4).fill(Color(argb: train.color)))
      .foregroundStyle(onColor(train.color))
  }

  var body: some View {
    if compact {
      // Pequeño: solo línea y hora; el cancelado, tachado y atenuado.
      HStack(spacing: 6) {
        badge
        Spacer(minLength: 2)
        Text(hhmm(train.departure))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .strikethrough(train.canceled)
          .fixedSize()
          .foregroundStyle(late ? amber : Color.primary)
      }
      .opacity(train.canceled ? 0.5 : 1)
    } else {
      full
    }
  }

  private var full: some View {
    HStack(spacing: 6) {
      badge
      VStack(alignment: .leading, spacing: 0) {
        Text(train.dest).font(.caption).lineLimit(1)
        if let a = train.arrival {
          Text("llega \(hhmm(a))").font(.caption2).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 2)
      if let p = train.platform, !train.canceled {
        Text(p)
          .font(.caption2.weight(.bold))
          .fixedSize()
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
        .fixedSize()
        .foregroundStyle(late ? amber : Color.primary)
    }
    .opacity(train.canceled ? 0.5 : 1)
  }
}

struct NextTrainsView: View {
  @Environment(\.widgetFamily) var family
  let entry: NextTrainsEntry

  var body: some View {
    let max = 4
    let trains = entry.trains
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
