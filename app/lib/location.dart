import 'package:geolocator/geolocator.dart';

abstract class LocationSource {
  /// Current (lat, lon), or null without permission, with location off, or on timeout.
  /// Only asks the user for permission when [requestPermission] is true (an explicit or first-launch action).
  Future<(double, double)?> current({bool requestPermission = false});
}

class GeolocatorLocationSource implements LocationSource {
  @override
  Future<(double, double)?> current({bool requestPermission = false}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && requestPermission) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 8)),
      );
      return (pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }
}
