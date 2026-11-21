import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as tzdata;

import '../data/train_client.dart';
import 'follow_logic.dart';
import 'follow_loop.dart';
import 'follower.dart';

const _trainKey = 'follow_train';
const _startedKey = 'follow_started_ms';
const _stopButton = 'stop';
const _pollEvery = Duration(seconds: 30);

/// Monochrome status bar icon (res/drawable/ic_stat_train.xml); the app icon shows as a square.
const _statusIcon = 'ic_stat_train';
const _brand = Color(0xFF0F766E);

/// Android: follows the train in a foreground service, so it keeps polling with the app closed.
class FollowService extends ChangeNotifier implements Follower {
  FollowService._();

  /// Call once, before runApp.
  static Future<FollowService> create() async {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'following',
        channelName: 'Siguiendo un tren',
        channelDescription: 'Muestra el tren que sigues mientras la app lo consulta',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.repeat(_pollEvery.inMilliseconds)),
    );
    final s = FollowService._();
    FlutterForegroundTask.addTaskDataCallback(s._onTaskData);
    await s.sync();
    return s;
  }

  FollowedTrain? _current;
  Future<void> _queue = Future.value();

  @override
  FollowedTrain? get current => _current;

  /// One change at a time: a quick follow-then-follow cannot interleave two services.
  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _queue.then((_) => f());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  @override
  Future<void> sync() => _serial(() async {
        _set(await FlutterForegroundTask.isRunningService ? await _saved() : null);
      });

  @override
  Future<bool> follow(FollowedTrain t) => _serial(() async {
        if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted &&
            await FlutterForegroundTask.requestNotificationPermission() != NotificationPermission.granted) {
          return false;
        }
        if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
        await FlutterForegroundTask.saveData(key: _trainKey, value: jsonEncode(t.toJson()));
        await FlutterForegroundTask.saveData(key: _startedKey, value: DateTime.now().millisecondsSinceEpoch);
        final r = await FlutterForegroundTask.startService(
          serviceId: 7,
          serviceTypes: [ForegroundServiceTypes.dataSync],
          notificationTitle: 'Siguiendo',
          notificationText: t.title,
          notificationButtons: const [NotificationButton(id: _stopButton, text: 'Dejar de seguir')],
          notificationIcon: const NotificationIcon(metaDataName: 'com.jfcaba.proximotren.FOLLOW_ICON', backgroundColor: _brand),
          callback: followCallback,
        );
        if (r is! ServiceRequestSuccess) {
          await _clearSaved();
          _set(null);
          return false;
        }
        _set(t);
        return true;
      });

  @override
  Future<void> stop() => _serial(() async {
        await _clearSaved();
        await FlutterForegroundTask.stopService();
        _set(null);
      });

  /// flutter_foreground_task has no notification-settings page; the app details page has the toggle.
  @override
  Future<void> openSettings() async {
    await Geolocator.openAppSettings();
  }

  void _onTaskData(Object data) {
    if (data is! String) return;
    final stopped = FollowedTrain.fromJson(jsonDecode(data) as Map<String, dynamic>);
    if (stopped == _current) _set(null); // a newer follow is not cleared by the old one ending
  }

  void _set(FollowedTrain? t) {
    if (t == _current) return;
    _current = t;
    notifyListeners();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    super.dispose();
  }
}

Future<FollowedTrain?> _saved() async {
  final j = await FlutterForegroundTask.getData<String>(key: _trainKey);
  return j == null ? null : FollowedTrain.fromJson(jsonDecode(j) as Map<String, dynamic>);
}

Future<void> _clearSaved() async {
  await FlutterForegroundTask.removeData(key: _trainKey);
  await FlutterForegroundTask.removeData(key: _startedKey);
}

@pragma('vm:entry-point')
void followCallback() {
  // Its own isolate: the time zones main() loaded are not here.
  tzdata.initializeTimeZones();
  FlutterForegroundTask.setTaskHandler(_FollowHandler());
}

/// Runs in the service's own isolate.
class _FollowHandler extends TaskHandler {
  final _notes = FlutterLocalNotificationsPlugin();
  final _client = http.Client();
  FollowLoop? _loop;
  FollowedTrain? _train;
  int _alertId = 100;
  bool _ending = false;

  static const _alertDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'train_changes',
      'Cambios del tren',
      channelDescription: 'Cambios de vía, retrasos y cancelaciones del tren que sigues',
      importance: Importance.high,
      priority: Priority.high,
      icon: _statusIcon,
      color: _brand,
    ),
  );

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _notes.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings(_statusIcon)));
    final train = await _saved();
    final startedMs = await FlutterForegroundTask.getData<int>(key: _startedKey);
    if (train == null || startedMs == null) {
      await _end(notify: false);
      return;
    }
    _train = train;
    _loop = FollowLoop(
      train: train,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedMs),
      fetch: TrainClient(_client).fetch,
      clock: DateTime.now,
      alert: (title, body) => _notes.show(id: _alertId++, title: title, body: body, notificationDetails: _alertDetails),
      ongoing: (title, text) async {
        if (!_ending) await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      },
    );
    unawaited(_poll());
  }

  @override
  void onRepeatEvent(DateTime timestamp) => unawaited(_poll());

  Future<void> _poll() async {
    final loop = _loop;
    if (loop == null || _ending) return;
    if (!await loop.tick()) await _end();
  }

  /// Stops following from the service side and tells the app, if it is open.
  Future<void> _end({bool notify = true}) async {
    if (_ending) return;
    _ending = true;
    final t = _train;
    // The app may already have started following another train: then that follow owns the service.
    final saved = await _saved();
    if (saved != null && saved != t) return;
    if (notify && t != null) FlutterForegroundTask.sendDataToMain(jsonEncode(t.toJson()));
    await _clearSaved();
    await FlutterForegroundTask.stopService();
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == _stopButton) unawaited(_end());
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/');

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Android ended the service: the follow is over (and tell the app).
    if (isTimeout) await _end();
    // From here on a poll still running must not rewrite the next train's notification.
    _ending = true;
    _client.close();
  }


  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationDismissed() {}
}
