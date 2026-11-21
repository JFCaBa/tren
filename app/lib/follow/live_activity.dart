import 'dart:async';

import 'package:flutter/services.dart';

import 'follow_logic.dart';

/// The iOS Live Activity for the followed train (lock screen and Dynamic Island). The app starts
/// and ends it; the server updates it by push, using the token from [tokens].
abstract class LiveActivity {
  /// Starts one for [t], ending any other. False where Live Activities are unavailable or off.
  Future<bool> start(FollowedTrain t, Map<String, Object?> state);

  Future<void> update(Map<String, Object?> state);

  Future<void> end();

  /// Push tokens for the current activity, as lowercase hex; iOS may give a new one at any time.
  Stream<String> get tokens;
}

/// Over the `anden/activity` channel (ios/Runner/AppDelegate.swift).
class ChannelLiveActivity implements LiveActivity {
  ChannelLiveActivity() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token' && call.arguments is String) _tokens.add(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('anden/activity');
  final _tokens = StreamController<String>.broadcast();

  @override
  Stream<String> get tokens => _tokens.stream;

  @override
  Future<bool> start(FollowedTrain t, Map<String, Object?> state) async {
    try {
      return await _channel.invokeMethod<bool>('start', {
            'title': t.title,
            'station': t.stopId,
            'state': state,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> update(Map<String, Object?> state) => _call('update', {'state': state});

  @override
  Future<void> end() => _call('end', null);

  Future<void> _call(String method, Object? args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException {
      // best effort: the server's end push or iOS's own timeout ends it
    } on MissingPluginException {
      // not on iOS
    }
  }
}
