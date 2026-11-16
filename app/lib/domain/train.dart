/// Renfe trip ids are `<service:5><train number:5><line>`, e.g. "3019L23525C1".
final _tripId = RegExp(r'^[0-9A-Z]{5}\d{5}[A-Za-z0-9]+$');

/// The train number inside [tripId], or null for other shapes. Same rule as the pipeline's
/// `train_number`, so the usual-platform map published in the feed can be looked up.
String? trainNumber(String tripId) => _tripId.hasMatch(tripId) ? tripId.substring(5, 10) : null;
