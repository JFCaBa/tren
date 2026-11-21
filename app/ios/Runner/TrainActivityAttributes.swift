import ActivityKit
import Foundation

/// The followed train's Live Activity. Shared by the app (starts and ends it) and the widget
/// extension (draws it). The server pushes `ContentState` as JSON with exactly these keys
/// (server/anden_api/live.py): `departs` is epoch seconds, not a Date, so decoding is unambiguous.
@available(iOS 16.1, *)
struct TrainActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var departs: Double?
    var status: String
    var platform: String?
    /// The platform is the usual one, not yet announced live.
    var usual: Bool?
    var `where`: String?
    var cancelled: Bool

    var departure: Date? { departs.map { Date(timeIntervalSince1970: $0) } }
  }

  /// "08:12 a Guadalajara"
  var title: String
  /// Stop id of the station it leaves from.
  var station: String
}
