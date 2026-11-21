import 'package:flutter/foundation.dart';

import 'follow_logic.dart';

/// Follows at most one train; null on platforms without background following.
abstract class Follower implements Listenable {
  FollowedTrain? get current;

  /// Starts following [t], replacing any other train. False when notifications are not allowed.
  Future<bool> follow(FollowedTrain t);

  Future<void> stop();

  /// Re-reads the follow state, e.g. after the app comes back to the foreground.
  Future<void> sync();

  /// Opens the system settings page where the user can allow this app's notifications.
  Future<void> openSettings();
}

/// Why [Follower.follow] could not start.
enum FollowFailure {
  /// Notifications are not allowed: the user can fix it in Settings.
  notifications,

  /// The train has left (or is no longer on the board).
  gone,

  /// Anything else: network, server, or the device could not get a push token.
  network,
}

class FollowFailed implements Exception {
  const FollowFailed(this.reason);
  final FollowFailure reason;

  @override
  String toString() => 'FollowFailed($reason)';
}
