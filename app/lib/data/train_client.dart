import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../follow/follow_logic.dart';

/// One train's live reading from our server (a few hundred bytes, instead of Renfe's two
/// ~130 KB feeds every 30 s while following).
class TrainClient {
  TrainClient(this._client, {this.baseUrl = apiBaseUrl});

  final http.Client _client;
  final String baseUrl;

  /// Throws on network, HTTP or shape errors.
  Future<TrainReading> fetch(String tripId, String stopId) async {
    final url = '$baseUrl/train/${Uri.encodeComponent(tripId)}/${Uri.encodeComponent(stopId)}';
    final r = await _client.get(Uri.parse(url), headers: const {'User-Agent': userAgent}).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw http.ClientException('train HTTP ${r.statusCode}');
    final reading = TrainReading.fromJson(jsonDecode(utf8.decode(r.bodyBytes)));
    if (reading == null) throw const FormatException('train reading');
    return reading;
  }
}
