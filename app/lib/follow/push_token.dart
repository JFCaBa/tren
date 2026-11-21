import 'package:flutter/services.dart';

/// The device's push registration (APNs on iOS).
abstract class PushToken {
  /// Asks to show alerts; false when the user said no.
  Future<bool> requestPermission();

  /// Lowercase hex device token, or null when the device could not register.
  Future<String?> token();

  /// APNs environment the token belongs to: 'sandbox' or 'production'.
  Future<String> environment();

  /// Opens this app's page in the Settings app.
  Future<void> openSettings();
}

/// Talks to AppDelegate.swift over the `anden/push` channel. Never throws: a failure reads as
/// no permission, no token or production.
class ChannelPushToken implements PushToken {
  const ChannelPushToken();

  static const _channel = MethodChannel('anden/push');

  /// The method's answer, or null when the native side failed or is missing.
  static Future<T?> _call<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> requestPermission() async => await _call<bool>('requestPermission') ?? false;

  @override
  Future<String?> token() => _call<String>('token');

  @override
  Future<String> environment() async => await _call<String>('environment') == 'sandbox' ? 'sandbox' : 'production';

  @override
  Future<void> openSettings() => _call<void>('openSettings');
}
