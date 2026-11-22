import Foundation

// Datos del widget de próximos trenes: lo que deja la app (lib/widget/next_trains_widget.dart), el
// tiempo real que descarga el propio widget y la mezcla de ambos. Solo Foundation, para probarlo
// fuera del simulador.

/// Un tren tal como lo deja la app: horas programadas y el retraso que la app conocía.
struct WidgetTrain: Codable {
  let line: String
  let color: Int
  let dest: String
  let sched: Double?
  let arrSched: Double?
  let delaySec: Int?
  let canceled: Bool?
  let platform: String?
  let live: Bool?
  /// Id del trip en el tiempo real de Renfe; nulo si el id se repite en varios días.
  let rt: String?
}

struct WidgetBoard: Codable {
  let station: String
  let via: String?
  let updatedAt: Double?
  /// Cuándo se descargó el tiempo real que usó la app; nulo si no tenía uno reciente.
  let rtAt: Double?
  let trains: [WidgetTrain]
}

/// Tiempo real de Renfe que guardó el widget: todo el feed, para que un cambio de estación a mitad de
/// descarga no deje trenes sin datos.
struct RtCache: Codable {
  struct Trip: Codable {
    let d: Int?
    let c: Bool
  }

  let fetchedAt: Double
  let feedAt: Double
  let trips: [String: Trip]
}

/// Un tren listo para pintar.
struct ShownTrain {
  let line: String
  let color: Int
  let dest: String
  let departure: Date
  let arrival: Date?
  let delayMin: Int?
  let canceled: Bool
  let platform: String?
  let live: Bool
}

/// Datos de más de esto no se usan: el tren va a su hora programada.
let rtMaxAge: TimeInterval = 30 * 60

/// Retraso y cancelación de cada tren a la hora [now]: manda la fuente más reciente de menos de
/// 30 min (el tiempo real del widget o el que usó la app, según cuándo se descargó cada uno); sin
/// ninguna, la hora programada.
func resolve(_ board: WidgetBoard, rt: RtCache?, at now: Date) -> [ShownTrain] {
  let t = now.timeIntervalSince1970
  let appAt = board.rtAt ?? 0
  let appFresh = t - appAt < rtMaxAge
  let rtFresh = rt.map { t - $0.fetchedAt < rtMaxAge && t - $0.feedAt < rtMaxAge && $0.fetchedAt > appAt } ?? false
  var shown: [ShownTrain] = []
  for train in board.trains {
    guard let sched = train.sched else { continue } // datos de una versión anterior
    var delay: Int?
    var canceled = false
    if rtFresh, let rt {
      // Como en la app: un tren que no sale en un tiempo real reciente va a su hora.
      if let id = train.rt, let r = rt.trips[id] {
        canceled = r.c
        delay = r.c ? nil : r.d
      }
    } else if appFresh {
      canceled = train.canceled ?? false
      delay = canceled ? nil : train.delaySec
    }
    let shift = TimeInterval(delay ?? 0)
    shown.append(ShownTrain(
      line: train.line, color: train.color, dest: train.dest,
      departure: Date(timeIntervalSince1970: sched + shift),
      arrival: train.arrSched.map { Date(timeIntervalSince1970: $0 + shift) },
      delayMin: delay.map { Int((Double($0) / 60).rounded()) },
      canceled: canceled, platform: train.platform, live: train.live ?? false))
  }
  return shown.sorted { $0.departure < $1.departure }
}

private func number(_ v: Any?) -> Double? {
  switch v {
  case let n as NSNumber: return n.doubleValue
  case let s as String: return Double(s)
  default: return nil
  }
}

/// `trip_updates.json` de Renfe: retraso por tren (`tripUpdate.delay`) y cancelados, como la app.
func parseTripUpdates(_ data: Data, fetchedAt: Date) -> RtCache? {
  guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
  let feedAt = number((json["header"] as? [String: Any])?["timestamp"]) ?? 0
  var trips: [String: RtCache.Trip] = [:]
  for e in json["entity"] as? [Any] ?? [] {
    guard let tu = (e as? [String: Any])?["tripUpdate"] as? [String: Any],
          let trip = tu["trip"] as? [String: Any],
          let id = trip["tripId"] as? String else { continue }
    trips[id] = RtCache.Trip(d: number(tu["delay"]).map { Int($0) },
                             c: (trip["scheduleRelationship"] as? String) == "CANCELED")
  }
  return RtCache(fetchedAt: fetchedAt.timeIntervalSince1970, feedAt: feedAt, trips: trips)
}

let appGroup = "group.com.jfcaba.proximotren"
private let boardKey = "next_trains"
private let rtKey = "widget_rt"
private let rtUrl = URL(string: "https://gtfsrt.renfe.com/trip_updates.json")!

func loadBoard() -> WidgetBoard? {
  guard let json = UserDefaults(suiteName: appGroup)?.string(forKey: boardKey),
        let data = json.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(WidgetBoard.self, from: data)
}

func loadRt() -> RtCache? {
  guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: rtKey) else { return nil }
  return try? JSONDecoder().decode(RtCache.self, from: data)
}

/// Descarga el tiempo real (como mucho una vez por minuto) y lo guarda; si falla, el guardado.
func refreshRt(completion: @escaping (RtCache?) -> Void) {
  let saved = loadRt()
  if let saved, Date().timeIntervalSince1970 - saved.fetchedAt < 60 { return completion(saved) }
  var req = URLRequest(url: rtUrl, timeoutInterval: 10)
  req.setValue("Anden/1.4", forHTTPHeaderField: "User-Agent")
  URLSession.shared.dataTask(with: req) { data, resp, _ in
    guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
          let rt = parseTripUpdates(data, fetchedAt: Date()) else { return completion(saved) }
    if let encoded = try? JSONEncoder().encode(rt) { UserDefaults(suiteName: appGroup)?.set(encoded, forKey: rtKey) }
    completion(rt)
  }.resume()
}

/// Lo que se ve en la galería de widgets cuando aún no hay trenes reales.
func sampleBoard(now: Date) -> WidgetBoard {
  let t = now.timeIntervalSince1970
  func train(_ line: String, _ color: Int, _ dest: String, _ min: Double, delay: Int? = nil, platform: String, live: Bool) -> WidgetTrain {
    WidgetTrain(line: line, color: color, dest: dest, sched: t + min * 60, arrSched: nil, delaySec: delay,
                canceled: false, platform: platform, live: live, rt: nil)
  }
  return WidgetBoard(station: "Atocha", via: nil, updatedAt: t, rtAt: t, trains: [
    train("C3", 0xFF8E4A9E, "Aranjuez", 3, platform: "2", live: true),
    train("C4a", 0xFF1F57A0, "Parla", 6, platform: "5", live: false),
    train("C5", 0xFFF2B200, "Móstoles El Soto", 5, delay: 240, platform: "8", live: false),
    train("C2", 0xFF00A650, "Guadalajara", 14, platform: "1", live: false),
  ])
}
